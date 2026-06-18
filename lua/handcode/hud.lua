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

---@param text string
---@param width number
---@return string
local function fit(text, width)
  if #text <= width then return text end
  if width <= 1 then return text:sub(1, width) end
  return text:sub(1, width - 1) .. "…"
end

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
  local highlights = {
    { line = 0, group = "Title" },
    { line = 1, group = "Comment" },
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

    local filename_line = #lines
    table.insert(lines, fname)
    table.insert(highlights, { line = filename_line, group = "Directory" })
    if #line_ranges > 0 then
      local range_line = #lines
      table.insert(lines, ranges)
      table.insert(highlights, { line = range_line, group = "Number" })
    end
    local stats_line = #lines
    table.insert(lines, stat_line)
    table.insert(highlights, { line = stats_line, group = "DiagnosticOk" })
    table.insert(lines, "") -- spacer

    computed_width = math.max(computed_width, #fname + 2, #ranges + 2, #stat_line + 2)
  end

  local width = math.min(computed_width, M.config.max_width)
  for i, line in ipairs(lines) do
    lines[i] = fit(line, width)
  end

  -- Ensure scratch buffer exists
  if not M.bufnr or not vim.api.nvim_buf_is_valid(M.bufnr) then
    M.bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[M.bufnr].bufhidden = "hide"
  end

  vim.api.nvim_buf_set_lines(M.bufnr, 0, -1, false, lines)

  -- Apply highlights
  vim.api.nvim_buf_clear_namespace(M.bufnr, HUD_HL_NS, 0, -1)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(M.bufnr, HUD_HL_NS, hl.group, hl.line, 0, -1)
  end

  -- Window config
  local right = M.config.position == "top_right" or M.config.position == "bottom_right"
  local bottom = M.config.position == "bottom_left" or M.config.position == "bottom_right"
  local col = right and (vim.o.columns - width - 3) or 3
  local row = bottom and math.max(1, vim.o.lines - #lines - 4) or 1
  local win_opts = {
    relative  = "editor",
    width     = width,
    height    = #lines,
    col       = col,
    row       = row,
    anchor    = right and "NE" or "NW",
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
