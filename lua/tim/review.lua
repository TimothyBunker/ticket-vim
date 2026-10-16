local U = require('tim.util')
local M = {}
M.__index = M
function M.new(ui) return setmetatable({ ui = ui }, M) end
function M:close()
  if self.win and vim.api.nvim_win_is_valid(self.win) then vim.api.nvim_win_close(self.win, true) end
  self.win = nil
end
function M:show(title, lines, actions, filetype)
  self.ui:dismiss_popups()
  self:close(); self.actions = actions
  self.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buf].bufhidden = 'wipe'
  vim.bo[self.buf].filetype = filetype or 'markdown'
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = false
  local width = math.max(25, math.min(90, vim.o.columns - 6))
  self.win = vim.api.nvim_open_win(self.buf, true, { relative = 'editor', border = 'rounded',
    row = 2, col = math.max(0, math.floor((vim.o.columns - width) / 2)), width = width,
    height = math.max(3, math.min(vim.o.lines - 7, #lines)), style = 'minimal', title = ' ' .. title .. ' ' })
  vim.wo[self.win].wrap = filetype ~= 'diff'
  if filetype == 'diff' then
    local namespace = vim.api.nvim_create_namespace('tim-diff-preview')
    for row, line in ipairs(lines) do
      local group = line:match('^@@') and 'DiffText'
        or (line:match('^%+') and 'DiffAdd') or (line:match('^%-') and 'DiffDelete')
      if group then
        vim.api.nvim_buf_set_extmark(self.buf, namespace, row - 1, 0, { line_hl_group = group })
      end
    end
  end
  for _, key in ipairs({ 'q', '<Esc>' }) do vim.keymap.set(key == '<Esc>' and { 'n', 'i', 'x' } or 'n', key, function() vim.cmd('stopinsert'); self:close() end, { buffer = self.buf }) end
  vim.keymap.set('n', '<CR>', function()
    local at = vim.api.nvim_win_get_cursor(0); self:click(at[1], at[2] + 1)
  end, { buffer = self.buf })
end
function M:click(row, col)
  if row ~= 1 then return end
  for _, action in ipairs(self.actions or {}) do
    if col >= action[1] and col <= action[2] then
      local ok, err = pcall(action[3])
      if not ok then U.notify(err, vim.log.levels.ERROR) end
      return
    end
  end
end
function M:selection()
  local lines = { '[Clear selection]  [Close]', '' }
  for _, ref in ipairs(self.ui.app.state.draft.references or {}) do
    lines[#lines + 1] = require('tim.references').label(ref)
    vim.list_extend(lines, U.lines(ref.selection_text or ref.text or ''))
    lines[#lines + 1] = ''
  end
  self:show('Selected context', lines, {
    { 1, 18, function() self:close(); self.ui:set_selection({}) end },
    { 19, 1000, function() self:close() end },
  })
end
function M:patch(diff, entry)
  for _, proposal in ipairs(self.ui.app.all_proposals or {}) do
    if proposal.entry_id == entry and proposal.diff == diff then self.ui.selected_proposal = proposal.id; break end
  end
  self.ui:set_view('diffs')
end
function M:proposals(proposals)
  if proposals[1] then self.ui.selected_proposal = proposals[1].id end
  self.ui:set_view('diffs')
end
function M:annotation(note)
  self.ui.selected_comment = note.id
  self.ui:set_view('comments')
end
return M
