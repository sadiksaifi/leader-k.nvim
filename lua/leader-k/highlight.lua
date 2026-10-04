-- Highlight groups. Colors derive from the active colorscheme's diff groups,
-- so the preview matches the theme. Every group is `default`, so a
-- colorscheme or user config can override it.

local M = {}

local function get(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false })
end

---@param a integer
---@param b integer
---@param t number Weight of b.
local function blend(a, b, t)
  local function ch(c, shift)
    return bit.band(bit.rshift(c, shift), 0xff)
  end
  local r = math.floor(ch(a, 16) * (1 - t) + ch(b, 16) * t + 0.5)
  local g = math.floor(ch(a, 8) * (1 - t) + ch(b, 8) * t + 0.5)
  local bl = math.floor(ch(a, 0) * (1 - t) + ch(b, 0) * t + 0.5)
  return r * 0x10000 + g * 0x100 + bl
end

---@param name string
---@param spec table
local function set(name, spec)
  spec.default = true
  vim.api.nvim_set_hl(0, name, spec)
end

function M.setup()
  local add, del = get("DiffAdd"), get("DiffDelete")
  local added, removed = get("Added"), get("Removed")

  -- Background-only groups, so syntax colors show through the diff.
  if add.bg then
    set("LeaderKAdd", { bg = add.bg })
    set("LeaderKAddText", { bg = added.fg and blend(add.bg, added.fg, 0.4) or add.bg, bold = false })
  else
    set("LeaderKAdd", { link = "DiffAdd" })
    set("LeaderKAddText", { link = "DiffText" })
  end
  if del.bg then
    set("LeaderKDelete", { bg = del.bg })
    set("LeaderKDeleteText", { bg = removed.fg and blend(del.bg, removed.fg, 0.4) or del.bg })
  else
    set("LeaderKDelete", { link = "DiffDelete" })
    set("LeaderKDeleteText", { link = "DiffText" })
  end

  set("LeaderKBar", { link = "NonText" })
  set("LeaderKBarAdd", { link = "Added" })
  set("LeaderKBarDelete", { link = "Removed" })
  set("LeaderKSpinner", { link = "Special" })
  set("LeaderKKey", { link = "Special" })
  set("LeaderKHint", { link = "NonText" })
  set("LeaderKCountAdd", { link = "Added" })
  set("LeaderKCountDelete", { link = "Removed" })
  set("LeaderKWarn", { link = "DiagnosticWarn" })
  set("LeaderKPlaceholder", { link = "NonText" })
  set("LeaderKNote", { link = "Comment" })

  -- The user's messages in the panel: an accent bar over a faint tint
  -- of the same hue, so they read as a group apart from the answers, which
  -- keep the plain background and full contrast.
  set("LeaderKUserBar", { link = "Function" })
  local normal, accent = get("Normal"), get("LeaderKUserBar")
  if normal.bg and accent.fg then
    set("LeaderKUser", { bg = blend(normal.bg, accent.fg, 0.2) })
  else
    set("LeaderKUser", { link = "CursorLine" })
  end
  -- The bar itself sits on the tint.
  set("LeaderKUserEdge", { fg = accent.fg, bg = get("LeaderKUser").bg })
  -- The divider above the panel input: dim, on the panel's background.
  set("LeaderKDivider", { fg = get("NonText").fg, bg = normal.bg })
end

return M
