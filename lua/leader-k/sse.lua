-- Incremental Server-Sent Events parser.
-- Handles split chunks, CRLF, comment lines, and multi-line `data:` fields.

local M = {}

---@param on_event fun(data: string)
---@return fun(chunk: string)
function M.parser(on_event)
  local buf = ""
  local data = nil ---@type string[]|nil

  local function line(l)
    if l == "" then
      if data then
        on_event(table.concat(data, "\n"))
        data = nil
      end
      return
    end
    if l:sub(1, 1) == ":" then
      return -- Comment, e.g. ": OPENROUTER PROCESSING".
    end
    local field, value = l:match("^([^:]*):?%s?(.*)$")
    if field == "data" then
      data = data or {}
      data[#data + 1] = value
    end
  end

  return function(chunk)
    buf = buf .. chunk
    while true do
      local i = buf:find("\n", 1, true)
      if not i then
        break
      end
      local l = buf:sub(1, i - 1)
      buf = buf:sub(i + 1)
      if l:sub(-1) == "\r" then
        l = l:sub(1, -2)
      end
      line(l)
    end
  end
end

return M
