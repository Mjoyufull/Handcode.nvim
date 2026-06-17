local M = {}

M.config = {
  hl_groups = {
    ghost = "HandcodeGhost",
    delete = "HandcodeDelete",
  },
  hud = {
    enabled = true,
    position = "top_right",
    border = "rounded",
    max_width = 30,
  },
  keymaps = {
    accept_line = "<Tab>",
    complete_hunk = "<leader>hc",
    complete_file = "<leader>hf",
  }
}

---Setup the plugin with user config options
---@param opts table?
function M.setup(opts)
  if opts then
    if opts.hl_groups then
      M.config.hl_groups = vim.tbl_extend("force", M.config.hl_groups, opts.hl_groups)
    end
    if opts.hud then
      M.config.hud = vim.tbl_extend("force", M.config.hud, opts.hud)
    end
    if opts.keymaps then
      M.config.keymaps = vim.tbl_extend("force", M.config.keymaps, opts.keymaps)
    end
  end

  -- Apply highlight configurations
  vim.api.nvim_set_hl(0, "HandcodeGhost", { link = M.config.hl_groups.ghost, default = true })
  vim.api.nvim_set_hl(0, "HandcodeDelete", { link = M.config.hl_groups.delete, default = true })

  -- Setup HUD configurations
  local hud = require("handcode.hud")
  hud.config = M.config.hud

  -- Setup user commands
  vim.api.nvim_create_user_command("Handcode", function(args)
    local subcmd = args.fargs[1] or "toggle"
    if subcmd == "start" then
      M.start()
    elseif subcmd == "stop" then
      local restore = args.fargs[2] == "restore"
      M.stop(restore)
    elseif subcmd == "toggle" then
      M.toggle()
    elseif subcmd == "complete_line" then
      M.complete_line()
    elseif subcmd == "complete_hunk" then
      M.complete_hunk()
    elseif subcmd == "complete_file" then
      M.complete_file()
    else
      vim.notify("Handcode: Unknown subcommand. Use start, stop, toggle, complete_line, complete_hunk, complete_file", vim.log.levels.ERROR)
    end
  end, {
    nargs = "*",
    complete = function()
      return { "start", "stop", "toggle", "complete_line", "complete_hunk", "complete_file" }
    end
  })

  -- Register range completion command
  vim.api.nvim_create_user_command("HandcodeCompleteRange", function(args)
    M.complete_range(args.line1, args.line2)
  end, { range = true })
end

---Start session on current buffer
function M.start()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = require("handcode.state")
  state.start_session(bufnr)
  
  -- Bind buffer local keymaps if configured
  if M.config.keymaps.complete_hunk then
    vim.keymap.set("n", M.config.keymaps.complete_hunk, function()
      M.complete_hunk()
    end, { buffer = bufnr, desc = "Handcode: Complete current hunk" })
  end

  if M.config.keymaps.complete_file then
    vim.keymap.set("n", M.config.keymaps.complete_file, function()
      M.complete_file()
    end, { buffer = bufnr, desc = "Handcode: Complete entire file" })
  end
end

---Stop session on current buffer
---@param restore boolean? if true, resets buffer to original AI edits
function M.stop(restore)
  local bufnr = vim.api.nvim_get_current_buf()
  local state = require("handcode.state")
  
  if M.config.keymaps.complete_hunk then
    pcall(vim.keymap.del, "n", M.config.keymaps.complete_hunk, { buffer = bufnr })
  end
  if M.config.keymaps.complete_file then
    pcall(vim.keymap.del, "n", M.config.keymaps.complete_file, { buffer = bufnr })
  end

  state.stop_session(bufnr, restore or false)
end

---Toggle session on current buffer
function M.toggle()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = require("handcode.state")
  if state.sessions[bufnr] then
    M.stop(false)
  else
    M.start()
  end
end

---Complete/accept current active line
function M.complete_line()
  local state = require("handcode.state")
  state.accept_current_line()
end

---Complete active hunk at cursor position
function M.complete_hunk()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = require("handcode.state")
  local session = state.sessions[bufnr]
  if not session then return end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1 -- 0-indexed

  for _, hunk in ipairs(session.ghost_hunks) do
    if not hunk.resolved then
      local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id, hunk.extmark_id, {})
      if pos and pos[1] then
        local start_row = pos[1]
        local hunk_end = start_row + #hunk.additions
        
        if cursor_line >= start_row and cursor_line <= hunk_end then
          session.is_updating = true
          
          -- 1. Resolve deletions
          if hunk.del_extmark_id then
            local del_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id, hunk.del_extmark_id, { details = true })
            if del_pos and del_pos[1] and del_pos.details then
              vim.api.nvim_buf_set_lines(bufnr, del_pos[1], del_pos.details.end_row, false, {})
            end
            hunk.deletions = {}
          end

          -- 2. Resolve additions
          local new_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id, hunk.extmark_id, {})
          if new_pos and new_pos[1] then
            local new_start = new_pos[1]
            vim.api.nvim_buf_set_lines(bufnr, new_start, new_start + #hunk.additions, false, hunk.additions)
          end

          hunk.additions = {}
          hunk.solidified_lines = {}
          hunk.solidified_col = 0
          hunk.resolved = true
          session.is_updating = false

          vim.schedule(function()
            state.render_buffer(bufnr)
          end)
          vim.notify("Handcode: Hunk completed!", vim.log.levels.INFO)
          return
        end
      end
    end
  end
  vim.notify("Handcode: Cursor not inside a ghost hunk", vim.log.levels.WARN)
end

---Complete all ghost text in the visually selected range of lines
---@param start_line number 1-indexed
---@param end_line number 1-indexed
function M.complete_range(start_line, end_line)
  local bufnr = vim.api.nvim_get_current_buf()
  local state = require("handcode.state")
  local session = state.sessions[bufnr]
  if not session then return end

  local start_row = start_line - 1
  local end_row = end_line - 1

  session.is_updating = true
  local completed_count = 0

  for _, hunk in ipairs(session.ghost_hunks) do
    if not hunk.resolved then
      local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id, hunk.extmark_id, {})
      if pos and pos[1] then
        local start_row_hunk = pos[1]
        local end_row_hunk = start_row_hunk + #hunk.additions - 1

        -- Check if hunk range overlaps with selected range
        if not (end_row_hunk < start_row or start_row_hunk > end_row) then
          -- Resolve deletions
          if hunk.del_extmark_id then
            local del_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id, hunk.del_extmark_id, { details = true })
            if del_pos and del_pos[1] and del_pos.details then
              vim.api.nvim_buf_set_lines(bufnr, del_pos[1], del_pos.details.end_row, false, {})
            end
            hunk.deletions = {}
          end

          -- Resolve additions
          local new_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id, hunk.extmark_id, {})
          if new_pos and new_pos[1] then
            local new_start = new_pos[1]
            vim.api.nvim_buf_set_lines(bufnr, new_start, new_start + #hunk.additions, false, hunk.additions)
          end

          hunk.additions = {}
          hunk.solidified_lines = {}
          hunk.solidified_col = 0
          hunk.resolved = true
          completed_count = completed_count + 1
        end
      end
    end
  end

  session.is_updating = false

  vim.schedule(function()
    state.render_buffer(bufnr)
  end)

  if completed_count > 0 then
    vim.notify("Handcode: Range completed (" .. completed_count .. " hunks)", vim.log.levels.INFO)
  else
    vim.notify("Handcode: No ghost hunks inside selection", vim.log.levels.WARN)
  end
end

---Complete all ghost text in the current file
function M.complete_file()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = require("handcode.state")
  local session = state.sessions[bufnr]
  if not session then return end

  session.is_updating = true
  for _, hunk in ipairs(session.ghost_hunks) do
    if not hunk.resolved then
      -- Resolve deletions
      if hunk.del_extmark_id then
        local del_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id, hunk.del_extmark_id, { details = true })
        if del_pos and del_pos[1] and del_pos.details then
          vim.api.nvim_buf_set_lines(bufnr, del_pos[1], del_pos.details.end_row, false, {})
        end
        hunk.deletions = {}
      end

      -- Resolve additions
      local new_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id, hunk.extmark_id, {})
      if new_pos and new_pos[1] then
        local new_start = new_pos[1]
        vim.api.nvim_buf_set_lines(bufnr, new_start, new_start + #hunk.additions, false, hunk.additions)
      end

      hunk.additions = {}
      hunk.solidified_lines = {}
      hunk.solidified_col = 0
      hunk.resolved = true
    end
  end
  session.is_updating = false

  vim.schedule(function()
    state.render_buffer(bufnr)
  end)
  vim.notify("Handcode: File completed!", vim.log.levels.INFO)
end

return M
