local U = require('tim.util')
local M = {}

function M.items(state)
  local result, by_id, chain, matched, persisted = {}, {}, {}, {}, {}
  for _, entry in ipairs(state.entries or {}) do
    by_id[entry.id] = entry
    if entry.type == 'message' and entry.message and entry.message.role == 'user' then
      local request_id = U.message_text(entry.message):match('<!%-%- tim:([a-f0-9]+) %-%->')
      if request_id then persisted[request_id] = true end
    end
  end
  local id = state.leaf_id
  while id and by_id[id] and not chain[id] do
    chain[id] = true
    id = by_id[id].parentId
  end
  local request, parent_refs
  for _, entry in ipairs(state.entries or {}) do
    if chain[entry.id] and entry.type == 'message' then
      local msg = entry.message or {}
      local text = U.message_text(msg)
      if msg.role == 'user' then
        request = nil
        local request_id = text:match('<!%-%- tim:([a-f0-9]+) %-%->')
        for _, candidate in ipairs(state.requests or {}) do
          if candidate.id == request_id then request = candidate; matched[candidate.id] = true; break end
        end
        parent_refs = request and request.references or {}
        result[#result + 1] = { id = request and request.id or entry.id, pi_entry_id = entry.id, role = 'user', kind = 'question',
          text = request and request.text or text, references = parent_refs,
          git = request and request.git, status = request and request.status, error = request and request.error, intent = request and request.intent,
          request_id = request and request.id, comment_policy = request and request.comment_policy, current_file = request and request.current_file,
          thread_id = request and request.thread_id, created_at = request and request.created_at or 0,
          timestamp = entry.timestamp, order = #result + 1 }
      elseif msg.role == 'toolResult' and require('tim.actions').decode(msg) then
        local action = require('tim.actions').decode(msg)
        result[#result + 1] = { id = entry.id, pi_entry_id = entry.id, role = 'assistant', kind = 'editor_action',
          editor_action = action, text = action.kind == 'comment' and action.body or action.title,
          references = vim.deepcopy(parent_refs or {}), current_file = request and request.current_file,
          git = request and request.git, intent = request and request.intent, request_id = request and request.id,
          instruction = request and request.text, thread_id = request and request.thread_id,
          comment_policy = request and request.comment_policy, created_at = request and request.created_at or 0,
          timestamp = entry.timestamp, order = #result + 1 }
      elseif msg.role == 'assistant' and text ~= '' then
        local refs = vim.deepcopy(parent_refs or {})
        for _, ref in ipairs(require('tim.references').parse(text)) do refs[#refs + 1] = ref end
        result[#result + 1] = { id = entry.id, pi_entry_id = entry.id, role = 'assistant', kind = 'reply',
          text = text, references = refs, citations = require('tim.references').parse(text),
          current_file = request and request.current_file, git = request and request.git,
          intent = request and request.intent, request_id = request and request.id,
          instruction = request and request.text, comment_policy = request and request.comment_policy,
          thread_id = request and request.thread_id, created_at = request and request.created_at or 0,
          timestamp = entry.timestamp, order = #result + 1 }
      end
    end
  end
  for _, request_item in ipairs(state.requests or {}) do
    if not matched[request_item.id] and not persisted[request_item.id] then
      local item = vim.deepcopy(request_item)
      item.role = 'user'; item.kind = 'question'; item.order = #result + 1
      result[#result + 1] = item
    end
  end
  for _, note in ipairs(state.notes or {}) do
    local item = vim.deepcopy(note); item.kind = 'comment'; item.role = item.role or 'user'; item.order = #result + 1
    result[#result + 1] = item
  end
  for _, imported in ipairs(state.imports or {}) do
    local item = vim.deepcopy(imported); item.order = #result + 1
    result[#result + 1] = item
  end
  table.sort(result, function(a, b)
    if a.created_at == b.created_at then return a.order < b.order end
    return (a.created_at or 0) < (b.created_at or 0)
  end)
  return result
end

function M.filter(items, path, thread)
  local result = {}
  for _, item in ipairs(items) do
    local matches = not path
    for _, ref in ipairs(item.references or {}) do if ref.path == path then matches = true end end
    if matches and (not thread or item.thread_id == thread or item.id == thread) then result[#result + 1] = item end
  end
  return result
end

return M
