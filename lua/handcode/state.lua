local M = {}
local diff_mod = require("handcode.diff")

-- Namespaces for our decorations
M.ns_id = vim.api.nvim_create_namespace("handcode_system")
M.ns_ghost = vim.api.nvim_create_namespace("handcode_ghosts")

---@class handcode.GhostHunk
---@field extmark_id number ID of the extmark tracking the addition start line
---@field del_extmark_id number? ID of the extmark tracking the deletion range
---@field additions string[]
---@field deletions string[]
---@field solidified_lines table<number, boolean> index -> true if solidified
---@field solidified_col number column index up to which active line is solidified
---@field resolved boolean

---@class handcode.Session
---@field bufnr number
---@field file string
---@field ghost_hunks handcode.GhostHunk[]
---@field original_lines string[]
---@field ai_lines string[]
---@field attached boolean
---@field is_updating boolean recursion guard flag

---@type table<number, handcode.Session>
M.sessions = {}

-- Ensure highlights exist
vim.api.nvim_set_hl(0, "HandcodeGhost", { link = "Comment", default = true })
vim.api.nvim_set_hl(0, "HandcodeDelete", { link = "DiffDelete", default = true })

---Check if all hunks in a session are resolved
---@param session handcode.Session
---@return boolean
function M.is_session_resolved(session)
  for _, hunk in ipairs(session.ghost_hunks) do
    if not hunk.resolved then
      return false
    end
  end
  return true
end

---Check if a deletion hunk is resolved by looking at extmark range
---@param bufnr number
---@param extmark_id number
---@return boolean
local function is_deletion_resolved(bufnr, extmark_id)
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns_id, extmark_id, { details = true })
  if not pos or not pos[1] or not pos.details then
    return true
  end
  local start_row = pos[1]
  local end_row = pos.details.end_row
  return start_row >= end_row
end

---Get active addition line index for a hunk
---@param hunk handcode.GhostHunk
---@return number? index
local function get_active_line(hunk)
  for i = 1, #hunk.additions do
    if not hunk.solidified_lines[i] then
      return i
    end
  end
  return nil
end

---Sync the hunk state with the actual buffer text (loose matching / manipulation check)
---@param bufnr number
---@param hunk handcode.GhostHunk
local function sync_hunk_state(bufnr, hunk)
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns_id, hunk.extmark_id, {})
  if not pos or not pos[1] then
    hunk.resolved = true
    return
  end
  local start_row = pos[1]

  -- Get buffer lines for additions
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, start_row, start_row + #hunk.additions, false)

  for i = 1, #hunk.additions do
    if not hunk.solidified_lines[i] then
      local buf_line = buf_lines[i]
      if not buf_line then
        -- Line deleted, mark as solidified
        hunk.solidified_lines[i] = true
      else
        local target = hunk.additions[i]
        -- If line matches target fully, mark solidified
        if buf_line == target then
          hunk.solidified_lines[i] = true
        else
          -- If prefix up to solidified_col doesn't match, user manipulated it differently
          if hunk.solidified_col > #buf_line then
            hunk.solidified_col = #buf_line
          end
          local target_prefix = string.sub(target, 1, hunk.solidified_col)
          local buf_prefix = string.sub(buf_line, 1, hunk.solidified_col)
          if target_prefix ~= buf_prefix then
            hunk.solidified_lines[i] = true
          end
        end
      end
    end
  end

  -- Check if all additions are solidified
  local all_solidified = true
  for i = 1, #hunk.additions do
    if not hunk.solidified_lines[i] then
      all_solidified = false
      break
    end
  end
  if all_solidified then
    hunk.additions = {}
  end
end

---Render the virtual text and overlays for a buffer
---@param bufnr number
function M.render_buffer(bufnr)
  local session = M.sessions[bufnr]
  if not session then return end

  -- Clear existing ghosts
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns_ghost, 0, -1)

  local hud = require("handcode.hud")

  for _, hunk in ipairs(session.ghost_hunks) do
    if not hunk.resolved then
      -- 1. Sync additions and deletions state
      sync_hunk_state(bufnr, hunk)

      if hunk.del_extmark_id and not hunk.resolved then
        if is_deletion_resolved(bufnr, hunk.del_extmark_id) then
          hunk.deletions = {}
        end
      end

      -- 2. Render additions ghost highlights and overlays
      if #hunk.additions > 0 then
        local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns_id, hunk.extmark_id, {})
        if pos and pos[1] then
          local start_row = pos[1]
          local active_idx = get_active_line(hunk)

          if active_idx then
            local active_line_num = start_row + active_idx - 1
            local target = hunk.additions[active_idx]
            local buf_line = (vim.api.nvim_buf_get_lines(bufnr, active_line_num, active_line_num + 1, false)[1] or "")

            -- Render the remaining gray highlight on the active line
            if #target > hunk.solidified_col then
              local end_col = #target
              vim.api.nvim_buf_set_extmark(bufnr, M.ns_ghost, active_line_num, hunk.solidified_col, {
                end_col = math.min(#buf_line, end_col),
                hl_group = "HandcodeGhost",
              })
            end

            -- Highlight subsequent un-solidified lines fully in gray
            for r = active_idx + 1, #hunk.additions do
              local line_num = start_row + r - 1
              local line_text = (vim.api.nvim_buf_get_lines(bufnr, line_num, line_num + 1, false)[1] or "")
              vim.api.nvim_buf_set_extmark(bufnr, M.ns_ghost, line_num, 0, {
                end_col = #line_text,
                hl_group = "HandcodeGhost",
              })
            end
          end
        end
      end

      -- 3. Check overall hunk resolution
      if #hunk.additions == 0 and #hunk.deletions == 0 then
        hunk.resolved = true
      end
    end
  end

  -- Update the HUD status
  hud.update()

  -- If all hunks resolved, clean up session
  if M.is_session_resolved(session) then
    vim.notify("Handcode: All changes handcoded! Cleaned up.", vim.log.levels.INFO)
    M.stop_session(bufnr, false)
  end
end

---Start Handcode session for a buffer
---@param bufnr number
function M.start_session(bufnr)
  if M.sessions[bufnr] then
    vim.notify("Handcode already active in this buffer", vim.log.levels.INFO)
    return
  end

  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then
    vim.notify("Handcode: Buffer must have a filename", vim.log.levels.ERROR)
    return
  end

  local hunks = diff_mod.get_file_diff(filepath)
  if not hunks or #hunks == 0 then
    vim.notify("Handcode: No unstaged changes to handcode", vim.log.levels.INFO)
    return
  end

  -- Cache current AI lines
  local ai_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local session = {
    bufnr = bufnr,
    file = vim.fn.fnamemodify(filepath, ":t"),
    ghost_hunks = {},
    ai_lines = ai_lines,
    original_lines = {},
    attached = false,
    is_updating = false,
  }

  -- 1. Apply deletions and additions highlights directly to buffer
  -- In this mode, the AI changes ARE present in the buffer.
  -- We just highlight them in gray, and mark deletions in red.
  -- We restore deletions so that the user sees them and has to delete them.
  -- To restore deletions, we insert them back. Let's do it bottom to top.
  for h = #hunks, 1, -1 do
    local hunk = hunks[h]
    if hunk.del_len > 0 then
      -- Insert deleted lines back into the buffer at their original position
      local start_idx = hunk.add_start - 1
      vim.api.nvim_buf_set_lines(bufnr, start_idx, start_idx, false, hunk.deletions)
    end
  end

  -- Cache original lines (what we now have in the buffer)
  session.original_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- 2. Now place extmarks and setup the state
  -- Since we restored deletions, we must compute their offsets.
  -- Let's iterate hunks again to place marks.
  local offset = 0
  for _, hunk in ipairs(hunks) do
    local start_line = hunk.add_start - 1 + offset

    -- Place additions mark (tracks start of additions block)
    -- Additions block is shifted by deletion insertion if deletions existed.
    local add_start_line = start_line + hunk.del_len
    local extmark_id = vim.api.nvim_buf_set_extmark(bufnr, M.ns_id, add_start_line, 0, {
      right_gravity = false,
      end_right_gravity = false,
    })

    -- Place deletions mark if any
    local del_extmark_id = nil
    if hunk.del_len > 0 then
      del_extmark_id = vim.api.nvim_buf_set_extmark(bufnr, M.ns_id, start_line, 0, {
        end_row = start_line + hunk.del_len,
        hl_group = "HandcodeDelete",
      })

      -- Add deletion indicators at EOL
      for i = 1, hunk.del_len do
        vim.api.nvim_buf_set_extmark(bufnr, M.ns_id, start_line + i - 1, 0, {
          virt_text = { { "  [DELETE]", "HandcodeDelete" } },
          virt_text_pos = "eol",
        })
      end
    end

    table.insert(session.ghost_hunks, {
      extmark_id = extmark_id,
      del_extmark_id = del_extmark_id,
      additions = hunk.additions,
      deletions = hunk.deletions,
      solidified_lines = {},
      solidified_col = 0,
      resolved = false,
    })

    offset = offset + hunk.del_len
  end

  M.sessions[bufnr] = session

  -- 3. Attach buffer listener
  vim.api.nvim_buf_attach(bufnr, false, {
    on_bytes = function(_, _, b, start_row, start_col, _, old_row, old_col, _, new_row, new_col, _)
      local s = M.sessions[b]
      if not s then return true end -- detach if session ended
      if s.is_updating then return end

      -- We only care about single line character insertions in Insert Mode
      if new_col > 0 and old_col == 0 and old_row == 0 and new_row == 0 then
        -- Find if we are typing on the active line of a ghost hunk
        for _, hunk in ipairs(s.ghost_hunks) do
          if not hunk.resolved and #hunk.additions > 0 then
            local pos = vim.api.nvim_buf_get_extmark_by_id(b, M.ns_id, hunk.extmark_id, {})
            if pos and pos[1] then
              local start_row_hunk = pos[1]
              local active_idx = get_active_line(hunk)
              if active_idx and start_row_hunk + active_idx - 1 == start_row then
                -- Typing on active ghost line!
                if start_col >= hunk.solidified_col then
                  local target = hunk.additions[active_idx]
                  
                  -- Get the typed char from buffer
                  local typed_char = vim.api.nvim_buf_get_text(b, start_row, start_col, start_row, start_col + new_col, {})[1] or ""
                  local target_char = string.sub(target, start_col + 1, start_col + new_col)

                  if typed_char == target_char then
                    -- Match! Perform overwrite (delete the shifted character to the right)
                    if start_col + new_col < #target then
                      s.is_updating = true
                      pcall(function()
                        vim.api.nvim_buf_set_text(b, start_row, start_col + new_col, start_row, start_col + 2 * new_col, {})
                      end)
                      s.is_updating = false
                      hunk.solidified_col = start_col + new_col
                    else
                      -- End of line matched!
                      hunk.solidified_lines[active_idx] = true
                      hunk.solidified_col = 0
                    end
                  else
                    -- Mismatch! Overwrite anyway (consume ghost) but solidify the line
                    if start_col + new_col < #target then
                      s.is_updating = true
                      pcall(function()
                        vim.api.nvim_buf_set_text(b, start_row, start_col + new_col, start_row, start_col + 2 * new_col, {})
                      end)
                      s.is_updating = false
                    end
                    hunk.solidified_lines[active_idx] = true
                    hunk.solidified_col = 0
                  end

                  vim.schedule(function()
                    M.render_buffer(b)
                  end)
                  break
                end
              end
            end
          end
        end
      end
    end,

    on_lines = function(_, b, _, _, _, _, _)
      local s = M.sessions[b]
      if not s then return true end -- detach
      if s.is_updating then return end

      vim.schedule(function()
        M.render_buffer(b)
      end)
    end,

    on_detach = function(_, b)
      M.stop_session(b, false)
    end,
  })
  session.attached = true

  -- Initial render
  M.render_buffer(bufnr)

  vim.notify("Handcode started: " .. #hunks .. " hunks loaded", vim.log.levels.INFO)
end

---Stop Handcode session for a buffer
---@param bufnr number
---@param restore boolean if true, restores buffer to original AI state
function M.stop_session(bufnr, restore)
  local session = M.sessions[bufnr]
  if not session then return end

  -- Clear extmarks
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns_id, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns_ghost, 0, -1)

  if restore then
    -- Restore to the AI version
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, session.ai_lines)
    vim.notify("Handcode stopped: Restored AI suggestions", vim.log.levels.INFO)
  end

  M.sessions[bufnr] = nil

  -- Update HUD
  local hud = require("handcode.hud")
  hud.update()
end

---Accept/complete the current ghost line at the cursor
---@return boolean true if handled, false otherwise
function M.accept_current_line()
  local bufnr = vim.api.nvim_get_current_buf()
  local session = M.sessions[bufnr]
  if not session then return false end

  local cursor_pos = vim.api.nvim_win_get_cursor(0)
  local cursor_line = cursor_pos[1] - 1 -- 0-indexed

  for _, hunk in ipairs(session.ghost_hunks) do
    if not hunk.resolved and #hunk.additions > 0 then
      local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns_id, hunk.extmark_id, {})
      if pos and pos[1] then
        local start_row = pos[1]
        local active_idx = get_active_line(hunk)

        if active_idx and start_row + active_idx - 1 == cursor_line then
          local target = hunk.additions[active_idx]
          
          session.is_updating = true
          vim.api.nvim_buf_set_lines(bufnr, cursor_line, cursor_line + 1, false, { target })
          session.is_updating = false
          
          hunk.solidified_lines[active_idx] = true
          hunk.solidified_col = 0

          vim.api.nvim_win_set_cursor(0, { cursor_line + 1, #target })

          -- Re-render immediately
          vim.schedule(function()
            M.render_buffer(bufnr)
          end)
          return true
        end
      end
    end
  end

  return false
end

return M
