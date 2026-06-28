-- The modal state machine. set_mode swaps the per-mode keymaps and manages the
-- shared "view" (non-modifiable buffer + hidden real cursor) that all table modes
-- use. It does NOT repaint — callers (enter/exit/selection) trigger a refresh.
-- (in-cell / in-cell-edit are driven by edit.lua's floating editor, not set_mode.)
local state = require('table-vim.state')
local config = require('table-vim.config')
local keymaps = require('table-vim.keymaps')

local M = {}

---@param mode string
---@return boolean
function M.is_table(mode)
  return mode ~= 'inactive'
end

---Buffer becomes non-modifiable and the real cursor is hidden while in a table.
local function set_view(buf, st)
  st.saved.modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = false
  if config.get().cursor.hide_real then
    st.saved.guicursor = vim.o.guicursor
    vim.o.guicursor = 'a:TableVimHiddenCursor'
  end
end

local function restore_view(buf, st)
  if st.saved.guicursor ~= nil then
    vim.o.guicursor = st.saved.guicursor
    st.saved.guicursor = nil
  end
  if st.saved.modifiable ~= nil then
    vim.bo[buf].modifiable = st.saved.modifiable
    st.saved.modifiable = nil
  end
end

---Transition between inactive / table-navigate / table-visual. No repaint.
---@param buf integer
---@param new string
function M.set_mode(buf, new)
  local st = state.get(buf)
  local old = st.mode
  if old == new then
    return
  end

  -- remove the old mode's keymaps
  if old == 'table-navigate' then
    keymaps.restore(buf, 'table-navigate')
  elseif old == 'table-visual' then
    keymaps.restore(buf, 'table-visual')
  end

  local was_table = old ~= 'inactive'
  local is_table = new ~= 'inactive'
  st.mode = new

  -- the shared view is set on entering any table mode and restored on leaving
  if not was_table and is_table then
    set_view(buf, st)
  elseif was_table and not is_table then
    restore_view(buf, st)
  end

  -- install the new mode's keymaps
  if new == 'table-navigate' then
    keymaps.install_navigate(buf)
  elseif new == 'table-visual' then
    keymaps.install_visual(buf)
  end
end

---Enter table-navigate on `tbl` (index `ti`), focusing the row under `lnum`.
---@param buf integer
---@param tbl table
---@param ti integer
---@param lnum integer 0-based
function M.enter(buf, tbl, ti, lnum)
  local st = state.get(buf)
  local manager = require('table-vim.manager')
  local navigate = require('table-vim.navigate')

  local row = navigate.row_index_for_lnum(tbl, lnum)
  local keep_col = (st.active and st.active.ti == ti) and st.active.col or 1
  st.active = { ti = ti, row = row, col = math.min(keep_col, tbl.ncols) }
  st.scroll.col_off = 0

  if st.mode == 'inactive' then
    M.set_mode(buf, 'table-navigate')
  elseif st.mode == 'table-visual' then
    M.set_mode(buf, 'table-navigate')
    st.selection = nil
  end

  local win = manager.win_for(buf)
  if win then
    st.internal_move = true
    vim.api.nvim_win_set_cursor(win, { tbl.rows[row].lnum + 1, 0 })
  end
  manager.refresh(buf)
end

---Leave table mode entirely, returning to inactive (still-rendered) state.
---@param buf integer
function M.exit(buf)
  local st = state.get(buf)
  if st.mode == 'inactive' then
    return
  end
  M.set_mode(buf, 'inactive')
  st.active = nil
  st.selection = nil
  require('table-vim.manager').refresh(buf)
end

return M
