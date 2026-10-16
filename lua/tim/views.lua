-- One agent panel: chat, findings, or proposal review. No nested review windows.
local U = require('tim.util')
local R = require('tim.references')
local Proposals = require('tim.proposals')
local M = {}
local function builder(ui)
  local view = { lines = {}, actions = {}, highlights = {} }
  function view:add(text) local first = #self.lines + 1; vim.list_extend(self.lines, U.lines(text)); return first end
  function view:buttons(buttons)
    local text, actions = '', {}
    for _, button in ipairs(buttons) do
      local first = #text + 1
      text = text .. '[' .. button[1] .. '] '
      actions[#actions + 1] = { first, #text, button[2] }
    end
    local row = self:add(text); self.actions[row] = actions
  end
  return view
end
function M.refresh(ui, finding, proposal)
  ui:flush_draft()
  local draft = ui.app.state.draft
  assert(vim.trim(draft.text) == '', 'Send or clear the current input before preparing a refresh')
  local path = finding and finding.reference.path or proposal.ranges[1] and proposal.ranges[1].path
    or proposal.current_file and proposal.current_file.path
  assert(path, 'This proposal has no valid file target')
  ui:open_reference({ path = path, line_start = 1 })
  draft.references = {}; draft.intent = 'review'
  local linked = finding or (proposal.comment_id and ui.app.state.annotations[proposal.comment_id])
  draft.thread_id = linked and linked.thread_id or nil
  draft.context = finding and ('Refresh comment_id ' .. finding.id .. ': ' .. finding.text)
    or ('Regenerate this proposal against the current buffer' .. (proposal.comment_id and ' for comment_id ' .. proposal.comment_id or '') .. ': ' .. proposal.title .. '\n' .. proposal.diff)
  local text = finding and 'Re-check this finding against the current file and update it. Propose a fix if it still applies.'
    or 'Propose an updated fix against the current file.'
  vim.api.nvim_buf_set_lines(ui.draft, 0, -1, false, { text })
  ui:set_view('chat'); ui:compose('ask')
end
function M.reply(ui, note)
  ui:flush_draft()
  assert(vim.trim(ui.app.state.draft.text) == '', 'Send or clear the current input before replying')
  local draft = ui.app.state.draft
  local reference = note.reference or (note.references or {})[1]
  draft.references = reference and { vim.deepcopy(reference) } or {}
  draft.thread_id = note.thread_id; draft.context = note.text; draft.intent = nil
  ui.app.thread = note.thread_id
  ui:set_view('chat'); ui:compose('ask')
end
function M.comments(ui)
  local v, app = builder(ui), ui.app
  v:buttons({ { 'Select lines', function() ui.selection:picker() end },
    { 'Save note', function() require('tim').submit_draft('comment') end } })
  v:add('')
  for _, err in ipairs(app.action_errors or {}) do v:add(err) end
  local count = 0
  for _, note in ipairs(app.findings or {}) do
    if not app.source_path or note.reference.path == app.source_path or note.id == ui.selected_comment then
      count = count + 1
      local status = Proposals.finding_status(app, note)
      local row = v:add(R.label(note.reference) .. ' · ' .. status)
      if note.id == ui.selected_comment then v.focus_row = row end
      for _, line in ipairs(U.lines(note.text)) do v:add(line) end
      local buttons = {
        { 'Source', function() ui:open_reference(note.reference) end },
        { 'Reply', function() M.reply(ui, note) end },
        { note.resolved and 'Reopen' or 'Resolve', function()
          note.resolved = not note.resolved; app:save(); require('tim.annotations').refresh(app); ui:render()
        end },
      }
      local proposals = {}
      for _, proposal in ipairs(app.all_proposals or {}) do if proposal.comment_id == note.id then proposals[#proposals + 1] = proposal end end
      if #proposals > 0 then buttons[#buttons + 1] = { 'Diffs', function() ui.selected_proposal = proposals[#proposals].id; ui:set_view('diffs') end } end
      if status == 'outdated' then buttons[#buttons + 1] = { 'Refresh', function() M.refresh(ui, note) end } end
      v:buttons(buttons); v:add('')
    end
  end
  for _, note in ipairs(app.state.notes) do
    local ref = (note.references or {})[1]
    if ref and (not app.source_path or ref.path == app.source_path) then
      count = count + 1; v:add(R.label(ref) .. ' · local note'); v:add(note.text)
      v:buttons({ { 'Reply', function() M.reply(ui, note) end } }); v:add('')
    end
  end
  if count == 0 then v:add('No comments for this file.'); v:add('Review this file to request findings.') end
  return v
end
function M.diffs(ui)
  local v, app = builder(ui), ui.app
  local proposals = app.all_proposals or {}
  if #proposals == 0 then v:add('No proposed changes yet.'); v:add('Ask for a fix in chat or review your file.'); return v end
  local selected
  for _, proposal in ipairs(proposals) do if proposal.id == ui.selected_proposal then selected = proposal end end
  selected = selected or proposals[#proposals]; ui.selected_proposal = selected.id
  for i, proposal in ipairs(proposals) do
    local status = Proposals.inspect(app, proposal)
    v:buttons({ { (proposal == selected and '> ' or '') .. i .. '. ' .. proposal.title:gsub('[\r\n]', ' ') .. ' · ' .. status,
      function() ui.selected_proposal = proposal.id; ui:render() end } })
  end
  v:add(''); v.focus_row = v:add(selected.title)
  local status, plan = Proposals.inspect(app, selected)
  local buttons = {}
  if status == 'ready' then
    -- Capture this exact preview; apply refuses a source edit after it was drawn.
    buttons[#buttons + 1] = { 'Apply', function()
      require('tim.work').apply(app, selected, plan)
      for _, file in ipairs(plan) do ui.files:track(file.buf) end
      ui:render()
    end }
  elseif status == 'applied' then
    buttons[#buttons + 1] = { 'Undo', function() require('tim.work').undo(app, selected); ui:render() end }
  end
  if selected.status == 'pending' then
    buttons[#buttons + 1] = { 'Reject', function() require('tim.work').reject(app, selected); ui:render() end }
    if status == 'outdated' then buttons[#buttons + 1] = { 'Refresh', function() M.refresh(ui, nil, selected) end } end
  end
  if selected.comment_id and app.state.annotations[selected.comment_id] then
    buttons[#buttons + 1] = { 'Comment', function() ui.selected_comment = selected.comment_id; ui:set_view('comments') end }
  end
  if #buttons > 0 then v:buttons(buttons) end
  if status == 'ready' then v:add('Needs approval · applying changes buffers, not disk.')
  elseif status == 'outdated' then v:add('Outdated or invalid · ' .. tostring(plan):gsub('[\r\n]', ' '))
  elseif status == 'applied' then v:add('Applied to buffers · save when ready.')
  else v:add('Rejected · source unchanged.') end
  v:add('')
  for _, line in ipairs(U.lines(selected.diff)) do
    local row = v:add(line)
    local group = line:match('^@@') and 'DiffText' or line:match('^%+') and 'DiffAdd' or line:match('^%-') and 'DiffDelete'
    if group then v.highlights[#v.highlights + 1] = { row, group } end
  end
  return v
end
return M
