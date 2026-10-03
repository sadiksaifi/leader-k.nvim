-- The instruction prompt: a small float anchored to the selection, so the
-- question is asked where the code is.

local M = {}

local history = {} ---@type string[]
local MAX_HISTORY = 100
local MAX_HEIGHT = 6
local ns = vim.api.nvim_create_namespace("leader-k.input")

---@class leader_k.InputOpts
---@field win integer Window showing the code.
---@field r0 integer First selected row, 0-based.
---@field r1 integer Last selected row, 0-based.
---@field title string
---@field footer string
---@field placeholder string
---@field default string|nil
---@field allow_empty boolean|nil
---@field on_submit fun(text: string)
---@field on_cancel fun()
---@field on_layout fun(rows: integer) Screen rows the float needs above the selection, 0 once closed.

---@param pwin integer
local function border_rows(pwin)
  local b = vim.api.nvim_win_get_config(pwin).border
  if b == nil or b == "none" or b == "" then
    return 0
  end
  if type(b) == "table" then
    local top = b[2] or b[1]
    local bottom = b[6] or b[#b > 1 and 2 or 1]
    local function empty(x)
      return x == nil or x == "" or (type(x) == "table" and (x[1] == nil or x[1] == ""))
    end
    return (empty(top) and 0 or 1) + (empty(bottom) and 0 or 1)
  end
  return 2
end

---Adds a sent request to the history.
---@param t string
function M.remember(t)
  for i = #history, 1, -1 do
    if history[i] == t then
      table.remove(history, i)
    end
  end
  history[#history + 1] = t
  if #history > MAX_HISTORY then
    table.remove(history, 1)
  end
end

---Maps Up and Down in Insert mode to step through the history in `buf`,
---keeping what was typed as a draft past the newest entry.
---@param buf integer
---@return fun() reset Starts the next recall from the newest entry.
function M.map_history(buf)
  local pos, draft = #history + 1, nil
  local function recall(step)
    if #history == 0 then
      return
    end
    if pos > #history then
      draft = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end
    pos = math.max(1, math.min(#history + 1, pos + step))
    local lines = pos > #history and (draft or { "" }) or vim.split(history[pos], "\n", { plain = true })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(0, { #lines, #lines[#lines] })
  end
  for lhs, step in pairs({ ["<Up>"] = -1, ["<Down>"] = 1 }) do
    vim.keymap.set("i", lhs, function()
      recall(step)
    end, { buffer = buf, nowait = true, silent = true })
  end
  return function()
    pos, draft = #history + 1, nil
  end
end

---@param opts leader_k.InputOpts
function M.open(opts)
  local win = opts.win
  local buf = vim.api.nvim_win_get_buf(win)
  local info = vim.fn.getwininfo(win)[1]
  local first = vim.api.nvim_buf_get_lines(buf, opts.r0, opts.r0 + 1, false)[1] or ""
  local indent_col = vim.fn.strdisplaywidth(first:match("^%s*"))
  if indent_col >= info.width - info.textoff - 30 then
    indent_col = 0
  end
  local avail = info.width - info.textoff - indent_col - 2
  local width = math.max(math.min(avail, 76), math.min(30, info.width - 2))

  -- The float sits in blank virtual lines the caller reserves above the
  -- selection (see `on_layout`), so it never covers code.
  local config = {
    relative = "win",
    win = win,
    bufpos = { opts.r0, 0 },
    anchor = "SW",
    row = 0,
    col = math.max(indent_col - 1, 0),
    width = width,
    height = 1,
    style = "minimal",
    title = opts.title,
    title_pos = "left",
    footer = opts.footer,
    footer_pos = "right",
    zindex = 60,
  }

  local pbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[pbuf].bufhidden = "wipe"
  vim.bo[pbuf].filetype = "leader_k_prompt"
  pcall(vim.api.nvim_buf_set_name, pbuf, "leader-k://instruction")
  vim.b[pbuf].completion = false -- blink.cmp
  if opts.default and opts.default ~= "" then
    vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, vim.split(opts.default, "\n", { plain = true }))
  end

  local origin_cursor = vim.api.nvim_win_get_cursor(win)
  local pwin = vim.api.nvim_open_win(pbuf, true, config)
  local borders = border_rows(pwin)
  local reserved = -1
  vim.wo[pwin].wrap = true
  vim.wo[pwin].linebreak = true
  vim.wo[pwin].winhighlight = "FloatFooter:LeaderKFooter"

  local closed = false

  local function text()
    return vim.trim(table.concat(vim.api.nvim_buf_get_lines(pbuf, 0, -1, false), "\n"))
  end

  local function refresh()
    if closed or not vim.api.nvim_win_is_valid(pwin) then
      return
    end
    vim.api.nvim_buf_clear_namespace(pbuf, ns, 0, -1)
    local lines = vim.api.nvim_buf_get_lines(pbuf, 0, -1, false)
    if #lines == 1 and lines[1] == "" then
      vim.api.nvim_buf_set_extmark(pbuf, ns, 0, 0, {
        virt_text = { { opts.placeholder, "LeaderKPlaceholder" } },
        virt_text_pos = "overlay",
      })
    end
    local h = math.max(1, math.min(vim.api.nvim_win_text_height(pwin, {}).all, MAX_HEIGHT))
    vim.api.nvim_win_set_height(pwin, h)
    if h + borders ~= reserved then
      reserved = h + borders
      opts.on_layout(reserved)
    end
  end

  local function close()
    if closed then
      return
    end
    closed = true
    if vim.api.nvim_win_is_valid(pwin) then
      vim.api.nvim_win_close(pwin, true)
    end
    opts.on_layout(0)
    local inserting = vim.fn.mode():find("^i") ~= nil
    vim.cmd.stopinsert()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
      -- Leaving Insert mode moves the cursor left; put it back afterwards.
      local function restore()
        if vim.api.nvim_win_is_valid(win) then
          pcall(vim.api.nvim_win_set_cursor, win, origin_cursor)
        end
      end
      if inserting then
        vim.api.nvim_create_autocmd("InsertLeave", { once = true, callback = vim.schedule_wrap(restore) })
      else
        restore()
      end
    end
  end

  local function submit()
    local t = text()
    if t == "" and not opts.allow_empty then
      return
    end
    if t ~= "" then
      M.remember(t)
    end
    close()
    opts.on_submit(t)
  end

  local function cancel()
    if closed then
      return
    end
    close()
    opts.on_cancel()
  end

  local map = function(modes, lhs, fn)
    vim.keymap.set(modes, lhs, fn, { buffer = pbuf, nowait = true, silent = true })
  end
  map({ "i", "n" }, "<CR>", submit)
  map({ "i", "n" }, "<C-c>", cancel)
  map("n", "<Esc>", cancel)
  -- With nothing typed, Esc cancels at once. Otherwise it goes to Normal
  -- mode for editing, as usual, and a second Esc cancels.
  vim.keymap.set("i", "<Esc>", function()
    if text() == "" then
      vim.schedule(cancel)
      return ""
    end
    return "<Esc>"
  end, { buffer = pbuf, expr = true, nowait = true, silent = true })
  map("n", "q", cancel)
  M.map_history(pbuf)

  local group = vim.api.nvim_create_augroup("leader-k.input", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = pbuf,
    callback = refresh,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    buffer = pbuf,
    once = true,
    callback = function()
      vim.schedule(cancel)
    end,
  })

  refresh()
  vim.cmd.startinsert({ bang = true })
end

return M
