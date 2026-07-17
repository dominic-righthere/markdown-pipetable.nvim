-- Per-buffer state store, keyed by bufnr.
local M = {}

local states = {}

---@param buf integer
---@return table
function M.get(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not states[buf] then
    states[buf] = {
      attached = false,
      mode = 'inactive', -- 'inactive' | 'table-navigate' | 'in-cell' | 'in-cell-edit'
      tables = nil,
      dirty = true, -- tables need (re)parsing
      active = nil, -- { ti, row, col }: ti -> tables index, row -> Table.rows index, col -> 1-based logical column
      scroll = { col_off = 0, cell_off = 0 },
      internal_move = false, -- set when WE move the cursor, so on_cursor ignores the event
      saved = {
        maps = {}, -- per-mode saved keymaps
        guicursor = nil,
        modifiable = nil,
      },
      edit = nil, -- { row, col, orig } while editing
      timer = nil,
    }
  end
  return states[buf]
end

---@param buf integer
---@return table|nil
function M.peek(buf)
  return states[buf]
end

---@param buf integer
function M.clear(buf)
  local st = states[buf]
  if st and st.timer then
    st.timer:stop()
    st.timer:close()
  end
  states[buf] = nil
end

return M
