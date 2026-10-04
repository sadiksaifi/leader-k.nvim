-- The Visual-mode key that attaches the selection. It exists only while the
-- panel is open, and puts back any global mapping it shadows when the panel
-- closes. In Visual mode, a hint above the selection names the key.

local config = require("leader-k.config")
local hint = require("leader-k.hint")

local M = {}

---@class leader_k.AttachState
---@field lhs string
---@field raw string The key as typed when the map was set.
---@field callback function The mapping's callback.
---@field saved table|nil The shadowed global Visual-mode mapping.
---@field augroup integer
---@field owns fun(win: integer): boolean Whether `win` belongs to the panel.
---@field attach fun(buf: integer, r0: integer, r1: integer, focus: integer[][]|nil)

---@type leader_k.AttachState|nil
local active = nil

M.hint = hint.new()

local function visual()
  local mode = vim.fn.mode()
  return mode == "v" or mode == "V" or mode == "\22"
end

---@param win integer
local function selectable(win)
  return active ~= nil and not active.owns(win) and vim.api.nvim_win_get_config(win).relative == ""
end

---Where the hint goes in `win`: the row above the selection's first line,
---or below its last line when the first line is the window's top row.
---@param win integer
---@return integer row, integer col 0-based, within the window.
local function position(win)
  local v, c = vim.fn.getpos("v"), vim.fn.getpos(".")
  local top, bot = v, c
  if v[2] > c[2] or (v[2] == c[2] and v[3] > c[3]) then
    top, bot = c, v
  end
  local col = top[3]
  if vim.fn.mode() == "V" then
    col = math.max(1, vim.fn.match(vim.fn.getline(top[2]), "\\S") + 1)
  elseif vim.fn.mode() == "\22" then
    col = math.min(v[3], c[3])
  end
  local origin = vim.fn.win_screenpos(win)
  local height = vim.api.nvim_win_get_height(win)
  local first = vim.fn.screenpos(win, top[2], col)
  local x = first.col > 0 and first.col - origin[2] or vim.fn.getwininfo(win)[1].textoff
  if first.row == 0 then
    return 0, x
  end
  local row = first.row - origin[1]
  if row >= 1 then
    return row - 1, x
  end
  local last = vim.fn.screenpos(win, bot[2], 1)
  return last.row > 0 and math.min(last.row - origin[1] + 1, height - 1) or 1, x
end

---Shows the hint next to the selection.
local function show_hint()
  local win = vim.api.nvim_get_current_win()
  if not (active and visual() and selectable(win)) then
    hint.hide(M.hint)
    return
  end
  local row, col = position(win)
  hint.show(M.hint, { { active.lhs, "attach" } }, { relative = "win", win = win, row = row, col = col })
end

---The global Visual-mode mapping of the keys `raw`. maparg() would return
---a buffer-local mapping of the current buffer instead.
---@param raw string Keys as typed, such as from vim.keycode().
---@return table|nil
local function global_map(raw)
  for _, m in ipairs(vim.api.nvim_get_keymap("x")) do
    if m.lhsraw == raw or m.lhsrawalt == raw then
      return m
    end
  end
end

---Maps the attach key in Visual mode until disable().
---@param owns fun(win: integer): boolean
---@param attach fun(buf: integer, r0: integer, r1: integer, focus: integer[][]|nil)
function M.enable(owns, attach)
  if active then
    return
  end
  local lhs = config.options.keys.attach
  -- The key as typed now: a later change of mapleader does not move it.
  local raw = vim.keycode(lhs)
  local saved = global_map(raw)
  local function callback()
    if not selectable(vim.api.nvim_get_current_win()) then
      vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
      return
    end
    hint.hide(M.hint)
    local buf, r0, r1, focus = require("leader-k.context").visual()
    active.attach(buf, r0, r1, focus)
  end
  active = { lhs = lhs, raw = raw, callback = callback, saved = saved, owns = owns, attach = attach }
  vim.keymap.set("x", lhs, callback, { silent = true, desc = "leader-k: attach the selection" })
  active.augroup = vim.api.nvim_create_augroup("leader-k.attach", { clear = true })
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = active.augroup,
    pattern = "*:[vV\22]*",
    callback = show_hint,
  })
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = active.augroup,
    pattern = "[vV\22]*:*",
    callback = function()
      if not visual() then
        hint.hide(M.hint)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled" }, {
    group = active.augroup,
    callback = function()
      if visual() then
        show_hint()
      end
    end,
  })
end

---Removes the attach key and the hint, and restores what the key shadowed.
function M.disable()
  if not active then
    return
  end
  local a = active
  active = nil
  hint.hide(M.hint)
  pcall(vim.api.nvim_del_augroup_by_id, a.augroup)
  -- A mapping the user put on the key meanwhile stays, and so does what it
  -- replaced.
  local m = global_map(a.raw)
  if not (m and m.callback == a.callback) then
    return
  end
  vim.api.nvim_del_keymap("x", m.lhs)
  if a.saved then
    vim.fn.mapset("x", false, a.saved)
  end
end

---@return boolean
function M.enabled()
  return active ~= nil
end

return M
