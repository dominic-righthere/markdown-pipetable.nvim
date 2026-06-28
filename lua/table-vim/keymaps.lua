-- Buffer-local keymaps for each table mode. Prior user mappings are saved on
-- install and restored on exit, so we never permanently clobber the user's keys.
local config = require('table-vim.config')
local state = require('table-vim.state')

local M = {}

---Save the prior mapping for `lhs`, then install ours. `lhs` may be a string, a
---list of strings (multiple keys for one action), or false/nil to skip.
---@param buf integer
---@param saved table accumulator of prior mappings keyed by lhs
---@param lhs string|string[]|false|nil
---@param rhs function
local function set_map(buf, saved, lhs, rhs, desc)
  if not lhs or lhs == '' then
    return
  end
  if type(lhs) == 'table' then
    for _, k in ipairs(lhs) do
      set_map(buf, saved, k, rhs, desc)
    end
    return
  end
  saved[lhs] = vim.fn.maparg(lhs, 'n', false, true)
  vim.keymap.set('n', lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc or 'table-vim' })
end

---@param buf integer
---@param mode_name string
---@param maps table[] list of { lhs, fn, desc? }
function M.install(buf, mode_name, maps)
  local st = state.get(buf)
  st.saved.maps = st.saved.maps or {}
  local saved = {}
  for _, m in ipairs(maps) do
    set_map(buf, saved, m[1], m[2], m[3])
  end
  st.saved.maps[mode_name] = saved
end

---Remove our maps for a mode and restore any prior user mappings.
---@param buf integer
---@param mode_name string
function M.restore(buf, mode_name)
  local st = state.peek(buf)
  if not st or not st.saved.maps or not st.saved.maps[mode_name] then
    return
  end
  for lhs, prev in pairs(st.saved.maps[mode_name]) do
    pcall(vim.keymap.del, 'n', lhs, { buffer = buf })
    if prev and not vim.tbl_isempty(prev) then
      pcall(vim.fn.mapset, 'n', false, prev)
    end
  end
  st.saved.maps[mode_name] = nil
end

---Build the leader-group structural-op maps (lhs = keys.leader .. suffix).
---@param buf integer
---@return table[]
local function op_maps(buf)
  local keys = config.get().keys
  if keys.ops == false or not keys.leader then
    return {}
  end
  local ops = require('table-vim.ops')
  local L = keys.leader
  local function s(suffix)
    return suffix and (L .. suffix) or nil
  end
  local o = keys.ops
  return {
    { s(o.insert_row_below), function() ops.insert_row(buf, 'below') end, 'table: insert row below' },
    { s(o.insert_row_above), function() ops.insert_row(buf, 'above') end, 'table: insert row above' },
    { s(o.insert_col_right), function() ops.insert_col(buf, 'right') end, 'table: insert column right' },
    { s(o.insert_col_left), function() ops.insert_col(buf, 'left') end, 'table: insert column left' },
    { s(o.delete_row), function() ops.delete_row(buf) end, 'table: delete row' },
    { s(o.delete_col), function() ops.delete_col(buf) end, 'table: delete column' },
    { s(o.move_col_left), function() ops.move_col(buf, -1) end, 'table: move column left' },
    { s(o.move_col_right), function() ops.move_col(buf, 1) end, 'table: move column right' },
    { s(o.move_row_up), function() ops.move_row(buf, -1) end, 'table: move row up' },
    { s(o.move_row_down), function() ops.move_row(buf, 1) end, 'table: move row down' },
    { s(o.dup_row), function() ops.dup_row(buf) end, 'table: duplicate row' },
    { s(o.dup_col), function() ops.dup_col(buf) end, 'table: duplicate column' },
    { s(o.align_left), function() ops.set_align(buf, 'left') end, 'table: align left' },
    { s(o.align_center), function() ops.set_align(buf, 'center') end, 'table: align center' },
    { s(o.align_right), function() ops.set_align(buf, 'right') end, 'table: align right' },
    { s(o.align_default), function() ops.set_align(buf, 'default') end, 'table: align default' },
    { s(o.sort_asc), function() ops.sort(buf, false) end, 'table: sort ascending' },
    { s(o.sort_desc), function() ops.sort(buf, true) end, 'table: sort descending' },
  }
end

---Install the table-navigate keymaps.
---@param buf integer
function M.install_navigate(buf)
  local nav = config.get().keys.nav
  local navigate = require('table-vim.navigate')
  local mode = require('table-vim.mode')
  local edit = require('table-vim.edit')
  local ops = require('table-vim.ops')
  local selection = require('table-vim.selection')

  local maps = {
    { nav.left, function() navigate.move_col(buf, -1) end },
    { nav.right, function() navigate.move_col(buf, 1) end },
    { nav.up, function() navigate.move_row(buf, -1) end },
    { nav.down, function() navigate.move_row(buf, 1) end },
    { '<Left>', function() navigate.move_col(buf, -1) end },
    { '<Right>', function() navigate.move_col(buf, 1) end },
    { '<Up>', function() navigate.move_row(buf, -1) end },
    { '<Down>', function() navigate.move_row(buf, 1) end },
    { nav.first_col, function() navigate.goto_col(buf, 'first') end },
    { '0', function() navigate.goto_col(buf, 'first') end },
    { '^', function() navigate.goto_col(buf, 'first') end },
    { nav.last_col, function() navigate.goto_col(buf, 'last') end },
    { nav.first_row, function() navigate.goto_row(buf, 'first') end },
    { nav.last_row, function() navigate.goto_row(buf, 'last') end },
    { 'u', function() navigate.undo(buf, false) end },
    { '<C-r>', function() navigate.undo(buf, true) end },
    { nav.exit, function() mode.exit(buf) end },
    { nav.quit, function() mode.exit(buf) end },
    -- enter the cell: <CR> = in-cell (normal), i/a = in-cell-edit (insert)
    { nav.into_cell, function() edit.open(buf, false) end },
    { nav.edit, function() edit.open(buf, true) end },
    { nav.edit_append, function() edit.open(buf, true) end },
    -- structural direct keys
    { nav.new_row_below, function() ops.insert_row(buf, 'below') end, 'table: insert row below' },
    { nav.new_row_above, function() ops.insert_row(buf, 'above') end, 'table: insert row above' },
    { nav.delete_row, function() ops.delete_row(buf) end, 'table: delete row' },
    { nav.yank_row, function() ops.yank_row(buf) end, 'table: yank row' },
    { nav.paste_below, function() ops.paste(buf, false) end, 'table: paste below/right' },
    { nav.paste_above, function() ops.paste(buf, true) end, 'table: paste above/left' },
    -- enter visual selection
    { nav.visual_cell, function() selection.start(buf, 'cell') end, 'table: select cells' },
    { nav.visual_row, function() selection.start(buf, 'row') end, 'table: select rows' },
    { nav.visual_col, function() selection.start(buf, 'col') end, 'table: select columns' },
  }
  for _, m in ipairs(op_maps(buf)) do
    maps[#maps + 1] = m
  end
  M.install(buf, 'table-navigate', maps)
end

---Install the table-visual keymaps (selection extend + selection ops).
---@param buf integer
function M.install_visual(buf)
  local v = config.get().keys.visual
  local navigate = require('table-vim.navigate')
  local selection = require('table-vim.selection')
  local ops = require('table-vim.ops')

  M.install(buf, 'table-visual', {
    { v.left, function() navigate.move_col(buf, -1) end },
    { v.right, function() navigate.move_col(buf, 1) end },
    { v.up, function() navigate.move_row(buf, -1, true) end },
    { v.down, function() navigate.move_row(buf, 1, true) end },
    { '<Left>', function() navigate.move_col(buf, -1) end },
    { '<Right>', function() navigate.move_col(buf, 1) end },
    { '<Up>', function() navigate.move_row(buf, -1, true) end },
    { '<Down>', function() navigate.move_row(buf, 1, true) end },
    { v.first_col, function() navigate.goto_col(buf, 'first') end },
    { v.last_col, function() navigate.goto_col(buf, 'last') end },
    { v.first_row, function() navigate.goto_row(buf, 'first') end },
    { v.last_row, function() navigate.goto_row(buf, 'last') end },
    { v.switch_cell, function() selection.switch(buf, 'cell') end },
    { v.switch_row, function() selection.switch(buf, 'row') end },
    { v.switch_col, function() selection.switch(buf, 'col') end },
    { v.delete, function() ops.delete_selection(buf) end, 'table: delete selection' },
    { v.yank, function() ops.yank_selection(buf) end, 'table: yank selection' },
    { v.clear, function() ops.clear_selection(buf) end, 'table: clear selection' },
    { v.cancel, function() selection.cancel(buf) end },
  })
end

return M
