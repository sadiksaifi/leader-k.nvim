-- One conversation: a prompt, a request, then a proposed edit to review or
-- an answer to read, and follow-ups. It starts on a selection, and each
-- follow-up can attach a new one, in any buffer. Edits replace the latest
-- selection. One conversation exists at a time.

local answer = require("leader-k.answer")
local config = require("leader-k.config")
local context = require("leader-k.context")
local prompt = require("leader-k.prompt")
local provider = require("leader-k.provider")
local render = require("leader-k.render")

local M = {}

local mark_ns = vim.api.nvim_create_namespace("leader-k.region")
local flash_ns = vim.api.nvim_create_namespace("leader-k.flash")
local attach_ns = vim.api.nvim_create_namespace("leader-k.attach")
local FRAME_MS = 80

---@type leader_k.Session|nil
local current

-- How long a conversation can be resumed after its proposal is accepted.
local RESUME_MS = 120000

---@class leader_k.Recent
---@field buf integer
---@field mark integer Extmark over the accepted lines.
---@field turns leader_k.Turn[]
---@field ctx leader_k.Context
---@field mode leader_k.Mode
---@field seen string[]
---@field expires integer

---The last accepted conversation.
---@type leader_k.Recent|nil
local recent

local function forget()
  local r = recent
  recent = nil
  if r and vim.api.nvim_buf_is_valid(r.buf) then
    pcall(vim.api.nvim_buf_del_extmark, r.buf, mark_ns, r.mark)
  end
end

---Returns the accepted conversation to resume for a request on rows r0..r1,
---and the rows it covers now, or nil.
---@param buf integer
---@param r0 integer
---@param r1 integer
---@param mode leader_k.Mode
---@return leader_k.Recent|nil, integer|nil, integer|nil
local function resumable(buf, r0, r1, mode)
  local r = recent
  if not r or r.buf ~= buf then
    return nil
  end
  local m = vim.api.nvim_buf_get_extmark_by_id(buf, mark_ns, r.mark, { details = true })
  if not m[1] or vim.uv.now() > r.expires then
    forget()
    return nil
  end
  local q0, q1 = m[1], math.max(m[1], m[3].end_row or m[1])
  -- The same lines, or the cursor line inside them in Normal mode.
  local hit = (r0 == q0 and r1 == q1) or (r0 == r1 and r0 >= q0 and r0 <= q1)
  if not hit or r.mode ~= mode then
    return nil
  end
  return r, q0, q1
end

---A selection: rows of a buffer, and its characters when characterwise.
---@class leader_k.Target
---@field buf integer
---@field win integer The window it was selected in.
---@field mark integer
---@field focus_marks integer[]|nil Highlighted characters of a characterwise selection, one mark per line.

---@class leader_k.Session: leader_k.Target The selection edits replace.
---@field mark_ns integer
---@field original string[] The selected lines a proposal replaces.
---@field seen string[] The selected lines as the model last saw them.
---@field ctx leader_k.Context
---@field filetype string
---@field indent_width integer
---@field model_label string
---@field mode leader_k.Mode
---@field state "prompt"|"running"|"review"|"answered"|"closed"
---@field phase "waiting"|"thinking"|"writing"|"answering"|nil
---@field turns leader_k.Turn[]
---@field instruction string|nil
---@field proposal string[]|nil
---@field hunks integer[][]|nil
---@field added integer
---@field removed integer
---@field raw string
---@field answer_text string|nil The answer streamed so far.
---@field answer_win integer|nil
---@field answer_buf integer|nil
---@field answer_lines string|nil Text the answer buffer holds.
---@field answer_shown integer|nil Turn the panel last scrolled to.
---@field input_win integer|nil The panel's follow-up input.
---@field input_buf integer|nil
---@field error string|nil The last failure, kept for callers and tests.
---@field prev table|nil The review a refine started from, restored if it fails.
---@field pending leader_k.Target|nil A selection attached to the next follow-up.
---@field pending_drawn integer|nil Buffer that holds the highlight of `pending`.
---@field stale boolean
---@field cancel fun()|nil
---@field timer uv.uv_timer_t|nil
---@field dirty boolean Text arrived since the proposal was last parsed.
---@field saved_maps table[]
---@field augroup integer
---@field busy boolean
---@field resumed boolean Continues a conversation whose proposal was accepted.
---@field reveal boolean Scroll virtual lines above the selection into view on the next draw.
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

---@param buf integer
---@param r0 integer
---@param r1 integer
---@return integer mark Extmark over rows r0..r1 that grows with edits inside them.
local function region_mark(buf, r0, r1)
  local last = vim.api.nvim_buf_get_lines(buf, r1, r1 + 1, false)[1] or ""
  return vim.api.nvim_buf_set_extmark(buf, mark_ns, r0, 0, {
    end_row = r1,
    end_col = #last,
    right_gravity = true,
    end_right_gravity = false,
  })
end

---@param buf integer
---@param mark integer
---@return integer r0, integer r1 0-based rows, inclusive; r1 < r0 once the mark is gone.
local function region_of(buf, mark)
  local m = vim.api.nvim_buf_get_extmark_by_id(buf, mark_ns, mark, { details = true })
  if not m[1] then
    return 0, -1
  end
  return m[1], math.max(m[1], m[3].end_row or m[1])
end

---@param buf integer
---@param marks integer[]|nil
---@return { [1]: integer, [2]: integer, [3]: integer, [4]: integer }[] ranges row, col, end row, end col
local function ranges_of(buf, marks)
  local out = {}
  for _, id in ipairs(marks or {}) do
    local m = vim.api.nvim_buf_get_extmark_by_id(buf, mark_ns, id, { details = true })
    if m[1] then
      out[#out + 1] = { m[1], m[2], m[3].end_row or m[1], m[3].end_col or m[2] }
    end
  end
  return out
end

---@param buf integer
---@param marks integer[]|nil
---@return string|nil
local function text_of(buf, marks)
  if not marks then
    return nil
  end
  local parts = {}
  for _, r in ipairs(ranges_of(buf, marks)) do
    vim.list_extend(parts, vim.api.nvim_buf_get_text(buf, r[1], r[2], r[3], r[4], {}))
  end
  return table.concat(parts, "\n")
end

---Builds a target for rows r0..r1 of `buf`.
---@param win integer
---@param buf integer
---@param r0 integer
---@param r1 integer
---@param focus integer[][]|nil { row, start col, end col (exclusive) } per line, 0-based.
---@return leader_k.Target
local function new_target(win, buf, r0, r1, focus)
  local t = { buf = buf, win = win, mark = region_mark(buf, r0, r1) }
  if focus then
    t.focus_marks = {}
    for _, f in ipairs(focus) do
      local row = f[1]
      local len = #(vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "")
      local c0 = math.min(f[2], len)
      local c1 = math.max(c0, math.min(f[3], len))
      table.insert(
        t.focus_marks,
        vim.api.nvim_buf_set_extmark(buf, mark_ns, row, c0, { end_row = row, end_col = c1, end_right_gravity = true })
      )
    end
    -- Whole lines selected characterwise are a linewise selection.
    local lines = vim.api.nvim_buf_get_lines(buf, r0, r1 + 1, false)
    if text_of(buf, t.focus_marks) == table.concat(lines, "\n") then
      for _, id in ipairs(t.focus_marks) do
        pcall(vim.api.nvim_buf_del_extmark, buf, mark_ns, id)
      end
      t.focus_marks = nil
    end
  end
  return t
end

---@param t leader_k.Target|nil
local function free_target(t)
  if not (t and vim.api.nvim_buf_is_valid(t.buf)) then
    return
  end
  pcall(vim.api.nvim_buf_del_extmark, t.buf, mark_ns, t.mark)
  for _, id in ipairs(t.focus_marks or {}) do
    pcall(vim.api.nvim_buf_del_extmark, t.buf, mark_ns, id)
  end
end

---@param t leader_k.Target
---@return string label such as "lines 3-9 of sample.lua".
local function describe(t)
  local r0, r1 = region_of(t.buf, t.mark)
  local name = vim.api.nvim_buf_get_name(t.buf)
  return answer.label(name ~= "" and name or "[unnamed buffer]", r0, r1, t.focus_marks ~= nil)
end

---@return leader_k.Target
function Session:target()
  return { buf = self.buf, win = self.win, mark = self.mark, focus_marks = self.focus_marks }
end

---Makes `t` the selection edits replace.
---@param t leader_k.Target
function Session:set_target(t)
  if self.buf and t.buf ~= self.buf then
    self:restore_maps()
    render.clear(self.buf)
  end
  self.buf, self.win, self.mark, self.focus_marks = t.buf, t.win, t.mark, t.focus_marks
  self.filetype = vim.bo[t.buf].filetype
  self.original = self:region_lines()
  local first = self.original[1] or ""
  for _, l in ipairs(self.original) do
    if l:find("%S") then
      first = l
      break
    end
  end
  self.indent_width = vim.fn.strdisplaywidth(first:match("^%s*"))
end

---What the input shows as attached to the next message, if anything.
---@return string|nil
function Session:attachment()
  if self.pending then
    return describe(self.pending)
  end
  if self.state == "prompt" and #self.turns == 0 then
    return describe(self:target())
  end
end

-- Highlights the selection attached to the next follow-up.
function Session:draw_pending()
  if self.pending_drawn and vim.api.nvim_buf_is_valid(self.pending_drawn) then
    vim.api.nvim_buf_clear_namespace(self.pending_drawn, attach_ns, 0, -1)
  end
  self.pending_drawn = nil
  local a = self.pending
  if not (a and vim.api.nvim_buf_is_valid(a.buf)) then
    return
  end
  self.pending_drawn = a.buf
  local ranges = ranges_of(a.buf, a.focus_marks)
  for _, f in ipairs(ranges) do
    vim.api.nvim_buf_set_extmark(a.buf, attach_ns, f[1], f[2], {
      end_row = f[3],
      end_col = f[4],
      hl_group = "LeaderKSelection",
      priority = 150,
      strict = false,
    })
  end
  if #ranges == 0 then
    local r0, r1 = region_of(a.buf, a.mark)
    for row = r0, r1 do
      vim.api.nvim_buf_set_extmark(a.buf, attach_ns, row, 0, {
        line_hl_group = "LeaderKSelection",
        priority = 150,
        strict = false,
      })
    end
  end
end

function Session:drop_pending()
  free_target(self.pending)
  self.pending = nil
  self:draw_pending()
end

---Attaches rows r0..r1 of `buf` to the next message. Before the first
---request, it replaces the selection instead.
---@param win integer
---@param buf integer
---@param r0 integer
---@param r1 integer
---@param focus integer[][]|nil See new_target().
function Session:attach(win, buf, r0, r1, focus)
  local t = new_target(win, buf, r0, r1, focus)
  if self.state == "prompt" and #self.turns == 0 then
    local old = self:target()
    self:set_target(t)
    free_target(old)
  else
    self:drop_pending()
    self.pending = t
  end
  self:draw()
end

function Session:draw()
  -- The panel first: whether it is open decides what the code shows.
  answer.sync(self)
  render.draw(self)
  self:draw_pending()
end

---Wraps code in a Markdown fence for the answer view.
---@param code string
function Session:fence(code)
  return ("```%s\n%s\n```"):format(self.filetype, code)
end

-- Parses the reply streamed so far. Runs at most once per frame: the work
-- grows with the reply, so parsing on every delta is quadratic.
function Session:update_proposal()
  if not self.dirty then
    return
  end
  self.dirty = false
  local ex = prompt.extract(self.raw, false, prompt.untagged[self.mode])
  if ex.kind == "answer" or (ex.kind == "code" and self.mode == "ask") then
    self.phase = "answering"
    self.answer_text = ex.kind == "answer" and ex.text or self:fence(ex.text)
  elseif ex.kind == "code" then
    self.phase = "writing"
    self.proposal = prompt.lines(ex.text, self.ctx, false, self.original)
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
  if current == self then
    current = nil
  end
  self:end_request()
  self:stop_timer()
  self:set_busy(false)
  pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  answer.close(self)
  self:drop_pending()
  self:drop_prev()
  if vim.api.nvim_buf_is_valid(self.buf) then
    render.clear(self.buf)
    free_target(self:target())
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
      return self.state == "review" or self.state == "answered"
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

---@return { [1]: integer, [2]: integer, [3]: integer, [4]: integer }[] ranges row, col, end row, end col
function Session:focus_ranges()
  return ranges_of(self.buf, self.focus_marks)
end

---@return string|nil
function Session:focus_text()
  return text_of(self.buf, self.focus_marks)
end

function Session:build_context()
  local r0, r1 = render.region(self)
  self.ctx = context.build(self.buf, r0, r1, self.original, self:focus_text())
end

-- Snapshot of the review a refine starts from.
function Session:save_review()
  self.prev = {
    state = self.state,
    original = self.original,
    seen = self.seen,
    turns = vim.deepcopy(self.turns),
    instruction = self.instruction,
    proposal = self.proposal,
    hunks = self.hunks,
    added = self.added,
    removed = self.removed,
  }
end

---Forgets the review a refine started from, once the refine succeeds.
function Session:drop_prev()
  local p = self.prev
  self.prev = nil
  if p and p.target then
    -- The refine moved to an attached selection.
    free_target(p.target)
    if p.target.buf ~= self.buf and vim.api.nvim_buf_is_valid(p.target.buf) then
      render.clear(p.target.buf)
    end
  end
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
  if p.target then
    -- Back to the earlier selection; the new one waits for the next try.
    if self.pending then
      free_target(self:target())
    else
      self.pending = self:target()
    end
    self:set_target(p.target)
    self.ctx = p.ctx
    self:install_maps()
  end
  self.turns, self.instruction = p.turns, p.instruction
  self.original, self.seen = p.original, p.seen
  self.proposal, self.hunks, self.added, self.removed = p.proposal, p.hunks, p.added, p.removed
  self.state, self.phase, self.answer_text = p.state, nil, nil
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
  self.answer_text = nil
  self.added, self.removed = 0, 0
  self.instruction = self.turns[#self.turns].instruction

  local messages = prompt.messages(self.turns, self.mode)
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
  self:set_busy(true)
  self:start_timer()
  self:draw()
end

---Tells the user where a reply landed when they are looking elsewhere.
---@param what string
function Session:notify_ready(what)
  if vim.api.nvim_get_current_buf() ~= self.buf and not answer.focused(self) then
    local r0 = render.region(self)
    vim.api.nvim_echo({
      { ("leader-k: %s ready in "):format(what) },
      { ("%s:%d"):format(self.ctx.path, r0 + 1), "Directory" },
    }, false, {})
  end
end

---@param finish_reason string|nil
function Session:finish(finish_reason)
  self:stop_timer()
  self:set_busy(false)
  local ex = prompt.extract(self.raw, true, prompt.untagged[self.mode])
  if ex.kind == "error" then
    return self:fail("the model declined: " .. (ex.text ~= "" and ex.text or "no reason given"))
  end
  if vim.trim(self.raw) == "" then
    return self:fail("the model returned an empty reply")
  end
  local turn = self.turns[#self.turns]
  if self.resumed then
    self.resumed = false
    forget()
  end
  if ex.kind == "answer" or self.mode == "ask" then
    local text = ex.kind == "answer" and ex.text or self:fence(ex.text)
    if vim.trim(text) == "" then
      return self:fail("the model returned an empty reply")
    end
    -- Part of an answer still helps, unlike part of an edit.
    if finish_reason == "length" then
      text = text .. "\n\n*The reply hit the model's output limit before it finished.*"
    end
    turn.answer, turn.proposal = text, nil
    self:drop_prev()
    self.answer_text = nil
    self.state, self.phase = "answered", nil
    self:draw()
    self:notify_ready("answer")
    return
  end
  if finish_reason == "length" then
    return self:fail("the reply hit the model's output limit before it finished")
  end
  self.proposal = prompt.lines(ex.text, self.ctx, true, self.original)
  self.hunks = diff(self.original, self.proposal)
  self.added, self.removed = 0, 0
  for _, h in ipairs(self.hunks) do
    self.removed = self.removed + h[2]
    self.added = self.added + h[4]
  end
  turn.proposal, turn.answer = self.proposal, nil
  self:drop_prev()
  self.state, self.phase = "review", nil
  self.stale = not same_lines(self:region_lines(), self.original)
  self.reveal = true
  self:draw()
  -- A proposal is reviewed in the code.
  if answer.focused(self) then
    answer.to_code(self)
  end
  self:notify_ready("proposal")
end

---Keeps the conversation after its proposal is applied to rows r0..r1, so
---asking again on those lines soon after continues it.
---@param r0 integer
---@param r1 integer
---@param lines string[]
function Session:remember(r0, r1, lines)
  forget()
  local turns = vim.deepcopy(self.turns)
  turns[#turns].applied = true
  recent = {
    buf = self.buf,
    mark = vim.api.nvim_buf_set_extmark(self.buf, mark_ns, r0, 0, {
      end_row = r1,
      end_col = #lines[#lines],
      right_gravity = true,
      end_right_gravity = false,
    }),
    turns = turns,
    ctx = self.ctx,
    mode = self.mode,
    seen = lines,
    expires = vim.uv.now() + RESUME_MS,
  }
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
  if not vim.bo[self.buf].modifiable then
    vim.api.nvim_echo({ { "leader-k: this buffer is not modifiable", "WarningMsg" } }, false, {})
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
    self:remember(r0, r0 + #lines - 1, lines)
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

---Sends a follow-up to the conversation, with the attached selection if
---there is one. Empty text regenerates the last reply.
---@param text string
---@return boolean sent
function Session:follow_up(text)
  local state = self.state
  if current ~= self or #self.turns == 0 or (state ~= "review" and state ~= "answered" and state ~= "prompt") then
    return false
  end
  -- Regenerating needs a reply to replace and keeps its selection.
  if text == "" and (state == "prompt" or self.pending) then
    return false
  end
  local last = self.turns[#self.turns]
  self:save_review()
  if state ~= "review" then
    -- The code may have changed since the last request. An edit replaces
    -- what is there now.
    self.original, self.stale = self:region_lines(), false
  end
  if text == "" then
    last.proposal, last.answer = nil, nil -- Regenerate the same turn.
  else
    local turn = { instruction = text }
    if self.pending then
      self.prev.target, self.prev.ctx = self:target(), self.ctx
      local t = self.pending
      self.pending = nil
      self:set_target(t)
      self.seen, self.stale = self.original, false
      self:build_context()
      turn.attach = self.ctx
    elseif not same_lines(self.original, self.seen) then
      self.seen, turn.selection = self.original, self.original
    end
    table.insert(self.turns, turn)
  end
  self:send()
  return true
end

---Sends the text typed in the panel input: the first request, or a
---follow-up.
---@param text string
---@return boolean sent
function Session:submit(text)
  if self.state ~= "prompt" or #self.turns > 0 then
    return self:follow_up(text)
  end
  if text == "" then
    return false
  end
  -- Read the selection again in case it changed while typing.
  self.original = self:region_lines()
  self.seen = self.original
  self:build_context()
  self.turns = { { instruction = text, attach = self.ctx } }
  self:send()
  return true
end

---Moves focus into the panel input.
function Session:refine()
  answer.focus_input(self)
end

---Starts a conversation on rows r0..r1 (0-based, inclusive) of the current
---window and opens the panel with its input focused, or sends
---`instruction` directly when given. During a conversation, attaches
---`opts.selection` rows to the next message, or only focuses the input.
---@param r0 integer
---@param r1 integer
---@param instruction string|nil
---@param opts { mode: leader_k.Mode|nil, focus: integer[][]|nil, selection: boolean|nil }|nil `focus`: see new_target(). `selection`: the rows were selected, not just the cursor line.
function M.start(r0, r1, instruction, opts)
  opts = opts or {}
  local mode = opts.mode or "auto"
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  instruction = vim.trim(instruction or "")
  local s = current
  if s then
    if opts.selection then
      if s.mode == "edit" and not vim.bo[buf].modifiable then
        vim.api.nvim_echo({ { "leader-k: this buffer is not modifiable", "WarningMsg" } }, false, {})
        return
      end
      s:attach(win, buf, r0, r1, opts.focus)
    end
    if instruction == "" then
      answer.focus_input(s)
    elseif not s:submit(instruction) then
      vim.api.nvim_echo({
        { "leader-k: a request is already running. " },
        { render.key_label(config.options.keys.cancel), "Special" },
        { " stops it." },
      }, false, {})
    end
    return
  end
  -- A read-only buffer can still be asked about.
  if mode == "auto" and not vim.bo[buf].modifiable then
    mode = "ask"
  end
  if mode == "edit" and not vim.bo[buf].modifiable then
    vim.api.nvim_echo({ { "leader-k: this buffer is not modifiable", "WarningMsg" } }, false, {})
    return
  end
  -- Report missing settings before opening a prompt that cannot be sent.
  local _, config_err = config.endpoint()
  if config_err then
    vim.api.nvim_echo({ { "leader-k: " .. config_err } }, true, { err = true })
    return
  end
  local resume
  if not opts.focus then
    local q0, q1
    resume, q0, q1 = resumable(buf, r0, r1, mode)
    if resume then
      r0, r1 = assert(q0), assert(q1)
    end
  end

  local self = setmetatable({
    mode = mode,
    mark_ns = mark_ns,
    state = "prompt",
    turns = {},
    added = 0,
    removed = 0,
    raw = "",
    stale = false,
    dirty = false,
    busy = false,
    reveal = false,
    resumed = resume ~= nil,
    model_label = model_label(config.options.model or ""),
  }, Session)
  self:set_target(new_target(win, buf, r0, r1, opts.focus))
  if resume then
    self.ctx, self.turns, self.seen = resume.ctx, vim.deepcopy(resume.turns), resume.seen
  end
  current = self

  self.augroup = vim.api.nvim_create_augroup("leader-k.session", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = self.augroup,
    callback = function(ev)
      if ev.buf == self.buf then
        self:check_stale()
      end
      if self.pending and ev.buf == self.pending.buf then
        self:draw_pending()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = self.augroup,
    callback = function(ev)
      if ev.buf == self.buf then
        self:destroy()
      elseif self.pending and ev.buf == self.pending.buf then
        self:drop_pending()
        self:draw()
      elseif self.prev and self.prev.target and ev.buf == self.prev.target.buf then
        -- A failed refine can no longer return there.
        self.prev = nil
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = self.augroup,
    callback = function()
      self:draw()
    end,
  })

  if instruction ~= "" then
    self:submit(instruction)
    return
  end
  self:draw()
  answer.focus_input(self)
end

---The conversation when its edits target `buf`.
---@param buf integer
---@return leader_k.Session|nil
function M.get(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  if current and current.buf == buf then
    return current
  end
end

---@return leader_k.Session|nil
function M.current()
  return current
end

---Stops the conversation. Used on exit.
function M.stop_all()
  if current then
    current:destroy()
  end
end

return M
