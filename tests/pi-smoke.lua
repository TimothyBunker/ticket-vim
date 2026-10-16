-- Protocol-only smoke test against an installed Pi. No model call or auth needed.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local U = require('tim.util')
local dir = vim.fn.tempname()
U.mkdir(dir)
vim.env.PI_CODING_AGENT_DIR = dir .. '/agent'
local complete, failure = false, nil
local client = require('tim.pi').new({
  command = vim.env.TIM_PI or 'pi', root = dir, session = dir .. '/pi.jsonl',
  on_event = function() end,
  on_error = function(err) failure = err end,
})
local ok, err = pcall(function()
  client:request('get_state', {}, function(state, state_error)
    if state_error then failure = state_error; return end
    assert(type(state.sessionFile) == 'string')
    client:request('get_entries', {}, function(entries, entries_error)
      if entries_error then failure = entries_error; return end
      assert(type(entries.entries) == 'table')
      client:request('get_commands', {}, function(data, command_error)
        if command_error then failure = command_error; return end
        for _, command in ipairs(data.commands or {}) do if command.name == 'tim-editor-tools' then complete = true end end
        if not complete then failure = 'Tim structured editor tools extension did not load' end
      end)
    end)
  end)
  assert(vim.wait(20000, function() return complete or failure end, 20), 'Pi handshake timed out')
  assert(not failure, failure)
end)
client:close()
if not ok then print(err); vim.cmd('cquit 1') end
print('PASS installed Pi startup, state, history and structured editor extension through Tim RPC client (no model call)')
vim.cmd('qa!')
