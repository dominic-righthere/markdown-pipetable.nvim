-- Global escape hatches: <Plug> mappings (bind your own keys) and :Table*
-- commands (usable outside table mode — they resolve the table at the cursor).
local M = {}

local function buf()
  return vim.api.nvim_get_current_buf()
end

-- name -> action; exposed as <Plug>(table-vim-<name>)
local PLUGS = {
  ['insert-row-below'] = function() require('table-vim.ops').insert_row(buf(), 'below') end,
  ['insert-row-above'] = function() require('table-vim.ops').insert_row(buf(), 'above') end,
  ['insert-col-right'] = function() require('table-vim.ops').insert_col(buf(), 'right') end,
  ['insert-col-left'] = function() require('table-vim.ops').insert_col(buf(), 'left') end,
  ['delete-row'] = function() require('table-vim.ops').delete_row(buf()) end,
  ['delete-col'] = function() require('table-vim.ops').delete_col(buf()) end,
  ['move-row-up'] = function() require('table-vim.ops').move_row(buf(), -1) end,
  ['move-row-down'] = function() require('table-vim.ops').move_row(buf(), 1) end,
  ['move-col-left'] = function() require('table-vim.ops').move_col(buf(), -1) end,
  ['move-col-right'] = function() require('table-vim.ops').move_col(buf(), 1) end,
  ['dup-row'] = function() require('table-vim.ops').dup_row(buf()) end,
  ['dup-col'] = function() require('table-vim.ops').dup_col(buf()) end,
  ['align-left'] = function() require('table-vim.ops').set_align(buf(), 'left') end,
  ['align-center'] = function() require('table-vim.ops').set_align(buf(), 'center') end,
  ['align-right'] = function() require('table-vim.ops').set_align(buf(), 'right') end,
  ['align-default'] = function() require('table-vim.ops').set_align(buf(), 'default') end,
  ['sort-asc'] = function() require('table-vim.ops').sort(buf(), false) end,
  ['sort-desc'] = function() require('table-vim.ops').sort(buf(), true) end,
  ['yank-row'] = function() require('table-vim.ops').yank_row(buf()) end,
  ['paste-below'] = function() require('table-vim.ops').paste(buf(), false) end,
  ['paste-above'] = function() require('table-vim.ops').paste(buf(), true) end,
}

function M.setup()
  for name, fn in pairs(PLUGS) do
    vim.keymap.set('n', '<Plug>(table-vim-' .. name .. ')', fn, { desc = 'table-vim ' .. name })
  end

  local cmd = vim.api.nvim_create_user_command
  local ops = function() return require('table-vim.ops') end

  cmd('TableInsertRow', function(a) ops().insert_row(buf(), a.bang and 'above' or 'below') end,
    { bang = true, desc = 'table-vim: insert row (! = above)' })
  cmd('TableDeleteRow', function() ops().delete_row(buf()) end, { desc = 'table-vim: delete row' })
  cmd('TableInsertColumn', function(a) ops().insert_col(buf(), a.bang and 'left' or 'right') end,
    { bang = true, desc = 'table-vim: insert column (! = left)' })
  cmd('TableDeleteColumn', function() ops().delete_col(buf()) end, { desc = 'table-vim: delete column' })
  cmd('TableMoveColumn', function(a) ops().move_col(buf(), a.args == 'left' and -1 or 1) end,
    { nargs = 1, complete = function() return { 'left', 'right' } end, desc = 'table-vim: move column' })
  cmd('TableMoveRow', function(a) ops().move_row(buf(), a.args == 'up' and -1 or 1) end,
    { nargs = 1, complete = function() return { 'up', 'down' } end, desc = 'table-vim: move row' })
  cmd('TableAlign', function(a) ops().set_align(buf(), a.args ~= '' and a.args or 'default') end,
    { nargs = 1, complete = function() return { 'left', 'center', 'right', 'default' } end, desc = 'table-vim: set column alignment' })
  cmd('TableSort', function(a) ops().sort(buf(), a.bang) end,
    { bang = true, desc = 'table-vim: sort by current column (! = descending)' })
  cmd('TableYank', function() ops().yank_row(buf()) end, { desc = 'table-vim: yank row' })
  cmd('TablePaste', function(a) ops().paste(buf(), a.bang) end,
    { bang = true, desc = 'table-vim: paste (! = above/left)' })
end

return M
