-- Draws a session into its buffer with extmarks. The buffer text is never
-- touched here: the proposal is shown as virtual lines until it is accepted.

local M = {}

M.ns = vim.api.nvim_create_namespace("leader-k.ui")

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local BAR = "▎"

---@param lhs string
local function key_label(lhs)
  local leader = vim.g.mapleader
  local named = {
    ["<cr>"] = "Enter",
    ["<bs>"] = "Backspace",
    ["<esc>"] = "Esc",
    ["<tab>"] = "Tab",
    ["<space>"] = "Space",
    ["<up>"] = "Up",
    ["<down>"] = "Down",
  }
  local lower = lhs:lower()
  if named[lower] then
    return named[lower]
  end
  local ctrl, rest = lhs:match("^<[Cc]%-(.)>(.*)$")
  if ctrl then
    return "Ctrl-" .. ctrl .. (rest ~= "" and " " .. rest or "")
  end
  if lower:find("^<leader>") then
    local l = (leader == nil or leader == " ") and "Space" or leader
    return l .. " " .. lhs:sub(#"<leader>" + 1)
  end
  return lhs
end
M.key_label = key_label

---@param buf integer
---@return integer|nil win
local function window_for(buf)
  local cur = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(cur) == buf then
    return cur
  end
  local wins = vim.fn.win_findbuf(buf)
  return wins[1]
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

M._changed_ranges = changed_ranges

---Builds virtual-line chunks for one proposed line.
---@param line string
---@param spans { [1]: integer, [2]: integer, [3]: string }[]|nil
---@param emph { [1]: integer, [2]: integer }[]|nil
---@param base string Background group.
---@param width integer Pad to this display width so the background spans the window.
---@param emph_group string
---@param cursor boolean Draw a streaming cursor after the text.
local function virt_line(line, spans, emph, base, width, emph_group, cursor)
  local syn = {}
  if spans then
    for _, sp in ipairs(spans) do
      for c = sp[1] + 1, math.min(sp[2], #line) do
        syn[c] = sp[3]
      end
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
      local e = em[c]
      local s = syn[c]
      key = (s or "") .. (e and "!" or "")
      groups = { base }
      if s then
        groups[#groups + 1] = s
      end
      if e then
        groups[#groups + 1] = emph_group
      end
    end
    if key ~= run_key then
      if run_key ~= nil then
        chunks[#chunks + 1] = { line:sub(run_start, c - 1), run_groups }
      end
      run_start, run_key, run_groups = c, key, groups
    end
  end
  if cursor then
    chunks[#chunks + 1] = { "▍", { base, "LeaderKSpinner" } }
  end
  local used = vim.fn.strdisplaywidth(line) + (cursor and 1 or 0)
  chunks[#chunks + 1] = { string.rep(" ", math.max(width - used, 0)), base }
  return chunks
end

---The spinner frame and what a running request is doing.
---@param s leader_k.Session
---@param now integer
---@return string frame, string text
function M.progress(s, now)
  local frame = SPINNER[math.floor(now / 80) % #SPINNER + 1]
  if s.phase == "waiting" then
    return frame, "Waiting for " .. s.model_label
  elseif s.phase == "thinking" then
    return frame, "Thinking"
  elseif s.phase == "answering" then
    return frame, "Answering"
  end
  local n = s.proposal and #s.proposal or 0
  return frame, ("Writing %d %s"):format(n, n == 1 and "line" or "lines")
end

---@param s leader_k.Session
---@param now integer
---@param width integer Text area width of the window.
---@return string[][] header chunks
local function header(s, now, width)
  local o = require("leader-k.config").options
  local ind = string.rep(" ", s.indent_width)
  local chunks = { { ind, "" } }
  local function add(text, group)
    chunks[#chunks + 1] = { text, group }
  end
  local function hint(lhs, label)
    add("  " .. key_label(lhs), "LeaderKKey")
    add(" " .. label, "LeaderKHint")
  end
  local instruction = s.instruction or ""
  if vim.fn.strchars(instruction) > 60 then
    instruction = vim.fn.strcharpart(instruction, 0, 59) .. "…"
  end

  if s.state == "running" then
    local frame, text = M.progress(s, now)
    add(frame .. " ", "LeaderKSpinner")
    add(text, "LeaderKStatus")
    if instruction ~= "" then
      add("  " .. instruction, "LeaderKInstruction")
    end
    add("  ", "")
    hint(o.keys.cancel, "stop")
  elseif s.state == "review" then
    if s.stale then
      add("Selection edited after the request.", "LeaderKWarn")
      add(" Undo to restore it, or", "LeaderKHint")
      hint(o.keys.reject, "discard")
    elseif s.added == 0 and s.removed == 0 then
      add("No changes", "LeaderKStatus")
      if instruction ~= "" then
        add("  " .. instruction, "LeaderKInstruction")
      end
      add("  ", "")
      hint(o.keys.reject, "close")
      hint(o.keys.refine, "refine")
    else
      add("+" .. s.added, "LeaderKCountAdd")
      add(" -" .. s.removed, "LeaderKCountDelete")
      if instruction ~= "" then
        add("  " .. instruction, "LeaderKInstruction")
      end
      add("  ", "")
      hint(o.keys.accept, "accept")
      hint(o.keys.reject, "reject")
      hint(o.keys.refine, "refine")
    end
  end
  return chunks
end

---@param s leader_k.Session
---@return integer r0, integer r1 0-based rows, inclusive.
function M.region(s)
  local m = vim.api.nvim_buf_get_extmark_by_id(s.buf, s.mark_ns, s.mark, { details = true })
  if not m[1] then
    return 0, -1
  end
  local r0, r1 = m[1], m[3].end_row or m[1]
  return r0, math.max(r0, r1)
end

---@param buf integer
function M.clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  end
end

---@param s leader_k.Session
function M.draw(s)
  local buf = s.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  M.clear(buf)
  local r0, r1 = M.region(s)
  if r1 < r0 then
    return
  end
  local now = vim.uv.now()

  local win_width = text_width(buf)
  local width = win_width + 200
  local above, below = {}, {} ---@type table<integer, table[]>, table<integer, table[]>
  local function push(tbl, row, vl)
    tbl[row] = tbl[row] or {}
    table.insert(tbl[row], vl)
  end

  local line_marks = {} ---@type table<integer, string>
  local focus = s:focus_ranges()
  local function mark_focus(group)
    for _, f in ipairs(focus) do
      vim.api.nvim_buf_set_extmark(buf, M.ns, f[1], f[2], {
        end_row = f[3],
        end_col = f[4],
        hl_group = group,
        priority = 150,
        strict = false,
      })
    end
  end
  if s.state == "prompt" then
    if #focus > 0 then
      mark_focus("LeaderKSelection")
    else
      for row = r0, r1 do
        line_marks[row] = "selected"
      end
    end
  else
    -- Keep the question's subject in sight; a proposal shows its own diff.
    if s.state == "answered" or (s.state == "running" and not s.proposal) then
      mark_focus("LeaderKFocus")
    end
    -- With the answer panel open, the conversation's status lives there;
    -- the code shows a header only for a proposal to accept or reject.
    local docked = s.answer_win ~= nil and vim.api.nvim_win_is_valid(s.answer_win)
    if not docked or s.state == "review" then
      push(above, r0, header(s, now, win_width))
    end
    for row = r0, r1 do
      line_marks[row] = "bar"
    end
  end

  local emph_delete = {} ---@type table<integer, { [1]: integer, [2]: integer }[]>
  if s.proposal and not s.stale and (s.state == "running" or s.state == "review") then
    local orig, prop = s.original, s.proposal
    local streaming = s.state == "running"
    local hunks = s.hunks or {}
    -- Parse once per proposal, not once per spinner frame.
    if s.spans_for ~= prop then
      s.spans_for, s.spans = prop, syntax_spans(prop, s.filetype) or {}
    end
    local spans = s.spans
    local last = hunks[#hunks]
    -- While streaming, a hunk that runs to the end of the selection has not
    -- been reached yet: its old lines are pending, not deleted.
    local trailing = streaming and last and last[2] > 0 and last[1] + last[2] - 1 == #orig and last or nil

    for _, h in ipairs(hunks) do
      local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
      local pending = h == trailing
      for i = 0, ca - 1 do
        line_marks[r0 + sa - 1 + i] = pending and "pending" or "delete"
      end
      local vls = {}
      for j = 0, cb - 1 do
        local bi = sb + j
        local emph
        if not pending and j < ca then
          local ra, rb = changed_ranges(orig[sa + j], prop[bi])
          if ra then
            emph = rb
            emph_delete[r0 + sa - 1 + j] = ra
          end
        end
        local cursor = streaming and bi == #prop
        vls[#vls + 1] = virt_line(prop[bi], spans[bi - 1], emph, "LeaderKAdd", width, "LeaderKAddText", cursor)
      end
      -- New lines sit above the pending old lines they are replacing, after
      -- the old lines they replace, or after the line they follow.
      local tbl, row
      if pending then
        tbl, row = above, r0 + sa - 1
      elseif ca == 0 and sa == 0 then
        tbl, row = above, r0
      elseif ca == 0 then
        tbl, row = below, r0 + sa - 1
      else
        tbl, row = below, r0 + sa + ca - 2
      end
      for _, vl in ipairs(vls) do
        push(tbl, row, vl)
      end
    end
  end

  for row, kind in pairs(line_marks) do
    if kind == "selected" then
      vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
        line_hl_group = "LeaderKSelection",
        priority = 150,
        strict = false,
      })
      goto continue
    end
    local opts = {
      sign_text = BAR,
      sign_hl_group = kind == "delete" and "LeaderKBarDelete" or "LeaderKBar",
      priority = 250,
      strict = false,
    }
    if kind == "delete" then
      opts.line_hl_group = "LeaderKDelete"
    end
    vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, opts)
    if kind == "pending" then
      vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
        end_row = row + 1,
        end_col = 0,
        hl_group = "LeaderKPending",
        priority = 250,
        strict = false,
      })
    elseif kind == "delete" and emph_delete[row] then
      for _, r in ipairs(emph_delete[row]) do
        vim.api.nvim_buf_set_extmark(buf, M.ns, row, r[1], {
          end_col = r[2],
          hl_group = "LeaderKDeleteText",
          priority = 251,
          strict = false,
        })
      end
    end
    ::continue::
  end

  -- Blank rows for the instruction float, closest to the selection.
  for _ = 1, s.reserve or 0 do
    push(above, r0, { { "", "" } })
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

  -- Virtual lines above the window's top line stay hidden unless the view
  -- scrolls into them. Reveal them once when the session asks for it.
  if s.reveal then
    s.reveal = false
    local win = window_for(buf)
    local n = above[r0] and #above[r0] or 0
    if win and n > 0 then
      vim.api.nvim_win_call(win, function()
        local view = vim.fn.winsaveview()
        if view.topline == r0 + 1 and (view.topfill or 0) < n then
          vim.fn.winrestview({ topfill = n })
        elseif view.topline > r0 + 1 then
          vim.fn.winrestview({ topline = r0 + 1, topfill = n })
        end
      end)
    end
  end
end

return M
