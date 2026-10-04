if vim.g.loaded_leader_k then
  return
end
vim.g.loaded_leader_k = true

vim.api.nvim_create_user_command("LeaderK", function(cmd)
  require("leader-k").run(cmd.line1, cmd.line2, cmd.args, cmd.range > 0)
end, {
  range = true,
  nargs = "*",
  desc = "leader-k: open the panel, attach the range, and send a request",
})

vim.api.nvim_create_user_command("LeaderKAdd", function(cmd)
  require("leader-k").add(cmd.args)
end, {
  nargs = "?",
  complete = "file",
  desc = "leader-k: attach a file to the next message",
})

vim.api.nvim_create_user_command("LeaderKNew", function()
  require("leader-k").new()
end, {
  desc = "leader-k: start a new conversation",
})
