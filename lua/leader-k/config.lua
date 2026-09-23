local M = {}

---@class leader_k.Keys
---@field accept string
---@field reject string
---@field cancel string
---@field refine string

---@class leader_k.EnvKey
---@field env string Name of an environment variable inherited by Neovim.

---@class leader_k.Config
---@field base_url string API root; /chat/completions is appended.
---@field model string Chat Completions model ID.
---@field api_key? string|leader_k.EnvKey Literal key or an explicit environment variable reference.
---@field params? table Extra request body fields, merged over the defaults.
---@field context_bytes? integer Most surrounding code sent on each side, in bytes.
---@field timeout_ms? integer
---@field libcurl? string Explicit path to the libcurl shared library.
---@field keys? leader_k.Keys

-- The endpoint and model have no defaults. Credentials are never inferred
-- from the machine, the model name, or the URL's host.
M.defaults = {
  params = {},
  context_bytes = 50000,
  timeout_ms = 180000,
  libcurl = nil,
  keys = {
    accept = "<CR>",
    reject = "<BS>",
    cancel = "<C-c>",
    refine = "<leader>k",
  },
}

---@type leader_k.Config
M.options = vim.deepcopy(M.defaults)

---@param opts leader_k.Config|nil
function M.setup(opts)
  if opts ~= nil and type(opts) ~= "table" then
    error("leader-k: setup() expects a configuration table", 2)
  end
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

---@class leader_k.Endpoint
---@field name string
---@field url string
---@field model string
---@field key? string
---@field params table

---Resolves the endpoint for one request. The key is read now and never stored.
---@return leader_k.Endpoint|nil endpoint, string|nil err
function M.endpoint()
  local o = M.options
  for field in pairs(o) do
    if M.defaults[field] == nil and field ~= "base_url" and field ~= "model" and field ~= "api_key" then
      return nil, ("unknown configuration option `%s`"):format(tostring(field))
    end
  end
  if type(o.params) ~= "table" then
    return nil, "`params` must be a table of request body fields"
  end
  if type(o.context_bytes) ~= "number" or o.context_bytes < 0 or o.context_bytes % 1 ~= 0 then
    return nil, "`context_bytes` must be a nonnegative integer"
  end
  if type(o.timeout_ms) ~= "number" or o.timeout_ms <= 0 or o.timeout_ms % 1 ~= 0 then
    return nil, "`timeout_ms` must be a positive integer"
  end
  if o.libcurl ~= nil and (type(o.libcurl) ~= "string" or o.libcurl == "") then
    return nil, "`libcurl` must be a nonempty path"
  end
  if type(o.keys) ~= "table" then
    return nil, "`keys` must be a table of mappings"
  end
  for _, action in ipairs({ "accept", "reject", "cancel", "refine" }) do
    if type(o.keys[action]) ~= "string" or o.keys[action] == "" then
      return nil, ("`keys.%s` must be a nonempty string"):format(action)
    end
  end
  local base = o.base_url
  if type(base) ~= "string" or base == "" then
    return nil, "set `base_url` to the API root, for example https://example.com/v1"
  end
  local scheme, authority = base:match("^(https?)://([^/?#]+)")
  if not scheme or base:find("[?#]") or authority:find("@", 1, true) or base:find("%s") then
    return nil, "`base_url` must be an HTTP(S) API root without credentials, query or fragment"
  end
  local host = authority:match("^(%b[])") or authority:match("^([^:]+)")
  local loopback = host == "localhost" or host == "127.0.0.1" or host == "[::1]"
  if scheme == "http" and not loopback then
    return nil, "`base_url` must use https:// (plain http is only allowed for localhost)"
  end
  base = base:gsub("/+$", "")
  if base:match("/chat/completions$") then
    return nil, "`base_url` must be the API root, not the full /chat/completions URL"
  end
  if type(o.model) ~= "string" or vim.trim(o.model) == "" then
    return nil, "set `model` to a nonempty model ID"
  end

  local key = o.api_key
  if type(key) == "table" then
    local env = key.env
    if type(env) ~= "string" or not env:match("^[%a_][%w_]*$") or vim.tbl_count(key) ~= 1 then
      return nil, "`api_key` must be a string or { env = 'VARIABLE_NAME' }"
    end
    key = vim.env[env]
    if type(key) ~= "string" or vim.trim(key) == "" then
      return nil, ("API key unavailable: $%s is missing or empty in Neovim's environment"):format(env)
    end
  end
  if key ~= nil then
    if type(key) ~= "string" or vim.trim(key) == "" then
      return nil, "`api_key` must be a nonempty string or { env = 'VARIABLE_NAME' }"
    end
    key = vim.trim(key)
    if key:find("[\r\n]") then
      return nil, "`api_key` must not contain a line break"
    end
  end

  return {
    name = host,
    url = base .. "/chat/completions",
    model = o.model,
    key = key,
    params = o.params or {},
  }
end

return M
