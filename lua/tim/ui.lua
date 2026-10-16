local U = require('tim.util')
local R = require('tim.references')
local P = require('tim.project')
local M = {}
M.__index = M
local ns = vim.api.nvim_create_namespace('tim-comments')
local input_ns = vim.api.nvim_create_namespace('tim-input')
local links_ns = vim.api.nvim_create_namespace('tim-links')
local agent_ns = vim.api.nvim_create_namespace('tim-agent-comments')
local proposal_ns = vim.api.nvim_create_namespace('tim-proposals')
local selection_ns = vim.api.nvim_create_namespace('tim-selection')

local function valid_buf(buf) return buf and vim.api.nvim_buf_is_valid(buf) end
local function window(buf)
  if not valid_buf(buf) then return nil end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then return win end
  end
end

function M.new(app)
  local self = setmetatable({ app = app, rows = {}, links = {}, view = 'chat' }, M)
  self.selection = require('tim.selection').new(self)
  self.review = require('tim.review').new(self)
  self.task = require('tim.task').new(self)
  self.files = require('tim.files').new(self)
  app.on_change = function()
    if self.scheduled then return end
    self.scheduled = true
    vim.defer_fn(function()
      self.scheduled = false
      if not app.closed then self:render() end
    end, 40)
  end
  app.on_draft_reset = function()
    self.selection_version = (self.selection_version or 0) + 1
    if valid_buf(self.draft) then
      vim.api.nvim_buf_set_lines(self.draft, 0, -1, false, { '' })
      vim.bo[self.draft].modified = false
      self:input_labels()
    end
  end
  app.on_before_accept = function() self:flush_draft() end
  return self
end

function M:transcript_buffer()
  if valid_buf(self.transcript) then return self.transcript end
  local buf = vim.api.nvim_create_buf(false, true)
  self.transcript = buf
  vim.api.nvim_buf_set_name(buf, 'tim://' .. self.app.state.id .. '/session')
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].modifiable = false
  local function map(key, fn, desc)
    vim.keymap.set('n', key, function()
      local ok, err = pcall(fn)
      if not ok then U.notify(err, vim.log.levels.WARN) end
    end, { buffer = buf, silent = true, desc = desc })
  end
  map('<CR>', function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    if not self:action(cursor[1], cursor[2] + 1) then self:follow() end
  end, 'Open source reference')
  map('gf', function() self:follow() end, 'Open source reference')
  map('a', function() self:ask_item(false) end, 'Ask about this comment or exchange')
  map('r', function() self:ask_item(true) end, 'Reply to this exchange')
  map('i', function() self:compose('ask') end, 'Write a message')
  map('q', function() self:hide() end, 'Hide agent pane')
  return buf
end

function M:show(full, focus)
  local previous = vim.api.nvim_get_current_win()
  local buf = self:transcript_buffer()
  local win = window(buf)
  if full then
    if #vim.api.nvim_tabpage_list_wins(0) > 1 then vim.cmd('tabnew') end
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  end
  if not win then
    if not full then vim.cmd('botright vsplit') end
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    if not full then vim.api.nvim_win_set_width(win, math.max(30, math.min(64, math.floor(vim.o.columns * 0.42)))) end
  elseif focus then vim.api.nvim_set_current_win(win) end
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].wrap = true
  vim.wo[win].statusline = ' ' .. self.app.state.name:gsub('%%', '%%%%') .. '%= ' .. self.app.status:gsub('%%', '%%%%') .. ' '
  vim.wo[win].winbar = self:header()
  self:show_input(win)
  self:render()
  if focus then vim.api.nvim_set_current_win(win) end
  if vim.api.nvim_win_is_valid(previous) and vim.api.nvim_win_get_buf(previous) == self.app.source_buf then
    self.source_win = previous
    if self.app.opts.editor then
      vim.wo[previous].winbar = ' %f %m%=%@v:lua.TimNextPoint@ Points %X%@v:lua.TimToggleAgent@ Agent %X'
    end
  end
  if not focus and vim.api.nvim_win_is_valid(previous) then vim.api.nvim_set_current_win(previous) end
end

function M:header()
  local parts = {}
  for _, tab in ipairs({ { 'chat', 11, 'Chat' }, { 'comments', 12, 'Comments' }, { 'diffs', 13, 'Diffs' } }) do
    parts[#parts + 1] = '%' .. tab[2] .. '@v:lua.TimAgentControl@ '
      .. (self.view == tab[1] and '[' .. tab[3] .. ']' or tab[3]) .. ' %X'
  end
  return table.concat(parts) .. '%=%2@v:lua.TimAgentControl@ Hide %X'
end

function M:set_view(view)
  self:dismiss_popups()
  self.view = view
  self:show(false, false)
end

function M:report_error(err)
  self.app.status = tostring(err):gsub('^.-:%d+: ', '')
  self:input_labels(); self:render()
end

function M:render()
  if not valid_buf(self.transcript) then self:marks(); return end
  local app = self.app
  local state, lines = app.state, {}
  local function add(value) lines[#lines + 1] = value end
  self.actions, self.rows, self.links = {}, {}, {}
  local items = self.view == 'chat' and app:items(app.all_sessions) or {}
  if #items == 0 then add('Ask about your file below.') end
  for _, item in ipairs(items) do
    local start = #lines + 1
    local label = item.role == 'assistant' and 'Pi' or 'You'
    if item.kind == 'comment' then label = label .. ' · local note' end
    if item.editor_action then label = label .. ((app.action_error_entries or {})[item.id] and ' · comment unavailable'
      or item.editor_action.kind == 'comment' and ' · comment posted' or ' · diff proposed') end
    if item.intent == 'review' and item.role == 'user' then label = label .. ' · Review' end
    if item.imported then label = label .. ' · imported' end
    if item.other_session then label = label .. ' · ' .. item.session_name end
    add(label)
    if item.status and vim.tbl_contains({ 'failed', 'uncertain', 'cancelled' }, item.status) then add(item.status) end
    local text = item.text
    local proposals = item.editor_action and (item.editor_action.kind == 'proposal' and { item.editor_action.diff } or {}) or require('tim.patches').extract(text)
    text = text:gsub('```diff%s*\n.-\n```', ''):gsub('\n+$', '')
    for _, line in ipairs(U.lines(text)) do add(line) end
    for _, diff in ipairs(proposals) do
      add('[Review changes]')
      self.actions[#lines] = { { 1, 1000, function() self.review:patch(diff, item.id) end } }
    end
    local error = item.error or (app.action_error_entries or {})[item.id]
    if error then for _, line in ipairs(U.lines(error)) do add(line) end end
    add('')
    for row = start, #lines do self.rows[row] = item end
  end
  if app.busy and self.view == 'chat' then
    add('Pi · ' .. (app.stream == '' and 'thinking…' or ''))
    for _, line in ipairs(U.lines(app.stream:gsub('```diff.*', 'Preparing proposed changes…'))) do add(line) end
  end
  local panel
  if self.view ~= 'chat' then
    panel = require('tim.views')[self.view](self)
    lines, self.actions = panel.lines, panel.actions
  end
  local win, cursor = window(self.transcript), nil
  if win then vim.wo[win].winbar = self:header() end
  if win then vim.wo[win].statusline = ' ' .. state.name:gsub('%%', '%%%%')
    .. (app.thread and self.view == 'chat' and ' · thread %5@v:lua.TimAgentControl@ Back %X' or '')
    .. '%= ' .. app.status:gsub('[\r\n]', ' '):gsub('%%', '%%%%') .. ' ' end
  if win then cursor = vim.api.nvim_win_get_cursor(win) end
  local selection = self.view == 'diffs' and self.selected_proposal or self.selected_comment
  if panel and (self.rendered_view ~= self.view or self.rendered_selection ~= selection) then cursor = { panel.focus_row or 1, 0 } end
  self.rendered_view, self.rendered_selection = self.view, selection
  local changed = not vim.deep_equal(lines, self.rendered_lines)
  local follow = win and changed and (self.rendered_request ~= app.last_request
    or vim.api.nvim_get_current_win() ~= win)
  self.rendered_lines = vim.deepcopy(lines); self.rendered_request = app.last_request
  vim.bo[self.transcript].modifiable = true
  vim.api.nvim_buf_set_lines(self.transcript, 0, -1, false, lines)
  vim.bo[self.transcript].modifiable = false
  vim.bo[self.transcript].modified = false
  vim.api.nvim_buf_clear_namespace(self.transcript, links_ns, 0, -1)
  -- Parse the whole message view so fenced code is never turned into links.
  local joined = table.concat(lines, '\n')
  for _, ref in ipairs(self.view == 'diffs' and {} or R.parse(joined)) do
    local prefix = joined:sub(1, ref.start_col)
    local _, count = prefix:gsub('\n', '')
    local row = count + 1
    local last = prefix:match('.*\n()') or 1
    local column = #prefix - last + 1
    local finish = math.min(#(lines[row] or ''), column + ref.end_col - ref.start_col)
    self.links[row] = self.links[row] or {}
    local link = vim.deepcopy(ref); link.start_col = column; link.end_col = finish
    self.links[row][#self.links[row] + 1] = link
    vim.api.nvim_buf_set_extmark(self.transcript, links_ns, row - 1, column, { end_col = finish, hl_group = 'Underlined' })
  end
  if win and cursor then
    cursor[1] = math.min(cursor[1], #lines)
    cursor[2] = math.min(cursor[2], #(lines[cursor[1]] or ''))
    vim.api.nvim_win_set_cursor(win, cursor)
  end
  if panel then
    for _, highlight in ipairs(panel.highlights) do vim.api.nvim_buf_set_extmark(self.transcript, links_ns, highlight[1] - 1, 0, { line_hl_group = highlight[2] }) end
  end
  if follow and self.view == 'chat' then self:latest() end
  self:input_labels()
  self:marks()
  if app.opts.editor then vim.cmd('redrawtabline') end
end

function M:latest()
  local win = window(self.transcript)
  if win then
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(self.transcript), 0 })
    vim.api.nvim_win_call(win, function() vim.cmd('normal! zb') end)
  end
end

function M:has_popup()
  for _, popup in ipairs({ self.task, self.review, self.selection }) do
    if popup.win and vim.api.nvim_win_is_valid(popup.win) then return true end
  end
  return false
end

function M:dismiss_popups()
  if not self:has_popup() then return false end
  for _, popup in ipairs({ self.task, self.review, self.selection }) do
    if popup.win and vim.api.nvim_win_is_valid(popup.win) then popup:close() end
  end
  return true
end

function M:marks()
  local app = self.app
  if not valid_buf(app.source_buf) or not vim.api.nvim_buf_is_loaded(app.source_buf) then return end
  local buf = app.source_buf
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for _, note in ipairs(app.state.notes) do
    for _, ref in ipairs(note.references or {}) do
      local branch = (ref.git or {}).branch or (note.git or {}).branch
      if ref.path == app.source_path and (not branch or branch == (app.state.git or {}).branch) then
        local row = R.locate(ref, lines)
        if row then
          vim.api.nvim_buf_set_extmark(buf, ns, row - 1, math.min(#lines[row], (ref.column_start or 1) - 1), {
            sign_text = '●', sign_hl_group = 'DiagnosticInfo',
            end_row = ref.column_start and (row - 1 + ref.line_end - ref.line_start)
              or math.min(#lines, row - 1 + #(U.lines(ref.text))),
            end_col = ref.column_end and math.min(#(lines[row + (ref.line_end - ref.line_start)] or ''), ref.column_end - 1) or nil,
            hl_group = ref.column_start and 'Visual' or nil,
          })
        end
      end
    end
  end
  if self.selected_buf and valid_buf(self.selected_buf) then
    vim.api.nvim_buf_clear_namespace(self.selected_buf, selection_ns, 0, -1)
  end
  self.selected_buf = buf
  vim.api.nvim_buf_clear_namespace(buf, selection_ns, 0, -1)
  for _, ref in ipairs(app.state.draft.references or {}) do
    if ref.path == app.source_path and ref.text and ref.line_end then
      local row = R.locate(ref, lines)
      if row then
        vim.api.nvim_buf_set_extmark(buf, selection_ns, row - 1, (ref.column_start or 1) - 1, {
          end_row = ref.column_start and (row - 1 + ref.line_end - ref.line_start) or (row + ref.line_end - ref.line_start),
          end_col = ref.column_end and ref.column_end - 1 or 0,
          hl_group = 'Visual', hl_eol = not ref.column_start,
        })
      end
    end
  end

  vim.api.nvim_buf_clear_namespace(buf, agent_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, proposal_ns, 0, -1)
  vim.api.nvim_set_hl(0, 'TimProposal', { fg = '#70c080', ctermfg = 114, default = true })
  self.agent_rows, self.proposal_rows = {}, {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do vim.wo[win].signcolumn = 'yes:2' end
  for _, note in ipairs(app.annotations or {}) do
    local ref = note.reference
    local branch = (ref.git or {}).branch
    if ref.path == app.source_path and (not branch or branch == (app.state.git or {}).branch) then
      local row = R.locate(ref, lines)
      if row and row >= 1 and row <= #lines then
        self.agent_rows[row] = self.agent_rows[row] or {}
        table.insert(self.agent_rows[row], note)
        -- One comment marker per row leaves the adjacent sign slot for its diff.
        if #self.agent_rows[row] == 1 then
          vim.api.nvim_buf_set_extmark(buf, agent_ns, row - 1, 0, {
            sign_text = '◆', sign_hl_group = 'DiagnosticHint', priority = 100,
          })
        end
        if #((app.comment_proposals or {})[note.id] or {}) > 0 then
          if not self.proposal_rows[row] then
            vim.api.nvim_buf_set_extmark(buf, proposal_ns, row - 1, 0, {
              sign_text = '◆', sign_hl_group = 'TimProposal', priority = 90,
            })
          end
          self.proposal_rows[row] = self.proposal_rows[row] or {}
          for _, proposal in ipairs((app.comment_proposals or {})[note.id]) do
            if not vim.tbl_contains(self.proposal_rows[row], proposal) then table.insert(self.proposal_rows[row], proposal) end
          end
        end
      end
    end
  end

end

function M:flush_draft()
  if valid_buf(self.draft) then
    self.app.state.draft.text = table.concat(vim.api.nvim_buf_get_lines(self.draft, 0, -1, false), '\n')
    self.app:save()
    vim.bo[self.draft].modified = false
    self:input_labels()
  end
end

function M:draft_buffer()
  if valid_buf(self.draft) then return self.draft end
  local draft = self.app.state.draft
  self.draft = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(self.draft, 'tim://' .. self.app.state.id .. '/draft')
  vim.bo[self.draft].buftype = 'acwrite'
  vim.bo[self.draft].bufhidden = 'hide'
  vim.bo[self.draft].filetype = 'markdown'
  vim.bo[self.draft].omnifunc = "v:lua.require'tim'.complete"
  vim.api.nvim_buf_set_lines(self.draft, 0, -1, false, U.lines(draft.text))
  vim.bo[self.draft].modified = false
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufLeave', 'BufWriteCmd' }, {
    buffer = self.draft, callback = function(event)
      self:flush_draft()
      if event.event == 'BufLeave' then vim.cmd('stopinsert') end
    end,
  })
  vim.api.nvim_create_autocmd('BufEnter', { buffer = self.draft, callback = function()
    vim.schedule(function()
      if not self.app.closed and vim.api.nvim_get_current_buf() == self.draft then vim.cmd('startinsert') end
    end)
  end })
  local function submit()
    local ok, err = pcall(function() self:flush_draft(); require('tim').submit_draft() end)
    if not ok then self:report_error(err) end
  end
  vim.keymap.set({ 'n', 'i' }, '<C-s>', submit, { buffer = self.draft, desc = 'Send to Pi' })
  vim.keymap.set({ 'n', 'i' }, '<CR>', function()
    if vim.fn.pumvisible() == 1 then
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-y>', true, false, true), 'n', false)
    else submit() end
  end, { buffer = self.draft, desc = 'Send to Pi' })
  vim.keymap.set('i', '<M-CR>', '<CR>', { buffer = self.draft, desc = 'New line' })
  vim.keymap.set('i', '<C-j>', '<CR>', { buffer = self.draft, desc = 'New line' })
  vim.keymap.set({ 'n', 'i' }, '<Esc>', function() if not self:dismiss_popups() then self:return_to_source() end end,
    { buffer = self.draft, desc = 'Return to code' })
  return self.draft
end

function M:show_input(transcript_win)
  local buf = self:draft_buffer()
  local win = window(buf)
  if not win then
    vim.api.nvim_set_current_win(transcript_win)
    vim.cmd('belowright 6split')
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  end
  vim.wo[win].wrap = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].winfixheight = true
  vim.wo[win].winhighlight = 'Normal:NormalFloat,WinBar:Title'
  self:input_labels()
  return win
end

function M:input_labels()
  local win = window(self.draft)
  if not win then return end
  local draft = self.app.state.draft
  local title = draft.intent == 'review' and 'Review · Enter run' or 'Message · Enter send'
  local control = draft.intent == 'review' and '%16@v:lua.TimAgentControl@ Cancel review %X' or '%7@v:lua.TimAgentControl@ Review %X'
  if self.app.busy then title = self.app.status; control = '%14@v:lua.TimAgentControl@ Cancel %X'
  else
    local last = self.app.state.requests[#self.app.state.requests]
    if last and vim.tbl_contains({ 'failed', 'cancelled', 'uncertain' }, last.status) then control = control .. '%15@v:lua.TimAgentControl@ Retry %X' end
  end
  title = vim.fn.strcharpart(title:gsub('[\r\n]', ' '), 0, math.max(12, vim.api.nvim_win_get_width(win) - 18))
  vim.wo[win].winbar = ' ' .. title:gsub('%%', '%%%%') .. ' %=' .. control
  local attachments = {}
  for _, source in ipairs(draft.references or {}) do attachments[#attachments + 1] = R.label(source) end
  local context = self.app.source_path and (self.app.source_path .. ' · whole file') or 'Session chat'
  if #attachments > 0 then context = 'Selected: ' .. table.concat(attachments, ', ') end
  local limit = math.max(4, vim.api.nvim_win_get_width(win) - (#attachments > 0 and 19 or 2))
  if vim.fn.strdisplaywidth(context) > limit then
    while vim.fn.strdisplaywidth(context) >= limit do context = vim.fn.strcharpart(context, 0, vim.fn.strchars(context) - 1) end
    context = context .. '…'
  end
  vim.wo[win].statusline = (#attachments > 0 and '%6@v:lua.TimAgentControl@' or '')
    .. (' ' .. context):gsub('%%', '%%%%') .. (#attachments > 0 and '%X' or '')
    .. (#attachments > 0 and ' %=%3@v:lua.TimAgentControl@ Clear selection %X' or '')
  vim.api.nvim_buf_clear_namespace(self.draft, input_ns, 0, -1)
  if vim.trim(draft.text or '') == '' then
    local hint = draft.intent == 'review' and 'Optional instructions · Enter reviews the target' or (#attachments > 0 and 'Selection ready · ask about it…'
        or (self.app.source_path and 'Ask about this file…' or 'Write a message to Pi…'))
    vim.api.nvim_buf_set_extmark(self.draft, input_ns, 0, 0, {
      virt_text = { { hint, 'Comment' } }, virt_text_pos = 'overlay',
    })
  end
end

function M:set_selection(refs)
  self.selection_version = (self.selection_version or 0) + 1
  self.app.state.draft.references = vim.deepcopy(refs)
  self.app.state.draft.thread_id = nil
  self.app.state.draft.context = nil
  self.app:save()
  self:render()
end

-- Available across file/thread filters, so a proposal never depends on scroll position.
function M:show_changes() self:set_view('diffs') end

function M:action(row, col)
  for _, action in ipairs((self.actions or {})[row] or {}) do
    if col >= action[1] and col <= action[2] then
      local ok, err = pcall(action[3]); if not ok then self:report_error(err) end
      return true
    end
  end
  return false
end

function M:hide()
  self.task:close()
  self.review:close()
  local mode = vim.fn.mode()
  if mode == 'v' or mode == 'V' then
    vim.cmd('normal! ' .. vim.api.nvim_replace_termcodes('<Esc>', true, false, true))
  end
  self.selection:close()
  self:flush_draft()
  self:return_to_source()
  for _, buf in ipairs({ self.draft or -1, self.transcript or -1 }) do
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      if vim.api.nvim_win_is_valid(win) then
        local wins = vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win))
        if #wins > 1 then vim.api.nvim_win_close(win, true)
        elseif self.app.source_buf then vim.api.nvim_win_set_buf(win, self.app.source_buf)
        else vim.api.nvim_win_call(win, function() vim.cmd('enew') end) end
      end
    end
  end
end

function M:toggle()
  if window(self.transcript) or window(self.draft) then self:hide()
  else self:show(false, false) end
end

function M:return_to_source()
  self:flush_draft()
  vim.cmd('stopinsert')
  local win = window(self.app.source_buf)
  if not win and self.source_win and vim.api.nvim_win_is_valid(self.source_win) then win = self.source_win end
  if win then vim.api.nvim_set_current_win(win)
  elseif self.app.source_path then self:open_reference({ path = self.app.source_path, line_start = 1 })
  elseif window(self.transcript) then vim.api.nvim_set_current_win(window(self.transcript)) end
end

function M:compose(mode, ref)
  self:flush_draft()
  local draft = self.app.state.draft
  if vim.trim(draft.text or '') == '' and ref then
    draft.references = {}; draft.thread_id = nil; draft.context = nil
  end
  draft.mode = 'ask'
  if ref then self.app:attach(ref) end
  if mode == 'comment' and #draft.references == 0 then
    self.selection:picker('comment'); return
  end
  self.view = 'chat'
  self:show(false, false)
  local win = window(self.draft)
  vim.api.nvim_set_current_win(win)
  self:input_labels()
  self.app:save()
  vim.cmd('startinsert!')
end

function M:ask_item(comment)
  local item = self.rows[vim.api.nvim_win_get_cursor(0)[1]]
  assert(item, 'Move to a comment or exchange first')
  self:flush_draft()
  assert(vim.trim(self.app.state.draft.text or '') == '', 'Send or clear the current message before replying to this entry')
  local draft = self.app.state.draft
  draft.thread_id = item.thread_id or item.id
  draft.references = vim.deepcopy(item.references or {})
  draft.context = item.text
  self:compose(comment and 'comment' or 'ask')
end

function M:link_at(row, col)
  for _, ref in ipairs(self.links[row] or {}) do
    if col >= ref.start_col and col < ref.end_col then return ref end
  end
end

function M:follow()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local ref = self:link_at(cursor[1], cursor[2]) or (self.links[cursor[1]] or {})[1]
  assert(ref, 'No source reference on this line')
  self:open_reference(ref)
end

function M:point(direction)
  local rows = vim.tbl_keys(self.agent_rows or {})
  table.sort(rows)
  assert(#rows > 0, 'No agent comments in this file')
  self:return_to_source()
  local current = vim.api.nvim_win_get_cursor(0)[1]
  local target = direction > 0 and rows[1] or rows[#rows]
  if direction > 0 then
    for _, row in ipairs(rows) do if row > current then target = row; break end end
  else
    for i = #rows, 1, -1 do if rows[i] < current then target = rows[i]; break end end
  end
  vim.api.nvim_win_set_cursor(0, { target, 0 })
  self.review:annotation(self.agent_rows[target][1])
end

function M:open_reference(ref)
  local full, err = P.resolve(self.app.project.root, ref.path)
  assert(full, err)
  local buf = vim.fn.bufnr(full)
  assert(vim.uv.fs_stat(full) or buf > 0, 'Source no longer exists: ' .. ref.path)
  if buf < 1 then buf = vim.fn.bufadd(full) end
  vim.fn.bufload(buf)
  local win = window(self.app.source_buf)
  if not win then
    vim.cmd('topleft vsplit')
    win = vim.api.nvim_get_current_win()
  end
  if self.app.source_buf and self.source_win and vim.api.nvim_win_is_valid(self.source_win) then
    self.files.positions = self.files.positions or {}
    self.files.positions[self.app.source_buf] = vim.api.nvim_win_get_cursor(self.source_win)[1]
  end
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_buf(win, buf)
  self.files:track(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert(ref.text or (ref.line_start or 1) <= #lines, 'Referenced line is outside the current file')
  local row, status = R.locate(ref, lines)
  if not row then U.notify('Historical reference is ' .. status .. '; showing its original location', vim.log.levels.WARN) end
  local target = math.min(#lines, row or ref.line_start or 1)
  vim.api.nvim_win_set_cursor(win, { target, math.min(#lines[target], (ref.column_start or 1) - 1) })
  local jump = vim.api.nvim_create_namespace('tim-jump')
  vim.api.nvim_buf_clear_namespace(buf, jump, 0, -1)
  local mark = vim.api.nvim_buf_set_extmark(buf, jump, target - 1, 0, { line_hl_group = 'Visual' })
  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_del_extmark, buf, jump, mark) end
  end, 1500)
  self.app:source(buf)
  self.source_win = win
  self:render()
end

function M:destroy()
  self.task:close()
  for _, buf in ipairs(self.files:list()) do
    for _, namespace in ipairs({ ns, agent_ns, proposal_ns, selection_ns }) do vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1) end
  end
  self.review:close()
  self.selection:close()
  self:flush_draft()
  for _, buf in pairs({ draft = self.draft, transcript = self.transcript }) do
    if valid_buf(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
  end
end

M.namespace = ns
M.agent_namespace = agent_ns
return M
