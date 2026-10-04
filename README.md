# leader-k.nvim

Cursor-style inline edits and answers for Neovim.

![LeaderK Screenshot](https://github.com/user-attachments/assets/6ee69613-1d97-4cd9-aa9f-a45fa22579c4)

## Requirements

- [Neovim](https://neovim.io/) 0.12 or newer, built with LuaJIT.
- [libcurl](https://curl.se/libcurl/) shared library.

## Install

```lua
{
  "sadiksaifi/leader-k.nvim",
  cmd = { "LeaderK", "LeaderKEdit", "LeaderKAsk" },
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

Select code, or put the cursor on a line, and press `<leader>k`. A panel
opens on the right with the selection attached and an input for your
request. Until you send it, the panel shows the selected code and example
requests. The model decides how to reply:

- A change, such as "use ipairs", comes back as a proposed edit shown inline
  as a diff. Nothing changes until you accept it.
- A question, such as "why multiply here?", comes back as a Markdown answer in
  the panel. The buffer is never changed.

The panel holds the conversation: the transcript, the status, and the
input. Follow-ups continue it and can switch between the two: ask "why is
this slow?", then "fix it". A proposed edit is reviewed in the code.
Accepting or rejecting it, or pressing `q` in the panel, ends the
conversation. Asking again on lines you just accepted, within two minutes,
continues it.

To bring other code into the conversation, select it in any buffer and
press `<leader>k`. The input shows it as attached, for example
"Attached: lines 3-9 of sample.lua", and it goes with your next message.
From then on, edits replace that selection. If every line of the selection
is replaced, for example by a formatter that rewrites the file, select the
code again or undo the change before you send.

A characterwise or blockwise selection sends the exact characters along with
the lines they are on, so you can ask about a single expression.

| Context | Key | Action |
| --- | --- | --- |
| Normal / Visual | `<leader>k` | Start on the current line / selection |
| Conversation, Visual | `<leader>k` | Attach the selection to the next message |
| Conversation, Normal | `<leader>k` | Move into the panel input |
| Panel input | `<CR>` / `<Up>` / `<Down>` | Send / recall requests |
| Panel input | `<Esc>` | Back to the code; on an empty new request, cancel |
| Panel | `q` | End the conversation |
| Review | `<CR>` | Accept proposal |
| Review / answer / request | `<BS>` | Reject proposal / close answer / stop request |
| Request | `<C-c>` | Stop request |

To always get one kind of reply, map the mode explicitly:

```lua
{ "<leader>e", function() require("leader-k").open({ mode = "edit" }) end, mode = { "n", "x" } },
{ "<leader>a", function() require("leader-k").open({ mode = "ask" }) end, mode = { "n", "x" } },
```

`:LeaderK` (model decides), `:LeaderKEdit`, and `:LeaderKAsk` accept a range
and an optional request. During a conversation, they attach the range. See
`:help leader-k` for more keys. Run `:checkhealth leader-k` to inspect your
setup.
