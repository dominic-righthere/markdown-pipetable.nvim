-- Parse markdown pipe-tables into a byte-accurate model.
-- Detection prefers treesitter (`pipe_table` nodes) and falls back to a regex scan.
-- Cell/pipe byte positions are always derived by scanning each line so the two
-- detection paths produce an identical model.
local config = require('table-vim.config')
local width = require('table-vim.width')

local M = {}

---0-based byte columns of every UNESCAPED '|' in `line`.
---@param line string
---@return integer[]
local function pipe_positions(line)
  local positions = {}
  local i, n = 1, #line
  while i <= n do
    local c = line:sub(i, i)
    if c == '\\' then
      i = i + 2 -- skip the escaped character
    elseif c == '|' then
      positions[#positions + 1] = i - 1 -- store 0-based byte column
      i = i + 1
    else
      i = i + 1
    end
  end
  return positions
end

---A delimiter row looks like `|:---|:--:|---:|` (only |, :, -, spaces; has a pipe and a dash).
---@param line string|nil
---@return boolean
local function is_delimiter_line(line)
  if not line then
    return false
  end
  local t = line:gsub('%s', '')
  return t ~= '' and t:find('|', 1, true) ~= nil and t:match('^[|:%-]+$') ~= nil and t:find('%-') ~= nil
end

---A table data row (canonical form: trimmed line begins with a pipe).
---@param line string|nil
---@return boolean
local function is_table_row(line)
  if not line then
    return false
  end
  local t = vim.trim(line)
  return t ~= '' and t:sub(1, 1) == '|'
end

---@param text string delimiter cell text
---@return string 'left'|'right'|'center'|'default'
local function delim_align(text)
  local left = text:match('^%s*:') ~= nil
  local right = text:match(':%s*$') ~= nil
  if left and right then
    return 'center'
  elseif right then
    return 'right'
  elseif left then
    return 'left'
  end
  return 'default'
end

---Treesitter-detected table ranges, or nil when the parser is unavailable.
---@param buf integer
---@return integer[][]|nil  list of {srow, erow} 0-based inclusive
local function ts_ranges(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, 'markdown')
  if not ok or not parser then
    return nil
  end
  local ok2, trees = pcall(function()
    return parser:parse()
  end)
  if not ok2 or not trees then
    return nil
  end
  local ok3, query = pcall(vim.treesitter.query.parse, 'markdown', '(pipe_table) @t')
  if not ok3 or not query then
    return nil
  end
  local ranges = {}
  for _, tree in ipairs(trees) do
    for _, node in query:iter_captures(tree:root(), buf, 0, -1) do
      local srow, _, erow, ecol = node:range()
      if ecol == 0 and erow > srow then
        erow = erow - 1
      end
      ranges[#ranges + 1] = { srow, erow }
    end
  end
  if #ranges == 0 then
    return nil
  end
  table.sort(ranges, function(a, b)
    return a[1] < b[1]
  end)
  return ranges
end

---Regex-scan fallback table ranges.
---@param lines string[]
---@return integer[][]  list of {srow, erow} 0-based inclusive
local function regex_ranges(lines)
  local ranges = {}
  local in_fence = false
  local i = 1
  while i <= #lines do
    local line = lines[i]
    if line:match('^%s*```') or line:match('^%s*~~~') then
      in_fence = not in_fence
      i = i + 1
    elseif
      not in_fence
      and i >= 2
      and is_delimiter_line(line)
      and is_table_row(lines[i - 1])
      and not is_delimiter_line(lines[i - 1])
    then
      local srow = i - 2 -- header line, 0-based
      local last = i -- delimiter line, 1-based
      local j = i + 1
      while j <= #lines and is_table_row(lines[j]) and not is_delimiter_line(lines[j]) do
        last = j
        j = j + 1
      end
      ranges[#ranges + 1] = { srow, last - 1 }
      i = j
    else
      i = i + 1
    end
  end
  return ranges
end

---Parse one row line into cells. Pads/truncates to `ncols`.
---@param line string
---@param lnum integer 0-based
---@param ncols integer
---@return table|nil
function M.parse_row(line, lnum, ncols)
  if not is_table_row(line) then
    return nil
  end
  local pipes = pipe_positions(line)
  if #pipes < 2 then
    return nil
  end
  local count = #pipes - 1
  local cells = {}
  for c = 1, ncols do
    if c <= count then
      local sbyte = pipes[c] + 1 -- byte col just after the left pipe (0-based)
      local ebyte = pipes[c + 1] -- byte col of the right pipe (0-based, end-exclusive)
      local raw = line:sub(sbyte + 1, ebyte)
      local text = vim.trim(raw)
      cells[c] = {
        text = text, -- trimmed, file form (may contain \|)
        raw = raw, -- exact bytes between the pipes
        sbyte = sbyte,
        ebyte = ebyte,
        width = width.width(width.unescape_pipe(text)),
      }
    else
      cells[c] = { text = '', raw = '', sbyte = nil, ebyte = nil, width = 0 }
    end
  end
  return { lnum = lnum, pipes = pipes, cells = cells }
end

---Build a Table model from a buffer line range.
---@param lines string[] full buffer (1-based Lua array)
---@param srow integer 0-based inclusive
---@param erow integer 0-based inclusive
---@return table|nil
function M.build_table(lines, srow, erow)
  local delim_lnum
  for l = srow, erow do
    if is_delimiter_line(lines[l + 1]) then
      delim_lnum = l
      break
    end
  end
  if not delim_lnum then
    return nil
  end
  local header_lnum = math.max(srow, delim_lnum - 1)
  if header_lnum < 0 then
    return nil
  end

  local dline = lines[delim_lnum + 1]
  local dpipes = pipe_positions(dline)
  if #dpipes < 2 then
    return nil
  end
  local ncols = #dpipes - 1

  local align = {}
  for c = 1, ncols do
    local seg = dline:sub(dpipes[c] + 2, dpipes[c + 1])
    align[c] = delim_align(seg)
  end

  local rows = {}
  for l = srow, erow do
    if l ~= delim_lnum then
      local row = M.parse_row(lines[l + 1], l, ncols)
      if row then
        row.kind = (l <= header_lnum) and 'header' or 'body'
        rows[#rows + 1] = row
      end
    end
  end
  if #rows == 0 then
    return nil
  end

  local cfg = config.get().column
  local widths = {}
  for c = 1, ncols do
    widths[c] = 0
  end
  for _, row in ipairs(rows) do
    for c = 1, ncols do
      local cell = row.cells[c]
      if cell then
        widths[c] = math.max(widths[c], cell.width)
      end
    end
  end
  for c = 1, ncols do
    widths[c] = math.max(cfg.min_width, math.min(cfg.max_width, widths[c]))
  end

  return {
    range = { srow, erow },
    delim_lnum = delim_lnum,
    header_lnum = header_lnum,
    ncols = ncols,
    align = align,
    widths = widths,
    rows = rows,
  }
end

---Parse all tables in a buffer.
---@param buf integer
---@return table[]
function M.parse_buffer(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  -- Regex scan is primary: it handles empty-cell rows (which treesitter-markdown
  -- terminates a table on) and reads current lines (no stale-tree after our own
  -- structural edits). Treesitter is a fallback for tables the scanner misses.
  local ranges = regex_ranges(lines)
  if #ranges == 0 then
    ranges = ts_ranges(buf) or {}
  end
  local tables = {}
  for _, r in ipairs(ranges) do
    local tbl = M.build_table(lines, r[1], r[2])
    if tbl then
      tbl.ti = #tables + 1
      tables[#tables + 1] = tbl
    end
  end
  return tables
end

---Find the table whose range contains 0-based `lnum`, plus its index.
---@param tables table[]
---@param lnum integer
---@return table|nil, integer|nil
function M.table_at(tables, lnum)
  for ti, tbl in ipairs(tables) do
    if lnum >= tbl.range[1] and lnum <= tbl.range[2] then
      return tbl, ti
    end
  end
  return nil, nil
end

return M
