if vim.g.loaded_leader_k then
  return
end
vim.g.loaded_leader_k = true

---@param name string
---@param mode leader_k.Mode
---@param desc string
local function command(name, mode, desc)
  vim.api.nvim_create_user_command(name, function(cmd)
    require("leader-k").run(cmd.line1, cmd.line2, cmd.args, { mode = mode })
  end, { range = true, nargs = "*", desc = "leader-k: " .. desc })
end

command("LeaderK", "auto", "edit or ask about the line range")
command("LeaderKEdit", "edit", "edit the line range with an instruction")
command("LeaderKAsk", "ask", "ask a question about the line range")
