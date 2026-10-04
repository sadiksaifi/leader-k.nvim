-- The panel: a column on the right of the editor that holds the
-- conversation from its start to its end. A Markdown transcript sits above
-- an input for requests. A dim divider with the status tops the input, and
-- the selection attached to the next message shows above the text.

local config = require("leader-k.config")
local input = require("leader-k.input")
local render = require("leader-k.render")

local M = {}

local ns = vim.api.nvim_create_namespace("leader-k.answer")
local input_ns = vim.api.nvim_create_namespace("leader-k.answer.input")
local MAX_WIDTH = 80
local MIN_WIDTH = 30
local MAX_INPUT = 6

-- Placeholders for the first request, and for one that resumes an accepted
-- conversation.
local REQUEST = { auto = "Ask, or describe a change.", edit = "Describe the change.", ask = "Ask a question." }
local FOLLOW_UP = { auto = "Ask, or describe a change.", edit = "What should change?", ask = "Ask a follow-up." }

-- Rows (1-based) of the user's messages, per answer buffer, for the column.
---@type table<integer, table<integer, true>>
local user_rows = {}

---@param s leader_k.Session
---@return integer|nil
local function code_window(s)
  local cur = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(cur) == s.buf then
    return cur
  end
  if vim.api.nvim_win_is_valid(s.win) and vim.api.nvim_win_get_buf(s.win) == s.buf then
    return s.win
  end
  return vim.fn.win_findbuf(s.buf)[1]
end

---@param win integer|nil
local function valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

---Names a selection, such as "lines 3-9 of sample.lua".
---@param path string
---@param r0 integer First row, 0-based.
---@param r1 integer Last row, 0-based.
---@param part boolean Only some characters of the rows are selected.
---@param total integer Lines in the file.
---@return string
function M.label(path, r0, r1, part, total)
  local tail = vim.fn.fnamemodify(path, ":t")
  if r1 < r0 then
    return ("Attached: lines of %s, replaced since. Select them again."):format(tail)
  end
  if not part and r0 == 0 and r1 == total - 1 then
    return ("Attached: all of %s"):format(tail)
  end
  local where = r0 == r1 and ("line %d"):format(r0 + 1) or ("lines %d-%d"):format(r0 + 1, r1 + 1)
  return ("Attached: %s%s of %s"):format(part and "part of " or "", where, tail)
end

---Before the first request: what the request will send.
---@param s leader_k.Session
---@return string
local function intro(s)
  local name = vim.api.nvim_buf_get_name(s.buf)
  local file = name ~= "" and vim.fn.fnamemodify(name, ":t") or "[unnamed buffer]"
  local r0, r1 = render.region(s)
  if r1 < r0 then
    return ("The selected lines of %s were replaced. Select them again."):format(file)
  end
  if r0 == 0 and r1 == vim.api.nvim_buf_line_count(s.buf) - 1 and not s.focus_marks then
    return ("Sending the whole file: %s"):format(file)
  end
  local where = r0 == r1 and ("line %d"):format(r0 + 1) or ("lines %d-%d"):format(r0 + 1, r1 + 1)
  return ("Sending %s%s of %s"):format(s.focus_marks and "part of " or "", where, file)
end

---Each turn as its question, then its answer or a note about its edit.
---Before the first request, what it will send.
---@param s leader_k.Session
---@return string[] lines, integer[] questions 0-based rows of the user's messages, integer[] notes 0-based rows of notes, integer latest 0-based row where the last turn starts
local function transcript(s)
  if #s.turns == 0 and s.state == "prompt" then
    return { intro(s) }, {}, { 0 }, 0
  end
  local out, questions, notes, latest = {}, {}, {}, 0
  local function ask(line)
    questions[#questions + 1] = #out
    out[#out + 1] = line
  end
  for i, turn in ipairs(s.turns) do
    local text, note = turn.answer, false
    if i == #s.turns and s.state == "running" then
      text = s.answer_text
    end
    if not text then
      note = true
      text = (turn.applied and "*Applied an edit.*")
        or (turn.proposal and "*Proposed an edit.*")
        or (i == #s.turns and s.state == "running" and "*Waiting for the reply.*")
        or nil
    end
    if text then
      if #out > 0 then
        out[#out + 1] = ""
      end
      latest = #out
      -- A tinted blank row above and below pads the message. The blank row
      -- below also keeps it out of the answer's first Markdown paragraph.
      ask("")
      local a = turn.attach
      if a then
        notes[#notes + 1] = #out
        ask(M.label(a.path, a.first_row - 1, a.first_row + math.max(#a.selection, 1) - 2, a.focus ~= nil, a.line_count))
      end
      for _, l in ipairs(vim.split(turn.instruction, "\n", { plain = true })) do
        ask(l)
      end
      ask("")
      out[#out + 1] = ""
      if note then
        notes[#notes + 1] = #out
      end
      vim.list_extend(out, vim.split(text, "\n", { plain = true }))
    end
  end
  return out, questions, notes, latest
end

---@param text string
local function escape(text)
  return (text:gsub("%%", "%%%%"))
end

---The divider above the input: a dim rule that carries what the
---conversation is doing and how to stop or close it, as wide as the input.
---@param s leader_k.Session
---@param width integer
local function divider(s, width)
  local left, right ---@type string[][], string
  if s.state == "running" then
    local frame, text = render.progress(s, vim.uv.now())
    left = { { frame .. " ", "LeaderKSpinner" }, { text } }
    right = render.key_label(config.options.keys.cancel) .. " stop"
  elseif s.state == "review" and s.stale then
    left = { { "Selection edited after the request. Undo to accept.", "LeaderKWarn" } }
  elseif s.state == "review" and s.added == 0 and s.removed == 0 then
    left = { { "No changes" } }
  elseif s.state == "review" then
    left = {
      { "+" .. s.added, "LeaderKCountAdd" },
      { " -" .. s.removed, "LeaderKCountDelete" },
      { "  Review it in the code." },
    }
  else
    left = { { s.model_label or "" } }
  end
  right = right or "q close"
  local used, out = 4, { "── " }
  for _, c in ipairs(left) do
    used = used + vim.fn.strdisplaywidth(c[1])
    out[#out + 1] = c[2] and ("%#" .. c[2] .. "#" .. escape(c[1]) .. "%#LeaderKDivider#") or escape(c[1])
  end
  local fill = width - used - vim.fn.strdisplaywidth(right) - 4
  if fill < 1 then
    right, fill = "", math.max(width - used, 0)
  end
  out[#out + 1] = " " .. string.rep("─", fill)
  if right ~= "" then
    out[#out + 1] = " " .. escape(right) .. " ──"
  end
  return table.concat(out)
end

---The row of key hints at the bottom of the input box: the review keys
---while a proposal waits in the code, the input's own keys otherwise.
---@param s leader_k.Session
---@param focused boolean The input has focus.
---@return string[][] chunks
local function hints(s, focused)
  local keys = config.options.keys
  local list
  if s.state == "review" and not focused then
    if s.stale then
      list = { { keys.reject, "discard" } }
    elseif s.added == 0 and s.removed == 0 then
      list = { { keys.reject, "close" } }
    else
      list = { { keys.accept, "accept" }, { keys.reject, "reject" } }
    end
    list[#list + 1] = { keys.refine, "refine" }
  else
    list = { { "<CR>", "send" }, { "<Up>", "history" }, { "<Esc>", "back to the code" } }
  end
  local chunks = {}
  for i, h in ipairs(list) do
    chunks[#chunks + 1] = { (i > 1 and "  " or "") .. render.key_label(h[1]), "LeaderKKey" }
    chunks[#chunks + 1] = { " " .. h[2], "LeaderKHint" }
  end
  return chunks
end

---@param win integer
---@param name string
---@param value string
local function set_wo(win, name, value)
  if vim.wo[win][name] ~= value then
    vim.wo[win][name] = value
  end
end

---@param s leader_k.Session
---@param win integer
---@return boolean Can show the code: a normal window outside the panel that shows the code or, unless it was the code's own window, a file.
local function code_slot(s, win)
  return valid(win)
    and win ~= s.answer_win
    and win ~= s.input_win
    and vim.api.nvim_win_get_config(win).relative == ""
    and (win == s.win or vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "")
end

---Moves focus back to the code. When no window shows the code edits
---target, the window it was selected in shows it again, or another file
---window of the tab, or a new window left of the panel.
---@param s leader_k.Session
function M.to_code(s)
  vim.cmd.stopinsert()
  local code = code_window(s)
  if not code then
    if not vim.api.nvim_buf_is_valid(s.buf) then
      return
    end
    local candidates = { s.win }
    vim.list_extend(candidates, vim.api.nvim_tabpage_list_wins(0))
    for _, win in ipairs(candidates) do
      if code_slot(s, win) and pcall(vim.api.nvim_win_set_buf, win, s.buf) then
        code = win
        break
      end
    end
    code = code or vim.api.nvim_open_win(s.buf, false, { split = "left", win = -1 })
    s.win = code
    local r0, r1 = render.region(s)
    if r1 >= r0 then
      pcall(vim.api.nvim_win_set_cursor, code, { r0 + 1, 0 })
    end
  end
  vim.api.nvim_set_current_win(code)
end

---Moves focus into the follow-up input.
---@param s leader_k.Session
function M.focus_input(s)
  if valid(s.input_win) then
    vim.api.nvim_set_current_win(s.input_win)
    vim.cmd.startinsert({ bang = true })
  end
end

---@param s leader_k.Session
local function refresh_input(s)
  local buf, win = s.input_buf, s.input_win
  if not (valid(win) and buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, input_ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  -- A row above and below the text gives it room inside the box. The row
  -- above names the selection sent with the next message; a row of key
  -- hints closes the box. The hints are not in the window's status line,
  -- which statusline plugins such as lualine keep setting for every window.
  local attached = s:attachment()
  local focused = vim.api.nvim_get_current_win() == win
  vim.api.nvim_buf_set_extmark(buf, input_ns, 0, 0, {
    virt_lines = { attached and { { attached, "LeaderKNote" } } or { { "", "" } } },
    virt_lines_above = true,
  })
  vim.api.nvim_buf_set_extmark(buf, input_ns, #lines - 1, 0, {
    virt_lines = { { { "", "" } }, hints(s, focused) },
  })
  if #lines == 1 and lines[1] == "" then
    local text
    if s.state == "prompt" then
      local resumed = #s.turns > 0
      text = resumed and FOLLOW_UP[s.mode] or REQUEST[s.mode]
      text = focused and (text .. " Enter sends, Esc cancels")
        or (render.key_label(config.options.keys.refine) .. " to continue")
    elseif s.state == "review" then
      text = focused and "What should change? Enter alone regenerates"
        or (render.key_label(config.options.keys.refine) .. " to refine")
    else
      text = focused and "Ask a follow-up. Enter alone regenerates"
        or (render.key_label(config.options.keys.refine) .. " to follow up")
    end
    vim.api.nvim_buf_set_extmark(buf, input_ns, 0, 0, {
      virt_text = { { text, "LeaderKPlaceholder" } },
      virt_text_pos = "overlay",
    })
  end
  -- Every row the text wraps to stays in view, with the padding. The
  -- height counts the winbar that holds the divider.
  local rows = vim.api.nvim_win_text_height(win, {}).all
  local h = math.max(4, math.min(rows, MAX_INPUT + 3))
  if vim.api.nvim_win_get_height(win) ~= h + 1 then
    vim.api.nvim_win_set_height(win, h + 1)
  end
  -- The padding above the first line shows only while the view starts on it.
  if rows <= h then
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview({ topline = 1, topfill = 1 })
    end)
  end
end

---@param s leader_k.Session
local function create_buf(s)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  pcall(vim.api.nvim_buf_set_name, buf, "leader-k://transcript")
  vim.bo[buf].filetype = "markdown"
  -- Highlight even when the user's config does not start tree-sitter for
  -- Markdown. Fenced code gets its language's colors through injections.
  pcall(vim.treesitter.start, buf, "markdown")
  vim.bo[buf].modifiable = false
  local keys = config.options.keys
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      user_rows[buf] = nil
    end,
  })
  map("q", function()
    s:destroy()
  end)
  for _, lhs in ipairs({ keys.refine, "i", "a" }) do
    map(lhs, function()
      M.focus_input(s)
    end)
  end
  map(keys.cancel, function()
    if s.state == "running" then
      s:stop()
    end
  end)
  return buf
end

---@param s leader_k.Session
local function create_input(s)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "leader_k_prompt"
  pcall(vim.api.nvim_buf_set_name, buf, "leader-k://input")
  vim.b[buf].completion = false -- blink.cmp
  local reset = input.map_history(buf)
  local function map(modes, lhs, fn)
    vim.keymap.set(modes, lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map({ "i", "n" }, "<CR>", function()
    if s.state == "running" then
      return
    end
    local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    if s:submit(text) then
      if text ~= "" then
        input.remember(text)
      end
      -- A request that cannot start ends the session and wipes this buffer.
      if vim.api.nvim_buf_is_valid(buf) then
        reset()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
      end
    end
  end)
  map({ "i", "n" }, config.options.keys.cancel, function()
    if s.state == "running" then
      s:stop()
    else
      M.to_code(s)
    end
  end)
  map("n", "<Esc>", function()
    M.to_code(s)
  end)
  -- With nothing typed, Esc cancels a new conversation or returns to the
  -- code. Otherwise it goes to Normal mode for editing, as usual.
  vim.keymap.set("i", "<Esc>", function()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if #lines > 1 or lines[1] ~= "" then
      return "<Esc>"
    end
    vim.schedule(function()
      if s.state == "prompt" then
        s:destroy()
      else
        M.to_code(s)
      end
    end)
    return ""
  end, { buffer = buf, expr = true, nowait = true, silent = true })
  map("n", "q", function()
    s:destroy()
  end)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "CursorMovedI", "WinEnter", "WinLeave" }, {
    buffer = buf,
    callback = function()
      -- WinLeave fires before the new window is current.
      vim.schedule(function()
        refresh_input(s)
      end)
    end,
  })
  return buf
end

---@param s leader_k.Session
local function open_panel(s)
  local width = math.max(MIN_WIDTH, math.min(MAX_WIDTH, math.floor(vim.o.columns * 0.4)))
  local awin = vim.api.nvim_open_win(s.answer_buf, false, { split = "right", win = -1, width = width })
  local iwin = vim.api.nvim_open_win(s.input_buf, false, { split = "below", win = awin, height = 1 })
  for _, win in ipairs({ awin, iwin }) do
    local wo = vim.wo[win]
    wo.wrap, wo.linebreak, wo.breakindent = true, true, true
    wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn = false, false, "no", "0"
    wo.cursorline, wo.spell, wo.list, wo.fillchars = false, false, false, "eob: "
    wo.winfixwidth, wo.winfixbuf = true, true
    wo.statuscolumn, wo.winbar = "", ""
    vim.api.nvim_create_autocmd("WinClosed", {
      group = s.augroup,
      pattern = tostring(win),
      once = true,
      callback = function()
        -- Closing either window of the panel ends the conversation.
        if s.answer_win == win or s.input_win == win then
          s:destroy()
        end
      end,
    })
  end
  vim.wo[awin].conceallevel, vim.wo[awin].concealcursor = 2, "nc"
  -- The bar beside the user's messages, drawn on every screen row so it
  -- stays unbroken where a message wraps.
  vim.wo[awin].statuscolumn = "%!v:lua.require'leader-k.answer'.column()"
  vim.wo[iwin].winfixheight = true
  -- A plain box under the divider, its text in line with the transcript's.
  vim.wo[iwin].statuscolumn = " "
  -- Where windows have status lines, the rows around the box stay blank.
  -- They are set once: statusline plugins may replace them.
  vim.wo[awin].winhighlight = "StatusLine:Normal,StatusLineNC:Normal"
  -- With a global status line, the blank row is a window separator; its
  -- joint with the code window's border stays a plain vertical line, in
  -- the border's own WinSeparator color.
  local vert = vim.opt.fillchars:get().vert or "│"
  vim.wo[awin].fillchars = "eob: ,stl: ,stlnc: ,horiz: ,horizup: ,horizdown: ,vertright:" .. vert
  vim.wo[iwin].winhighlight =
    "WinBar:LeaderKDivider,WinBarNC:LeaderKDivider,StatusLine:LeaderKDivider,StatusLineNC:LeaderKDivider"
  -- A global status line shows the focused window's; it stays the user's.
  if vim.o.laststatus ~= 3 then
    vim.wo[awin].statusline, vim.wo[iwin].statusline = " ", " "
  end
  s.answer_win, s.input_win = awin, iwin
end

---@param s leader_k.Session
function M.close(s)
  local wins = { s.answer_win, s.input_win }
  s.answer_win, s.answer_buf, s.answer_lines, s.answer_shown = nil, nil, nil, nil
  s.input_win, s.input_buf = nil, nil
  local live = vim.tbl_filter(valid, wins)
  if #live == 0 then
    return
  end
  -- Wiping the code's buffer can close every window but the panel's. The
  -- last window cannot be closed, so an empty one takes the panel's place.
  local others = #vim.api.nvim_list_tabpages() > 1
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(live[1]))) do
    others = others or not vim.tbl_contains(live, win)
  end
  if not others then
    vim.api.nvim_open_win(vim.api.nvim_create_buf(true, false), true, { split = "left", win = -1 })
  end
  local cur = vim.api.nvim_get_current_win()
  for _, win in ipairs(live) do
    if win == cur then
      M.to_code(s)
    end
    pcall(vim.api.nvim_win_close, win, true)
  end
end

---The panel's 'statuscolumn': a bar on the user's messages, blank elsewhere.
---@return string
function M.column()
  local rows = user_rows[vim.api.nvim_win_get_buf(vim.g.statusline_winid)]
  if rows and rows[vim.v.lnum] then
    return "%#LeaderKUserEdge#▎"
  end
  return " "
end

---@param s leader_k.Session
---@return boolean
function M.docked(s)
  return valid(s.answer_win)
end

---Whether focus is in the panel.
---@param s leader_k.Session
---@return boolean
function M.focused(s)
  local cur = vim.api.nvim_get_current_win()
  return cur == s.answer_win or cur == s.input_win
end

---Opens or updates the panel to match the session.
---@param s leader_k.Session
function M.sync(s)
  if s.state == "closed" then
    return
  end
  local open = valid(s.answer_win)

  if not (s.answer_buf and vim.api.nvim_buf_is_valid(s.answer_buf)) then
    s.answer_buf, s.answer_lines = create_buf(s), nil
  end
  if not (s.input_buf and vim.api.nvim_buf_is_valid(s.input_buf)) then
    s.input_buf = create_input(s)
  end
  local abuf = s.answer_buf
  local lines, questions, notes, latest = transcript(s)
  local joined = table.concat(lines, "\n")
  if joined ~= s.answer_lines then
    s.answer_lines = joined
    -- Show tabs in code as wide as the code's buffer does.
    if vim.api.nvim_buf_is_valid(s.buf) then
      vim.bo[abuf].tabstop = vim.bo[s.buf].tabstop
    end
    vim.bo[abuf].modifiable = true
    vim.api.nvim_buf_set_lines(abuf, 0, -1, false, lines)
    vim.bo[abuf].modifiable = false
    vim.api.nvim_buf_clear_namespace(abuf, ns, 0, -1)
    local rows = {}
    for _, row in ipairs(questions) do
      rows[row + 1] = true
      vim.api.nvim_buf_set_extmark(abuf, ns, row, 0, { line_hl_group = "LeaderKUser" })
    end
    user_rows[abuf] = rows
    for _, row in ipairs(notes) do
      vim.api.nvim_buf_set_extmark(abuf, ns, row, 0, {
        end_col = #lines[row + 1],
        hl_group = "LeaderKNote",
        priority = 200,
      })
    end
  end

  if not open then
    open_panel(s)
  end
  local awin, iwin = s.answer_win, s.input_win
  set_wo(iwin, "winbar", divider(s, vim.api.nvim_win_get_width(iwin)))
  refresh_input(s)

  -- Follow the stream, then show the latest turn from its question, with
  -- earlier turns above it when they fit, unless the user is reading the
  -- transcript.
  if vim.api.nvim_get_current_win() ~= awin and #lines > 0 then
    if s.state == "running" then
      vim.api.nvim_win_set_cursor(awin, { #lines, 0 })
    elseif s.answer_shown ~= #s.turns then
      s.answer_shown = #s.turns
      local rest = vim.api.nvim_win_text_height(awin, { start_row = latest }).all
      vim.api.nvim_win_call(awin, function()
        if rest <= vim.api.nvim_win_get_height(awin) then
          vim.api.nvim_win_set_cursor(awin, { #lines, 0 })
          vim.cmd("normal! zb")
        else
          vim.api.nvim_win_set_cursor(awin, { latest + 1, 0 })
          vim.fn.winrestview({ topline = latest + 1 })
        end
      end)
    end
  end
end

return M
