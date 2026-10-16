-- Explicit human decisions; agent tools cannot call these operations.
local U = require('tim.util')
local P = require('tim.project')
local M = {}
local function record(app, kind, proposal, files)
  app.state.work[#app.state.work + 1] = { id = U.id(), kind = kind, actor_role = 'user',
    proposal_id = proposal.id, proposal_entry = proposal.entry_id, files = files,
    paths = vim.tbl_map(function(file) return file.path end, files or {}), git = app:context(), created_at = U.now() }
  require('tim.annotations').refresh(app); app:save(); app:changed()
end
function M.apply(app, proposal, preview)
  assert(proposal.status == 'pending', 'This proposal is no longer pending')
  assert((proposal.git or {}).branch == (app:context() or {}).branch, 'Branch changed; refresh the proposal')
  assert(preview, 'Open the diff before approving it')
  require('tim.patches').apply(preview) -- exact content + changedtick from the displayed preview
  local files = vim.tbl_map(function(file) return { path = file.path, before = file.base, after = file.output } end, preview)
  record(app, 'proposal_applied', proposal, files)
  app.status = 'Applied to buffers · save when ready'
end
function M.reject(app, proposal)
  assert(proposal.status == 'pending', 'This proposal is no longer pending')
  record(app, 'proposal_rejected', proposal)
  app.status = 'Proposal rejected'
end
function M.undo(app, proposal)
  assert(proposal.status == 'applied', 'Only applied proposals can be undone')
  assert((proposal.git or {}).branch == (app:context() or {}).branch, 'Branch changed; cannot undo this proposal here')
  local event
  for _, work in ipairs(app.state.work) do if work.proposal_id == proposal.id and work.kind == 'proposal_applied' then event = work end end
  assert(event and event.files, 'This older proposal has no stored undo snapshot; use the source buffer undo history')
  local plans = {}
  for _, file in ipairs(event.files) do
    local full, err = P.resolve(app.project.root, file.path); assert(full, err)
    local buf = vim.fn.bufadd(full); vim.fn.bufload(buf)
    assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), file.after), 'File has changed since Apply; undo would overwrite newer work: ' .. file.path)
    plans[#plans + 1] = { buf = buf, path = file.path, base = file.after, output = file.before, tick = vim.api.nvim_buf_get_changedtick(buf) }
  end
  require('tim.patches').apply(plans)
  record(app, 'proposal_undone', proposal)
  app.status = 'Application undone · buffers remain unsaved'
end
return M
