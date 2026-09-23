local M = {}

function M.check()
  local h = vim.health
  local config = require("leader-k.config")
  local http = require("leader-k.http")
  local o = config.options

  h.start("leader-k: transport")
  if not pcall(require, "ffi") then
    h.error("LuaJIT FFI is unavailable; this Neovim build cannot load libcurl in-process")
    return
  end
  local lib, err = http.load(o.libcurl)
  if not lib then
    h.error(err or "libcurl failed to load", {
      "Install the libcurl shared library (libcurl4 on Debian/Ubuntu, curl on Arch/Fedora)",
      "or set `libcurl` in setup() to its full path",
    })
  else
    local info = assert(http.info())
    h.ok(("libcurl %s from %s, loaded in-process (no executable)"):format(info.version, info.path))
    h.info("TLS: " .. info.tls)
    if not info.async_dns then
      h.warn("libcurl has no threaded resolver: DNS lookups briefly block the editor")
    end
  end

  h.start("leader-k: endpoint")
  h.info("OpenAI-compatible Chat Completions streaming")
  local ep, ep_err = config.endpoint()
  if not ep then
    h.error(ep_err or "invalid configuration")
    return
  end
  h.ok("url: " .. ep.url)
  h.ok("model: " .. ep.model)
  if ep.key then
    local source = type(o.api_key) == "table" and ("$" .. o.api_key.env) or "a literal key"
    h.ok(("API key: present (from %s)"):format(source))
  else
    h.info("API key: not configured (no Authorization header)")
  end
  if next(ep.params) then
    h.info("extra params: " .. vim.inspect(ep.params, { newline = " ", indent = "" }))
  end
end

return M
