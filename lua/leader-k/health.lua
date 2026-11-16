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

  h.start("leader-k: project tools")
  if vim.fn.executable("git") == 1 then
    h.ok("git: list_files uses git ls-files, and ignored files stay off limits")
  else
    h.warn("git not found: list_files walks directories, and .gitignore is not applied")
  end
  if vim.fn.executable("rg") == 1 then
    h.ok("rg: search uses ripgrep")
  elseif vim.fn.executable("git") == 1 then
    h.info("rg not found: search uses git grep, which works only inside git repositories")
  else
    h.warn("neither rg nor git found: the search tool is unavailable")
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
