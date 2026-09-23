-- Builds the request messages and turns streamed model output into lines.

local M = {}

M.system = [[
You edit code in Neovim. The user selected a region of a file and asked for a change to it.

Reply with the complete new text for the selected region inside one <code></code> block, and nothing else.
- The block replaces the selection exactly. Include every line of the new region, unchanged lines too. Never elide code or write placeholders.
- Do not repeat code from <before> or <after>.
- Keep the file's indentation style (tabs or spaces) and the selection's base indentation.
- No markdown fences, no commentary, no text outside the block.
- If the instruction cannot be done by rewriting this selection, reply with <error>one short sentence</error> instead.
]]

---@class leader_k.Context
---@field path string
---@field filetype string
---@field line_count integer
---@field first_row integer 1-based line of the selection's first line.
---@field before string[]
---@field omitted_before integer Lines above `before` that were left out.
---@field selection string[]
---@field after string[]
---@field omitted_after integer Lines below `after` that were left out.
---@field diagnostics string[]

---@class leader_k.Turn
---@field instruction string
---@field proposal string[]|nil

---@param ctx leader_k.Context
---@param instruction string
local function first_message(ctx, instruction)
  local out = {}
  local ft = ctx.filetype ~= "" and ctx.filetype or "plain text"
  local r0 = ctx.first_row
  local r1 = r0 + math.max(#ctx.selection, 1) - 1
  out[#out + 1] = ("File: %s (%s), %d lines. The selection is %s."):format(
    ctx.path,
    ft,
    ctx.line_count,
    r0 == r1 and ("line %d"):format(r0) or ("lines %d-%d"):format(r0, r1)
  )
  if ctx.omitted_before > 0 or ctx.omitted_after > 0 then
    out[#out + 1] = "The file is large, so only the part around the selection is shown."
  end
  out[#out + 1] = ""
  if ctx.omitted_before > 0 then
    out[#out + 1] = ("[lines 1-%d omitted]"):format(ctx.omitted_before)
  end
  if #ctx.before > 0 then
    out[#out + 1] = "<before>"
    vim.list_extend(out, ctx.before)
    out[#out + 1] = "</before>"
  end
  out[#out + 1] = "<selection>"
  vim.list_extend(out, ctx.selection)
  out[#out + 1] = "</selection>"
  if #ctx.after > 0 then
    out[#out + 1] = "<after>"
    vim.list_extend(out, ctx.after)
    out[#out + 1] = "</after>"
  end
  if ctx.omitted_after > 0 then
    out[#out + 1] = ("[lines %d-%d omitted]"):format(ctx.line_count - ctx.omitted_after + 1, ctx.line_count)
  end
  if #ctx.diagnostics > 0 then
    out[#out + 1] = ""
    out[#out + 1] = "Diagnostics in the selection:"
    vim.list_extend(out, ctx.diagnostics)
  end
  out[#out + 1] = ""
  out[#out + 1] = "Instruction: " .. instruction
  return table.concat(out, "\n")
end

---@param ctx leader_k.Context
---@param turns leader_k.Turn[] The last turn is the one being requested.
---@return { role: string, content: string }[]
function M.messages(ctx, turns)
  local msgs = {
    { role = "system", content = M.system },
    { role = "user", content = first_message(ctx, turns[1].instruction) },
  }
  for i = 2, #turns do
    local prev = turns[i - 1].proposal or {}
    msgs[#msgs + 1] = { role = "assistant", content = "<code>\n" .. table.concat(prev, "\n") .. "\n</code>" }
    msgs[#msgs + 1] = {
      role = "user",
      content = "Revise your replacement for the same selection. Reply with the full new region in <code></code> again.\n\nInstruction: "
        .. turns[i].instruction,
    }
  end
  return msgs
end

---@class leader_k.Extract
---@field kind "pending"|"code"|"error"
---@field text string
---@field complete boolean

local CLOSE = "</code>"

---Reads the model output streamed so far.
---@param raw string
---@param final boolean
---@return leader_k.Extract
function M.extract(raw, final)
  raw = raw:gsub("\r\n", "\n")
  local cs = raw:find("<code>", 1, true)
  local es = raw:find("<error>", 1, true)
  if es and (not cs or es < cs) then
    local ee = raw:find("</error>", es, true)
    return { kind = "error", text = vim.trim(raw:sub(es + 7, ee and ee - 1 or -1)), complete = ee ~= nil }
  end
  if not cs then
    if not final then
      return { kind = "pending", text = "", complete = false }
    end
    -- The model ignored the format. Use a fenced block if there is one,
    -- otherwise the whole reply.
    -- Trim blank lines only; the first line's indentation matters.
    local fenced = raw:match("```[%w_+.#-]*\n(.-)\n?```")
    local text = (fenced or raw):gsub("^%s*\n", ""):gsub("%s+$", "")
    return { kind = "code", text = text, complete = true }
  end
  local body = raw:sub(cs + #"<code>")
  -- The code itself can contain </code> (HTML, Markdown), so only the last
  -- closing tag ends the block. While streaming, that is one with nothing
  -- but whitespace after it so far.
  local ce
  if final then
    local at = body:find(CLOSE, 1, true)
    while at do
      ce = at
      at = body:find(CLOSE, at + 1, true)
    end
  else
    ce = body:find(CLOSE .. "%s*$")
  end
  if ce then
    body = body:sub(1, ce - 1)
  elseif not final then
    -- Hold back a partial closing tag so it never flashes on screen.
    for k = #CLOSE - 1, 1, -1 do
      if body:sub(-k) == CLOSE:sub(1, k) then
        body = body:sub(1, -k - 1)
        break
      end
    end
  end
  body = body:gsub("^\n", "")
  -- Some models wrap the block content in a fence anyway.
  local inner = body:match("^```[%w_+.#-]*\n(.-)\n?```%s*$")
  if inner then
    body = inner
  elseif not ce and body:match("^```[%w_+.#-]*\n") then
    body = body:gsub("^```[%w_+.#-]*\n", "")
  end
  return { kind = "code", text = body, complete = ce ~= nil }
end

---@param line string
local function indent_of(line)
  return line:match("^[ \t]*")
end

---@param lines string[]
---@return string|nil indent The shortest indent among non-blank lines.
local function base_indent(lines)
  local best
  for _, l in ipairs(lines) do
    if l:find("%S") then
      local ind = indent_of(l)
      if not best or vim.fn.strdisplaywidth(ind) < vim.fn.strdisplaywidth(best) then
        best = ind
      end
    end
  end
  return best
end

---@param a string[]
---@param b string[]
---@param ai integer
---@param bi integer
---@param n integer
local function same(a, b, ai, bi, n)
  for k = 0, n - 1 do
    if a[ai + k] ~= b[bi + k] then
      return false
    end
  end
  return true
end

---@param lines string[]
---@param from integer
---@param n integer
local function has_text(lines, from, n)
  for k = from, from + n - 1 do
    if lines[k] and lines[k]:find("%S") then
      return true
    end
  end
  return false
end

---Turns extracted text into replacement lines.
---@param text string
---@param ctx leader_k.Context
---@param final boolean Apply the cleanups that need the whole reply.
---@return string[]
function M.lines(text, ctx, final)
  if final then
    text = text:gsub("\n$", "")
  end
  local lines = vim.split(text, "\n", { plain = true })
  if #lines == 1 and lines[1] == "" then
    return {}
  end

  -- Models often drop the base indentation of an indented selection.
  local want, got = base_indent(ctx.selection), base_indent(lines)
  if want and want ~= "" and got == "" then
    for i, l in ipairs(lines) do
      if l:find("%S") then
        lines[i] = want .. l
      end
    end
  end

  if not final then
    return lines
  end

  local sel = ctx.selection
  -- Drop lines the model echoed from the surrounding context.
  local before, after = ctx.before, ctx.after
  for n = math.min(#lines - 1, #before, 20), 1, -1 do
    if same(lines, before, 1, #before - n + 1, n) and has_text(lines, 1, n) and not same(lines, sel, 1, 1, n) then
      lines = vim.list_slice(lines, n + 1)
      break
    end
  end
  for n = math.min(#lines - 1, #after, 20), 1, -1 do
    local from = #lines - n + 1
    if same(lines, after, from, 1, n) and has_text(lines, from, n) and not same(lines, sel, from, #sel - n + 1, n) then
      lines = vim.list_slice(lines, 1, #lines - n)
      break
    end
  end

  -- Keep leading and trailing blank lines only when the selection had them.
  while #lines > 0 and lines[1]:find("^%s*$") and not (sel[1] or ""):find("^%s*$") do
    table.remove(lines, 1)
  end
  while #lines > 0 and lines[#lines]:find("^%s*$") and not (sel[#sel] or ""):find("^%s*$") do
    table.remove(lines)
  end
  return lines
end

return M
