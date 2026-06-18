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

---@param bufnr number
---@param state table
---@param hunk table
---@return number
local function remaining_deletions(bufnr, state, hunk)
  if not hunk.del_extmark_id then return 0 end

  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id, hunk.del_extmark_id, { details = true })
  if not pos or not pos[1] or not pos[3] then return 0 end

  return math.max(0, pos[3].end_row - pos[1])
end

---@param bufnr number
---@param state table
---@param hunk table
---@return string?
local function hunk_range(bufnr, state, hunk)
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id, hunk.extmark_id, { details = true })
  if not pos or not pos[1] then return nil end

  local start_row = pos[1]
  local end_row = pos[1] + math.max(#hunk.additions, 1) - 1

  if hunk.del_extmark_id then
    local del_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id, hunk.del_extmark_id, { details = true })
    if del_pos and del_pos[1] and del_pos[3] then
      start_row = math.min(start_row, del_pos[1])
      end_row = math.max(end_row, del_pos[3].end_row - 1)
    end
  end

  return string.format("L%d-%d", start_row + 1, end_row + 1)
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
        local range = hunk_range(item.bufnr, state, hunk)
        if range then
          table.insert(line_ranges, range)
        end

        for i = 1, #hunk.additions do
          if not hunk.solidified_lines[i] then adds = adds + 1 end
        end
        dels = dels + remaining_deletions(item.bufnr, state, hunk)
      end
    end

    local fname = "  " .. session.file
    local ranges = "    " .. table.concat(line_ranges, ", ")
    local stat_line = string.format("    +%d  -%d", adds, dels)
    local plus_start, plus_end = stat_line:find("%+%d+")
    local minus_start, minus_end = stat_line:find("%-%d+")

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
    table.insert(highlights, {
      line = stats_line,
      group = adds > 0 and "DiagnosticOk" or "Comment",
      start_col = plus_start and plus_start - 1 or 0,
      end_col = plus_end or -1,
    })
    table.insert(highlights, {
      line = stats_line,
      group = dels > 0 and "HandcodeDelete" or "Comment",
      start_col = minus_start and minus_start - 1 or 0,
      end_col = minus_end or -1,
    })
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
    vim.api.nvim_buf_add_highlight(M.bufnr, HUD_HL_NS, hl.group, hl.line, hl.start_col or 0, hl.end_col or -1)
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
