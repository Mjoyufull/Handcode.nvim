--- handcode/init.lua
--- Public API: setup, start/stop, complete_* commands.

local M = {}

M.config = {
  hl_groups = {
    ghost  = "HandcodeGhost",
    delete = "HandcodeDelete",
  },
  hud = {
    enabled   = true,
    position  = "top_right",
    border    = "rounded",
    max_width = 30,
  },
  keymaps = {
    accept_line   = "<Tab>",
    complete_hunk = "<leader>hc",
    complete_file = "<leader>hf",
  },
  detection = {
    opencode_events = true,  -- hook into OpencodeEvent:* autocmds
    fs_watch        = true,  -- vim.uv.fs_event per buffer
    buf_enter       = true,  -- BufEnter / FocusGained fallback
    auto_follow     = false, -- automatically switch to edited files (breaks workflow)
  },
}

---@param opts table?
function M.setup(opts)
  if opts then
    for _, key in ipairs({ "hl_groups", "hud", "keymaps", "detection" }) do
      if opts[key] then
        M.config[key] = vim.tbl_extend("force", M.config[key], opts[key])
      end
    end
  end

  -- Highlights
  vim.api.nvim_set_hl(0, "HandcodeGhost",  { link = M.config.hl_groups.ghost,  default = true })
  vim.api.nvim_set_hl(0, "HandcodeDelete", { link = M.config.hl_groups.delete, default = true })

  -- HUD config
  require("handcode.hud").config = M.config.hud

  -- Detection layer
  require("handcode.detect").setup(M.config)

  -- User commands
  vim.api.nvim_create_user_command("Handcode", function(args)
    local sub = args.fargs[1] or "toggle"
    if     sub == "start"         then M.start()
    elseif sub == "stop"          then M.stop(args.fargs[2] == "restore")
    elseif sub == "toggle"        then M.toggle()
    elseif sub == "complete_line" then M.complete_line()
    elseif sub == "complete_hunk" then M.complete_hunk()
    elseif sub == "complete_file" then M.complete_file()
    else
      vim.notify(
        "Handcode: unknown subcommand '" .. sub .. "'",
        vim.log.levels.ERROR
      )
    end
  end, {
    nargs    = "*",
    complete = function()
      return { "start", "stop", "toggle", "complete_line", "complete_hunk", "complete_file" }
    end,
  })

  vim.api.nvim_create_user_command("HandcodeCompleteRange", function(a)
    M.complete_range(a.line1, a.line2)
  end, { range = true })
end

-- ─── session control ─────────────────────────────────────────────────────────

---Start a Handcode session on bufnr (defaults to current buffer).
---@param bufnr number?
function M.start(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = require("handcode.state")
  state.start_session(bufnr)

  -- Buffer-local keymaps (only if session actually started)
  if not state.sessions[bufnr] then return end

  local km = M.config.keymaps

  if km.accept_line then
    -- Insert-mode: accept/complete the current ghost line.
    -- expr = true so we can fall through to a real <Tab> when not on a ghost line.
    vim.keymap.set("i", km.accept_line, function()
      if require("handcode.state").accept_current_line() then
        return ""           -- handled — produce no keypress
      end
      return km.accept_line -- not on ghost text — pass the key through
    end, { buffer = bufnr, expr = true, replace_keycodes = true, desc = "Handcode: accept ghost line" })
  end

  if km.complete_hunk then
    vim.keymap.set("n", km.complete_hunk, function()
      M.complete_hunk()
    end, { buffer = bufnr, desc = "Handcode: complete hunk" })
  end

  if km.complete_file then
    vim.keymap.set("n", km.complete_file, function()
      M.complete_file()
    end, { buffer = bufnr, desc = "Handcode: complete file" })
  end
end

---Stop the session on the current buffer.
---@param restore boolean?
function M.stop(restore)
  local bufnr = vim.api.nvim_get_current_buf()
  local km    = M.config.keymaps

  pcall(vim.keymap.del, "i", km.accept_line   or "", { buffer = bufnr })
  pcall(vim.keymap.del, "n", km.complete_hunk or "", { buffer = bufnr })
  pcall(vim.keymap.del, "n", km.complete_file or "", { buffer = bufnr })

  require("handcode.state").stop_session(bufnr, restore or false)
end

---Toggle the session on the current buffer.
function M.toggle()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = require("handcode.state")
  if state.sessions[bufnr] then
    M.stop(false)
  else
    M.start(bufnr)
  end
end

-- ─── completion API ──────────────────────────────────────────────────────────

---Accept the current ghost line. Returns true if handled (for expr keymap).
---@return boolean
function M.complete_line()
  return require("handcode.state").accept_current_line()
end

---Complete the ghost hunk under the cursor.
function M.complete_hunk()
  local bufnr      = vim.api.nvim_get_current_buf()
  local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
  require("handcode.state").resolve_hunk_at(bufnr, cursor_row)
end

---Complete ghost hunks in a visually selected range.
---@param start_line number  1-indexed
---@param end_line   number  1-indexed
function M.complete_range(start_line, end_line)
  local bufnr = vim.api.nvim_get_current_buf()
  local n     = require("handcode.state").resolve_range(
    bufnr, start_line - 1, end_line - 1
  )
  if n > 0 then
    vim.notify("Handcode: completed " .. n .. " hunk(s) in range", vim.log.levels.INFO)
  else
    vim.notify("Handcode: no ghost hunks in selection", vim.log.levels.WARN)
  end
end

---Complete all ghost hunks in the current buffer.
function M.complete_file()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = require("handcode.state")
  if not state.sessions[bufnr] then return end
  state.resolve_all(bufnr)
  vim.notify("Handcode: file completed", vim.log.levels.INFO)
end

return M
