# Handcode.nvim — Usage Guide

## Installation

### lazy.nvim

```lua
{
  "Mjoyufull/Handcode.nvim",
  -- Optional: pin to a release
  -- version = "*",
  config = function()
    require("handcode").setup({
      -- Your overrides (see Configuration below)
    })
  end,
}
```

### vim.pack (Neovim ≥ 0.10)

```lua
vim.pack.add({
  {
    src = "https://github.com/Mjoyufull/Handcode.nvim",
    version = vim.version.range("*"),
  },
})

-- Call setup in your init.lua
require("handcode").setup()
```

### packer.nvim

```lua
use({
  "Mjoyufull/Handcode.nvim",
  config = function()
    require("handcode").setup()
  end,
})
```

### vim-plug

```vim
Plug 'Mjoyufull/Handcode.nvim'
```

```lua
-- In your init.lua
require("handcode").setup()
```

---

## Configuration

Call `require("handcode").setup()` with an optional table of overrides. All fields are optional.

```lua
require("handcode").setup({
  hl_groups = {
    ghost = "HandcodeGhost",   -- Highlight for ghost text (default: linked to "Comment")
    delete = "HandcodeDelete", -- Highlight for deletions (default: linked to "DiffDelete")
  },
  hud = {
    enabled = true,            -- Show the floating HUD
    position = "top_right",    -- "top_right" or "top_left"
    border = "rounded",        -- "rounded", "single", "double", "solid", "shadow"
    max_width = 30,            -- Maximum HUD width in columns
  },
  keymaps = {
    accept_line   = "<Tab>",        -- Accept current line (Insert mode)
    complete_hunk = "<leader>hc",   -- Complete current hunk (Normal mode)
    complete_file = "<leader>hf",   -- Complete entire file (Normal mode)
  },
})
```

Setting a keymap to `nil` or `false` disables it.

---

## Getting Started

### 1. Create or open a file in a git repo

```bash
git init myproject && cd myproject
echo "print('hello')" > main.py
git add main.py && git commit -m "init"
```

### 2. Simulate an AI change (or make any edit)

Open `main.py` in Neovim and make changes:

```python
import sys

def greet(name):
    print(f"hello {name}")

def main():
    greet("world")

if __name__ == "__main__":
    main()
```

Save the file — these are now unstaged changes.

### 3. Start Handcode

```vim
:Handcode start
```

You'll see:
- New lines (`import sys`, function definitions, etc.) highlighted in gray — these are **ghost additions**
- Deleted lines (`print('hello')`) highlighted in red with a `[DELETE]` marker — these are **ghost deletions**
- A HUD window in the top-right corner showing the file and remaining counts

### 4. Type over ghost text

Place your cursor at the start of a gray line and start typing:

- **Matching characters**: The gray highlight is removed character by character as you type the same text
- **Different characters**: Type anything different and the rest of the line solidifies immediately — Handcode accepts your edit
- **Delete a ghost deletion**: The red `[DELETE]` line disappears and Handcode marks it as resolved

### 5. Use auto-complete for the rest

| Key | Action |
|-----|--------|
| `<Tab>` (Insert mode) | Solidify the rest of the current ghost line |
| `<leader>hc` (Normal) | Complete the entire hunk under the cursor |
| `<leader>hf` (Normal) | Complete all ghost hunks in the file |
| `:HandcodeCompleteRange` (Visual) | Complete selected range of lines |

### 6. Stop the session

```vim
:Handcode stop
```

To restore the buffer to the original AI suggestions (undo your handcoding):

```vim
:Handcode stop restore
```

---

## Commands Reference

| Command | Description |
|---------|-------------|
| `:Handcode` | Toggle (default subcommand) |
| `:Handcode start` | Start a Handcode session on the current buffer |
| `:Handcode stop` | Stop the session, keep current edits |
| `:Handcode stop restore` | Stop and restore buffer to original AI lines |
| `:Handcode toggle` | Toggle (same as `:Handcode`) |
| `:Handcode complete_line` | Accept/complete the active ghost line at the cursor |
| `:Handcode complete_hunk` | Accept/complete the ghost hunk under the cursor |
| `:Handcode complete_file` | Accept/complete all ghost hunks in the buffer |
| `:HandcodeCompleteRange` | (Range command) Complete selected lines only |

---

## How It Works

1. **Diff detection**: `git diff -U0 --relative <file>` parses additions and deletions for the current buffer
2. **Ghost rendering**: Additions stay in the buffer with a `HandcodeGhost` highlight extmark; deletions are re-inserted with `HandcodeDelete` highlight and a `[DELETE]` virtual text marker
3. **Type-over listener**: Handcode attaches to the buffer via `nvim_buf_attach` and listens for `on_bytes` events:
   - **Match**: Character matches the ghost text → overwrite the next ghost char, advance cursor
   - **Mismatch**: Character differs from ghost text → solidify the line immediately
4. **Auto-complete**: Replace buffer lines with stored target lines for the current line, hunk, range, or entire file

### Highlight Groups

| Group | Default | Purpose |
|-------|---------|---------|
| `HandcodeGhost` | Linked to `Comment` | Un-solidified ghost additions |
| `HandcodeDelete` | Linked to `DiffDelete` | Deletion lines with `[DELETE]` marker |

Override them in your `colorscheme` or `setup`:

```lua
vim.api.nvim_set_hl(0, "HandcodeGhost", { fg = "#555555", bg = "#1a1a2e" })
```

---

## Integration Examples

### With NvChad (your config)

Add the plugin spec to your custom plugins:

```lua
-- lua/plugins/handcode.lua
return {
  "Mjoyufull/Handcode.nvim",
  config = function()
    require("handcode").setup({
      keymaps = {
        accept_line   = "<C-l>",     -- Use Ctrl+L instead of Tab
        complete_hunk = "<leader>a", -- Use leader+a for hunk complete
      },
    })
  end,
}
```

Then run `:Lazy` or restart Neovim.

### With Lualine

```lua
require("lualine").setup({
  sections = {
    lualine_x = {
      {
        function()
          local state = require("handcode.state")
          local count = 0
          for _, session in pairs(state.sessions or {}) do
            for _, hunk in ipairs(session.ghost_hunks or {}) do
              if not hunk.resolved then
                for i = 1, #(hunk.additions or {}) do
                  if not hunk.solidified_lines[i] then
                    count = count + 1
                  end
                end
              end
            end
          end
          return count > 0 and ("HC:%d"):format(count) or ""
        end,
        color = { fg = "#888888" },
      },
    },
  },
})
```

### Auto-start with an autocmd

```lua
vim.api.nvim_create_autocmd("BufRead", {
  pattern = "*.py",
  callback = function()
    -- Wait for git diff to be available
    vim.defer_fn(function()
      require("handcode").start()
    end, 100)
  end,
})
```

---

## FAQ

**Q: Can I use Handcode on files without git?**

No — Handcode relies on `git diff` to detect changes. The file must be in a git repository with unstaged changes.

**Q: What happens if I delete a ghost addition line?**

The line counts as resolved. Handcode tracks lines by extmark position; if a line is gone, it skips it.

**Q: Can I stop Handcode mid-session?**

Yes. `:Handcode stop` ends the session and leaves your current buffer edits as-is.

**Q: Multiple buffers at once?**

Handcode tracks sessions per buffer. You can have ghost hunks active in different files simultaneously — the HUD shows all of them.

**Q: Tab completion conflicts with other plugins?**

Disable the default keymap:

```lua
require("handcode").setup({
  keymaps = {
    accept_line = false, -- Disable Tab mapping
  },
})
```

Then map insert-mode completion elsewhere:

```lua
vim.keymap.set("i", "<C-l>", function()
  require("handcode").complete_line()
end, { buffer = bufnr, desc = "Handcode: Accept line" })
```

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `:Handcode start` does nothing | Ensure the buffer has a named file path and is in a git repo with unstaged changes |
| `git diff` failed | Run `git status` to confirm you're in a repo with uncommitted changes |
| Ghost highlights not showing | Check `:hi HandcodeGhost` — it should link to `Comment` |
| HUD not appearing | Try `:lua require("handcode.hud").toggle()` to re-enable |
| Insert mode feels laggy | The type-over listener runs per keystroke — large hunks may cause minor delay. Use auto-complete (`<Tab>`) for large blocks |
