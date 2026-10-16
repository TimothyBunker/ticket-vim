local M = {}
M.__index = M
function M.new(ui) return setmetatable({ ui = ui }, M) end
function M:close() end
function M:open()
  local app = self.ui.app
  assert(app.source_buf or #(app.state.draft.references or {}) > 0, 'Open a file or select code to review')
  app.state.draft.intent = 'review'
  self.ui:compose('ask')
end
return M
