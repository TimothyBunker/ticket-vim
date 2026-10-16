local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.o.swapfile = false
local U = require('tim.util')
local P = require('tim.project')
local R = require('tim.references')
local S = require('tim.store')
local App = require('tim.app')
local H = require('tim.history')
local temp = vim.fn.tempname()
U.mkdir(temp)
local passed, failed, apps = 0, 0, {}
local notifications = {}
vim.notify = function(msg, level) notifications[#notifications + 1] = { msg, level } end

local function eq(actual, expected)
  assert(vim.deep_equal(actual, expected), 'expected ' .. vim.inspect(expected) .. ', got ' .. vim.inspect(actual))
end
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then passed = passed + 1; print('PASS ' .. name)
  else failed = failed + 1; print('FAIL ' .. name .. '\n' .. err) end
end
local function repo(name)
  local path = temp .. '/' .. name
  U.mkdir(path .. '/src')
  U.atomic(path .. '/src/example.py', 'first\nsecond\nthird\n')
  assert(U.run({ 'git', 'init', '-b', 'main', path }))
  assert(U.run({ 'git', '-C', path, 'add', '.' }))
  assert(U.run({ 'git', '-C', path, '-c', 'user.name=Tim Test', '-c', 'user.email=test@example.invalid', 'commit', '-m', 'fixture' }))
  return path
end
local function app(path, name)
  local value = App.new({ root = path, name = name, data_dir = temp .. '/data',
    pi_command = { 'python3', root .. '/tests/fake_pi.py' }, rpc_timeout = 3000 })
  apps[#apps + 1] = value
  return value
end
local function wait_for(fn)
  assert(vim.wait(6000, fn, 20), 'Timed out waiting for RPC')
end

test('mention parsing excludes code and email, supports Unicode and spaces', function()
  local refs = R.parse('See @src/example.py:2 and @[src/with Ω spaces.py]:7. x@y.com `@ignored.py:1`\n```\n@skip.py\n```')
  eq(#refs, 2)
  eq(refs[1].path, 'src/example.py'); eq(refs[1].line_start, 2)
  eq(refs[2].path, 'src/with Ω spaces.py'); eq(refs[2].line_start, 7)
end)

test('references reject traversal and escaping symlinks', function()
  local path = repo('paths')
  U.mkdir(temp .. '/outside')
  assert(vim.uv.fs_symlink(temp .. '/outside', path .. '/escape'))
  assert(not P.resolve(path, '../outside/file'))
  assert(not P.resolve(path, 'escape/new.txt'))
  local full, normalized = P.resolve(path, './src\\example.py')
  eq(full, path .. '/src/example.py'); eq(normalized, 'src/example.py')
end)

test('file completion preserves spaces and Unicode from Git', function()
  local path = repo('completion')
  U.atomic(path .. '/src/Ω with spaces.py', 'value\n')
  local files = R.files(P.discover(path))
  assert(vim.tbl_contains(files, 'src/Ω with spaces.py'))
  assert(vim.tbl_contains(files, 'src/example.py'))
end)

test('snapshots preserve unsaved ranges and relocate uniquely', function()
  local path = repo('snapshots')
  local project = P.discover(path)
  local buf = vim.fn.bufadd(path .. '/src/example.py'); vim.fn.bufload(buf)
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { 'unsaved second' })
  local ref = R.capture(project, 'src/example.py', 2, 2, buf)
  eq(ref.text, 'unsaved second'); eq(ref.unsaved, true)
  local row, status = R.locate(ref, { 'inserted', 'first', 'unsaved second', 'third' })
  eq(row, 3); eq(status, 'moved')
  row, status = R.locate(ref, { 'unsaved second', 'unsaved second' })
  eq(row, nil); eq(status, 'ambiguous')
end)

test('exact selections preserve Unicode, reverse ranges and multiline boundaries', function()
  local path = repo('precise-selection')
  local buf = vim.fn.bufadd(path .. '/src/example.py'); vim.fn.bufload(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'alpha Ωmega end', 'tail text' })
  local project = P.discover(path)
  local function selection(a, b)
    return R.selection(project, 'src/example.py', buf, { buf, a[1], a[2], 0 }, { buf, b[1], b[2], 0 }, 'v')
  end
  local ref = selection({1, 7}, {1, 12})
  eq(ref.selection_text, 'Ωmega'); eq(ref.column_start, 7); eq(ref.column_end, 13)
  eq(selection({1, 12}, {1, 7}).selection_text, 'Ωmega')
  ref = selection({1, 13}, {2, 4})
  eq(ref.selection_text, ' end\ntail'); eq(ref.line_end, 2); eq(ref.column_end, 5)
  local old = vim.o.selection; vim.o.selection = 'exclusive'
  eq(selection({1, 7}, {1, 13}).selection_text, 'Ωmega')
  vim.o.selection = old
end)

test('every question receives the complete current buffer saved or unsaved', function()
  local path = repo('current-file')
  local a = app(path, 'current')
  local buf = vim.fn.bufadd(path .. '/src/example.py'); vim.fn.bufload(buf)
  local lines = {}
  for i = 1, 350 do lines[i] = 'line ' .. i end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  a:source(buf)
  local selected = a:capture(2, 2)
  local question = a:send('What does the rest of this file do?', { references = { selected } })
  wait_for(function() return not a.busy end)
  eq(question.current_file.line_end, 350); eq(question.current_file.truncated, false)
  eq(question.current_file.unsaved, true)
  assert(question.prompt:find('line 350', 1, true))
  local last = a.state.entries[#a.state.entries - 1]
  assert(U.message_text(last.message):find('line 350', 1, true))
  vim.api.nvim_buf_call(buf, function() vim.cmd('write') end)
  question = a:send('Saved now', { references = {} })
  wait_for(function() return not a.busy end)
  eq(question.current_file.unsaved, false); eq(question.current_file.line_end, 350)
  a:export(path .. '/snapshot-export.json')
  local records = U.json(path .. '/snapshot-export.json').records
  eq(records[1].current_file.line_end, 350)
  vim.api.nvim_buf_set_lines(buf, 349, 350, false, { 'latest unsaved ending' })
  question = a:send('Read the new ending', { references = {} })
  wait_for(function() return not a.busy end)
  assert(question.prompt:find('latest unsaved ending', 1, true))
  eq(question.current_file.unsaved, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { string.rep('x', 256 * 1024 + 1) })
  local count = #a.state.requests
  local ok, err = pcall(a.send, a, 'Too large', { references = {} })
  assert(not ok and tostring(err):find('question was not sent', 1, true))
  eq(#a.state.requests, count); eq(a.busy, false)
  a:close()
end)

test('agent links parse files, ranges and Markdown without linking code or websites', function()
  local refs = R.parse('See @[src/example.py]:2-3 and [helper](src/helper.py#L9), [site](https://example.com). `@[no.py]:1`')
  eq(#refs, 2); eq(refs[1].line_end, 3); eq(refs[2].path, 'src/helper.py'); eq(refs[2].line_start, 9)
end)

test('diff preview validates all files and refuses stale or escaping changes', function()
  local path = repo('patches')
  U.atomic(path .. '/other.py', 'old\n')
  local patches = require('tim.patches')
  local diff = '--- a/src/example.py\n+++ b/src/example.py\n@@ -1,3 +1,3 @@\n first\n-second\n+changed\n third\n--- a/other.py\n+++ b/other.py\n@@ -1 +1 @@\n-old\n+new'
  local plan = patches.prepare(P.discover(path), diff)
  eq(vim.api.nvim_buf_get_lines(plan[1].buf, 1, 2, false), { 'second' })
  eq(U.read(path .. '/other.py'), 'old\n')
  vim.api.nvim_buf_set_lines(plan[2].buf, 0, -1, false, { 'user edit' })
  assert(not pcall(patches.apply, plan))
  eq(vim.api.nvim_buf_get_lines(plan[1].buf, 1, 2, false), { 'second' })
  vim.api.nvim_buf_set_lines(plan[2].buf, 0, -1, false, { 'old' })
  plan = patches.prepare(P.discover(path), diff); patches.apply(plan)
  eq(vim.api.nvim_buf_get_lines(plan[1].buf, 1, 2, false), { 'changed' })
  eq(vim.api.nvim_buf_get_lines(plan[2].buf, 0, -1, false), { 'new' })
  assert(vim.bo[plan[1].buf].modified and vim.bo[plan[2].buf].modified)
  eq(U.read(path .. '/other.py'), 'old\n')
  assert(not pcall(patches.apply, plan))
  assert(not pcall(patches.prepare, P.discover(path), diff:gsub('src/example.py', '../outside.py')))
  assert(not pcall(patches.prepare, P.discover(path), diff:gsub('@@ %-1,3 %+1,3 @@', '@@ -1,4 +1,3 @@')))
  U.atomic(path .. '/empty.py', '')
  local blank = patches.prepare(P.discover(path), '--- a/empty.py\n+++ b/empty.py\n@@ -0,0 +1 @@\n+created line')
  patches.apply(blank)
  eq(vim.api.nvim_buf_get_lines(blank[1].buf, 0, -1, false), { 'created line' })
end)

test('assistant annotations anchor sent snapshots and retain resolved state', function()
  local path = repo('annotations')
  local a = app(path, 'annotations')
  local buf = vim.fn.bufadd(path .. '/src/example.py'); vim.fn.bufload(buf); a:source(buf)
  local snapshot = a:capture(nil, nil, nil, true)
  a.state.requests = { { id = 'abcd', current_file = snapshot, references = { snapshot }, thread_id = 'abcd', text = 'Review', created_at = 1, intent = 'review', comment_policy = 'explicit' } }
  a.state.entries = {
    { id = 'user', type = 'message', message = { role = 'user', content = '<!-- tim:abcd --> Review' } },
    { id = 'answer', parentId = 'user', type = 'message', message = { role = 'assistant', content = 'Comment: @[src/example.py]:2 Concern here.' } },
  }; a.state.leaf_id = 'answer'
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'inserted after sending' })
  require('tim.annotations').refresh(a)
  eq(#a.annotations, 1); eq(a.annotations[1].reference.text, 'second')
  eq(R.locate(a.annotations[1].reference, vim.api.nvim_buf_get_lines(buf, 0, -1, false)), 3)
  a.annotations[1].resolved = true; a:save(); a:close()
  local b = app(path, 'annotations'); eq(#b.annotations, 0); b:close()
end)

test('comment diffs link by file/range, follow moved anchors, and persist approval', function()
  local path = repo('comment-proposals')
  local a = app(path, 'proposals')
  local buf = vim.fn.bufadd(path .. '/src/example.py'); vim.fn.bufload(buf); a:source(buf)
  local snapshot = a:capture(nil, nil, nil, true)
  local diff = '--- a/src/example.py\n+++ b/src/example.py\n@@ -2 +2 @@\n-second\n+fixed'
  a.state.requests = { { id = 'abcd', text = 'Review', references = { snapshot }, current_file = snapshot,
    git = snapshot.git, created_at = 1, comment_policy = 'explicit' } }
  a.state.entries = {
    { id = 'user', type = 'message', message = { role = 'user', content = '<!-- tim:abcd --> Review' } },
    { id = 'review', parentId = 'user', type = 'message', message = { role = 'assistant', content =
      'Comment: @[src/example.py]:2 Fix this.\nComment: @[src/example.py]:3 Unrelated.\n```diff\n' .. diff .. '\n```' } },
  }; a.state.leaf_id = 'review'
  require('tim.annotations').refresh(a)
  eq(#a.annotations, 2)
  local target, unrelated = a.annotations[1], a.annotations[2]
  eq(#a.comment_proposals[target.id], 1); eq(a.comment_proposals[unrelated.id], nil)
  local original = a.comment_proposals[target.id][1]
  -- A later response can propose a fix after source lines have moved.
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'inserted' })
  local fresh = a:capture(nil, nil, nil, true)
  local moved = diff:gsub('@@ %-2 %+2 @@', '@@ -3 +3 @@')
  a.state.requests[2] = { id = 'dcba', text = 'Propose a solution', references = { fresh }, current_file = fresh,
    git = fresh.git, created_at = 2, comment_policy = 'none' }
  a.state.entries[3] = { id = 'followup', parentId = 'review', type = 'message', message = { role = 'user', content = '<!-- tim:dcba --> Propose a solution' } }
  a.state.entries[4] = { id = 'solution', parentId = 'followup', type = 'message', message = { role = 'assistant', content = '```diff\n' .. moved .. '\n```' } }
  a.state.leaf_id = 'solution'
  require('tim.annotations').refresh(a)
  eq(#a.annotations, 2) -- ordinary follow-up creates no new comments
  eq(#a.comment_proposals[target.id], 2); eq(a.comment_proposals[unrelated.id], nil)
  local proposal = a.comment_proposals[target.id][2]
  a.state.work[#a.state.work + 1] = { kind = 'proposal_applied', proposal_entry = original.entry_id, proposal_id = original.id }
  a.state.work[#a.state.work + 1] = { kind = 'proposal_applied', proposal_entry = proposal.entry_id, proposal_id = proposal.id }
  require('tim.annotations').refresh(a)
  eq(a.comment_proposals[target.id], nil)
  a:save(); a:close()
  local b = app(path, 'proposals')
  eq(#b.proposals, 0); eq(b.comment_proposals[target.id], nil); b:close()
  -- Unsafe paths and other files never acquire the comment's proposal link.
  eq(#require('tim.proposals').ranges(a.project, diff:gsub('src/example.py', '../escape.py')), 0)
  local insertion = require('tim.proposals').ranges(a.project, diff:gsub('@@ %-2 %+2 @@', '@@ -2,0 +3 @@'))
  eq(insertion[1].first, 2); eq(insertion[1].last, 2)
  vim.bo[buf].modified = false
end)

test('structured findings and diffs survive apply, undo, rejection and session reopen', function()
  local path = repo('structured-workflow')
  U.atomic(path .. '/example.py', 'alpha Ωmega end\ntail text\n')
  U.atomic(path .. '/helper.py', 'helper first\nboundary case\n')
  local a = app(path, 'workflow')
  local buf = vim.fn.bufadd(path .. '/example.py'); vim.fn.bufload(buf); a:source(buf)
  a:review('[structured-review]', {})
  wait_for(function() return not a.busy end)
  eq(#a.annotations, 2); eq(#a.all_proposals, 1)
  local proposal = a.all_proposals[1]
  local finding = a.state.annotations[proposal.comment_id]
  assert(finding); eq(finding.text, 'The first line needs a fix.')
  eq(require('tim.proposals').finding_status(a, finding), 'proposal ready')
  local actions = 0
  for _, item in ipairs(H.items(a.state)) do if item.editor_action then actions = actions + 1 end end
  eq(actions, 3)
  a:export(path .. '/structured-export.json')
  local exported = U.json(path .. '/structured-export.json')
  local exported_diff
  for _, record in ipairs(exported.records) do
    if record.editor_action and record.editor_action.kind == 'proposal' then exported_diff = record.editor_action.diff end
  end
  eq(exported_diff, proposal.diff)
  local status, plan = require('tim.proposals').inspect(a, proposal)
  eq(status, 'ready')
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'newer user work' })
  assert(not pcall(require('tim.work').apply, a, proposal, plan))
  eq(require('tim.proposals').inspect(a, proposal), 'outdated')
  eq(require('tim.proposals').finding_status(a, finding), 'outdated')
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'alpha Ωmega end' })
  require('tim.work').reject(a, proposal)
  eq(a.all_proposals[1].status, 'rejected')
  a:send('[structured-fix] Propose a new fix', { references = {} })
  wait_for(function() return not a.busy end)
  proposal = a.all_proposals[2]
  eq(proposal.comment_id, finding.id)
  status, plan = require('tim.proposals').inspect(a, proposal)
  eq(status, 'ready'); require('tim.work').apply(a, proposal, plan)
  eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], 'alpha fixed end')
  eq(U.read(path .. '/example.py'), 'alpha Ωmega end\ntail text\n')
  eq(a.all_proposals[2].status, 'applied')
  eq(require('tim.proposals').finding_status(a, finding), 'applied')
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { 'newer edit' })
  assert(not pcall(require('tim.work').undo, a, a.all_proposals[2]))
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { 'tail text' })
  a:save(); a:close()
  local b = app(path, 'workflow'); b:source(buf)
  eq(b.all_proposals[1].status, 'rejected'); eq(b.all_proposals[2].status, 'applied')
  require('tim.work').undo(b, b.all_proposals[2])
  eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], 'alpha Ωmega end')
  eq(b.all_proposals[2].status, 'pending')
  b:close(); vim.bo[buf].modified = false
end)

test('refreshing a structured finding preserves its identity and discussion thread', function()
  local path = repo('refresh-finding')
  local a = app(path, 'refresh')
  local buf = vim.fn.bufadd(path .. '/src/example.py'); vim.fn.bufload(buf); a:source(buf)
  local snapshot = a:capture(nil, nil, nil, true)
  a.state.requests = { { id = 'abcd', text = 'Review', current_file = snapshot, references = { snapshot }, thread_id = 'discussion', created_at = 1 } }
  a.state.entries = {
    { id = 'user', type = 'message', message = { role = 'user', content = '<!-- tim:abcd --> Review' } },
    { id = 'first', parentId = 'user', type = 'message', message = { role = 'toolResult', toolName = 'editor_comment', toolCallId = 'finding',
      details = { tim = { version = 1, id = 'finding', kind = 'comment', path = 'src/example.py', line_start = 2, body = 'Old finding' } } } },
  }; a.state.leaf_id = 'first'
  require('tim.annotations').refresh(a)
  a.state.annotations.finding.resolved = true
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'inserted' })
  local fresh = a:capture(nil, nil, nil, true)
  a.state.requests[2] = { id = 'dcba', text = 'Refresh', current_file = fresh, references = { fresh }, thread_id = 'new-request', created_at = 2 }
  a.state.entries[3] = { id = 'user2', parentId = 'first', type = 'message', message = { role = 'user', content = '<!-- tim:dcba --> Refresh' } }
  a.state.entries[4] = { id = 'update', parentId = 'user2', type = 'message', message = { role = 'toolResult', toolName = 'editor_comment', toolCallId = 'refresh',
    details = { tim = { version = 1, id = 'refresh', kind = 'comment', comment_id = 'finding', path = 'src/example.py', line_start = 3, body = 'Updated finding' } } } }
  a.state.leaf_id = 'update'; require('tim.annotations').refresh(a)
  eq(#a.findings, 1); eq(a.findings[1].id, 'finding'); eq(a.findings[1].reference.line_start, 3)
  eq(a.findings[1].thread_id, 'discussion'); eq(a.findings[1].text, 'Updated finding'); eq(a.findings[1].resolved, nil)
  a.findings[1].resolved = true
  require('tim.annotations').refresh(a); eq(a.findings[1].resolved, true) -- replay does not undo the user's decision
  a:close(); vim.bo[buf].modified = false
end)

test('Cancel during connection prevents a later prompt and preserves input', function()
  local a = app(repo('cancel-connecting'), 'cancel')
  local callback, prompts = nil, 0
  a.client = { request = function(_, kind, _, cb)
    if kind == 'get_state' then callback = cb elseif kind == 'prompt' then prompts = prompts + 1 end
  end, close = function() return true end }
  a.state.draft.text = 'Keep this question'
  local request = a:send(a.state.draft.text)
  a:stop()
  callback({ isStreaming = false })
  eq(prompts, 0); eq(request.status, 'cancelled'); eq(a.busy, false)
  eq(a.state.draft.text, 'Keep this question'); a:close()
end)

test('editor actions reject spoofed tool results and invalid metadata', function()
  local decode = require('tim.actions').decode
  local message = { role = 'toolResult', toolName = 'read', toolCallId = 'id',
    details = { tim = { version = 1, id = 'id', kind = 'comment', path = 'file.py', line_start = 1, body = 'Fake' } } }
  eq(decode(message), nil)
  message.toolName = 'editor_comment'; message.isError = true; eq(decode(message), nil)
  message.isError = false; message.details.tim.id = 'mismatch'; eq(decode(message), nil)
  message.details.tim.id = 'id'; message.details.tim.line_start = 1.5; eq(decode(message), nil)
  message.details.tim.line_start = 1; assert(decode(message))
end)

test('Review defaults to selected code or whole file, accepts other tasks, and preserves chat', function()
  local path = repo('review-action')
  local a = app(path, 'review')
  local buf = vim.fn.bufadd(path .. '/src/example.py'); vim.fn.bufload(buf); a:source(buf)
  a.state.draft.text = 'An unsent chat message'
  local ordinary = a:send('Explain this file', { references = {} })
  wait_for(function() return not a.busy end)
  eq(ordinary.comment_policy, 'none'); eq(#a.annotations, 0)
  local request = a:review('', {})
  wait_for(function() return not a.busy end)
  eq(request.text, 'Review this file.'); eq(request.scope, 'file'); eq(request.intent, 'review')
  eq(request.current_file.line_end, 3); eq(#a.annotations, 1)
  eq(a.annotations[1].request_id, request.id)
  eq(a.state.draft.text, 'An unsent chat message')
  local ref = a:capture(2, 2)
  request = a:review('', { ref })
  wait_for(function() return not a.busy end)
  eq(request.text, 'Review the selected code.'); eq(request.scope, 'selection')
  eq(request.references[1].line_start, 2); eq(request.references[1].line_end, 2)
  request = a:review('Explain the control flow instead', { ref })
  wait_for(function() return not a.busy end)
  eq(request.text, 'Explain the control flow instead')
  assert(request.prompt:find('rather than a review', 1, true))
  local count = #a.state.requests
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { 'changed selection' })
  assert(not pcall(a.review, a, '', { ref }))
  eq(#a.state.requests, count)
  a:close()
end)

test('Review only turns explicit findings into comments, leaving citations as links', function()
  local path = repo('explicit-comments')
  local a = app(path, 'review')
  a.state.requests = { { id = 'abcd', text = 'Explain or review', comment_policy = 'explicit', intent = 'review', created_at = 1 } }
  a.state.entries = {
    { id = 'user', type = 'message', message = { role = 'user', content = '<!-- tim:abcd --> Explain' } },
    { id = 'answer', parentId = 'user', type = 'message', message = { role = 'assistant', content = 'See @[src/example.py]:1.\nComment: @[src/example.py]:2 Check this assumption.' } },
  }; a.state.leaf_id = 'answer'
  require('tim.annotations').refresh(a)
  eq(#a.annotations, 1); eq(a.annotations[1].reference.line_start, 2)
  eq(a.annotations[1].instruction, 'Explain or review')
  a.state.annotations = {}; a.state.requests[1].comment_policy = 'none'
  require('tim.annotations').refresh(a)
  eq(#a.annotations, 0)
  a:close()
end)

test('named sessions, default resume and concurrent writer exclusion', function()
  local path = repo('sessions')
  local a = app(path, 'two words / are labels'); local id = a.state.id
  assert(not pcall(app, path, 'two words / are labels'))
  a:close()
  local b = app(path, 'other'); b:close()
  local again = app(path, 'two words / are labels'); eq(again.state.id, id); again:close()
  local latest = app(path); eq(latest.state.id, id); latest:close()
end)

test('default selection is durable and independent of newer activity', function()
  local path = repo('default')
  assert(not pcall(app, path)) -- no automatically named session
  local old = app(path, 'older')
  local chosen = app(path, 'work'); local id = chosen.state.id; chosen:close()
  old:comment('Newer activity must not change the default', { R.capture(old.project, 'src/example.py', 1, 1) })
  old:close()
  local resumed = app(path); eq(resumed.state.id, id); resumed:close()
end)

test('automatic Git provenance spans branch changes without rebinding', function()
  local path = repo('branches')
  local a = app(path, 'independent')
  local first = a:comment('main note', { R.capture(a.project, 'src/example.py', 1, 1) })
  assert(U.run({ 'git', '-C', path, 'switch', '-c', 'feature' }))
  local second = a:comment('feature note', { R.capture(a.project, 'src/example.py', 2, 2) })
  eq(first.git.branch, 'main'); eq(second.git.branch, 'feature'); eq(first.git.head, second.git.head)
  eq(#a.state.notes, 2); assert(not a.client)
  a:close()
end)

test('local comments persist offline and exact-path filtering does not match basenames', function()
  local path = repo('comments')
  local a = app(path, 'comments')
  a:comment('A note', { R.capture(a.project, 'src/example.py', 1, 1) })
  a:close()
  local resumed = app(path, 'comments')
  eq(#resumed.state.notes, 1)
  eq(#H.filter(H.items(resumed.state), 'example.py'), 0)
  eq(#H.filter(H.items(resumed.state), 'src/example.py'), 1)
  resumed:close()
end)

test('streaming RPC preserves fragmented JSON and Unicode; persisted answers resume', function()
  local path = repo('rpc')
  local a = app(path, 'rpc')
  a.state.draft.text = 'Explain @src/example.py:2 [retry]'
  a:send(a.state.draft.text)
  a:export(path .. '/before.json')
  local initial_event_id = U.json(path .. '/before.json').records[1].event_id
  wait_for(function() return not a.busy end)
  eq(a.state.requests[1].status, 'completed')
  eq(a.state.draft.text, '')
  local items = H.items(a.state)
  eq(#items, 2)
  assert(items[2].text:find('Ω', 1, true))
  assert(items[2].text:find('\226\128\168tail', 1, true))
  eq(items[1].references[1].line_start, 2)
  eq(items[1].thread_id, items[2].thread_id)
  a:export(path .. '/after.json')
  eq(U.json(path .. '/after.json').records[1].event_id, initial_event_id)
  local session_path = a.state.pi_session
  a:close()
  local b = app(path, 'rpc')
  eq(b.state.pi_session, session_path); eq(#H.items(b.state), 2)
  b:close()
end)

test('rejected prompts retain drafts and cancellation settles explicitly', function()
  local a = app(repo('reject'), 'reject')
  a.state.draft.text = '[reject] question'
  a:send(a.state.draft.text)
  wait_for(function() return not a.busy end)
  eq(a.state.requests[1].status, 'failed'); eq(a.state.draft.text, '[reject] question')
  a.state.draft.text = '[slow] question'
  a:send(a.state.draft.text)
  wait_for(function() return a.state.requests[2].status == 'running' end)
  a:stop()
  wait_for(function() return not a.busy end)
  eq(a.state.requests[2].status, 'cancelled')
  a:close()
end)

test('crash after durable acceptance is uncertain and never automatically resent', function()
  local path = repo('crash')
  local a = app(path, 'crash')
  a.state.draft.text = '[crash] question'
  a:send(a.state.draft.text)
  wait_for(function() return not a.busy end)
  eq(a.state.requests[1].status, 'uncertain')
  a:close()
  local b = app(path, 'crash')
  eq(#b.state.entries, 1); eq(#b.state.requests, 1); assert(not b.client)
  eq(#H.items(b.state), 1)
  b:close()
end)

test('history follows the Pi active branch rather than mixing alternatives', function()
  local state = { notes = {}, requests = { { id = 'abcd', text = 'abandoned question', created_at = 1 } }, imports = {}, leaf_id = 'c', entries = {
    { id = 'a', type = 'message', message = { role = 'user', content = 'question' } },
    { id = 'b', parentId = 'a', type = 'message', message = { role = 'assistant', content = 'abandoned' } },
    { id = 'c', parentId = 'a', type = 'message', message = { role = 'assistant', content = 'active' } },
    { id = 'd', parentId = 'a', type = 'message', message = { role = 'user', content = '<!-- tim:abcd --> abandoned question' } },
  } }
  local items = H.items(state); eq(#items, 2); eq(items[2].text, 'active')
end)

test('provider failure settles as failed and newer draft text survives acceptance', function()
  local a = app(repo('provider-error'), 'error')
  a.state.draft.text = '[error] first question'
  a:send(a.state.draft.text)
  a.state.draft.text = 'A newer draft while Pi connects'
  wait_for(function() return not a.busy end)
  eq(a.state.requests[1].status, 'failed')
  eq(a.state.draft.text, 'A newer draft while Pi connects')
  a:close()
end)

test('non-Git work stays independent and corrupt metadata is preserved', function()
  local path = temp .. '/plain-directory'; U.mkdir(path)
  local a = app(path, 'plain')
  eq(a.state.git.is_git, false)
  local state_path = a.handle.path
  a:close()
  U.atomic(state_path, '{broken')
  assert(not pcall(app, path, 'plain'))
  eq(U.read(state_path), '{broken')
end)

test('branch filter selects by observed usage without locking a session to Git', function()
  local path = repo('branch-filter')
  local a = app(path, 'main work'); a:close()
  assert(U.run({ 'git', '-C', path, 'switch', '-c', 'feature' }))
  local b = app(path, 'feature work'); b:close()
  assert(U.run({ 'git', '-C', path, 'switch', 'main' }))
  local selected = App.new({ root = path, data_dir = temp .. '/data', branch_filter = true })
  eq(selected.state.name, 'main work'); selected:close()
end)

test('worktrees have separate sessions and a shared repository identity', function()
  local path = repo('worktree-primary')
  local secondary = temp .. '/worktree-secondary'
  assert(U.run({ 'git', '-C', path, 'worktree', 'add', '-b', 'secondary', secondary }))
  local left, right = app(path, 'same name'), app(secondary, 'same name')
  assert(left.state.id ~= right.state.id)
  assert(left.project.worktree_id ~= right.project.worktree_id)
  eq(left.project.repository_id, right.project.repository_id)
  left:close(); right:close()
end)

test('dirty buffers retain original provenance across an external branch switch', function()
  local path = repo('dirty-switch')
  local a = app(path, 'cross-branch')
  local buf = vim.fn.bufadd(path .. '/src/example.py'); vim.fn.bufload(buf)
  a:source(buf)
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { 'unsaved change on main' })
  assert(U.run({ 'git', '-C', path, 'switch', '-c', 'next-branch' }))
  a:context()
  local ref = a:capture(2, 2)
  eq(ref.git.branch, 'main'); eq(ref.observed_git.branch, 'next-branch')
  eq(ref.stale_checkout, true); eq(ref.text, 'unsaved change on main')
  a:close()
end)

test('TicketBunker discovery and idempotent imports do not require a ticket session', function()
  local path = repo('ticket-context')
  U.write_json(path .. '/.tb/QA-1_bunker/ticket.json', { id = 'QA-1', title = 'Optional context', assigned_branches = { 'main' } })
  local a = app(path, 'independent')
  eq(a.state.ticketbunker.tickets[1].id, 'QA-1')
  local source = path .. '/history.jsonl'
  local body = vim.json.encode({ role = 'user', category = 'file', scope = 'main', path = 'src/example.py', text = 'Old question', reference = {
    kind = 'source', category = 'file', scope = 'main', branch = 'main', path = 'src/example.py', line_start = 2, line_end = 2, text = 'second', unsaved = false,
  } }) .. '\n'
  U.atomic(source, body)
  eq(a:import(source), 1); eq(a:import(source), 0); eq(U.read(source), body)
  a:export(path .. '/export.json')
  local export = U.json(path .. '/export.json'); eq(export.origin, 'tim'); eq(export.records[1].references[1].path, 'src/example.py')
  eq(export.records[1].actor_role, 'user')
  assert(export.records[1].event_id:find(a.state.id, 1, true) == 1)
  a:export(path .. '/export-again.json')
  eq(U.json(path .. '/export-again.json').records[1].event_id, export.records[1].event_id)
  a:close()
end)

test('Neovim UI creates separate buffers, comments, markers and source navigation', function()
  local path = repo('ui')
  vim.cmd('edit ' .. vim.fn.fnameescape(path .. '/src/example.py'))
  local tim = require('tim')
  tim.setup({ root = path, data_dir = temp .. '/ui-data', name = 'Editor', pi_command = { 'python3', root .. '/tests/fake_pi.py' } })
  vim.cmd('2TimComment Explain this line')
  eq(#tim.app.state.notes, 1)
  tim.ui:render()
  assert(vim.api.nvim_buf_is_valid(tim.ui.transcript))
  local marks = vim.api.nvim_buf_get_extmarks(tim.app.source_buf, require('tim.ui').namespace, 0, -1, {})
  eq(#marks, 1); eq(marks[1][2], 1)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd('TimThread')
  eq(tim.app.thread, tim.app.state.notes[1].thread_id)
  tim.ui:open_reference({ path = 'src/example.py', line_start = 2 })
  tim.app.thread = nil
  vim.cmd('2TimAsk')
  assert(tim.ui.draft ~= tim.ui.transcript)
  vim.api.nvim_buf_set_lines(tim.ui.draft, 0, -1, false, { 'Explain the selection' })
  tim.ui:flush_draft()
  tim.submit_draft()
  wait_for(function() return not tim.app.busy end)
  eq(tim.app.state.requests[1].status, 'completed')
  tim.ui:open_reference({ path = 'src/example.py', line_start = 2 })
  eq(vim.api.nvim_win_get_cursor(0)[1], 2)
  local original_session = tim.app.state.id
  vim.cmd('TimSession Another session')
  assert(tim.app.state.id ~= original_session)
  eq(tim.app.source_path, 'src/example.py')
  vim.cmd('TimSession Editor')
  eq(tim.app.state.id, original_session)
  tim.ui:open_reference({ path = 'src/example.py', line_start = 2 })
  vim.cmd('TimComment')
  vim.api.nvim_buf_set_lines(tim.ui.draft, 0, -1, false, { 'local-only followup' })
  tim.submit_draft('comment')
  eq(tim.app.state.draft.mode, 'ask')
  tim.ui:compose('comment', tim.app:capture(2, 2))
  local requests = #tim.app.state.requests
  vim.api.nvim_buf_set_lines(tim.ui.draft, 0, -1, false, { 'another local note' })
  tim.submit_draft('comment')
  eq(#tim.app.state.requests, requests)
  tim.ui:open_reference({ path = 'src/example.py', line_start = 2 })
  local old_tabs = #vim.api.nvim_list_tabpages()
  vim.cmd('Tim')
  eq(tim.app.source_path, 'src/example.py')
  eq(#vim.api.nvim_tabpage_list_wins(0), 2)
  eq(#vim.api.nvim_list_tabpages(), old_tabs + 1)
  vim.cmd('tabclose')
  tim.ui:destroy(); tim.close()
end)

test('new proposals are visible, history reading stays put, and empty replies report failure', function()
  local path = repo('visible-feedback')
  vim.cmd('edit ' .. vim.fn.fnameescape(path .. '/src/example.py'))
  local tim = require('tim')
  tim.setup({ root = path, data_dir = temp .. '/feedback-data', name = 'feedback',
    pi_command = { 'python3', root .. '/tests/fake_pi.py' } })
  tim.ensure(); tim.ui:show(false, false)
  local ref = tim.app:capture(1, 1)
  for i = 1, 30 do tim.app:comment('Earlier note ' .. i, { ref }) end
  tim.ui:render()
  local chat = vim.fn.bufwinid(tim.ui.transcript)
  vim.api.nvim_set_current_win(chat); vim.api.nvim_win_set_cursor(chat, { 1, 0 })
  tim.app:comment('Another note', { ref }); tim.ui:render()
  eq(vim.api.nvim_win_get_cursor(chat)[1], 1) -- do not move while reading history
  tim.ui:return_to_source()
  tim.app.thread = 'old-unrelated-thread'
  local request = tim.app:send('[workspace-review] propose a fix', { references = {} })
  wait_for(function() return not tim.app.busy end)
  tim.ui:render()
  eq(tim.app.thread, nil)
  eq(tim.app.status, '1 proposal · preview to apply')
  eq(vim.api.nvim_win_get_cursor(chat)[1], vim.api.nvim_buf_line_count(tim.ui.transcript))
  local proposal
  for row in pairs(tim.ui.actions) do proposal = row end
  assert(proposal)
  assert(vim.api.nvim_win_call(chat, function() return proposal >= vim.fn.line('w0') and proposal <= vim.fn.line('w$') end))
  tim.app.filter = 'file'; tim.app.thread = 'other-thread'
  TimAgentControl(8)
  eq(tim.app.thread, request.id)
  assert(#tim.app:items() >= 2) -- status opens the latest exchange even outside its file/thread
  tim.app.state.draft.mode = 'comment'
  vim.api.nvim_buf_set_lines(tim.ui.draft, 0, -1, false, { '[empty]' })
  local notes = #tim.app.state.notes
  tim.submit_draft()
  request = tim.app.state.requests[#tim.app.state.requests]
  eq(#tim.app.state.notes, notes)
  eq(request.text, '[empty]')
  wait_for(function() return not tim.app.busy end)
  tim.ui:render()
  eq(request.status, 'failed')
  assert(request.error:find('without a text reply', 1, true))
  local text = table.concat(vim.api.nvim_buf_get_lines(tim.ui.transcript, 0, -1, false), '\n')
  assert(text:find(request.error, 1, true)) -- errors survive Pi's persisted user-message projection
  tim.ui:destroy(); tim.close()
end)

test('agent selection controls avoid cursor attachment and reject stale line choices', function()
  local path = repo('selection-controls')
  vim.cmd('edit ' .. vim.fn.fnameescape(path .. '/src/example.py'))
  local tim = require('tim')
  tim.setup({ root = path, data_dir = temp .. '/controls-data', name = 'controls' })
  tim.ensure(); tim.ui:show(false, false)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  tim.focus_input()
  eq(#tim.app.state.draft.references, 0)
  vim.api.nvim_buf_set_lines(tim.ui.draft, 0, -1, false, { 'An unsent message' })
  tim.ui:flush_draft(); tim.ui:return_to_source()
  local picker = tim.ui.selection
  picker:picker(); picker:click(3, 2); picker:click(5, 2); picker:click(1, 2)
  eq(#tim.app.state.draft.references, 2)
  eq(tim.app.state.draft.references[1].line_start, 1)
  eq(tim.app.state.draft.references[2].line_start, 3)
  picker:picker()
  vim.api.nvim_buf_set_lines(tim.app.source_buf, 0, 1, false, { 'changed while selecting' })
  picker:click(4, 2); picker:click(1, 2)
  eq(#tim.app.state.draft.references, 2)
  assert(vim.api.nvim_win_is_valid(picker.win)) -- stale selection is not applied
  picker:close()
  tim.ui:set_selection({})
  tim.ui:hide()
  eq(#vim.api.nvim_list_wins(), 1)
  tim.ui:toggle()
  eq(#vim.api.nvim_list_wins(), 3)
  eq(tim.app.state.draft.text, 'An unsent message')
  tim.ui:compose('comment')
  eq(picker.kind, 'picker'); eq(picker.after, 'comment')
  picker:click(4, 2); picker:click(1, 2)
  eq(tim.app.state.draft.mode, 'ask')
  eq(tim.app.state.draft.references[1].line_start, 2)
  tim.ui:destroy(); tim.close()
  vim.bo.modified = false
end)

test('lowercase commands send literal questions and save selected-line comments', function()
  local path = repo('lowercase')
  vim.cmd('edit ' .. vim.fn.fnameescape(path .. '/src/example.py'))
  local tim = require('tim')
  tim.setup({ root = path, data_dir = temp .. '/lowercase-data', name = 'work',
    pi_command = { 'python3', root .. '/tests/fake_pi.py' } })
  local function type_command(cmd)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(':' .. cmd .. '<CR>', true, false, true), 'xt', false)
  end
  type_command('2,3comment ask about this | keep literal')
  eq(tim.app.state.notes[1].text, 'ask about this | keep literal')
  eq(tim.app.state.notes[1].references[1].line_start, 2)
  eq(tim.app.state.notes[1].references[1].line_end, 3)
  eq(tim.app.client, nil)
  vim.api.nvim_buf_set_lines(tim.ui.draft, 0, -1, false, { 'An unrelated unfinished draft' })
  tim.ui:flush_draft()
  type_command('ask Why comment here | explain?<Left><Left>')
  wait_for(function() return not tim.app.busy end)
  eq(tim.app.state.requests[1].text, 'Why comment here | explain?')
  eq(tim.app.state.requests[1].status, 'completed')
  eq(tim.app.state.draft.text, 'An unrelated unfinished draft')
  vim.cmd('normal! V')
  vim.cmd('normal! ' .. vim.api.nvim_replace_termcodes('<Esc>', true, false, true))
  vim.api.nvim_buf_set_mark(tim.app.source_buf, '<', 1, 0, {})
  vim.api.nvim_buf_set_mark(tim.app.source_buf, '>', 2, 0, {})
  type_command("'<,'>comment selection")
  eq(tim.app.state.notes[2].references[1].line_end, 2)
  type_command('ask')
  assert(tim.ui.draft and vim.api.nvim_get_current_buf() == tim.ui.draft)
  tim.ui:destroy(); tim.close()
end)

test('missing default prompts for a name and cancellation leaves the file open', function()
  local path = repo('prompt')
  vim.cmd('edit ' .. vim.fn.fnameescape(path .. '/src/example.py'))
  local tim = require('tim')
  tim.opts = { root = path, data_dir = temp .. '/prompt-data' }
  local original = vim.ui.input
  local callback, ran
  vim.ui.input = function(opts, cb) eq(opts.prompt, 'Name this session: '); callback = cb end
  tim.with_session(function() ran = true end)
  eq(tim.app, nil); callback(nil)
  eq(ran, nil); eq(tim.app, nil)
  eq(vim.api.nvim_buf_get_name(0), path .. '/src/example.py')
  tim.with_session(function() ran = true end); callback('work')
  eq(ran, true); eq(tim.app.state.name, 'work')
  local id = tim.app.state.id
  tim.ui:destroy(); tim.close(); tim.opts.name = nil
  vim.ui.input = function() error('Unexpected repeat prompt') end
  tim.with_session(function() eq(tim.app.state.id, id) end)
  vim.ui.input = original
  tim.ui:destroy(); tim.close()
end)

test('launcher persists defaults, prompts on first launch and supports non-Git files', function()
  local path = repo('launcher')
  local capture = path .. '/launch.json'
  local probe = path .. '/probe.lua'
  U.atomic(probe, [[
local prompted = false
vim.ui.input = function(_, cb) prompted = true; cb('first session') end
vim.api.nvim_create_autocmd('VimEnter', { once = true, callback = function()
  vim.defer_fn(function()
    local tim = require('tim')
    local result = { name = tim.app.state.name, source = tim.app.source_path,
      input_focused = vim.api.nvim_get_current_buf() == tim.ui.draft,
      prompted = prompted, windows = #vim.api.nvim_list_wins(), pi_started = tim.app.client ~= nil }
    require('tim.util').write_json(vim.env.TIM_LAUNCH_CAPTURE, result)
    vim.cmd('qa!')
  end, 250)
end })
]])
  local wrapper = path .. '/nvim-test'
  U.atomic(wrapper, '#!/bin/sh\nexec "$TIM_REAL_NVIM" --headless -i NONE --cmd "luafile $TIM_LAUNCH_PROBE" "$@"\n')
  assert(vim.uv.fs_chmod(wrapper, 448))
  local name = 'quoted "name" $(not-a-command)'
  local launcher = path .. '/tim-link'
  assert(vim.uv.fs_symlink(root .. '/bin/tim', launcher))
  local launch_opts = {
    cwd = path, text = true, env = { TIM_NVIM = wrapper, TIM_REAL_NVIM = vim.v.progpath,
      TIM_LAUNCH_PROBE = probe, TIM_LAUNCH_CAPTURE = capture, TIM_DATA_DIR = path .. '/data',
      XDG_STATE_HOME = path .. '/xdg-state', XDG_CACHE_HOME = path .. '/xdg-cache', XDG_DATA_HOME = path .. '/xdg-data',
    },
  }
  local proc = vim.system({ launcher, '-s', name }, launch_opts):wait(10000)
  assert(proc.code == 0, proc.stderr)
  eq(U.json(capture).prompted, false)
  eq(U.json(capture).input_focused, true)
  proc = vim.system({ launcher, 'src/example.py' }, launch_opts):wait(10000)
  assert(proc.code == 0, proc.stderr)
  local result = U.json(capture)
  eq(result.name, name); eq(result.source, 'src/example.py'); eq(result.windows, 3); eq(result.pi_started, false); eq(result.input_focused, false)
  eq(result.prompted, false)
  local plain = temp .. '/plain-launch'
  U.mkdir(plain .. '/nested')
  U.atomic(plain .. '/nested/file.txt', 'plain text\n')
  launch_opts.cwd = plain
  proc = vim.system({ launcher }, launch_opts):wait(10000)
  assert(proc.code == 0, proc.stderr)
  eq(U.json(capture).prompted, true); eq(U.json(capture).name, 'first session')
  proc = vim.system({ launcher, 'nested/file.txt' }, launch_opts):wait(10000)
  assert(proc.code == 0, proc.stderr)
  result = U.json(capture)
  eq(result.prompted, false); eq(result.name, 'first session'); eq(result.source, 'nested/file.txt')

end)

for _, a in ipairs(apps) do pcall(function() a:close() end) end
print(string.format('\n%d passed, %d failed. Fixtures: %s', passed, failed, temp))
if failed > 0 then vim.cmd('cquit 1') else vim.cmd('qa!') end
