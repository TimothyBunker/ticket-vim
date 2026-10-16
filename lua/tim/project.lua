local U = require('tim.util')
local M = {}

function M.discover(start)
  start = vim.fs.normalize(start or vim.fn.getcwd())
  if vim.fn.isdirectory(start) == 0 then start = vim.fs.dirname(start) end
  start = vim.uv.fs_realpath(start) or start
  local root = U.run({ 'git', '-C', start, 'rev-parse', '--show-toplevel' }) or start
  root = vim.uv.fs_realpath(root) or root
  local common = U.run({ 'git', '-C', root, 'rev-parse', '--path-format=absolute', '--git-common-dir' })
  return {
    root = root,
    id = vim.fn.sha256(root):sub(1, 24),
    repository_id = vim.fn.sha256(common or root):sub(1, 24),
    worktree_id = vim.fn.sha256(root):sub(1, 24),
  }
end

function M.context(project)
  local ref = U.run({ 'git', '-C', project.root, 'symbolic-ref', '--quiet', 'HEAD' })
  local head = U.run({ 'git', '-C', project.root, 'rev-parse', '--verify', 'HEAD' })
  local status = U.run({ 'git', '-C', project.root, 'status', '--porcelain', '--untracked-files=normal' })
  return {
    repository_id = project.repository_id, worktree_id = project.worktree_id,
    ref = ref, branch = ref and ref:gsub('^refs/heads/', '') or nil,
    head = head, dirty = status and status ~= '' or false,
    is_git = ref ~= nil or head ~= nil or status ~= nil,
  }
end

function M.relative(root, path)
  path = vim.fs.normalize(path)
  root = vim.fs.normalize(root)
  if path:sub(1, #root + 1) ~= root .. '/' then return nil end
  return path:sub(#root + 2)
end

function M.resolve(root, path)
  if type(path) ~= 'string' or path:find('%z') then return nil, 'Invalid file reference' end
  path = path:gsub('\\', '/')
  if path:sub(1, 1) == '/' or path:match('^%a:') then return nil, 'Use a project-relative file path' end
  local parts = {}
  for part in path:gmatch('[^/]+') do
    if part == '..' then return nil, 'Reference leaves the project' end
    if part ~= '.' then parts[#parts + 1] = part end
  end
  if #parts == 0 then return nil, 'Empty file reference' end
  path = table.concat(parts, '/')
  local full = root .. '/' .. path
  -- Check the existing ancestor too, so a new file under an escaping symlink
  -- cannot become a project-local reference.
  local ancestor = full
  while not vim.uv.fs_stat(ancestor) and ancestor ~= root do ancestor = vim.fs.dirname(ancestor) end
  local real = vim.uv.fs_realpath(ancestor)
  if real and real ~= root and not M.relative(root, real) then return nil, 'Reference resolves outside the project' end
  return full, path
end

return M
