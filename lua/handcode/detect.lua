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
local try_start

---@param filepath string
---@return string
local function normalize_path(filepath)
  return vim.fn.fnamemodify(filepath, ":p")
end

---@param filepath string
---@return number
local function find_or_load_buf(filepath)
  local target = normalize_path(filepath)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name ~= "" and normalize_path(name) == target then
      if not vim.api.nvim_buf_is_loaded(bufnr) then
        vim.fn.bufload(bufnr)
      end
      return bufnr
    end
  end

  local bufnr = vim.fn.bufadd(target)
  vim.fn.bufload(bufnr)
  return bufnr
end

---@param bufnr number
local function checktime(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  pcall(vim.cmd, "silent! checktime " .. bufnr)
end

---@param event table?
---@return string?
local function event_filepath(event)
  local props = event and event.properties or nil
  if not props then return nil end

  for _, key in ipairs({ "file", "path", "filepath", "filePath" }) do
    local value = props[key]
    if type(value) == "string" and value ~= "" then
      return value
    end
    if type(value) == "table" then
      for _, nested_key in ipairs({ "path", "absolute", "filename", "name" }) do
        local nested = value[nested_key]
        if type(nested) == "string" and nested ~= "" then
          return nested
        end
      end
    end
  end

  return nil
end

---@param filepath string
---@return string
local function resolve_event_filepath(filepath)
  if filepath:sub(1, 1) == "/" then
    return filepath
  end

  local ok, server_mod = pcall(require, "opencode.server")
  local connected = ok and server_mod.connected or nil
  if connected and connected.cwd and connected.cwd ~= "" then
    return connected.cwd:gsub("/$", "") .. "/" .. filepath
  end

  return filepath
end

---@return string[]
local function scan_roots()
  local roots = { vim.fn.getcwd() }
  local ok, server_mod = pcall(require, "opencode.server")
  local connected = ok and server_mod.connected or nil
  if connected and connected.cwd and connected.cwd ~= "" then
    table.insert(roots, connected.cwd)
  end
  return roots
end

---@param cwd string?
local function scan_changed_files(cwd)
  local diff = require("handcode.diff")
  for _, filepath in ipairs(diff.list_changed_files(cwd)) do
    local bufnr = find_or_load_buf(filepath)
    checktime(bufnr)
    try_start(bufnr)
  end
end

---Attempt to start a Handcode session on bufnr if it has new diff and no active session.
---@param bufnr number
function try_start(bufnr)
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
    require("handcode").start(bufnr)
  end
end

M.try_start = try_start

---Register a libuv fs_event watcher for a buffer's file.
---Fires try_start when the file is modified on disk.
---@param bufnr number
function M.watch_buf(bufnr)
  if watchers[bufnr] then return end -- already watching

  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then return end

  local handle = vim.uv.new_fs_event()
  if not handle then return end

  local ok = handle:start(filepath, {}, vim.schedule_wrap(function(fs_err, _, events)
    if fs_err then return end
    if not (events and events.change) then return end
    checktime(bufnr)
    vim.defer_fn(function()
      try_start(bufnr)
    end, 60)
  end))

  if not ok then
    pcall(function() handle:stop() end)
    pcall(function() handle:close() end)
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
  pcall(function() handle:close() end)
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
        local edited_file = event_filepath(args.data and args.data.event)
        if edited_file then
          edited_file = resolve_event_filepath(edited_file)
        end

        -- Defer so opencode.nvim's :checktime reload runs first
        vim.schedule(function()
          -- If we know which file was edited, ensure buffer is loaded
          if edited_file and vim.fn.filereadable(edited_file) == 1 then
            local target_bufnr = find_or_load_buf(edited_file)
            checktime(target_bufnr)

            if det.auto_follow then
              vim.api.nvim_set_current_buf(target_bufnr)
            end

            -- Try to start handcode on this buffer after a small delay
            vim.defer_fn(function()
              try_start(target_bufnr)
            end, 30)
          end

          for _, root in ipairs(scan_roots()) do
            scan_changed_files(root)
          end

          -- Also try the current buffer
          local bufnr = vim.api.nvim_get_current_buf()
          checktime(bufnr)
          try_start(bufnr)

          -- Scan all other loaded buffers for changes
          for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if b ~= bufnr and vim.api.nvim_buf_is_loaded(b) then
              checktime(b)
              try_start(b)
            end
          end
        end)
      end,
    })

    -- ── 2. opencode.nvim: end-of-turn sweep ───────────────────────────────
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = { "OpencodeEvent:session.status", "OpencodeEvent:session.idle" },
      desc = "Handcode: sweep all buffers when opencode goes idle",
      callback = function(args)
        local event = args.data and args.data.event
        if not event then return end
        local status = event.properties
          and event.properties.status
          and event.properties.status.type
        if event.type ~= "session.idle" and status ~= "idle" then return end

        vim.schedule(function()
          for _, root in ipairs(scan_roots()) do
            scan_changed_files(root)
          end

          for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(b) then
              checktime(b)
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

    vim.schedule(function()
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) and vim.api.nvim_buf_get_name(bufnr) ~= "" then
          M.watch_buf(bufnr)
        end
      end
    end)
  end

  -- ── 4. BufEnter / FocusGained fallback ──────────────────────────────────
  if det.buf_enter ~= false then
    vim.api.nvim_create_autocmd({ "BufEnter", "FocusGained" }, {
      group = group,
      desc = "Handcode: fallback check on focus/buffer switch",
      callback = function(ev)
        vim.defer_fn(function()
          local bufnr = ev.buf and ev.buf ~= 0 and ev.buf or vim.api.nvim_get_current_buf()
          checktime(bufnr)
          try_start(bufnr)
        end, 150)
      end,
    })
  end
end

return M
