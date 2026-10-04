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

---Resolves symlinks in the deepest part of `path` that exists.
---@param path string Absolute, normalized.
---@return string
local function realpath(path)
  local rest = {}
  local p = path
  while true do
    local real = vim.uv.fs_realpath(p)
    if real then
      return vim.fs.joinpath(real, unpack(rest))
    end
    local parent = vim.fs.dirname(p)
    if parent == p then
      return path
    end
    table.insert(rest, 1, vim.fs.basename(p))
    p = parent
  end
end

---@param root string
---@return boolean
local function has_git(root)
  return vim.fn.executable("git") == 1 and vim.uv.fs_stat(vim.fs.joinpath(root, ".git")) ~= nil
end
M.has_git = has_git

---@param root string
---@param rel string
---@return boolean
local function ignored(root, rel)
  if not has_git(root) then
    return false
  end
  local r = vim.system({ "git", "check-ignore", "-q", "--", rel }, { cwd = root, text = true }):wait(5000)
  return r.code == 0
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
