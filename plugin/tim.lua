if vim.g.loaded_tim then return end
vim.g.loaded_tim = true
-- Plugin users can call setup themselves; commands work with defaults too.
local tim = require('tim')
if not tim.configured then tim.setup() end
