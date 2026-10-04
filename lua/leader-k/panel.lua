-- The panel: a column on the right of the editor. A Markdown transcript
-- sits above an input for messages. A dim divider with the status tops the
-- input, and the attachments for the next message show above its text.

local config = require("leader-k.config")
local context = require("leader-k.context")
local input = require("leader-k.input")
local review = require("leader-k.review")

local M = {}

local ns = vim.api.nvim_create_namespace("leader-k.panel")
local input_ns = vim.api.nvim_create_namespace("leader-k.panel.input")
local MAX_WIDTH = 80
local MIN_WIDTH = 30
local MAX_INPUT = 6
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

---@class leader_k.Panel
---@field tbuf integer|nil Transcript buffer.
---@field twin integer|nil
---@field ibuf integer|nil Input buffer.
---@field iwin integer|nil
---@field joined string|nil The transcript text last drawn.
---@field file_rows table<integer, leader_k.Change> 1-based transcript rows of the changed-files list.
---@field shown integer|nil Items when the view last scrolled to the latest message.
---@field augroup integer|nil

-- Rows (1-based) of the user's messages, per transcript buffer, for the column.
---@type table<integer, table<integer, true>>
local user_rows = {}

local function agent()
  return require("leader-k.agent")
end

---@param win integer|nil
local function valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

---@param S leader_k.Conversation
---@return leader_k.Panel
local function state(S)
  S.panel = S.panel or { file_rows = {} }
  return S.panel
end

---@param S leader_k.Conversation
---@param win integer
---@return boolean
function M.owns(S, win)
  local p = S.panel
  return p ~= nil and (win == p.twin or win == p.iwin)
end

---@param S leader_k.Conversation
---@return boolean
function M.is_open(S)
  return S.panel ~= nil and valid(S.panel.twin)
end

---@param text string
local function escape(text)
  return (text:gsub("%%", "%%%%"))
end

---@param n integer
---@param word string
local function count(n, word)
  return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

---What the running request is doing.
---@param S leader_k.Conversation
---@return string
local function progress(S)
  if S.phase == "tool" then
    return S.activity or "Running a tool"
  elseif S.phase == "thinking" then
    return "Thinking"
  elseif S.phase == "writing" then
    return "Writing"
  end
  return "Waiting for " .. S.model_label
end

---@param S leader_k.Conversation
---@return integer files, integer added, integer removed
local function pending_counts(S)
  local files, added, removed = 0, 0, 0
  for _, c in ipairs(S.changes:pending()) do
    files, added, removed = files + 1, added + c.added, removed + c.removed
  end
  return files, added, removed
end

---Each message, the replies, and notes on tool calls, then the changed
---files.
---@param S leader_k.Conversation
---@return string[] lines, table[] marks { row, col, end_col, group, line }, integer latest 0-based row where the last message starts, table<integer, leader_k.Change> file_rows
local function transcript(S)
  local out, marks, file_rows, latest = {}, {}, {}, 0
  local function add(line, group, kind)
    out[#out + 1] = line
    if group then
      marks[#marks + 1] = { row = #out - 1, group = group, kind = kind or "text" }
    end
  end
  local default = agent().default_file()
  if #S.items == 0 then
    if default then
      add(("Sending the whole file: %s"):format(vim.fs.basename(default)), "LeaderKNote")
    end
    return out, marks, 0, file_rows
  end
  local prev
  for _, item in ipairs(S.items) do
    if item.kind == "user" then
      if #out > 0 then
        add("")
      end
      latest = #out
      -- A tinted blank row above and below pads the message. The blank row
      -- below also keeps it out of the reply's first Markdown paragraph.
      add("", "LeaderKUser", "user")
      for _, l in ipairs(item.labels or {}) do
        add("Attached: " .. l, "LeaderKUser", "user")
        marks[#marks + 1] = { row = #out - 1, group = "LeaderKNote", kind = "text" }
      end
      for _, l in ipairs(vim.split(item.text, "\n", { plain = true })) do
        add(l, "LeaderKUser", "user")
      end
      add("", "LeaderKUser", "user")
    elseif item.kind == "assistant" then
      add("")
      vim.list_extend(out, vim.split(item.text, "\n", { plain = true }))
    elseif item.kind == "note" then
      if prev ~= "note" then
        add("")
      end
      add(item.text, "LeaderKNote")
    else
      add("")
      for _, l in ipairs(vim.split("Error: " .. item.text, "\n", { plain = true })) do
        add(l, "LeaderKWarn")
      end
    end
    prev = item.kind
  end
  if #S.changes.list > 0 then
    add("")
    add("Changed files", "LeaderKNote")
    local current = review.current and review.current.change
    for _, c in ipairs(S.changes.list) do
      local status = c == current and "reviewing" or c.status
      local name = "  " .. c.rel .. "  "
      local plus, minus = "+" .. c.added, " -" .. c.removed
      out[#out + 1] = name .. plus .. minus .. "  " .. status
      local row = #out - 1
      file_rows[row + 1] = c
      local col = #name
      marks[#marks + 1] = { row = row, col = col, end_col = col + #plus, group = "LeaderKCountAdd", kind = "text" }
      col = col + #plus
      marks[#marks + 1] = { row = row, col = col, end_col = col + #minus, group = "LeaderKCountDelete", kind = "text" }
      col = col + #minus
      marks[#marks + 1] = { row = row, col = col, group = "LeaderKNote", kind = "text" }
    end
    if #S.changes:pending() > 0 then
      local keys = config.options.keys
      add(
        ("%s on a file opens it. %s accepts all, %s rejects all."):format(
          config.key_label("<CR>"),
          keys.accept_all,
          keys.reject_all
        ),
        "LeaderKNote"
      )
    end
  end
  return out, marks, latest, file_rows
end

---The divider above the input: a dim rule that carries what the
---conversation is doing and how to stop or close it, as wide as the input.
---@param S leader_k.Conversation
---@param width integer
local function divider(S, width)
  local left, right ---@type string[][], string
  local files, added, removed = pending_counts(S)
  if S.state == "running" then
    local frame = SPINNER[math.floor(vim.uv.now() / 80) % #SPINNER + 1]
    left = { { frame .. " ", "LeaderKSpinner" }, { progress(S) } }
    right = config.key_label(config.options.keys.cancel) .. " stop"
  elseif files > 0 then
    left = {
      { "+" .. added, "LeaderKCountAdd" },
      { " -" .. removed, "LeaderKCountDelete" },
      { " in " .. count(files, "file") .. " to review" },
    }
  else
    left = { { S.model_label } }
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

---The row of key hints at the bottom of the input box.
---@param focused boolean The input has focus.
---@return string[][] chunks
local function hints(focused)
  local keys = config.options.keys
  local list
  if focused then
    list = { { "<CR>", "send" }, { "<Up>", "history" }, { "<Esc>", "back to the code" } }
  elseif review.current then
    list = { { keys.accept, "accept" }, { keys.reject, "reject" }, { keys.next_file, "next file" } }
  else
    list = { { keys.refine, "type" }, { "q", "close" } }
  end
  local chunks = {}
  for i, h in ipairs(list) do
    chunks[#chunks + 1] = { (i > 1 and "  " or "") .. config.key_label(h[1]), "LeaderKKey" }
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

---A window for code: the conversation's code window, another normal file
---window of the tab, or a new window left of the panel.
---@param S leader_k.Conversation
---@return integer|nil
function M.code_window(S)
  local function usable(win)
    return valid(win)
      and not M.owns(S, win)
      and vim.api.nvim_win_get_config(win).relative == ""
      and vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage()
  end
  if usable(S.origin_win) and not vim.wo[S.origin_win].winfixbuf then
    return S.origin_win
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if usable(win) and not vim.wo[win].winfixbuf and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "" then
      return win
    end
  end
  local win = vim.api.nvim_open_win(vim.api.nvim_create_buf(true, false), false, { split = "left", win = -1 })
  S.origin_win = win
  return win
end

---Moves focus to the code window.
---@param S leader_k.Conversation
function M.to_code(S)
  vim.cmd.stopinsert()
  local win = M.code_window(S)
  if win then
    vim.api.nvim_set_current_win(win)
  end
end

---Moves focus into the input.
---@param S leader_k.Conversation
function M.focus_input(S)
  local p = S.panel
  if p and valid(p.iwin) then
    vim.api.nvim_set_current_win(p.iwin)
    vim.cmd.startinsert({ bang = true })
  end
end

---@param S leader_k.Conversation
local function refresh_input(S)
  local p = state(S)
  local buf, win = p.ibuf, p.iwin
  if not (valid(win) and buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, input_ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local focused = vim.api.nvim_get_current_win() == win
  -- A row above and below the text gives it room inside the box. The rows
  -- above name the attachments for the next message; a row of key hints
  -- closes the box. The hints are not in the window's status line, which
  -- statusline plugins such as lualine keep setting for every window.
  local chips = {}
  for _, a in ipairs(S.attachments) do
    chips[#chips + 1] = { { "Attached: " .. context.label(a, S.root), "LeaderKNote" } }
  end
  if #chips == 0 then
    chips[1] = { { "", "" } }
  end
  vim.api.nvim_buf_set_extmark(buf, input_ns, 0, 0, { virt_lines = chips, virt_lines_above = true })
  vim.api.nvim_buf_set_extmark(buf, input_ns, #lines - 1, 0, {
    virt_lines = { { { "", "" } }, hints(focused) },
  })
  if #lines == 1 and lines[1] == "" then
    local text
    if not focused then
      text = config.key_label(config.options.keys.refine) .. " to type"
    elseif S.state == "running" then
      text = "Type the next message while this one runs"
    else
      text = #S.items == 0 and "Ask, or describe a change" or "Reply"
    end
    vim.api.nvim_buf_set_extmark(buf, input_ns, 0, 0, {
      virt_text = { { text, "LeaderKPlaceholder" } },
      virt_text_pos = "overlay",
    })
  end
  -- Every row the text wraps to stays in view, with the padding. The
  -- height counts the winbar that holds the divider.
  local rows = vim.api.nvim_win_text_height(win, {}).all
  local h = math.max(3 + #chips, math.min(rows, MAX_INPUT + 2 + #chips))
  if vim.api.nvim_win_get_height(win) ~= h + 1 then
    vim.api.nvim_win_set_height(win, h + 1)
  end
  -- The rows above the first line show only while the view starts on it.
  if rows <= h then
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview({ topline = 1, topfill = #chips })
    end)
  end
end

---@param S leader_k.Conversation
---@param buf integer
local function map_common(S, buf)
  local keys = config.options.keys
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map("q", function()
    agent().close()
  end)
  map(keys.cancel, function()
    agent().stop()
  end)
end

---@param S leader_k.Conversation
local function create_transcript(S)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
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
  map_common(S, buf)
  for _, lhs in ipairs({ keys.refine, "i", "a" }) do
    map(lhs, function()
      M.focus_input(S)
    end)
  end
  map("<CR>", function()
    local c = state(S).file_rows[vim.api.nvim_win_get_cursor(0)[1]]
    if c then
      agent().review(c, true)
    end
  end)
  map(keys.accept_all, function()
    agent().decide_all("accepted")
  end)
  map(keys.reject_all, function()
    agent().decide_all("rejected")
  end)
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      user_rows[buf] = nil
    end,
  })
  return buf
end

---Completes `@path` in the input from the project's files.
---@param buf integer
local function complete_paths(buf)
  if vim.api.nvim_get_current_buf() ~= buf or vim.fn.pumvisible() == 1 then
    return
  end
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local before = vim.api.nvim_get_current_line():sub(1, col)
  local start, typed = before:match("()@([^%s@]*)$")
  if not start or (start > 1 and before:sub(start - 1, start - 1):match("%S")) then
    return
  end
  local files = agent().project_files()
  if typed ~= "" then
    files = vim.fn.matchfuzzy(files, typed, { limit = 50 })
  end
  local items = {}
  for i = 1, math.min(#files, 50) do
    items[i] = { word = "@" .. files[i], abbr = files[i], menu = "file" }
  end
  if #items > 0 then
    vim.fn.complete(start, items)
  end
end

M._complete_paths = complete_paths

---@param S leader_k.Conversation
local function create_input(S)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].filetype = "leader_k_prompt"
  pcall(vim.api.nvim_buf_set_name, buf, "leader-k://input")
  vim.b[buf].completion = false -- blink.cmp
  vim.bo[buf].completeopt = "menuone,noinsert,noselect,fuzzy"
  local reset = input.map_history(buf)
  local function map(modes, lhs, fn)
    vim.keymap.set(modes, lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map_common(S, buf)
  map({ "i", "n" }, "<CR>", function()
    if vim.fn.pumvisible() == 1 and vim.fn.complete_info({ "selected" }).selected ~= -1 then
      vim.api.nvim_feedkeys(vim.keycode("<C-y>"), "n", false)
      return
    end
    local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    if agent().submit(text) then
      input.remember(text)
      reset()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    end
  end)
  map("i", config.options.keys.cancel, function()
    if S.state == "running" then
      agent().stop()
    else
      M.to_code(S)
    end
  end)
  map("n", "<Esc>", function()
    M.to_code(S)
  end)
  -- With nothing typed, Esc returns to the code and Backspace drops the
  -- newest attachment. Otherwise they edit the text, as usual.
  local function empty()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    return #lines == 1 and lines[1] == ""
  end
  vim.keymap.set("i", "<Esc>", function()
    if not empty() then
      return "<Esc>"
    end
    vim.schedule(function()
      M.to_code(S)
    end)
    return ""
  end, { buffer = buf, expr = true, nowait = true, silent = true })
  vim.keymap.set("i", "<BS>", function()
    if not empty() then
      return "<BS>"
    end
    vim.schedule(function()
      agent().remove_last_attachment()
    end)
    return ""
  end, { buffer = buf, expr = true, nowait = true, silent = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "CursorMovedI", "WinEnter", "WinLeave" }, {
    buffer = buf,
    callback = function()
      -- WinLeave fires before the new window is current.
      vim.schedule(function()
        refresh_input(S)
      end)
    end,
  })
  vim.api.nvim_create_autocmd("TextChangedI", {
    buffer = buf,
    callback = function()
      complete_paths(buf)
    end,
  })
  return buf
end

---@param S leader_k.Conversation
local function open_windows(S)
  local p = state(S)
  local width = math.max(MIN_WIDTH, math.min(MAX_WIDTH, math.floor(vim.o.columns * 0.4)))
  local twin = vim.api.nvim_open_win(p.tbuf, false, { split = "right", win = -1, width = width })
  local iwin = vim.api.nvim_open_win(p.ibuf, false, { split = "below", win = twin, height = 1 })
  p.twin, p.iwin, p.shown = twin, iwin, nil
  p.augroup = vim.api.nvim_create_augroup("leader-k.panel", { clear = true })
  for _, win in ipairs({ twin, iwin }) do
    local wo = vim.wo[win]
    wo.wrap, wo.linebreak, wo.breakindent = true, true, true
    wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn = false, false, "no", "0"
    wo.cursorline, wo.spell, wo.list, wo.fillchars = false, false, false, "eob: "
    wo.winfixwidth, wo.winfixbuf = true, true
    wo.statuscolumn, wo.winbar = "", ""
    vim.api.nvim_create_autocmd("WinClosed", {
      group = p.augroup,
      pattern = tostring(win),
      once = true,
      callback = function()
        -- Closing either window hides the panel; the conversation stays.
        vim.schedule(function()
          if S.panel == p and (p.twin == win or p.iwin == win) then
            M.close(S)
          end
        end)
      end,
    })
  end
  vim.wo[twin].conceallevel, vim.wo[twin].concealcursor = 2, "nc"
  -- The bar beside the user's messages, drawn on every screen row so it
  -- stays unbroken where a message wraps.
  vim.wo[twin].statuscolumn = "%!v:lua.require'leader-k.panel'.column()"
  vim.wo[iwin].winfixheight = true
  -- A plain box under the divider, its text in line with the transcript's.
  vim.wo[iwin].statuscolumn = " "
  -- Where windows have status lines, the rows around the box stay blank.
  -- They are set once: statusline plugins may replace them.
  vim.wo[twin].winhighlight = "StatusLine:Normal,StatusLineNC:Normal"
  -- With a global status line, the blank row is a window separator; its
  -- joint with the code window's border stays a plain vertical line, in
  -- the border's own WinSeparator color.
  local vert = vim.opt.fillchars:get().vert or "│"
  vim.wo[twin].fillchars = "eob: ,stl: ,stlnc: ,horiz: ,horizup: ,horizdown: ,vertright:" .. vert
  vim.wo[iwin].winhighlight =
    "WinBar:LeaderKDivider,WinBarNC:LeaderKDivider,StatusLine:LeaderKDivider,StatusLineNC:LeaderKDivider"
  -- A global status line shows the focused window's; it stays the user's.
  if vim.o.laststatus ~= 3 then
    vim.wo[twin].statusline, vim.wo[iwin].statusline = " ", " "
  end
end

---Closes the panel's windows. The conversation's buffers are wiped when
---the conversation has ended.
---@param S leader_k.Conversation
function M.close(S)
  local p = S.panel
  if not p then
    return
  end
  local wins = vim.tbl_filter(valid, { p.twin, p.iwin })
  p.twin, p.iwin = nil, nil
  if p.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, p.augroup)
    p.augroup = nil
  end
  if #wins > 0 then
    -- The last window cannot be closed, so an empty one takes the panel's
    -- place.
    local others = #vim.api.nvim_list_tabpages() > 1
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(wins[1]))) do
      others = others or not vim.tbl_contains(wins, win)
    end
    if not others then
      vim.api.nvim_open_win(vim.api.nvim_create_buf(true, false), true, { split = "left", win = -1 })
    end
    local cur = vim.api.nvim_get_current_win()
    for _, win in ipairs(wins) do
      if win == cur then
        M.to_code(S)
      end
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  if agent().get() ~= S then
    for _, buf in ipairs({ p.tbuf, p.ibuf }) do
      if buf and vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
    S.panel = nil
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

---Redraws the divider, for the spinner.
---@param S leader_k.Conversation
function M.tick(S)
  local p = S.panel
  if p and valid(p.iwin) then
    set_wo(p.iwin, "winbar", divider(S, vim.api.nvim_win_get_width(p.iwin)))
  end
end

---Opens or updates the panel to match the conversation.
---@param S leader_k.Conversation
function M.sync(S)
  local p = state(S)
  if not (p.tbuf and vim.api.nvim_buf_is_valid(p.tbuf)) then
    p.tbuf, p.joined = create_transcript(S), nil
  end
  if not (p.ibuf and vim.api.nvim_buf_is_valid(p.ibuf)) then
    p.ibuf = create_input(S)
  end
  local buf = p.tbuf
  local lines, marks, latest, file_rows = transcript(S)
  p.file_rows = file_rows
  if #lines == 0 then
    lines = { "" }
  end
  local joined = table.concat(lines, "\n")
  if joined ~= p.joined then
    p.joined = joined
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    local rows = {}
    for _, m in ipairs(marks) do
      if m.kind == "user" then
        rows[m.row + 1] = true
        vim.api.nvim_buf_set_extmark(buf, ns, m.row, 0, { line_hl_group = m.group })
      else
        vim.api.nvim_buf_set_extmark(buf, ns, m.row, m.col or 0, {
          end_col = m.end_col or #lines[m.row + 1],
          hl_group = m.group,
          priority = 200,
          strict = false,
        })
      end
    end
    user_rows[buf] = rows
  end

  if not valid(p.twin) then
    open_windows(S)
  end
  local twin = p.twin --[[@as integer]]
  local iwin = p.iwin --[[@as integer]]
  set_wo(iwin, "winbar", divider(S, vim.api.nvim_win_get_width(iwin)))
  refresh_input(S)

  -- Follow the stream, then show the latest message from its start, with
  -- earlier ones above it when they fit, unless the user is reading the
  -- transcript.
  if vim.api.nvim_get_current_win() ~= twin and #lines > 0 then
    if S.state == "running" then
      vim.api.nvim_win_set_cursor(twin, { #lines, 0 })
    elseif p.shown ~= #S.items then
      p.shown = #S.items
      local rest = vim.api.nvim_win_text_height(twin, { start_row = latest }).all
      vim.api.nvim_win_call(twin, function()
        if rest <= vim.api.nvim_win_get_height(twin) then
          vim.api.nvim_win_set_cursor(twin, { #lines, 0 })
          vim.cmd("normal! zb")
        else
          vim.api.nvim_win_set_cursor(twin, { latest + 1, 0 })
          vim.fn.winrestview({ topline = latest + 1 })
        end
      end)
    end
  end
end

return M
