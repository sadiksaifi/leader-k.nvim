-- OpenAI-compatible Chat Completions streaming client.

local http = require("leader-k.http")
local sse = require("leader-k.sse")

local M = {}

local MAX_ERROR_BODY = 64 * 1024

local hints = {
  [401] = "check the API key",
  [402] = "the account is out of credits",
  [403] = "the request was refused, possibly by moderation",
  [404] = "check `model` and `url`",
  [408] = "the provider timed out",
  [429] = "rate limited; try again shortly",
  [502] = "the model provider failed",
  [503] = "the model is temporarily unavailable",
}

---@param ep leader_k.Endpoint
---@param status integer
---@param body string
local function http_error(ep, status, body)
  local ok, decoded = pcall(vim.json.decode, body)
  local msg
  if ok and type(decoded) == "table" and type(decoded.error) == "table" then
    msg = decoded.error.message
    local raw = vim.tbl_get(decoded.error, "metadata", "raw")
    if type(raw) == "string" and #raw < 300 and raw ~= msg then
      msg = ("%s (%s)"):format(msg, raw)
    end
  end
  if type(msg) ~= "string" or msg == "" then
    msg = vim.trim(body:sub(1, 200))
  end
  local text = ("%s returned HTTP %d"):format(ep.name, status)
  if msg ~= "" then
    text = text .. ": " .. msg
  end
  -- Provider messages can be cryptic ("User not found." for a bad key), so
  -- add a hint for statuses with one likely cause, or when there is no message.
  local hint = status == 401 and not ep.key and "set `api_key` in setup()" or hints[status]
  if (status == 400 or status == 404) and msg:lower():find("tool", 1, true) then
    hint = "the model may not support tool calls"
  end
  if hint and (msg == "" or status == 400 or status == 401 or status == 404) then
    text = text .. " (" .. hint .. ")"
  end
  return text
end

---@class leader_k.ToolCall
---@field id string
---@field type "function"
---@field function { name: string, arguments: string }

---@class leader_k.Reply
---@field content string
---@field tool_calls leader_k.ToolCall[]
---@field finish_reason string|nil

---@class leader_k.StreamHandlers
---@field on_reasoning fun()
---@field on_text fun(delta: string)
---@field on_tool fun(name: string) A tool call starts streaming.
---@field on_done fun(reply: leader_k.Reply)
---@field on_error fun(msg: string)

---Streams a chat completion. Exactly one of on_done or on_error is called,
---unless the returned cancel function runs first.
---@param ep leader_k.Endpoint
---@param messages table[] Chat Completions messages.
---@param tools table[]|nil Tool definitions.
---@param h leader_k.StreamHandlers
---@param timeout_ms integer
---@return fun()|nil cancel, string|nil err
function M.stream(ep, messages, tools, h, timeout_ms)
  local body = vim.tbl_deep_extend("force", {
    model = ep.model,
    messages = messages,
    stream = true,
  }, ep.params)
  body.stream = true
  if tools and #tools > 0 then
    body.tools = tools
    body.tool_choice = body.tool_choice or "auto"
  end

  local headers = {
    "Content-Type: application/json",
    "Accept: text/event-stream",
  }
  if ep.key then
    headers[#headers + 1] = "Authorization: Bearer " .. ep.key
  end

  local status, error_body = nil, {}
  local error_size = 0
  local finished, failed, finish_reason = false, false, nil
  local content, calls = {}, {} ---@type string[], table<integer, { id: string, name: string, args: string[] }>

  local function reply()
    local list = {}
    local indices = vim.tbl_keys(calls)
    table.sort(indices)
    for n, i in ipairs(indices) do
      local c = calls[i]
      list[#list + 1] = {
        id = c.id ~= "" and c.id or ("call_" .. n),
        type = "function",
        ["function"] = { name = c.name, arguments = table.concat(c.args) },
      }
    end
    return { content = table.concat(content), tool_calls = list, finish_reason = finish_reason }
  end

  local function fail(msg)
    if not failed and not finished then
      failed = true
      h.on_error(msg)
    end
  end

  local feed = sse.parser(function(data)
    if finished or failed then
      return
    end
    if data == "[DONE]" then
      finished = true
      h.on_done(reply())
      return
    end
    local ok, chunk = pcall(vim.json.decode, data, { luanil = { object = true, array = true } })
    if not ok or type(chunk) ~= "table" then
      return
    end
    if type(chunk.error) == "table" then
      fail(("%s: %s"):format(ep.name, chunk.error.message or "the stream failed"))
      return
    end
    local choice = chunk.choices and chunk.choices[1]
    if type(choice) ~= "table" then
      return
    end
    local delta = choice.delta or {}
    if
      (type(delta.reasoning) == "string" and delta.reasoning ~= "")
      or (type(delta.reasoning_content) == "string" and delta.reasoning_content ~= "")
    then
      h.on_reasoning()
    end
    if type(delta.content) == "string" and delta.content ~= "" then
      content[#content + 1] = delta.content
      h.on_text(delta.content)
    end
    -- Tool calls arrive in pieces keyed by index: the id and name first,
    -- then the arguments as JSON text in chunks.
    for _, tc in ipairs(type(delta.tool_calls) == "table" and delta.tool_calls or {}) do
      if type(tc) == "table" then
        local i = type(tc.index) == "number" and tc.index or 0
        local c = calls[i]
        if not c then
          c = { id = "", name = "", args = {} }
          calls[i] = c
        end
        if type(tc.id) == "string" and tc.id ~= "" then
          c.id = tc.id
        end
        local fn = type(tc["function"]) == "table" and tc["function"] or {}
        if type(fn.name) == "string" and fn.name ~= "" then
          local first = c.name == ""
          c.name = c.name .. fn.name
          if first then
            h.on_tool(c.name)
          end
        end
        if type(fn.arguments) == "string" then
          c.args[#c.args + 1] = fn.arguments
        end
      end
    end
    if type(choice.finish_reason) == "string" then
      finish_reason = choice.finish_reason
      if finish_reason == "error" then
        fail(ep.name .. ": the model stopped with an error")
      end
    end
  end)

  return http.post({
    url = ep.url,
    headers = headers,
    body = vim.json.encode(body),
    timeout_ms = timeout_ms,
    libcurl = ep.libcurl,
    on_status = function(s)
      status = s
    end,
    on_data = function(chunk)
      if status and status >= 200 and status < 300 then
        feed(chunk)
      elseif error_size < MAX_ERROR_BODY then
        error_body[#error_body + 1] = chunk
        error_size = error_size + #chunk
      end
    end,
    on_done = function(err, final_status)
      status = status or final_status
      if finished or failed then
        return
      end
      if status and status ~= 0 and (status < 200 or status >= 300) then
        fail(http_error(ep, status, table.concat(error_body)))
      elseif err then
        fail("request failed: " .. err)
      else
        -- Some servers close the stream without sending [DONE]. Accept that
        -- only when the model reported why it stopped.
        feed("\n\n")
        if finish_reason then
          if not finished and not failed then
            finished = true
            h.on_done(reply())
          end
        else
          fail("the stream ended before the model finished")
        end
      end
    end,
  })
end

return M
