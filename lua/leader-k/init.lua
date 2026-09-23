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

---Edits the visual selection, or the current line in Normal mode. When the
---buffer already has a proposal, refines it instead.
function M.open()
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
  require("leader-k.session").start(r0, r1)
end

---Starts an edit of lines l1..l2 (1-based), sending `instruction` right away
---when it is not empty. Backs the :LeaderK command.
---@param l1 integer
---@param l2 integer
---@param instruction string|nil
function M.edit(l1, l2, instruction)
  if not did_setup then
    M.setup()
  end
  require("leader-k.session").start(l1 - 1, l2 - 1, instruction)
end

return M
