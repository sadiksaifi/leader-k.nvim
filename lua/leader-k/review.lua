-- Shows one staged change in the code window: its buffer with the removed
-- lines marked and the new lines as virtual lines. The buffer text stays
-- as it is until the change is accepted. Review keys work in that buffer
-- while it is under review and put back what they shadowed afterwards.

local changes = require("leader-k.changes")
local config = require("leader-k.config")

local M = {}

M.ns = vim.api.nvim_create_namespace("leader-k.review")

local BAR = "▎"

---@class leader_k.ReviewActions
---@field accept fun()
---@field reject fun()
---@field next_file fun()
---@field prev_file fun()

---@class leader_k.Review
---@field change leader_k.Change
---@field buf integer
---@field saved_maps table[]
---@field augroup integer

---@type leader_k.Review|nil
M.current = nil

---@param buf integer
---@return integer|nil
local function window_for(buf)
  local cur = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(cur) == buf then
    return cur
  end
  return vim.fn.win_findbuf(buf)[1]
end

---@param buf integer
local function text_width(buf)
  local win = window_for(buf)
  if not win then
    return vim.o.columns
  end
  local info = vim.fn.getwininfo(win)[1]
  return info.width - info.textoff
end

-- Tree-sitter highlight spans for lines that are not in any buffer.
---@param lines string[]
---@param filetype string
---@return table<integer, { [1]: integer, [2]: integer, [3]: string }[]>|nil
local function syntax_spans(lines, filetype)
  local lang = vim.treesitter.language.get_lang(filetype)
  if not lang or #lines == 0 then
    return nil
  end
  local ok_add, added = pcall(vim.treesitter.language.add, lang)
  if not ok_add or not added then
    return nil
  end
  local query_ok, query = pcall(vim.treesitter.query.get, lang, "highlights")
  if not query_ok or not query then
    return nil
  end
  local src = table.concat(lines, "\n")
  local ok, parser = pcall(vim.treesitter.get_string_parser, src, lang)
  if not ok or not parser then
    return nil
  end
  local trees = parser:parse()
  if not trees or not trees[1] then
    return nil
  end
  local spans = {}
  for id, node in query:iter_captures(trees[1]:root(), src, 0, #lines) do
    local name = query.captures[id]
    if name:sub(1, 1) ~= "_" and name ~= "spell" and name ~= "nospell" and name ~= "conceal" then
      local group = "@" .. name .. "." .. lang
      local sr, sc, er, ec = node:range()
      for row = sr, math.min(er, #lines - 1) do
        local line = lines[row + 1]
        local s = row == sr and sc or 0
        local e = row == er and ec or #line
        if e > s then
          spans[row] = spans[row] or {}
          table.insert(spans[row], { s, e, group })
        end
      end
    end
  end
  return spans
end

---@param line string
---@return string[] tokens, integer[] starts 1-based byte offsets
local function tokenize(line)
  local toks, starts = {}, {}
  local i = 1
  while i <= #line do
    local _, e = line:find("^[%w_\128-\255]+", i)
    if not e then
      _, e = line:find("^%s+", i)
    end
    e = e or i
    toks[#toks + 1] = line:sub(i, e)
    starts[#starts + 1] = i
    i = e + 1
  end
  return toks, starts
end

---@param line string
local function weight(line)
  return #line:gsub("%s", "")
end

-- Word-level changes between an old and a new line, as 0-based [s, e) byte
-- ranges on each side. Returns nil when the lines share too little for the
-- detail to help.
---@param a string
---@param b string
---@return { [1]: integer, [2]: integer }[]|nil a_ranges, { [1]: integer, [2]: integer }[]|nil b_ranges
local function changed_ranges(a, b)
  local ta, pa = tokenize(a)
  local tb, pb = tokenize(b)
  if #ta == 0 or #tb == 0 or #ta + #tb > 400 then
    return nil, nil
  end
  local hunks = vim.text.diff(table.concat(ta, "\n") .. "\n", table.concat(tb, "\n") .. "\n", {
    result_type = "indices",
  }) --[[@as integer[][] ]]
  local ra, rb = {}, {}
  local wa, wb = 0, 0
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    if ca > 0 then
      local s0, e0 = pa[sa] - 1, pa[sa + ca - 1] + #ta[sa + ca - 1] - 1
      ra[#ra + 1] = { s0, e0 }
      wa = wa + weight(a:sub(s0 + 1, e0))
    end
    if cb > 0 then
      local s0, e0 = pb[sb] - 1, pb[sb + cb - 1] + #tb[sb + cb - 1] - 1
      rb[#rb + 1] = { s0, e0 }
      wb = wb + weight(b:sub(s0 + 1, e0))
    end
  end
  if wa > 0.6 * weight(a) or wb > 0.6 * weight(b) then
    return nil, nil
  end
  return ra, rb
end

---Builds virtual-line chunks for one proposed line.
---@param line string
---@param spans { [1]: integer, [2]: integer, [3]: string }[]|nil
---@param emph { [1]: integer, [2]: integer }[]|nil
---@param width integer Pad to this display width so the background spans the window.
local function virt_line(line, spans, emph, width)
  local base = "LeaderKAdd"
  local syn = {}
  for _, sp in ipairs(spans or {}) do
    for c = sp[1] + 1, math.min(sp[2], #line) do
      syn[c] = sp[3]
    end
  end
  local em = {}
  for _, r in ipairs(emph or {}) do
    for c = r[1] + 1, r[2] do
      em[c] = true
    end
  end
  local chunks = {}
  local run_start, run_key, run_groups = 1, nil, nil
  for c = 1, #line + 1 do
    local key, groups
    if c <= #line then
      local e, s = em[c], syn[c]
      key = (s or "") .. (e and "!" or "")
      groups = { base }
      if s then
        groups[#groups + 1] = s
      end
      if e then
        groups[#groups + 1] = "LeaderKAddText"
      end
    end
    if key ~= run_key then
      if run_key ~= nil then
        chunks[#chunks + 1] = { line:sub(run_start, c - 1), run_groups }
      end
      run_start, run_key, run_groups = c, key, groups
    end
  end
  local used = vim.fn.strdisplaywidth(line)
  chunks[#chunks + 1] = { string.rep(" ", math.max(width - used, 0)), base }
  return chunks
end

---The first buffer line (1-based) of each hunk.
---@param c leader_k.Change
---@return integer[]
function M.hunk_lines(c)
  local out = {}
  for _, h in ipairs(c.hunks) do
    out[#out + 1] = math.max(h[1], 1)
  end
  return out
end

---@param buf integer
function M.clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  end
end

---Whether the change can no longer be shown over its buffer.
---@param c leader_k.Change
---@param buf integer
---@return boolean
local function stale(c, buf)
  return not changes.same(changes.normalize(vim.api.nvim_buf_get_lines(buf, 0, -1, false)), c.original)
end

---Draws the change over its buffer.
---@param r leader_k.Review
local function draw(r)
  local c, buf = r.change, r.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  M.clear(buf)
  r.stale = stale(c, buf)
  if r.stale then
    vim.api.nvim_buf_set_extmark(buf, M.ns, 0, 0, {
      virt_text = { { ("  %s changed since the edit. Reject it, or ask again."):format(c.rel), "LeaderKWarn" } },
      virt_text_pos = "eol",
    })
    return
  end
  local width = text_width(buf) + 200
  if r.spans_for ~= c.staged then
    local ft = vim.bo[buf].filetype
    if ft == "" then
      ft = vim.filetype.match({ filename = c.path }) or ""
    end
    r.spans_for, r.spans = c.staged, syntax_spans(c.staged, ft) or {}
  end
  local spans = r.spans
  local orig, prop = c.original, c.staged
  local above, below, deleted, emph_delete = {}, {}, {}, {}
  local function push(tbl, row, vl)
    tbl[row] = tbl[row] or {}
    table.insert(tbl[row], vl)
  end
  for _, h in ipairs(c.hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    for i = 0, ca - 1 do
      deleted[sa - 1 + i] = true
    end
    local vls = {}
    for j = 0, cb - 1 do
      local bi = sb + j
      local emph
      if j < ca then
        local ra, rb = changed_ranges(orig[sa + j], prop[bi])
        if ra then
          emph = rb
          emph_delete[sa - 1 + j] = ra
        end
      end
      vls[#vls + 1] = virt_line(prop[bi], spans[bi - 1], emph, width)
    end
    -- New lines sit after the old lines they replace, or after the line
    -- they follow, or above the first line.
    local tbl, row
    if ca == 0 and sa == 0 then
      tbl, row = above, 0
    elseif ca == 0 then
      tbl, row = below, sa - 1
    else
      tbl, row = below, sa + ca - 2
    end
    for _, vl in ipairs(vls) do
      push(tbl, row, vl)
    end
    if ca == 0 then
      -- Mark where the lines go.
      vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
        sign_text = BAR,
        sign_hl_group = "LeaderKBarAdd",
        priority = 250,
        strict = false,
      })
    end
  end
  for row in pairs(deleted) do
    vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
      sign_text = BAR,
      sign_hl_group = "LeaderKBarDelete",
      line_hl_group = "LeaderKDelete",
      priority = 250,
      strict = false,
    })
    for _, rg in ipairs(emph_delete[row] or {}) do
      vim.api.nvim_buf_set_extmark(buf, M.ns, row, rg[1], {
        end_col = rg[2],
        hl_group = "LeaderKDeleteText",
        priority = 251,
        strict = false,
      })
    end
  end
  for row, vls in pairs(above) do
    vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
      virt_lines = vls,
      virt_lines_above = true,
      virt_lines_overflow = "scroll",
      strict = false,
    })
  end
  for row, vls in pairs(below) do
    vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
      virt_lines = vls,
      virt_lines_overflow = "scroll",
      strict = false,
    })
  end
end

---Moves the cursor of `win` to a hunk and keeps its new lines in view.
---@param r leader_k.Review
---@param win integer
---@param line integer 1-based.
local function show_line(r, win, line)
  pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
  local first = r.change.hunks[1]
  -- Virtual lines above the first line show only when the view scrolls
  -- into them.
  if line == 1 and first and first[1] == 0 and first[2] == 0 and not r.stale then
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview({ topline = 1, topfill = first[4] })
    end)
  else
    vim.api.nvim_win_call(win, function()
      vim.cmd("normal! zz")
    end)
  end
end

---Runs what `lhs` would do without the review's mapping.
---@param lhs string
---@param prev table|nil maparg() dict of the shadowed buffer-local mapping.
local function run_shadowed(lhs, prev)
  local raw = vim.keycode(lhs)
  local m = prev
  if not m then
    for _, g in ipairs(vim.api.nvim_get_keymap("n")) do
      if g.lhsraw == raw or g.lhsrawalt == raw then
        m = g
        break
      end
    end
  end
  local count = vim.v.count > 0 and tostring(vim.v.count) or ""
  if not m then
    vim.api.nvim_feedkeys(count .. raw, "n", false)
    return
  end
  if m.callback and m.expr == 0 then
    m.callback()
    return
  end
  local keys
  if m.callback then
    keys = m.callback() or ""
    if m.replace_keycodes == 1 then
      keys = vim.keycode(keys)
    end
  else
    local rhs = m.rhs:gsub("<[Ss][Ii][Dd]>", ("<SNR>%d_"):format(m.sid))
    keys = m.expr == 1 and vim.fn.eval(rhs) or vim.keycode(rhs)
  end
  if m.noremap ~= 0 then
    vim.api.nvim_feedkeys(count .. keys, "n", false)
  elseif vim.startswith(keys, raw) then
    -- As in Vim, a recursive mapping's own lhs at the start of its rhs is
    -- not mapped again. Here that also keeps the review's map from looping.
    vim.api.nvim_feedkeys(count .. raw, "n", false)
    vim.api.nvim_feedkeys(keys:sub(#raw + 1), "m", false)
  else
    vim.api.nvim_feedkeys(count .. keys, "m", false)
  end
end

---@param r leader_k.Review
---@param step integer 1 or -1.
local function jump_hunk(r, step)
  local win = vim.api.nvim_get_current_win()
  local lines = M.hunk_lines(r.change)
  if #lines == 0 then
    return
  end
  local cur = vim.api.nvim_win_get_cursor(win)[1]
  local target
  if step > 0 then
    for _, l in ipairs(lines) do
      if l > cur then
        target = l
        break
      end
    end
    target = target or lines[1]
  else
    for i = #lines, 1, -1 do
      if lines[i] < cur then
        target = lines[i]
        break
      end
    end
    target = target or lines[#lines]
  end
  show_line(r, win, target)
end

---@param r leader_k.Review
---@param actions leader_k.ReviewActions
local function install_maps(r, actions)
  local keys = config.options.keys
  local buf = r.buf
  local function map(lhs, fn, desc)
    local prev = vim.api.nvim_buf_call(buf, function()
      return vim.fn.maparg(lhs, "n", false, true)
    end)
    if prev and prev.buffer == 1 then
      table.insert(r.saved_maps, prev)
    else
      prev = nil
    end
    table.insert(r.saved_maps, { lhs = lhs, unmap = true })
    vim.keymap.set("n", lhs, function()
      if M.current ~= r then
        run_shadowed(lhs, prev)
        return
      end
      fn()
    end, { buffer = buf, nowait = true, silent = true, desc = "leader-k: " .. desc })
  end
  map(keys.accept, actions.accept, "accept the file")
  map(keys.reject, actions.reject, "reject the file")
  map(keys.next_file, actions.next_file, "next changed file")
  map(keys.prev_file, actions.prev_file, "previous changed file")
  map(keys.next_hunk, function()
    jump_hunk(r, 1)
  end, "next change")
  map(keys.prev_hunk, function()
    jump_hunk(r, -1)
  end, "previous change")
end

---@param r leader_k.Review
local function restore_maps(r)
  if not vim.api.nvim_buf_is_valid(r.buf) then
    return
  end
  for _, m in ipairs(r.saved_maps) do
    if m.unmap then
      pcall(vim.keymap.del, "n", m.lhs, { buffer = r.buf })
    end
  end
  for _, m in ipairs(r.saved_maps) do
    if not m.unmap then
      vim.api.nvim_buf_call(r.buf, function()
        vim.fn.mapset(m)
      end)
    end
  end
end

---Ends the review: clears the diff and restores the keys.
function M.hide()
  local r = M.current
  if not r then
    return
  end
  M.current = nil
  pcall(vim.api.nvim_del_augroup_by_id, r.augroup)
  M.clear(r.buf)
  restore_maps(r)
end

---Loads the change's file into a buffer without reading it into a window.
---@param c leader_k.Change
---@return integer buf
local function load(c)
  local buf = vim.fn.bufadd(vim.fn.fnamemodify(c.path, ":~:."))
  if not vim.api.nvim_buf_is_loaded(buf) then
    vim.fn.bufload(buf)
  end
  vim.bo[buf].buflisted = true
  if vim.bo[buf].filetype == "" then
    local ft = vim.filetype.match({ buf = buf, filename = c.path })
    if ft then
      vim.bo[buf].filetype = ft
    end
  end
  return buf
end

---Shows `c` in `win` for review.
---@param win integer
---@param c leader_k.Change
---@param actions leader_k.ReviewActions
---@param focus boolean|nil Move the cursor into `win`.
function M.show(win, c, actions, focus)
  M.hide()
  local buf = load(c)
  if vim.api.nvim_win_get_buf(win) ~= buf then
    vim.api.nvim_win_set_buf(win, buf)
  end
  local r = { change = c, buf = buf, saved_maps = {} } ---@type leader_k.Review
  r.augroup = vim.api.nvim_create_augroup("leader-k.review", { clear = true })
  M.current = r
  install_maps(r, actions)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = r.augroup,
    buffer = buf,
    callback = function()
      if M.current == r then
        draw(r)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = r.augroup,
    buffer = buf,
    callback = function()
      if M.current == r then
        M.hide()
      end
    end,
  })
  draw(r)
  show_line(r, win, M.hunk_lines(c)[1] or 1)
  if focus then
    vim.api.nvim_set_current_win(win)
  end
end

---Redraws the current review, as after the window is resized.
function M.redraw()
  if M.current then
    draw(M.current)
  end
end

return M
