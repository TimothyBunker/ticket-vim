local U = require('tim.util')
local P = require('tim.project')
local S = require('tim.store')
local R = require('tim.references')
local H = require('tim.history')
local TB = require('tim.ticketbunker')
local M = {}
M.__index = M

function M.new(opts)
  local project = P.discover(opts.root or vim.fn.getcwd())
  local handle = S.open(project, opts)
  local self = setmetatable({ opts = opts, project = project, handle = handle, state = handle.state,
    status = 'Ready', stream = '', busy = false, filter = 'file', source_buf = nil, buffers = {},
  }, M)
  local ok, err = pcall(function()
    local entries, leaf = S.read_pi(self.state.pi_session)
    if #entries > 0 then self.state.entries = entries; self.state.leaf_id = leaf end
    for _, request in ipairs(self.state.requests) do
      if request.status == 'running' or request.status == 'sending' or request.status == 'cancelling' then
        request.status = 'uncertain'
      end
    end
    self.state.draft.mode = 'ask' -- old comment drafts are never silently saved instead of sent
    self.state.ticketbunker = TB.discover(project.root, self.state.git)
    require('tim.annotations').refresh(self)
    S.save(handle)
  end)
  if not ok then handle.release(); error(err) end
  return self
end

function M:save()
  if not self.closed then S.save(self.handle) end
end

function M:changed()
  if self.on_change and not self.closed then self.on_change() end
end

function M:context()
  local git = P.context(self.project)
  self.state.git = git
  self.state.ticketbunker = TB.discover(self.project.root, git)
  return git
end

function M:source(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= '' then return end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' then return end -- temporary split/tab buffers do not change context
  local path = P.relative(self.project.root, name)
  if not path then
    self.source_buf = nil; self.source_path = nil
    self.source_error = 'Current file is outside this session folder; open it with tim from its folder before asking'
    return
  end
  self.source_error = nil
  self.source_buf = buf; self.source_path = path
  if not self.buffers[buf] then self.buffers[buf] = { git = vim.deepcopy(self.state.git), path = path } end
end

function M:capture(first, last, selection, full)
  assert(self.source_buf and vim.api.nvim_buf_is_valid(self.source_buf), 'Open a file first')
  local ref
  if selection then
    ref = R.selection(self.project, self.source_path, self.source_buf, selection.first, selection.last, selection.mode)
  elseif full then
    ref = R.capture(self.project, self.source_path, nil, nil, self.source_buf, { full = true })
  else
    ref = R.capture(self.project, self.source_path, first or 1, last or first or 1, self.source_buf)
  end
  local base = (self.buffers[self.source_buf] or {}).git
  if base and ref.unsaved and (base.ref ~= ref.git.ref or base.head ~= ref.git.head) then
    ref.observed_git = ref.git
    ref.git = vim.deepcopy(base)
    ref.stale_checkout = true
    U.notify('This buffer predates the checkout change; attaching its original Git context', vim.log.levels.WARN)
  end
  return ref
end

function M:attach(ref)
  local refs = self.state.draft.references
  for index, previous in ipairs(refs) do
    if previous.path == ref.path and previous.line_start == ref.line_start and previous.line_end == ref.line_end and previous.column_start == ref.column_start and previous.column_end == ref.column_end then
      refs[index] = ref; self:save(); self:changed(); return
    end
  end
  refs[#refs + 1] = ref
  self:save(); self:changed()
end

function M:comment(text, references, thread)
  assert(vim.trim(text) ~= '', 'Write a comment first')
  assert(#references > 0, 'A line comment needs a source reference')
  local note = { id = U.id(), text = text, references = vim.deepcopy(references),
    git = self:context(), created_at = U.now(), role = 'user' }
  note.thread_id = thread or note.id
  self.state.notes[#self.state.notes + 1] = note
  S.touch(self.state, note.git)
  self:save(); self:changed()
  return note
end

function M:items(all_sessions)
  local items = H.items(self.state)
  if all_sessions then
    for _, other in ipairs(S.list(self.project, self.opts.data_dir)) do
      if other.state.id ~= self.state.id then
        for _, item in ipairs(H.items(other.state)) do
          item.session_name = other.state.name; item.other_session = true
          items[#items + 1] = item
        end
      end
    end
  end
  return H.filter(items, self.filter == 'file' and self.source_path or nil, self.thread)
end

function M:sync(callback)
  self.client:request('get_entries', {}, function(data, err)
    if self.closed then return end
    if data then
      self.state.entries = data.entries or {}
      self.state.leaf_id = data.leafId ~= vim.NIL and data.leafId or nil
      for _, entry in ipairs(self.state.entries) do
        if entry.type == 'message' and entry.message and entry.message.role == 'user' then
          local id = U.message_text(entry.message):match('<!%-%- tim:([a-f0-9]+) %-%->')
          if id then
            for _, request in ipairs(self.state.requests) do
              if request.id == id then request.pi_entry_id = entry.id end
            end
          end
        end
      end
      require('tim.annotations').refresh(self)
      self:save(); self:changed()
    end
    if callback then callback(err) end
  end)
end

function M:agent_error(err)
  if self.closed then return end
  self.status = tostring(err)
  if self.active then self.active.status = 'uncertain'; self.active.error = tostring(err) end
  self.busy = false; self.active = nil
  self:save(); self:changed()
  U.notify(err, vim.log.levels.ERROR)
end

function M:agent_event(event)
  if self.closed then return end
  if event.type == 'message_update' then
    local change = event.assistantMessageEvent or {}
    if change.type == 'text_delta' then self.stream = self.stream .. (change.delta or ''); self:changed() end
  elseif event.type == 'message_end' then
    local message = event.message or {}
    if self.active and (message.stopReason == 'error' or message.stopReason == 'aborted') then
      self.active.outcome = message.stopReason == 'aborted' and 'cancelled' or 'failed'
      self.active.error = message.errorMessage
    end
  elseif event.type == 'tool_execution_start' then self.status = ({ editor_comment = 'Posting comment', editor_propose_diff = 'Preparing diff', read = 'Reading file', grep = 'Searching', find = 'Finding files', ls = 'Browsing files' })[event.toolName] or 'Working'; self:changed()
  elseif event.type == 'tool_execution_end' then self:sync()
  elseif event.type == 'auto_retry_start' then self.status = 'Pi retrying'; self:changed()
  elseif event.type == 'compaction_start' then self.status = 'Pi compacting context'; self:changed()
  elseif event.type == 'agent_settled' then
    self:sync(function(err)
      if err then self:agent_error(err); return end
      local status = 'Ready'
      if self.active then
        local request, replies, proposals, comments = self.active, 0, 0, 0
        request.status = request.outcome or 'completed'
        for _, item in ipairs(H.items(self.state)) do
          if item.role == 'assistant' and item.request_id == request.id then
            replies = replies + 1
            proposals = proposals + (item.editor_action and (item.editor_action.kind == 'proposal' and 1 or 0) or #require('tim.patches').extract(item.text))
          end
        end
        for _, note in ipairs(self.annotations or {}) do if note.request_id == request.id then comments = comments + 1 end end
        if request.status == 'completed' and replies == 0 then
          request.status = 'failed'
          request.error = 'Pi finished without a text reply or proposed changes. Try again.'
        end
        if request.status ~= 'completed' then
          status = request.status == 'cancelled' and 'Cancelled' or 'Request failed · see chat'
          request.error = request.error or (request.status == 'failed' and 'Pi could not complete this request.' or nil)
        elseif proposals > 0 then
          status = proposals .. (proposals == 1 and ' proposal' or ' proposals') .. ' · preview to apply'
        elseif comments > 0 then
          status = 'Reply ready · ' .. comments .. (comments == 1 and ' comment' or ' comments')
        else status = 'Reply ready' end
        request.result = status
      end
      self.busy = false; self.active = nil; self.stream = ''; self.status = status
      self:save(); self:changed()
    end)
  end
end

function M:review(instructions, selected)
  local refs = {}
  for _, ref in ipairs(selected or {}) do
    local fresh = R.capture(self.project, ref.path, nil, nil, nil, { full = true })
    if not ref.line_start then
      refs[#refs + 1] = fresh
    else
      local row = R.locate(ref, U.lines(fresh.text))
      assert(row, 'Selected code changed or is ambiguous; select it again before running Review')
      local last = row + (ref.line_end or ref.line_start) - ref.line_start
      local current = ref.path == self.source_path and self:capture(row, last)
        or R.capture(self.project, ref.path, row, last)
      current.column_start = ref.column_start; current.column_end = ref.column_end
      current.selection_text = ref.selection_text
      refs[#refs + 1] = current
    end
  end
  assert(#refs > 0 or self.source_buf, 'Open a file or select code to review')
  local text = vim.trim(instructions or '')
  if text == '' then text = #refs > 0 and 'Review the selected code.' or 'Review this file.' end
  return self:send(text, { references = refs, intent = 'review',
    scope = #refs > 0 and 'selection' or 'file' })
end

function M:send(text, context)
  assert(not self.source_error, self.source_error)
  assert(not self.busy, 'Pi is already answering; keep drafting or use :TimStop')
  assert(vim.trim(text) ~= '', 'Write a question first')
  local draft = context or self.state.draft
  local sent_draft = vim.deepcopy(draft)
  local refs = vim.deepcopy(draft.references or {})
  for i, ref in ipairs(refs) do
    if ref.text and ref.line_start then
      local fresh = R.capture(self.project, ref.path, nil, nil, nil, { full = true })
      local row = R.locate(ref, U.lines(fresh.text))
      assert(row, 'Selected context is outdated; clear it or select the current code again')
      local last = row + (ref.line_end or ref.line_start) - ref.line_start
      local updated = ref.path == self.source_path and self:capture(row, last) or R.capture(self.project, ref.path, row, last)
      updated.column_start, updated.column_end, updated.selection_text = ref.column_start, ref.column_end, ref.selection_text
      refs[i] = updated
    end
  end
  for _, mention in ipairs(R.parse(text)) do
    local found = false
    for _, ref in ipairs(refs) do
      if ref.path == mention.path and (not mention.line_start or ref.line_start == mention.line_start) then found = true end
    end
    if not found then refs[#refs + 1] = R.capture(self.project, mention.path, mention.line_start) end
  end
  assert(#refs <= 12, 'Attach at most 12 source references per question')
  local current = self.source_path and self:capture(nil, nil, nil, true) or nil
  if current then
    local found = false
    for _, ref in ipairs(refs) do if ref.path == current.path then found = true end end
    if not found then refs[#refs + 1] = current end
  end
  local id, git = U.id(), self:context()
  local prompt = { '<!-- tim:' .. id .. ' -->', text, '', 'Current Git context: ' .. vim.json.encode(git) }
  if draft.intent == 'review' then
    prompt[#prompt + 1] = 'User explicitly started Review. Target: ' .. (draft.scope == 'selection' and 'only the selected code; the full file is supporting context.' or 'the full current file.')
      .. ' Follow the user instructions above, even when they request explanation or another task rather than a review.'
      .. ' For a default review, identify concrete defects, risks, or useful improvements. Do not invent findings.'
      .. ' When a concrete fix is useful, publish it with editor_propose_diff linked to its editor_comment finding.'
  else
    prompt[#prompt + 1] = 'This is ordinary chat. File citations are navigation only. Use editor tools for requested comments or fixes.'
  end
  prompt[#prompt + 1] = require('tim.proposals').instructions
  local findings = {}
  for _, note in ipairs(self.annotations or {}) do
    if note.reference.path == self.source_path then
      findings[#findings + 1] = { id = note.id, path = note.reference.path, line = note.reference.line_start, body = note.text }
    end
  end
  if #findings > 0 then prompt[#prompt + 1] = 'Existing findings (reuse comment_id when refreshing or proposing a fix):\n' .. vim.json.encode(findings) end
  if current then
    prompt[#prompt + 1] = '\nCurrent editor file ' .. R.label(current)
      .. ' (complete buffer at send time; ' .. (current.unsaved and 'unsaved' or 'saved') .. ').'
      .. '\nUse this buffer as the current file content, even if disk or earlier snapshots differ.'
      .. '\n' .. current.text
  end
  for _, ref in ipairs(refs) do
    if ref ~= current then
      prompt[#prompt + 1] = '\nSource snapshot ' .. R.label(ref) .. ' through line ' .. ref.line_end
        .. (ref.unsaved and ' (unsaved buffer)' or '') .. (ref.truncated and ' (partial file)' or '')
        .. '\nSnapshot Git context: ' .. vim.json.encode(ref.git or {}) .. '\n' .. (ref.text or '')
      if ref.selection_text then
        prompt[#prompt + 1] = 'Focus on this exact selected text (end column exclusive):\n' .. ref.selection_text
          .. '\nColumns: ' .. ref.column_start .. ' to ' .. ref.column_end
      end
    end
  end
  if draft.context then prompt[#prompt + 1] = '\nUser-attached context:\n' .. draft.context end
  local joined = table.concat(prompt, '\n')
  assert(#joined <= 400 * 1024, 'Question and attachments exceed 400 KB; question was not sent')
  local request = { id = id, text = text, prompt = joined, references = refs, focus_references = vim.deepcopy(draft.references or {}), git = git,
    current_file = current, intent = draft.intent or 'chat', scope = draft.scope,
    comment_policy = draft.intent == 'review' and 'explicit' or 'none', status = 'sending', created_at = U.now(), thread_id = draft.thread_id or id }
  self.state.requests[#self.state.requests + 1] = request
  self.last_request = request.id; self.thread = draft.thread_id
  self.active = request; self.busy = true; self.stream = ''; self.status = 'Sending'
  self:save(); self:changed()
  if not self.client then
    self.client = require('tim.pi').new({ command = self.opts.pi_command or vim.env.TIM_PI or 'pi',
      root = self.project.root, session = self.state.pi_session, model = self.opts.model,
      timeout = self.opts.rpc_timeout,
      on_event = function(event) self:agent_event(event) end,
      on_error = function(err) self:agent_error(err) end,
    })
  end
  local ok, err = pcall(function()
    self.client:request('get_state', {}, function(data, failure)
      if self.closed or self.active ~= request then return end
      if not data then self:agent_error(failure); return end
      if data.isStreaming or data.isCompacting then self:agent_error('Pi still has work in progress; wait or Cancel before retrying'); return end
      request.prompt_sent = true
      self.client:request('prompt', { message = joined }, function(_, problem, uncertain)
        if self.closed or self.active ~= request then return end
        if problem and uncertain then self:agent_error(problem); return end
        if problem then
          request.status = 'failed'; request.error = problem
          self.busy = false; self.active = nil; self.status = problem
        else
          request.status = request.cancel_requested and 'cancelling' or 'running'
          self.status = request.cancel_requested and 'Cancelling' or 'Working'
          S.touch(self.state, request.git)
          -- Preserve edits made while the submission was awaiting acceptance.
          if self.on_before_accept then self.on_before_accept() end
          if not context and self.state.draft.text == text and vim.deep_equal(self.state.draft, sent_draft) then
            self.state.draft = { text = '', references = {}, mode = 'ask' }
            if self.on_draft_reset then self.on_draft_reset() end
          end
        end
        self:save(); self:changed()
      end)
    end)
  end)
  if not ok then self:agent_error(err) end
  return request
end

function M:retry()
  assert(not self.busy, 'Wait or cancel the current request first')
  local request = self.state.requests[#self.state.requests]
  assert(request and vim.tbl_contains({ 'failed', 'cancelled', 'uncertain' }, request.status), 'No failed request to retry')
  if request.current_file then
    assert(self.source_path == request.current_file.path, 'Open ' .. request.current_file.path .. ' before retrying')
  end
  local selected = request.focus_references or {}
  if request.intent == 'review' then return self:review(request.text, selected) end
  return self:send(request.text, { references = selected, thread_id = request.thread_id })
end

function M:stop()
  if not self.busy or not self.client then return end
  if self.active then
    self.active.cancel_requested = true; self.active.outcome = 'cancelled'
    if not self.active.prompt_sent then
      self.active.status = 'cancelled'; self.active = nil; self.busy = false; self.status = 'Cancelled'
      self:save(); self:changed(); return
    end
    self.active.status = 'cancelling'
  end
  self.status = 'Cancelling'; self:save(); self:changed()
  self.client:request('abort', {}, function(_, err)
    if err then self:agent_error(err) end
  end)
end

function M:import(path)
  local incoming = TB.import(vim.fn.fnamemodify(path, ':p'), self.project)
  local seen, count = {}, 0
  for _, item in ipairs(self.state.imports) do seen[item.id] = true end
  for _, item in ipairs(incoming) do
    if not seen[item.id] then self.state.imports[#self.state.imports + 1] = item; count = count + 1 end
  end
  self:save(); self:changed()
  return count
end

function M:export(path)
  assert(not vim.uv.fs_stat(path), 'Export destination already exists; choose a new file')
  local records, work = {}, {}
  for _, item in ipairs(H.items(self.state)) do
    records[#records + 1] = {
      event_id = self.state.id .. ':' .. item.id, origin = 'tim', session_id = self.state.id,
      thread_id = item.thread_id, kind = item.kind, actor_role = item.role,
      text = item.text, references = item.references, current_file = item.current_file, git = item.git,
      created_at = item.created_at, timestamp = item.timestamp, pi_entry_id = item.pi_entry_id,
      status = item.status, inherited_from = item.origin, intent = item.intent, request_id = item.request_id,
      editor_action = vim.deepcopy(item.editor_action),
    }
  end
  for _, event in ipairs(self.state.work) do
    local copy = vim.deepcopy(event)
    copy.event_id = self.state.id .. ':' .. event.id
    copy.origin = 'tim'; copy.session_id = self.state.id; copy.id = nil
    work[#work + 1] = copy
  end
  U.write_json(path, { schema_version = 1, origin = 'tim', session_id = self.state.id,
    session_name = self.state.name, project = self.project, ticketbunker = self.state.ticketbunker,
    records = records, work = work, annotations = self.state.annotations })
end

function M:close()
  if self.closed then return end
  if self.active then self.active.status = 'uncertain' end
  self:save(); self.closed = true
  local stopped = not self.client or self.client:close()
  if stopped then self.handle.release() end
end

return M
