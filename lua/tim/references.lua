local U = require('tim.util')
local P = require('tim.project')
local M = {}

-- Parse mentions outside fenced/inline code. Offsets are UTF-8 byte offsets,
-- matching Neovim columns. Brackets allow spaces and Unicode in a path.
function M.parse(text)
  local result, index, fence, ticks = {}, 1, false, false
  while index <= #text do
    if text:sub(index, index + 2) == '```' then
      fence = not fence; index = index + 3
    elseif text:sub(index, index) == '`' and not fence then
      ticks = not ticks; index = index + 1
    elseif not fence and not ticks and text:sub(index, index) == '[' then
      local label, target = text:sub(index):match('^%[([^%]]+)%]%(([^%)]+)%)')
      if label and not target:match('^%a[%w+.-]*://') then
        local path, number = target:match('^(.-)#L(%d+)$')
        if not path then path, number = target:match('^(.-):(%d+)$') end
        path = (path or target):gsub('%%20', ' ')
        local length = #label + #target + 4
        if path ~= '' and (not number or tonumber(number) > 0) then
          result[#result + 1] = { path = path, line_start = tonumber(number), start_col = index - 1, end_col = index + length - 1 }
        end
        index = index + length
      else index = index + 1 end
    elseif not fence and not ticks and text:sub(index, index) == '@'
      and (index == 1 or text:sub(index - 1, index - 1):match('[%s(]')) then
      local rest = text:sub(index + 1)
      local path, consumed
      if rest:sub(1, 1) == '[' then
        local close = rest:find(']', 2, true)
        if close then path = rest:sub(2, close - 1); consumed = close end
      else
        path = rest:match('^([%w_./\\%-]+)')
        if path then path = path:gsub('[.,;]+$', ''); consumed = #path end
      end
      if path and (path:find('[/\\.]') or rest:sub(1, 1) == '[') then
        local suffix = rest:sub(consumed + 1)
        local number = suffix:match('^:(%d+)')
        if number then consumed = consumed + 1 + #number end
        local last = number and rest:sub(consumed + 1):match('^%-(%d+)')
        if last then consumed = consumed + 1 + #last end
        local column = number and not last and rest:sub(consumed + 1):match('^:(%d+)')
        if column then consumed = consumed + 1 + #column end
        if (not number or tonumber(number) > 0) and (not last or tonumber(last) >= tonumber(number)) then
          result[#result + 1] = { path = path, line_start = number and tonumber(number) or nil, line_end = tonumber(last), column_start = tonumber(column),
            start_col = index - 1, end_col = index + consumed }
        end
        index = index + consumed + 1
      else index = index + 1 end
    else index = index + 1 end
  end
  return result
end

function M.label(ref)
  local label = '@[' .. ref.path .. ']:' .. (ref.line_start or 1)
  if ref.column_start then label = label .. ':' .. ref.column_start end
  return label
end

function M.capture(project, path, first, last, buf, opts)
  opts = opts or {}
  local full, relative = P.resolve(project.root, path)
  assert(full, relative)
  buf = buf or vim.fn.bufnr(full)
  local lines, unsaved
  if buf > 0 and vim.api.nvim_buf_is_loaded(buf) then
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    unsaved = vim.bo[buf].modified
  else
    local stat = vim.uv.fs_stat(full)
    assert(stat and stat.type == 'file', 'Missing source: ' .. relative)
    assert(stat.size <= 2 * 1024 * 1024, 'Source is too large; select a range in an open buffer')
    local raw = assert(U.read(full))
    assert(not raw:find('%z'), 'Cannot attach a binary file')
    lines = U.lines(raw:gsub('\r\n', '\n'))
    if lines[#lines] == '' and #lines > 1 then table.remove(lines) end
  end
  local whole = not first
  first = first or 1
  last = last or (whole and (opts.full and #lines or math.min(#lines, 200)) or first)
  assert(first >= 1 and first <= #lines and last >= first and last <= #lines, 'Reference line is outside ' .. relative)
  local excerpt = table.concat(vim.list_slice(lines, first, last), '\n')
  assert(#excerpt <= (opts.full and 256 * 1024 or 24000), opts.full
    and 'Current file exceeds 256 KB; question was not sent' or 'Source excerpt is too large; select fewer lines')
  local hash = vim.fn.sha256(table.concat(lines, '\n'))
  local disk = vim.uv.fs_stat(full)
  if disk and disk.size <= 2 * 1024 * 1024 then
    local raw = U.read(full)
    if raw then
      local normalized = raw:gsub('\r\n', '\n'):gsub('\n$', '')
      unsaved = unsaved or vim.fn.sha256(normalized) ~= hash
    end
  end
  return { kind = 'source', category = 'file', path = relative, line_start = first, line_end = last,
    text = excerpt, unsaved = unsaved or false, hash = hash,
    truncated = whole and last < #lines or false, git = P.context(project), created_at = U.now() }
end

-- Store line snapshots for relocation and byte columns for exact text focus.
-- Columns are one-based UTF-8 bytes; column_end is exclusive.
function M.selection(project, path, buf, first, last, mode)
  assert(mode == 'v' or mode == 'V', 'Use a text or whole-line selection for a question/comment')
  first, last = vim.deepcopy(first), vim.deepcopy(last)
  if first[1] == 0 then first[1] = buf end
  if last[1] == 0 then last[1] = buf end
  local opts = { type = mode, exclusive = vim.o.selection == 'exclusive', eol = true }
  local regions = vim.fn.getregionpos(first, last, opts)
  local text = vim.fn.getregion(first, last, opts)
  assert(#regions > 0, 'Select text in the current file')
  local start, finish = regions[1][1], regions[#regions][2]
  local ref = M.capture(project, path, start[2], finish[2], buf)
  if mode == 'v' then
    ref.column_start = math.max(1, start[3])
    ref.column_end = math.max(1, regions[#regions][1][3]) + #text[#text]
    ref.selection_text = table.concat(text, '\n')
  end
  return ref
end

function M.locate(ref, lines)
  if ref.hash and ref.hash == vim.fn.sha256(table.concat(lines, '\n'))
      and (ref.line_start or 1) <= #lines then return ref.line_start or 1, 'exact' end
  if not ref.text or ref.text == '' then return ref.line_start or 1, 'unverified' end
  local needle = U.lines(ref.text)
  local matches = {}
  for first = 1, #lines - #needle + 1 do
    local equal = true
    for offset, line in ipairs(needle) do if lines[first + offset - 1] ~= line then equal = false; break end end
    if equal then matches[#matches + 1] = first end
  end
  if #matches == 1 then return matches[1], matches[1] == ref.line_start and 'exact' or 'moved' end
  if #matches > 1 then return nil, 'ambiguous' end
  return nil, 'changed'
end

function M.files(project)
  local raw = U.run({ 'git', '-C', project.root, 'ls-files', '-co', '--exclude-standard', '-z' })
  local result, seen = {}, {}
  if raw then
    for _, path in ipairs(vim.split(raw, '\0', { plain = true })) do
      if path ~= '' and not path:find('[\r\n]') and not seen[path] then result[#result + 1] = path; seen[path] = true end
    end
  else
    local function walk(dir, prefix, depth)
      if depth > 8 or #result >= 3000 then return end
      for name, kind in vim.fs.dir(dir) do
        if name:sub(1, 1) ~= '.' and name ~= 'node_modules' then
          local path = prefix .. name
          if kind == 'file' then result[#result + 1] = path
          elseif kind == 'directory' then walk(dir .. '/' .. name, path .. '/', depth + 1) end
        end
        if #result >= 3000 then break end
      end
    end
    walk(project.root, '', 0)
  end
  table.sort(result)
  return result
end

return M
