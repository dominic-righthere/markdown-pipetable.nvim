-- Headless test suite for pipetable.
-- Run:  nvim --headless -u NONE -i NONE -l tests/run.lua
-- Exits non-zero if any assertion fails (used by CI).

vim.opt.runtimepath:prepend(vim.fn.getcwd())

local fails, total = 0, 0
local function ok(name, cond)
  total = total + 1
  if not cond then
    fails = fails + 1
    io.write('  FAIL  ' .. name .. '\n')
  end
end
local function eq(name, got, want)
  ok(name .. '  (got=' .. tostring(got) .. ' want=' .. tostring(want) .. ')', tostring(got) == tostring(want))
end
local function section(s)
  io.write('\n# ' .. s .. '\n')
end

local tv = require('pipetable')
tv.setup({})

local config = require('pipetable.config')
local width = require('pipetable.width')
local parser = require('pipetable.parser')
local grid = require('pipetable.grid')
local format = require('pipetable.format')
local layout = require('pipetable.layout')
local selection = require('pipetable.selection')
local state = require('pipetable.state')
local mode = require('pipetable.mode')
local manager = require('pipetable.manager')
local ops = require('pipetable.ops')
local edit = require('pipetable.edit')
local render = require('pipetable.render')

local function mkbuf(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = 'markdown'
  return b
end

-- ---------------------------------------------------------------- width
section('width')
eq('width ascii', width.width('hello'), 5)
eq('width cjk', width.width('中文'), 4)
eq('truncate ascii', width.truncate('hello world', 8, '…'), 'hello w…')
eq('fit pad left', width.fit('ab', 5, 'left'), 'ab   ')
eq('fit pad right', width.fit('ab', 5, 'right'), '   ab')
eq('escape pipe', width.escape_pipe('a|b'), 'a\\|b')
eq('escape idempotent', width.escape_pipe('a\\|b'), 'a\\|b')
eq('unescape pipe', width.unescape_pipe('a\\|b'), 'a|b')

-- ---------------------------------------------------------------- parser
section('parser')
do
  local b = mkbuf({
    '# title', '',
    '| Name | Role | Notes |',
    '|:-----|:----:|------:|',
    '| Ada  | Eng  | hi |',
    '| Bob \\| Lee | PM | x |',
  })
  local t = parser.parse_buffer(b)[1]
  eq('ncols', t.ncols, 3)
  eq('range', t.range[1] .. '-' .. t.range[2], '2-5')
  eq('align L/C/R', table.concat(t.align, ','), 'left,center,right')
  eq('rows', #t.rows, 3)
  eq('header kind', t.rows[1].kind, 'header')
  eq('escaped-pipe cell', t.rows[3].cells[1].text, 'Bob \\| Lee')
  local c = t.rows[3].cells[1]
  eq('byte slice roundtrip', vim.fn.getbufline(b, 6)[1]:sub(c.sbyte + 1, c.ebyte), ' Bob \\| Lee ')
end
do
  -- regex scanner must keep an all-empty-cell row (treesitter drops it)
  local b = mkbuf({ '| A | B |', '|---|---|', '| 1 | 2 |', '|   |   |', '| 3 | 4 |' })
  local t = parser.parse_buffer(b)[1]
  eq('empty-cell row kept', #t.rows, 4)
end

-- ---------------------------------------------------------------- grid
section('grid')
do
  local b = mkbuf({ '| Name | Age | City |', '|:--|--:|:-:|', '| Ada | 36 | LDN |', '| Bob | 8 | NYC |' })
  local t = parser.parse_buffer(b)[1]
  local g = grid.from_table(t)
  eq('grid nrows/ncols', g.nrows .. 'x' .. g.ncols, '3x3')
  eq('align preserved', table.concat(g.align, ','), 'left,right,center')

  local gi = grid.from_table(t)
  eq('insert_row at', grid.insert_row(gi, 3), 3)
  eq('insert_row nrows', gi.nrows, 4)
  eq('insert_row blank', gi.cells[3][1], '')

  local gd = grid.from_table(t)
  eq('delete body ok', tostring(grid.delete_rows(gd, 2, 2)), 'true')
  eq('delete last body refused', tostring(grid.delete_rows(gd, 2, 2)), 'false')

  local gm = grid.from_table(t)
  eq('move header noop', grid.move_row(gm, 1, 1), 1)
  eq('move row down', grid.move_row(gm, 2, 1), 3)

  local gc = grid.from_table(t)
  eq('insert_col', grid.insert_col(gc, 2), 2)
  eq('ncols after insert', gc.ncols, 4)
  eq('delete_col ok', tostring(grid.delete_col(gc, 2)), 'true')
  eq('move_col right', grid.move_col(gc, 1, 1), 2)
  eq('dup_col', grid.dup_col(gc, 1), 2)

  local g1 = grid.from_table(parser.parse_buffer(mkbuf({ '| Only |', '|---|', '| x |' }))[1])
  eq('delete last col refused', tostring(grid.delete_col(g1, 1)), 'false')

  local gs = grid.from_table(t)
  grid.sort(gs, 2, false) -- Age: Bob(8) < Ada(36)
  eq('numeric sort asc', gs.cells[2][1], 'Bob')
  grid.sort(gs, 1, true) -- Name desc
  eq('string sort desc', gs.cells[2][1], 'Bob')

  -- paste helpers
  local gp = grid.from_table(t)
  grid.insert_rows(gp, 3, { { 'x', 'y', 'z' } })
  eq('insert_rows', gp.cells[3][3], 'z')
  grid.put_block(gp, 2, 1, { { 'Q' } })
  eq('put_block', gp.cells[2][1], 'Q')
end

-- ---------------------------------------------------------------- format
section('format build_lines round-trip')
do
  local b = mkbuf({ '| Name | Age | City |', '|:-----|----:|:----:|', '| Ada | 36 | LDN |', '| Bob | 8 | NYC |' })
  local t = parser.parse_buffer(b)[1]
  local lines = format.build_lines(grid.from_table(t))
  local t2 = parser.parse_buffer(mkbuf(lines))[1]
  eq('roundtrip ncols', t2.ncols, 3)
  eq('roundtrip align', table.concat(t2.align, ','), 'left,right,center')
  eq('roundtrip cell', t2.rows[2].cells[3].text, 'LDN')
end

-- ---------------------------------------------------------------- layout
section('layout')
do
  local b = mkbuf({ '| Name | Role | Team | Loc | Notes |', '|------|------|------|-----|-------|', '| a | b | c | d | this is a long note |' })
  local t = parser.parse_buffer(b)[1]
  local opts = config.get()
  eq('plan wide shows all', #layout.plan(t, 80, 0, opts).columns, 5)
  local pn = layout.plan(t, 24, 0, opts)
  eq('plan narrow has_right', tostring(pn.has_right), 'true')
  eq('plan scrolled has_left', tostring(layout.plan(t, 30, 1, opts).has_left), 'true')
end

-- ---------------------------------------------------------------- window option ownership
section('window option ownership')
do
  local function table_buf()
    return mkbuf({ '| A | B |', '|---|---|', '| 1 | 2 |' })
  end
  local function set_wo(win, level, cursor, wrap)
    vim.wo[win].conceallevel = level
    vim.wo[win].concealcursor = cursor
    vim.wo[win].wrap = wrap
  end
  local function eq_wo(prefix, win, level, cursor, wrap)
    eq(prefix .. ' conceallevel', vim.wo[win].conceallevel, level)
    eq(prefix .. ' concealcursor', vim.wo[win].concealcursor, cursor)
    eq(prefix .. ' wrap', tostring(vim.wo[win].wrap), tostring(wrap))
  end

  -- An untouched claim returns the exact values that preceded pipetable.
  local b = table_buf()
  vim.api.nvim_set_current_buf(b)
  local win = vim.api.nvim_get_current_win()
  set_wo(win, 0, 'nc', true)
  manager.refresh(b)
  eq_wo('options applied', win, 2, '', false)
  manager.restore_wo(b)
  eq_wo('originals restored', win, 0, 'nc', true)

  -- Changing pipetable's own desired value must not replace the hand-back value.
  set_wo(win, 0, 'nc', true)
  manager.refresh(b)
  state.get(b).mode = 'table-navigate'
  manager.refresh(b)
  eq('active concealcursor applied', vim.wo[win].concealcursor, 'nvic')
  manager.restore_wo(b)
  eq_wo('mode change preserves originals', win, 0, 'nc', true)
  state.get(b).mode = 'inactive'

  -- Later writers win, even when they change away and back to the value that
  -- pipetable last wrote (the case compare-and-restore alone cannot detect).
  set_wo(win, 0, 'nc', true)
  manager.refresh(b)
  set_wo(win, 3, 'v', true)
  vim.wo[win].conceallevel = 2
  manager.restore_wo(b)
  eq_wo('external values preserved', win, 2, 'v', true)

  -- If pipetable refreshes after an external write, it may temporarily reclaim
  -- the options but must hand the latest external values back on release.
  set_wo(win, 0, 'nc', true)
  manager.refresh(b)
  set_wo(win, 3, 'v', true)
  manager.refresh(b)
  eq_wo('options reclaimed', win, 2, '', false)
  manager.restore_wo(b)
  eq_wo('latest values handed back', win, 3, 'v', true)

  -- Removing the last table releases every claimed option immediately.
  set_wo(win, 1, 'c', true)
  manager.refresh(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { '# no tables' })
  state.get(b).dirty = true
  manager.refresh(b)
  eq_wo('no-table release', win, 1, 'c', true)

  -- Each split keeps its own baseline. Reusing one window for another buffer
  -- restores only that window, even while the table remains visible elsewhere.
  local split_buf = table_buf()
  vim.api.nvim_set_current_buf(split_buf)
  local win1 = vim.api.nvim_get_current_win()
  set_wo(win1, 0, 'nc', true)
  manager.refresh(split_buf)

  vim.cmd('vnew')
  local win2 = vim.api.nvim_get_current_win()
  local other = vim.api.nvim_get_current_buf()
  vim.bo[other].buftype = 'nofile'
  set_wo(win2, 1, 'v', true)
  vim.api.nvim_win_set_buf(win2, split_buf)
  manager.refresh(split_buf)
  eq_wo('second window applied', win2, 2, '', false)
  vim.api.nvim_win_set_buf(win2, other)
  eq_wo('reused window restored', win2, 1, 'v', true)
  eq_wo('first window still owned', win1, 2, '', false)

  -- Closing an owned split discards only its dead-window record.
  vim.api.nvim_win_set_buf(win2, split_buf)
  manager.refresh(split_buf)
  vim.api.nvim_set_current_win(win1)
  vim.api.nvim_win_close(win2, true)
  ok('restore after owned window closes', pcall(manager.restore_wo, split_buf))
  eq_wo('remaining window restored', win1, 0, 'nc', true)
end

-- ---------------------------------------------------------------- selection.range
section('selection.range')
do
  local b = mkbuf({ '| A | B | C |', '|---|---|---|', '| 1 | 2 | 3 |', '| 4 | 5 | 6 |' })
  local t = parser.parse_buffer(b)[1]
  local st = state.get(b)
  st.active = { ti = 1, row = 2, col = 1 }
  st.selection = { kind = 'cell', anchor = { row = 2, col = 1 } }
  st.active.row, st.active.col = 3, 2
  local r = selection.range(st, t)
  eq('cell range', r.r1 .. r.c1 .. r.r2 .. r.c2, '2132')
  st.selection.kind = 'row'
  eq('row spans cols', selection.range(st, t).c2, t.ncols)
  st.selection.kind = 'col'
  eq('col spans rows', selection.range(st, t).r2, #t.rows)
end

-- ---------------------------------------------------------------- ops (buffer integration)
section('ops')
do
  local function fresh()
    local b = mkbuf({ '| Name | Age | City |', '|------|-----|------|', '| Ada | 36 | LDN |', '| Bob | 8 | NYC |', '| Cy | 51 | SF |' })
    vim.api.nvim_set_current_buf(b)
    manager.ensure_tables(b)
    mode.enter(b, state.get(b).tables[1], 1, state.get(b).tables[1].rows[2].lnum)
    return b
  end
  local function L(b) return vim.api.nvim_buf_get_lines(b, 0, -1, false) end

  local b = fresh()
  state.get(b).active.row = 2
  ops.insert_row(b, 'below')
  eq('insert_row +1 line', #L(b), 6)

  b = fresh(); state.get(b).active.row = 3
  ops.delete_row(b)
  eq('delete_row -1 line', #L(b), 4)

  b = fresh(); state.get(b).active.col = 2
  ops.delete_col(b)
  eq('delete_col header has 2 cols', select(2, L(b)[1]:gsub('|', '|')), 3)

  b = fresh(); state.get(b).active.col = 1
  ops.set_align(b, 'center')
  eq('align center delimiter', vim.trim(L(b)[2]:match('^|([^|]+)|')):match('^:.*:$') ~= nil and 'yes' or 'no', 'yes')

  b = fresh(); state.get(b).active.col = 2
  ops.sort(b, false)
  eq('sort by Age asc first body', L(b)[3]:match('| (%a+)'), 'Bob')
end

-- ---------------------------------------------------------------- edit write-back
section('edit write-back')
do
  local function setup(hl_edit)
    config.setup({ highlights = hl_edit and { edit = hl_edit } or nil })
    config.setup_highlights()
    local b = mkbuf({ '| A | B |', '|---|---|', '| 1 | 2 |' })
    vim.api.nvim_set_current_buf(b)
    manager.ensure_tables(b)
    mode.enter(b, state.get(b).tables[1], 1, state.get(b).tables[1].rows[2].lnum)
    return b
  end
  local b = setup()
  state.get(b).active.col = 1
  ok('edit.open string-edit-hl', pcall(edit.open, b, false))
  vim.api.nvim_buf_set_lines(state.get(b).edit.ebuf, 0, -1, false, { 'a|b' })
  edit.commit(b, false)
  eq('write-back escapes pipe', vim.api.nvim_buf_get_lines(b, 2, 3, false)[1], '| a\\|b | 2 |')

  -- regression: highlights.edit as a SPEC TABLE must not crash edit.open
  local b2 = setup({ ctermbg = 3, cterm = { reverse = true } })
  state.get(b2).active.col = 1
  ok('edit.open table-edit-hl (no crash)', pcall(edit.open, b2, false))
  if state.get(b2).edit then edit.cancel(b2) end
  config.setup({}) -- restore defaults
  config.setup_highlights()
end

-- ---------------------------------------------------------------- highlights
section('highlights')
do
  config.setup({})
  config.setup_highlights()
  eq('cursor_cell reverse default', tostring(vim.api.nvim_get_hl(0, { name = 'PipetableCursorCell' }).reverse), 'true')
  config.setup({ highlights = { cursor_cell = { bg = '#ff0000' } } })
  config.setup_highlights()
  local h = vim.api.nvim_get_hl(0, { name = 'PipetableCursorCell' })
  eq('custom bg applied', string.format('#%06x', h.bg or 0), '#ff0000')
  eq('reverse dropped (spec replaces)', tostring(h.reverse), 'nil')
  config.setup({ highlights = { border = 'WarningMsg' } })
  config.setup_highlights()
  eq('link applied', vim.api.nvim_get_hl(0, { name = 'PipetableBorder' }).link, 'WarningMsg')
  config.setup({})
  config.setup_highlights()
end

-- ---------------------------------------------------------------- csv
section('csv')
do
  local csv = require('pipetable.csv')
  local rows = csv.parse('a,b,c\n1,2,3')
  eq('parse rows', #rows, 2)
  eq('parse cell', rows[2][3], '3')
  local q = csv.parse('x,"a,b","he said ""hi"""')
  eq('quoted embedded comma', q[1][2], 'a,b')
  eq('quoted escaped quote', q[1][3], 'he said "hi"')
  eq('quoted embedded newline', csv.parse('"l1\nl2",y')[1][1], 'l1\nl2')

  eq('detect comma', csv.detect_delim('a,b,c'), ',')
  eq('detect tab', csv.detect_delim('a\tb\tc') == '\t' and 'tab' or 'no', 'tab')
  eq('detect semicolon', csv.detect_delim('a;b;c'), ';')

  eq('to_csv plain', csv.to_csv({ { 'a', 'b' } }), 'a,b')
  eq('to_csv quotes comma', csv.to_csv({ { 'a,b', 'c' } }), '"a,b",c')
  eq('to_csv doubles quote', csv.to_csv({ { 'a"b' } }), '"a""b"')

  local md = csv.to_markdown('Name,Age\nAda,36\nBob,8')
  eq('md header has cols', (md[1]:match('Name') and md[1]:match('Age')) and 'y' or 'n', 'y')
  eq('md delimiter row', md[2]:match('^|%s*%-') and 'y' or 'n', 'y')
  eq('md line count (hdr+delim+2)', #md, 4)
  eq('md escapes pipe', csv.to_markdown('h\na|b')[3]:match('\\|') and 'y' or 'n', 'y')

  -- from_markdown round-trip
  local t = parser.parse_buffer(mkbuf({ '| Name | Age |', '|------|-----|', '| Ada | 36 |', '| Bob | 8 |' }))[1]
  local rt = csv.parse(csv.from_markdown(t, ','))
  eq('roundtrip header', rt[1][1] .. ',' .. rt[1][2], 'Name,Age')
  eq('roundtrip body', rt[3][1] .. ',' .. rt[3][2], 'Bob,8')

  -- :TableFromCSV command on a range
  local cb = mkbuf({ 'Name,Age', 'Ada,36', 'Bob,8' })
  vim.api.nvim_set_current_buf(cb)
  vim.cmd('1,3TableFromCSV')
  local cl = vim.api.nvim_buf_get_lines(cb, 0, -1, false)
  eq('FromCSV made a table', cl[1]:match('|%s*Name') and 'y' or 'n', 'y')
  eq('FromCSV line count', #cl, 4)
end

-- ---------------------------------------------------------------- summary
io.write(string.format('\n%d/%d passed, %d failed\n', total - fails, total, fails))
os.exit(fails > 0 and 1 or 0)
