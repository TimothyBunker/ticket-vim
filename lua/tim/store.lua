local U = require('tim.util')
local M = {}

local function lock(path)
  local token = U.id()
  local ok = vim.uv.fs_mkdir(path, 448)
  if not ok then
    local owner = U.json(path .. '/owner.json', nil)
    if owner and owner.pid and not vim.uv.kill(owner.pid, 0) then
      vim.uv.fs_unlink(path .. '/owner.json')
      vim.uv.fs_rmdir(path)
      ok = vim.uv.fs_mkdir(path, 448)
    end
    if not ok then error('Session is open in another editor (lock: ' .. path .. ')') end
  end
  U.write_json(path .. '/owner.json', { pid = vim.uv.os_getpid(), token = token })
  return function()
    local owner = U.json(path .. '/owner.json', {})
    if owner.token == token then
      vim.uv.fs_unlink(path .. '/owner.json')
      vim.uv.fs_rmdir(path)
    end
  end
end

function M.directory(project, data_dir)
  return (data_dir or vim.env.TIM_DATA_DIR or (vim.fn.stdpath('data') .. '/tim')) .. '/projects/' .. project.id
end

function M.touch(state, git)
  state.last_used_at = U.now()
  state.git = git
  state.branch_usage = state.branch_usage or {}
  if git.ref then state.branch_usage[git.ref] = state.last_used_at end
end

function M.list(project, data_dir)
  local root = M.directory(project, data_dir)
  local result = {}
  for _, path in ipairs(vim.fn.glob(root .. '/sessions/*/state.json', false, true)) do
    local value = U.json(path)
    if type(value) ~= 'table' or value.schema_version ~= 1 or not value.id then
      error('Unsupported session data: ' .. path)
    end
    result[#result + 1] = { state = value, path = path }
  end
  table.sort(result, function(a, b)
    if a.state.last_used_at == b.state.last_used_at then return a.state.id > b.state.id end
    return a.state.last_used_at > b.state.last_used_at
  end)
  return result
end

-- The selected default is independent of activity timestamps.
function M.default(project, data_dir)
  return U.json(M.directory(project, data_dir) .. '/preferences.json', {}).default_session_id
end

function M.has_selection(project, opts)
  if opts.name and vim.trim(opts.name) ~= '' then return true end
  local default = M.default(project, opts.data_dir)
  local git = opts.branch_filter and require('tim.project').context(project) or {}
  for _, item in ipairs(M.list(project, opts.data_dir)) do
    if opts.branch_filter then
      if git.ref and (item.state.branch_usage or {})[git.ref] then return true end
    elseif item.state.id == default then return true end
  end
  return false
end

function M.open(project, opts)
  local root = M.directory(project, opts.data_dir)
  U.mkdir(root .. '/sessions')
  local release_project = lock(root .. '/catalog.lock')
  local ok, result = pcall(function()
    local selected
    if opts.name then assert(vim.trim(opts.name) ~= '', 'Enter a session name') end
    local default = M.default(project, opts.data_dir)
    local git = require('tim.project').context(project)
    if opts.branch_filter and not git.branch then error('--branch needs a checked-out Git branch') end
    local sessions = M.list(project, opts.data_dir)
    if opts.branch_filter and not opts.name then
      table.sort(sessions, function(a, b)
        local left = (a.state.branch_usage or {})[git.ref] or 0
        local right = (b.state.branch_usage or {})[git.ref] or 0
        if left == right then return a.state.id > b.state.id end
        return left > right
      end)
    end
    for _, item in ipairs(sessions) do
      local matches = opts.name and item.state.name == opts.name
        or not opts.name and (opts.branch_filter and (item.state.branch_usage or {})[git.ref]
          or not opts.branch_filter and item.state.id == default)
      if matches then selected = item; break end
    end
    if not selected then
      assert(opts.name, 'Choose a session name with tim -s NAME')
      local id = U.id()
      selected = { path = root .. '/sessions/' .. id .. '/state.json', state = {
        schema_version = 1, id = id, name = opts.name,
        project = project, created_at = U.now(), last_used_at = U.now(),
        notes = {}, requests = {}, entries = {}, imports = {}, work = {},
        git = git, draft = { text = '', references = {}, mode = 'ask' },
      } }
    end
    U.mkdir(vim.fs.dirname(selected.path))
    selected.release = lock(vim.fs.dirname(selected.path) .. '/writer.lock')
    local saved, err = pcall(function()
      M.touch(selected.state, git)
      selected.dir = vim.fs.dirname(selected.path)
      selected.state.pi_session = selected.state.pi_session or (selected.dir .. '/pi.jsonl')
      U.write_json(selected.path, selected.state)
      if opts.name then
        U.write_json(root .. '/preferences.json', { default_session_id = selected.state.id })
      end
    end)
    if not saved then selected.release(); error(err) end
    return selected
  end)
  release_project()
  if not ok then error(result) end
  return result
end

function M.save(handle)
  U.write_json(handle.path, handle.state)
end

function M.read_pi(path)
  local raw = U.read(path)
  if not raw then return {}, nil end
  local entries, leaf = {}, nil
  local lines = U.lines(raw)
  for index, line in ipairs(lines) do
    if line ~= '' then
      local ok, value = pcall(vim.json.decode, line)
      if not ok then
        if index == #lines and raw:sub(-1) ~= '\n' then break end
        error('Invalid Pi history record ' .. index .. ' in ' .. path)
      end
      if value.type ~= 'session' and value.id then entries[#entries + 1] = value; leaf = value.id end
    end
  end
  return entries, leaf
end

return M
