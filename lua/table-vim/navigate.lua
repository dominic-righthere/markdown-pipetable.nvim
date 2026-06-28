-- Logical cell movement and horizontal scroll-follow.
-- Movement updates state.active (+ scroll), parks the real cursor on the active
-- row's buffer line, and asks the manager to repaint.
local state = require('table-vim.state')
local config = require('table-vim.config')
local layout = require('table-vim.layout')

local M = {}

---Map a 0-based buffer line to a row index within the table (delimiter -> nearest row).
---@param tbl table
---@param lnum integer 0-based
---@return integer
function M.row_index_for_lnum(tbl, lnum)
  for i, row in ipairs(tbl.rows) do
    if row.lnum == lnum then
      return i
    end
  end
  for i, row in ipairs(tbl.rows) do
    if row.lnum >= lnum then
      return i
    end
  end
  return #tbl.rows
end

---@param buf integer
---@return table st, integer|nil win, table|nil tbl, table manager
local function ctx(buf)
  local manager = require('table-vim.manager')
  local st = state.get(buf)
  local win = manager.win_for(buf)
  local tbl = (st.active and st.tables) and st.tables[st.active.ti] or nil
  return st, win, tbl, manager
end

---Adjust the horizontal scroll offset so the active column is fully visible.
---@param buf integer
---@param tbl table
---@param W integer usable width
function M.ensure_visible(buf, tbl, W)
  local st = state.get(buf)
  local opts = config.get()
  local col = st.active.col
  if col <= st.scroll.col_off then
    st.scroll.col_off = col - 1
  else
    local guard = 0
    while
      col > layout.last_full_col(tbl, W, st.scroll.col_off, opts)
      and st.scroll.col_off < tbl.ncols - 1
    do
      st.scroll.col_off = st.scroll.col_off + 1
      guard = guard + 1
      if guard > tbl.ncols then
        break
      end
    end
  end
  if st.scroll.col_off < 0 then
    st.scroll.col_off = 0
  end
end

---@param buf integer
---@param delta integer
function M.move_col(buf, delta)
  local st, win, tbl, manager = ctx(buf)
  if not (st.active and tbl and win) then
    return
  end
  st.active.col = math.max(1, math.min(tbl.ncols, st.active.col + delta))
  M.ensure_visible(buf, tbl, manager.usable_width(win))
  manager.refresh(buf)
end

---@param buf integer
---@param delta integer
---@param no_exit boolean|nil clamp at the edge instead of leaving the table (visual mode)
function M.move_row(buf, delta, no_exit)
  local st, win, tbl, manager = ctx(buf)
  if not (st.active and tbl and win) then
    return
  end
  local new = st.active.row + delta
  if new < 1 or new > #tbl.rows then
    if no_exit then
      return
    end
    -- Stepping off the top/bottom edge leaves the table in that direction.
    require('table-vim.mode').exit(buf)
    local target = vim.api.nvim_win_get_cursor(win)[1] + delta
    target = math.max(1, math.min(vim.api.nvim_buf_line_count(buf), target))
    vim.api.nvim_win_set_cursor(win, { target, 0 })
    return
  end
  st.active.row = new
  st.internal_move = true
  vim.api.nvim_win_set_cursor(win, { tbl.rows[new].lnum + 1, 0 })
  manager.refresh(buf)
end

---@param buf integer
---@param which 'first'|'last'
function M.goto_row(buf, which)
  local st, win, tbl, manager = ctx(buf)
  if not (st.active and tbl and win) then
    return
  end
  st.active.row = (which == 'first') and 1 or #tbl.rows
  st.internal_move = true
  vim.api.nvim_win_set_cursor(win, { tbl.rows[st.active.row].lnum + 1, 0 })
  manager.refresh(buf)
end

---Undo/redo from within table-navigate (the buffer is non-modifiable in this mode).
---@param buf integer
---@param redo boolean
function M.undo(buf, redo)
  local st = state.get(buf)
  local manager = require('table-vim.manager')
  local was = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  pcall(vim.cmd, redo and 'redo' or 'undo')
  vim.bo[buf].modifiable = was
  st.dirty = true
  manager.ensure_tables(buf)

  local win = manager.win_for(buf)
  if not win then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(win)[1] - 1
  local tbl, ti = require('table-vim.parser').table_at(st.tables, lnum)
  if tbl and st.active then
    st.active.ti = ti
    st.active.row = M.row_index_for_lnum(tbl, lnum)
    st.active.col = math.min(st.active.col, tbl.ncols)
    st.internal_move = true
    vim.api.nvim_win_set_cursor(win, { tbl.rows[st.active.row].lnum + 1, 0 })
    manager.refresh(buf)
  else
    require('table-vim.mode').exit(buf)
  end
end

---@param buf integer
---@param which 'first'|'last'
function M.goto_col(buf, which)
  local st, win, tbl, manager = ctx(buf)
  if not (st.active and tbl and win) then
    return
  end
  st.active.col = (which == 'first') and 1 or tbl.ncols
  M.ensure_visible(buf, tbl, manager.usable_width(win))
  manager.refresh(buf)
end

return M
