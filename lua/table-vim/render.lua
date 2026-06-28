-- Turn a parsed Table + layout into extmarks: conceal the raw line, paint a
-- fitted inline virtual line over it, and draw top/bottom box borders as
-- virtual lines. (M1 persistent path; M3 moves this into a decoration provider.)
local layout = require('table-vim.layout')
local config = require('table-vim.config')

local M = {}

M.ns = vim.api.nvim_create_namespace('table-vim')

---The fixed extmark highlight groups (appearance is set via config.highlights).
---@return table
function M.hl()
  return config.GROUPS
end

---Clear all of our extmarks in a buffer (optionally a line range).
---@param buf integer
---@param first integer|nil 0-based
---@param last integer|nil 0-based exclusive (-1 for end)
function M.clear(buf, first, last)
  vim.api.nvim_buf_clear_namespace(buf, M.ns, first or 0, last or -1)
end

---Paint a single table.
---@param buf integer
---@param tbl table
---@param W integer usable display width
---@param scroll table { col_off }
---@param active table|nil { row, col } logical active cell within this table
---@param sel table|nil selection rectangle { r1, c1, r2, c2 }
---@param opts table
---@param hl table resolved highlights
---@param skip table|nil set of 0-based line numbers to leave raw (anti-conceal)
function M.paint_table(buf, tbl, W, scroll, active, sel, opts, hl, skip)
  local plan = layout.plan(tbl, W, scroll.col_off or 0, opts)

  local rowmap = {}
  for ri, row in ipairs(tbl.rows) do
    rowmap[row.lnum] = { row = row, ri = ri }
  end

  local srow, erow = tbl.range[1], tbl.range[2]
  for lnum = srow, erow do
    if not (skip and skip[lnum]) then
      local chunks
      if lnum == tbl.delim_lnum then
        chunks = layout.rule_chunks(plan, opts, { opts.border.ml, opts.border.mm, opts.border.mr }, hl.border)
      else
        local entry = rowmap[lnum]
        if entry then
          local is_active_row = active ~= nil and active.row == entry.ri
          local focus_col = active and active.col or nil
          chunks = layout.row_chunks(tbl, entry.row, entry.ri, plan, focus_col, is_active_row, sel, opts, hl)
        end
      end

      if chunks then
        local line = vim.api.nvim_buf_get_lines(buf, lnum, lnum + 1, false)[1] or ''
        if #line > 0 then
          vim.api.nvim_buf_set_extmark(buf, M.ns, lnum, 0, { end_col = #line, conceal = '' })
        end
        -- Place the rendered text at END of the (concealed, zero-width) line so the
        -- real cursor at byte 0 renders at screen column 0 and never triggers native
        -- horizontal scroll (leftcol stays 0). See plan: horizontal scroll is synthetic.
        vim.api.nvim_buf_set_extmark(buf, M.ns, lnum, #line, {
          virt_text = chunks,
          virt_text_pos = 'inline',
        })
      end
    end
  end

  if opts.border.enabled and opts.border.style == 'full' then
    if not (skip and skip[srow]) then
      local top = layout.rule_chunks(plan, opts, { opts.border.tl, opts.border.tm, opts.border.tr }, hl.border)
      vim.api.nvim_buf_set_extmark(buf, M.ns, srow, 0, { virt_lines = { top }, virt_lines_above = true })
    end
    if not (skip and skip[erow]) then
      local bot = layout.rule_chunks(plan, opts, { opts.border.bl, opts.border.bm, opts.border.br }, hl.border)
      vim.api.nvim_buf_set_extmark(buf, M.ns, erow, 0, { virt_lines = { bot } })
    end
  end
end

return M
