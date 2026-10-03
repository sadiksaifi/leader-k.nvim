-- Builds the request messages and turns streamed model output into lines.

local M = {}

---@alias leader_k.Mode "auto"|"edit"|"ask"

-- One system prompt per mode. Each names the reply tags the mode accepts.
M.system = {
  edit = [[
You edit code in Neovim. The user selected a region of a file and asked for a change to it.

Reply with the complete new text for the selected region inside one <code></code> block, and nothing else.
- The block replaces the selection exactly. Include every line of the new region, unchanged lines too. Never elide code or write placeholders.
- Do not repeat code from <before> or <after>.
- Keep the file's indentation style (tabs or spaces) and the selection's base indentation.
- No markdown fences, no commentary, no text outside the block.
- If the instruction cannot be done by rewriting this selection, reply with <error>one short sentence</error> instead.
]],
  ask = [[
You answer questions about code in Neovim. The user selected a region of a file and asked about it.

Reply inside one <answer></answer> block, in Markdown, and nothing else.
- Lead with the answer. Keep it short: it is shown in a small window next to the code.
- Refer to code by its line number in the file.
- Put code in fenced blocks with a language tag.
- Do not repeat the whole selection.
]],
}

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
---@field proposal string[]|nil The proposed edit, once the reply was code.
---@field answer string|nil The Markdown answer, once the reply was an answer.

-- How the user's text is introduced in each mode.
local LABEL = { edit = "Instruction", ask = "Question" }

---@param ctx leader_k.Context
---@param instruction string
---@param mode leader_k.Mode
local function first_message(ctx, instruction, mode)
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
  out[#out + 1] = LABEL[mode] .. ": " .. instruction
  return table.concat(out, "\n")
end

---@param turn leader_k.Turn
local function reply_of(turn)
  if turn.answer then
    return "<answer>\n" .. turn.answer .. "\n</answer>"
  end
  return "<code>\n" .. table.concat(turn.proposal or {}, "\n") .. "\n</code>"
end

---@param turn leader_k.Turn
---@param prev leader_k.Turn
---@param mode leader_k.Mode
local function follow_up(turn, prev, mode)
  local ask
  if mode == "ask" then
    ask = "Answer the follow-up about the same selection in <answer></answer> again."
  elseif prev.answer then
    ask = "Reply with the full new region for the same selection in <code></code>."
  else
    ask = "Revise your replacement for the same selection. Reply with the full new region in <code></code> again."
  end
  return ask .. "\n\n" .. LABEL[mode] .. ": " .. turn.instruction
end

---@param ctx leader_k.Context
---@param turns leader_k.Turn[] The last turn is the one being requested.
---@param mode leader_k.Mode
---@return { role: string, content: string }[]
function M.messages(ctx, turns, mode)
  local msgs = {
    { role = "system", content = M.system[mode] },
    { role = "user", content = first_message(ctx, turns[1].instruction, mode) },
  }
  for i = 2, #turns do
    msgs[#msgs + 1] = { role = "assistant", content = reply_of(turns[i - 1]) }
    msgs[#msgs + 1] = { role = "user", content = follow_up(turns[i], turns[i - 1], mode) }
  end
  return msgs
end

---@class leader_k.Extract
---@field kind "pending"|"code"|"answer"|"error"
---@field text string
---@field complete boolean

---Returns the block body up to its closing tag, and whether the tag was seen.
---@param body string Text after the opening tag.
---@param close string
---@param final boolean
local function block(body, close, final)
  -- The block itself can contain its closing tag (HTML, Markdown), so only
  -- the last one ends it. While streaming, that is one with nothing but
  -- whitespace after it so far.
  local ce
  if final then
    local at = body:find(close, 1, true)
    while at do
      ce = at
      at = body:find(close, at + 1, true)
    end
  else
    ce = body:find(close .. "%s*$")
  end
  if ce then
    body = body:sub(1, ce - 1)
  elseif not final then
    -- Hold back a partial closing tag so it never flashes on screen.
    for k = #close - 1, 1, -1 do
      if body:sub(-k) == close:sub(1, k) then
        body = body:sub(1, -k - 1)
        break
      end
    end
  end
  return body:gsub("^\n", ""), ce ~= nil
end

---Reads the model output streamed so far. The first tag in the reply decides
---its kind. A finished reply without tags is read as `untagged`.
---@param raw string
---@param final boolean
---@param untagged "code"|"answer"|nil Default "code".
---@return leader_k.Extract
function M.extract(raw, final, untagged)
  raw = raw:gsub("\r\n", "\n")
  local kind, at
  for _, k in ipairs({ "code", "answer", "error" }) do
    local p = raw:find("<" .. k .. ">", 1, true)
    if p and (not at or p < at) then
      kind, at = k, p
    end
  end
  if kind == "error" then
    local ee = raw:find("</error>", at, true)
    return { kind = "error", text = vim.trim(raw:sub(at + 7, ee and ee - 1 or -1)), complete = ee ~= nil }
  end
  if not kind then
    if not final then
      return { kind = "pending", text = "", complete = false }
    end
    if untagged == "answer" then
      return { kind = "answer", text = vim.trim(raw), complete = true }
    end
    -- The model ignored the format. Use a fenced block if there is one,
    -- otherwise the whole reply.
    -- Trim blank lines only; the first line's indentation matters.
    local fenced = raw:match("```[%w_+.#-]*\n(.-)\n?```")
    local text = (fenced or raw):gsub("^%s*\n", ""):gsub("%s+$", "")
    return { kind = "code", text = text, complete = true }
  end
  local body, complete = block(raw:sub(at + #kind + 2), "</" .. kind .. ">", final)
  if kind == "answer" then
    if final then
      body = vim.trim(body)
    end
    return { kind = "answer", text = body, complete = complete }
  end
  -- Some models wrap the block content in a fence anyway.
  local inner = body:match("^```[%w_+.#-]*\n(.-)\n?```%s*$")
  if inner then
    body = inner
  elseif not complete and body:match("^```[%w_+.#-]*\n") then
    body = body:gsub("^```[%w_+.#-]*\n", "")
  end
  return { kind = "code", text = body, complete = complete }
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
