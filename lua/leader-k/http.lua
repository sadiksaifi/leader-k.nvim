-- In-process HTTPS through the system libcurl library, loaded with LuaJIT FFI.
--
-- No process is spawned. Transfers run on libcurl's multi interface, which a
-- libuv timer drives from the main loop, so the editor never blocks. Response
-- bytes reach Lua through a single write callback that stays anchored for the
-- lifetime of the module.

local ffi = require("ffi")

local M = {}

ffi.cdef([[
typedef void CURL;
typedef void CURLM;
typedef int CURLcode;
typedef int CURLMcode;
struct curl_slist { char *data; struct curl_slist *next; };
typedef struct {
  int msg;
  CURL *easy_handle;
  union { void *whatever; CURLcode result; } data;
} CURLMsg;
typedef struct {
  int age;
  const char *version;
  unsigned int version_num;
  const char *host;
  int features;
  const char *ssl_version;
  long ssl_version_num;
} leader_k_curl_version_info;
typedef size_t (*leader_k_write_cb)(char *ptr, size_t size, size_t nmemb, void *userdata);

CURLcode curl_global_init(long flags);
leader_k_curl_version_info *curl_version_info(int age);
const char *curl_easy_strerror(CURLcode code);
const char *curl_multi_strerror(CURLMcode code);
CURL *curl_easy_init(void);
CURLcode curl_easy_setopt(CURL *handle, int option, ...);
CURLcode curl_easy_getinfo(CURL *handle, int info, ...);
void curl_easy_cleanup(CURL *handle);
struct curl_slist *curl_slist_append(struct curl_slist *list, const char *string);
void curl_slist_free_all(struct curl_slist *list);
CURLM *curl_multi_init(void);
CURLMcode curl_multi_add_handle(CURLM *multi, CURL *easy);
CURLMcode curl_multi_remove_handle(CURLM *multi, CURL *easy);
CURLMcode curl_multi_perform(CURLM *multi, int *running_handles);
CURLMsg *curl_multi_info_read(CURLM *multi, int *msgs_in_queue);
]])

-- Option and info ids from curl/curl.h. They are part of libcurl's stable ABI.
local OPT = {
  WRITEDATA = 10001,
  URL = 10002,
  ERRORBUFFER = 10010,
  WRITEFUNCTION = 20011,
  USERAGENT = 10018,
  HTTPHEADER = 10023,
  LOW_SPEED_LIMIT = 19,
  LOW_SPEED_TIME = 20,
  POSTFIELDSIZE = 60,
  NOSIGNAL = 99,
  TIMEOUT_MS = 155,
  CONNECTTIMEOUT_MS = 156,
  COPYPOSTFIELDS = 10165,
  PROTOCOLS_STR = 10318,
}
local INFO_RESPONSE_CODE = 0x200000 + 2
local CURLMSG_DONE = 1
local CURLE_OK = 0
local CURL_GLOBAL_DEFAULT = 3
local CURL_ERROR_SIZE = 256
local TICK_MS = 15

local candidates = {
  macos = { "/usr/lib/libcurl.4.dylib", "libcurl.4.dylib", "libcurl.dylib" },
  linux = { "libcurl.so.4", "libcurl-gnutls.so.4", "libcurl.so" },
  windows = { "libcurl-x64.dll", "libcurl.dll" },
}

---@type ffi.namespace*|nil
local lib
---@type string|nil
local load_error
---@type string|nil
local lib_path

---@param path string|nil Explicit library path from the config, if any.
---@return ffi.namespace*|nil lib, string|nil err
function M.load(path)
  if lib then
    return lib
  end
  if load_error and not path then
    return nil, load_error
  end
  local list = {}
  if path then
    list = { path }
  else
    local sys = vim.uv.os_uname().sysname
    list = sys == "Darwin" and candidates.macos or sys:match("Windows") and candidates.windows or candidates.linux
  end
  local errors = {}
  for _, name in ipairs(list) do
    local ok, loaded = pcall(ffi.load, name)
    if ok then
      if loaded.curl_global_init(CURL_GLOBAL_DEFAULT) ~= CURLE_OK then
        load_error = "curl_global_init failed for " .. name
        return nil, load_error
      end
      lib, lib_path = loaded, name
      return lib
    end
    errors[#errors + 1] = name
  end
  load_error = "could not load the libcurl shared library (tried " .. table.concat(errors, ", ") .. ")"
  return nil, load_error
end

---@return { path: string, version: string, tls: string, async_dns: boolean }|nil
function M.info()
  if not lib then
    return nil
  end
  local v = lib.curl_version_info(10)
  return {
    path = lib_path,
    version = ffi.string(v.version),
    tls = v.ssl_version ~= nil and ffi.string(v.ssl_version) or "none",
    async_dns = bit.band(v.features, 0x80) ~= 0,
  }
end

---@class leader_k.http.Transfer
---@field id integer
---@field easy ffi.cdata*
---@field headers ffi.cdata*
---@field errbuf ffi.cdata*
---@field status integer|nil
---@field on_status fun(status: integer)|nil
---@field on_data fun(chunk: string)
---@field on_done fun(err: string|nil, status: integer|nil)
---@field closed boolean

---@type table<integer, leader_k.http.Transfer>
local transfers = {}
local active = 0
local next_id = 0
local multi ---@type ffi.cdata*|nil
local timer ---@type uv.uv_timer_t|nil
local running = ffi.new("int[1]")
local queued = ffi.new("int[1]")
local status_out = ffi.new("long[1]")

-- The one C-to-Lua callback. LuaJIT callback slots are a scarce resource, so
-- transfers share it and are told apart by the id stored in WRITEDATA.
local write_cb = ffi.cast("leader_k_write_cb", function(ptr, size, nmemb, userdata)
  local n = size * nmemb
  local t = transfers[tonumber(ffi.cast("intptr_t", userdata))]
  if not t or t.closed then
    return 0 -- A short write makes libcurl abort the transfer.
  end
  if not t.status then
    lib.curl_easy_getinfo(t.easy, INFO_RESPONSE_CODE, status_out)
    t.status = tonumber(status_out[0])
    if t.on_status then
      pcall(t.on_status, t.status)
    end
  end
  local ok = pcall(t.on_data, ffi.string(ptr, n))
  return ok and n or 0
end)

---@param t leader_k.http.Transfer
local function release(t)
  if t.easy == nil then
    return
  end
  lib.curl_multi_remove_handle(multi, t.easy)
  lib.curl_easy_cleanup(t.easy)
  lib.curl_slist_free_all(t.headers)
  t.easy, t.headers = nil, nil
  transfers[t.id] = nil
  active = active - 1
end

local tick

local function stop_timer_if_idle()
  if active == 0 and timer then
    timer:stop()
  end
end

-- Drives every active transfer. Kept out of the JIT because libcurl calls back
-- into Lua from inside curl_multi_perform, which LuaJIT forbids on traces.
tick = function()
  local rc = lib.curl_multi_perform(multi, running)
  local done = {}
  while true do
    local msg = lib.curl_multi_info_read(multi, queued)
    if msg == nil then
      break
    end
    if msg.msg == CURLMSG_DONE then
      for _, t in pairs(transfers) do
        if t.easy == msg.easy_handle then
          done[#done + 1] = { t = t, code = msg.data.result }
          break
        end
      end
    end
  end
  for _, item in ipairs(done) do
    local t, code = item.t, item.code
    local err
    if not t.closed and code ~= CURLE_OK then
      local detail = ffi.string(t.errbuf)
      err = detail ~= "" and detail or ffi.string(lib.curl_easy_strerror(code))
    end
    if not t.status then
      lib.curl_easy_getinfo(t.easy, INFO_RESPONSE_CODE, status_out)
      t.status = tonumber(status_out[0])
    end
    release(t)
    if not t.closed then
      t.closed = true
      pcall(t.on_done, err, t.status)
    end
  end
  if rc ~= 0 then
    local err = ffi.string(lib.curl_multi_strerror(rc))
    for _, t in pairs(transfers) do
      release(t)
      if not t.closed then
        t.closed = true
        pcall(t.on_done, err, t.status)
      end
    end
  end
  stop_timer_if_idle()
end
jit.off(tick)

---@param easy ffi.cdata*
---@param opt integer
---@param value any
local function setopt(easy, opt, value)
  local rc = lib.curl_easy_setopt(easy, opt, value)
  if rc ~= CURLE_OK then
    error(("curl_easy_setopt(%d) failed: %s"):format(opt, ffi.string(lib.curl_easy_strerror(rc))), 0)
  end
end

---@class leader_k.http.Request
---@field url string
---@field headers string[]
---@field body string
---@field on_status fun(status: integer)|nil Called once, when the first body bytes arrive.
---@field on_data fun(chunk: string) Called on the main loop with raw body bytes.
---@field on_done fun(err: string|nil, status: integer|nil) Called exactly once unless cancelled.
---@field timeout_ms integer|nil

---Starts a POST request. Returns a cancel function, or nil and an error.
---@param req leader_k.http.Request
---@return (fun())|nil cancel, string|nil err
function M.post(req)
  if not lib then
    local _, err = M.load()
    if not lib then
      return nil, err
    end
  end
  if not multi then
    multi = lib.curl_multi_init()
    if multi == nil then
      return nil, "curl_multi_init failed"
    end
    ffi.gc(multi, nil)
  end

  local easy = lib.curl_easy_init()
  if easy == nil then
    return nil, "curl_easy_init failed"
  end
  next_id = next_id + 1
  local t = {
    id = next_id,
    easy = easy,
    headers = nil,
    errbuf = ffi.new("char[?]", CURL_ERROR_SIZE),
    on_status = req.on_status,
    on_data = req.on_data,
    on_done = req.on_done,
    closed = false,
  }

  local ok, err = pcall(function()
    local list = nil
    for _, h in ipairs(req.headers) do
      local nl = lib.curl_slist_append(list, h)
      if nl == nil then
        lib.curl_slist_free_all(list)
        error("curl_slist_append failed", 0)
      end
      list = nl
    end
    t.headers = list
    setopt(easy, OPT.URL, req.url)
    -- Only HTTP(S). Redirects stay disabled (the libcurl default), so the
    -- Authorization header can never be forwarded to another host.
    pcall(setopt, easy, OPT.PROTOCOLS_STR, "https,http")
    setopt(easy, OPT.HTTPHEADER, list)
    setopt(easy, OPT.POSTFIELDSIZE, ffi.cast("long", #req.body))
    setopt(easy, OPT.COPYPOSTFIELDS, req.body)
    setopt(easy, OPT.WRITEFUNCTION, write_cb)
    setopt(easy, OPT.WRITEDATA, ffi.cast("void *", ffi.cast("intptr_t", t.id)))
    setopt(easy, OPT.ERRORBUFFER, t.errbuf)
    setopt(easy, OPT.USERAGENT, "leader-k.nvim")
    setopt(easy, OPT.NOSIGNAL, ffi.cast("long", 1))
    setopt(easy, OPT.CONNECTTIMEOUT_MS, ffi.cast("long", 15000))
    setopt(easy, OPT.TIMEOUT_MS, ffi.cast("long", req.timeout_ms or 0))
    -- Abort when the server sends nothing at all for 90 seconds.
    setopt(easy, OPT.LOW_SPEED_LIMIT, ffi.cast("long", 1))
    setopt(easy, OPT.LOW_SPEED_TIME, ffi.cast("long", 90))
  end)
  if not ok then
    lib.curl_easy_cleanup(easy)
    if t.headers ~= nil then
      lib.curl_slist_free_all(t.headers)
    end
    return nil, err
  end

  local rc = lib.curl_multi_add_handle(multi, easy)
  if rc ~= 0 then
    lib.curl_easy_cleanup(easy)
    lib.curl_slist_free_all(t.headers)
    return nil, ffi.string(lib.curl_multi_strerror(rc))
  end
  transfers[t.id] = t
  active = active + 1

  if not timer then
    timer = assert(vim.uv.new_timer())
  end
  if not timer:is_active() then
    timer:start(0, TICK_MS, vim.schedule_wrap(tick))
  end

  return function()
    if t.closed then
      return
    end
    t.closed = true
    -- Aborting the connection lets the server stop generating.
    release(t)
    stop_timer_if_idle()
  end
end

---@return integer
function M.active_count()
  return active
end

return M
