-- Derived links from pending unified diffs to the review comments they address.
local U = require('tim.util')
local R = require('tim.references')
local P = require('tim.project')
local M = {}

-- Repeat this on each turn so follow-ups and compacted sessions retain the UI contract.
M.instructions = table.concat({
  'Tim editor actions:',
  'Use editor_comment to publish findings, not special prose or Comment: markers. During Review, publish concrete findings; in chat, only leave a finding when requested or when attaching a proposed fix.',
  'Use editor_propose_diff to publish actual fixes in the Diffs view, not code snippets or promises in chat. Pass the comment_id returned by editor_comment or supplied below to keep the finding and fix together.',
  'Use exact context from the latest supplied buffer, complete unified diffs with --- a/path and +++ b/path headers, and valid hunk counts. Existing text files only. One tool call per independently applicable fix.',
  'For a refreshed finding, pass its existing comment_id to editor_comment. Explain if the issue no longer exists rather than inventing changes.',
  'These tools only publish review data. Tim validates proposals, marks outdated context, and requires explicit human approval to apply changes. Never claim source was edited or saved.',
}, '\n')

function M.id(entry, diff) return entry .. ':' .. vim.fn.sha256(diff) end

-- This only reads locations for navigation. Applying still uses patches.prepare.
function M.ranges(project, diff)
  local result, path = {}, nil
  local lines = U.lines(diff)
  for i, line in ipairs(lines) do
    if line:match('^%-%-%- ') then
      local old = line:match('^%-%-%- a/(.+)$')
      local new = (lines[i + 1] or ''):match('^%+%+%+ b/(.+)$')
      path = nil
      if old and old == new then
        local full, relative = P.resolve(project.root, old)
        if full then path = relative end
      end
    elseif path then
      local first, count = line:match('^@@ %-(%d+),?(%d*) %+')
      if first then
        first, count = tonumber(first), tonumber(count) or 1
        result[#result + 1] = { path = path, first = math.max(1, first), last = math.max(1, first + math.max(1, count) - 1) }
      end
    end
  end
  return result
end

function M.refresh(app, items)
  local states, order = {}, {}
  for _, work in ipairs(app.state.work or {}) do
    local status = ({ proposal_applied = 'applied', proposal_rejected = 'rejected', proposal_undone = 'pending' })[work.kind]
    if status then states[work.proposal_id or work.proposal_entry] = status end
  end
  app.proposals, app.all_proposals, app.comment_proposals = {}, {}, {}
  for i, item in ipairs(items) do order[item.id] = i end
  for i, item in ipairs(items) do
    if item.role == 'assistant' then
      local action = item.editor_action
      local diffs = action and (action.kind == 'proposal' and { action.diff } or {}) or require('tim.patches').extract(item.text)
      for _, diff in ipairs(diffs) do
        local id = action and ('tool:' .. action.id) or M.id(item.id, diff)
        local proposal = { id = id, entry_id = item.id, diff = diff, ranges = M.ranges(app.project, diff),
          title = action and action.title or item.instruction or 'Proposed changes', request_id = item.request_id,
          comment_id = action and action.comment_id, git = item.git, current_file = item.current_file,
          references = item.references, status = states[id] or states[item.id] or 'pending' }
        app.all_proposals[#app.all_proposals + 1] = proposal
        if proposal.status == 'pending' then app.proposals[#app.proposals + 1] = proposal end
        for _, note in ipairs(app.findings or app.annotations or {}) do
          local ref, row = note.reference, nil
          local match = proposal.comment_id == note.id
          if not proposal.comment_id and (order[note.entry_id] or math.huge) <= i
              and (ref.git or {}).branch == (item.git or {}).branch then
            local sources = { item.current_file or {} }; vim.list_extend(sources, item.references or {})
            for _, source in ipairs(sources) do
              if source.path == ref.path and source.text and source.line_start then
                local located = R.locate(ref, U.lines(source.text))
                if located then row = source.line_start + located - 1; break end
              end
            end
            if not row and note.entry_id == item.id then row = ref.line_start end
            for _, range in ipairs(proposal.ranges) do
              if row and range.path == ref.path and row <= range.last and row + (ref.line_end or ref.line_start) - ref.line_start >= range.first then match = true; break end
            end
          end
          if match then
            proposal.comment_id = proposal.comment_id or note.id
            if proposal.status == 'pending' and not note.resolved then
              app.comment_proposals[note.id] = app.comment_proposals[note.id] or {}
              table.insert(app.comment_proposals[note.id], proposal)
            end
          end
        end
      end
    end
  end
end

function M.inspect(app, proposal)
  if proposal.status ~= 'pending' then return proposal.status end
  if (proposal.git or {}).branch ~= (app.state.git or {}).branch then return 'outdated', 'This proposal belongs to another branch.' end
  local ok, files = pcall(require('tim.patches').prepare, app.project, proposal.diff)
  if not ok then return 'outdated', tostring(files) end
  return 'ready', files
end

function M.finding_status(app, note)
  if note.resolved then return 'resolved' end
  for _, proposal in ipairs(app.all_proposals or {}) do
    if proposal.comment_id == note.id and proposal.status == 'applied' then return 'applied' end
  end
  local ok, snapshot = pcall(R.capture, app.project, note.reference.path, nil, nil, nil, { full = true })
  if not ok or not R.locate(note.reference, U.lines(snapshot.text))
      or (note.reference.git or {}).branch ~= (app.state.git or {}).branch then return 'outdated' end
  local applied = false
  for _, proposal in ipairs(app.all_proposals or {}) do
    if proposal.comment_id == note.id then
      local status = M.inspect(app, proposal)
      if status == 'ready' then return 'proposal ready' end
      if status == 'applied' then applied = true end
    end
  end
  return applied and 'applied' or 'open'
end
return M
