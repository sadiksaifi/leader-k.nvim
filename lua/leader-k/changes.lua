-- Edits the agent proposed, staged per file until the user accepts or
-- rejects them. Nothing here touches a buffer except accept().

local M = {}

---@class leader_k.Change
---@field path string Absolute path.
---@field rel string Path shown to the user and the model.
---@field original string[] The file as it was when first edited; empty for a new file.
---@field staged string[] The file with the proposed edits.
---@field new boolean The file does not exist yet.
---@field status "pending"|"accepted"|"rejected"
---@field hunks integer[][]
---@field added integer
---@field removed integer

---@param a string[]
---@param b string[]
function M.same(a, b)
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
---@return integer[][]
function M.diff(a, b)
  local sa = #a > 0 and table.concat(a, "\n") .. "\n" or ""
  local sb = #b > 0 and table.concat(b, "\n") .. "\n" or ""
  return vim.text.diff(sa, sb, { result_type = "indices", algorithm = "histogram", linematch = 40 }) --[[@as integer[][] ]]
end

---@param c leader_k.Change
local function measure(c)
  c.hunks = M.diff(c.original, c.staged)
  c.added, c.removed = 0, 0
  for _, h in ipairs(c.hunks) do
    c.removed = c.removed + h[2]
    c.added = c.added + h[4]
  end
end

---A buffer always has a line, so one empty line counts as no lines.
---@param lines string[]
---@return string[]
function M.normalize(lines)
  if #lines == 1 and lines[1] == "" then
    return {}
  end
  return lines
end

---The loaded buffer for `path`, if any.
---@param path string
---@return integer|nil
function M.loaded_buf(path)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    return buf
  end
end

---The file's text as the editor sees it: the loaded buffer, unsaved changes
---included, or the file on disk.
---@param path string
---@return string[]|nil lines, boolean|nil exists
function M.read(path)
  local buf = M.loaded_buf(path)
  if buf then
    return M.normalize(vim.api.nvim_buf_get_lines(buf, 0, -1, false)), true
  end
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil, false
  end
  if stat.type ~= "file" then
    return nil, true
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, true
  end
  return M.normalize(lines), true
end

---@class leader_k.Changes
---@field list leader_k.Change[] In the order the files were first edited.
local Changes = {}
Changes.__index = Changes

---@return leader_k.Changes
function M.new()
  return setmetatable({ list = {} }, Changes)
end

---@param path string
---@return leader_k.Change|nil
function Changes:pending_for(path)
  for _, c in ipairs(self.list) do
    if c.path == path and c.status == "pending" then
      return c
    end
  end
end

---The file's text with any pending edits.
---@param path string
---@return string[]|nil lines, boolean exists Whether the file exists or is staged as new.
function Changes:text(path)
  local c = self:pending_for(path)
  if c then
    return c.staged, true
  end
  local lines, exists = M.read(path)
  return lines, exists == true
end

---Stages `lines` as the new text of `path`. A file with pending edits keeps
---its original, so the review shows every edit at once.
---@param path string
---@param rel string
---@param lines string[]
---@param new boolean|nil
---@return leader_k.Change
function Changes:stage(path, rel, lines, new)
  local c = self:pending_for(path)
  if not c then
    c = {
      path = path,
      rel = rel,
      original = new and {} or (M.read(path) or {}),
      new = new == true,
      status = "pending",
    }
    self.list[#self.list + 1] = c
  end
  c.staged = M.normalize(lines)
  measure(c)
  return c
end

---@return leader_k.Change[]
function Changes:pending()
  return vim.tbl_filter(function(c)
    return c.status == "pending"
  end, self.list)
end

---Whether the file changed since its edits were staged.
---@param c leader_k.Change
---@return boolean
function Changes:stale(c)
  return not M.same(M.read(c.path) or {}, c.original)
end

---Applies the change to the file's buffer, loading it first, as one undo
---step. The buffer is left unsaved.
---@param c leader_k.Change
---@return integer|nil buf, string|nil err
function Changes:accept(c)
  if c.status ~= "pending" then
    return nil, "this change is no longer pending"
  end
  if self:stale(c) then
    return nil, ("%s changed since the edit. Reject it, or ask again."):format(c.rel)
  end
  if c.new then
    -- So that :w can create the file.
    vim.fn.mkdir(vim.fs.dirname(c.path), "p")
  end
  local buf = vim.fn.bufadd(vim.fn.fnamemodify(c.path, ":~:."))
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = true
  if not vim.bo[buf].modifiable then
    return nil, ("%s is not modifiable"):format(c.rel)
  end
  if #c.original == 0 then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, c.staged)
  else
    -- From the last hunk up, so earlier rows stay where the diff says.
    for i = #c.hunks, 1, -1 do
      local sa, ca, sb, cb = unpack(c.hunks[i])
      local start = ca == 0 and sa or sa - 1
      local repl = vim.list_slice(c.staged, sb, sb + cb - 1)
      vim.api.nvim_buf_set_lines(buf, start, start + ca, false, repl)
    end
  end
  c.status = "accepted"
  return buf
end

---@param c leader_k.Change
function Changes:reject(c)
  if c.status == "pending" then
    c.status = "rejected"
  end
end

return M
