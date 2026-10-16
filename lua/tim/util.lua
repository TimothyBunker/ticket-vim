local M = {}
local uv = vim.uv

function M.now()
  local sec, usec = uv.gettimeofday()
  return sec * 1000 + math.floor(usec / 1000)
end

function M.id()
  return vim.fn.sha256(table.concat({ tostring(uv.hrtime()), tostring(uv.os_getpid()), tostring(math.random()) }, ':')):sub(1, 24)
end

function M.read(path)
  local fd, err = io.open(path, 'rb')
  if not fd then return nil, err end
  local value = fd:read('*a')
  fd:close()
  return value
end

function M.json(path, default)
  local raw, err = M.read(path)
  if not raw then
    if not uv.fs_stat(path) then return default end
    error('Cannot read ' .. path .. ': ' .. tostring(err))
  end
  local ok, value = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
  if not ok then error('Invalid JSON in ' .. path .. ' (file preserved): ' .. tostring(value)) end
  return value
end

function M.mkdir(path)
  vim.fn.mkdir(path, 'p', 448)
end

function M.atomic(path, value)
  M.mkdir(vim.fs.dirname(path))
  local temp = path .. '.tmp-' .. M.id()
  local fd, err = uv.fs_open(temp, 'wx', 384)
  assert(fd, err)
  local ok, failure = pcall(function()
    local offset = 0
    while offset < #value do
      local count, write_err = uv.fs_write(fd, value:sub(offset + 1), offset)
      assert(count and count > 0, write_err or 'Short write')
      offset = offset + count
    end
    assert(uv.fs_fsync(fd))
  end)
  uv.fs_close(fd)
  if not ok then uv.fs_unlink(temp); error(failure) end
  local renamed, rename_err = uv.fs_rename(temp, path)
  if not renamed then uv.fs_unlink(temp); error(rename_err) end
end

function M.write_json(path, value)
  M.atomic(path, vim.json.encode(value) .. '\n')
end

function M.run(argv, cwd)
  local ok, result = pcall(function()
    return vim.system(argv, { cwd = cwd, text = true }):wait(2000)
  end)
  if not ok or result.code ~= 0 then return nil end
  local output = (result.stdout or ''):gsub('\n$', '')
  return output
end

function M.lines(text)
  return vim.split(text or '', '\n', { plain = true })
end

function M.message_text(message)
  if type(message.content) == 'string' then return message.content end
  local parts = {}
  for _, part in ipairs(message.content or {}) do
    if part.type == 'text' and type(part.text) == 'string' then parts[#parts + 1] = part.text end
  end
  return table.concat(parts, '\n')
end

function M.notify(message, level)
  vim.notify('tim: ' .. tostring(message), level or vim.log.levels.INFO)
end

return M
