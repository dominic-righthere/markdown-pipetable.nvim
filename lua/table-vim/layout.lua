-- Pure viewport math: decide which columns are visible for a given width and
-- horizontal offset, and build the per-line virtual-text chunk lists.
-- No side effects, no extmarks here.
local width = require('table-vim.width')

local M = {}

---Decide the visible columns for usable width `W` and horizontal offset `col_off`
---(number of columns scrolled off the left). The last visible column may be a
---truncated partial column. Reserves one cell for the right overflow indicator.
---@param tbl table
---@param W integer usable display width
---@param col_off integer 0-based count of hidden left columns
---@param opts table resolved config
---@return table { columns = {{idx,width,truncated}}, has_left, has_right, start }
function M.plan(tbl, W, col_off, opts)
  local pad = opts.column.padding
  local ncols = tbl.ncols
  local start = math.max(1, math.min(col_off + 1, ncols))
  local min_vis = opts.overflow.min_visible

  local columns = {}
  local budget = W - 1 -- left border (or ‹)
  local i = start
  while i <= ncols do
    local cw = tbl.widths[i]
    local seg = pad * 2 + cw
    local reserve = (i < ncols) and 1 or 0 -- keep a cell for › if more columns remain
    if budget - (seg + 1) >= reserve then
      columns[#columns + 1] = { idx = i, width = cw, truncated = false }
      budget = budget - (seg + 1)
      i = i + 1
    else
      local avail_cw = budget - 1 - pad * 2
      if avail_cw >= min_vis then
        columns[#columns + 1] = { idx = i, width = avail_cw, truncated = true }
      end
      break
    end
  end

  local last = columns[#columns]
  local has_right
  if not last then
    has_right = start <= ncols
  else
    has_right = last.truncated or last.idx < ncols
  end

  return { columns = columns, has_left = start > 1, has_right = has_right, start = start }
end

---Largest column index that is fully (not truncated) visible for this offset.
---Used by scroll-follow to keep the focused cell complete.
---@param tbl table
---@param W integer
---@param col_off integer
---@param opts table
---@return integer
function M.last_full_col(tbl, W, col_off, opts)
  local plan = M.plan(tbl, W, col_off, opts)
  local last_full = col_off -- nothing fully visible -> below start
  for _, col in ipairs(plan.columns) do
    if not col.truncated then
      last_full = col.idx
    end
  end
  return last_full
end

---Build the chunk list for a data row, applying crosshair + selection highlights.
---Chunks may use a LIST of groups (`{ text, { base, tint } }`) so a cell keeps
---its own fg while gaining the row/column/selection background (later wins).
---@param tbl table
---@param row table
---@param ri integer row index within tbl.rows (1 = header)
---@param plan table
---@param focus_col integer|nil the active logical column
---@param is_active_row boolean whether this row holds the cell cursor
---@param sel table|nil selection rectangle { r1, c1, r2, c2 }
---@param opts table
---@param hl table fixed highlight group names
---@return table[] list of { text, hlgroup }
function M.row_chunks(tbl, row, ri, plan, focus_col, is_active_row, sel, opts, hl)
  local pad = opts.column.padding
  local padstr = string.rep(' ', pad)
  local rowhl = (row.kind == 'header') and hl.header or hl.cell
  local row_tint = is_active_row and opts.cursor.row_highlight
  local col_tint = opts.cursor.column_highlight
  local in_sel = sel ~= nil and ri >= sel.r1 and ri <= sel.r2
  local out = {}

  -- A border following column `after` is selection-tinted when between two
  -- selected columns, else picks up the active-row tint.
  local function bg(group, after)
    if in_sel and after >= sel.c1 and after < sel.c2 then
      return { group, hl.selection }
    end
    if row_tint then
      return { group, hl.cursor_row }
    end
    return group
  end

  if plan.has_left then
    out[#out + 1] = { opts.overflow.left, bg(hl.overflow, 0) }
  else
    out[#out + 1] = { opts.border.vert, bg(hl.border, 0) }
  end

  for k, col in ipairs(plan.columns) do
    local cell = row.cells[col.idx]
    local value = cell and width.unescape_pipe(cell.text) or ''
    local side = tbl.align[col.idx]
    if side == 'default' then
      side = 'left'
    end
    local content = width.fit(value, col.width, side, opts.overflow.ellipsis)

    local selected = in_sel and col.idx >= sel.c1 and col.idx <= sel.c2
    local cellhl
    if is_active_row and focus_col == col.idx then
      cellhl = hl.cursor_cell -- the focused cell (head) wins outright
    elseif selected then
      cellhl = { rowhl, hl.selection }
    elseif row_tint then
      cellhl = { rowhl, hl.cursor_row }
    elseif col_tint and focus_col == col.idx then
      cellhl = { rowhl, hl.cursor_col }
    else
      cellhl = rowhl
    end
    out[#out + 1] = { padstr .. content .. padstr, cellhl }

    if k < #plan.columns then
      out[#out + 1] = { opts.border.vert, bg(hl.border, col.idx) }
    elseif plan.has_right then
      out[#out + 1] = { opts.overflow.right, bg(hl.overflow, col.idx) }
    else
      out[#out + 1] = { opts.border.vert, bg(hl.border, col.idx) }
    end
  end

  if #plan.columns == 0 then
    out[#out + 1] = plan.has_right and { opts.overflow.right, hl.overflow } or { opts.border.vert, hl.border }
  end

  return out
end

---Build a horizontal rule (top / middle / bottom border) chunk list.
---@param plan table
---@param opts table
---@param chars string[] { left, cross, right }
---@param hlgroup string
---@return table[]
function M.rule_chunks(plan, opts, chars, hlgroup)
  local pad = opts.column.padding
  local horiz = opts.border.horiz
  local out = { { chars[1], hlgroup } }
  for k, col in ipairs(plan.columns) do
    out[#out + 1] = { string.rep(horiz, pad * 2 + col.width), hlgroup }
    out[#out + 1] = { (k < #plan.columns) and chars[2] or chars[3], hlgroup }
  end
  if #plan.columns == 0 then
    out[#out + 1] = { chars[3], hlgroup }
  end
  return out
end

return M
