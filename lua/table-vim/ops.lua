-- Structural table operations: mutate the grid, rewrite the table's lines in one
-- buffer write (single undo step), reparse, and reposition the active cell.
local grid = require('table-vim.grid')
local config = require('table-vim.config')

local M = {}

local function notify(msg)
  vim.notify('table-vim: ' .. msg, vim.log.levels.WARN)
end

---Resolve the table to operate on. Uses the active cell when in table mode,
---otherwise derives it from the cursor (so :Table* commands work anywhere).
---@param buf integer
---@return table|nil st, table|nil tbl
local function resolve(buf)
  local state = require('table-vim.state')
  local manager = require('table-vim.manager')
  local st = state.get(buf)
  manager.ensure_tables(buf)
  if st.active and st.tables and st.tables[st.active.ti] then
    return st, st.tables[st.active.ti]
  end
  local win = manager.win_for(buf)
  if not win then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(win)[1] - 1
  local tbl, ti = require('table-vim.parser').table_at(st.tables or {}, lnum)
  if not tbl then
    return nil
  end
  st.active = st.active or {}
  st.active.ti = ti
  st.active.row = require('table-vim.navigate').row_index_for_lnum(tbl, lnum)
  st.active.col = math.min(st.active.col or 1, tbl.ncols)
  return st, tbl
end

---Write the mutated grid back, reparse, and move the active cell to (new_row, new_col).
---@param buf integer
---@param tbl table the pre-mutation parsed table (for its range)
---@param g table mutated grid
---@param new_row integer|nil
---@param new_col integer|nil
local function apply(buf, tbl, g, new_row, new_col)
  local state = require('table-vim.state')
  local manager = require('table-vim.manager')
  local navigate = require('table-vim.navigate')

  require('table-vim.format').write(buf, tbl.range, g)

  local st = state.get(buf)
  st.dirty = true
  manager.ensure_tables(buf)

  local newtbl = st.tables[st.active.ti]
  if not newtbl then
    return
  end
  st.active.row = math.max(1, math.min(new_row or st.active.row, #newtbl.rows))
  st.active.col = math.max(1, math.min(new_col or st.active.col, newtbl.ncols))

  local win = manager.win_for(buf)
  if win then
    st.internal_move = true
    vim.api.nvim_win_set_cursor(win, { newtbl.rows[st.active.row].lnum + 1, 0 })
    navigate.ensure_visible(buf, newtbl, manager.usable_width(win))
  end
  manager.refresh(buf)
end

---@param buf integer
---@param where 'above'|'below'
function M.insert_row(buf, where)
  local st, tbl = resolve(buf)
  if not st then return end
  local g = grid.from_table(tbl)
  local at = (where == 'above') and st.active.row or (st.active.row + 1)
  apply(buf, tbl, g, grid.insert_row(g, at), st.active.col)
end

---@param buf integer
function M.delete_row(buf)
  local st, tbl = resolve(buf)
  if not st then return end
  if st.active.row == 1 then
    return notify('cannot delete the header row')
  end
  local g = grid.from_table(tbl)
  if not grid.delete_rows(g, st.active.row, st.active.row) then
    return notify('cannot delete the last body row')
  end
  apply(buf, tbl, g, math.min(st.active.row, g.nrows), st.active.col)
end

---@param buf integer
---@param dir -1|1 up|down
function M.move_row(buf, dir)
  local st, tbl = resolve(buf)
  if not st then return end
  local g = grid.from_table(tbl)
  local nr = grid.move_row(g, st.active.row, dir)
  if nr == st.active.row then return end
  apply(buf, tbl, g, nr, st.active.col)
end

---@param buf integer
function M.dup_row(buf)
  local st, tbl = resolve(buf)
  if not st then return end
  local g = grid.from_table(tbl)
  apply(buf, tbl, g, grid.dup_row(g, st.active.row), st.active.col)
end

---@param buf integer
---@param where 'left'|'right'
function M.insert_col(buf, where)
  local st, tbl = resolve(buf)
  if not st then return end
  local g = grid.from_table(tbl)
  local at = (where == 'left') and st.active.col or (st.active.col + 1)
  apply(buf, tbl, g, st.active.row, grid.insert_col(g, at))
end

---@param buf integer
function M.delete_col(buf)
  local st, tbl = resolve(buf)
  if not st then return end
  local g = grid.from_table(tbl)
  if not grid.delete_col(g, st.active.col) then
    return notify('cannot delete the last column')
  end
  apply(buf, tbl, g, st.active.row, math.min(st.active.col, g.ncols))
end

---@param buf integer
---@param dir -1|1 left|right
function M.move_col(buf, dir)
  local st, tbl = resolve(buf)
  if not st then return end
  local g = grid.from_table(tbl)
  local nc = grid.move_col(g, st.active.col, dir)
  if nc == st.active.col then return end
  apply(buf, tbl, g, st.active.row, nc)
end

---@param buf integer
function M.dup_col(buf)
  local st, tbl = resolve(buf)
  if not st then return end
  local g = grid.from_table(tbl)
  apply(buf, tbl, g, st.active.row, grid.dup_col(g, st.active.col))
end

---@param buf integer
---@param a 'left'|'center'|'right'|'default'
function M.set_align(buf, a)
  local st, tbl = resolve(buf)
  if not st then return end
  local g = grid.from_table(tbl)
  grid.set_align(g, st.active.col, a)
  apply(buf, tbl, g, st.active.row, st.active.col)
end

---@param buf integer
---@param desc boolean
function M.sort(buf, desc)
  local st, tbl = resolve(buf)
  if not st then return end
  local g = grid.from_table(tbl)
  grid.sort(g, st.active.col, desc)
  apply(buf, tbl, g, st.active.row, st.active.col)
end

---Delete the current selection: rows→drop rows, cols→drop columns, cells→clear.
---@param buf integer
function M.delete_selection(buf)
  local selection = require('table-vim.selection')
  local st, tbl = resolve(buf)
  if not st then return end
  local rng = selection.range(st, tbl)
  if not rng then return end
  local g = grid.from_table(tbl)

  if rng.kind == 'col' then
    local removed = false
    for c = rng.c2, rng.c1, -1 do
      if grid.delete_col(g, c) then
        removed = true
      end
    end
    if not removed then
      return notify('cannot delete the last column')
    end
    selection.clear(buf)
    require('table-vim.mode').set_mode(buf, 'table-navigate')
    apply(buf, tbl, g, st.active.row, math.min(rng.c1, g.ncols))
  elseif rng.kind == 'row' then
    local from = math.max(2, rng.r1)
    if not grid.delete_rows(g, from, rng.r2) then
      return notify('cannot delete those rows (header / last body protected)')
    end
    selection.clear(buf)
    require('table-vim.mode').set_mode(buf, 'table-navigate')
    apply(buf, tbl, g, math.min(from, g.nrows), st.active.col)
  else
    grid.clear(g, rng.r1, rng.c1, rng.r2, rng.c2)
    selection.clear(buf)
    require('table-vim.mode').set_mode(buf, 'table-navigate')
    apply(buf, tbl, g, st.active.row, st.active.col)
  end
end

---Clear the contents of the selected cells (keeps structure).
---@param buf integer
function M.clear_selection(buf)
  local selection = require('table-vim.selection')
  local st, tbl = resolve(buf)
  if not st then return end
  local rng = selection.range(st, tbl)
  if not rng then return end
  local g = grid.from_table(tbl)
  grid.clear(g, rng.r1, rng.c1, rng.r2, rng.c2)
  selection.clear(buf)
  require('table-vim.mode').set_mode(buf, 'table-navigate')
  apply(buf, tbl, g, st.active.row, st.active.col)
end

-- Internal register holds the structured cells for in-table paste.
---@type table|nil { kind = 'row'|'col'|'cell', cells = string[][] }
M.register = nil

local function to_tsv(cells)
  local width = require('table-vim.width')
  local rows = {}
  for _, r in ipairs(cells) do
    local cols = {}
    for _, v in ipairs(r) do
      cols[#cols + 1] = width.unescape_pipe(vim.trim(v))
    end
    rows[#rows + 1] = table.concat(cols, '\t')
  end
  return table.concat(rows, '\n')
end

local function set_clipboard(cells)
  local text = to_tsv(cells)
  pcall(vim.fn.setreg, '"', text)
  if config.get().clipboard then
    pcall(vim.fn.setreg, '+', text)
  end
end

---Yank the current row.
---@param buf integer
function M.yank_row(buf)
  local st, tbl = resolve(buf)
  if not st then return end
  local g = grid.from_table(tbl)
  local sub = grid.slice(g, st.active.row, 1, st.active.row, g.ncols)
  M.register = { kind = 'row', cells = sub.cells }
  set_clipboard(sub.cells)
  vim.notify('table-vim: yanked row', vim.log.levels.INFO)
end

---Yank the current selection (kind = selection kind).
---@param buf integer
function M.yank_selection(buf)
  local selection = require('table-vim.selection')
  local st, tbl = resolve(buf)
  if not st then return end
  local rng = selection.range(st, tbl)
  if not rng then return end
  local sub = grid.slice(grid.from_table(tbl), rng.r1, rng.c1, rng.r2, rng.c2)
  M.register = { kind = rng.kind, cells = sub.cells }
  set_clipboard(sub.cells)
  selection.clear(buf)
  require('table-vim.mode').set_mode(buf, 'table-navigate')
  require('table-vim.manager').refresh(buf)
  vim.notify(string.format('table-vim: yanked %s', rng.kind), vim.log.levels.INFO)
end

---Paste the register. Row→insert rows, col→insert cols, cell→overwrite block.
---@param buf integer
---@param before boolean above/left when true, below/right when false
function M.paste(buf, before)
  local st, tbl = resolve(buf)
  if not st then return end
  local reg = M.register
  if not reg then
    return notify('nothing to paste (yank a row/column/selection first)')
  end
  local g = grid.from_table(tbl)
  if reg.kind == 'row' then
    local at = grid.insert_rows(g, before and st.active.row or (st.active.row + 1), reg.cells)
    apply(buf, tbl, g, at, st.active.col)
  elseif reg.kind == 'col' then
    local at = grid.insert_cols(g, before and st.active.col or (st.active.col + 1), reg.cells)
    apply(buf, tbl, g, st.active.row, at)
  else
    grid.put_block(g, st.active.row, st.active.col, reg.cells)
    apply(buf, tbl, g, st.active.row, st.active.col)
  end
end

-- exposed for reuse / tests
M._apply = apply
M._resolve = resolve

return M
