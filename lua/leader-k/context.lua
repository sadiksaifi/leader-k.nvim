-- What a request tells the model about the file around the selection.

local config = require("leader-k.config")

local M = {}

---Builds the context for rows r0..r1 (0-based, inclusive) of `buf`.
---@param buf integer
---@param r0 integer
---@param r1 integer
---@param selection string[] The selected lines.
---@return leader_k.Context
function M.build(buf, r0, r1, selection)
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
  return {
    path = name ~= "" and vim.fn.fnamemodify(name, ":~:.") or "[unnamed buffer]",
    filetype = vim.bo[buf].filetype,
    line_count = vim.api.nvim_buf_line_count(buf),
    first_row = r0 + 1,
    before = vim.list_slice(before, first),
    omitted_before = first - 1,
    selection = selection,
    after = vim.list_slice(after, 1, last),
    omitted_after = #after - last,
    diagnostics = diagnostics,
  }
end

return M
