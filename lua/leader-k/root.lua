-- The project root and the rule for which paths the tools may touch: files
-- under the root, outside .git, and not ignored by git.

local config = require("leader-k.config")

local M = {}

---The nearest directory above `start` (a file or directory) that holds one
---of `root_markers`, or Neovim's working directory.
---@param start string|nil
---@return string
function M.find(start)
  local cwd = vim.fn.getcwd()
  local from = start and start ~= "" and vim.fs.dirname(vim.fs.abspath(start)) or cwd
  local found = vim.fs.root(from, config.options.root_markers)
  return vim.fs.normalize(found or cwd)
end

---Resolves every symlink in `path`, including dangling ones, so a link
---to a missing file outside the root cannot pass for a path inside it.
---@param path string Absolute, normalized.
---@param depth integer|nil
---@return string
local function realpath(path, depth)
  depth = depth or 0
  local rest = {}
  local p = path
  while true do
    local real = vim.uv.fs_realpath(p)
    if real then
      return vim.fs.joinpath(real, unpack(rest))
    end
    local link = vim.uv.fs_readlink(p)
    if link and depth < 40 then
      -- A dangling link: follow its target instead of trusting its parent.
      local target = link:sub(1, 1) == "/" and link or vim.fs.joinpath(vim.fs.dirname(p), link)
      return realpath(vim.fs.normalize(vim.fs.joinpath(target, unpack(rest))), depth + 1)
    end
    local parent = vim.fs.dirname(p)
    if parent == p then
      return path
    end
    table.insert(rest, 1, vim.fs.basename(p))
    p = parent
  end
end

---Whether `root` is inside a git work tree. The repository may start above
---the root, as when `root_markers` names a file in a subdirectory.
---@param root string
---@return boolean
local function has_git(root)
  return vim.fn.executable("git") == 1 and vim.fs.root(root, ".git") ~= nil
end
M.has_git = has_git

---The paths of `rels` (relative to `root`) that git ignores.
---@param root string
---@param rels string[]
---@return table<string, true>
function M.ignored_set(root, rels)
  local out = {}
  if #rels == 0 or not has_git(root) then
    return out
  end
  local r = vim
    .system({ "git", "check-ignore", "--stdin", "-z" }, { cwd = root, text = true, stdin = table.concat(rels, "\0") .. "\0" })
    :wait(5000)
  for _, rel in ipairs(vim.split(r.stdout or "", "\0", { plain = true, trimempty = true })) do
    out[rel] = true
  end
  return out
end

---@param root string
---@param rel string
---@return boolean
local function ignored(root, rel)
  return M.ignored_set(root, { rel })[rel] == true
end

---Resolves `path`, relative to `root` unless absolute, for a tool.
---@param root string
---@param path any
---@return string|nil abs, string rel_or_err The path relative to the root, or why it is refused.
function M.resolve(root, path)
  if type(path) ~= "string" or vim.trim(path) == "" then
    return nil, "the path must be a nonempty string"
  end
  path = vim.trim(path)
  local abs = path:sub(1, 1) == "/" and path or vim.fs.joinpath(root, path)
  abs = vim.fs.normalize(abs)
  local real_root = vim.uv.fs_realpath(root) or root
  local real = realpath(abs)
  if real ~= real_root and real:sub(1, #real_root + 1) ~= real_root .. "/" then
    return nil, ("%s is outside the project root %s"):format(path, root)
  end
  local rel = real == real_root and "." or real:sub(#real_root + 2)
  for part in vim.gsplit(rel, "/", { plain = true }) do
    if part == ".git" then
      return nil, ("%s is inside .git"):format(path)
    end
  end
  if rel ~= "." and ignored(root, rel) then
    return nil, ("%s is ignored by git"):format(path)
  end
  return vim.fs.joinpath(root, rel ~= "." and rel or nil), rel
end

---@param root string
---@param abs string
---@return string
function M.relative(root, abs)
  local rel = vim.fs.relpath(root, abs)
  return rel or vim.fn.fnamemodify(abs, ":~")
end

return M
