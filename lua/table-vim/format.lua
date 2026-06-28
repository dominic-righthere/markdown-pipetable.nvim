-- Turn a grid (see grid.lua) into aligned, portable GFM lines, and write them
-- back to the buffer. Used by structural ops and by `format_on_edit` reformatting.
local width = require('table-vim.width')

local M = {}

---Aligned `| … |` lines for a grid: header (row 1), delimiter, then body rows.
---Column widths are measured on the FILE form (so escaped pipes `\|` and
---double-width glyphs stay aligned in the source).
---@param g table grid { cells, align, nrows, ncols }
---@return string[]
function M.build_lines(g)
  local w = {}
  for c = 1, g.ncols do
    w[c] = 3
  end
  for r = 1, g.nrows do
    for c = 1, g.ncols do
      w[c] = math.max(w[c], width.width(g.cells[r][c] or ''))
    end
  end

  local function row_line(r)
    local parts = {}
    for c = 1, g.ncols do
      local side = g.align[c]
      if side == 'default' then
        side = 'left'
      end
      parts[c] = width.align(g.cells[r][c] or '', w[c], side)
    end
    return '| ' .. table.concat(parts, ' | ') .. ' |'
  end

  local lines = { row_line(1) }

  local segs = {}
  for c = 1, g.ncols do
    local n, a = w[c], g.align[c]
    if a == 'center' then
      segs[c] = ':' .. string.rep('-', math.max(1, n - 2)) .. ':'
    elseif a == 'left' then
      segs[c] = ':' .. string.rep('-', math.max(1, n - 1))
    elseif a == 'right' then
      segs[c] = string.rep('-', math.max(1, n - 1)) .. ':'
    else
      segs[c] = string.rep('-', n)
    end
  end
  lines[#lines + 1] = '| ' .. table.concat(segs, ' | ') .. ' |'

  for r = 2, g.nrows do
    lines[#lines + 1] = row_line(r)
  end
  return lines
end

---Replace a table's buffer lines with the rendered grid (one undo step).
---@param buf integer
---@param range integer[] { srow, erow } 0-based inclusive (the OLD table extent)
---@param g table grid
function M.write(buf, range, g)
  local lines = M.build_lines(g)
  local was = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, range[1], range[2] + 1, false, lines)
  vim.bo[buf].modifiable = was
end

---Repad a parsed table's source so all columns align (format_on_edit).
---@param buf integer
---@param tbl table
function M.reformat(buf, tbl)
  M.write(buf, tbl.range, require('table-vim.grid').from_table(tbl))
end

return M
