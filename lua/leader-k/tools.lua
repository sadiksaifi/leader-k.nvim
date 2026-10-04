-- The tools the model can call, as Chat Completions definitions and their
-- executors. Every result is a string for a `role = "tool"` message. Edits
-- go to the staged changes, never to a buffer or a file.

local changes = require("leader-k.changes")
local config = require("leader-k.config")
local root = require("leader-k.root")

local M = {}

local MAX_FILES = 500
local MAX_MATCHES = 200
local MAX_LINE = 300

---@class leader_k.ToolContext
---@field root string
---@field changes leader_k.Changes

---@alias leader_k.ToolDone fun(result: string, note: string|nil)

local function object(props, required)
  return { type = "object", properties = props, required = required or {}, additionalProperties = false }
end

---@type table[]
M.definitions = {
  {
    type = "function",
    ["function"] = {
      name = "read_file",
      description = "Read a project file. Lines come numbered as `number<TAB>text`; the numbers are not part of the file. Files with proposed edits read back with those edits.",
      parameters = object({
        path = { type = "string", description = "Path relative to the project root." },
        start_line = { type = "integer", description = "First line to read, 1-based. Defaults to 1." },
        end_line = { type = "integer", description = "Last line to read, inclusive. Defaults to the end." },
      }, { "path" }),
    },
  },
  {
    type = "function",
    ["function"] = {
      name = "list_files",
      description = "List project files, skipping files ignored by git.",
      parameters = object({
        path = { type = "string", description = "Directory relative to the project root. Defaults to the root." },
        pattern = {
          type = "string",
          description = "Glob such as `*.lua` or `src/**/*.ts`. Without a slash it matches file names; with one, paths from the root.",
        },
      }),
    },
  },
  {
    type = "function",
    ["function"] = {
      name = "search",
      description = "Search project files for a regular expression. Returns `path:line:text` matches.",
      parameters = object({
        pattern = { type = "string", description = "Regular expression." },
        path = {
          type = "string",
          description = "File or directory relative to the project root. Defaults to the root.",
        },
        glob = { type = "string", description = "Only search files matching this glob, such as `*.go`." },
      }, { "pattern" }),
    },
  },
  {
    type = "function",
    ["function"] = {
      name = "edit_file",
      description = "Propose replacing one exact piece of a file. `old_string` must match the file's text exactly once, including indentation; include surrounding lines to make it unique. The user reviews the change before it applies.",
      parameters = object({
        path = { type = "string", description = "Path relative to the project root." },
        old_string = { type = "string", description = "Exact text to replace, without line numbers." },
        new_string = { type = "string", description = "Replacement text." },
      }, { "path", "old_string", "new_string" }),
    },
  },
  {
    type = "function",
    ["function"] = {
      name = "create_file",
      description = "Propose a new file. Fails if the file exists. The user reviews it before it is created.",
      parameters = object({
        path = { type = "string", description = "Path relative to the project root." },
        content = { type = "string", description = "The whole file." },
      }, { "path", "content" }),
    },
  },
}

---@param n integer
---@param word string
---@param plural string|nil
local function count(n, word, plural)
  return ("%d %s"):format(n, n == 1 and word or (plural or word .. "s"))
end

---@param rel string
local function tail(rel)
  return vim.fs.basename(rel)
end

---@param path string
---@return boolean
local function binary(path)
  local f = io.open(path, "rb")
  if not f then
    return false
  end
  local head = f:read(8000) or ""
  f:close()
  return head:find("\0", 1, true) ~= nil
end

---@param ctx leader_k.ToolContext
---@param args table
---@param done leader_k.ToolDone
local function read_file(ctx, args, done)
  local abs, rel = root.resolve(ctx.root, args.path)
  if not abs then
    return done("Error: " .. rel)
  end
  local stat = vim.uv.fs_stat(abs)
  if stat and stat.type == "directory" then
    return done(("Error: %s is a directory. Use list_files."):format(rel))
  end
  if stat and not ctx.changes:pending_for(abs) and not changes.loaded_buf(abs) and binary(abs) then
    return done(("Error: %s is a binary file."):format(rel))
  end
  local lines, exists = ctx.changes:text(abs)
  if not exists then
    return done(("Error: %s does not exist."):format(rel))
  end
  if not lines then
    return done(("Error: %s cannot be read."):format(rel))
  end
  local total = #lines
  if total == 0 then
    return done(("%s is empty."):format(rel), ("Read %s (empty)"):format(tail(rel)))
  end
  local first = math.max(1, math.floor(tonumber(args.start_line) or 1))
  local last = math.min(total, math.floor(tonumber(args.end_line) or total))
  if first > total then
    return done(("Error: %s has %s; start_line %d is past the end."):format(rel, count(total, "line"), first))
  end
  if last < first then
    return done("Error: end_line is before start_line.")
  end
  local out, size, shown = {}, 0, last
  local cap = config.options.max_read_bytes
  for i = first, last do
    local line = ("%6d\t%s"):format(i, lines[i])
    size = size + #line + 1
    if size > cap and i > first then
      shown = i - 1
      break
    end
    out[#out + 1] = line
  end
  local head = ("%s, lines %d-%d of %d:"):format(rel, first, shown, total)
  local text = head .. "\n" .. table.concat(out, "\n")
  if shown < last then
    text = text .. ("\n[Stopped at %d bytes. Read on with start_line=%d.]"):format(cap, shown + 1)
  end
  local whole = first == 1 and shown == total
  done(text, whole and ("Read %s"):format(tail(rel)) or ("Read %s, lines %d-%d"):format(tail(rel), first, shown))
end

---@param cmd string[]
---@param cwd string
---@param cb fun(r: vim.SystemCompleted)
---@return fun() cancel
local function run(cmd, cwd, cb)
  local ok, proc = pcall(vim.system, cmd, { cwd = cwd, text = true }, vim.schedule_wrap(cb))
  if not ok then
    vim.schedule(function()
      cb({ code = -1, signal = 0, stdout = "", stderr = tostring(proc) })
    end)
    return function() end
  end
  return function()
    pcall(proc.kill, proc, "sigterm")
  end
end

---@param pattern string|nil
---@return (fun(rel: string): boolean)|nil, string|nil err
local function glob_filter(pattern)
  if type(pattern) ~= "string" or pattern == "" then
    return function()
      return true
    end
  end
  local ok, lpeg = pcall(vim.glob.to_lpeg, pattern)
  if not ok then
    return nil, ("invalid glob %s"):format(pattern)
  end
  local by_name = not pattern:find("/", 1, true)
  return function(rel)
    return lpeg:match(by_name and vim.fs.basename(rel) or rel) ~= nil
  end
end

---@param files string[] Paths relative to the root.
---@param dir string Directory relative to the root.
---@param pattern string|nil
---@param done leader_k.ToolDone
local function report_files(files, dir, pattern, done)
  local keep, err = glob_filter(pattern)
  if not keep then
    return done("Error: " .. err)
  end
  local seen, out = {}, {}
  for _, f in ipairs(files) do
    if f ~= "" and not seen[f] and keep(f) then
      seen[f] = true
      out[#out + 1] = f
    end
  end
  table.sort(out)
  local where = dir == "." and "the project" or dir
  local note = ("Listed %s%s: %s"):format(
    where,
    pattern and pattern ~= "" and (" " .. pattern) or "",
    count(#out, "file")
  )
  if #out == 0 then
    return done(("No files in %s match."):format(where), note)
  end
  local text = table.concat(vim.list_slice(out, 1, MAX_FILES), "\n")
  if #out > MAX_FILES then
    text = text .. ("\n[%d of %d files shown. Narrow with path or pattern.]"):format(MAX_FILES, #out)
  end
  done(text, note)
end

---@param ctx leader_k.ToolContext
---@param args table
---@param done leader_k.ToolDone
---@return fun()|nil cancel
local function list_files(ctx, args, done)
  local abs, dir = root.resolve(ctx.root, args.path or ".")
  if not abs then
    return done("Error: " .. dir)
  end
  local stat = vim.uv.fs_stat(abs)
  if not stat or stat.type ~= "directory" then
    return done(("Error: %s is not a directory."):format(dir))
  end
  if root.has_git(ctx.root) then
    return run({ "git", "ls-files", "-co", "--exclude-standard", "--", dir }, ctx.root, function(r)
      if r.code ~= 0 then
        return done("Error: git ls-files failed: " .. vim.trim(r.stderr or ""))
      end
      local files = vim.tbl_filter(function(f)
        return vim.uv.fs_stat(vim.fs.joinpath(ctx.root, f)) ~= nil
      end, vim.split(r.stdout or "", "\n", { plain = true, trimempty = true }))
      report_files(files, dir, args.pattern, done)
    end)
  end
  local files = {}
  for name, type in
    vim.fs.dir(abs, {
      depth = 20,
      skip = function(d)
        return vim.fs.basename(d) ~= ".git"
      end,
    })
  do
    if type == "file" then
      files[#files + 1] = dir == "." and name or (dir .. "/" .. name)
    end
  end
  report_files(files, dir, args.pattern, done)
end

---@param ctx leader_k.ToolContext
---@param args table
---@param done leader_k.ToolDone
---@return fun()|nil cancel
local function search(ctx, args, done)
  local pattern = args.pattern
  if type(pattern) ~= "string" or pattern == "" then
    return done("Error: pattern must be a nonempty string.")
  end
  local abs, where = root.resolve(ctx.root, args.path or ".")
  if not abs then
    return done("Error: " .. where)
  end
  local glob = type(args.glob) == "string" and args.glob ~= "" and args.glob or nil
  local cmd
  if vim.fn.executable("rg") == 1 then
    cmd = { "rg", "--line-number", "--no-heading", "--color", "never", "--max-count", "50", "--max-columns", "300" }
    if glob then
      vim.list_extend(cmd, { "--glob", glob })
    end
    vim.list_extend(cmd, { "-e", pattern, "--", where })
  elseif root.has_git(ctx.root) then
    cmd = {
      "git",
      "grep",
      "-n",
      "-I",
      "--untracked",
      "-E",
      "-e",
      pattern,
      "--",
      glob and (":(glob)" .. (where == "." and "" or where .. "/") .. "**/" .. glob) or where,
    }
  else
    return done("Error: search needs ripgrep (rg) or git, and neither is available.")
  end
  local shown = pattern:gsub("\n", " ")
  return run(cmd, ctx.root, function(r)
    -- Both tools exit with 1 when nothing matches.
    if r.code == 1 and vim.trim(r.stderr or "") == "" then
      return done("No matches.", ('Searched "%s": no matches'):format(shown))
    end
    if r.code ~= 0 then
      return done("Error: " .. vim.trim(r.stderr ~= "" and r.stderr or ("search exited with " .. r.code)))
    end
    local hits = vim.split(r.stdout or "", "\n", { plain = true, trimempty = true })
    local out = {}
    for i = 1, math.min(#hits, MAX_MATCHES) do
      local h = hits[i]:gsub("^%./", "")
      out[i] = #h > MAX_LINE + 40 and (h:sub(1, MAX_LINE + 40) .. " [...]") or h
    end
    local text = table.concat(out, "\n")
    if #hits > MAX_MATCHES then
      text = text .. ("\n[%d of %d matches shown. Narrow the pattern, path or glob.]"):format(MAX_MATCHES, #hits)
    end
    done(text, ('Searched "%s": %s'):format(shown, count(#hits, "match", "matches")))
  end)
end

---@param s string
---@return string[]
local function to_lines(s)
  local lines = vim.split(s, "\n", { plain = true })
  if #lines > 1 and lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

---@param c leader_k.Change
local function counts(c)
  return ("+%d -%d"):format(c.added, c.removed)
end

---@param ctx leader_k.ToolContext
---@param args table
---@param done leader_k.ToolDone
local function edit_file(ctx, args, done)
  local abs, rel = root.resolve(ctx.root, args.path)
  if not abs then
    return done("Error: " .. rel)
  end
  local old, new = args.old_string, args.new_string
  if type(old) ~= "string" or old == "" then
    return done("Error: old_string must be nonempty. Use create_file for a new file.")
  end
  if type(new) ~= "string" then
    return done("Error: new_string must be a string.")
  end
  if old == new then
    return done("Error: old_string and new_string are the same.")
  end
  local lines, exists = ctx.changes:text(abs)
  if not exists then
    return done(("Error: %s does not exist. Use create_file."):format(rel))
  end
  if not lines then
    return done(("Error: %s cannot be read."):format(rel))
  end
  local text = table.concat(lines, "\n")
  local at, n, from = nil, 0, 1
  while true do
    local s = text:find(old, from, true)
    if not s then
      break
    end
    n = n + 1
    at = at or s
    from = s + 1
  end
  if n == 0 then
    return done(
      ("Error: old_string was not found in %s. Read the file again and copy the text exactly, including indentation."):format(
        rel
      )
    )
  end
  if n > 1 then
    return done(
      ("Error: old_string matches %d places in %s. Include more surrounding lines so it matches once."):format(n, rel)
    )
  end
  local result = text:sub(1, at - 1) .. new .. text:sub(at + #old)
  local c = ctx.changes:stage(abs, rel, vim.split(result, "\n", { plain = true }))
  done(
    ("Staged the edit to %s. Its pending changes are now %s. The user reviews them before they apply."):format(
      rel,
      counts(c)
    ),
    ("Edited %s %s"):format(tail(rel), counts(c))
  )
end

---@param ctx leader_k.ToolContext
---@param args table
---@param done leader_k.ToolDone
local function create_file(ctx, args, done)
  local abs, rel = root.resolve(ctx.root, args.path)
  if not abs then
    return done("Error: " .. rel)
  end
  if type(args.content) ~= "string" then
    return done("Error: content must be a string.")
  end
  local _, exists = ctx.changes:text(abs)
  if exists or vim.uv.fs_stat(abs) then
    return done(("Error: %s already exists. Use edit_file."):format(rel))
  end
  local c = ctx.changes:stage(abs, rel, to_lines(args.content), true)
  done(
    ("Staged the new file %s (%s). The user reviews it before it is created."):format(rel, count(#c.staged, "line")),
    ("Created %s %s"):format(tail(rel), counts(c))
  )
end

local executors = {
  read_file = read_file,
  list_files = list_files,
  search = search,
  edit_file = edit_file,
  create_file = create_file,
}

---What a running tool call is doing, for the status line.
---@param name string
---@param arguments string|nil
---@return string
function M.activity(name, arguments)
  local ok, args = pcall(vim.json.decode, arguments or "")
  local path = ok and type(args) == "table" and type(args.path) == "string" and tail(args.path) or nil
  if name == "read_file" then
    return path and ("Reading " .. path) or "Reading"
  elseif name == "list_files" then
    return "Listing files"
  elseif name == "search" then
    return "Searching"
  elseif name == "edit_file" then
    return path and ("Editing " .. path) or "Editing"
  elseif name == "create_file" then
    return path and ("Creating " .. path) or "Creating a file"
  end
  return "Running " .. name
end

---Runs one tool call. `done` is called once, unless cancel runs first.
---@param ctx leader_k.ToolContext
---@param call leader_k.ToolCall
---@param done leader_k.ToolDone
---@return fun()|nil cancel
function M.run(ctx, call, done)
  local name = call["function"].name
  local fn = executors[name]
  if not fn then
    done(("Error: there is no tool named %s."):format(name))
    return
  end
  local raw = call["function"].arguments
  local ok, args = pcall(vim.json.decode, raw ~= "" and raw or "{}", { luanil = { object = true, array = true } })
  if not ok or type(args) ~= "table" then
    done(("Error: the arguments for %s are not a JSON object."):format(name))
    return
  end
  local finished = false
  local cancel = fn(ctx, args, function(result, note)
    if not finished then
      finished = true
      done(result, note)
    end
  end)
  return function()
    finished = true
    if cancel then
      cancel()
    end
  end
end

return M
