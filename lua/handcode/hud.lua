--- handcode/hud.lua
--- Floating HUD window showing active sessions and remaining ghost counts.

local M = {}

M.win_id = nil
M.bufnr  = nil

M.config = {
  enabled   = true,
  position  = "top_right",
  border    = "rounded",
  max_width = 30,
}

-- Namespace created once — fixes the leak from creating it on every update()
local HUD_HL_NS = vim.api.nvim_create_namespace("handcode_hud_hl")

---Close the HUD window.
function M.close()
  if M.win_id and vim.api.nvim_win_is_valid(M.win_id) then
    pcall(vim.api.nvim_win_close, M.win_id, true)
  end
  M.win_id = nil
end

---Update (or open) the HUD window with current session stats.
function M.update()
  if not M.config.enabled then
    M.close()
    return
  end

  local state = require("handcode.state")
  local active = {}

  for bufnr, session in pairs(state.sessions) do
    local has_unresolved = false
    for _, hunk in ipairs(session.ghost_hunks) do
      if not hunk.resolved then
        has_unresolved = true
        break
      end
    end
    if has_unresolved then
      table.insert(active, { bufnr = bufnr, session = session })
    end
  end

  if #active == 0 then
    M.close()
    return
  end

  -- Build display lines
  local lines = {
    "  HANDCODE MODE ",
    " ────────────────",
  }
  local computed_width = 18

  for _, item in ipairs(active) do
    local session = item.session
    local adds, dels = 0, 0
    local line_ranges = {}
    
    for _, hunk in ipairs(session.ghost_hunks) do
      if not hunk.resolved then
        -- Get extmark position to show line numbers
        local pos = vim.api.nvim_buf_get_extmark_by_id(
          item.bufnr, state.ns_id, hunk.extmark_id, {}
        )
        if pos and pos[1] then
          local start_line = pos[1] + 1  -- convert to 1-indexed
          local end_line = start_line + math.max(#hunk.additions, #hunk.deletions) - 1
          table.insert(line_ranges, string.format("L%d-%d", start_line, end_line))
        end
        
        for i = 1, #hunk.additions do
          if not hunk.solidified_lines[i] then adds = adds + 1 end
        end
        dels = dels + #hunk.deletions
      end
    end

    local fname = "  " .. session.file
    local ranges = "    " .. table.concat(line_ranges, ", ")
    local stat_line = string.format("    +%d  -%d", adds, dels)
    
    table.insert(lines, fname)
    if #line_ranges > 0 then
      table.insert(lines, ranges)
    end
    table.insert(lines, stat_line)
    table.insert(lines, "")  -- spacer
    
    computed_width = math.max(computed_width, #fname + 2, #ranges + 2, #stat_line + 2)
  end

  local width = math.min(computed_width, M.config.max_width)

  -- Ensure scratch buffer exists
  if not M.bufnr or not vim.api.nvim_buf_is_valid(M.bufnr) then
    M.bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[M.bufnr].bufhidden = "hide"
  end

  vim.api.nvim_buf_set_lines(M.bufnr, 0, -1, false, lines)

  -- Apply highlights
  vim.api.nvim_buf_clear_namespace(M.bufnr, HUD_HL_NS, 0, -1)
  vim.api.nvim_buf_add_highlight(M.bufnr, HUD_HL_NS, "Title",   0, 0, -1)
  vim.api.nvim_buf_add_highlight(M.bufnr, HUD_HL_NS, "Comment", 1, 0, -1)

  local li = 2
  for _ = 1, #active do
    vim.api.nvim_buf_add_highlight(M.bufnr, HUD_HL_NS, "Directory",     li,     0, -1)  -- filename
    vim.api.nvim_buf_add_highlight(M.bufnr, HUD_HL_NS, "Number",        li + 1, 0, -1)  -- line ranges
    vim.api.nvim_buf_add_highlight(M.bufnr, HUD_HL_NS, "DiagnosticOk",  li + 2, 0, -1)  -- stats
    li = li + 4  -- filename + ranges + stats + spacer
  end

  -- Window config
  local col = (M.config.position == "top_right") and (vim.o.columns - width - 3) or 3
  local win_opts = {
    relative  = "editor",
    width     = width,
    height    = #lines,
    col       = col,
    row       = 1,
    anchor    = (M.config.position == "top_right") and "NE" or "NW",
    style     = "minimal",
    border    = M.config.border,
    focusable = false,
    zindex    = 50,
  }

  if not M.win_id or not vim.api.nvim_win_is_valid(M.win_id) then
    M.win_id = vim.api.nvim_open_win(M.bufnr, false, win_opts)
  else
    vim.api.nvim_win_set_config(M.win_id, win_opts)
  end
end

---Toggle the HUD on/off.
function M.toggle()
  M.config.enabled = not M.config.enabled
  M.update()
end

return M
