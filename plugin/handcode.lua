if vim.g.loaded_handcode == 1 then
  return
end
vim.g.loaded_handcode = 1

-- Run default setup to register commands and settings.
-- Users can call require("handcode").setup(opts) in their config to override defaults.
require("handcode").setup()
