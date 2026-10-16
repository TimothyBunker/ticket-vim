-- Strict unified diffs against existing editor buffers; never execute model text.
local P = require('tim.project')
local U = require('tim.util')
local M = {}

function M.extract(text)
  local result = {}
  for diff in (text .. '\n'):gmatch('```diff%s*\n(.-)\n```') do result[#result + 1] = diff end
  return result
end

function M.prepare(project, diff)
  local lines, index, files, seen = U.lines(diff), 1, {}, {}
  while index <= #lines do
    local line = lines[index]
    if line:match('^diff %-%-git ') or line:match('^index ') or line == '' then index = index + 1
    else
      local old = line:match('^%-%-%- a/(.+)$')
      local new = (lines[index + 1] or ''):match('^%+%+%+ b/(.+)$')
      assert(old and new and old == new, 'Only unified diffs for existing files are supported (--- a/path, +++ b/path)')
      local full, path = P.resolve(project.root, old)
      assert(full, path)
      assert(not seen[path], 'Duplicate file section: ' .. path); seen[path] = true
      local stat = vim.uv.fs_stat(full)
      assert(stat and stat.type == 'file', 'Patch target must be an existing file: ' .. path)
      assert(stat.size <= 1024 * 1024, 'Patch target exceeds 1 MB')
      local buf = vim.fn.bufadd(full); vim.fn.bufload(buf)
      assert(vim.bo[buf].modifiable and not vim.bo[buf].readonly, 'File is read-only: ' .. path)
      local original = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local base = original
      if stat.size == 0 and not vim.bo[buf].modified and #original == 1 and original[1] == '' then base = {} end
      local output, consumed, hunks = {}, 0, 0
      index = index + 2
      while index <= #lines and lines[index]:match('^@@') do
        local a, ac, b, bc = lines[index]:match('^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@')
        assert(a, 'Invalid hunk header')
        a, b, ac, bc = tonumber(a), tonumber(b), tonumber(ac) or 1, tonumber(bc) or 1
        local start = ac == 0 and a + 1 or a
        assert(start > consumed and start <= #base + 1, 'Overlapping or invalid hunk in ' .. path)
        for row = consumed + 1, start - 1 do output[#output + 1] = base[row] end
        assert((bc == 0 and b + 1 or b) == #output + 1, 'Inconsistent new hunk position in ' .. path)
        consumed = start - 1
        local removed, added = 0, 0
        index = index + 1
        while removed < ac or added < bc do
          local body = assert(lines[index], 'Incomplete patch')
          local tag, text = body:sub(1, 1), body:sub(2)
          assert(tag == ' ' or tag == '-' or tag == '+', 'Unsupported patch line')
          if tag ~= '+' then
            assert(removed < ac and base[consumed + 1] == text, 'Patch does not match current buffer: ' .. path)
            consumed = consumed + 1; removed = removed + 1
          end
          if tag ~= '-' then
            assert(added < bc, 'Invalid added-line count'); output[#output + 1] = text; added = added + 1
          end
          index = index + 1
        end
        hunks = hunks + 1
      end
      assert(hunks > 0, 'No changes for ' .. path)
      for row = consumed + 1, #base do output[#output + 1] = base[row] end
      files[#files + 1] = { path = path, buf = buf, base = original, output = output,
        tick = vim.api.nvim_buf_get_changedtick(buf), modified = vim.bo[buf].modified }
    end
  end
  assert(#files > 0, 'No supported changes found')
  return files
end

function M.apply(files)
  for _, file in ipairs(files) do
    assert(vim.api.nvim_buf_is_valid(file.buf) and vim.api.nvim_buf_is_loaded(file.buf)
      and vim.api.nvim_buf_get_changedtick(file.buf) == file.tick
      and vim.deep_equal(vim.api.nvim_buf_get_lines(file.buf, 0, -1, false), file.base),
      'File changed since preview; reopen the diff: ' .. file.path)
    assert(vim.bo[file.buf].modifiable and not vim.bo[file.buf].readonly, 'File is read-only: ' .. file.path)
  end
  local applied = {}
  local ok, err = pcall(function()
    for _, file in ipairs(files) do
      vim.api.nvim_buf_set_lines(file.buf, 0, -1, false, file.output)
      applied[#applied + 1] = file
    end
  end)
  if not ok then
    for _, file in ipairs(applied) do
      vim.api.nvim_buf_set_lines(file.buf, 0, -1, false, file.base)
      vim.bo[file.buf].modified = file.modified
    end
    error(err)
  end
end
return M
