local M = {}

---@class handcode.Hunk
---@field del_start number 1-indexed start line of deletion in original file
---@field del_len number number of deleted lines
---@field add_start number 1-indexed start line of addition in new file
---@field add_len number number of added lines
---@field deletions string[] deleted lines content
---@field additions string[] added lines content

---Parse git diff -U0 output
---@param diff_lines string[]
---@return handcode.Hunk[]
function M.parse_diff(diff_lines)
  local hunks = {}
  local current_hunk = nil

  for _, line in ipairs(diff_lines) do
    if line:match("^@@") then
      local del_start_str, del_len_str, add_start_str, add_len_str =
        line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")

      if del_start_str then
        local del_start = tonumber(del_start_str)
        local del_len = tonumber(del_len_str)
        if not del_len then
          del_len = (del_len_str == "" and 1 or 0)
        end

        local add_start = tonumber(add_start_str)
        local add_len = tonumber(add_len_str)
        if not add_len then
          add_len = (add_len_str == "" and 1 or 0)
        end

        current_hunk = {
          del_start = del_start,
          del_len = del_len,
          add_start = add_start,
          add_len = add_len,
          deletions = {},
          additions = {},
        }
        table.insert(hunks, current_hunk)
      end
    elseif current_hunk then
      local prefix = line:sub(1, 1)
      if prefix == "-" then
        table.insert(current_hunk.deletions, line:sub(2))
      elseif prefix == "+" then
        table.insert(current_hunk.additions, line:sub(2))
      end
    end
  end

  return hunks
end

---Get diff for a file using git
---@param filepath string
---@return handcode.Hunk[]?
function M.get_file_diff(filepath)
  -- First check if we're in a git repo
  local git_root = vim.fn.systemlist({ "git", "rev-parse", "--show-toplevel" })
  if vim.v.shell_error ~= 0 then
    return nil
  end

  -- Check if the file is untracked
  local status = vim.fn.systemlist({ "git", "status", "--porcelain", filepath })
  if #status > 0 and status[1]:match("^%?%?") then
    -- Untracked file: the entire file is an addition!
    local lines = vim.fn.readfile(filepath)
    if #lines == 0 then return nil end  -- empty file
    return {
      {
        del_start = 1,
        del_len = 0,
        add_start = 1,
        add_len = #lines,
        deletions = {},
        additions = lines,
      }
    }
  end

  -- Run git diff -U0 --relative
  local cmd = { "git", "diff", "-U0", "--relative", filepath }
  local output = vim.fn.systemlist(cmd)

  if vim.v.shell_error ~= 0 then
    return nil
  end

  local hunks = M.parse_diff(output)
  if not hunks or #hunks == 0 then
    return nil
  end

  return hunks
end

return M
