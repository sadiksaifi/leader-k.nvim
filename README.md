# leader-k.nvim

A chat sidebar for Neovim that reads your project and proposes edits.
You review each edit in the code, file by file, before it applies.

![LeaderK Screenshot](https://github.com/user-attachments/assets/6ee69613-1d97-4cd9-aa9f-a45fa22579c4)

## Requirements

- [Neovim](https://neovim.io/) 0.12 or newer, built with LuaJIT.
- [libcurl](https://curl.se/libcurl/) shared library.

## Install

```lua
{
  "sadiksaifi/leader-k.nvim",
  cmd = { "LeaderK", "LeaderKAdd", "LeaderKNew" },
  keys = {
    { "<leader>k", function() require("leader-k").open() end },
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
The model must support tool calls.

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

`<leader>k` in Normal mode opens the sidebar. Type a request and press
Enter. With nothing attached, the first message sends the current file.

To send other code, select it while the sidebar is open. A hint above the
selection names the attach key, `<leader>a`. Repeat this in any buffer to
collect several selections. `:LeaderKAdd [path]` attaches a whole file, and
`@path` in a message attaches that file. The attachments show above the
input until you send them.

The model reads, lists, and searches files under the project root, the
nearest directory with `.git`. It proposes edits to any of those files.
Nothing changes until you accept: the first changed file opens in the code
with the edit shown inline, and the cursor moves to the transcript. The
review keys work there, and the row under the input names them. Accepting
writes the edit into the buffer, unsaved; save it with `:w`. `u` undoes it.

The code buffer keeps its own keys during a review. The attach key exists
only while the sidebar is open; otherwise `<leader>a` keeps its usual
meaning, including your own mapping. Closing the sidebar pauses the review;
opening it again resumes it.

| Context | Key | Action |
| --- | --- | --- |
| Normal | `<leader>k` | Open the sidebar, or move into its input |
| Visual, sidebar open | `<leader>a` | Attach the selection |
| Input | `<CR>` | Send |
| Input | `<Up>` / `<Down>` | Recall messages |
| Input, empty | `<BS>` | Remove the newest attachment |
| Sidebar | `<C-c>` | Stop the reply |
| Transcript | `a` / `r` | Accept / reject the file under review |
| Transcript | `]f` / `[f` | Next / previous changed file |
| Transcript | `]c` / `[c` | Next / previous change in the file |
| Transcript | `<CR>` on a file | Review that file |
| Transcript | `A` / `R` | Accept / reject every pending file |
| Transcript | `<leader>k` / `i` | Move into the input |

The sidebar maps only keys that have no use in it otherwise. Esc, `q`,
and window commands keep their native meaning: move between the sidebar
and the code with `<C-w>`, and close the sidebar as you close any window,
such as with `<C-w>c` or `:q`.

`:LeaderK [request]` opens the sidebar and sends the request, with the range
attached when one is given. `:LeaderKNew` starts over. Closing the sidebar
keeps the conversation; `<leader>k` brings it back. See
`:help leader-k` for options. Run `:checkhealth leader-k` to inspect your
setup.

The `list_files` and `search` tools use `git` and `rg` when they are
installed.
