# leader-k.nvim

Cursor-style inline edits for Neovim.

![LeaderK Screenshot](https://github.com/user-attachments/assets/6ee69613-1d97-4cd9-aa9f-a45fa22579c4)

## Requirements

- [Neovim](https://neovim.io/) 0.12 or newer, built with LuaJIT.
- [libcurl](https://curl.se/libcurl/) shared library.

## Install

```lua
{
  "sadiksaifi/leader-k.nvim",
  cmd = "LeaderK",
  keys = {
    { "<leader>k", function() require("leader-k").open() end, mode = { "n", "x" } },
  },
  ---@type leader_k.Config
  opts = {
    base_url = "https://openrouter.ai/api/v1", -- Required API root; /chat/completions is appended.
    model = "openai/gpt-6-luna", -- Required model ID.
    api_key = { env = "OPENROUTER_API_KEY" }, -- Optional; literal string or omit for keyless endpoints.
    params = { -- Optional; omit to use the model's default.
      -- "none" (off), "low", "medium", "high", "xhigh", "max"
      reasoning = { effort = "none" },
    },
  },
}
```

Use any OpenAI-compatible streaming Chat Completions endpoint, including
[OpenRouter](https://openrouter.ai/docs/quickstart),
[OpenAI](https://developers.openai.com/api/reference/resources/chat),
[Anthropic](https://platform.claude.com/docs/en/cli-sdks-libraries/libraries/openai-sdk),
[Groq](https://console.groq.com/docs/openai),
[Ollama](https://docs.ollama.com/api/openai-compatibility), and
[llama.cpp](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md).
<details>
<summary>OpenAI example</summary>

Replace `opts` with:

```lua
---@type leader_k.Config
opts = {
  base_url = "https://api.openai.com/v1",
  model = "gpt-6-luna",
  api_key = { env = "OPENAI_API_KEY" },
},
```
</details>

<details>
<summary>Anthropic example</summary>

Replace `opts` with:

```lua
---@type leader_k.Config
opts = {
  base_url = "https://api.anthropic.com/v1",
  model = "claude-haiku-4-5",
  api_key = { env = "ANTHROPIC_API_KEY" },
},
```
</details>

<details>
<summary>Ollama example (local)</summary>

Run `ollama pull qwen3.5:4b`, then replace `opts` with:

```lua
---@type leader_k.Config
opts = {
  base_url = "http://localhost:11434/v1",
  model = "qwen3.5:4b",
},
```
</details>

## Use

| Context | Key | Action |
| --- | --- | --- |
| Normal / Visual | `<leader>k` | Edit current line / selected lines |
| Prompt | `<CR>` | Send instruction |
| Prompt | `<Up>` / `<Down>` | Recall instructions |
| Prompt | `<C-c>` | Cancel |
| Review | `<CR>` | Accept proposal |
| Review / request | `<BS>` | Reject proposal / stop request |
| Review | `<leader>k` | Refine proposal |
| Request | `<C-c>` | Stop request |

`:LeaderK` accepts a range and optional instruction. See `:help leader-k` for
more keys. Run `:checkhealth leader-k` to inspect your setup.
