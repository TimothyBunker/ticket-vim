local M = { opts = {}, app = nil, ui = nil }
local U = require('tim.util')
local P = require('tim.project')
local R = require('tim.references')

local function safe(fn)
  return function(...)
    local ok, result = pcall(fn, ...)
    if not ok then
      if M.ui then pcall(M.ui.report_error, M.ui, result) end
      U.notify(result, vim.log.levels.ERROR)
    end
    return ok and result or nil
  end
end

function M.ensure()
  if M.app then return M.app end
  local name = M.opts.name or vim.env.TIM_SESSION_NAME
  if name == '' then name = nil end
  local opts = vim.tbl_extend('force', M.opts, { name = name })
  opts.branch_filter = opts.branch_filter or vim.env.TIM_BRANCH_FILTER == '1'
  M.app = require('tim.app').new(opts)
  M.ui = require('tim.ui').new(M.app)
  M.app:source(vim.api.nvim_get_current_buf())
  M.ui.files:track(vim.api.nvim_get_current_buf())
  for _, path in ipairs(vim.fn.argv()) do M.ui.files:track(vim.fn.bufadd(vim.fn.fnamemodify(path, ':p'))) end
  return M.app
end

-- Naming is an editor prompt, so opening a file never depends on a shell dialog.
function M.with_session(callback)
  if M.app then return callback() end
  local name = M.opts.name or vim.env.TIM_SESSION_NAME
  if name == '' then name = nil end
  local opts = vim.tbl_extend('force', M.opts, { name = name })
  opts.branch_filter = opts.branch_filter or vim.env.TIM_BRANCH_FILTER == '1'
  if require('tim.store').has_selection(P.discover(opts.root), opts) then
    M.ensure(); return callback()
  end
  if M.prompting then return end
  M.prompting = true
  vim.ui.input({ prompt = 'Name this session: ' }, function(answer)
    M.prompting = false
    if not answer or vim.trim(answer) == '' then return end
    safe(function()
      M.opts.name = answer
      M.ensure(); callback()
    end)()
  end)
end

-- Neovim only registers uppercase user commands. Translate the command token
-- on Enter, preserving ranges and all argument text. Other Ex commands pass through.
function M.command_enter()
  local enter = vim.api.nvim_replace_termcodes('<CR>', true, false, true)
  if vim.fn.getcmdtype() ~= ':' then return enter end
  local line = vim.fn.getcmdline()
  if M.opts.editor and vim.bo.buftype == '' then
    local cmd = vim.trim(line)
    local quit = ({ q = 'confirm qall', quit = 'confirm qall', close = 'confirm qall',
      ['q!'] = 'qall!', ['quit!'] = 'qall!', wq = 'write | confirm qall', x = 'update | confirm qall',
      exit = 'update | confirm qall' })[cmd]
    if quit then
      return vim.api.nvim_replace_termcodes('<C-E><C-U>', true, false, true) .. quit .. enter
    end
  end
  local prefix, name, rest = line:match("^([%d%s%.,;%%$'<>+%-]*)(%a+)(.*)$")
  local target = ({ ask = 'TimAsk', comment = 'TimComment' })[name]
  if not target or (rest ~= '' and not rest:match('^%s')) then return enter end
  if prefix:find("'<,'>", 1, true) then
    M.pending_selection = { first = vim.fn.getpos("'<"), last = vim.fn.getpos("'>"), mode = vim.fn.visualmode() }
  end
  return vim.api.nvim_replace_termcodes('<C-E><C-U>', true, false, true) .. prefix .. target .. rest .. enter
end

function M.submit_draft(action)
  local app = M.ensure()
  M.ui:flush_draft()
  local draft = app.state.draft
  if action == 'comment' then
    app:comment(draft.text, draft.references, draft.thread_id)
    app.state.draft = { text = '', references = {}, mode = 'ask' }
    app:save()
    if app.on_draft_reset then app.on_draft_reset() end
    app.status = 'Note saved locally · not sent to Pi'; app:changed()
    U.notify('Note saved locally · not sent to Pi')
  elseif draft.intent == 'review' then
    draft.scope = #draft.references > 0 and 'selection' or 'file'
    if vim.trim(draft.text) == '' then
      draft.text = #draft.references > 0 and 'Review the selected code.' or 'Review this file.'
      if M.ui.draft then vim.api.nvim_buf_set_lines(M.ui.draft, 0, -1, false, { draft.text }) end
    end
    app:send(draft.text)
  else app:send(draft.text) end
end

function M.complete(findstart, base)
  if findstart == 1 then
    local before = vim.api.nvim_get_current_line():sub(1, vim.fn.col('.') - 1)
    return (before:match('()@[^@]*$') or (#before + 1)) - 1
  end
  local prefix = base:gsub('^@%[?', '')
  local choices = {}
  for _, path in ipairs(R.files(M.ensure().project)) do
    if path:sub(1, #prefix) == prefix then choices[#choices + 1] = '@[' .. path .. ']:1' end
    if #choices >= 100 then break end
  end
  return choices
end

function M.close()
  if M.ui then M.ui:flush_draft() end
  if M.app then M.app:close() end
  M.app, M.ui = nil, nil
end

function M.capture(args, visual)
  local app = M.ensure()
  local buf = vim.api.nvim_get_current_buf()
  app:source(buf)
  if not app.source_path then return nil end
  local selection = visual or M.pending_selection
  M.pending_selection = nil
  if selection then return app:capture(nil, nil, selection) end
  local line = args and args.range > 0 and args.line1 or vim.api.nvim_win_get_cursor(0)[1]
  if vim.bo.buftype ~= '' then
    local win = vim.fn.bufwinid(app.source_buf)
    line = win > 0 and vim.api.nvim_win_get_cursor(win)[1] or 1
  end
  return app:capture(line, args and args.range > 0 and args.line2 or line)
end

function M.focus_input(mode, visual)
  M.with_session(function()
    local buf = vim.api.nvim_get_current_buf()
    if not mode and buf == M.ui.draft then M.ui:return_to_source(); return end
    local ref
    if vim.bo[buf].buftype == '' then
      M.ui.source_win = vim.api.nvim_get_current_win()
      if visual or mode == 'comment' then ref = M.capture(nil, visual) end
    end
    if visual then vim.cmd('normal! ' .. vim.api.nvim_replace_termcodes('<Esc>', true, false, true)) end
    M.ui:compose(mode or 'ask', ref)
  end)
end

local function visual_selection()
  return { first = vim.fn.getpos('v'), last = vim.fn.getpos('.'), mode = vim.fn.mode() }
end

function M.mouse_input(key)
  key = key or '<LeftMouse>'
  local mouse = vim.fn.getmousepos()
  local ui = M.ui
  if ui and mouse.winid > 0 and vim.api.nvim_win_is_valid(mouse.winid) then
    local buf = vim.api.nvim_win_get_buf(mouse.winid)
    if key ~= '<LeftMouse>' and ((buf == ui.transcript and (ui.actions or {})[mouse.line])
        or buf == ui.selection.buf or buf == ui.review.buf) then return '' end
    if buf == ui.review.buf and mouse.line == 1 then
      vim.schedule(safe(function() ui.review:click(mouse.line, mouse.column) end))
      return ''
    elseif buf == M.app.source_buf and (ui.agent_rows or {})[mouse.line]
        and mouse.wincol <= (vim.fn.getwininfo(mouse.winid)[1].textoff or 0) then
      local proposals = (ui.proposal_rows or {})[mouse.line]
      -- Native signs occupy two cells each: comment first, green proposal second.
      local fold = tonumber(vim.wo[mouse.winid].foldcolumn) or 0
      if proposals and mouse.wincol > fold + 2 and mouse.wincol <= fold + 4 then
        vim.schedule(safe(function() ui.review:proposals(proposals) end))
      else vim.schedule(safe(function() ui.review:annotation(ui.agent_rows[mouse.line][1]) end)) end
      return ''
    elseif buf == ui.transcript and ui:link_at(mouse.line, mouse.column - 1) then
      local ref = ui:link_at(mouse.line, mouse.column - 1)
      vim.schedule(safe(function() ui:open_reference(ref) end))
      return ''
    elseif buf == ui.selection.buf then
      vim.schedule(safe(function() ui.selection:click(mouse.line, mouse.column) end))
      return ''
    elseif buf == ui.transcript and (ui.actions or {})[mouse.line] then
      vim.schedule(safe(function() ui:action(mouse.line, mouse.column) end))
      return ''
    elseif buf == ui.draft and vim.api.nvim_get_current_buf() == M.app.source_buf then
      local mode = vim.fn.mode()
      if mode == 'v' or mode == 'V' then
        local app, selection = M.app, visual_selection()
        vim.schedule(safe(function()
          if M.app == app then ui:set_selection({ app:capture(nil, nil, selection) }) end
        end))
      end
      vim.schedule(function() ui.selection:close() end)
    end
  end
  return vim.api.nvim_replace_termcodes(key, true, false, true)
end

function M.toggle_agent()
  M.with_session(function() M.ui:toggle() end)
end

function M.quit()
  vim.cmd('stopinsert')
  if M.ui then M.ui.selection:close(); M.ui:flush_draft() end
  vim.cmd('confirm qall')
end

-- Keep native selections as context without opening a window or taking focus.
function M.track_selection(event)
  if not M.app or not M.ui or vim.api.nvim_get_current_buf() ~= M.app.source_buf then return end
  local mode, selection = vim.fn.mode(), nil
  if mode == 'v' or mode == 'V' then
    selection = visual_selection()
  elseif event.event == 'ModeChanged' and (vim.v.event.old_mode == 'v' or vim.v.event.old_mode == 'V') then
    selection = { first = vim.fn.getpos("'<"), last = vim.fn.getpos("'>"), mode = vim.v.event.old_mode }
  end
  if not selection or selection.first[2] == 0 or selection.last[2] == 0 then return end
  M.selection_epoch = (M.selection_epoch or 0) + 1
  local epoch, app, ui = M.selection_epoch, M.app, M.ui
  local version, buf, tick = ui.selection_version, app.source_buf, vim.api.nvim_buf_get_changedtick(app.source_buf)
  vim.defer_fn(safe(function()
    if epoch ~= M.selection_epoch or M.app ~= app or app.closed or ui.selection_version ~= version
        or app.source_buf ~= buf or not vim.api.nvim_buf_is_valid(buf)
        or vim.api.nvim_buf_get_changedtick(buf) ~= tick then return end
    local ref = app:capture(nil, nil, selection)
    if not vim.deep_equal(app.state.draft.references, { ref }) then ui:set_selection({ ref }) end
  end), (mode == 'v' or mode == 'V') and 80 or 0)
end

function M.commands()
  if M.registered then return end
  M.registered = true
  _G.TimAgentControl = safe(function(action)
    if not M.ui then return end
    if action == 1 then M.ui.selection:picker()
    elseif action == 2 then M.ui:hide()
    elseif action == 3 then M.ui:set_selection({})
    elseif action == 4 then
      local mode = vim.fn.mode()
      if (mode == 'v' or mode == 'V') and vim.api.nvim_get_current_buf() == M.app.source_buf then
        local ref = M.capture(nil, visual_selection())
        vim.cmd('normal! ' .. vim.api.nvim_replace_termcodes('<Esc>', true, false, true))
        M.ui:set_selection({ ref })
      end
      M.ui:compose('ask')
    elseif action == 9 then M.submit_draft('comment')
    elseif action == 10 or action == 13 then M.ui.selected_proposal = nil; M.ui:set_view('diffs')
    elseif action == 11 then M.ui:set_view('chat')
    elseif action == 12 then M.ui:set_view('comments')
    elseif action == 14 then M.ensure():stop()
    elseif action == 15 then M.ensure():retry()
    elseif action == 16 then M.app.state.draft.intent = nil; M.app:save(); M.ui:input_labels()
    elseif action == 5 then M.app.thread = nil; M.app.filter = 'file'; M.ui:render()
    elseif action == 8 then
      local request = M.app.state.requests[#M.app.state.requests]
      M.app.thread = request and request.thread_id; M.app.filter = 'session'; M.ui:set_view('chat'); M.ui:latest()
    elseif action == 6 then M.ui.review:selection()
    elseif action == 7 then
      local mode = vim.fn.mode()
      if (mode == 'v' or mode == 'V') and vim.api.nvim_get_current_buf() == M.app.source_buf then
        local ref = M.capture(nil, visual_selection())
        vim.cmd('normal! ' .. vim.api.nvim_replace_termcodes('<Esc>', true, false, true))
        M.ui:set_selection({ ref })
      end
      M.ui.selection:close(); M.ui.task:open()
    end
  end)
  _G.TimFileTabs = function() return M.ui and M.ui.files:label() or '' end
  _G.TimFileTab = safe(function(buf) if M.ui then M.ui.files:open(buf) end end)
  _G.TimCloseFile = safe(function(buf) if M.ui then M.ui.files:close(buf) end end)
  _G.TimOpenFile = safe(function() M.with_session(function() M.ui.files:pick() end) end)
  _G.TimNextPoint = safe(function() if M.ui then M.ui:point(1) end end)
  local function command(name, fn, opts)
    vim.api.nvim_create_user_command(name, safe(function(args)
      M.with_session(function() fn(args) end)
    end), opts or {})
  end
  vim.keymap.set('c', '<CR>', M.command_enter, { expr = true, replace_keycodes = false,
    desc = 'Run lowercase ask and comment commands' })
  command('Tim', function() M.ensure(); M.app.filter = 'all'; M.ui:show(true, true) end)
  command('TimToggle', M.toggle_agent)
  command('TimSplit', function() M.ensure(); M.ui:show(false, false) end)
  command('TimFile', function() M.ensure(); M.app.filter = 'file'; M.app.thread = nil; M.ui:show(false, false) end)
  command('TimAll', function() M.ensure(); M.app.filter = 'all'; M.app.thread = nil; M.ui:show(false, false) end)
  command('TimRelated', function() M.ensure(); M.app.filter = 'file'; M.app.all_sessions = not M.app.all_sessions; M.ui:show(false, false) end)
  local function capture(args)
    return M.capture(args)
  end
  command('TimAsk', function(args)
    local ref = capture(args)
    if args.args ~= '' then
      M.app:send(args.args, { references = ref and { ref } or {} })
      M.ui:show(false, false)
    else M.ui:compose('ask', ref) end
  end, { range = true, nargs = '*' })
  command('TimComment', function(args)
    local ref = capture(args)
    if args.args ~= '' then
      M.app:comment(args.args, { ref }); M.ui:show(false, false); U.notify('Comment saved locally')
    else M.ui:compose('comment', ref) end
  end, { range = true, nargs = '*' })
  command('TimRef', function(args) local ref = capture(args); M.app:attach(ref); U.notify('Attached ' .. R.label(ref)) end, { range = true })
  command('TimSend', function() M.submit_draft() end)
  command('TimSaveComment', function() M.submit_draft('comment') end)
  command('TimStop', function() M.ensure():stop() end)
  command('TimDraft', function() local app = M.ensure(); M.ui:compose(app.state.draft.mode or 'ask') end)
  command('TimFiles', function()
    local app = M.ensure()
    vim.ui.select(R.files(app.project), { prompt = 'Open file' }, safe(function(path)
      if path then M.ui:open_reference({ path = path, line_start = 1 }) end
    end))
  end)
  command('TimSession', function(args)
    assert(not M.app or not M.app.busy, 'Stop the current Pi turn before switching sessions')
    local function switch(name)
      if M.ui then M.ui:destroy() end
      M.close(); M.opts.name = name; M.ensure(); M.ui:show(false, false)
    end
    if args.args ~= '' then switch(args.args)
    else
      local app = M.ensure()
      local sessions = require('tim.store').list(app.project, M.opts.data_dir)
      vim.ui.select(sessions, { prompt = 'Local sessions', format_item = function(item) return item.state.name end }, safe(function(item)
        if item then switch(item.state.name) end
      end))
    end
  end, { nargs = '*' })
  command('TimImport', function(args)
    local count = M.ensure():import(args.args)
    M.app.filter = 'all'; M.ui:show(false, false); U.notify('Imported ' .. count .. ' historical messages; originals unchanged')
  end, { nargs = 1, complete = 'file' })
  command('TimExport', function(args)
    M.ensure():export(vim.fn.fnamemodify(args.args, ':p')); U.notify('Exported local session index')
  end, { nargs = 1, complete = 'file' })
  command('TimTicket', function()
    local app = M.ensure(); app:context()
    local tickets = (app.state.ticketbunker or {}).tickets or {}
    assert(#tickets > 0, 'No legacy TicketBunker records match this branch')
    vim.ui.select(tickets, { prompt = 'Attach ticket context', format_item = function(ticket) return ticket.id .. ' · ' .. (ticket.title or '') end }, safe(function(ticket)
      if ticket then
        app.state.draft.context = vim.json.encode(ticket)
        M.ui:compose('ask')
      end
    end))
  end)
  command('TimThread', function()
    local app = M.ensure()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local notes = {}
    for _, note in ipairs(app.state.notes) do
      for _, ref in ipairs(note.references or {}) do
        local row = app.source_buf and R.locate(ref, vim.api.nvim_buf_get_lines(app.source_buf, 0, -1, false))
        if ref.path == app.source_path and row and row <= line and row + #(U.lines(ref.text)) - 1 >= line then
          notes[#notes + 1] = note; break
        end
      end
    end
    assert(#notes > 0, 'No local comment at this line')
    app.thread = notes[1].thread_id; app.filter = 'file'; M.ui:show(false, true)
  end)
end

function M.setup(opts)
  assert(vim.fn.has('nvim-0.11') == 1, 'tim requires Neovim 0.11 or newer')
  M.opts = vim.tbl_extend('force', M.opts, opts or {})
  M.configured = true
  M.commands()
  local group = vim.api.nvim_create_augroup('Tim', { clear = true })
  vim.api.nvim_create_autocmd('BufEnter', { group = group, callback = function(args)
    if M.app then
      local previous = M.app.source_path
      M.app:source(args.buf)
      if M.app.source_buf == args.buf then
        M.ui.files:track(args.buf)
        M.ui.source_win = vim.api.nvim_get_current_win()
        if M.opts.editor then
          vim.wo.winbar = ' %f %m%=%@v:lua.TimNextPoint@ Points %X%@v:lua.TimToggleAgent@ Agent %X'
        end
      end
      if previous ~= M.app.source_path then M.app.thread = nil end
      M.app:changed()
    end
  end })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'FocusGained' }, { group = group, callback = function()
    local app = M.app
    if not app or app.refresh_pending then return end
    app.refresh_pending = true
    vim.defer_fn(safe(function()
      app.refresh_pending = false
      if not app.closed then app:context(); app:changed() end
    end), 150)
  end })
  vim.api.nvim_create_autocmd('BufWritePost', { group = group, callback = safe(function(args)
    if not M.app or vim.bo[args.buf].buftype ~= '' then return end
    local path = P.relative(M.app.project.root, vim.api.nvim_buf_get_name(args.buf))
    if not path then return end
    local content = table.concat(vim.api.nvim_buf_get_lines(args.buf, 0, -1, false), '\n')
    local git = M.app:context()
    local base = (M.app.buffers[args.buf] or {}).git
    M.app.state.work[#M.app.state.work + 1] = { id = U.id(), kind = 'source_saved', actor_role = 'user',
      path = path, content_hash = vim.fn.sha256(content), git = git, origin_git = base,
      checkout_changed = base and (base.ref ~= git.ref or base.head ~= git.head) or false, created_at = U.now() }
    M.app.buffers[args.buf] = { git = vim.deepcopy(git), path = path }
    require('tim.store').touch(M.app.state, git)
    M.app:save(); M.app:changed()
  end) })
  vim.api.nvim_create_autocmd('BufReadPost', { group = group, callback = safe(function(args)
    if M.app and vim.bo[args.buf].buftype == '' then
      M.app.buffers[args.buf] = nil
      M.app:context(); M.app:source(args.buf)
    end
  end) })
  vim.api.nvim_create_autocmd({ 'ModeChanged', 'CursorMoved' }, { group = group, callback = safe(M.track_selection) })
  -- Native window-close commands also finish the editor when they close source.
  if M.opts.editor then
    _G.TimToggleAgent = safe(M.toggle_agent)
    vim.o.showtabline = 2
    vim.o.tabline = '%!v:lua.TimFileTabs()'
    vim.api.nvim_create_autocmd('QuitPre', { group = group, callback = function()
      if M.ui then M.ui:flush_draft() end
      if not M.app or vim.bo.buftype ~= '' then return end
      local win = vim.api.nvim_get_current_win()
      vim.schedule(safe(function()
        if M.app and not vim.api.nvim_win_is_valid(win) then M.quit() end
      end))
    end })
  end
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'TextChangedP' }, { group = group, callback = function(args)
    if M.app and args.buf == M.app.source_buf then M.app:changed() end
  end })
  vim.api.nvim_create_autocmd('VimLeavePre', { group = group, callback = safe(M.close) })
  if M.opts.mappings ~= false then
    vim.keymap.set({ 'n', 'i', 'x' }, '<Esc>', function()
      if M.ui and M.ui:has_popup() then
        vim.schedule(safe(function() if M.ui then M.ui:dismiss_popups() end end))
      end
      return vim.api.nvim_replace_termcodes('<Esc>', true, false, true)
    end, { expr = true, replace_keycodes = false, desc = 'Dismiss agent popup' })
    vim.keymap.set('n', ']c', safe(function() if M.ui then M.ui:point(1) end end), { desc = 'Next agent comment' })
    vim.keymap.set('n', '[c', safe(function() if M.ui then M.ui:point(-1) end end), { desc = 'Previous agent comment' })
    vim.keymap.set({ 'n', 'i' }, '<C-PageDown>', safe(function() if M.ui then M.ui.files:cycle(1) end end), { desc = 'Next file tab' })
    vim.keymap.set({ 'n', 'i' }, '<C-PageUp>', safe(function() if M.ui then M.ui.files:cycle(-1) end end), { desc = 'Previous file tab' })
    vim.keymap.set({ 'n', 'i', 'x' }, '<F4>', safe(M.toggle_agent), { desc = 'Show/hide agent pane' })
    for _, key in ipairs({ '<LeftMouse>', '<2-LeftMouse>', '<3-LeftMouse>', '<4-LeftMouse>' }) do
      vim.keymap.set({ 'n', 'i', 'x' }, key, function() return M.mouse_input(key) end,
        { expr = true, replace_keycodes = false, desc = 'Use editor controls' })
    end
    for key, command in pairs({ a = 'TimAsk', c = 'TimComment', s = 'TimSplit', f = 'TimFile', j = 'TimThread', o = 'TimFiles' }) do
      vim.keymap.set('n', '<leader>t' .. key, '<Cmd>' .. command .. '<CR>', { desc = command })
    end
    vim.keymap.set({ 'n', 'i' }, '<C-g>', safe(function() M.focus_input() end), { desc = 'Switch between code and input' })
    vim.keymap.set({ 'n', 'i' }, '<M-c>', safe(function() M.focus_input('comment') end), { desc = 'Comment on current line' })
    vim.keymap.set('x', '<M-c>', safe(function() M.focus_input('comment', visual_selection()) end), { desc = 'Comment on selected text' })
    vim.keymap.set('x', '<C-g>', safe(function() M.focus_input('ask', visual_selection()) end), { desc = 'Ask about selected text' })
    vim.keymap.set('x', '<leader>ta', safe(function() M.focus_input('ask', visual_selection()) end), { desc = 'Ask about selected text' })
    vim.keymap.set('x', '<leader>tc', safe(function() M.focus_input('comment', visual_selection()) end), { desc = 'Comment on selected text' })
  end
  if M.opts.startup then
    local function start()
      if vim.fn.argc() > 0 and not M.opts.root then
        local file = vim.fn.fnamemodify(vim.fn.argv(0), ':p')
        local cwd = vim.fn.getcwd()
        M.opts.root = P.relative(cwd, file) and cwd or file
      end
      M.with_session(function()
        M.app:source(vim.api.nvim_get_current_buf())
        M.ui:show(not M.app.source_path, not M.app.source_path)
        if not M.app.source_path then M.ui:compose(M.app.state.draft.mode or 'ask') end
      end)
    end
    if vim.v.vim_did_enter == 1 then safe(start)()
    else vim.api.nvim_create_autocmd('VimEnter', { group = group, once = true, callback = safe(start) }) end
  end
end

return M
