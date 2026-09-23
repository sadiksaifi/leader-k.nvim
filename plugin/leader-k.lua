if vim.g.loaded_leader_k then
  return
end
vim.g.loaded_leader_k = true

vim.api.nvim_create_user_command("LeaderK", function(cmd)
  require("leader-k").edit(cmd.line1, cmd.line2, cmd.args)
end, {
  range = true,
  nargs = "*",
  desc = "leader-k: edit the line range with an instruction",
})
