--- handcode/detect.lua
--- Detection layer: watches for AI-written file changes and triggers Handcode sessions.
--- Priority order:
---   1. OpencodeEvent:file.edited  (opencode.nvim SSE, per-file, immediate)
---   2. OpencodeEvent:session.status idle  (opencode.nvim, end-of-turn sweep)
---   3. vim.uv.fs_event  (libuv watcher, generic fallback for any AI tool)
---   4. BufEnter / FocusGained  (last resort, requires user focus switch)

local M = {}

---@type table<number, uv_fs_event_t>  bufnr -> active watcher handle
local watchers = {}

---Attempt to start a Handcode session on bufnr if it has new diff and no active session.
---@param bufnr number
local function try_start(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  if not vim.api.nvim_buf_is_loaded(bufnr) then return end

  local state = require("handcode.state")
  if state.sessions[bufnr] then return end -- already active

  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then return end
  
  -- Check if file exists on disk
  if vim.fn.filereadable(filepath) == 0 then return end

  local hunks = require("handcode.diff").get_file_diff(filepath)
  if hunks and #hunks > 0 then
    vim.notify("Handcode: detected changes in " .. vim.fn.fnamemodify(filepath, ":t"), vim.log.levels.INFO)
    require("handcode").start(bufnr)
  end
end

---Register a libuv fs_event watcher for a buffer's file.
---Fires try_start when the file is modified on disk.
---@param bufnr number
function M.watch_buf(bufnr)
  if watchers[bufnr] then return end -- already watching

  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then return end

  local handle = vim.uv.new_fs_event()
  if not handle then return end

  local ok, err = handle:start(filepath, {}, vim.schedule_wrap(function(fs_err, _, events)
    if fs_err then return end
    if not (events and events.change) then return end
    -- Small defer so that :checktime / autoread can reload the buffer first
    vim.defer_fn(function()
      try_start(bufnr)
    end, 60)
  end))

  if not ok then
    handle:stop()
    return
  end

  watchers[bufnr] = handle
end

---Stop and remove the fs_event watcher for a buffer.
---@param bufnr number
function M.unwatch_buf(bufnr)
  local handle = watchers[bufnr]
  if not handle then return end
  pcall(function() handle:stop() end)
  watchers[bufnr] = nil
end

---Setup all detection methods according to config.
---Called once from init.lua setup().
---@param config table  M.config from init.lua
function M.setup(config)
  local det = config.detection or {}
  local group = vim.api.nvim_create_augroup("HandcodeDetect", { clear = true })

  -- ── 1. opencode.nvim: per-file write event ──────────────────────────────
  if det.opencode_events ~= false then
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "OpencodeEvent:file.edited",
      desc = "Handcode: start session after opencode file edit",
      callback = function(args)
        -- Extract the filepath from the event data if available
        local edited_file = args.data and args.data.event 
          and args.data.event.properties 
          and args.data.event.properties.file

        -- Defer so opencode.nvim's :checktime reload runs first
        vim.defer_fn(function()
          -- If we know which file was edited, ensure buffer is loaded
          if edited_file and vim.fn.filereadable(edited_file) == 1 then
            local target_bufnr = vim.fn.bufnr(edited_file)
            
            if target_bufnr == -1 then
              -- Buffer doesn't exist yet - create it
              target_bufnr = vim.fn.bufadd(edited_file)
              vim.fn.bufload(target_bufnr)
              
              -- Only auto-switch if configured to do so
              if det.auto_follow then
                vim.cmd("buffer " .. target_bufnr)
              end
            elseif not vim.api.nvim_buf_is_loaded(target_bufnr) then
              -- Buffer exists but isn't loaded
              vim.fn.bufload(target_bufnr)
            end
            
            -- Try to start handcode on this buffer after a small delay
            vim.defer_fn(function()
              try_start(target_bufnr)
            end, 100)
          end
          
          -- Also try the current buffer
          local bufnr = vim.api.nvim_get_current_buf()
          try_start(bufnr)
          
          -- Scan all other loaded buffers for changes
          for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if b ~= bufnr and vim.api.nvim_buf_is_loaded(b) then
              try_start(b)
            end
          end
        end, 200)
      end,
    })

    -- ── 2. opencode.nvim: end-of-turn sweep ───────────────────────────────
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "OpencodeEvent:session.status",
      desc = "Handcode: sweep all buffers when opencode goes idle",
      callback = function(args)
        local event = args.data and args.data.event
        if not event then return end
        local status = event.properties
          and event.properties.status
          and event.properties.status.type
        if status ~= "idle" then return end

        vim.schedule(function()
          for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(b) then
              try_start(b)
            end
          end
        end)
      end,
    })
  end

  -- ── 3. libuv fs_event watcher: start watching on BufEnter ───────────────
  if det.fs_watch ~= false then
    vim.api.nvim_create_autocmd({ "BufEnter", "BufAdd" }, {
      group = group,
      desc = "Handcode: register fs_event watcher for buffer",
      callback = function(ev)
        local bufnr = ev.buf
        if vim.api.nvim_buf_get_name(bufnr) ~= "" then
          M.watch_buf(bufnr)
        end
      end,
    })

    -- Clean up watchers when buffers are unloaded
    vim.api.nvim_create_autocmd({ "BufUnload", "BufDelete" }, {
      group = group,
      desc = "Handcode: remove fs_event watcher on buffer unload",
      callback = function(ev)
        M.unwatch_buf(ev.buf)
      end,
    })
  end

  -- ── 4. BufEnter / FocusGained fallback ──────────────────────────────────
  if det.buf_enter ~= false then
    vim.api.nvim_create_autocmd({ "BufEnter", "FocusGained" }, {
      group = group,
      desc = "Handcode: fallback check on focus/buffer switch",
      callback = function(ev)
        vim.defer_fn(function()
          local bufnr = ev.buf ~= 0 and ev.buf or vim.api.nvim_get_current_buf()
          try_start(bufnr)
        end, 150)
      end,
    })
  end
end

return M
