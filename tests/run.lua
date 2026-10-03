-- Headless tests against a local fake server, which this script starts.
--   nvim --headless -u NONE -l tests/run.lua
-- Set LEADER_K_LIVE=1 to run optional requests against the explicitly
-- configured LEADER_K_BASE_URL, LEADER_K_MODEL and LEADER_K_API_KEY.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.cmd("runtime plugin/leader-k.lua")
vim.o.swapfile = false
vim.g.mapleader = " "

local lk = require("leader-k")
local config = require("leader-k.config")
local session = require("leader-k.session")
local render = require("leader-k.render")
local http = require("leader-k.http")

local BASE_URL = "http://127.0.0.1:8765/v1"
local LOG = "/tmp/leader-k-test-request.json"

-- The server is test tooling; the plugin itself never spawns a process.
local server = vim.system({ "python3", root .. "/tests/fake_server.py" })
local up = vim.wait(5000, function()
  local tcp = vim.uv.new_tcp()
  local ok = false
  tcp:connect("127.0.0.1", 8765, function(err)
    ok = not err
    tcp:close()
  end)
  vim.wait(100, function()
    return ok
  end, 10)
  return ok
end, 50)
assert(up, "fake server did not start")

local function use(model, extra)
  lk.setup(vim.tbl_extend("force", {
    base_url = BASE_URL,
    model = model,
    api_key = "sk-test-123",
  }, extra or {}))
end

local passed, failed = 0, 0
local function test(name, fn)
  vim.cmd("enew!")
  vim.bo.buftype = "nofile"
  local ok, err = xpcall(fn, debug.traceback)
  local s = session.get(0)
  if s then
    s:destroy()
  end
  if ok then
    passed = passed + 1
    print("ok   " .. name)
  else
    failed = failed + 1
    print("FAIL " .. name .. "\n" .. err)
  end
end

local function eq(a, b, msg)
  if not vim.deep_equal(a, b) then
    error(("%s\n  expected: %s\n  got:      %s"):format(msg or "not equal", vim.inspect(b), vim.inspect(a)), 2)
  end
end

local function truthy(v, msg)
  if not v then
    error(msg or "expected truthy", 2)
  end
end

-- Forces edit mode, which most tests exercise.
local function edit(l1, l2, instruction)
  lk.run(l1, l2, instruction, { mode = "edit" })
end

local function lines(t)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, t)
end

local function buf_lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

local function wait_state(s, want, ms)
  vim.wait(ms or 10000, function()
    return s.state == want or s.state == "closed"
  end, 10)
  eq(s.state, want, "state (error: " .. tostring(s.error) .. ")")
end

-- Errors go to the message area. Capture them instead of printing.
local echoed = {}
local real_echo = vim.api.nvim_echo
vim.api.nvim_echo = function(chunks, history, opts)
  if opts and opts.err then
    local text = {}
    for _, c in ipairs(chunks) do
      text[#text + 1] = c[1]
    end
    echoed[#echoed + 1] = table.concat(text)
    return
  end
  return real_echo(chunks, history, opts)
end

local function marks(buf)
  return vim.api.nvim_buf_get_extmarks(buf or 0, render.ns, 0, -1, { details = true })
end

---Waits for a session to fail and checks that it left nothing behind.
---@return string message
local function wait_error(s, ms)
  vim.wait(ms or 10000, function()
    return s.state == "closed"
  end, 10)
  eq(s.state, "closed", "session closed after an error")
  truthy(s.error, "error recorded")
  eq(echoed[#echoed], "leader-k: " .. s.error, "error echoed to the message area")
  eq(session.get(s.buf), nil, "session gone")
  eq(#marks(s.buf), 0, "no inline decorations left")
  return s.error
end

local function undo_break()
  vim.o.undolevels = vim.o.undolevels
end

local SAMPLE = {
  "local M = {}",
  "",
  "function M.total(items)",
  "  local sum = 0",
  "  for i = 1, #items do",
  "    sum = sum + items[i].price * items[i].qty",
  "  end",
  "  return sum",
  "end",
  "",
  "return M",
}

-- Runs first: once any request has loaded libcurl, it stays loaded.
test("the configured libcurl path loads the library, and a bad one can be fixed", function()
  lines(SAMPLE)
  use("fast", { libcurl = "/nonexistent/libcurl-leader-k" })
  edit(1, 1, "x")
  eq(session.get(0), nil, "the request could not start")
  truthy(echoed[#echoed]:find("/nonexistent/libcurl-leader-k", 1, true), echoed[#echoed])
  local path = vim.uv.os_uname().sysname == "Darwin" and "/usr/lib/libcurl.4.dylib" or "libcurl.so.4"
  use("fast", { libcurl = path })
  edit(1, 1, "x")
  wait_state(assert(session.get(0)), "review")
  eq(http.info().path, path)
end)

test("streams, shows pending lines, then reviews", function()
  use("slow")
  vim.bo.filetype = "lua"
  lines(SAMPLE)
  edit(3, 9, "use ipairs")
  local s = assert(session.get(0))
  eq(s.state, "running")
  local saw_pending, saw_writing = false, false
  vim.wait(10000, function()
    if s.phase == "writing" then
      saw_writing = true
      for _, m in ipairs(marks()) do
        if m[4].hl_group == "LeaderKPending" then
          saw_pending = true
        end
      end
    end
    return s.state ~= "running"
  end, 5)
  truthy(saw_writing, "never entered the writing phase")
  truthy(saw_pending, "no pending lines while streaming")
  eq(s.state, "review")
  eq(s.proposal[1], "local function total(items)")
  eq(#s.proposal, 7)
  truthy(s.added > 0 and s.removed > 0)
  eq(buf_lines(), SAMPLE, "buffer untouched before accept")
  local req = vim.json.decode(table.concat(vim.fn.readfile(LOG), "\n"))
  eq(req.body.stream, true)
  eq(req.body.model, "slow")
  truthy(req.body.messages[2].content:find("<selection>\nfunction M.total", 1, true), "selection in prompt")
  truthy(req.body.messages[2].content:find("Instruction: use ipairs", 1, true), "instruction in prompt")
  eq(req.auth_present, true, "explicit key is sent as a bearer token")
end)

test("accept applies as one undo step and flashes", function()
  use("slow")
  lines(SAMPLE)
  undo_break()
  edit(3, 9, "use ipairs")
  local s = assert(session.get(0))
  wait_state(s, "review")
  s:accept()
  eq(session.get(0), nil)
  eq(buf_lines()[3], "local function total(items)")
  eq(#buf_lines(), 11)
  eq(#marks(), 0, "decorations cleared")
  vim.cmd("undo")
  eq(buf_lines(), SAMPLE, "undo restores the selection")
end)

test("reject leaves the buffer alone and restores shadowed keys", function()
  use("fast")
  lines(SAMPLE)
  vim.keymap.set("n", "<CR>", "<Cmd>let g:lk_cr = 1<CR>", { buffer = 0 })
  edit(3, 9, "use ipairs")
  local s = assert(session.get(0))
  wait_state(s, "review")
  eq(vim.fn.maparg("<CR>", "n", false, true).desc, "leader-k: accept")
  s:destroy()
  eq(buf_lines(), SAMPLE)
  eq(#marks(), 0)
  eq(vim.fn.maparg("<CR>", "n"), "<Cmd>let g:lk_cr = 1<CR>", "buffer map restored")
  eq(vim.fn.maparg("<BS>", "n"), "", "reject map removed")
end)

test("Enter accepts only while the proposal is visible", function()
  use("fast")
  local long = {}
  for i = 1, 300 do
    long[i] = "x" .. i
  end
  lines(long)
  edit(1, 2, "change")
  local s = assert(session.get(0))
  wait_state(s, "review")
  vim.cmd("normal! 250Gzz")
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  eq(s.state, "review", "Enter off-screen is a normal Enter")
  eq(vim.fn.line("."), 251)
  vim.cmd("normal! 1G")
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  eq(session.get(0), nil, "Enter on-screen accepts")
  eq(buf_lines()[1], "local function total(items)")
end)

test("a key the session does not handle runs the user's global mapping", function()
  use("hang")
  lines(SAMPLE)
  local calls = 0
  vim.keymap.set("n", "<leader>k", function()
    calls = calls + 1
  end)
  edit(3, 9, "x")
  local s = assert(session.get(0))
  vim.api.nvim_feedkeys(vim.keycode("<leader>k"), "x", false)
  vim.keymap.del("n", "<leader>k")
  eq(s.state, "running")
  eq(calls, 1, "the global <leader>k mapping ran during the request")
end)

test("off-screen keys keep the user's mappings, counts, and recursion rules", function()
  use("fast")
  local long = {}
  for i = 1, 300 do
    long[i] = "x" .. i
  end
  lines(long)
  vim.keymap.set("n", "<CR>", "<Cmd>let g:lk_cr = v:count<CR>")
  vim.keymap.set("n", "<BS>", "<BS>j", { remap = true })
  edit(1, 2, "change")
  local s = assert(session.get(0))
  wait_state(s, "review")
  vim.cmd("normal! 250Gzzl")
  vim.api.nvim_feedkeys("3" .. vim.keycode("<CR>"), "x", false)
  local cr = vim.g.lk_cr
  vim.api.nvim_feedkeys(vim.keycode("<BS>"), "x", false)
  local cursor = vim.api.nvim_win_get_cursor(0)
  vim.keymap.del("n", "<CR>")
  vim.keymap.del("n", "<BS>")
  eq(s.state, "review")
  eq(cr, 3, "the global <CR> mapping ran with the count")
  eq(cursor, { 251, 0 }, "<BS>j ran once: built-in <BS>, then j")
end)

test("HTTP 401 goes to the message area", function()
  use("err401")
  lines(SAMPLE)
  edit(1, 1, "x")
  local s = assert(session.get(0))
  wait_error(s)
  truthy(s.error:find("HTTP 401", 1, true), s.error)
  truthy(s.error:find("User not found", 1, true), s.error)
  truthy(s.error:find("check the API key", 1, true), s.error)
  eq(buf_lines(), SAMPLE)
end)

test("HTTP 402 explains credits", function()
  use("err402")
  lines(SAMPLE)
  edit(1, 1, "x")
  local s = assert(session.get(0))
  wait_error(s)
  truthy(s.error:find("HTTP 402: Insufficient credits", 1, true), s.error)
end)

test("mid-stream provider error", function()
  use("midstream")
  lines(SAMPLE)
  edit(1, 1, "x")
  local s = assert(session.get(0))
  wait_error(s)
  truthy(s.error:find("Provider disconnected", 1, true), s.error)
end)

test("a finished reply closes a connection the server keeps open", function()
  use("linger")
  lines(SAMPLE)
  edit(1, 1, "x")
  local s = assert(session.get(0))
  wait_state(s, "review")
  vim.wait(50)
  eq(http.active_count(), 0)
end)

test("an in-stream error closes a connection the server keeps open", function()
  use("linger_error")
  lines(SAMPLE)
  edit(1, 1, "x")
  local s = assert(session.get(0))
  truthy(wait_error(s):find("boom", 1, true), s.error)
  vim.wait(50)
  eq(http.active_count(), 0)
end)

test("stream cut without a finish reason", function()
  use("cut")
  lines(SAMPLE)
  edit(1, 1, "x")
  local s = assert(session.get(0))
  wait_error(s)
  truthy(s.error:find("ended before", 1, true), s.error)
end)

test("model refusal via <error>", function()
  use("refuse")
  lines(SAMPLE)
  edit(1, 1, "x")
  local s = assert(session.get(0))
  wait_error(s)
  truthy(s.error:find("declined: That needs changes outside", 1, true), s.error)
end)

test("output limit is an error, not a proposal", function()
  use("length")
  lines(SAMPLE)
  edit(1, 1, "x")
  local s = assert(session.get(0))
  wait_error(s)
  truthy(s.error:find("output limit", 1, true), s.error)
end)

test("fenced reply without tags keeps indentation", function()
  use("fence")
  lines({ "local function f()", "  return 1", "end" })
  edit(2, 2, "return 42")
  local s = assert(session.get(0))
  wait_state(s, "review")
  eq(s.proposal, { "  return 42" })
end)

test("restores a dropped base indent", function()
  use("noindent")
  lines({ "function f(x)", "  if not x then", "    return 0", "  end", "end" })
  edit(2, 4, "flip")
  local s = assert(session.get(0))
  wait_state(s, "review")
  eq(s.proposal, { "  if x then", "    return 1", "  end" })
end)

test("empty code block proposes deleting the selection", function()
  use("empty")
  lines({ "a", "b", "c" })
  edit(2, 2, "delete")
  local s = assert(session.get(0))
  wait_state(s, "review")
  eq(s.proposal, {})
  eq(s.removed, 1)
  s:accept()
  eq(buf_lines(), { "a", "c" })
end)

test("identical reply shows no changes and accept does nothing", function()
  use("same")
  lines(SAMPLE)
  vim.bo.modified = false
  edit(3, 5, "nothing")
  local s = assert(session.get(0))
  wait_state(s, "review")
  eq({ s.added, s.removed }, { 0, 0 })
  s:accept()
  eq(vim.bo.modified, false)
  eq(buf_lines(), SAMPLE)
end)

test("CRLF event stream", function()
  use("crlf")
  lines({ "x" })
  edit(1, 1, "y")
  local s = assert(session.get(0))
  wait_state(s, "review")
  eq(s.proposal, { "local y = 2" })
end)

test("reasoning shows the thinking phase", function()
  use("think")
  lines(SAMPLE)
  edit(3, 9, "x")
  local s = assert(session.get(0))
  local saw = false
  vim.wait(10000, function()
    saw = saw or s.phase == "thinking"
    return s.state ~= "running"
  end, 5)
  truthy(saw, "no thinking phase")
  eq(s.state, "review")
end)

test("cancel stops the transfer", function()
  use("hang")
  lines(SAMPLE)
  edit(1, 1, "x")
  local s = assert(session.get(0))
  vim.wait(300)
  eq(s.state, "running")
  eq(http.active_count(), 1)
  vim.api.nvim_feedkeys(vim.keycode("<C-c>"), "x", false)
  eq(session.get(0), nil)
  eq(http.active_count(), 0)
  eq(#marks(), 0)
  eq(vim.bo.busy, 0)
end)

test("editing the selection blocks accept until undone", function()
  use("fast")
  lines(SAMPLE)
  undo_break()
  edit(3, 9, "x")
  local s = assert(session.get(0))
  wait_state(s, "review")
  vim.api.nvim_buf_set_lines(0, 3, 4, false, { "  local sum = 1" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = 0 })
  eq(s.stale, true)
  s:accept()
  eq(s.state, "review", "stale accept refused")
  eq(buf_lines()[4], "  local sum = 1")
  vim.cmd("undo")
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = 0 })
  eq(s.stale, false)
  s:accept()
  eq(buf_lines()[3], "local function total(items)")
end)

test("edits outside the selection shift it without going stale", function()
  use("slow")
  lines(SAMPLE)
  edit(3, 9, "x")
  local s = assert(session.get(0))
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { "-- header", "" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = 0 })
  wait_state(s, "review")
  eq(s.stale, false)
  s:accept()
  eq(buf_lines()[5], "local function total(items)")
  eq(buf_lines()[1], "-- header")
end)

test("refine sends the conversation", function()
  use("fast")
  lines(SAMPLE)
  edit(3, 9, "use ipairs")
  local s = assert(session.get(0))
  wait_state(s, "review")
  s:refine()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "add a doc comment" })
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  eq(#s.turns, 2)
  wait_state(s, "review")
  local req = vim.json.decode(table.concat(vim.fn.readfile(LOG), "\n"))
  eq(#req.body.messages, 4)
  eq(req.body.messages[3].role, "assistant")
  truthy(req.body.messages[3].content:find("<code>\nlocal function total", 1, true))
  truthy(req.body.messages[4].content:find("add a doc comment", 1, true))
end)

test("a failed refine keeps the previous proposal", function()
  use("fast")
  lines(SAMPLE)
  edit(3, 9, "use ipairs")
  local s = assert(session.get(0))
  wait_state(s, "review")
  local proposal = s.proposal
  use("err401")
  s:refine()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "add a doc comment" })
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  vim.wait(10000, function()
    return s.state ~= "running"
  end, 10)
  eq(s.state, "review")
  eq(s.proposal, proposal)
  eq(#s.turns, 1)
  eq(s.instruction, "use ipairs")
  eq(echoed[#echoed], "leader-k: " .. s.error)
  truthy(s.error:find("HTTP 401", 1, true), s.error)
  s:accept()
  eq(buf_lines()[3], "local function total(items)")
end)

test("stopping a refine keeps the previous proposal", function()
  use("fast")
  lines(SAMPLE)
  edit(3, 9, "use ipairs")
  local s = assert(session.get(0))
  wait_state(s, "review")
  local proposal = s.proposal
  use("hang")
  s:refine()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "more" })
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  eq(s.state, "running")
  s:stop()
  eq(s.state, "review")
  eq(s.proposal, proposal)
  eq(#s.turns, 1)
end)

local function last_request()
  return vim.json.decode(table.concat(vim.fn.readfile(LOG), "\n"))
end

---@return string text of the answer float, or nil when it is closed.
local function answer_text(s)
  local win = s.answer_win
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return nil
  end
  return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
end

test("ask streams a Markdown answer into a float and leaves the code alone", function()
  use("answer_slow")
  vim.bo.filetype = "lua"
  lines(SAMPLE)
  local code_win = vim.api.nvim_get_current_win()
  lk.run(3, 9, "why multiply?", { mode = "ask" })
  local s = assert(session.get(0))
  local streamed = false
  vim.wait(10000, function()
    streamed = streamed or (s.state == "running" and answer_text(s) ~= nil)
    return s.state ~= "running"
  end, 5)
  truthy(streamed, "the float opened while the answer streamed")
  eq(s.state, "answered")
  local text = assert(answer_text(s))
  truthy(text:find("why multiply?", 1, true), "question shown: " .. text)
  truthy(text:find("It multiplies each `price` by its `qty`.\n\n```lua\nlocal x = price * qty\n```", 1, true), text)
  truthy(not text:find("answer>", 1, true), "tags stripped: " .. text)
  eq(vim.bo[vim.api.nvim_win_get_buf(s.answer_win)].filetype, "markdown")
  eq(vim.api.nvim_get_current_win(), code_win, "focus stays in the code")
  eq(buf_lines(), SAMPLE, "buffer untouched")
  local req = last_request()
  truthy(req.body.messages[1].content:find("<answer>", 1, true), "ask system prompt")
  truthy(req.body.messages[2].content:find("Question: why multiply?", 1, true), "question in prompt")
end)

test("ask shows a code reply as an answer and never edits", function()
  use("fast")
  vim.bo.filetype = "lua"
  lines(SAMPLE)
  lk.run(3, 9, "show me ipairs", { mode = "ask" })
  local s = assert(session.get(0))
  wait_state(s, "answered")
  truthy(assert(answer_text(s)):find("```lua\nlocal function total(items)", 1, true), answer_text(s))
  eq(s.proposal, nil)
end)

test("a truncated answer is kept with a note", function()
  use("answer_length")
  lines(SAMPLE)
  lk.run(3, 9, "explain", { mode = "ask" })
  local s = assert(session.get(0))
  wait_state(s, "answered")
  local text = assert(answer_text(s))
  truthy(text:find("The first half", 1, true), text)
  truthy(text:find("output limit", 1, true), text)
end)

test("closing an answer leaves nothing behind", function()
  use("answer")
  lines(SAMPLE)
  lk.run(3, 9, "why?", { mode = "ask" })
  local s = assert(session.get(0))
  wait_state(s, "answered")
  vim.cmd("normal! 3G")
  vim.api.nvim_feedkeys(vim.keycode("<BS>"), "x", false)
  eq(session.get(0), nil, "Backspace closes the answer")
  eq(answer_text(s), nil, "float closed")
  eq(#marks(), 0)

  lk.run(3, 9, "why?", { mode = "ask" })
  s = assert(session.get(0))
  wait_state(s, "answered")
  local code_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(s.answer_win)
  vim.api.nvim_feedkeys("q", "x", false)
  eq(session.get(0), nil, "q in the float closes the answer")
  eq(vim.api.nvim_get_current_win(), code_win, "focus returns to the code")
  eq(#marks(), 0)
end)

test("stopping an answer closes it", function()
  use("hang")
  lines(SAMPLE)
  lk.run(3, 9, "why?", { mode = "ask" })
  local s = assert(session.get(0))
  vim.wait(200)
  vim.api.nvim_feedkeys(vim.keycode("<C-c>"), "x", false)
  eq(session.get(0), nil)
  eq(http.active_count(), 0)
end)

test("auto mode proposes an edit when the reply is code", function()
  use("fast")
  lines(SAMPLE)
  lk.run(3, 9, "use ipairs")
  local s = assert(session.get(0))
  wait_state(s, "review")
  eq(s.proposal[1], "local function total(items)")
  local req = last_request()
  truthy(req.body.messages[1].content:find("<code>", 1, true), "auto prompt offers <code>")
  truthy(req.body.messages[1].content:find("<answer>", 1, true), "auto prompt offers <answer>")
  truthy(req.body.messages[2].content:find("Request: use ipairs", 1, true))
end)

test("auto mode answers when the reply is an answer or has no tags", function()
  use("answer")
  lines(SAMPLE)
  lk.run(3, 9, "why multiply?")
  local s = assert(session.get(0))
  wait_state(s, "answered")
  truthy(assert(answer_text(s)):find("It multiplies", 1, true))
  s:destroy()

  use("untagged")
  lk.run(3, 9, "what is this?")
  s = assert(session.get(0))
  wait_state(s, "answered")
  truthy(assert(answer_text(s)):find("This adds up price times quantity.", 1, true), answer_text(s))
  eq(buf_lines(), SAMPLE)
end)

test("commands pick the mode: auto, edit, or ask", function()
  use("answer")
  lines(SAMPLE)
  for cmd, prompt in pairs({ LeaderK = "<answer>", LeaderKEdit = "You edit code", LeaderKAsk = "You answer" }) do
    vim.cmd("3,9" .. cmd .. " why?")
    local s = assert(session.get(0), cmd)
    vim.wait(10000, function()
      return s.state ~= "running"
    end, 10)
    truthy(last_request().body.messages[1].content:find(prompt, 1, true), cmd)
    s:destroy()
  end
end)

test("auto mode in a read-only buffer only answers", function()
  use("fast")
  lines(SAMPLE)
  vim.bo.modifiable = false
  lk.run(3, 9, "use ipairs")
  local s = assert(session.get(0))
  wait_state(s, "answered")
  eq(s.mode, "ask")
end)

test("a characterwise selection sends its exact text and highlights only it", function()
  use("answer")
  lines(SAMPLE)
  vim.keymap.set("x", "<leader>k", lk.open)
  local word = "items[i].price"
  local col = SAMPLE[6]:find(word, 1, true)
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_cursor(0, { 6, col - 1 })
  vim.api.nvim_feedkeys("v" .. (#word - 1) .. "l" .. vim.keycode("<Space>") .. "k", "x", false)
  local s = assert(session.get(buf))
  eq(s.state, "prompt")
  local hl = {}
  for _, m in ipairs(marks(buf)) do
    if m[4].hl_group == "LeaderKSelection" then
      hl[#hl + 1] = { m[2], m[3], m[4].end_row, m[4].end_col }
    end
  end
  eq(hl, { { 5, col - 1, 5, col - 1 + #word } }, "only the characters are highlighted")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "why?" })
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  wait_state(s, "answered")
  local user = last_request().body.messages[2].content
  truthy(user:find("<selection>\n" .. SAMPLE[6] .. "\n</selection>", 1, true), "whole line as the selection")
  truthy(user:find("<highlight>\n" .. word .. "\n</highlight>", 1, true), user)
end)

local function follow_up(s, text)
  s:refine()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { text })
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
end

test("follow-ups keep one conversation across answers and edits", function()
  use("route")
  lines(SAMPLE)
  lk.run(3, 9, "why?")
  local s = assert(session.get(0))
  wait_state(s, "answered")

  follow_up(s, "explain more")
  wait_state(s, "answered")
  local text = assert(answer_text(s))
  truthy(text:find("› why?", 1, true) and text:find("› explain more", 1, true), text)
  local msgs = last_request().body.messages
  eq(#msgs, 4)
  truthy(msgs[3].content:find("<answer>\nIt multiplies", 1, true), msgs[3].content)
  truthy(msgs[4].content:find("Request: explain more", 1, true), msgs[4].content)

  follow_up(s, "change it to ipairs")
  wait_state(s, "review")
  eq(s.proposal[1], "local function total(items)")
  eq(answer_text(s), nil, "the answer gives way to the proposal")
  eq(#last_request().body.messages, 6)

  follow_up(s, "why that?")
  wait_state(s, "answered")
  text = assert(answer_text(s))
  truthy(text:find("› change it to ipairs\n*Proposed an edit.*", 1, true), text)
  msgs = last_request().body.messages
  truthy(msgs[7].content:find("<code>\nlocal function total", 1, true), msgs[7].content)
  eq(buf_lines(), SAMPLE)
end)

test("an edit asked for under an answer starts from the current lines", function()
  use("route")
  lines(SAMPLE)
  lk.run(3, 9, "why?")
  local s = assert(session.get(0))
  wait_state(s, "answered")
  vim.api.nvim_buf_set_lines(0, 3, 4, false, { "  local sum = 1" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = 0 })
  follow_up(s, "change it to ipairs")
  wait_state(s, "review")
  eq(s.stale, false)
  truthy(
    last_request().body.messages[4].content:find(
      "The selection now reads:\n<selection>\nfunction M.total(items)\n  local sum = 1",
      1,
      true
    ),
    last_request().body.messages[4].content
  )
  s:accept()
  eq(buf_lines()[3], "local function total(items)")
end)

test("whole file is sent; large files are cut at whole lines", function()
  use("fast")
  local big = {}
  for i = 1, 3000 do
    big[i] = ("local v%d = %d -- %s"):format(i, i, string.rep("x", 20))
  end
  lines(big)
  edit(1500, 1501, "x")
  local s = assert(session.get(0))
  wait_state(s, "review")
  local user = vim.json.decode(table.concat(vim.fn.readfile(LOG), "\n")).body.messages[2].content
  truthy(user:find("3000 lines. The selection is lines 1500-1501.", 1, true), user:sub(1, 200))
  eq(#s.ctx.before + s.ctx.omitted_before, 1499)
  eq(#s.ctx.after + s.ctx.omitted_after, 1499)
  truthy(s.ctx.omitted_before > 0 and s.ctx.omitted_after > 0, "cut on both sides")
  local bytes = #table.concat(s.ctx.before, "\n") + 1
  truthy(bytes <= 50000 and bytes > 49000, "before size " .. bytes)
  eq(s.ctx.before[#s.ctx.before], big[1499], "nearest line kept")
  truthy(user:find(("[lines 1-%d omitted]"):format(s.ctx.omitted_before), 1, true), "omission noted")
  truthy(user:find("[lines " .. (3000 - s.ctx.omitted_after + 1) .. "-3000 omitted]", 1, true), "tail omission noted")
  s:destroy()

  lines(SAMPLE)
  edit(3, 9, "x")
  s = assert(session.get(0))
  wait_state(s, "review")
  eq(s.ctx.before, { "local M = {}", "" })
  eq(s.ctx.after, { "", "return M" })
  user = vim.json.decode(table.concat(vim.fn.readfile(LOG), "\n")).body.messages[2].content
  truthy(not user:find("omitted", 1, true), "small file sent whole")
end)

test("prompt: Esc then q cancels without a request", function()
  use("fast")
  lines(SAMPLE)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  edit(3, 4)
  local s = assert(session.get(buf))
  eq(s.state, "prompt")
  truthy(vim.api.nvim_get_current_win() ~= win, "prompt float focused")
  truthy(#marks(buf) > 0, "selection highlighted")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "draft" })
  vim.api.nvim_feedkeys(vim.keycode("<Esc>q"), "x", false)
  eq(vim.api.nvim_get_current_win(), win)
  eq(session.get(buf), nil)
  eq(#marks(buf), 0)
end)

test("prompt: Esc on an empty prompt cancels at once", function()
  use("fast")
  lines(SAMPLE)
  local buf = vim.api.nvim_get_current_buf()
  edit(3, 4)
  truthy(session.get(buf))
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "x", false)
  vim.wait(50)
  eq(session.get(buf), nil)
end)

test("SSE parser: split chunks, comments, multi-line data", function()
  local got = {}
  local feed = require("leader-k.sse").parser(function(d)
    got[#got + 1] = d
  end)
  feed(": OPENROUTER PROCESSING\n\nda")
  feed("ta: one\ndata: two\n\ndata:three\r\n\r\n")
  eq(got, { "one\ntwo", "three" })
end)

test("extract: partial closing tag never shows", function()
  local p = require("leader-k.prompt")
  eq(p.extract("<code>\nlocal a = 1\n</co", false).text, "local a = 1\n")
  eq(p.extract("thinking out loud", false).kind, "pending")
  eq(p.extract("<code>\n```lua\nx()\n```\n</code>", true).text, "x()")
end)

test("extract: </code> inside the code does not end the block", function()
  local p = require("leader-k.prompt")
  local html = "<code>\n<p>Run <code>make</code> first.</p>\n</code>\n"
  eq(p.extract(html, true).text, "<p>Run <code>make</code> first.</p>\n")
  eq(p.extract(html:sub(1, 34), false).text, "<p>Run <code>make</code> fi")
  eq(p.extract(html, false).complete, true)
end)

test("visual <leader>k opens the prompt for the selected lines", function()
  use("fast")
  lines(SAMPLE)
  vim.keymap.set("x", "<leader>k", lk.open)
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_feedkeys("4GVj" .. vim.keycode("<Space>") .. "k", "x", false)
  local s = assert(session.get(buf))
  local r0, r1 = render.region(s)
  eq({ r0, r1 }, { 3, 4 })
  vim.api.nvim_feedkeys("add logging" .. vim.keycode("<CR>"), "x", false)
  wait_state(s, "review")
end)

test("wiping the buffer mid-request cancels cleanly", function()
  use("hang")
  lines(SAMPLE)
  local buf = vim.api.nvim_get_current_buf()
  edit(1, 1, "x")
  vim.wait(200)
  vim.cmd("bwipeout! " .. buf)
  eq(session.get(buf), nil)
  eq(http.active_count(), 0)
end)

test("two buffers stream at the same time", function()
  use("slow")
  lines(SAMPLE)
  edit(3, 9, "x")
  local a = assert(session.get(0))
  vim.cmd("enew!")
  vim.bo.buftype = "nofile"
  lines(SAMPLE)
  edit(3, 9, "y")
  local b = assert(session.get(0))
  eq(http.active_count(), 2)
  wait_state(a, "review")
  wait_state(b, "review")
  a:destroy()
end)

test("header is revealed for a selection on the first line", function()
  use("fast")
  lines(SAMPLE)
  edit(1, 1, "x")
  local s = assert(session.get(0))
  wait_state(s, "review")
  truthy(vim.fn.winsaveview().topfill >= 1, "topfill shows the header")
end)

test("diagnostics in the selection are sent", function()
  use("fast")
  lines(SAMPLE)
  local ns = vim.api.nvim_create_namespace("lk-test")
  vim.diagnostic.set(
    ns,
    0,
    { { lnum = 5, col = 0, message = "undefined field `qty`", severity = vim.diagnostic.severity.WARN } }
  )
  edit(3, 9, "x")
  local s = assert(session.get(0))
  wait_state(s, "review")
  local req = vim.json.decode(table.concat(vim.fn.readfile(LOG), "\n"))
  truthy(req.body.messages[2].content:find("line 4 of the selection: warn: undefined field `qty`", 1, true))
end)

test("params merge into the body and cannot turn streaming off", function()
  use("fast", { params = { temperature = 0.1, stream = false, reasoning = { effort = "none" } } })
  lines(SAMPLE)
  edit(3, 9, "x")
  local s = assert(session.get(0))
  wait_state(s, "review")
  local req = vim.json.decode(table.concat(vim.fn.readfile(LOG), "\n"))
  eq(req.body.temperature, 0.1)
  eq(req.body.stream, true)
  eq(req.body.reasoning, { effort = "none" })
end)

test("literal key and base URL produce a chat completion request", function()
  use("fast", { base_url = BASE_URL .. "/" })
  lines(SAMPLE)
  edit(1, 1, "x")
  local s = assert(session.get(0))
  wait_state(s, "review")
  local req = vim.json.decode(table.concat(vim.fn.readfile(LOG), "\n"))
  eq(req.auth_present, true)
  eq(req.auth_prefix, "Bearer ")
  eq(config.endpoint().url, BASE_URL .. "/chat/completions")
  use("fast", { api_key = "LEADER_K_TEST_KEY" })
  eq(config.endpoint().key, "LEADER_K_TEST_KEY", "plain strings are literal keys, never variable names")
end)

test("key from the named environment variable is read for each request", function()
  local name = "LEADER_K_TEST_KEY"
  local saved = vim.env[name]
  vim.env[name] = "sk-from-env"
  use("fast", { api_key = { env = name } })
  eq(config.endpoint().key, "sk-from-env")
  vim.env[name] = "sk-rotated"
  eq(config.endpoint().key, "sk-rotated")
  lines(SAMPLE)
  edit(1, 1, "x")
  wait_state(assert(session.get(0)), "review")
  local req = vim.json.decode(table.concat(vim.fn.readfile(LOG), "\n"))
  eq(req.auth_present, true)
  vim.env[name] = saved
end)

test("keyless endpoints send no Authorization header", function()
  lk.setup({ base_url = BASE_URL, model = "fast" })
  local ep, err = config.endpoint()
  truthy(ep, err)
  eq(ep.key, nil)
  lines(SAMPLE)
  edit(1, 1, "x")
  wait_state(assert(session.get(0)), "review")
  local req = vim.json.decode(table.concat(vim.fn.readfile(LOG), "\n"))
  eq(req.auth_present, false)
end)

test("a keyless request surfaces authentication errors", function()
  lk.setup({ base_url = BASE_URL, model = "err401" })
  lines(SAMPLE)
  edit(1, 1, "x")
  local s = assert(session.get(0))
  wait_error(s)
  truthy(s.error:find("HTTP 401", 1, true), s.error)
  truthy(s.error:find("set `api_key`", 1, true), s.error)
end)

test("missing configuration and environment keys stop requests", function()
  lk.setup({})
  local _, err = config.endpoint()
  truthy(err:find("`base_url`", 1, true), err)
  lk.open()
  eq(session.get(0), nil, "no prompt opens without mandatory configuration")
  truthy(echoed[#echoed]:find("`base_url`", 1, true), echoed[#echoed])
  lk.setup({ base_url = BASE_URL })
  _, err = config.endpoint()
  truthy(err:find("`model`", 1, true), err)
  use("fast", { api_key = { env = "LEADER_K_MISSING_TEST_KEY" } })
  local saved = vim.env.LEADER_K_MISSING_TEST_KEY
  vim.env.LEADER_K_MISSING_TEST_KEY = nil
  lines(SAMPLE)
  edit(1, 1, "x")
  eq(session.get(0), nil)
  truthy(echoed[#echoed]:find("$LEADER_K_MISSING_TEST_KEY", 1, true), echoed[#echoed])
  vim.env.LEADER_K_MISSING_TEST_KEY = saved
  eq(#marks(), 0)
end)

test("invalid configuration is rejected without revealing secrets", function()
  use("fast", { base_url = "http://example.com/v1" })
  local _, err = config.endpoint()
  truthy(err:find("must use https", 1, true), err)
  use("fast", { base_url = BASE_URL .. "/chat/completions" })
  _, err = config.endpoint()
  truthy(err:find("base_url", 1, true), err)
  use("fast", { api_key = { env = "INVALID-NAME" } })
  _, err = config.endpoint()
  truthy(err:find("api_key", 1, true), err)
  use("fast", { api_key = "sk-secret\nmalformed" })
  _, err = config.endpoint()
  truthy(err:find("api_key", 1, true), err)
  truthy(not err:find("sk-secret", 1, true), err)
  use("fast", { api_key = {} })
  _, err = config.endpoint()
  truthy(err:find("api_key", 1, true), err)
  use("fast", { provider = "openrouter" })
  _, err = config.endpoint()
  truthy(err:find("unknown configuration option `provider`", 1, true), err)
  use("fast", { timeout_ms = "180000" })
  _, err = config.endpoint()
  truthy(err:find("`timeout_ms`", 1, true), err)
end)

test("unreachable host", function()
  use("fast", { base_url = "http://127.0.0.1:1/v1" })
  lines(SAMPLE)
  edit(1, 1, "x")
  local s = assert(session.get(0))
  wait_error(s)
  truthy(s.error:find("request failed", 1, true), s.error)
end)

if vim.env.LEADER_K_LIVE == "1" then
  test("live compatible endpoint edit", function()
    lk.setup({
      base_url = assert(vim.env.LEADER_K_BASE_URL),
      model = assert(vim.env.LEADER_K_MODEL),
      api_key = { env = "LEADER_K_API_KEY" },
    })
    vim.bo.filetype = "lua"
    lines(SAMPLE)
    edit(3, 9, "use ipairs instead of a numeric loop")
    local s = assert(session.get(0))
    wait_state(s, "review", 60000)
    local text = table.concat(s.proposal, "\n")
    truthy(text:find("ipairs", 1, true), text)
    truthy(s.proposal[1]:find("^function M.total"), text)
    s:accept()
    eq(buf_lines()[1], "local M = {}")
    eq(buf_lines()[#buf_lines()], "return M")
    print("     " .. table.concat(vim.api.nvim_buf_get_lines(0, 2, -3, false), "\n     "))
  end)
end

server:kill(15)
print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
