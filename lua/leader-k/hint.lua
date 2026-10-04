-- A one-line floating hint that names keys, such as "Leader k attach".

local config = require("leader-k.config")

local M = {}

local ns = vim.api.nvim_create_namespace("leader-k.hint")

---@class leader_k.Hint
---@field win integer|nil
---@field buf integer|nil

---@return leader_k.Hint
function M.new()
  return {}
end

---Shows `keys` as "Key action  Key action". `prefix` comes first, dim.
---@param h leader_k.Hint
---@param keys { [1]: string, [2]: string }[] Pairs of lhs and action.
---@param win_config table nvim_open_win() position fields: relative, win, row, col, anchor.
---@param prefix string|nil
---@param max_width integer|nil
function M.show(h, keys, win_config, prefix, max_width)
  local chunks = {}
  if prefix then
    chunks[#chunks + 1] = { prefix, "LeaderKHint" }
  end
  for _, k in ipairs(keys) do
    chunks[#chunks + 1] = { (#chunks > 0 and "  " or "") .. config.key_label(k[1]), "LeaderKKey" }
    chunks[#chunks + 1] = { " " .. k[2], "LeaderKHint" }
  end
  local text, marks = " ", {}
  for _, c in ipairs(chunks) do
    marks[#marks + 1] = { #text, #text + #c[1], c[2] }
    text = text .. c[1]
  end
  text = text .. " "
  if not (h.buf and vim.api.nvim_buf_is_valid(h.buf)) then
    h.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[h.buf].bufhidden = "hide"
  end
  vim.api.nvim_buf_set_lines(h.buf, 0, -1, false, { text })
  vim.api.nvim_buf_clear_namespace(h.buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(h.buf, ns, 0, m[1], { end_col = m[2], hl_group = m[3] })
  end
  local opts = vim.tbl_extend("force", {
    width = math.max(1, math.min(vim.fn.strdisplaywidth(text), max_width or vim.o.columns)),
    height = 1,
    style = "minimal",
    focusable = false,
    zindex = 150,
  }, win_config)
  if h.win and vim.api.nvim_win_is_valid(h.win) then
    vim.api.nvim_win_set_config(h.win, opts)
  else
    opts.noautocmd = true
    h.win = vim.api.nvim_open_win(h.buf, false, opts)
    vim.wo[h.win].winhighlight = "NormalFloat:LeaderKHintFloat"
    vim.wo[h.win].wrap = false
  end
end

---@param h leader_k.Hint
function M.hide(h)
  if h.win and vim.api.nvim_win_is_valid(h.win) then
    pcall(vim.api.nvim_win_close, h.win, true)
  end
  h.win = nil
end

---@param h leader_k.Hint
---@return boolean
function M.visible(h)
  return h.win ~= nil and vim.api.nvim_win_is_valid(h.win)
end

return M
