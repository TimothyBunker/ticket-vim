-- Native selection controls owned by the agent pane.
local U = require('tim.util')
local M = {}
M.__index = M

function M.new(ui) return setmetatable({ ui = ui }, M) end

function M:close()
  if self.win and vim.api.nvim_win_is_valid(self.win) then vim.api.nvim_win_close(self.win, true) end
  self.win = nil
end

function M:open(lines, title, focus)
  self.ui:dismiss_popups()
  self:close()
  self.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = false
  local width = math.max(25, math.min(76, vim.o.columns - 6))
  self.win = vim.api.nvim_open_win(self.buf, focus, { relative = 'editor',
    row = math.max(1, math.floor(vim.o.lines * 0.2)), col = math.max(0, vim.o.columns - width - 3),
    width = width, height = math.min(#lines, math.max(3, vim.o.lines - 8)),
    style = 'minimal', border = 'rounded', title = ' ' .. title .. ' ', title_pos = 'left' })
  vim.wo[self.win].wrap = false
  for _, key in ipairs({ '<CR>', '<Space>' }) do
    vim.keymap.set('n', key, function() self:click(vim.api.nvim_win_get_cursor(0)[1], vim.api.nvim_win_get_cursor(0)[2] + 1) end,
      { buffer = self.buf, nowait = true })
  end
  for _, key in ipairs({ '<Esc>', 'q' }) do
    vim.keymap.set(key == '<Esc>' and { 'n', 'i', 'x' } or 'n', key, function() vim.cmd('stopinsert'); self:close() end, { buffer = self.buf, nowait = true })
  end
end

function M:picker(after)
  self.after = after
  local app = self.ui.app
  assert(app.source_buf and vim.api.nvim_buf_is_valid(app.source_buf), 'Open a file to select lines')
  self.kind = 'picker'; self.source = app.source_buf; self.path = app.source_path
  self.tick = vim.api.nvim_buf_get_changedtick(self.source)
  self.lines = vim.api.nvim_buf_get_lines(self.source, 0, -1, false)
  self.checked = {}
  for _, ref in ipairs(app.state.draft.references or {}) do
    if ref.path == self.path then
      for row = ref.line_start or 1, ref.line_end or ref.line_start or 1 do self.checked[row] = true end
    end
  end
  self:open(self:picker_lines(), 'Select lines · click or Space to toggle', true)
end

function M:picker_lines()
  local lines = { '[Use selection]  [Cancel]', self.path }
  for row, line in ipairs(self.lines) do
    lines[#lines + 1] = string.format('[%s] %4d  %s', self.checked[row] and 'x' or ' ', row, line)
  end
  return lines
end

function M:click(row, col)
  local ok, err = pcall(function()
    if row == 1 then
      if col >= 18 then self:close(); return end
      assert(vim.api.nvim_buf_is_valid(self.source)
        and self.ui.app.source_buf == self.source
        and vim.api.nvim_buf_get_changedtick(self.source) == self.tick,
        'File changed while selecting; reopen Select lines')
      local refs, first = {}, nil
      for line = 1, #self.lines + 1 do
        if self.checked[line] then first = first or line
        elseif first then refs[#refs + 1] = self.ui.app:capture(first, line - 1); first = nil end
      end
      assert(#refs <= 12, 'Select at most 12 separate ranges')
      assert(not self.after or #refs > 0, 'Select at least one line for the comment')
      local after = self.after
      self:close(); self.ui:set_selection(refs)
      if after then self.ui:compose(after) else self.ui:show(false, true) end
    elseif row >= 3 then
      local line = row - 2
      self.checked[line] = not self.checked[line]
      vim.bo[self.buf].modifiable = true
      vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, self:picker_lines())
      vim.bo[self.buf].modifiable = false
    end
  end)
  if not ok then U.notify(err, vim.log.levels.WARN) end
end

return M
