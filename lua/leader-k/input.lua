-- Request history for the panel input.

local M = {}

local history = {} ---@type string[]
local MAX_HISTORY = 100

---Adds a sent request to the history.
---@param t string
function M.remember(t)
  for i = #history, 1, -1 do
    if history[i] == t then
      table.remove(history, i)
    end
  end
  history[#history + 1] = t
  if #history > MAX_HISTORY then
    table.remove(history, 1)
  end
end

---Maps Up and Down in Insert mode to step through the history in `buf`,
---keeping what was typed as a draft past the newest entry.
---@param buf integer
---@return fun() reset Starts the next recall from the newest entry.
function M.map_history(buf)
  local pos, draft = #history + 1, nil
  local function recall(step)
    if #history == 0 then
      return
    end
    if pos > #history then
      draft = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end
    pos = math.max(1, math.min(#history + 1, pos + step))
    local lines = pos > #history and (draft or { "" }) or vim.split(history[pos], "\n", { plain = true })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(0, { #lines, #lines[#lines] })
  end
  for lhs, step in pairs({ ["<Up>"] = -1, ["<Down>"] = 1 }) do
    vim.keymap.set("i", lhs, function()
      recall(step)
    end, { buffer = buf, nowait = true, silent = true })
  end
  return function()
    pos, draft = #history + 1, nil
  end
end

return M
