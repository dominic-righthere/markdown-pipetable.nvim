-- Autocmds, attach/detach, debounced repaint, auto enter/exit, and :Pipetable.
local config = require('pipetable.config')
local parser = require('pipetable.parser')
local render = require('pipetable.render')
local state = require('pipetable.state')

local M = {}

local augroup = vim.api.nvim_create_augroup('pipetable', { clear = true })

-- Window options are shared territory. Keep ownership by window (not buffer),
-- remember the latest value written by somebody else, and only hand a value
-- back when ours is still the current value.
local WO_NAMES = { 'conceallevel', 'concealcursor', 'wrap' }
local wo_owners = {} ---@type table<integer, { buf: integer, options: table<string, { restore: any, applied: any }> }>
local wo_writing = {} ---@type table<integer, string>

---@param win integer
---@param name string
---@param value any
local function write_wo(win, name, value)
  wo_writing[win] = name
  vim.wo[win][name] = value
  wo_writing[win] = nil
end

---@param win integer
local function restore_win_wo(win)
  local owner = wo_owners[win]
  if not owner then
    return
  end
  -- Drop ownership first so our hand-back writes are not mistaken for a new
  -- external owner by the OptionSet observer.
  wo_owners[win] = nil
  wo_writing[win] = nil
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  for _, name in ipairs(WO_NAMES) do
    local option = owner.options[name]
    if option and vim.wo[win][name] == option.applied then
      write_wo(win, name, option.restore)
    end
  end
end

---@param win integer
---@return integer
function M.usable_width(win)
  local info = vim.fn.getwininfo(win)[1]
  local textoff = (info and info.textoff) or 0
  return vim.api.nvim_win_get_width(win) - textoff
end

---@param buf integer
---@return integer|nil
function M.win_for(buf)
  local cur = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(cur) and vim.api.nvim_win_get_buf(cur) == buf then
    return cur
  end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == buf then
      return w
    end
  end
  return nil
end

---Apply our window options, capturing the latest external values for restore.
---concealcursor depends on mode: rendered-through-cursor in table modes, raw in inactive.
---@param buf integer
---@param win integer
local function apply_wo(buf, win)
  local st = state.get(buf)
  local desired = {
    conceallevel = 2,
    concealcursor = (st.mode ~= 'inactive') and 'nvic' or '',
    wrap = false,
  }
  local owner = wo_owners[win]
  if owner and owner.buf ~= buf then
    restore_win_wo(win)
    owner = nil
  end
  if not owner then
    owner = { buf = buf, options = {} }
    wo_owners[win] = owner
  end
  for _, name in ipairs(WO_NAMES) do
    local current = vim.wo[win][name]
    local option = owner.options[name]
    if not option then
      option = { restore = current, applied = current }
      owner.options[name] = option
    elseif current ~= option.applied then
      -- Fallback for writes made with :noautocmd or before OptionSet is live.
      option.restore = current
    end
    option.applied = desired[name]
    write_wo(win, name, option.applied)
  end
end

---Release every window currently owned for a buffer.
---@param buf integer
function M.restore_wo(buf)
  local wins = {}
  for win, owner in pairs(wo_owners) do
    if owner.buf == buf then
      wins[#wins + 1] = win
    end
  end
  for _, win in ipairs(wins) do
    restore_win_wo(win)
  end
end

---@param buf integer
local function ensure_tables(buf)
  local st = state.get(buf)
  if st.dirty or not st.tables then
    st.tables = parser.parse_buffer(buf)
    st.dirty = false
  end
end
M.ensure_tables = ensure_tables

---Repaint every visible table, honoring the current mode.
---@param buf integer|nil
function M.refresh(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local win = M.win_for(buf)
  if not win then
    return
  end
  local opts = config.get()
  render.clear(buf)
  ensure_tables(buf)

  local st = state.get(buf)
  local tables = st.tables
  if #tables == 0 then
    -- Don't force our window options on a markdown buffer with no tables.
    M.restore_wo(buf)
    return
  end
  apply_wo(buf, win)

  local W = M.usable_width(win)
  local hl = render.hl(opts)
  local cur = vim.api.nvim_win_get_cursor(win)[1] - 1
  local top = vim.fn.line('w0', win) - 1
  local bot = vim.fn.line('w$', win) - 1

  for ti, tbl in ipairs(tables) do
    if tbl.range[2] >= top and tbl.range[1] <= bot then
      if st.mode ~= 'inactive' and st.active and st.active.ti == ti then
        local sel = (st.mode == 'table-visual') and require('pipetable.selection').range(st, tbl) or nil
        render.paint_table(buf, tbl, W, st.scroll, { row = st.active.row, col = st.active.col }, sel, opts, hl, nil)
      else
        local skip = (st.mode == 'inactive') and { [cur] = true } or nil
        render.paint_table(buf, tbl, W, { col_off = 0 }, nil, nil, opts, hl, skip)
      end
    end
  end

  -- Mode-indicator badge on the active row (right-aligned).
  if st.mode ~= 'inactive' and st.active then
    local atbl = tables[st.active.ti]
    local arow = atbl and atbl.rows[st.active.row]
    if arow and arow.lnum >= top and arow.lnum <= bot then
      local label = M.MODE_LABEL[st.mode] or 'TBL'
      vim.api.nvim_buf_set_extmark(buf, render.ns, arow.lnum, 0, {
        virt_text = { { string.format(' %s %d:%d ', label, st.active.row, st.active.col), hl.edit } },
        virt_text_pos = 'right_align',
      })
    end
  end
end

M.MODE_LABEL = {
  ['table-navigate'] = 'NAV',
  ['table-visual'] = 'VIS',
  ['in-cell'] = 'CELL',
  ['in-cell-edit'] = 'EDIT',
}

---Handle a (non-internal) cursor move: auto enter/exit and active-row sync.
---@param buf integer
function M.on_cursor(buf)
  local st = state.get(buf)
  if st.internal_move then
    st.internal_move = false
    return
  end
  local win = M.win_for(buf)
  if not win then
    return
  end
  ensure_tables(buf)
  local lnum = vim.api.nvim_win_get_cursor(win)[1] - 1
  local tbl, ti = parser.table_at(st.tables, lnum)
  local mode = require('pipetable.mode')

  if st.mode ~= 'inactive' then
    if tbl and st.active and ti == st.active.ti then
      st.active.row = require('pipetable.navigate').row_index_for_lnum(tbl, lnum)
      M.refresh(buf)
    elseif tbl then
      mode.enter(buf, tbl, ti, lnum) -- moved into a different table
    else
      mode.exit(buf)
    end
  else
    if tbl and config.get().auto_enter then
      mode.enter(buf, tbl, ti, lnum)
    else
      M.refresh(buf)
    end
  end
end

---@param buf integer
---@param fn function
local function debounce(buf, fn)
  local st = state.get(buf)
  if not st.timer then
    st.timer = vim.uv.new_timer()
  end
  st.timer:stop()
  st.timer:start(
    config.get().debounce,
    0,
    vim.schedule_wrap(function()
      if vim.api.nvim_buf_is_valid(buf) then
        fn()
      end
    end)
  )
end
M.request_redraw = function(buf)
  debounce(buf, function()
    M.refresh(buf)
  end)
end

---@param buf integer
function M.attach(buf)
  local st = state.get(buf)
  if st.attached then
    return
  end
  st.attached = true
  local opts = config.get()

  -- Cursor handling runs synchronously (not on the shared debounce timer) so
  -- auto enter/exit is never dropped, and is cheap: tables are cached and only
  -- visible tables are painted.
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = augroup,
    buffer = buf,
    callback = function()
      M.on_cursor(buf)
    end,
  })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = augroup,
    buffer = buf,
    callback = function()
      state.get(buf).dirty = true
      debounce(buf, function()
        M.refresh(buf)
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufWinEnter', 'WinScrolled' }, {
    group = augroup,
    buffer = buf,
    callback = function()
      debounce(buf, function()
        M.refresh(buf)
      end)
    end,
  })
  -- Leaving the window while navigating: drop modal state cleanly so other
  -- buffers aren't affected. (in-cell / in-cell-edit own their own teardown via
  -- the floating editor, so we only react to 'table-navigate' here.)
  vim.api.nvim_create_autocmd('BufLeave', {
    group = augroup,
    buffer = buf,
    callback = function()
      local s = state.peek(buf)
      if s and s.mode == 'table-navigate' then
        require('pipetable.mode').set_mode(buf, 'inactive')
        s.active = nil
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufWinLeave', {
    group = augroup,
    buffer = buf,
    callback = function()
      M.restore_wo(buf)
    end,
  })
  vim.api.nvim_create_autocmd('BufUnload', {
    group = augroup,
    buffer = buf,
    callback = function()
      M.restore_wo(buf)
      state.clear(buf)
    end,
  })

  -- Optional manual-enter key (normal mode).
  if type(opts.keys.enter) == 'string' then
    vim.keymap.set('n', opts.keys.enter, function()
      M.toggle()
    end, { buffer = buf, silent = true, desc = 'pipetable: enter/toggle table mode' })
  end

  debounce(buf, function()
    M.refresh(buf)
  end)
end

---Toggle table mode on the current buffer.
function M.toggle()
  local buf = vim.api.nvim_get_current_buf()
  local st = state.get(buf)
  local mode = require('pipetable.mode')
  if st.mode ~= 'inactive' then
    mode.exit(buf)
    return
  end
  ensure_tables(buf)
  if #(st.tables or {}) == 0 then
    return
  end
  local win = M.win_for(buf)
  if not win then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(win)[1] - 1
  local tbl, ti = parser.table_at(st.tables, lnum)
  if not tbl then
    tbl, ti = st.tables[1], 1
    lnum = tbl.rows[1].lnum
    vim.api.nvim_win_set_cursor(win, { lnum + 1, 0 })
  end
  mode.enter(buf, tbl, ti, lnum)
end

function M.init()
  local opts = config.get()

  vim.api.nvim_create_autocmd('OptionSet', {
    group = augroup,
    pattern = WO_NAMES,
    callback = function(ev)
      local win = vim.api.nvim_get_current_win()
      local owner = wo_owners[win]
      local name = ev.match
      if owner and owner.buf == vim.api.nvim_win_get_buf(win) and wo_writing[win] ~= name then
        local option = owner.options[name]
        if option then
          -- Reading the option is more reliable than v:option_new across the
          -- number/string/boolean option types supported by Neovim 0.10+.
          option.restore = vim.wo[win][name]
        end
      end
    end,
  })

  -- BufWinLeave is not emitted for one split if the same buffer remains visible
  -- elsewhere. BufEnter lets us release ownership when that particular window
  -- is reused for another buffer.
  vim.api.nvim_create_autocmd('BufEnter', {
    group = augroup,
    callback = function(ev)
      local win = vim.api.nvim_get_current_win()
      local owner = wo_owners[win]
      if owner and owner.buf ~= ev.buf then
        restore_win_wo(win)
      end
    end,
  })

  vim.api.nvim_create_autocmd('WinClosed', {
    group = augroup,
    callback = function(ev)
      local win = tonumber(ev.match)
      if win then
        wo_owners[win] = nil
        wo_writing[win] = nil
      end
    end,
  })

  vim.api.nvim_create_autocmd('FileType', {
    group = augroup,
    pattern = opts.filetypes,
    callback = function(ev)
      M.attach(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd('VimResized', {
    group = augroup,
    callback = function()
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        local st = state.peek(b)
        if st and st.attached then
          M.request_redraw(b)
        end
      end
    end,
  })

  vim.api.nvim_create_user_command('Pipetable', function()
    M.toggle()
  end, { desc = 'pipetable: toggle table mode' })

  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.tbl_contains(opts.filetypes, vim.bo[b].filetype) then
      M.attach(b)
    end
  end
end

return M
