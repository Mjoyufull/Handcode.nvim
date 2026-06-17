# Handcode.nvim

Intercept AI-generated code edits (or any git diff) and load them as "ghost text" directly in your buffer. Type over the grayed-out suggestions to handcode them into reality — no strict matching required.

## Features

- **Ghost rendering** — AI additions appear as gray highlighted text; deletions shown in red with `[DELETE]` markers
- **Loose type-over matching** — Type matching characters to solidify them instantly; type different characters to accept your edit and clear the ghost highlight
- **Auto-complete at any granularity** — Line, hunk, visual range, or entire file
- **Floating HUD** — Top-right status window showing active files and remaining changes
- **Zero-config defaults** — Works out of the box with sensible keymaps

## Quick Start

```lua
-- lazy.nvim
{
  "Mjoyufull/Handcode.nvim",
  config = function()
    require("handcode").setup()
  end,
}
```

Then in a git repo with unstaged changes:

```vim
:Handcode start
```

## Default Keymaps (Insert/Normal mode)

| Key | Action |
|-----|--------|
| `<Tab>` | Accept/complete current ghost line |
| `<leader>hc` | Complete current hunk |
| `<leader>hf` | Complete entire file |
| `:HandcodeCompleteRange` | Complete visually selected range |

## Commands

| Command | Description |
|---------|-------------|
| `:Handcode start` | Start session on current buffer |
| `:Handcode stop` | Stop session (keeps your edits) |
| `:Handcode stop restore` | Stop and restore original AI suggestions |
| `:Handcode toggle` | Toggle session |
| `:Handcode complete_line` | Accept current line |
| `:Handcode complete_hunk` | Accept current hunk |
| `:Handcode complete_file` | Accept entire file |
| `:HandcodeCompleteRange` | Accept range (visual mode) |

## Requirements

- Neovim ≥ 0.10
- Git repository (uses `git diff -U0`)

## License

GNU General Public License v3.0 or later