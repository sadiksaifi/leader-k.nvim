-- Headless tests against a local fake server, which this script starts.
--   nvim --headless -u NONE -l tests/run.lua
-- Set LEADER_K_LIVE=1 to run an optional request against the explicitly
-- configured LEADER_K_BASE_URL, LEADER_K_MODEL and LEADER_K_API_KEY.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(here)
vim.cmd("runtime plugin/leader-k.lua")
vim.o.swapfile = false
vim.o.hidden = true
vim.g.mapleader = " "

local lk = require("leader-k")
local agent = require("leader-k.agent")
local config = require("leader-k.config")
local http = require("leader-k.http")
local panel = require("leader-k.panel")
local review = require("leader-k.review")

local BASE_URL = "http://127.0.0.1:8765/v1"
local LOG = "/tmp/leader-k-test-request.json"
local SCRIPT = "/tmp/leader-k-test-script.json"

-- The server is test tooling; the plugin itself never spawns a process.
local server = vim.system({ "python3", here .. "/tests/fake_server.py" })
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

local FILES = {
  ["a.lua"] = SAMPLE,
  ["b.lua"] = { "local B = {}", "", "function B.name()", '  return "b"', "end", "", "return B" },
  ["src/util.lua"] = { "local function answer()", "  return 42", "end", "", "return answer" },
  [".gitignore"] = { "secret.txt" },
  ["secret.txt"] = { "hunter2" },
}

-- A git project with a few files, rebuilt before each test.
local project = vim.fs.normalize(vim.uv.fs_realpath(vim.fn.tempname():match("^(.*)/") or "/tmp") .. "/lk-project")
vim.fn.delete(project, "rf")
vim.fn.mkdir(project .. "/src", "p")
vim.system({ "git", "init", "-q" }, { cwd = project }):wait()

local function reset_files()
  for rel, content in pairs(FILES) do
    vim.fn.writefile(content, project .. "/" .. rel)
  end
  local f = assert(io.open(project .. "/image.bin", "wb"))
  f:write("PNG\0\1\2binary")
  f:close()
  for _, extra in ipairs({ "new.lua", "src/deep/new.lua", "src/package.json", "src/secret.txt", "link.lua" }) do
    vim.fn.delete(project .. "/" .. extra)
  end
end
vim.cmd.cd(project)

local function use(model, extra)
  lk.setup(vim.tbl_extend("force", {
    base_url = BASE_URL,
    model = model,
    api_key = "sk-test-123",
  }, extra or {}))
end

---Writes the replies the fake server sends for the "script" model.
---@param replies table[]
local function script(replies)
  vim.fn.writefile({ vim.json.encode(replies) }, SCRIPT)
end

---@return table[] requests The bodies the server received, oldest first.
local function requests()
  if vim.fn.filereadable(LOG) == 0 then
    return {}
  end
  return vim.tbl_map(function(r)
    return r.body
  end, vim.json.decode(table.concat(vim.fn.readfile(LOG), "\n")))
end

local function last_log()
  local all = vim.json.decode(table.concat(vim.fn.readfile(LOG), "\n"))
  return all[#all]
end

-- Errors go to the message area. Capture them instead of printing.
local echoed, warned = {}, {}
local real_echo = vim.api.nvim_echo
vim.api.nvim_echo = function(chunks, history, opts)
  local text = {}
  for _, c in ipairs(chunks) do
    text[#text + 1] = c[1]
  end
  if opts and opts.err then
    echoed[#echoed + 1] = table.concat(text)
    return
  end
  if chunks[1] and chunks[1][2] == "WarningMsg" then
    warned[#warned + 1] = table.concat(text)
    return
  end
  return real_echo(chunks, history, opts)
end

local function teardown()
  local S = agent.get()
  if S then
    S.confirm_close = true
    agent.close()
  end
  review.hide()
  vim.cmd("silent! only!")
  vim.cmd("enew!")
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= vim.api.nvim_get_current_buf() then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  vim.fn.delete(LOG)
  echoed, warned = {}, {}
end

local passed, failed = 0, 0
local function test(name, fn)
  reset_files()
  vim.fn.delete(LOG)
  local ok, err = xpcall(fn, debug.traceback)
  teardown()
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

local function has(text, part, msg)
  if type(text) ~= "string" or not text:find(part, 1, true) then
    error(("%s\n  missing: %s\n  in:      %s"):format(msg or "text", part, vim.inspect(text)), 2)
  end
end

local function edit(rel)
  vim.cmd.edit(vim.fn.fnameescape(project .. "/" .. rel))
  return vim.api.nvim_get_current_buf()
end

local function wait_idle(ms)
  local done = vim.wait(ms or 10000, function()
    local S = agent.get()
    return not S or S.state == "idle"
  end, 10)
  truthy(done, "the run did not finish")
end

---Sends a message from the code window, as if typed in the panel.
local function send(text)
  agent.open()
  vim.cmd.stopinsert()
  return agent.submit(text)
end

local function transcript()
  local S = assert(agent.get())
  return table.concat(vim.api.nvim_buf_get_lines(S.panel.tbuf, 0, -1, false), "\n")
end

---The tool messages of a request, by call id.
local function tool_results(body)
  local out = {}
  for _, m in ipairs(body.messages) do
    if m.role == "tool" then
      out[m.tool_call_id] = m.content
    end
  end
  return out
end

local function lines_of(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "mtx", false)
end

---The text of a hint float, or nil when it is hidden.
local function hint_text(h)
  if not (h.win and vim.api.nvim_win_is_valid(h.win)) then
    return nil
  end
  return vim.trim(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(h.win), 0, 1, false)[1])
end

---Presses `keys` in the transcript, where the review keys work.
local function in_transcript(keys)
  vim.api.nvim_set_current_win(assert(agent.get()).panel.twin)
  feed(keys)
end

---The key hints row under the input.
local function input_hints()
  local S = assert(agent.get())
  local ns = vim.api.nvim_get_namespaces()["leader-k.panel.input"]
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(S.panel.ibuf, ns, 0, -1, { details = true })) do
    local vl = m[4].virt_lines
    if vl and not m[4].virt_lines_above then
      return table.concat(vim.tbl_map(function(c)
        return c[1]
      end, vl[#vl]))
    end
  end
end

local function code_win()
  local S = assert(agent.get())
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if not require("leader-k.panel").owns(S, win) then
      return win
    end
  end
end

-- Runs first: once any request has loaded libcurl, it stays loaded.
test("the configured libcurl path loads the library, and a bad one can be fixed", function()
  script({ { content = "Hi." } })
  use("script", { libcurl = "/nonexistent/libcurl-leader-k" })
  edit("a.lua")
  send("hello")
  wait_idle()
  has(echoed[#echoed], "/nonexistent/libcurl-leader-k")
  local path = vim.uv.os_uname().sysname == "Darwin" and "/usr/lib/libcurl.4.dylib" or "libcurl.so.4"
  use("script", { libcurl = path })
  send("hello again")
  wait_idle()
  eq(http.info().path, path)
  has(transcript(), "Hi.")
end)

test("a read_file call reaches the model and its result is sent back", function()
  script({
    { content = "Let me look.", tool_calls = { { name = "read_file", arguments = { path = "src/util.lua" } } } },
    { content = "It returns **42**." },
  })
  use("script")
  edit("a.lua")
  send("what does util do?")
  wait_idle()
  local reqs = requests()
  eq(#reqs, 2, "one request per step")
  local first = reqs[1]
  eq(first.tool_choice, "auto")
  eq(
    vim.tbl_map(function(t)
      return t["function"].name
    end, first.tools),
    { "read_file", "list_files", "search", "edit_file", "create_file" }
  )
  eq(first.messages[1].role, "system")
  has(first.messages[1].content, project)
  local user = first.messages[2].content
  has(user, '<attachment path="a.lua" lines="1-11">', "the current file is attached by default")
  has(user, "function M.total(items)")
  has(user, "what does util do?")
  local second = reqs[2]
  local assistant = second.messages[3]
  eq(assistant.role, "assistant")
  eq(assistant.content, "Let me look.")
  eq(assistant.tool_calls[1].id, "call_0_0")
  eq(assistant.tool_calls[1]["function"].name, "read_file")
  eq(vim.json.decode(assistant.tool_calls[1]["function"].arguments), { path = "src/util.lua" })
  eq(
    tool_results(second)["call_0_0"],
    "src/util.lua, lines 1-5 of 5:\n     1\tlocal function answer()\n     2\t  return 42\n     3\tend\n     4\t\n     5\treturn answer"
  )
  local t = transcript()
  has(t, "what does util do?")
  has(t, "Attached: all of a.lua")
  has(t, "Read util.lua")
  has(t, "It returns **42**.")
  eq(agent.get().state, "idle")
end)

test("read_file reads a line range and stops at max_read_bytes", function()
  script({
    {
      tool_calls = {
        { name = "read_file", arguments = { path = "a.lua", start_line = 3, end_line = 4 } },
        { name = "read_file", arguments = { path = "a.lua" } },
      },
    },
    { content = "ok" },
  })
  use("script", { max_read_bytes = 60 })
  edit("b.lua")
  send("read")
  wait_idle()
  local results = tool_results(requests()[2])
  eq(results["call_0_0"], "a.lua, lines 3-4 of 11:\n     3\tfunction M.total(items)\n     4\t  local sum = 0")
  local capped = results["call_0_1"]
  has(capped, "a.lua, lines 1-3 of 11:")
  has(capped, "[Stopped at 60 bytes. Read on with start_line=4.]")
  has(transcript(), "Read a.lua, lines 3-4")
end)

test("read_file sees unsaved buffer text", function()
  script({ { tool_calls = { { name = "read_file", arguments = { path = "b.lua" } } } }, { content = "ok" } })
  use("script")
  local b = edit("b.lua")
  vim.api.nvim_buf_set_lines(b, 0, 1, false, { "local B = { unsaved = true }" })
  edit("a.lua")
  send("read b")
  wait_idle()
  has(tool_results(requests()[2])["call_0_0"], "     1\tlocal B = { unsaved = true }")
end)

test("list_files and search return project files and matches", function()
  script({
    {
      tool_calls = {
        { name = "list_files", arguments = {} },
        { name = "list_files", arguments = { pattern = "*.lua", path = "src" } },
        { name = "search", arguments = { pattern = "return [0-9]+" } },
        { name = "search", arguments = { pattern = "nothing_matches_this" } },
      },
    },
    { content = "ok" },
  })
  use("script")
  edit("a.lua")
  send("look around")
  wait_idle()
  local r = tool_results(requests()[2])
  eq(vim.split(r["call_0_0"], "\n"), { ".gitignore", "a.lua", "b.lua", "image.bin", "src/util.lua" })
  eq(r["call_0_1"], "src/util.lua")
  eq(r["call_0_2"], "src/util.lua:2:  return 42")
  eq(r["call_0_3"], "No matches.")
  local t = transcript()
  has(t, "Listed the project: 5 files")
  has(t, 'Searched "return [0-9]+": 1 match')
end)

test("tools refuse paths outside the project, in .git, ignored, or binary", function()
  script({
    {
      tool_calls = {
        { name = "read_file", arguments = { path = "../outside.lua" } },
        { name = "read_file", arguments = { path = "/etc/hosts" } },
        { name = "read_file", arguments = { path = ".git/config" } },
        { name = "read_file", arguments = { path = "secret.txt" } },
        { name = "read_file", arguments = { path = "image.bin" } },
        { name = "read_file", arguments = { path = "missing.lua" } },
        { name = "edit_file", arguments = { path = "secret.txt", old_string = "hunter2", new_string = "x" } },
        { name = "create_file", arguments = { path = "../escape.lua", content = "x" } },
        { name = "nope", arguments = {} },
        { name = "read_file", arguments = "{not json" },
      },
    },
    { content = "ok" },
  })
  use("script")
  edit("a.lua")
  send("try things")
  wait_idle()
  local r = tool_results(requests()[2])
  has(r["call_0_0"], "Error: ../outside.lua is outside the project root")
  has(r["call_0_1"], "Error: /etc/hosts is outside the project root")
  eq(r["call_0_2"], "Error: .git/config is inside .git")
  eq(r["call_0_3"], "Error: secret.txt is ignored by git")
  eq(r["call_0_4"], "Error: image.bin is a binary file.")
  eq(r["call_0_5"], "Error: missing.lua does not exist.")
  eq(r["call_0_6"], "Error: secret.txt is ignored by git")
  has(r["call_0_7"], "is outside the project root")
  eq(r["call_0_8"], "Error: there is no tool named nope.")
  eq(r["call_0_9"], "Error: the arguments for read_file are not a JSON object.")
  eq(#agent.get().changes.list, 0, "nothing staged")
  has(transcript(), "read_file failed: secret.txt is ignored by git")
end)

local EDITS = {
  {
    content = "Updating both.",
    tool_calls = {
      {
        name = "edit_file",
        arguments = { path = "a.lua", old_string = "  local sum = 0\n", new_string = "  local sum = 0 -- total\n" },
      },
      {
        name = "edit_file",
        arguments = { path = "b.lua", old_string = '  return "b"', new_string = '  return "bee"' },
      },
    },
  },
  { content = "Done." },
  { content = "Noted." },
}

test("edits are staged, reviewed per file, and accepted into the unsaved buffer", function()
  script(EDITS)
  use("script")
  local a = edit("a.lua")
  send("annotate")
  wait_idle()
  local S = assert(agent.get())
  eq(lines_of(a), SAMPLE, "the buffer is untouched while the edit is staged")
  eq(#S.changes.list, 2)
  local results = tool_results(requests()[2])
  eq(
    results["call_0_0"],
    "Staged the edit to a.lua. Its pending changes are now +1 -1. The user reviews them before they apply."
  )
  local t = transcript()
  has(t, "Edited a.lua +1 -1")
  has(t, "Edited b.lua +1 -1")
  has(t, "Changed files")
  has(t, "  a.lua  +1 -1  reviewing")
  has(t, "  b.lua  +1 -1  pending")
  -- The first file the run changed opens for review in the code window.
  eq(review.current.change.rel, "a.lua")
  local win = code_win()
  eq(vim.api.nvim_win_get_buf(win), a)
  eq(vim.api.nvim_win_get_cursor(win)[1], 4, "the cursor is on the change")
  local marks = vim.api.nvim_buf_get_extmarks(a, review.ns, 0, -1, { details = true })
  local virt = 0
  for _, m in ipairs(marks) do
    if m[4].virt_lines then
      virt = virt + 1
      local text = table.concat(vim.tbl_map(function(c)
        return c[1]
      end, m[4].virt_lines[1]))
      has(text, "local sum = 0 -- total")
    end
  end
  eq(virt, 1, "the new line shows as a virtual line")

  in_transcript("a")
  eq(lines_of(a)[4], "  local sum = 0 -- total")
  eq(vim.bo[a].modified, true, "accepted into the buffer, unsaved")
  eq(vim.fn.readfile(project .. "/a.lua"), SAMPLE, "the file on disk is unchanged")
  eq(#vim.api.nvim_buf_get_extmarks(a, review.ns, 0, -1, {}), 0, "the diff is cleared")
  -- The next pending file opens.
  eq(review.current.change.rel, "b.lua")
  local b = vim.api.nvim_win_get_buf(win)
  eq(vim.api.nvim_buf_get_name(b), project .. "/b.lua")
  feed("r")
  eq(lines_of(b)[4], '  return "b"', "rejected: the buffer is untouched")
  eq(review.current, nil, "nothing left to review")
  t = transcript()
  has(t, "  a.lua  +1 -1  accepted")
  has(t, "  b.lua  +1 -1  rejected")

  -- Accept is one undo step.
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_set_current_buf(a)
  vim.cmd("silent undo")
  eq(lines_of(a), SAMPLE)

  -- The next message tells the model what the user decided.
  send("thanks")
  wait_idle()
  local reqs = requests()
  local last = reqs[#reqs].messages
  local user = last[#last].content
  has(user, "<review>\nThe user accepted your changes to a.lua.\nThe user rejected your changes to b.lua.\n</review>")
end)

test("review keys in the transcript move between files and hunks", function()
  script({
    {
      tool_calls = {
        {
          name = "edit_file",
          arguments = { path = "a.lua", old_string = "local M = {}", new_string = "local M = { v = 1 }" },
        },
        { name = "edit_file", arguments = { path = "a.lua", old_string = "return M", new_string = "return M -- end" } },
        { name = "edit_file", arguments = { path = "b.lua", old_string = "return B", new_string = "return B -- end" } },
      },
    },
    { content = "Done." },
  })
  use("script")
  edit("a.lua")
  send("go")
  wait_idle()
  local S = assert(agent.get())
  eq(#S.changes.list, 2, "two edits to one file are one change")
  eq(S.changes.list[1].added, 2)
  local win = code_win()
  eq(vim.api.nvim_win_get_cursor(win)[1], 1)
  in_transcript("]c")
  eq(vim.api.nvim_win_get_cursor(win)[1], 11, "]c moves the code window to the next hunk")
  feed("]c")
  eq(vim.api.nvim_win_get_cursor(win)[1], 1, "]c wraps around")
  feed("[c")
  eq(vim.api.nvim_win_get_cursor(win)[1], 11)
  feed("]f")
  eq(review.current.change.rel, "b.lua")
  eq(vim.api.nvim_get_current_win(), S.panel.twin, "focus stays in the transcript")
  feed("[f")
  eq(review.current.change.rel, "a.lua")
end)

test("]c moves the review's window, not another window on the file", function()
  script(EDITS)
  use("script")
  local a = edit("a.lua")
  -- a.lua is also open in another tab, where the cursor stays put.
  vim.cmd("tab split")
  local other = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(other, { 2, 0 })
  vim.cmd("tabnew")
  vim.api.nvim_set_current_buf(a)
  send("annotate")
  wait_idle()
  local win = code_win()
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  in_transcript("]c")
  eq(vim.api.nvim_win_get_cursor(win)[1], 4)
  eq(vim.api.nvim_win_get_cursor(other)[1], 2)
end)

test("the code buffer keeps its own keys during a review", function()
  script(EDITS)
  use("script")
  local a = edit("a.lua")
  vim.keymap.set("n", "<CR>", "<Cmd>let g:lk_cr = v:count<CR>")
  vim.keymap.set("n", "]f", "<Cmd>let g:lk_user_map = 1<CR>", { buffer = a })
  send("annotate")
  wait_idle()
  eq(review.current.change.rel, "a.lua")
  vim.api.nvim_set_current_win(code_win())
  feed("3<CR>")
  eq(vim.g.lk_cr, 3, "Enter runs the user's mapping")
  feed("]f")
  eq(vim.g.lk_user_map, 1, "]f runs the user's buffer mapping")
  eq(review.current.change.rel, "a.lua")
  eq(assert(agent.get()).changes.list[1].status, "pending")
  vim.keymap.del("n", "<CR>")
  vim.g.lk_cr, vim.g.lk_user_map = nil, nil
end)

test("A in the transcript accepts every pending file", function()
  script(EDITS)
  use("script")
  local a = edit("a.lua")
  send("annotate")
  wait_idle()
  local S = assert(agent.get())
  vim.api.nvim_set_current_win(S.panel.twin)
  feed("A")
  eq(lines_of(a)[4], "  local sum = 0 -- total")
  local b = vim.fn.bufnr(project .. "/b.lua")
  eq(lines_of(b)[4], '  return "bee"')
  eq(vim.bo[b].modified, true)
  eq(#S.changes:pending(), 0)
end)

test("Enter on a changed file opens its review", function()
  script(EDITS)
  use("script")
  edit("a.lua")
  send("annotate")
  wait_idle()
  local S = assert(agent.get())
  vim.api.nvim_set_current_win(S.panel.twin)
  local row
  for i, l in ipairs(vim.api.nvim_buf_get_lines(S.panel.tbuf, 0, -1, false)) do
    if l:find("^  b%.lua") then
      row = i
    end
  end
  vim.api.nvim_win_set_cursor(0, { assert(row), 0 })
  feed("<CR>")
  eq(review.current.change.rel, "b.lua")
  eq(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(code_win())), project .. "/b.lua")
  eq(vim.api.nvim_get_current_win(), S.panel.twin, "focus stays in the transcript")
end)

test("after a run, focus moves to the transcript and the input names the review keys", function()
  script(EDITS)
  use("script")
  edit("a.lua")
  send("annotate")
  wait_idle()
  local S = assert(agent.get())
  eq(vim.api.nvim_get_current_win(), S.panel.twin, "focus left the empty input")
  has(vim.api.nvim_get_current_line(), "a.lua  +1 -1  reviewing", "the cursor is on the file under review")
  eq(input_hints(), "a accept  r reject  ]f next file")
  feed("a")
  eq(input_hints(), "a accept  r reject", "the last file has no next file")
  -- Esc in the empty input goes back to the transcript while files wait.
  panel.focus_input(S)
  vim.cmd.stopinsert()
  feed("<Esc>")
  eq(vim.api.nvim_get_current_win(), S.panel.twin)
  feed("r")
  eq(input_hints(), "Leader k type  q close")
  panel.focus_input(S)
  vim.cmd.stopinsert()
  feed("<Esc>")
  eq(vim.api.nvim_get_current_win(), code_win(), "with nothing to review, Esc goes to the code")
end)

test("a run does not take focus from a typed message", function()
  script(EDITS)
  use("script")
  edit("a.lua")
  send("annotate")
  local S = assert(agent.get())
  vim.api.nvim_buf_set_lines(S.panel.ibuf, 0, -1, false, { "draft" })
  wait_idle()
  eq(vim.api.nvim_get_current_win(), S.panel.iwin)
end)

test("a buffer-local attach key does not hide the global one it shadows", function()
  use("script")
  local attach = require("leader-k.attach")
  local a = edit("a.lua")
  vim.keymap.set("x", "<C-l>", "<Cmd>let g:lk_global = 1<CR>")
  vim.keymap.set("x", "<C-l>", "<Cmd>let g:lk_local = 1<CR>", { buffer = a })
  agent.open()
  truthy(attach.enabled())
  agent.hide()
  eq(vim.fn.maparg("<C-l>", "x", false, true).buffer, 1, "the buffer-local map stays")
  vim.keymap.del("x", "<C-l>", { buffer = a })
  eq(vim.fn.maparg("<C-l>", "x"), "<Cmd>let g:lk_global = 1<CR>", "the global map is restored")
  vim.keymap.del("x", "<C-l>")
end)

test("closing the panel suspends the review; opening it resumes", function()
  script(EDITS)
  use("script")
  local a = edit("a.lua")
  send("annotate")
  wait_idle()
  local S = assert(agent.get())
  agent.hide()
  eq(review.current, nil)
  eq(#vim.api.nvim_buf_get_extmarks(a, review.ns, 0, -1, {}), 0, "the diff is cleared")
  vim.api.nvim_set_current_buf(a)
  feed("<CR>")
  eq(lines_of(a), SAMPLE, "Enter does not accept with the panel closed")
  eq(S.changes.list[1].status, "pending")
  lk.open()
  vim.cmd.stopinsert()
  eq(review.current.change.rel, "a.lua", "the review resumes")
end)

test("a run that finishes with the panel closed reviews once it opens", function()
  script({
    {
      delay = 0.05,
      tool_calls = {
        { name = "edit_file", arguments = { path = "a.lua", old_string = "return M", new_string = "return M -- x" } },
      },
    },
    { content = "Done." },
  })
  use("script")
  edit("a.lua")
  send("go")
  agent.hide()
  wait_idle()
  eq(review.current, nil)
  lk.open()
  vim.cmd.stopinsert()
  eq(review.current.change.rel, "a.lua")
end)

test("a file changed after the edit cannot be accepted", function()
  script(EDITS)
  use("script")
  local a = edit("a.lua")
  send("annotate")
  wait_idle()
  local S = assert(agent.get())
  vim.api.nvim_buf_set_lines(a, 0, 1, false, { "local M = { changed = true }" })
  local c = S.changes.list[1]
  eq(agent.decide(c, "accepted"), false)
  has(warned[#warned], "a.lua changed since the edit. Reject it, or ask again.")
  eq(c.status, "pending")
  eq(lines_of(a)[4], "  local sum = 0")
  local marks = vim.api.nvim_buf_get_extmarks(a, review.ns, 0, -1, { details = true })
  eq(#marks, 1, "only the warning shows")
  has(marks[1][4].virt_text[1][1], "changed since the edit")
end)

test("edit_file needs a unique exact match and builds on staged text", function()
  script({
    {
      tool_calls = {
        { name = "edit_file", arguments = { path = "a.lua", old_string = "not in the file", new_string = "x" } },
        { name = "edit_file", arguments = { path = "a.lua", old_string = "sum", new_string = "total" } },
        {
          name = "edit_file",
          arguments = { path = "a.lua", old_string = "  return sum", new_string = "  return sum + 0" },
        },
        { name = "read_file", arguments = { path = "a.lua", start_line = 8, end_line = 8 } },
        {
          name = "edit_file",
          arguments = { path = "a.lua", old_string = "  return sum + 0", new_string = "  return sum + 1" },
        },
        { name = "edit_file", arguments = { path = "new.lua", old_string = "a", new_string = "b" } },
      },
    },
    { content = "ok" },
  })
  use("script")
  edit("a.lua")
  send("edit")
  wait_idle()
  local r = tool_results(requests()[2])
  has(r["call_0_0"], "Error: old_string was not found in a.lua.")
  has(r["call_0_1"], "Error: old_string matches 4 places in a.lua.")
  has(r["call_0_2"], "Staged the edit to a.lua.")
  eq(r["call_0_3"], "a.lua, lines 8-8 of 11:\n     8\t  return sum + 0", "reads show staged text")
  has(r["call_0_4"], "Its pending changes are now +1 -1.")
  eq(r["call_0_5"], "Error: new.lua does not exist. Use create_file.")
  local S = assert(agent.get())
  eq(#S.changes.list, 1)
  eq(S.changes.list[1].staged[8], "  return sum + 1")
end)

test("create_file stages a new file; accepting opens an unsaved buffer", function()
  script({
    {
      tool_calls = {
        { name = "create_file", arguments = { path = "src/deep/new.lua", content = "return 1\n" } },
        { name = "create_file", arguments = { path = "b.lua", content = "x" } },
        { name = "create_file", arguments = { path = "src/deep/new.lua", content = "again" } },
      },
    },
    { content = "ok" },
  })
  use("script")
  edit("a.lua")
  send("create")
  wait_idle()
  local r = tool_results(requests()[2])
  eq(r["call_0_0"], "Staged the new file src/deep/new.lua (1 line). The user reviews it before it is created.")
  eq(r["call_0_1"], "Error: b.lua already exists. Use edit_file.")
  eq(r["call_0_2"], "Error: src/deep/new.lua already exists. Use edit_file.")
  eq(review.current.change.rel, "src/deep/new.lua")
  in_transcript("a")
  local buf = vim.fn.bufnr(project .. "/src/deep/new.lua")
  eq(lines_of(buf), { "return 1" })
  eq(vim.bo[buf].modified, true)
  eq(vim.uv.fs_stat(project .. "/src/deep/new.lua"), nil, "not written until :w")
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("silent write")
  end)
  eq(vim.fn.readfile(project .. "/src/deep/new.lua"), { "return 1" })
end)

test("attachments: selections from two buffers and a file, with Backspace removal", function()
  script({ { content = "Got them." } })
  use("script")
  local a = edit("a.lua")
  agent.open()
  vim.cmd.stopinsert()
  vim.api.nvim_set_current_win(code_win())
  feed("4GVj<C-l>")
  eq(vim.fn.mode(), "n", "Visual mode ends")
  eq(vim.api.nvim_get_current_buf(), a, "focus stays in the code")
  local b = edit("b.lua")
  feed("4G0wv$<C-l>")
  vim.cmd("LeaderKAdd src/util.lua")
  vim.cmd("LeaderKAdd a.lua")
  local S = assert(agent.get())
  eq(#S.attachments, 4)
  local labels = vim.tbl_map(function(x)
    return require("leader-k.context").label(x, S.root)
  end, S.attachments)
  eq(labels, { "lines 4-5 of a.lua", "part of line 4 of b.lua", "all of src/util.lua", "all of a.lua" })
  local chips = vim.api.nvim_buf_get_extmarks(S.panel.ibuf, -1, 0, 0, { details = true })
  local shown = {}
  for _, m in ipairs(chips) do
    if m[4].virt_lines_above then
      for _, l in ipairs(m[4].virt_lines) do
        shown[#shown + 1] = l[1][1]
      end
    end
  end
  eq(shown, {
    "Attached: lines 4-5 of a.lua",
    "Attached: part of line 4 of b.lua",
    "Attached: all of src/util.lua",
    "Attached: all of a.lua",
  })
  -- Backspace in the empty input drops the newest one.
  agent.open()
  vim.cmd.stopinsert()
  feed("a<BS><Esc>")
  vim.wait(50)
  eq(#S.attachments, 3)
  agent.submit("explain these")
  wait_idle()
  local user = requests()[1].messages[2].content
  has(user, '<attachment path="a.lua" lines="4-5">\n  local sum = 0\n  for i = 1, #items do\n</attachment>')
  has(user, '<attachment path="b.lua" lines="4-4" part="true">\nreturn "b"\n</attachment>')
  has(user, '<attachment path="src/util.lua" lines="1-5">\nlocal function answer()')
  truthy(not user:find('lines="1-11"', 1, true), "a.lua was removed and is not the default")
  eq(#S.attachments, 0, "attachments are cleared once sent")
  local t = transcript()
  has(t, "Attached: lines 4-5 of a.lua")
  has(t, "Attached: part of line 4 of b.lua")
  -- A later message sends nothing by default.
  script({ { content = "a" }, { content = "b" } })
  agent.submit("and now?")
  wait_idle()
  local reqs = requests()
  local msgs = reqs[#reqs].messages
  eq(msgs[#msgs].content, "and now?")
  eq(lines_of(b)[4], '  return "b"')
end)

test("the attach key works only while the panel is open, with a hint", function()
  use("script")
  local attach = require("leader-k.attach")
  vim.keymap.set("x", "<C-l>", "<Cmd>let g:lk_user_x = 1<CR>")
  edit("a.lua")
  feed("2GV<C-l>")
  eq(agent.get(), nil, "no panel: no attachment and no conversation")
  eq(vim.g.lk_user_x, 1, "the user's own mapping ran")
  vim.g.lk_user_x = nil
  feed("<Esc>")

  agent.open()
  vim.cmd.stopinsert()
  vim.api.nvim_set_current_win(code_win())
  local shown
  vim.keymap.set("x", "<F3>", function()
    shown = hint_text(attach.hint)
  end)
  feed("3GVj<F3>")
  eq(shown, "Ctrl-l attach", "Visual mode shows the hint")
  feed("<C-l>")
  eq(hint_text(attach.hint), nil, "the hint closes")
  eq(#agent.get().attachments, 1)
  eq(vim.g.lk_user_x, nil, "the panel's key shadowed the user's mapping")

  agent.hide()
  eq(attach.enabled(), false)
  feed("4GV<C-l>")
  eq(vim.g.lk_user_x, 1, "the user's mapping is back once the panel closes")
  eq(#agent.get().attachments, 1)
  vim.keymap.del("x", "<F3>")
  vim.keymap.del("x", "<C-l>")
  vim.g.lk_user_x = nil
end)

test("@path in a message attaches the file", function()
  script({ { content = "ok" } })
  use("script")
  edit("a.lua")
  send("compare with @src/util.lua, please")
  wait_idle()
  local user = requests()[1].messages[2].content
  has(user, '<attachment path="src/util.lua" lines="1-5">')
  truthy(not user:find('path="a.lua"', 1, true), "a mention replaces the default file")
  has(user, "compare with @src/util.lua, please")
end)

test("@ in the input completes project files", function()
  use("script")
  edit("a.lua")
  agent.open()
  vim.cmd.stopinsert()
  local S = assert(agent.get())
  local items
  vim.keymap.set("i", "<F2>", function()
    require("leader-k.panel")._complete_paths(S.panel.ibuf)
    items = vim.fn.complete_info({ "items" }).items
  end, { buffer = S.panel.ibuf })
  feed("alook at @uti<F2><C-e><Esc>")
  eq(
    vim.tbl_map(function(i)
      return i.word
    end, items or {}),
    { "@src/util.lua" }
  )
end)

test("diagnostics in an attachment are sent", function()
  script({ { content = "ok" } })
  use("script")
  local a = edit("a.lua")
  local ns = vim.api.nvim_create_namespace("lk-test")
  vim.diagnostic.set(ns, a, {
    { lnum = 5, col = 0, message = "undefined field `qty`", severity = vim.diagnostic.severity.WARN },
  })
  agent.attach_selection(a, 2, 8)
  send("fix")
  wait_idle()
  has(
    requests()[1].messages[2].content,
    '<diagnostics path="a.lua">\nline 6: warning: undefined field `qty`\n</diagnostics>'
  )
end)

test("the panel shows the default file before the first message", function()
  use("script")
  edit("a.lua")
  agent.open()
  vim.cmd.stopinsert()
  eq(transcript(), "Sending the whole file: a.lua")
end)

test("Ctrl-c stops a reply and keeps the conversation valid", function()
  script({ { content = "Thinking about it at length", delay = 0.1, piece = 3, hang = true }, { content = "Resumed." } })
  use("script")
  edit("a.lua")
  send("long")
  vim.wait(10000, function()
    return agent.get().phase == "writing"
  end, 10)
  local S = assert(agent.get())
  vim.api.nvim_set_current_win(S.panel.iwin)
  feed("<C-c>")
  eq(S.state, "idle")
  eq(http.active_count(), 0)
  has(transcript(), "Stopped.")
  local partial = S.messages[#S.messages]
  eq(partial.role, "assistant", "the partial reply is kept")
  send("go on")
  wait_idle()
  has(transcript(), "Resumed.")
end)

test("stopping during tool calls fills in their results", function()
  script({
    { tool_calls = { { name = "read_file", arguments = { path = "a.lua" } } }, delay = 0 },
    { content = "slow", delay = 0.2, hang = true },
    { content = "after" },
  })
  use("script")
  edit("a.lua")
  send("go")
  vim.wait(10000, function()
    local S = agent.get()
    return S.step == 2
  end, 10)
  agent.stop()
  local S = assert(agent.get())
  local roles = vim.tbl_map(function(m)
    return m.role
  end, S.messages)
  eq(roles, { "user", "assistant", "tool" })
  -- A stop between a reply's tool calls answers every call.
  script({
    {
      tool_calls = {
        { name = "search", arguments = { pattern = "x" } },
        { name = "read_file", arguments = { path = "a.lua" } },
      },
    },
  })
  agent.submit("again")
  agent.stop()
  local last = S.messages[#S.messages]
  truthy(last.role == "user" or last.role == "tool", "messages end with a user message or tool results")
end)

test("max_steps stops a loop that keeps calling tools", function()
  script({ { tool_calls = { { name = "list_files", arguments = {} } } } })
  use("script", { max_steps = 3 })
  edit("a.lua")
  send("loop")
  wait_idle()
  eq(#requests(), 3)
  has(transcript(), "Stopped after 3 requests for one message. Send a message to continue.")
end)

test("q with pending changes asks for a second q", function()
  script(EDITS)
  use("script")
  edit("a.lua")
  send("annotate")
  wait_idle()
  local S = assert(agent.get())
  vim.api.nvim_set_current_win(S.panel.twin)
  feed("q")
  truthy(agent.get(), "the first q only warns")
  has(warned[#warned], "2 files are pending review. Press q again")
  feed("q")
  eq(agent.get(), nil)
  eq(review.current, nil)
  eq(#vim.api.nvim_tabpage_list_wins(0), 1)
end)

test("closing the panel windows keeps the conversation", function()
  script({ { content = "First answer." } })
  use("script")
  edit("a.lua")
  send("hi")
  wait_idle()
  local S = assert(agent.get())
  vim.api.nvim_win_close(S.panel.twin, true)
  vim.wait(50)
  eq(#vim.api.nvim_tabpage_list_wins(0), 1, "both panel windows close")
  eq(agent.get(), S)
  lk.open()
  has(transcript(), "First answer.")
  eq(vim.api.nvim_get_current_win(), S.panel.iwin)
  vim.cmd.stopinsert()
end)

test(":LeaderKNew starts over", function()
  script(EDITS)
  use("script")
  edit("a.lua")
  send("annotate")
  wait_idle()
  vim.cmd("LeaderKNew")
  local S = assert(agent.get())
  eq(#S.items, 0)
  eq(#S.changes.list, 0)
  eq(review.current, nil)
  vim.cmd.stopinsert()
end)

test(":LeaderK with a range attaches it and sends the request", function()
  script({ { content = "ok" } })
  use("script")
  edit("a.lua")
  vim.cmd("3,4LeaderK explain")
  wait_idle()
  local user = requests()[1].messages[2].content
  has(user, '<attachment path="a.lua" lines="3-4">\nfunction M.total(items)\n  local sum = 0\n</attachment>')
  has(user, "explain")
end)

test("a dangling symlink to a file outside the project is refused", function()
  local outside = vim.fn.tempname() .. "-lk-outside/missing.lua"
  vim.uv.fs_symlink(outside, project .. "/link.lua")
  script({
    { tool_calls = { { name = "create_file", arguments = { path = "link.lua", content = "x" } } } },
    { content = "ok" },
  })
  use("script")
  edit("a.lua")
  send("create")
  wait_idle()
  has(tool_results(requests()[2])["call_0_0"], "Error: link.lua is outside the project root")
  eq(#agent.get().changes.list, 0)
end)

test("search never returns files git ignores, even through a glob", function()
  script({
    {
      tool_calls = {
        { name = "search", arguments = { pattern = "hunter2", glob = "*.txt" } },
        { name = "search", arguments = { pattern = "hunter2" } },
      },
    },
    { content = "ok" },
  })
  use("script")
  edit("a.lua")
  send("find it")
  wait_idle()
  local r = tool_results(requests()[2])
  eq(r["call_0_0"], "No matches.")
  eq(r["call_0_1"], "No matches.")
end)

test("a project root below the git repository still applies .gitignore", function()
  vim.fn.writefile({ "{}" }, project .. "/src/package.json")
  vim.fn.writefile({ "hunter2" }, project .. "/src/secret.txt")
  script({
    {
      tool_calls = {
        { name = "read_file", arguments = { path = "secret.txt" } },
        { name = "list_files", arguments = {} },
      },
    },
    { content = "ok" },
  })
  use("script", { root_markers = { "package.json" } })
  edit("src/util.lua")
  send("read")
  wait_idle()
  eq(agent.get().root, project .. "/src")
  local r = tool_results(requests()[2])
  eq(r["call_0_0"], "Error: secret.txt is ignored by git")
  eq(vim.split(r["call_0_1"], "\n"), { "package.json", "util.lua" })
end)

test("a later edit to the file under review redraws it", function()
  script({
    {
      tool_calls = {
        { name = "edit_file", arguments = { path = "a.lua", old_string = "return sum", new_string = "return first" } },
      },
    },
    { content = "First." },
    {
      tool_calls = {
        {
          name = "edit_file",
          arguments = { path = "a.lua", old_string = "return first", new_string = "return second" },
        },
      },
    },
    { content = "Second." },
  })
  use("script")
  local a = edit("a.lua")
  send("one")
  wait_idle()
  eq(review.current.change.rel, "a.lua")
  agent.submit("two")
  wait_idle()
  local shown = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(a, review.ns, 0, -1, { details = true })) do
    for _, l in ipairs(m[4].virt_lines or {}) do
      shown[#shown + 1] = vim.trim(table.concat(vim.tbl_map(function(c)
        return c[1]
      end, l)))
    end
  end
  eq(shown, { "return second" })
  in_transcript("a")
  eq(lines_of(a)[8], "  return second")
end)

test("accept refuses text that autocommands changed while loading the file", function()
  script(EDITS)
  use("script")
  edit("a.lua")
  send("annotate")
  wait_idle()
  local S = assert(agent.get())
  local c = S.changes.list[2]
  eq(c.rel, "b.lua")
  eq(vim.fn.bufnr(project .. "/b.lua"), -1, "b.lua is not loaded yet")
  local au = vim.api.nvim_create_autocmd("BufReadPost", {
    pattern = "*/b.lua",
    callback = function(ev)
      vim.api.nvim_buf_set_lines(ev.buf, 0, 1, false, { "-- from an autocommand" })
    end,
  })
  agent.decide_all("accepted")
  vim.api.nvim_del_autocmd(au)
  eq(c.status, "pending")
  local b = vim.fn.bufnr(project .. "/b.lua")
  eq(lines_of(b)[1], "-- from an autocommand")
  eq(lines_of(b)[4], '  return "b"')
end)

test("a rejected new file can be proposed again", function()
  script({
    { tool_calls = { { name = "create_file", arguments = { path = "new.lua", content = "one\n" } } } },
    { content = "ok" },
    { tool_calls = { { name = "create_file", arguments = { path = "new.lua", content = "two\n" } } } },
    { content = "ok" },
  })
  use("script")
  edit("a.lua")
  send("create")
  wait_idle()
  eq(review.current.change.rel, "new.lua")
  in_transcript("r")
  eq(vim.fn.bufnr(project .. "/new.lua"), -1, "the empty review buffer is gone")
  agent.submit("again")
  wait_idle()
  local reqs = requests()
  has(tool_results(reqs[#reqs])["call_2_0"], "Staged the new file new.lua")
end)

test("a reply streaming in does not reopen a closed panel", function()
  script({ { content = "A slow reply that keeps streaming.", delay = 0.05, piece = 2 } })
  use("script")
  edit("a.lua")
  send("slow")
  local S = assert(agent.get())
  vim.api.nvim_win_close(S.panel.twin, true)
  vim.wait(50)
  wait_idle()
  eq(require("leader-k.panel").is_open(S), false)
  eq(#vim.api.nvim_tabpage_list_wins(0), 1)
  lk.open()
  vim.cmd.stopinsert()
  has(transcript(), "A slow reply that keeps streaming.")
end)

test("HTTP 401 goes to the message area and the transcript", function()
  use("err401")
  edit("a.lua")
  send("x")
  wait_idle()
  has(echoed[#echoed], "HTTP 401")
  has(echoed[#echoed], "User not found.")
  has(transcript(), "Error: 127.0.0.1 returned HTTP 401")
end)

test("HTTP 402 explains credits", function()
  use("err402")
  edit("a.lua")
  send("x")
  wait_idle()
  has(echoed[#echoed], "Insufficient credits")
end)

test("a model without tool support gets a hint", function()
  use("notools")
  edit("a.lua")
  send("x")
  wait_idle()
  has(echoed[#echoed], "the model may not support tool calls")
end)

test("mid-stream provider error", function()
  use("midstream")
  edit("a.lua")
  send("x")
  wait_idle()
  has(echoed[#echoed], "Provider disconnected unexpectedly")
end)

test("stream cut without a finish reason", function()
  use("cut")
  edit("a.lua")
  send("x")
  wait_idle()
  has(echoed[#echoed], "the stream ended before the model finished")
end)

test("CRLF event stream and a stream without [DONE]", function()
  use("crlf")
  edit("a.lua")
  send("x")
  wait_idle()
  has(transcript(), "Hi there")
  use("nodone")
  agent.submit("y")
  wait_idle()
  has(transcript(), "Done")
end)

test("reasoning shows the thinking phase", function()
  script({ { reasoning = true, delay = 0.15, content = "ok" } })
  use("script")
  edit("a.lua")
  send("x")
  local saw = vim.wait(5000, function()
    return agent.get().phase == "thinking"
  end, 10)
  truthy(saw, "thinking phase")
  wait_idle()
end)

test("SSE parser: split chunks, comments, multi-line data", function()
  local got = {}
  local parse = require("leader-k.sse").parser(function(d)
    got[#got + 1] = d
  end)
  parse(": OPENROUTER PROCESSING\n\nda")
  parse("ta: one\ndata: two\n\ndata:three\r\n\r\n")
  eq(got, { "one\ntwo", "three" })
end)

test("params merge into the body and cannot turn streaming off", function()
  script({ { content = "ok" } })
  use("script", { params = { temperature = 0.1, stream = false, reasoning = { effort = "none" } } })
  edit("a.lua")
  send("x")
  wait_idle()
  local body = requests()[1]
  eq(body.temperature, 0.1)
  eq(body.stream, true)
  eq(body.reasoning, { effort = "none" })
end)

test("literal key and base URL produce a chat completion request", function()
  script({ { content = "ok" } })
  use("script", { base_url = BASE_URL .. "/" })
  edit("a.lua")
  send("x")
  wait_idle()
  local req = last_log()
  eq(req.auth_present, true)
  eq(req.auth_prefix, "Bearer ")
  eq(config.endpoint().url, BASE_URL .. "/chat/completions")
  use("script", { api_key = "LEADER_K_TEST_KEY" })
  eq(config.endpoint().key, "LEADER_K_TEST_KEY", "plain strings are literal keys, never variable names")
end)

test("key from the named environment variable is read for each request", function()
  local name = "LEADER_K_TEST_KEY"
  local saved = vim.env[name]
  vim.env[name] = "sk-from-env"
  use("script", { api_key = { env = name } })
  eq(config.endpoint().key, "sk-from-env")
  vim.env[name] = "sk-rotated"
  eq(config.endpoint().key, "sk-rotated")
  vim.env[name] = saved
end)

test("keyless endpoints send no Authorization header", function()
  script({ { content = "ok" } })
  lk.setup({ base_url = BASE_URL, model = "script" })
  local ep, err = config.endpoint()
  truthy(ep, err)
  eq(ep.key, nil)
  edit("a.lua")
  send("x")
  wait_idle()
  eq(last_log().auth_present, false)
end)

test("a keyless request surfaces authentication errors", function()
  lk.setup({ base_url = BASE_URL, model = "err401" })
  edit("a.lua")
  send("x")
  wait_idle()
  has(echoed[#echoed], "HTTP 401")
  has(echoed[#echoed], "set `api_key`")
end)

test("missing configuration stops a message", function()
  lk.setup({})
  local _, err = config.endpoint()
  has(err, "`base_url`")
  edit("a.lua")
  eq(send("x"), false)
  has(echoed[#echoed], "`base_url`")
  lk.setup({ base_url = BASE_URL })
  _, err = config.endpoint()
  has(err, "`model`")
  use("script", { api_key = { env = "LEADER_K_MISSING_TEST_KEY" } })
  local saved = vim.env.LEADER_K_MISSING_TEST_KEY
  vim.env.LEADER_K_MISSING_TEST_KEY = nil
  eq(agent.submit("x"), false)
  has(echoed[#echoed], "$LEADER_K_MISSING_TEST_KEY")
  vim.env.LEADER_K_MISSING_TEST_KEY = saved
  eq(#requests(), 0)
end)

test("invalid configuration is rejected without revealing secrets", function()
  local function err_for(extra)
    use("script", extra)
    local _, err = config.endpoint()
    return err
  end
  has(err_for({ base_url = "http://example.com/v1" }), "must use https")
  has(err_for({ base_url = BASE_URL .. "/chat/completions" }), "base_url")
  has(err_for({ api_key = { env = "INVALID-NAME" } }), "api_key")
  local e = err_for({ api_key = "sk-secret\nmalformed" })
  has(e, "api_key")
  truthy(not e:find("sk-secret", 1, true), e)
  has(err_for({ api_key = {} }), "api_key")
  has(err_for({ provider = "openrouter" }), "unknown configuration option `provider`")
  has(err_for({ timeout_ms = "180000" }), "`timeout_ms`")
  has(err_for({ max_steps = 0 }), "`max_steps`")
  has(err_for({ max_read_bytes = 1.5 }), "`max_read_bytes`")
  has(err_for({ root_markers = {} }), "`root_markers`")
  has(err_for({ keys = { next_file = "" } }), "`keys.next_file`")
end)

test("unreachable host", function()
  use("script", { base_url = "http://127.0.0.1:1/v1" })
  edit("a.lua")
  send("x")
  wait_idle()
  has(echoed[#echoed], "request failed")
end)

if vim.env.LEADER_K_LIVE == "1" then
  test("live compatible endpoint with tools", function()
    lk.setup({
      base_url = assert(vim.env.LEADER_K_BASE_URL),
      model = assert(vim.env.LEADER_K_MODEL),
      api_key = { env = "LEADER_K_API_KEY" },
    })
    edit("a.lua")
    send("Read src/util.lua and tell me the number it returns. Answer with the number only.")
    wait_idle(120000)
    print("     " .. transcript():gsub("\n", "\n     "))
    has(transcript(), "42")
  end)
end

server:kill(15)
vim.fn.delete(project, "rf")
print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
