-- The conversation: one per editor. It holds the messages sent to the
-- model, the transcript shown in the panel, the attachments for the next
-- message, and the staged changes. A message runs the agent loop: stream a
-- reply, run its tool calls, send the results, until a reply has no calls.

local changes = require("leader-k.changes")
local config = require("leader-k.config")
local context = require("leader-k.context")
local provider = require("leader-k.provider")
local review = require("leader-k.review")
local root = require("leader-k.root")
local tools = require("leader-k.tools")

local M = {}

local FRAME_MS = 80
local attach_ns = vim.api.nvim_create_namespace("leader-k.attached")

---@class leader_k.Item
---@field kind "user"|"assistant"|"note"|"error"
---@field text string
---@field labels string[]|nil Attachments sent with a user message.

---@class leader_k.Conversation
---@field root string
---@field messages table[] Everything after the system prompt.
---@field items leader_k.Item[]
---@field attachments leader_k.Attachment[]
---@field changes leader_k.Changes
---@field decisions { rel: string, status: string }[] Review results the model has not heard yet.
---@field state "idle"|"running"
---@field phase "waiting"|"thinking"|"writing"|"tool"|nil
---@field activity string|nil What a running tool does.
---@field step integer Requests made for the current message.
---@field run table|nil Token of the running loop.
---@field cancel fun()|nil
---@field tool_cancel fun()|nil
---@field reply leader_k.Item|nil The streaming assistant item.
---@field before table<leader_k.Change, string[]> Staged text when the run started.
---@field origin_win integer|nil The code window the conversation works with.
---@field model_label string
---@field dirty boolean The transcript needs a redraw.
---@field timer uv.uv_timer_t|nil
---@field augroup integer
---@field confirm_close boolean
---@field files string[]|nil Project files for @path completion.

---@type leader_k.Conversation|nil
local S = nil

---@return leader_k.Conversation|nil
function M.get()
  return S
end

---@param msg string
local function echo_error(msg)
  vim.api.nvim_echo({ { "leader-k: " .. msg } }, true, { err = true })
end

---@param msg string
local function warn(msg)
  vim.api.nvim_echo({ { "leader-k: " .. msg, "WarningMsg" } }, false, {})
end

local function panel()
  return require("leader-k.panel")
end

---Redraws the panel. It opens the panel's windows only when `show` is set,
---so a reply streaming in does not reopen a panel the user closed.
---@param show boolean|nil
local function sync(show)
  if S then
    S.dirty = false
    panel().sync(S, show)
  end
end

---@param model string
local function model_label(model)
  return model:match("[^/]+$") or model
end

---@param win integer|nil
---@return boolean
local function code_like(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return false
  end
  if S and panel().owns(S, win) then
    return false
  end
  return vim.api.nvim_win_get_config(win).relative == ""
end

---Draws a sign beside the rows of each pending attachment.
local function draw_attachments()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      vim.api.nvim_buf_clear_namespace(buf, attach_ns, 0, -1)
    end
  end
  if not S then
    return
  end
  for _, a in ipairs(S.attachments) do
    if a.kind == "selection" then
      local r0, r1 = context.rows(a)
      for row = r0, r1 do
        vim.api.nvim_buf_set_extmark(a.buf, attach_ns, row, 0, {
          sign_text = "▎",
          sign_hl_group = "LeaderKBar",
          priority = 200,
          strict = false,
        })
      end
    end
  end
end

---The file the first message sends when nothing is attached.
---@return string|nil path
function M.default_file()
  if not S or #S.items > 0 or #S.attachments > 0 then
    return nil
  end
  local win = S.origin_win
  if not code_like(win) then
    return nil
  end
  local buf = vim.api.nvim_win_get_buf(win --[[@as integer]])
  local name = vim.api.nvim_buf_get_name(buf)
  if vim.bo[buf].buftype ~= "" or name == "" then
    return nil
  end
  return vim.fs.normalize(name)
end

local function start_timer()
  if S.timer then
    return
  end
  local conv = S
  S.timer = vim.uv.new_timer()
  S.timer:start(
    FRAME_MS,
    FRAME_MS,
    vim.schedule_wrap(function()
      if S ~= conv or conv.state ~= "running" then
        return
      end
      if conv.dirty then
        sync()
      else
        panel().tick(conv)
      end
    end)
  )
end

local function stop_timer()
  if S and S.timer then
    S.timer:stop()
    S.timer:close()
    S.timer = nil
  end
end

---@param kind "note"|"error"
---@param text string
local function add_item(kind, text)
  S.items[#S.items + 1] = { kind = kind, text = text }
  S.dirty = true
end

---Adds results for tool calls of the last assistant message that have none,
---so the messages stay valid for the next request.
---@param text string
local function fill_results(text)
  local last
  for i = #S.messages, 1, -1 do
    local m = S.messages[i]
    if m.role == "assistant" then
      last = i
      break
    end
  end
  if not last or not S.messages[last].tool_calls then
    return
  end
  local answered = {}
  for i = last + 1, #S.messages do
    if S.messages[i].role == "tool" then
      answered[S.messages[i].tool_call_id] = true
    end
  end
  for _, call in ipairs(S.messages[last].tool_calls) do
    if not answered[call.id] then
      S.messages[#S.messages + 1] = { role = "tool", tool_call_id = call.id, content = text }
    end
  end
end

---Shows `c` in the code window for review.
---@param c leader_k.Change
---@param focus boolean|nil
function M.review(c, focus)
  if not S or c.status ~= "pending" then
    return
  end
  local win = panel().code_window(S)
  if not win then
    return
  end
  S.origin_win = win
  local ok, err = pcall(review.show, win, c, {
    accept = function()
      M.decide(c, "accepted")
    end,
    reject = function()
      M.decide(c, "rejected")
    end,
    next_file = function()
      M.step_file(1)
    end,
    prev_file = function()
      M.step_file(-1)
    end,
  }, focus)
  if not ok then
    echo_error(tostring(err))
  end
  sync()
end

---Reviews the next or previous pending file, in the order they were first
---edited.
---@param dir integer 1 or -1.
function M.step_file(dir)
  if not S then
    return
  end
  local list = S.changes.list
  local cur = review.current and review.current.change
  local at = 0
  for i, c in ipairs(list) do
    if c == cur then
      at = i
    end
  end
  for k = 1, #list do
    local i = ((at - 1 + dir * k) % #list) + 1
    if list[i].status == "pending" and list[i] ~= cur then
      M.review(list[i], true)
      return
    end
  end
end

---Accepts or rejects a change. Reviews the next pending file after it.
---@param c leader_k.Change
---@param status "accepted"|"rejected"
---@return boolean
function M.decide(c, status, quiet)
  if not S or c.status ~= "pending" then
    return false
  end
  local was_current = review.current and review.current.change == c
  if was_current then
    review.hide()
  end
  if status == "accepted" then
    -- The file system may have changed since the edit was staged.
    local abs, resolve_err = root.resolve(S.root, c.rel)
    local err
    if abs ~= c.path then
      err = abs and ("%s now resolves to another file"):format(c.rel) or resolve_err
    else
      err = select(2, S.changes:accept(c))
    end
    if err then
      warn(err)
      if was_current then
        M.review(c, false)
      end
      return false
    end
  else
    S.changes:reject(c)
  end
  S.decisions[#S.decisions + 1] = { rel = c.rel, status = status }
  if was_current and not quiet then
    local nxt
    local list = S.changes.list
    for i, x in ipairs(list) do
      if x == c then
        for k = 1, #list - 1 do
          local y = list[((i - 1 + k) % #list) + 1]
          if y.status == "pending" then
            nxt = y
            break
          end
        end
      end
    end
    if nxt then
      M.review(nxt, true)
      return true
    end
  end
  sync()
  return true
end

---@param status "accepted"|"rejected"
function M.decide_all(status)
  if not S then
    return
  end
  for _, c in ipairs(S.changes:pending()) do
    M.decide(c, status, true)
  end
  sync()
end

---The system prompt.
---@return string
local function system_prompt()
  return table.concat({
    "You are a coding assistant inside Neovim, working with the user on the project at " .. S.root .. ".",
    "",
    "Use the tools to read and search the project before you answer or edit. Read a file before you edit it.",
    "edit_file and create_file propose changes. Nothing changes until the user reviews each file and accepts it. Files with proposed changes read back with those changes.",
    "Paths are relative to the project root. Files outside it, inside .git, or ignored by git are off limits.",
    "",
    "Attachments in <attachment> blocks are code the user selected, with their line numbers in the file. read_file output numbers each line; the numbers are not part of the file, so never put them in old_string or new_string.",
    "Keep edits minimal and match the surrounding style. Make every edit the request needs, across all files.",
    "Answer in Markdown and keep it short. After proposing edits, say in a sentence or two what changed; do not repeat the code.",
  }, "\n")
end

---@return table[]
local function request_messages()
  local out = { { role = "system", content = system_prompt() } }
  vim.list_extend(out, S.messages)
  return out
end

local finish, step

---@param run table
---@param calls leader_k.ToolCall[]
---@param i integer
local function run_calls(run, calls, i)
  if S == nil or S.run ~= run then
    return
  end
  if i > #calls then
    step(run)
    return
  end
  local call = calls[i]
  S.phase = "tool"
  S.activity = tools.activity(call["function"].name, call["function"].arguments)
  S.dirty = true
  local finished = false
  local cancel = tools.run({ root = S.root, changes = S.changes }, call, function(result, note)
    finished = true
    if S == nil or S.run ~= run then
      return
    end
    S.tool_cancel = nil
    S.messages[#S.messages + 1] = { role = "tool", tool_call_id = call.id, content = result }
    if note then
      add_item("note", note)
    elseif result:sub(1, 7) == "Error: " then
      add_item("note", ("%s failed: %s"):format(call["function"].name, result:sub(8)))
    end
    -- An edit to the file under review shows at once.
    review.redraw()
    -- The next call starts on a fresh stack, so a quick tool cannot nest.
    vim.schedule(function()
      run_calls(run, calls, i + 1)
    end)
  end)
  if not finished then
    S.tool_cancel = cancel
  end
end

---@param run table
step = function(run)
  if S == nil or S.run ~= run then
    return
  end
  S.step = S.step + 1
  if S.step > config.options.max_steps then
    add_item(
      "note",
      ("Stopped after %d requests for one message. Send a message to continue."):format(config.options.max_steps)
    )
    finish()
    return
  end
  local ep, err = config.endpoint()
  if not ep then
    M.fail(err --[[@as string]])
    return
  end
  S.phase, S.activity, S.reply = "waiting", nil, nil
  S.dirty = true
  local cancel, start_err = provider.stream(ep, request_messages(), tools.definitions, {
    on_reasoning = function()
      if S and S.run == run and S.phase == "waiting" then
        S.phase = "thinking"
      end
    end,
    on_text = function(delta)
      if not (S and S.run == run) then
        return
      end
      if not S.reply then
        S.reply = { kind = "assistant", text = "" }
        S.items[#S.items + 1] = S.reply
      end
      S.reply.text = S.reply.text .. delta
      S.phase = "writing"
      S.dirty = true
    end,
    on_tool = function(name)
      if S and S.run == run then
        S.phase, S.activity = "tool", tools.activity(name, nil)
      end
    end,
    on_done = function(reply)
      if not (S and S.run == run) then
        return
      end
      S.cancel = nil
      local calls = reply.tool_calls
      local msg = { role = "assistant", content = reply.content ~= "" and reply.content or vim.NIL }
      if #calls > 0 then
        msg.tool_calls = calls
      end
      if reply.content == "" and #calls == 0 then
        add_item("note", "The model sent an empty reply.")
        finish()
        return
      end
      S.messages[#S.messages + 1] = msg
      if #calls == 0 then
        if reply.finish_reason == "length" then
          add_item("note", "The reply stopped at the length limit.")
        end
        finish()
        return
      end
      run_calls(run, calls, 1)
    end,
    on_error = function(msg)
      if S and S.run == run then
        S.cancel = nil
        M.fail(msg)
      end
    end,
  }, config.options.timeout_ms)
  if not cancel then
    M.fail(start_err or "the request could not start")
    return
  end
  S.cancel = cancel
end

---Ends a run. Opens the first file the run changed for review.
finish = function()
  if not S then
    return
  end
  local first
  for _, c in ipairs(S.changes:pending()) do
    if S.before[c] ~= c.staged then
      first = first or c
    end
  end
  S.state, S.phase, S.activity, S.run, S.reply = "idle", nil, nil, nil, nil
  S.cancel, S.tool_cancel = nil, nil
  stop_timer()
  if first and not review.current then
    M.review(first, false)
  else
    sync()
  end
end

---Ends a run with an error, shown in the transcript and the message area.
---@param msg string
function M.fail(msg)
  if not S then
    return
  end
  fill_results("Not run: the request failed.")
  add_item("error", msg)
  echo_error(msg)
  finish()
end

---Stops the running request or tool. The transcript stays.
function M.stop()
  if not S or S.state ~= "running" then
    return
  end
  local cancel, tool_cancel = S.cancel, S.tool_cancel
  S.run, S.cancel, S.tool_cancel = nil, nil, nil
  if cancel then
    cancel()
  end
  if tool_cancel then
    tool_cancel()
  end
  -- Keep what the model wrote, so the next message continues from what the
  -- user saw.
  if cancel and S.reply and S.reply.text ~= "" then
    S.messages[#S.messages + 1] = { role = "assistant", content = S.reply.text }
  end
  fill_results("Not run: the user stopped the request.")
  add_item("note", "Stopped.")
  finish()
end

---@return string|nil
local function review_summary()
  if #S.decisions == 0 then
    return nil
  end
  local out = { "<review>" }
  for _, d in ipairs(S.decisions) do
    out[#out + 1] = ("The user %s your changes to %s."):format(d.status, d.rel)
  end
  local pending = vim.tbl_map(function(c)
    return c.rel
  end, S.changes:pending())
  if #pending > 0 then
    out[#out + 1] = "Still under review: " .. table.concat(pending, ", ") .. "."
  end
  out[#out + 1] = "</review>"
  return table.concat(out, "\n")
end

---Project files that `@path` tokens in `text` name.
---@param text string
---@return string[] Absolute paths.
local function mentioned(text)
  local out, seen = {}, {}
  for token in text:gmatch("@(%S+)") do
    token = token:gsub("[,.;:!?)]+$", "")
    local abs = root.resolve(S.root, token)
    if abs and not seen[abs] then
      local stat = vim.uv.fs_stat(abs)
      if stat and stat.type == "file" then
        seen[abs] = true
        out[#out + 1] = abs
      end
    end
  end
  return out
end

---Sends a message with the pending attachments.
---@param text string
---@return boolean sent
function M.submit(text)
  if not S then
    return false
  end
  if S.state == "running" then
    warn("a reply is still running. " .. config.key_label(config.options.keys.cancel) .. " stops it.")
    return false
  end
  text = vim.trim(text or "")
  if text == "" then
    return false
  end
  local ep, err = config.endpoint()
  if not ep then
    echo_error(err --[[@as string]])
    return false
  end
  local list = vim.list_extend({}, S.attachments)
  local default = M.default_file()
  for _, abs in ipairs(mentioned(text)) do
    local a = context.file(abs)
    local dup = false
    for _, b in ipairs(list) do
      dup = dup or context.same(a, b)
    end
    if not dup then
      list[#list + 1] = a
    end
  end
  if #list == 0 and default then
    list[1] = context.file(default)
  end
  local parts, labels = {}, {}
  local summary = review_summary()
  if summary then
    parts[#parts + 1] = summary
  end
  for _, a in ipairs(list) do
    local block, block_err = context.render(a, S.root, function(path)
      return (S.changes:text(path))
    end)
    if block then
      parts[#parts + 1] = block
      labels[#labels + 1] = context.label(a, S.root)
    else
      warn(block_err .. "; not sent")
    end
  end
  parts[#parts + 1] = text
  for _, a in ipairs(S.attachments) do
    context.free(a)
  end
  S.attachments, S.decisions = {}, {}
  -- Files may have been created since the last completion.
  S.files = nil
  draw_attachments()
  S.messages[#S.messages + 1] = { role = "user", content = table.concat(parts, "\n\n") }
  S.items[#S.items + 1] = { kind = "user", text = text, labels = labels }
  S.before = {}
  for _, c in ipairs(S.changes:pending()) do
    S.before[c] = c.staged
  end
  S.state, S.step, S.run = "running", 0, {}
  S.confirm_close = false
  start_timer()
  step(S.run)
  sync()
  return true
end

---Removes the newest pending attachment.
---@return boolean removed
function M.remove_last_attachment()
  if not S or #S.attachments == 0 then
    return false
  end
  context.free(table.remove(S.attachments))
  draw_attachments()
  sync()
  return true
end

---@param a leader_k.Attachment
local function add_attachment(a)
  for _, b in ipairs(S.attachments) do
    if context.same(a, b) then
      context.free(a)
      return
    end
  end
  S.attachments[#S.attachments + 1] = a
  draw_attachments()
end

---Project files relative to the root, for completion.
---@return string[]
function M.project_files()
  if not S then
    return {}
  end
  if S.files then
    return S.files
  end
  local files = {}
  if root.has_git(S.root) then
    local r = vim.system({ "git", "ls-files", "-co", "--exclude-standard" }, { cwd = S.root, text = true }):wait(5000)
    if r.code == 0 then
      files = vim.split(r.stdout or "", "\n", { plain = true, trimempty = true })
    end
  else
    for name, type in
      vim.fs.dir(S.root, {
        depth = 10,
        skip = function(d)
          return vim.fs.basename(d) ~= ".git"
        end,
      })
    do
      if type == "file" then
        files[#files + 1] = name
        if #files >= 5000 then
          break
        end
      end
    end
  end
  table.sort(files)
  S.files = files
  return files
end

local function destroy()
  if not S then
    return
  end
  local conv = S
  if conv.state == "running" then
    M.stop()
  end
  review.hide()
  for _, c in ipairs(conv.changes:pending()) do
    changes.drop_placeholder(c)
  end
  for _, a in ipairs(conv.attachments) do
    context.free(a)
  end
  stop_timer()
  pcall(vim.api.nvim_del_augroup_by_id, conv.augroup)
  S = nil
  draw_attachments()
  panel().close(conv)
end

---Starts a conversation when there is none.
---@return leader_k.Conversation
local function ensure()
  if S then
    return S
  end
  local win = vim.api.nvim_get_current_win()
  local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
  S = {
    root = root.find(name ~= "" and name or nil),
    messages = {},
    items = {},
    attachments = {},
    changes = changes.new(),
    decisions = {},
    state = "idle",
    step = 0,
    before = {},
    origin_win = win,
    model_label = model_label(config.options.model or ""),
    dirty = false,
    confirm_close = false,
  }
  local conv = S
  S.augroup = vim.api.nvim_create_augroup("leader-k.conversation", { clear = true })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = S.augroup,
    callback = function()
      local cur = vim.api.nvim_get_current_win()
      if S == conv and code_like(cur) then
        conv.origin_win = cur
        if #conv.items == 0 then
          sync()
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = S.augroup,
    callback = function()
      if S == conv then
        review.redraw()
        sync()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = S.augroup,
    callback = function(ev)
      if S ~= conv then
        return
      end
      for _, a in ipairs(conv.attachments) do
        if a.buf == ev.buf then
          draw_attachments()
          sync()
          return
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = S.augroup,
    callback = function(ev)
      if S ~= conv then
        return
      end
      local kept = {}
      for _, a in ipairs(conv.attachments) do
        if a.buf ~= ev.buf then
          kept[#kept + 1] = a
        end
      end
      if #kept ~= #conv.attachments then
        conv.attachments = kept
        vim.schedule(sync)
      end
    end,
  })
  return S
end

---Records the current window as the code window, unless it is the panel.
local function note_origin()
  local cur = vim.api.nvim_get_current_win()
  if code_like(cur) then
    S.origin_win = cur
  end
end

---Opens the panel and moves into its input.
function M.open()
  local fresh = S == nil
  ensure()
  if not fresh then
    note_origin()
  end
  sync(true)
  panel().focus_input(S)
end

---Attaches rows r0..r1 of `buf`, opening the panel without moving into it.
---@param buf integer
---@param r0 integer
---@param r1 integer
---@param focus integer[][]|nil
function M.attach_selection(buf, r0, r1, focus)
  ensure()
  note_origin()
  add_attachment(context.selection(buf, r0, r1, focus))
  sync(true)
end

---Attaches a whole file.
---@param path string|nil Defaults to the current buffer's file.
function M.attach_file(path)
  local name = path and path ~= "" and path or vim.api.nvim_buf_get_name(0)
  if name == "" then
    warn("this buffer has no file to attach")
    return
  end
  local abs = vim.fs.normalize(vim.fs.abspath(name))
  local stat = vim.uv.fs_stat(abs)
  if (not stat or stat.type ~= "file") and vim.fn.bufnr(abs) == -1 then
    warn(("%s is not a file"):format(name))
    return
  end
  ensure()
  note_origin()
  add_attachment(context.file(abs))
  sync(true)
end

---Closes the panel and ends the conversation. With pending changes, asks
---for a second press first.
function M.close()
  if not S then
    return
  end
  local pending = #S.changes:pending()
  if pending > 0 and not S.confirm_close then
    S.confirm_close = true
    warn(
      ("%d %s pending review. Press q again to discard %s and close."):format(
        pending,
        pending == 1 and "file is" or "files are",
        pending == 1 and "it" or "them"
      )
    )
    local conv = S
    vim.defer_fn(function()
      if S == conv then
        conv.confirm_close = false
      end
    end, 3000)
    return
  end
  destroy()
end

---Starts over with an empty conversation, discarding pending changes.
function M.new()
  local open = S ~= nil and panel().is_open(S)
  local origin = S and S.origin_win
  destroy()
  if origin and vim.api.nvim_win_is_valid(origin) then
    vim.api.nvim_set_current_win(origin)
  end
  if open then
    M.open()
  end
end

---Hides the panel; the conversation stays.
function M.hide()
  if S then
    panel().close(S)
  end
end

---Ends any conversation, as Neovim exits.
function M.stop_all()
  if S and S.state == "running" then
    M.stop()
  end
end

return M
