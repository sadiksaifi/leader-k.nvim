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

---Opens the panel and moves into its input. In Visual mode, it first
---attaches the selection, as keys.attach does.
function M.open()
  ensure_setup()
  local agent = require("leader-k.agent")
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    agent.attach_selection(require("leader-k.context").visual())
  end
  agent.open()
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
