local M = {}

local did_setup = false

---@param opts leader_k.Config|table|nil
function M.setup(opts)
  require("leader-k.config").setup(opts)
  local hl = require("leader-k.highlight")
  hl.setup()
  if did_setup then
    return
  end
  did_setup = true
  local group = vim.api.nvim_create_augroup("leader-k", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = hl.setup })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      require("leader-k.session").stop_all()
    end,
  })
end

---@class leader_k.OpenOpts
---@field mode? leader_k.Mode "auto" (default) lets the model edit or answer; "edit" or "ask" forces one.

---Starts a session on the visual selection, or the current line in Normal
---mode. When the buffer already has a proposal or an answer, asks for a
---follow-up instead.
---@param opts leader_k.OpenOpts|nil
function M.open(opts)
  if not did_setup then
    M.setup()
  end
  local mode = vim.fn.mode()
  local r0, r1
  if mode == "v" or mode == "V" or mode == "\22" then
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    r0, r1 = math.min(a, b) - 1, math.max(a, b) - 1
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  else
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    r0, r1 = row, row
  end
  require("leader-k.session").start(r0, r1, nil, opts)
end

---Starts a session on lines l1..l2 (1-based), sending `instruction` right
---away when it is not empty. Backs the commands.
---@param l1 integer
---@param l2 integer
---@param instruction string|nil
---@param opts leader_k.OpenOpts|nil
function M.run(l1, l2, instruction, opts)
  if not did_setup then
    M.setup()
  end
  require("leader-k.session").start(l1 - 1, l2 - 1, instruction, opts)
end

return M
