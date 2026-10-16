-- Optional, read-only legacy context discovery. No TicketBunker process or UI.
local U = require('tim.util')
local M = {}

function M.discover(root, git)
  local result = { tickets = {} }
  local ok, locator = pcall(U.json, root .. '/.ticketbunker.json', {})
  if not ok then result.warning = locator; return result end
  if type(locator) ~= 'table' then return result end
  result.project = locator.project
  result.bunker_id = locator.bunker_id
  result.repository_id = locator.repository_id
  local paths = vim.fn.glob(root .. '/.tb/*_bunker/ticket.json', false, true)
  if type(locator.project) == 'string' and locator.project:match('^[%w_.%-]+$') then
    vim.list_extend(paths, vim.fn.glob(root .. '/.tb/data/projects/' .. locator.project .. '/tickets/*/ticket.json', false, true))
  end
  for _, path in ipairs(paths) do
    local valid, ticket = pcall(U.json, path, {})
    if valid and type(ticket) == 'table' and type(ticket.id) == 'string' then
      local branches = ticket.assigned_branches or {}
      local good, resolution = pcall(U.json, vim.fs.dirname(path) .. '/observations/branch_resolution.json', {})
      if good and type(resolution) == 'table' then branches = resolution.branches or branches end
      for _, branch in ipairs(type(branches) == 'table' and branches or {}) do
        if branch == git.branch then
          result.tickets[#result.tickets + 1] = { id = ticket.id, title = ticket.title,
            branch = branch, source_record = path, source = 'ticketbunker-legacy' }
          break
        end
      end
    end
  end
  return result
end

function M.import(path, project)
  local raw = assert(U.read(path), 'Cannot read import file')
  assert(#raw <= 8 * 1024 * 1024, 'Import exceeds 8 MB')
  local records = {}
  for number, line in ipairs(U.lines(raw)) do
    if line ~= '' then
      local ok, item = pcall(vim.json.decode, line)
      assert(ok and type(item) == 'table', 'Invalid import JSON at line ' .. number)
      local message = item.type == 'message' and item.message or item
      if message and (message.role == 'user' or message.role == 'assistant') then
        local body = message.text or U.message_text(message)
        assert(type(body) == 'string', 'Invalid imported message text')
        local refs = {}
        local ref = message.reference or item.reference
        if type(ref) == 'table' and type(ref.path) == 'string' then
          local _, relative = require('tim.project').resolve(project.root, ref.path)
          local full = require('tim.project').resolve(project.root, ref.path)
          assert(full, relative)
          assert(not ref.line_start or type(ref.line_start) == 'number' and ref.line_start >= 1, 'Invalid imported line')
          assert(not ref.line_end or type(ref.line_end) == 'number' and ref.line_end >= (ref.line_start or 1), 'Invalid imported range')
          refs[#refs + 1] = { kind = ref.kind, category = ref.category, path = relative,
            line_start = ref.line_start or 1, line_end = ref.line_end or ref.line_start or 1,
            text = ref.text, unsaved = ref.unsaved, branch = ref.branch }
        elseif type(item.path) == 'string' and item.path ~= '' then
          local full, relative = require('tim.project').resolve(project.root, item.path)
          assert(full, relative)
          refs[#refs + 1] = { path = relative, line_start = 1 }
        end
        if #refs == 0 then
          for _, mention in ipairs(require('tim.references').parse(body)) do
            local full, relative = require('tim.project').resolve(project.root, mention.path)
            if full then refs[#refs + 1] = { path = relative, line_start = mention.line_start or 1 } end
          end
        end
        records[#records + 1] = { id = 'import-' .. vim.fn.sha256(path .. ':' .. number .. ':' .. line):sub(1, 24),
          role = message.role, kind = 'import', text = body, references = refs,
          created_at = 0, timestamp = item.created_at or item.timestamp,
          origin = { path = path, line = number, original_id = item.id, scope = item.scope },
          git = { branch = ref and ref.branch or item.scope }, imported = true }
      end
    end
  end
  assert(#records > 0, 'No user or assistant messages found in JSONL import')
  return records
end

return M
