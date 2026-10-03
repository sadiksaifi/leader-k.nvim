-- The answer view: a Markdown transcript of a session's answers, in a float
-- docked under the selection. Focus stays in the code until the user moves it.

local config = require("leader-k.config")
local input = require("leader-k.input")
local render = require("leader-k.render")

local M = {}

local ns = vim.api.nvim_create_namespace("leader-k.answer")
local MAX_WIDTH = 88
-- Below the selection only when this many rows fit; else at the window bottom.
local MIN_ROWS = 5

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
      text = s.answer_text
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
  local function close()
    s:destroy()
  end
  map("q", close)
  map("<Esc>", close)
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
    vim.api.nvim_win_close(win, true)
  end
end

---@param s leader_k.Session
---@return boolean
function M.focused(s)
  return s.answer_win ~= nil and vim.api.nvim_get_current_win() == s.answer_win
end

---Opens, updates, moves, or closes the float to match the session.
---@param s leader_k.Session
function M.sync(s)
  local show = s.state == "answered" or (s.state == "running" and s.answer_text ~= nil)
  local win = show and vim.api.nvim_buf_is_valid(s.buf) and code_window(s)
  if not win then
    M.close(s)
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

  local info = vim.fn.getwininfo(win)[1]
  local indent = s.indent_width
  if indent >= info.width - info.textoff - 30 then
    indent = 0
  end
  local width = math.max(math.min(info.width - info.textoff - indent - 2, MAX_WIDTH), math.min(30, info.width - 2))
  local cfg = {
    relative = "win",
    win = win,
    row = 0,
    col = info.textoff + math.max(indent - 1, 0),
    width = width,
    height = 1,
    hide = true,
    title = " Answer ",
    title_pos = "left",
    footer = " " .. (s.model_label or "") .. " ",
    footer_pos = "right",
    zindex = 50,
  }
  local awin = s.answer_win
  if not (awin and vim.api.nvim_win_is_valid(awin)) then
    cfg.style = "minimal"
    awin = vim.api.nvim_open_win(abuf, false, cfg)
    s.answer_win = awin
    local wo = vim.wo[awin]
    wo.wrap, wo.linebreak, wo.breakindent = true, true, true
    wo.conceallevel, wo.concealcursor = 2, "nc"
    wo.winhighlight = "FloatFooter:LeaderKFooter"
  else
    vim.api.nvim_win_set_config(awin, cfg)
  end

  -- Hidden while the selection is scrolled out of view.
  local r0, r1 = render.region(s)
  local top, bot = vim.fn.line("w0", win) - 1, vim.fn.line("w$", win) - 1
  if r1 < top or r0 > bot then
    return
  end
  local border = input.border_rows(awin)
  local max_h = math.max(3, math.floor(info.height * 0.4))
  -- Sized to the latest turn, which the view shows; earlier turns are above.
  local want = math.min(vim.api.nvim_win_text_height(awin, { start_row = latest, max_height = max_h }).all, max_h)
  local row, height
  if r1 <= bot then
    local at = vim.fn.screenpos(win, r1 + 1, 1).row - info.winrow
    -- Rows of the last line itself, without virtual lines above it.
    local tall = vim.api.nvim_win_text_height(win, { start_row = r1, start_vcol = 0, end_row = r1 }).all
    local below = info.height - at - tall - border
    if below >= math.min(want, MIN_ROWS) then
      row, height = at + tall, math.min(want, below)
    end
  end
  if not row then
    height = math.max(1, math.min(want, info.height - border))
    row = math.max(0, info.height - height - border)
  end
  cfg.row, cfg.height, cfg.hide = row, height, false
  vim.api.nvim_win_set_config(awin, cfg)

  -- Follow the stream, then show the latest turn from its question, unless
  -- the user is reading in the float.
  if not M.focused(s) then
    if s.state == "running" then
      vim.api.nvim_win_set_cursor(awin, { #lines, 0 })
    elseif s.answer_shown ~= #s.turns then
      s.answer_shown = #s.turns
      vim.api.nvim_win_set_cursor(awin, { latest + 1, 0 })
      vim.api.nvim_win_call(awin, function()
        vim.fn.winrestview({ topline = latest + 1 })
      end)
    end
  end
end

return M
