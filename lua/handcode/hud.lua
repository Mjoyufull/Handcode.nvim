local M = {}

M.win_id = nil
M.bufnr = nil

-- Config settings (loaded from setup)
M.config = {
  enabled = true,
  position = "top_right",
  border = "rounded",
  max_width = 30,
}

---Update the HUD window contents and visibility
function M.update()
  if not M.config.enabled then
    M.close()
    return
  end

  local state = require("handcode.state")
  local active_sessions = {}

  for bufnr, session in pairs(state.sessions) do
    local has_active_hunks = false
    for _, hunk in ipairs(session.ghost_hunks) do
      if not hunk.resolved then
        has_active_hunks = true
        break
      end
    end
    if has_active_hunks then
      table.insert(active_sessions, session)
    end
  end

  -- If no active sessions, close HUD and exit
  if #active_sessions == 0 then
    M.close()
    return
  end

  -- Prepare lines to display
  local lines = {
    "  HANDCODE MODE ",
    " ────────────────",
  }
  local max_width = 18 -- min width

  for _, session in ipairs(active_sessions) do
    local add_left = 0
    local del_left = 0
    for _, hunk in ipairs(session.ghost_hunks) do
      if not hunk.resolved then
        -- Count un-solidified additions
        for i = 1, #hunk.additions do
          if not hunk.solidified_lines[i] then
            add_left = add_left + 1
          end
        end
        del_left = del_left + #hunk.deletions
      end
    end

    table.insert(lines, "  " .. session.file)
    local status_line = string.format("    %d additions   %d deletions", add_left, del_left)
    table.insert(lines, status_line)

    max_width = math.max(max_width, #session.file + 5, #status_line + 2)
  end

  -- Clamp width to max_width configuration
  max_width = math.min(max_width, M.config.max_width)

  -- Create buffer if not exists
  if not M.bufnr or not vim.api.nvim_buf_is_valid(M.bufnr) then
    M.bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[M.bufnr].bufhidden = "hide"
  end

  -- Write lines to buffer
  vim.api.nvim_buf_set_lines(M.bufnr, 0, -1, false, lines)

  -- Apply syntax highlighting to HUD
  local ns = vim.api.nvim_create_namespace("handcode_hud_hl")
  vim.api.nvim_buf_clear_namespace(M.bufnr, ns, 0, -1)
  vim.api.nvim_buf_add_highlight(M.bufnr, ns, "Title", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(M.bufnr, ns, "Comment", 1, 0, -1)

  local line_idx = 2
  for _ = 1, #active_sessions do
    -- File name highlighting
    vim.api.nvim_buf_add_highlight(M.bufnr, ns, "Directory", line_idx, 0, -1)

    -- Status line parsing for coloring
    local status = lines[line_idx + 1]
    local add_start = status:find("")
    local del_start = status:find("")

    if add_start then
      local add_end = status:find("additions")
      if add_end then
        vim.api.nvim_buf_add_highlight(M.bufnr, ns, "DiagnosticOk", line_idx + 1, add_start - 1, add_end + 9)
      end
    end

    if del_start then
      local del_end = status:find("deletions")
      if del_end then
        vim.api.nvim_buf_add_highlight(M.bufnr, ns, "DiagnosticError", line_idx + 1, del_start - 1, del_end + 9)
      end
    end

    line_idx = line_idx + 2
  end

  -- Configure window properties
  local width = max_width
  local height = #lines
  local col = (M.config.position == "top_right") and (vim.o.columns - width - 3) or 3
  local row = 1

  local win_opts = {
    relative = "editor",
    width = width,
    height = height,
    col = col,
    row = row,
    anchor = (M.config.position == "top_right") and "NE" or "NW",
    style = "minimal",
    border = M.config.border,
    focusable = false,
  }

  -- Open or update window
  if not M.win_id or not vim.api.nvim_win_is_valid(M.win_id) then
    M.win_id = vim.api.nvim_open_win(M.bufnr, false, win_opts)
  else
    vim.api.nvim_win_set_config(M.win_id, win_opts)
  end
end

---Close the HUD window
function M.close()
  if M.win_id and vim.api.nvim_win_is_valid(M.win_id) then
    vim.api.nvim_win_close(M.win_id, true)
  end
  M.win_id = nil
end

---Toggle HUD display configuration
function M.toggle()
  M.config.enabled = not M.config.enabled
  M.update()
end

return M
