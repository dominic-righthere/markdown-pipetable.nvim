-- Multi-cell selection state + table-visual entry. The selection head is always
-- the current active cell; the anchor is fixed at start. range() normalizes them.
local state = require('table-vim.state')

local M = {}

---Begin a selection of `kind` ('cell'|'row'|'col') and enter table-visual.
---@param buf integer
---@param kind string
function M.start(buf, kind)
  local st = state.get(buf)
  if not st.active then
    return
  end
  st.selection = { kind = kind, anchor = { row = st.active.row, col = st.active.col } }
  if st.mode ~= 'table-visual' then
    require('table-vim.mode').set_mode(buf, 'table-visual')
  end
  require('table-vim.manager').refresh(buf)
end

---Change the selection kind in place.
---@param buf integer
---@param kind string
function M.switch(buf, kind)
  local st = state.get(buf)
  if not st.selection then
    return M.start(buf, kind)
  end
  st.selection.kind = kind
  require('table-vim.manager').refresh(buf)
end

---Normalized selection rectangle for the current head (active) + anchor.
---@param st table
---@param tbl table
---@return table|nil { r1, c1, r2, c2, kind }
function M.range(st, tbl)
  local sel = st.selection
  if not sel or not st.active then
    return nil
  end
  local a, h = sel.anchor, st.active
  local r1, r2 = math.min(a.row, h.row), math.max(a.row, h.row)
  local c1, c2 = math.min(a.col, h.col), math.max(a.col, h.col)
  if sel.kind == 'row' then
    c1, c2 = 1, tbl.ncols
  elseif sel.kind == 'col' then
    r1, r2 = 1, #tbl.rows
  end
  return { r1 = r1, c1 = c1, r2 = r2, c2 = c2, kind = sel.kind }
end

---@param buf integer
function M.clear(buf)
  state.get(buf).selection = nil
end

---Cancel the selection and drop back to table-navigate.
---@param buf integer
function M.cancel(buf)
  local st = state.get(buf)
  st.selection = nil
  require('table-vim.mode').set_mode(buf, 'table-navigate')
  require('table-vim.manager').refresh(buf)
end

return M
