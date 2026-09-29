-- :Diffy command + completion.
local diffy = require('diffy')

vim.api.nvim_create_user_command('Diffy', function(cmd_opts)
  diffy.command(cmd_opts.fargs)
end, {
  nargs = '*',
  complete = diffy.complete,
  desc = 'Open or control a diffy session',
})
