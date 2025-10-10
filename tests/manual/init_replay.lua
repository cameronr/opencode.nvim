local plugin_root = vim.fn.expand('$PWD')
vim.opt.runtimepath:append(plugin_root)

local plenary_path = plugin_root .. '/deps/plenary.nvim'
if vim.fn.isdirectory(plenary_path) == 1 then
  vim.opt.runtimepath:append(plenary_path)
end

vim.opt.termguicolors = true

vim.g.opencode_config = {
  ui = {
    default_mode = 'build',
  },
}

require('opencode').setup()

require('tests.manual.streaming_renderer_replay').start()
