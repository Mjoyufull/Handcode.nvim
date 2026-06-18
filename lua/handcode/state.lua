--- handcode/state.lua
--- Session state, extmark management, and type-over listener.
--- Type-over uses on_lines + common-prefix comparison (no on_bytes overwrite hack).

local M = {}
local diff_mod = require("handcode.diff")

-- Namespaces
M.ns_id   = vim.api.nvim_create_namespace("handcode_system")
M.ns_ghost = vim.api.nvim_create_namespace("handcode_ghosts")

---@class handcode.GhostHunk
---@field extmark_id     number     extmark tracking the addition block start row
---@field del_extmark_id number?    extmark tracking the deletion block
---@field additions      string[]   target lines (what the AI wrote)
---@field deletions      string[]   original lines being replaced
---@field solidified_lines table<number, boolean>  1-indexed: true = done
---@field solidified_col  number    byte col up to which the active line is solidified
---@field resolved        boolean

---@class handcode.Session
---@field bufnr          number
---@field file           string     short filename for HUD
---@field ghost_hunks    handcode.GhostHunk[]
---@field ai_lines       string[]   buffer snapshot when session started (AI version)
---@field original_lines string[]   buffer snapshot after deletions restored
---@field is_updating    boolean    re-entrancy guard

---@type table<number, handcode.Session>
M.sessions = {}

-- Default highlights (overridden by setup via init.lua)
vim.api.nvim_set_hl(0, "HandcodeGhost",  { link = "Comment",    default = true })
vim.api.nvim_set_hl(0, "HandcodeDelete", { link = "DiffDelete", default = true })

-- ─── helpers ────────────────────────────────────────────────────────────────

---Return the first un-solidified addition index in a hunk, or nil.
---@param hunk handcode.GhostHunk
---@return number?
local function get_active_line(hunk)
  for i = 1, #hunk.additions do
    if not hunk.solidified_lines[i] then
      return i
    end
  end
  return nil
end

---Byte length of the longest common prefix of two strings.
---@param a string
---@param b string
---@return number
local function common_prefix_len(a, b)
  local limit = math.min(#a, #b)
  for i = 1, limit do
    if a:sub(i, i) ~= b:sub(i, i) then
      return i - 1
    end
  end
  return limit
end

---Resolve a hunk's deletion block: remove the restored lines from the buffer.
---@param bufnr   number
---@param hunk    handcode.GhostHunk
---@param session handcode.Session
local function resolve_deletions(bufnr, hunk, session)
  if not hunk.del_extmark_id then return end
  local del_pos = vim.api.nvim_buf_get_extmark_by_id(
    bufnr, M.ns_id, hunk.del_extmark_id, { details = true }
  )
  if del_pos and del_pos[1] and del_pos[3] then
    local s = del_pos[1]
    local e = del_pos[3].end_row
    if e > s then
      session.is_updating = true
      vim.api.nvim_buf_set_lines(bufnr, s, e, false, {})
      session.is_updating = false
    end
  end
  hunk.deletions = {}
  hunk.del_extmark_id = nil
end

---Resolve a hunk's addition block: replace buffer lines with stored targets.
---@param bufnr   number
---@param hunk    handcode.GhostHunk
---@param session handcode.Session
local function resolve_additions(bufnr, hunk, session)
  if #hunk.additions == 0 then return end
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns_id, hunk.extmark_id, {})
  if pos and pos[1] then
    session.is_updating = true
    vim.api.nvim_buf_set_lines(bufnr, pos[1], pos[1] + #hunk.additions, false, hunk.additions)
    session.is_updating = false
  end
  hunk.additions = {}
  hunk.solidified_lines = {}
  hunk.solidified_col = 0
end

-- ─── render ─────────────────────────────────────────────────────────────────

---Recompute solidification state for a hunk from the current buffer content,
---then repaint the ghost highlight extmarks.
---Uses common-prefix comparison — no on_bytes required.
---@param bufnr number
---@param hunk  handcode.GhostHunk
local function sync_and_paint_hunk(bufnr, hunk)
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns_id, hunk.extmark_id, {})
  if not pos or not pos[1] then
    hunk.resolved = true
    return
  end
  local start_row = pos[1]

  local buf_lines = vim.api.nvim_buf_get_lines(
    bufnr, start_row, start_row + #hunk.additions, false
  )

  local all_done = true
  for i = 1, #hunk.additions do
    if hunk.solidified_lines[i] then goto continue end

    local buf_line = buf_lines[i]
    local target   = hunk.additions[i]

    if buf_line == nil then
      -- line was deleted — count as solidified
      hunk.solidified_lines[i] = true
      goto continue
    end

    if buf_line == target then
      hunk.solidified_lines[i] = true
      goto continue
    end

    -- Compute how far the user has typed (common prefix length)
    local prefix = common_prefix_len(buf_line, target)

    -- If this is the active (first un-solidified) line, update solidified_col
    local active_idx = get_active_line(hunk)
    if active_idx == i then
      -- If the already-solidified portion has been edited (prefix retreated), solidify whole line
      if prefix < hunk.solidified_col then
        hunk.solidified_lines[i] = true
        goto continue
      end
      hunk.solidified_col = prefix
    else
      -- Non-active lines: any edit at all solidifies them
      if prefix < #target then
        -- User edited a non-active line — solidify it
        hunk.solidified_lines[i] = true
        goto continue
      end
    end

    all_done = false

    -- Paint ghost highlight from solidified_col (or 0 for non-active) to end of target
    local paint_from = (active_idx == i) and hunk.solidified_col or 0
    local paint_to   = math.min(#buf_line, #target)
    if paint_to > paint_from then
      vim.api.nvim_buf_set_extmark(bufnr, M.ns_ghost, start_row + i - 1, paint_from, {
        end_col  = paint_to,
        hl_group = "HandcodeGhost",
        priority = 100,
      })
    end

    ::continue::
  end

  -- If every addition line is done, clear the list so hunk can resolve
  if all_done then
    hunk.additions = {}
  end
end

---Full render pass: clear ghost namespace, re-sync all hunks, update HUD.
---@param bufnr number
function M.render_buffer(bufnr)
  local session = M.sessions[bufnr]
  if not session then return end

  vim.api.nvim_buf_clear_namespace(bufnr, M.ns_ghost, 0, -1)

  for _, hunk in ipairs(session.ghost_hunks) do
    if hunk.resolved then goto continue end

    -- Sync + paint additions
    if #hunk.additions > 0 then
      sync_and_paint_hunk(bufnr, hunk)
    end

    -- Check if deletions have been manually deleted (extmark range collapsed)
    if hunk.del_extmark_id then
      local dp = vim.api.nvim_buf_get_extmark_by_id(
        bufnr, M.ns_id, hunk.del_extmark_id, { details = true }
      )
      if dp and dp[1] and dp[3] then
        if dp[3].end_row <= dp[1] then
          hunk.deletions = {}
          hunk.del_extmark_id = nil
        end
      else
        -- extmark gone
        hunk.deletions = {}
        hunk.del_extmark_id = nil
      end
    end

    -- Resolve hunk when both sides are done
    if #hunk.additions == 0 and #hunk.deletions == 0 then
      hunk.resolved = true
    end

    ::continue::
  end

  require("handcode.hud").update()

  if M.is_session_resolved(session) then
    vim.notify("Handcode: All changes handcoded!", vim.log.levels.INFO)
    M.stop_session(bufnr, false)
  end
end

-- ─── session lifecycle ───────────────────────────────────────────────────────

---@param session handcode.Session
---@return boolean
function M.is_session_resolved(session)
  for _, hunk in ipairs(session.ghost_hunks) do
    if not hunk.resolved then return false end
  end
  return true
end

---Start a Handcode session for bufnr.
---@param bufnr number
function M.start_session(bufnr)
  if M.sessions[bufnr] then
    vim.notify("Handcode: already active in this buffer", vim.log.levels.INFO)
    return
  end

  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then
    vim.notify("Handcode: buffer must have a filename", vim.log.levels.ERROR)
    return
  end

  local hunks = diff_mod.get_file_diff(filepath)
  if not hunks or #hunks == 0 then
    vim.notify("Handcode: no unstaged changes found", vim.log.levels.INFO)
    return
  end

  local ai_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local session = {
    bufnr          = bufnr,
    file           = vim.fn.fnamemodify(filepath, ":t"),
    ghost_hunks    = {},
    ai_lines       = ai_lines,
    original_lines = {},
    is_updating    = false,
  }

  -- Restore deleted lines bottom-to-top so line numbers stay valid
  for h = #hunks, 1, -1 do
    local hunk = hunks[h]
    if hunk.del_len > 0 then
      local ins_row = hunk.add_start - 1
      vim.api.nvim_buf_set_lines(bufnr, ins_row, ins_row, false, hunk.deletions)
    end
  end

  session.original_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Place extmarks and build ghost_hunks
  local offset = 0
  for _, hunk in ipairs(hunks) do
    local del_start_row = hunk.add_start - 1 + offset
    local add_start_row = del_start_row + hunk.del_len

    -- Extmark for the addition block (stays at its row even as text is inserted above)
    local extmark_id = vim.api.nvim_buf_set_extmark(bufnr, M.ns_id, add_start_row, 0, {
      right_gravity = false,
    })

    -- Extmark + highlight for deletion block
    local del_extmark_id = nil
    if hunk.del_len > 0 then
      del_extmark_id = vim.api.nvim_buf_set_extmark(bufnr, M.ns_id, del_start_row, 0, {
        end_row  = del_start_row + hunk.del_len,
        hl_group = "HandcodeDelete",
      })
      for i = 0, hunk.del_len - 1 do
        vim.api.nvim_buf_set_extmark(bufnr, M.ns_id, del_start_row + i, 0, {
          virt_text     = { { "  [DELETE]", "HandcodeDelete" } },
          virt_text_pos = "eol",
        })
      end
    end

    table.insert(session.ghost_hunks, {
      extmark_id      = extmark_id,
      del_extmark_id  = del_extmark_id,
      additions       = hunk.additions,
      deletions       = hunk.deletions,
      solidified_lines = {},
      solidified_col  = 0,
      resolved        = false,
    })

    offset = offset + hunk.del_len
  end

  M.sessions[bufnr] = session

  -- Attach buffer listener (on_lines only — no on_bytes)
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, b, _, first, last_old, last_new)
      local s = M.sessions[b]
      if not s then return true end  -- true = detach
      if s.is_updating then return end

      -- Check if any deletion-block rows were removed
      local row_delta = last_new - last_old
      if row_delta < 0 then
        -- Rows were deleted — check each hunk's deletion extmark
        for _, h in ipairs(s.ghost_hunks) do
          if not h.resolved and h.del_extmark_id then
            local dp = vim.api.nvim_buf_get_extmark_by_id(
              b, M.ns_id, h.del_extmark_id, { details = true }
            )
            if dp and dp[1] and dp[3] then
              if dp[3].end_row <= dp[1] then
                h.deletions = {}
                h.del_extmark_id = nil
              end
            end
          end
        end
      end

      vim.schedule(function()
        M.render_buffer(b)
      end)
    end,

    on_detach = function(_, b)
      -- Buffer was closed/unloaded — clean up without restoring
      local s = M.sessions[b]
      if s then
        vim.api.nvim_buf_clear_namespace(b, M.ns_id,    0, -1)
        vim.api.nvim_buf_clear_namespace(b, M.ns_ghost, 0, -1)
        M.sessions[b] = nil
        require("handcode.hud").update()
      end
    end,
  })

  M.render_buffer(bufnr)
  vim.notify("Handcode: started — " .. #hunks .. " hunk(s) loaded", vim.log.levels.INFO)
end

---Stop a Handcode session.
---@param bufnr   number
---@param restore boolean  if true, put the AI's original lines back
function M.stop_session(bufnr, restore)
  local session = M.sessions[bufnr]
  if not session then return end

  vim.api.nvim_buf_clear_namespace(bufnr, M.ns_id,    0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns_ghost, 0, -1)

  if restore then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, session.ai_lines)
    vim.notify("Handcode: restored AI suggestions", vim.log.levels.INFO)
  end

  M.sessions[bufnr] = nil
  require("handcode.detect").unwatch_buf(bufnr)
  require("handcode.hud").update()
end

-- ─── public completion helpers ───────────────────────────────────────────────

---Accept the current ghost line at the cursor (Insert or Normal mode).
---@return boolean
function M.accept_current_line()
  local bufnr      = vim.api.nvim_get_current_buf()
  local session    = M.sessions[bufnr]
  if not session then return false end

  local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1  -- 0-indexed

  for _, hunk in ipairs(session.ghost_hunks) do
    if hunk.resolved or #hunk.additions == 0 then goto continue end

    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns_id, hunk.extmark_id, {})
    if not (pos and pos[1]) then goto continue end

    local active_idx = get_active_line(hunk)
    if active_idx and pos[1] + active_idx - 1 == cursor_row then
      local target = hunk.additions[active_idx]
      session.is_updating = true
      vim.api.nvim_buf_set_lines(bufnr, cursor_row, cursor_row + 1, false, { target })
      session.is_updating = false

      hunk.solidified_lines[active_idx] = true
      hunk.solidified_col = 0
      vim.api.nvim_win_set_cursor(0, { cursor_row + 1, math.max(0, #target - 1) })

      vim.schedule(function() M.render_buffer(bufnr) end)
      return true
    end

    ::continue::
  end
  return false
end

---Resolve the ghost hunk under the cursor.
---@param bufnr      number
---@param cursor_row number  0-indexed
function M.resolve_hunk_at(bufnr, cursor_row)
  local session = M.sessions[bufnr]
  if not session then return end

  for _, hunk in ipairs(session.ghost_hunks) do
    if hunk.resolved then goto continue end

    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns_id, hunk.extmark_id, {})
    if not (pos and pos[1]) then goto continue end

    local hunk_start = pos[1]
    local hunk_end   = hunk_start + math.max(#hunk.additions, 1) - 1

    if cursor_row >= hunk_start and cursor_row <= hunk_end then
      resolve_deletions(bufnr, hunk, session)
      resolve_additions(bufnr, hunk, session)
      hunk.resolved = true
      vim.schedule(function() M.render_buffer(bufnr) end)
      return
    end

    ::continue::
  end
  vim.notify("Handcode: cursor not inside a ghost hunk", vim.log.levels.WARN)
end

---Resolve all hunks whose addition rows overlap [start_row, end_row] (0-indexed, inclusive).
---@param bufnr     number
---@param start_row number
---@param end_row   number
---@return number  number of hunks resolved
function M.resolve_range(bufnr, start_row, end_row)
  local session = M.sessions[bufnr]
  if not session then return 0 end

  local count = 0
  for _, hunk in ipairs(session.ghost_hunks) do
    if hunk.resolved then goto continue end

    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns_id, hunk.extmark_id, {})
    if not (pos and pos[1]) then goto continue end

    local hs = pos[1]
    local he = hs + math.max(#hunk.additions, 1) - 1

    if not (he < start_row or hs > end_row) then
      resolve_deletions(bufnr, hunk, session)
      resolve_additions(bufnr, hunk, session)
      hunk.resolved = true
      count = count + 1
    end

    ::continue::
  end

  vim.schedule(function() M.render_buffer(bufnr) end)
  return count
end

---Resolve every unresolved hunk in bufnr.
---@param bufnr number
function M.resolve_all(bufnr)
  local session = M.sessions[bufnr]
  if not session then return end

  for _, hunk in ipairs(session.ghost_hunks) do
    if not hunk.resolved then
      resolve_deletions(bufnr, hunk, session)
      resolve_additions(bufnr, hunk, session)
      hunk.resolved = true
    end
  end

  vim.schedule(function() M.render_buffer(bufnr) end)
end

return M
