local U = require('tim.util')
local R = require('tim.references')
local P = require('tim.project')
local M = {}

function M.refresh(app)
  app.state.annotations = app.state.annotations or {}
  local active, present = {}, {}
  app.action_errors, app.action_error_entries = {}, {}
  local items = require('tim.history').items(app.state)
  for _, item in ipairs(items) do
    if item.role == 'assistant' then
      for index, citation in ipairs(item.citations or {}) do
        if citation.line_start and P.resolve(app.project.root, citation.path) then
          local id = item.id .. ':' .. index
          local annotation = app.state.annotations[id]
          local before = item.text:sub(1, citation.start_col)
          local prefix = before:match('([^\n]*)$') or ''
          local explicit = item.comment_policy == 'explicit' and prefix:match('^%s*Comment:%s*$')
          if not annotation and explicit then
            local ref
            local candidates = { item.current_file or {} }
            vim.list_extend(candidates, item.references or {})
            for _, source in ipairs(candidates) do
              if source.path == citation.path and source.text and source.line_start <= citation.line_start
                  and (source.line_end or source.line_start) >= (citation.line_end or citation.line_start) then
                ref = vim.deepcopy(citation)
                ref.line_end = citation.line_end or citation.line_start
                ref.text = table.concat(vim.list_slice(U.lines(source.text), ref.line_start - source.line_start + 1,
                  ref.line_end - source.line_start + 1), '\n')
                ref.git = source.git; ref.unsaved = source.unsaved; ref.hash = source.hash
                break
              end
            end
            local observed = not ref
            if not ref then
              local ok, result = pcall(R.capture, app.project, citation.path, citation.line_start, citation.line_end)
              if ok then ref = result; ref.column_start = citation.column_start end
            end
            if ref then
              local before = item.text:sub(1, citation.start_col)
              local first = before:match('.*\n()') or 1
              local last = item.text:find('\n', citation.end_col + 1, true) or (#item.text + 1)
              annotation = { id = id, entry_id = item.id, thread_id = item.thread_id or item.id,
                text = item.text:sub(first, last - 1), reference = ref, observed_after_reply = observed,
                created_at = item.created_at, role = 'assistant', request_id = item.request_id,
                instruction = item.instruction, origin = 'review' }
              app.state.annotations[id] = annotation
            end
          end
          if annotation then present[annotation.id] = true; if not annotation.resolved then active[#active + 1] = annotation end end
        end
      end
    end
  end
  -- Structured actions are authoritative; legacy prose remains readable for old sessions.
  local latest = {}
  for _, item in ipairs(items) do
    local action = item.editor_action
    if action and action.kind == 'comment' then latest[action.comment_id or action.id] = item end
  end
  for id, item in pairs(latest) do
    local action, ref = item.editor_action, nil
    if P.resolve(app.project.root, action.path) then
      local sources = { item.current_file or {} }; vim.list_extend(sources, item.references or {})
      for _, source in ipairs(sources) do
        local last = action.line_end or action.line_start
        if source.path == action.path and source.text and source.line_start <= action.line_start and source.line_end >= last then
          ref = { path = source.path, line_start = action.line_start, line_end = last,
            text = table.concat(vim.list_slice(U.lines(source.text), action.line_start - source.line_start + 1, last - source.line_start + 1), '\n'),
            hash = source.hash, git = source.git, unsaved = source.unsaved }; break
        end
      end
      if not ref then
        local ok, value = pcall(R.capture, app.project, action.path, action.line_start, action.line_end)
        if ok then ref = value end
      end
    end
    if ref then
      local note = app.state.annotations[id]
      if not note or note.action_entry ~= item.id then
        note = { id = id, action_entry = item.id, entry_id = item.id, thread_id = note and note.thread_id or item.thread_id,
          text = action.body, reference = ref, created_at = item.created_at, role = 'assistant',
          request_id = item.request_id, instruction = item.instruction, origin = 'editor_tool' }
        app.state.annotations[id] = note
      end
      present[note.id] = true
      if not note.resolved then active[#active + 1] = note end
    else
      local err = 'Could not anchor comment in ' .. action.path .. '. Refresh the review against current code.'
      app.action_errors[#app.action_errors + 1] = err; app.action_error_entries[item.id] = err
    end
  end
  table.sort(active, function(a, b) if a.created_at == b.created_at then return a.id < b.id end return (a.created_at or 0) < (b.created_at or 0) end)
  app.annotations = active
  app.findings = {}
  for _, note in pairs(app.state.annotations) do
    if present[note.id] then app.findings[#app.findings + 1] = note end
  end
  table.sort(app.findings, function(a,b) return (a.created_at or 0) < (b.created_at or 0) end)
  require('tim.proposals').refresh(app, items)
end
return M
