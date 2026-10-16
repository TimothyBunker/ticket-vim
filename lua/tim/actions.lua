-- Only successful results from Tim's own tool names are editor actions.
local M = {}
function M.decode(message)
  local action = type(message.details) == 'table' and message.details.tim
  if message.isError or type(action) ~= 'table' or action.version ~= 1
      or (action.comment_id ~= nil and type(action.comment_id) ~= 'string')
      or type(action.id) ~= 'string' or action.id ~= message.toolCallId then return end
  if action.kind == 'comment' and message.toolName == 'editor_comment'
      and type(action.path) == 'string' and type(action.body) == 'string' and #action.body <= 16384
      and type(action.line_start) == 'number' and action.line_start >= 1 and action.line_start % 1 == 0
      and (not action.line_end or (type(action.line_end) == 'number' and action.line_end >= action.line_start and action.line_end % 1 == 0)) then
    return action
  elseif action.kind == 'proposal' and message.toolName == 'editor_propose_diff'
      and type(action.diff) == 'string' and #action.diff <= 262144 and type(action.title) == 'string' then return action end
end
return M
