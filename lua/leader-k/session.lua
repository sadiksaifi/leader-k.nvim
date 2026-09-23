-- One edit of one selection: prompt, request, review, and the way back to
-- the code. At most one session exists per buffer.

local config = require("leader-k.config")
local input = require("leader-k.input")
local prompt = require("leader-k.prompt")
local provider = require("leader-k.provider")
local render = require("leader-k.render")

local M = {}

local mark_ns = vim.api.nvim_create_namespace("leader-k.region")
local flash_ns = vim.api.nvim_create_namespace("leader-k.flash")
local FRAME_MS = 80

---@type table<integer, leader_k.Session>
local sessions = {}

---@class leader_k.Session
---@field buf integer
---@field win integer
---@field mark integer
---@field mark_ns integer
---@field original string[]
---@field ctx leader_k.Context
---@field filetype string
---@field indent_width integer
---@field model_label string
---@field state "prompt"|"running"|"review"|"closed"
---@field phase "waiting"|"thinking"|"writing"|nil
---@field turns leader_k.Turn[]
---@field instruction string|nil
---@field proposal string[]|nil
---@field hunks integer[][]|nil
---@field added integer
---@field removed integer
---@field raw string
---@field error string|nil The last failure, kept for callers and tests.
---@field prev table|nil The review a refine started from, restored if it fails.
---@field stale boolean
---@field cancel fun()|nil
---@field timer uv.uv_timer_t|nil
---@field dirty boolean Text arrived since the proposal was last parsed.
---@field saved_maps table[]
---@field augroup integer
---@field busy boolean
---@field reserve integer Blank rows kept above the selection for the prompt float.
---@field reveal boolean Scroll the header into view on the next draw.
---@field spans_for string[]|nil Proposal the cached syntax spans belong to.
---@field spans table|nil
local Session = {}
Session.__index = Session

---@param a string[]
---@param b string[]
local function same_lines(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

---@param a string[]
---@param b string[]
local function diff(a, b)
  local sa = #a > 0 and table.concat(a, "\n") .. "\n" or ""
  local sb = #b > 0 and table.concat(b, "\n") .. "\n" or ""
  return vim.text.diff(sa, sb, { result_type = "indices", algorithm = "histogram", linematch = 40 }) --[[@as integer[][] ]]
end

---@param model string
local function model_label(model)
  return model:match("[^/]+$") or model
end

function Session:region_lines()
  local r0, r1 = render.region(self)
  if r1 < r0 then
    return {}
  end
  return vim.api.nvim_buf_get_lines(self.buf, r0, r1 + 1, false)
end

---@param r0 integer
---@param r1 integer
function Session:set_region(r0, r1)
  local last = vim.api.nvim_buf_get_lines(self.buf, r1, r1 + 1, false)[1] or ""
  self.mark = vim.api.nvim_buf_set_extmark(self.buf, mark_ns, r0, 0, {
    id = self.mark,
    end_row = r1,
    end_col = #last,
    right_gravity = true,
    end_right_gravity = false,
  })
end

---@param rows integer
function Session:set_reserve(rows)
  if rows == self.reserve then
    return
  end
  self.reserve = rows
  self.reveal = rows > 0
  self:draw()
end

function Session:draw()
  render.draw(self)
end

-- Parses the reply streamed so far. Runs at most once per frame: the work
-- grows with the reply, so parsing on every delta is quadratic.
function Session:update_proposal()
  if not self.dirty then
    return
  end
  self.dirty = false
  local ex = prompt.extract(self.raw, false)
  if ex.kind == "code" then
    self.phase = "writing"
    self.proposal = prompt.lines(ex.text, self.ctx, false)
    self.hunks = diff(self.original, self.proposal)
  elseif self.phase == "waiting" then
    self.phase = "thinking"
  end
end

function Session:start_timer()
  if self.timer then
    return
  end
  self.timer = assert(vim.uv.new_timer())
  self.timer:start(
    FRAME_MS,
    FRAME_MS,
    vim.schedule_wrap(function()
      if self.state == "running" then
        self:update_proposal()
        self:draw()
      end
    end)
  )
end

function Session:stop_timer()
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
end

---@param on boolean
function Session:set_busy(on)
  if on == self.busy or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  self.busy = on
  pcall(function()
    local b = vim.bo[self.buf].busy
    vim.bo[self.buf].busy = math.max(0, b + (on and 1 or -1))
  end)
end

-- Closes the request's connection, if one is open.
function Session:end_request()
  local cancel = self.cancel
  self.cancel = nil
  if cancel then
    cancel()
  end
end

function Session:destroy()
  self.state = "closed"
  if sessions[self.buf] == self then
    sessions[self.buf] = nil
  end
  self:end_request()
  self:stop_timer()
  self:set_busy(false)
  pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  if vim.api.nvim_buf_is_valid(self.buf) then
    render.clear(self.buf)
    pcall(vim.api.nvim_buf_del_extmark, self.buf, mark_ns, self.mark)
    self:restore_maps()
  end
end

---Runs what `lhs` does without the session's mapping: the mapping it
---shadows (`prev`, else a global one), or the built-in key. Called from
---inside the session's mapping, so v:count still holds the typed count.
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
    -- not mapped again. Here that also keeps the session's map from looping.
    vim.api.nvim_feedkeys(count .. raw, "n", false)
    vim.api.nvim_feedkeys(keys:sub(#raw + 1), "m", false)
  else
    vim.api.nvim_feedkeys(count .. keys, "m", false)
  end
end

-- Buffer-local keys live only as long as the session and put back whatever
-- they shadowed. Accept and reject act only while the region is on screen;
-- elsewhere the key keeps its normal meaning.
function Session:install_maps()
  if self.saved_maps then
    return
  end
  self.saved_maps = {}
  local keys = config.options.keys
  local function visible()
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(win) ~= self.buf then
      return false
    end
    local r0, r1 = render.region(self)
    local top, bot = vim.fn.line("w0", win) - 1, vim.fn.line("w$", win) - 1
    return r1 >= top - 1 and r0 <= bot + 1
  end
  local function map(lhs, fn, desc, guard)
    local prev = vim.fn.maparg(lhs, "n", false, true)
    if prev and prev.buffer == 1 then
      table.insert(self.saved_maps, prev)
    else
      prev = nil
    end
    table.insert(self.saved_maps, { lhs = lhs, unmap = true })
    vim.keymap.set("n", lhs, function()
      if guard and not guard() then
        run_shadowed(lhs, prev)
        return
      end
      fn()
    end, { buffer = self.buf, nowait = true, silent = true, desc = "leader-k: " .. desc })
  end
  map(
    keys.accept,
    function()
      self:accept()
    end,
    "accept",
    function()
      return self.state == "review" and visible()
    end
  )
  map(
    keys.reject,
    function()
      self:destroy()
    end,
    "reject",
    function()
      return self.state ~= "prompt" and visible()
    end
  )
  if keys.cancel ~= keys.reject then
    map(
      keys.cancel,
      function()
        self:stop()
      end,
      "stop",
      function()
        return self.state == "running"
      end
    )
  end
  map(
    keys.refine,
    function()
      self:refine()
    end,
    "refine",
    function()
      return self.state == "review"
    end
  )
end

function Session:restore_maps()
  if not self.saved_maps then
    return
  end
  for _, m in ipairs(self.saved_maps) do
    if m.unmap then
      pcall(vim.keymap.del, "n", m.lhs, { buffer = self.buf })
    end
  end
  for _, m in ipairs(self.saved_maps) do
    if not m.unmap then
      vim.api.nvim_buf_call(self.buf, function()
        vim.fn.mapset(m)
      end)
    end
  end
  self.saved_maps = nil
end

function Session:check_stale()
  if self.state ~= "running" and self.state ~= "review" then
    return
  end
  local stale = not same_lines(self:region_lines(), self.original)
  if stale ~= self.stale then
    self.stale = stale
    self:draw()
  end
end

function Session:build_context()
  local buf, r0, r1 = self.buf, render.region(self)
  local limit = config.options.context_bytes
  local name = vim.api.nvim_buf_get_name(buf)
  local diagnostics = {}
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    if d.lnum >= r0 and d.lnum <= r1 then
      local sev = vim.diagnostic.severity[d.severity] or "INFO"
      local msg = vim.split(d.message, "\n", { plain = true })[1]
      diagnostics[#diagnostics + 1] = ("- line %d of the selection: %s: %s"):format(d.lnum - r0 + 1, sev:lower(), msg)
    end
  end
  -- Send the whole file unless it is large; then keep whole lines nearest
  -- the selection, up to `limit` bytes on each side.
  local before = vim.api.nvim_buf_get_lines(buf, 0, r0, false)
  local after = vim.api.nvim_buf_get_lines(buf, r1 + 1, -1, false)
  local first, size = #before + 1, 0
  while first > 1 and size + #before[first - 1] + 1 <= limit do
    first = first - 1
    size = size + #before[first] + 1
  end
  local last
  last, size = 0, 0
  while last < #after and size + #after[last + 1] + 1 <= limit do
    last = last + 1
    size = size + #after[last] + 1
  end
  self.ctx = {
    path = name ~= "" and vim.fn.fnamemodify(name, ":~:.") or "[unnamed buffer]",
    filetype = vim.bo[buf].filetype,
    line_count = vim.api.nvim_buf_line_count(buf),
    first_row = r0 + 1,
    before = vim.list_slice(before, first),
    omitted_before = first - 1,
    selection = self.original,
    after = vim.list_slice(after, 1, last),
    omitted_after = #after - last,
    diagnostics = diagnostics,
  }
end

-- Snapshot of the review a refine starts from.
function Session:save_review()
  self.prev = {
    turns = vim.deepcopy(self.turns),
    instruction = self.instruction,
    proposal = self.proposal,
    hunks = self.hunks,
    added = self.added,
    removed = self.removed,
  }
end

---Returns to the review a refine started from. False if there is none.
function Session:restore_review()
  local p = self.prev
  if not p then
    return false
  end
  self.prev = nil
  self.cancel = nil
  self:stop_timer()
  self:set_busy(false)
  self.turns, self.instruction = p.turns, p.instruction
  self.proposal, self.hunks, self.added, self.removed = p.proposal, p.hunks, p.added, p.removed
  self.state, self.phase = "review", nil
  self.stale = not same_lines(self:region_lines(), self.original)
  self:draw()
  return true
end

---Stops a running request. A refine goes back to the proposal it refined.
function Session:stop()
  self:end_request()
  if not self:restore_review() then
    self:destroy()
  end
end

---Reports a failure in the message area and leaves the code as it was. A
---failed refine goes back to the proposal it refined.
---@param msg string
function Session:fail(msg)
  self:end_request()
  self.error = msg
  if not self:restore_review() then
    self:destroy()
  end
  vim.api.nvim_echo({ { "leader-k: " .. msg } }, true, { err = true })
end

function Session:send()
  local ep, err = config.endpoint()
  self:install_maps()
  if not ep then
    self:fail(err --[[@as string]])
    return
  end
  self.model_label = model_label(ep.model)
  self.state, self.phase = "running", "waiting"
  self.raw, self.proposal, self.hunks, self.error, self.dirty = "", nil, nil, nil, false
  self.added, self.removed = 0, 0
  self.instruction = self.turns[#self.turns].instruction

  local messages = prompt.messages(self.ctx, self.turns)
  local cancel, start_err = provider.stream(ep, messages, {
    on_reasoning = function()
      if self.phase == "waiting" then
        self.phase = "thinking"
      end
    end,
    on_text = function(delta)
      self.raw = self.raw .. delta
      self.dirty = true
    end,
    on_done = function(finish_reason)
      -- Some servers keep the connection open after [DONE].
      self:end_request()
      self:finish(finish_reason)
    end,
    on_error = function(msg)
      self:fail(msg)
    end,
  }, config.options.timeout_ms)
  if not cancel then
    self:fail(start_err or "could not start the request")
    return
  end
  self.cancel = cancel
  self.reveal = true
  self:set_busy(true)
  self:start_timer()
  self:draw()
end

---@param finish_reason string|nil
function Session:finish(finish_reason)
  self:stop_timer()
  self:set_busy(false)
  local ex = prompt.extract(self.raw, true)
  if ex.kind == "error" then
    return self:fail("the model declined: " .. (ex.text ~= "" and ex.text or "no reason given"))
  end
  if finish_reason == "length" then
    return self:fail("the reply hit the model's output limit before it finished")
  end
  if vim.trim(self.raw) == "" then
    return self:fail("the model returned an empty reply")
  end
  self.proposal = prompt.lines(ex.text, self.ctx, true)
  self.hunks = diff(self.original, self.proposal)
  self.added, self.removed = 0, 0
  for _, h in ipairs(self.hunks) do
    self.removed = self.removed + h[2]
    self.added = self.added + h[4]
  end
  self.turns[#self.turns].proposal = self.proposal
  self.prev = nil
  self.state, self.phase = "review", nil
  self.stale = not same_lines(self:region_lines(), self.original)
  self:draw()
  if vim.api.nvim_get_current_buf() ~= self.buf then
    local r0 = render.region(self)
    vim.api.nvim_echo({
      { "leader-k: proposal ready in " },
      { ("%s:%d"):format(self.ctx.path, r0 + 1), "Directory" },
    }, false, {})
  end
end

function Session:accept()
  if self.state ~= "review" then
    return
  end
  if self.stale or not same_lines(self:region_lines(), self.original) then
    self.stale = true
    self:draw()
    vim.api.nvim_echo({
      {
        "leader-k: the selection changed after the request. Undo your edit to accept, or reject the proposal.",
        "WarningMsg",
      },
    }, false, {})
    return
  end
  local r0, r1 = render.region(self)
  local lines = self.proposal or {}
  local buf = self.buf
  self:destroy()
  if self.added == 0 and self.removed == 0 then
    return
  end
  vim.api.nvim_buf_set_lines(buf, r0, r1 + 1, false, lines)
  if #lines > 0 then
    vim.hl.range(buf, flash_ns, "LeaderKFlash", { r0, 0 }, { r0 + #lines - 1, 0 }, {
      regtype = "V",
      timeout = 300,
    })
  end
  -- Land on the first line of the new code.
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) == buf then
    local row = math.min(r0 + 1, vim.api.nvim_buf_line_count(buf))
    local cur = vim.api.nvim_win_get_cursor(win)[1]
    if cur < r0 + 1 or cur > r0 + math.max(#lines, 1) then
      vim.api.nvim_win_set_cursor(win, { row, 0 })
      vim.cmd.normal({ "^", bang = true })
    end
  end
end

function Session:refine()
  if self.state ~= "review" then
    return
  end
  local r0, r1 = render.region(self)
  local last = self.turns[#self.turns]
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= self.buf then
    win = self.win
  end
  input.open({
    win = win,
    r0 = r0,
    r1 = r1,
    title = " Refine ",
    footer = " " .. model_label(config.options.model or "") .. " ",
    placeholder = "What should change? Enter alone regenerates",
    allow_empty = true,
    on_layout = function(rows)
      self:set_reserve(rows)
    end,
    on_submit = function(text)
      if sessions[self.buf] ~= self then
        return
      end
      self:save_review()
      if text == "" then
        last.proposal = nil -- Regenerate the same turn.
      else
        last.proposal = self.proposal
        table.insert(self.turns, { instruction = text })
      end
      self:send()
    end,
    on_cancel = function() end,
  })
end

---Starts a session for rows r0..r1 (0-based, inclusive) of the current window.
---Opens the prompt, or sends `instruction` directly when given.
---@param r0 integer
---@param r1 integer
---@param instruction string|nil
function M.start(r0, r1, instruction)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local existing = sessions[buf]
  if existing then
    if existing.state == "review" then
      existing:refine()
    elseif existing.state == "running" then
      vim.api.nvim_echo({
        { "leader-k: a request is already running in this buffer. " },
        { render.key_label(config.options.keys.cancel), "Special" },
        { " stops it." },
      }, false, {})
    end
    return
  end
  if not vim.bo[buf].modifiable then
    vim.api.nvim_echo({ { "leader-k: this buffer is not modifiable", "WarningMsg" } }, false, {})
    return
  end
  -- Report missing settings before opening a prompt that cannot be sent.
  local _, config_err = config.endpoint()
  if config_err then
    vim.api.nvim_echo({ { "leader-k: " .. config_err } }, true, { err = true })
    return
  end

  local self = setmetatable({
    buf = buf,
    win = win,
    mark_ns = mark_ns,
    state = "prompt",
    turns = {},
    added = 0,
    removed = 0,
    raw = "",
    stale = false,
    dirty = false,
    busy = false,
    reserve = 0,
    reveal = false,
    filetype = vim.bo[buf].filetype,
  }, Session)
  self:set_region(r0, r1)
  self.original = vim.api.nvim_buf_get_lines(buf, r0, r1 + 1, false)
  local first = self.original[1] or ""
  for _, l in ipairs(self.original) do
    if l:find("%S") then
      first = l
      break
    end
  end
  self.indent_width = vim.fn.strdisplaywidth(first:match("^%s*"))
  sessions[buf] = self

  self.augroup = vim.api.nvim_create_augroup("leader-k.session." .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = self.augroup,
    buffer = buf,
    callback = function()
      self:check_stale()
    end,
  })
  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = self.augroup,
    buffer = buf,
    callback = function()
      self:destroy()
    end,
  })
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = self.augroup,
    callback = function()
      if self.state ~= "prompt" then
        self:draw()
      end
    end,
  })

  local function submit(text)
    if sessions[buf] ~= self then
      return
    end
    -- Read the selection again in case it changed while typing.
    local r0_, r1_ = render.region(self)
    self.original = vim.api.nvim_buf_get_lines(buf, r0_, r1_ + 1, false)
    self:build_context()
    self.turns = { { instruction = text } }
    self:send()
  end

  if instruction and vim.trim(instruction) ~= "" then
    submit(vim.trim(instruction))
    return
  end

  -- Put the cursor on the selection's first line so the view keeps the
  -- prompt, which sits above that line, on screen.
  vim.api.nvim_win_set_cursor(win, { r0 + 1, 0 })
  vim.cmd.normal({ "^", bang = true })
  self.reserve = 0
  local n = r1 - r0 + 1
  input.open({
    win = win,
    r0 = r0,
    r1 = r1,
    title = n == 1 and (" Edit line %d "):format(r0 + 1) or (" Edit lines %d-%d "):format(r0 + 1, r1 + 1),
    footer = " " .. model_label(config.options.model or "no model set") .. " ",
    placeholder = "Describe the change. Enter sends, Esc cancels",
    on_layout = function(rows)
      self:set_reserve(rows)
    end,
    on_submit = submit,
    on_cancel = function()
      self:destroy()
    end,
  })
end

---@param buf integer
---@return leader_k.Session|nil
function M.get(buf)
  return sessions[buf == 0 and vim.api.nvim_get_current_buf() or buf]
end

---Stops every running request. Used on exit.
function M.stop_all()
  for _, s in pairs(sessions) do
    s:destroy()
  end
end

return M
