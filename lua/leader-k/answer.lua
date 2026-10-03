-- The answer panel: a column on the right of the editor that holds a
-- conversation once it has an answer. A Markdown transcript sits above an
-- input for follow-ups, and the line between them shows the status. Focus
-- stays in the code until the user moves it.

local config = require("leader-k.config")
local input = require("leader-k.input")
local render = require("leader-k.render")

local M = {}

local ns = vim.api.nvim_create_namespace("leader-k.answer")
local input_ns = vim.api.nvim_create_namespace("leader-k.answer.input")
local MAX_WIDTH = 80
local MIN_WIDTH = 30
local MAX_INPUT = 6

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

---Each turn as its question, then its answer or a note about its edit.
---@param s leader_k.Session
---@return string[] lines, integer[] questions 0-based rows of the user's messages, integer[] notes 0-based rows of notes, integer latest 0-based row where the last turn starts
local function transcript(s)
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

---@param lhs string
---@param label string
local function hint(lhs, label)
  return ("%%#LeaderKKey#%s%%#LeaderKHint# %s%%*"):format(escape(render.key_label(lhs)), label)
end

---What the conversation is doing, and how to stop or close it.
---@param s leader_k.Session
local function status(s)
  local left, right
  if s.state == "running" then
    local frame, text = render.progress(s, vim.uv.now())
    left = ("%%#LeaderKSpinner#%s%%* %s"):format(frame, escape(text))
    right = hint(config.options.keys.cancel, "stop")
  elseif s.state == "review" then
    left, right = "Proposed an edit. Review it in the code.", hint("q", "close")
  else
    left, right = "%#LeaderKFooter#" .. escape(s.model_label or "") .. "%*", hint("q", "close")
  end
  return " " .. left .. "%=" .. right .. " "
end

---@param win integer
---@param name string
---@param value string
local function set_wo(win, name, value)
  if vim.wo[win][name] ~= value then
    vim.wo[win][name] = value
  end
end

---Moves focus back to the code.
---@param s leader_k.Session
function M.to_code(s)
  vim.cmd.stopinsert()
  local code = code_window(s)
  if code then
    vim.api.nvim_set_current_win(code)
  end
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
  if #lines == 1 and lines[1] == "" then
    local refine = s.state == "review"
    local text
    if vim.api.nvim_get_current_win() == win then
      text = (refine and "What should change?" or "Ask a follow-up.") .. " Enter alone regenerates"
    else
      text = render.key_label(config.options.keys.refine) .. (refine and " to refine" or " to follow up")
    end
    vim.api.nvim_buf_set_extmark(buf, input_ns, 0, 0, {
      virt_text = { { text, "LeaderKPlaceholder" } },
      virt_text_pos = "overlay",
    })
  end
  -- Every row the text wraps to stays in view. The height counts the
  -- winbar, which holds the status when windows have no status line.
  local h = math.max(1, math.min(vim.api.nvim_win_text_height(win, {}).all, MAX_INPUT))
  h = h + (vim.wo[win].winbar ~= "" and 1 or 0)
  if vim.api.nvim_win_get_height(win) ~= h then
    vim.api.nvim_win_set_height(win, h)
  end
end

---@param s leader_k.Session
local function create_buf(s)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  pcall(vim.api.nvim_buf_set_name, buf, "leader-k://answer/" .. s.buf)
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
  pcall(vim.api.nvim_buf_set_name, buf, "leader-k://follow-up/" .. s.buf)
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
    if s:follow_up(text) then
      if text ~= "" then
        input.remember(text)
      end
      reset()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
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
  map("n", "q", function()
    s:destroy()
  end)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "WinEnter", "WinLeave" }, {
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

---Closing either window of the panel closes both. With nothing else on
---screen, it also ends the conversation.
---@param s leader_k.Session
local function on_closed(s)
  if s.state == "answered" or (s.state == "running" and s.answer_text) then
    s:destroy()
  else
    M.close(s)
  end
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
        if s.answer_win == win or s.input_win == win then
          on_closed(s)
        end
      end,
    })
  end
  vim.wo[awin].conceallevel, vim.wo[awin].concealcursor = 2, "nc"
  -- The bar beside the user's messages, drawn on every screen row so it
  -- stays unbroken where a message wraps.
  vim.wo[awin].statuscolumn = "%!v:lua.require'leader-k.answer'.column()"
  vim.wo[iwin].winfixheight = true
  -- The input wears the color of the user's messages it turns into.
  vim.wo[iwin].winhighlight = "Normal:LeaderKUser,NormalNC:LeaderKUser,EndOfBuffer:LeaderKUser"
  vim.wo[iwin].statuscolumn = "%#LeaderKUserEdge#▎%#LeaderKUser# "
  vim.wo[iwin].statusline = (" %s  %s  %s"):format(
    hint("<CR>", "send"),
    hint("<Up>", "history"),
    hint("<Esc>", "back to the code")
  )
  s.answer_win, s.input_win = awin, iwin
end

---@param s leader_k.Session
function M.close(s)
  local wins = { s.answer_win, s.input_win }
  s.answer_win, s.answer_buf, s.answer_lines, s.answer_shown = nil, nil, nil, nil
  s.input_win, s.input_buf = nil, nil
  local cur = vim.api.nvim_get_current_win()
  for _, win in ipairs(wins) do
    if valid(win) then
      if win == cur then
        M.to_code(s)
      end
      -- The last window cannot be closed; the buffer then stays until replaced.
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

---The panel's 'statuscolumn': a bar on the user's messages, blank elsewhere.
---@return string
function M.column()
  local rows = user_rows[vim.api.nvim_win_get_buf(vim.g.statusline_winid)]
  if rows and rows[vim.v.lnum] then
    return "%#LeaderKUserEdge#▎%#LeaderKUser# "
  end
  return "  "
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

---Opens or updates the panel to match the session. Once open, it stays for
---the rest of the session, through turns that propose edits.
---@param s leader_k.Session
function M.sync(s)
  local open = valid(s.answer_win)
  if not open and not (s.state == "answered" or (s.state == "running" and s.answer_text ~= nil)) then
    return
  end

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
  -- The status sits on the line between the transcript and the input: the
  -- transcript's status line when windows have one, else the input's winbar.
  local bar = status(s)
  local own = vim.o.laststatus == 1 or vim.o.laststatus == 2
  set_wo(awin, "statusline", own and bar or "")
  set_wo(iwin, "winbar", own and "" or bar)
  refresh_input(s)

  -- Follow the stream, then show the latest turn from its question, with
  -- earlier turns above it when they fit, unless the user is reading the
  -- transcript.
  if vim.api.nvim_get_current_win() ~= awin then
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
