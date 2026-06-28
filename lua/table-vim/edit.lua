-- Cell editing via a small floating editor anchored over the active cell.
-- The float's native modes map onto our table modes:
--   float normal mode  = in-cell      (move within the cell with vim motions)
--   float insert mode  = in-cell-edit (type to change the cell)
-- Commit writes the value back into the raw markdown via nvim_buf_set_text.
local state = require('table-vim.state')
local config = require('table-vim.config')
local layout = require('table-vim.layout')
local width = require('table-vim.width')

local M = {}

---Screen column where the active cell's content begins (0-based from line start).
local function cell_screen_col(plan, opts, active_col)
  local pad = opts.column.padding
  local x = 1 -- left border
  for _, col in ipairs(plan.columns) do
    if col.idx == active_col then
      return x + pad
    end
    x = x + pad * 2 + col.width + 1
  end
  return x
end

local function show_cursor(st)
  if config.get().cursor.hide_real and st.saved.guicursor ~= nil then
    vim.o.guicursor = st.saved.guicursor
  end
end

local function hide_cursor(st)
  if config.get().cursor.hide_real then
    vim.o.guicursor = 'a:TableVimHiddenCursor'
  end
end

---@param buf integer
---@param start_insert boolean enter insert (in-cell-edit) immediately
function M.open(buf, start_insert)
  local st = state.get(buf)
  if not st.active then
    return
  end
  local manager = require('table-vim.manager')
  local tbl = st.tables[st.active.ti]
  local row = tbl and tbl.rows[st.active.row]
  local cell = row and row.cells[st.active.col]
  if not cell or not cell.sbyte then
    vim.notify('table-vim: this cell cannot be edited', vim.log.levels.WARN)
    return
  end
  local win = manager.win_for(buf)
  if not win then
    return
  end

  local opts = config.get()
  local value = width.unescape_pipe(cell.text)
  local plan = layout.plan(tbl, manager.usable_width(win), st.scroll.col_off, opts)
  local scol = cell_screen_col(plan, opts, st.active.col)

  local cw
  for _, c in ipairs(plan.columns) do
    if c.idx == st.active.col then
      cw = c.width
    end
  end
  local ewidth = math.max(8, vim.fn.strdisplaywidth(value) + 1, cw or 0)

  local ebuf = vim.api.nvim_create_buf(false, true)
  vim.bo[ebuf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(ebuf, 0, -1, false, { value })

  -- Claim the mode BEFORE opening (focus leaves buf -> BufLeave must not tear down).
  st.mode = 'in-cell-edit'
  st.edit = { row = st.active.row, col = st.active.col, orig = value, ebuf = ebuf }

  local ewin = vim.api.nvim_open_win(ebuf, true, {
    relative = 'cursor',
    row = 0,
    col = scol,
    width = ewidth,
    height = 1,
    style = 'minimal',
    border = 'none',
  })
  st.edit.ewin = ewin
  vim.wo[ewin].winhighlight = 'Normal:' .. opts.highlights.edit
  vim.wo[ewin].wrap = false
  show_cursor(st)

  local kopts = { buffer = ebuf, nowait = true, silent = true }
  vim.keymap.set({ 'n', 'i' }, '<CR>', function() M.commit(buf, false) end, kopts)
  vim.keymap.set({ 'n', 'i' }, '<Tab>', function() M.commit(buf, true) end, kopts)
  vim.keymap.set('n', '<Esc>', function() M.commit(buf, false) end, kopts)
  vim.keymap.set('n', 'q', function() M.cancel(buf) end, kopts)

  -- Track in-cell vs in-cell-edit for the mode indicator.
  vim.api.nvim_create_autocmd('ModeChanged', {
    buffer = ebuf,
    callback = function()
      if not st.edit then
        return
      end
      st.mode = (vim.api.nvim_get_mode().mode:sub(1, 1) == 'i') and 'in-cell-edit' or 'in-cell'
    end,
  })

  -- Safety: if the float is closed by anything other than commit/cancel.
  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(ewin),
    once = true,
    callback = function()
      if st.edit and st.edit.ewin == ewin then
        M.cancel(buf)
      end
    end,
  })

  if start_insert then
    vim.cmd('startinsert!')
  else
    st.mode = 'in-cell'
  end
end

---Return focus + modal state to table-navigate.
local function back_to_navigate(buf, st)
  -- The float may have been in insert mode; closing it from an insert-mode
  -- mapping would otherwise leave the parent buffer in insert mode.
  vim.cmd('stopinsert')
  st.mode = 'table-navigate'
  hide_cursor(st)
  local manager = require('table-vim.manager')
  local win = manager.win_for(buf)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  end
end

---@param buf integer
---@param move_next boolean commit then advance to the next column and keep editing
function M.commit(buf, move_next)
  local st = state.get(buf)
  local e = st.edit
  if not e then
    return
  end
  st.edit = nil -- claim before closing (WinClosed safety becomes a no-op)

  local value = vim.trim(table.concat(vim.api.nvim_buf_get_lines(e.ebuf, 0, -1, false), ' '))
  if e.ewin and vim.api.nvim_win_is_valid(e.ewin) then
    vim.api.nvim_win_close(e.ewin, true)
  end

  local manager = require('table-vim.manager')
  local tbl = st.tables[st.active.ti]
  local row = tbl and tbl.rows[e.row]
  local cell = row and row.cells[e.col]
  if cell and cell.sbyte then
    local pad = string.rep(' ', config.get().column.padding)
    local text = pad .. width.escape_pipe(value) .. pad
    local was = vim.bo[buf].modifiable
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_text(buf, row.lnum, cell.sbyte, row.lnum, cell.ebyte, { text })
    vim.bo[buf].modifiable = was
    st.dirty = true
  end

  back_to_navigate(buf, st)
  manager.ensure_tables(buf)

  if config.get().format_on_edit then
    local ftbl = st.tables[st.active.ti]
    if ftbl then
      require('table-vim.format').reformat(buf, ftbl)
      st.dirty = true
      manager.ensure_tables(buf)
    end
  end

  if move_next then
    local newtbl = st.tables[st.active.ti]
    local win = manager.win_for(buf)
    if newtbl and st.active.col < newtbl.ncols and win then
      st.active.col = st.active.col + 1
      require('table-vim.navigate').ensure_visible(buf, newtbl, manager.usable_width(win))
    else
      move_next = false
    end
  end

  manager.refresh(buf)
  if move_next then
    M.open(buf, true)
  end
end

---@param buf integer
function M.cancel(buf)
  local st = state.get(buf)
  local e = st.edit
  if not e then
    return
  end
  st.edit = nil
  if e.ewin and vim.api.nvim_win_is_valid(e.ewin) then
    vim.api.nvim_win_close(e.ewin, true)
  end
  back_to_navigate(buf, st)
  require('table-vim.manager').refresh(buf)
end

return M
