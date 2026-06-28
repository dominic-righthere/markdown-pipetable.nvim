-- Pure 2D table model + structural mutations. The grid is the unit of edit:
-- a mutation runs here, then format.build_lines/write turns it back into aligned
-- markdown lines in a single buffer write. Cell text is FILE form (may contain \|).
-- Row 1 is always the header.
local width = require('table-vim.width')

local M = {}

---@param tbl table parsed Table
---@return table grid { cells[r][c]=string, align[c], nrows, ncols }
function M.from_table(tbl)
  local cells = {}
  for r, row in ipairs(tbl.rows) do
    cells[r] = {}
    for c = 1, tbl.ncols do
      local cell = row.cells[c]
      cells[r][c] = (cell and cell.text) or ''
    end
  end
  local align = {}
  for c = 1, tbl.ncols do
    align[c] = tbl.align[c] or 'default'
  end
  return { cells = cells, align = align, nrows = #tbl.rows, ncols = tbl.ncols }
end

local function blank_row(ncols)
  local r = {}
  for c = 1, ncols do
    r[c] = ''
  end
  return r
end

---Insert a blank body row before index `at` (clamped to >= 2 so never above the header).
---@return integer at the index of the new row
function M.insert_row(g, at)
  at = math.max(2, math.min(at, g.nrows + 1))
  table.insert(g.cells, at, blank_row(g.ncols))
  g.nrows = g.nrows + 1
  return at
end

---Delete body rows [from,to] (clamped to body; keeps >= 1 body row).
---@return boolean ok
function M.delete_rows(g, from, to)
  from = math.max(2, from)
  to = math.min(to or from, g.nrows)
  if to < from then
    return false
  end
  local count = to - from + 1
  if g.nrows - count < 2 then
    return false -- would remove the last body row
  end
  for _ = from, to do
    table.remove(g.cells, from)
  end
  g.nrows = g.nrows - count
  return true
end

---Move body row `r` by `dir` (+1 down / -1 up). Header is fixed.
---@return integer new row index
function M.move_row(g, r, dir)
  if r <= 1 then
    return r
  end
  local nr = r + dir
  if nr <= 1 or nr > g.nrows then
    return r
  end
  g.cells[r], g.cells[nr] = g.cells[nr], g.cells[r]
  return nr
end

---Duplicate row `r` directly below it (clamped into the body).
---@return integer index of the copy
function M.dup_row(g, r)
  if r < 1 or r > g.nrows then
    return r
  end
  local copy = {}
  for c = 1, g.ncols do
    copy[c] = g.cells[r][c]
  end
  local at = math.max(2, r + 1)
  table.insert(g.cells, at, copy)
  g.nrows = g.nrows + 1
  return at
end

---Insert a blank column before index `at`.
---@return integer at
function M.insert_col(g, at)
  at = math.max(1, math.min(at, g.ncols + 1))
  for r = 1, g.nrows do
    table.insert(g.cells[r], at, '')
  end
  table.insert(g.align, at, 'default')
  g.ncols = g.ncols + 1
  return at
end

---Delete column `c` (keeps >= 1 column).
---@return boolean ok
function M.delete_col(g, c)
  if g.ncols <= 1 or c < 1 or c > g.ncols then
    return false
  end
  for r = 1, g.nrows do
    table.remove(g.cells[r], c)
  end
  table.remove(g.align, c)
  g.ncols = g.ncols - 1
  return true
end

---Move column `c` by `dir` (+1 right / -1 left).
---@return integer new column index
function M.move_col(g, c, dir)
  local nc = c + dir
  if nc < 1 or nc > g.ncols then
    return c
  end
  for r = 1, g.nrows do
    g.cells[r][c], g.cells[r][nc] = g.cells[r][nc], g.cells[r][c]
  end
  g.align[c], g.align[nc] = g.align[nc], g.align[c]
  return nc
end

---Duplicate column `c` directly to its right.
---@return integer index of the copy
function M.dup_col(g, c)
  local at = c + 1
  for r = 1, g.nrows do
    table.insert(g.cells[r], at, g.cells[r][c])
  end
  table.insert(g.align, at, g.align[c])
  g.ncols = g.ncols + 1
  return at
end

---@param a string 'left'|'center'|'right'|'default'
function M.set_align(g, c, a)
  if c >= 1 and c <= g.ncols then
    g.align[c] = a
  end
end

local function cell_num(s)
  return tonumber((vim.trim(width.unescape_pipe(s or ''))))
end

---Sort the body rows by column `c`. Numeric when every non-empty value parses as
---a number; otherwise case-insensitive string compare. `desc` reverses.
function M.sort(g, c, desc)
  local body = {}
  for r = 2, g.nrows do
    body[#body + 1] = g.cells[r]
  end
  local numeric = true
  for _, row in ipairs(body) do
    local s = vim.trim(width.unescape_pipe(row[c] or ''))
    if s ~= '' and cell_num(row[c]) == nil then
      numeric = false
      break
    end
  end
  table.sort(body, function(a, b)
    local av, bv
    if numeric then
      av, bv = cell_num(a[c]) or 0, cell_num(b[c]) or 0
    else
      av = vim.trim(width.unescape_pipe(a[c] or '')):lower()
      bv = vim.trim(width.unescape_pipe(b[c] or '')):lower()
    end
    if desc then
      return av > bv
    end
    return av < bv
  end)
  for i, row in ipairs(body) do
    g.cells[i + 1] = row
  end
end

---Empty the cells in the inclusive rectangle.
function M.clear(g, r1, c1, r2, c2)
  for r = r1, r2 do
    if g.cells[r] then
      for c = c1, c2 do
        g.cells[r][c] = ''
      end
    end
  end
end

---Insert body rows (each padded/truncated to ncols) before index `at` (>= 2).
---@return integer at index of the first inserted row
function M.insert_rows(g, at, rows2d)
  at = math.max(2, math.min(at, g.nrows + 1))
  for i = #rows2d, 1, -1 do
    local src = rows2d[i]
    local row = {}
    for c = 1, g.ncols do
      row[c] = src[c] or ''
    end
    table.insert(g.cells, at, row)
    g.nrows = g.nrows + 1
  end
  return at
end

---Insert columns before index `at`. `cols2d` is rows×C; values are taken as
---cols2d[row][k], padded/truncated to the grid's row count.
---@return integer at index of the first inserted column
function M.insert_cols(g, at, cols2d)
  at = math.max(1, math.min(at, g.ncols + 1))
  local C = (cols2d[1] and #cols2d[1]) or 0
  for k = C, 1, -1 do
    for r = 1, g.nrows do
      table.insert(g.cells[r], at, (cols2d[r] and cols2d[r][k]) or '')
    end
    table.insert(g.align, at, 'default')
    g.ncols = g.ncols + 1
  end
  return at
end

---Overwrite cells starting at (r0,c0) with `block2d`, clipped to the table.
function M.put_block(g, r0, c0, block2d)
  for i, brow in ipairs(block2d) do
    local r = r0 + i - 1
    if r >= 1 and r <= g.nrows then
      for j, val in ipairs(brow) do
        local c = c0 + j - 1
        if c >= 1 and c <= g.ncols then
          g.cells[r][c] = val
        end
      end
    end
  end
end

---Copy out an inclusive rectangle as a standalone grid-ish { cells, nrows, ncols }.
function M.slice(g, r1, c1, r2, c2)
  local cells = {}
  for r = r1, r2 do
    local row = {}
    for c = c1, c2 do
      row[#row + 1] = (g.cells[r] and g.cells[r][c]) or ''
    end
    cells[#cells + 1] = row
  end
  return { cells = cells, nrows = r2 - r1 + 1, ncols = c2 - c1 + 1 }
end

return M
