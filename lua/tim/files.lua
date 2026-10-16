-- File tabs use ordinary buffers, keeping one shared agent pane.
local U = require('tim.util')
local M = {}
M.__index = M
function M.new(ui) return setmetatable({ ui = ui, order = {} }, M) end
function M:track(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= '' then return end
  local path = require('tim.project').relative(self.ui.app.project.root, vim.api.nvim_buf_get_name(buf))
  if path and not vim.tbl_contains(self.order, buf) then self.order[#self.order + 1] = buf end
end
function M:list()
  local result = {}
  for _, buf in ipairs(self.order) do if vim.api.nvim_buf_is_valid(buf) then result[#result + 1] = buf end end
  self.order = result
  return result
end
function M:label()
  local parts = {}
  for _, buf in ipairs(self:list()) do
    local path = require('tim.project').relative(self.ui.app.project.root, vim.api.nvim_buf_get_name(buf)) or vim.api.nvim_buf_get_name(buf)
    parts[#parts + 1] = (buf == self.ui.app.source_buf and '%#TabLineSel#' or '%#TabLine#')
      .. '%' .. buf .. '@v:lua.TimFileTab@ ' .. path:gsub('%%', '%%%%') .. (vim.bo[buf].modified and ' + ' or ' ')
      .. '%X%' .. buf .. '@v:lua.TimCloseFile@× %X'
  end
  return table.concat(parts) .. '%#TabLineFill#%=%@v:lua.TimOpenFile@ + Open file %X'
end
function M:open(buf)
  assert(vim.api.nvim_buf_is_valid(buf), 'File tab is closed')
  local path = require('tim.project').relative(self.ui.app.project.root, vim.api.nvim_buf_get_name(buf))
  self.ui:open_reference({ path = path, line_start = (self.positions or {})[buf] or 1 })
end
function M:cycle(direction)
  local all = self:list()
  for i, buf in ipairs(all) do if buf == self.ui.app.source_buf then self:open(all[(i - 1 + direction) % #all + 1]); return end end
end
function M:close(buf)
  local all = self:list()
  if #all <= 1 then require('tim').quit(); return end
  if vim.bo[buf].modified then
    local choice = vim.fn.confirm('Save changes to ' .. vim.api.nvim_buf_get_name(buf) .. '?', '&Save\n&Discard\n&Cancel', 3)
    if choice == 3 or choice == 0 then return end
    if choice == 1 then vim.api.nvim_buf_call(buf, function() vim.cmd('write') end) end
  end
  if self.ui.app.source_buf == buf then
    for _, other in ipairs(all) do if other ~= buf then self:open(other); break end end
  end
  vim.api.nvim_buf_delete(buf, { force = true })
  self.ui:render()
end
function M:pick()
  vim.ui.select(require('tim.references').files(self.ui.app.project), { prompt = 'Open file' }, function(path)
    if path then
      local ok, err = pcall(function() self.ui:open_reference({ path = path, line_start = 1 }) end)
      if not ok then U.notify(err, vim.log.levels.WARN) end
    end
  end)
end
return M
