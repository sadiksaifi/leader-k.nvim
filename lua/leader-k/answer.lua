-- The answer panel: a Markdown transcript of a session's answers, in a split
-- on the right of the editor. Focus stays in the code until the user moves it.

local config = require("leader-k.config")
local render = require("leader-k.render")

local M = {}

local ns = vim.api.nvim_create_namespace("leader-k.answer")
local MAX_WIDTH = 80
local MIN_WIDTH = 30

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

---Each turn as its question, then its answer or a note about its edit.
---@param s leader_k.Session
---@return string[] lines, integer[] questions 0-based rows of question lines, integer latest 0-based row where the last turn starts
local function transcript(s)
  local out, questions, latest = {}, {}, 0
  for i, turn in ipairs(s.turns) do
    local text = turn.answer or (turn.applied and "*Applied an edit.*") or (turn.proposal and "*Proposed an edit.*")
    if i == #s.turns and s.state == "running" then
      text = s.answer_text or "*Waiting for the reply.*"
    end
    if text then
      if #out > 0 then
        out[#out + 1] = ""
      end
      latest = #out
      for j, l in ipairs(vim.split(turn.instruction, "\n", { plain = true })) do
        questions[#questions + 1] = #out
        out[#out + 1] = (j == 1 and "› " or "  ") .. l
      end
      vim.list_extend(out, vim.split(text, "\n", { plain = true }))
    end
  end
  return out, questions, latest
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
  map("q", function()
    s:destroy()
  end)
  map(keys.refine, function()
    s:refine()
  end)
  map(keys.cancel, function()
    if s.state == "running" then
      s:stop()
    end
  end)
  return buf
end

---@param text string
local function escape(text)
  return (text:gsub("%%", "%%%%"))
end

---@param s leader_k.Session
local function winbar(s)
  local keys = config.options.keys
  local function hint(lhs, label)
    return ("%%#LeaderKKey#%s%%#LeaderKHint# %s"):format(escape(render.key_label(lhs)), label)
  end
  return (" %%#LeaderKQuestion#Answer%%#LeaderKFooter#  %s%%=%s  %s "):format(
    escape(s.model_label or ""),
    hint("q", "close"),
    hint(keys.refine, "follow up")
  )
end

---@param s leader_k.Session
---@param buf integer
local function open_win(s, buf)
  local width = math.max(MIN_WIDTH, math.min(MAX_WIDTH, math.floor(vim.o.columns * 0.4)))
  local win = vim.api.nvim_open_win(buf, false, { split = "right", win = -1, width = width })
  local wo = vim.wo[win]
  wo.wrap, wo.linebreak, wo.breakindent = true, true, true
  wo.conceallevel, wo.concealcursor = 2, "nc"
  wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn = false, false, "no", "0"
  wo.cursorline, wo.spell, wo.list, wo.fillchars = false, false, false, "eob: "
  wo.winfixwidth, wo.winfixbuf = true, true
  -- Closing the panel ends a conversation that has nothing else on screen.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = s.augroup,
    pattern = tostring(win),
    once = true,
    callback = function()
      if s.answer_win ~= win then
        return
      end
      s.answer_win, s.answer_buf, s.answer_lines, s.answer_shown = nil, nil, nil, nil
      if s.state == "answered" or (s.state == "running" and s.answer_text) then
        s:destroy()
      end
    end,
  })
  return win
end

---@param s leader_k.Session
function M.close(s)
  local win = s.answer_win
  s.answer_win, s.answer_buf, s.answer_lines, s.answer_shown = nil, nil, nil, nil
  if win and vim.api.nvim_win_is_valid(win) then
    if vim.api.nvim_get_current_win() == win then
      local code = code_window(s)
      if code then
        vim.api.nvim_set_current_win(code)
      end
    end
    -- The last window cannot be closed; the buffer then stays until replaced.
    pcall(vim.api.nvim_win_close, win, true)
  end
end

---@param s leader_k.Session
---@return boolean
function M.focused(s)
  return s.answer_win ~= nil and vim.api.nvim_get_current_win() == s.answer_win
end

---Opens or updates the panel to match the session. Once open, it stays for
---the rest of the session, through turns that propose edits.
---@param s leader_k.Session
function M.sync(s)
  local awin = s.answer_win
  local open = awin ~= nil and vim.api.nvim_win_is_valid(awin)
  if not open and not (s.state == "answered" or (s.state == "running" and s.answer_text ~= nil)) then
    return
  end

  if not (s.answer_buf and vim.api.nvim_buf_is_valid(s.answer_buf)) then
    s.answer_buf, s.answer_lines = create_buf(s), nil
  end
  local abuf = s.answer_buf
  local lines, questions, latest = transcript(s)
  local joined = table.concat(lines, "\n")
  if joined ~= s.answer_lines then
    s.answer_lines = joined
    vim.bo[abuf].modifiable = true
    vim.api.nvim_buf_set_lines(abuf, 0, -1, false, lines)
    vim.bo[abuf].modifiable = false
    vim.api.nvim_buf_clear_namespace(abuf, ns, 0, -1)
    for _, row in ipairs(questions) do
      vim.api.nvim_buf_set_extmark(abuf, ns, row, 0, {
        end_col = #lines[row + 1],
        hl_group = "LeaderKQuestion",
        priority = 200,
      })
    end
  end

  if not open then
    awin = open_win(s, abuf)
    s.answer_win = awin
  end
  local bar = winbar(s)
  if vim.wo[awin].winbar ~= bar then
    vim.wo[awin].winbar = bar
  end

  -- Follow the stream, then show the latest turn from its question, with
  -- earlier turns above it when they fit, unless the user is reading in the
  -- panel.
  if not M.focused(s) then
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
