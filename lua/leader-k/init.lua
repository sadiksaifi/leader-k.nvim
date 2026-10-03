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

---Starts a conversation on the visual selection, or the current line in
---Normal mode. During a conversation, attaches the visual selection to the
---next message, or in Normal mode moves into the panel input.
---@param opts leader_k.OpenOpts|nil
function M.open(opts)
  if not did_setup then
    M.setup()
  end
  local mode = vim.fn.mode()
  local r0, r1, focus
  local visual = mode == "v" or mode == "V" or mode == "\22"
  if visual then
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    r0, r1 = math.min(a, b) - 1, math.max(a, b) - 1
    if mode ~= "V" then
      focus = {}
      local region = vim.fn.getregionpos(vim.fn.getpos("v"), vim.fn.getpos("."), { type = mode })
      for _, piece in ipairs(region) do
        -- Positions are 1-based; the end is the last byte of the last character.
        local from, to = piece[1], piece[2]
        if from[3] == 0 then
          -- A block that does not reach this row's text selects none of it.
          focus[#focus + 1] = { from[2] - 1, 0, 0 }
        else
          focus[#focus + 1] = { from[2] - 1, from[3] - 1, to[3] }
        end
      end
    end
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  else
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    r0, r1 = row, row
  end
  require("leader-k.session").start(
    r0,
    r1,
    nil,
    vim.tbl_extend("force", opts or {}, { focus = focus, selection = visual })
  )
end

---Starts a conversation on lines l1..l2 (1-based), or attaches them to the
---next message of the current one. Sends `instruction` right away when it
---is not empty. Backs the commands.
---@param l1 integer
---@param l2 integer
---@param instruction string|nil
---@param opts leader_k.OpenOpts|nil
function M.run(l1, l2, instruction, opts)
  if not did_setup then
    M.setup()
  end
  require("leader-k.session").start(
    l1 - 1,
    l2 - 1,
    instruction,
    vim.tbl_extend("force", opts or {}, { selection = true })
  )
end

return M
