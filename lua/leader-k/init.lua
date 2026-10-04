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
      require("leader-k.agent").stop_all()
    end,
  })
end

local function ensure_setup()
  if not did_setup then
    M.setup()
  end
end

---In Visual mode, attaches the selection to the next message and stays in
---the code. In Normal mode, opens the panel and moves into its input.
function M.open()
  ensure_setup()
  local agent = require("leader-k.agent")
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local buf, r0, r1, focus = require("leader-k.context").visual()
    agent.attach_selection(buf, r0, r1, focus)
  else
    agent.open()
  end
end

---Opens the panel, attaches lines l1..l2 (1-based) when `range` is set,
---and sends `request` when it is not empty. Backs :LeaderK.
---@param l1 integer
---@param l2 integer
---@param request string|nil
---@param range boolean|nil
function M.run(l1, l2, request, range)
  ensure_setup()
  local agent = require("leader-k.agent")
  if range then
    agent.attach_selection(vim.api.nvim_get_current_buf(), l1 - 1, l2 - 1)
  end
  request = vim.trim(request or "")
  if request == "" then
    agent.open()
  else
    agent.open()
    vim.cmd.stopinsert()
    agent.submit(request)
  end
end

---Attaches a whole file, the current buffer's by default.
---@param path string|nil
function M.add(path)
  ensure_setup()
  require("leader-k.agent").attach_file(path)
end

---Starts a new conversation, discarding pending changes.
function M.new()
  ensure_setup()
  require("leader-k.agent").new()
end

return M
