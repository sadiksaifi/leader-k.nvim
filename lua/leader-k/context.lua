-- Attachments: code the user sends with the next message. A selection
-- follows edits to its buffer through extmarks; a whole file is read when
-- the message is sent.

local config = require("leader-k.config")
local root = require("leader-k.root")

local M = {}

M.ns = vim.api.nvim_create_namespace("leader-k.attach")

---@class leader_k.Attachment
---@field kind "selection"|"file"
---@field path string Absolute path, or "" for an unnamed buffer.
---@field buf integer|nil The selection's buffer.
---@field mark integer|nil Extmark over the selected rows.
---@field focus_marks integer[]|nil Selected characters of a characterwise selection, one mark per line.

---@param buf integer
---@param r0 integer
---@param r1 integer
---@return integer mark Extmark over rows r0..r1 that grows with edits inside them.
local function region_mark(buf, r0, r1)
  local last = vim.api.nvim_buf_get_lines(buf, r1, r1 + 1, false)[1] or ""
  -- Replacing every line, as a formatter that rewrites the file may, would
  -- leave the mark on one unrelated line; it is invalid instead until undo.
  -- A single empty line has no text to replace, and deleting the line
  -- before it would invalidate it, so it moves as before.
  return vim.api.nvim_buf_set_extmark(buf, M.ns, r0, 0, {
    end_row = r1,
    end_col = #last,
    right_gravity = true,
    end_right_gravity = false,
    invalidate = r0 ~= r1 or last ~= "",
  })
end

---@param buf integer
---@param marks integer[]|nil
---@return { [1]: integer, [2]: integer, [3]: integer, [4]: integer }[] ranges row, col, end row, end col
local function ranges_of(buf, marks)
  local out = {}
  for _, id in ipairs(marks or {}) do
    local m = vim.api.nvim_buf_get_extmark_by_id(buf, M.ns, id, { details = true })
    if m[1] then
      out[#out + 1] = { m[1], m[2], m[3].end_row or m[1], m[3].end_col or m[2] }
    end
  end
  return out
end

---@param buf integer
---@param marks integer[]
---@return string
local function text_of(buf, marks)
  local parts = {}
  for _, r in ipairs(ranges_of(buf, marks)) do
    vim.list_extend(parts, vim.api.nvim_buf_get_text(buf, r[1], r[2], r[3], r[4], {}))
  end
  return table.concat(parts, "\n")
end

---@param a leader_k.Attachment
---@return integer r0, integer r1 0-based rows, inclusive; r1 < r0 once the selection is gone.
function M.rows(a)
  if not (a.buf and vim.api.nvim_buf_is_valid(a.buf)) then
    return 0, -1
  end
  local m = vim.api.nvim_buf_get_extmark_by_id(a.buf, M.ns, a.mark, { details = true })
  if not m[1] or m[3].invalid then
    return 0, -1
  end
  return m[1], math.max(m[1], m[3].end_row or m[1])
end

---Attaches rows r0..r1 of `buf`.
---@param buf integer
---@param r0 integer
---@param r1 integer
---@param focus integer[][]|nil { row, start col, end col (exclusive) } per line, 0-based, for a characterwise selection.
---@return leader_k.Attachment
function M.selection(buf, r0, r1, focus)
  local a = { kind = "selection", path = vim.api.nvim_buf_get_name(buf), buf = buf, mark = region_mark(buf, r0, r1) }
  if focus then
    a.focus_marks = {}
    for _, f in ipairs(focus) do
      local row = f[1]
      local len = #(vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "")
      local c0 = math.min(f[2], len)
      local c1 = math.max(c0, math.min(f[3], len))
      table.insert(
        a.focus_marks,
        vim.api.nvim_buf_set_extmark(buf, M.ns, row, c0, { end_row = row, end_col = c1, end_right_gravity = true })
      )
    end
    -- Whole lines selected characterwise are a linewise selection.
    local lines = vim.api.nvim_buf_get_lines(buf, r0, r1 + 1, false)
    if text_of(buf, a.focus_marks) == table.concat(lines, "\n") then
      M.free({ kind = "selection", path = "", buf = buf, mark = -1, focus_marks = a.focus_marks })
      a.focus_marks = nil
    end
  end
  return a
end

---@param path string Absolute.
---@return leader_k.Attachment
function M.file(path)
  return { kind = "file", path = path }
end

---@param a leader_k.Attachment
function M.free(a)
  if not (a.buf and vim.api.nvim_buf_is_valid(a.buf)) then
    return
  end
  pcall(vim.api.nvim_buf_del_extmark, a.buf, M.ns, a.mark)
  for _, id in ipairs(a.focus_marks or {}) do
    pcall(vim.api.nvim_buf_del_extmark, a.buf, M.ns, id)
  end
end

---@param a leader_k.Attachment
---@param b leader_k.Attachment
---@return boolean
function M.same(a, b)
  if a.kind ~= b.kind or a.path ~= b.path then
    return false
  end
  if a.kind == "file" then
    return true
  end
  local a0, a1 = M.rows(a)
  local b0, b1 = M.rows(b)
  return a.buf == b.buf
    and a0 == b0
    and a1 == b1
    and text_of(a.buf, a.focus_marks or {}) == text_of(b.buf, b.focus_marks or {})
end

---@param path string
---@param project string
local function name_of(path, project)
  if path == "" then
    return "[unnamed buffer]"
  end
  return root.relative(project, path)
end

---Names an attachment, such as "lines 3-9 of lua/a.lua".
---@param a leader_k.Attachment
---@param project string
---@return string
function M.label(a, project)
  local name = name_of(a.path, project)
  if a.kind == "file" then
    return "all of " .. name
  end
  local r0, r1 = M.rows(a)
  if r1 < r0 then
    return ("lines of %s, replaced since"):format(name)
  end
  local part = a.focus_marks and "part of " or ""
  if not a.focus_marks and r0 == 0 and r1 == vim.api.nvim_buf_line_count(a.buf) - 1 then
    return "all of " .. name
  end
  local where = r0 == r1 and ("line %d"):format(r0 + 1) or ("lines %d-%d"):format(r0 + 1, r1 + 1)
  return ("%s%s of %s"):format(part, where, name)
end

---Diagnostics on rows r0..r1 of `buf`, as text lines.
---@param buf integer
---@param r0 integer
---@param r1 integer
---@return string[]
local function diagnostics(buf, r0, r1)
  local out = {}
  local severity = { "error", "warning", "info", "hint" }
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    if d.lnum >= r0 and d.lnum <= r1 then
      local msg = d.message:gsub("%s*\n%s*", " ")
      out[#out + 1] = ("line %d: %s: %s"):format(d.lnum + 1, severity[d.severity] or "note", msg)
    end
  end
  table.sort(out)
  return out
end

---@param s string
local function attr(s)
  return (s:gsub("&", "&amp;"):gsub('"', "&quot;"):gsub("<", "&lt;"))
end

---The attachment as a block for the user message, or nil and why it
---cannot be sent.
---@param a leader_k.Attachment
---@param project string
---@param text_of_file fun(path: string): string[]|nil The file's text, with staged edits.
---@return string|nil block, string|nil err
function M.render(a, project, text_of_file)
  local name = name_of(a.path, project)
  if a.kind == "file" then
    local lines = text_of_file(a.path)
    if not lines then
      return nil, ("%s cannot be read"):format(name)
    end
    local cap, size, body = config.options.max_read_bytes, 0, {}
    for i, l in ipairs(lines) do
      size = size + #l + 1
      if size > cap then
        body[#body + 1] = ("[Stopped at %d bytes. Use read_file from line %d for the rest.]"):format(cap, i)
        break
      end
      body[#body + 1] = l
    end
    local buf = vim.fn.bufnr(a.path)
    local diags = buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) and diagnostics(buf, 0, #lines - 1) or {}
    local out = { ('<attachment path="%s" lines="1-%d">'):format(attr(name), #lines) }
    vim.list_extend(out, body)
    out[#out + 1] = "</attachment>"
    if #diags > 0 then
      out[#out + 1] = ('<diagnostics path="%s">'):format(attr(name))
      vim.list_extend(out, diags)
      out[#out + 1] = "</diagnostics>"
    end
    return table.concat(out, "\n")
  end
  local r0, r1 = M.rows(a)
  if r1 < r0 then
    return nil, ("the selected lines of %s were replaced"):format(name)
  end
  local lines = a.focus_marks and vim.split(text_of(a.buf, a.focus_marks), "\n", { plain = true })
    or vim.api.nvim_buf_get_lines(a.buf, r0, r1 + 1, false)
  local out = {
    ('<attachment path="%s" lines="%d-%d"%s>'):format(
      attr(name),
      r0 + 1,
      r1 + 1,
      a.focus_marks and ' part="true"' or ""
    ),
  }
  vim.list_extend(out, lines)
  out[#out + 1] = "</attachment>"
  local diags = diagnostics(a.buf, r0, r1)
  if #diags > 0 then
    out[#out + 1] = ('<diagnostics path="%s">'):format(attr(name))
    vim.list_extend(out, diags)
    out[#out + 1] = "</diagnostics>"
  end
  return table.concat(out, "\n")
end

---Reads the Visual selection of the current window and leaves Visual mode.
---@return integer buf, integer r0, integer r1, integer[][]|nil focus
function M.visual()
  local mode = vim.fn.mode()
  local a, b = vim.fn.line("v"), vim.fn.line(".")
  local r0, r1 = math.min(a, b) - 1, math.max(a, b) - 1
  local focus
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
  return vim.api.nvim_get_current_buf(), r0, r1, focus
end

return M
