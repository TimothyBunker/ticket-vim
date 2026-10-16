local root = assert(vim.env.TIM_INSTALL_DIR, 'Launch this configuration with bin/tim')
vim.opt.runtimepath:prepend(root)
vim.opt.number = true
vim.opt.mouse = 'a'
vim.opt.signcolumn = 'yes'
vim.opt.hidden = true
vim.opt.expandtab = true
vim.opt.tabstop = 2
vim.opt.shiftwidth = 2
vim.opt.softtabstop = 2
vim.g.python_recommended_style = 0 -- keep Tim defaults instead of the Python plugin's four spaces
vim.opt.splitright = true
vim.opt.splitbelow = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.updatetime = 250
vim.opt.termguicolors = true
vim.g.mapleader = ' '
require('tim').setup({ startup = true, editor = true })

vim.keymap.set({ 'n', 'i', 'x' }, '<C-q>', require('tim').quit, { desc = 'Quit Tim' })
vim.keymap.set('n', 'ZZ', function() vim.cmd('write'); require('tim').quit() end, { desc = 'Save and quit Tim' })
vim.keymap.set('n', '<C-w>q', function()
  if vim.bo.buftype == '' then require('tim').quit()
  elseif require('tim').ui then require('tim').ui:hide() end
end, { desc = 'Close file/session or agent pane' })
