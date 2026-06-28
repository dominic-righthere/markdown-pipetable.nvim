-- table-vim configuration: defaults, user-merge, and highlight groups.
local M = {}

---@type table
M.defaults = {
  enabled = true,
  auto_enter = true, -- enter table-navigate when the cursor lands on a table
  filetypes = { 'markdown' },
  debounce = 16, -- ms to coalesce repaints
  format_on_edit = false, -- repad the whole column on commit vs minimal single-cell diff

  column = {
    min_width = 3,
    max_width = 40,
    padding = 1, -- spaces on each side of a cell's content
  },

  border = {
    enabled = true,
    style = 'full', -- 'full' | 'rows' | 'none'
    vert = '│',
    horiz = '─',
    -- corners / tees for the full box
    tl = '┌', tm = '┬', tr = '┐',
    ml = '├', mm = '┼', mr = '┤',
    bl = '└', bm = '┴', br = '┘',
  },

  overflow = {
    left = '‹',
    right = '›',
    ellipsis = '…',
    min_visible = 3, -- minimum content cells before a partial column is shown
  },

  cursor = {
    hide_real = true, -- hide the real cursor in table-navigate (cell cursor is a highlight)
    row_highlight = true, -- tint the whole active row
    column_highlight = false, -- tint the whole active column (full crosshair when on)
  },

  clipboard = true, -- mirror yanks to the system clipboard ("+) as TSV

  -- All keys are rebindable; set a key (or a whole group) to false to disable.
  -- Every binding accepts a string, a list of strings, or false.
  keys = {
    enter = false, -- optional manual-enter key in normal mode (false = rely on auto_enter / :TableVim)
    leader = '<leader>t', -- prefix for the structural-op group (keys.ops are suffixes of this)
    nav = {
      left = 'h', down = 'j', up = 'k', right = 'l',
      first_col = '_', last_col = '$',
      first_row = 'gg', last_row = 'G',
      into_cell = '<CR>',
      edit = 'i', edit_append = 'a',
      exit = '<Esc>', quit = 'q',
      -- structural direct keys (buffer-local, only inside a table)
      new_row_below = 'o', new_row_above = 'O',
      delete_row = 'dd', yank_row = 'yy',
      paste_below = 'p', paste_above = 'P',
      visual_cell = 'v', visual_row = 'V', visual_col = '<C-v>',
    },
    -- Structural-op group. Each value is a SUFFIX appended to keys.leader, so the
    -- whole group moves if you change keys.leader. Set keys.ops = false to drop
    -- the entire group, or any entry to false to drop just that op.
    ops = {
      insert_row_below = 'ir', insert_row_above = 'iR',
      insert_col_right = 'ic', insert_col_left = 'iC',
      delete_row = 'dr', delete_col = 'dc',
      move_col_left = 'mh', move_col_right = 'ml',
      move_row_up = 'mk', move_row_down = 'mj',
      dup_row = 'cr', dup_col = 'cc',
      align_left = 'al', align_center = 'ac', align_right = 'ar', align_default = 'ad',
      sort_asc = 's', sort_desc = 'S',
    },
    cell = {
      edit = 'i', edit_append = 'a',
      commit = '<CR>', exit = '<Esc>',
    },
    edit = {
      commit = '<CR>', commit_next = '<Tab>', cancel = '<Esc>',
    },
    -- table-visual mode (entered with nav.visual_*)
    visual = {
      left = 'h', down = 'j', up = 'k', right = 'l',
      first_col = '_', last_col = '$', first_row = 'gg', last_row = 'G',
      switch_cell = 'v', switch_row = 'V', switch_col = '<C-v>',
      delete = 'd', yank = 'y', clear = { 'x', 'c' },
      cancel = { '<Esc>', 'q' },
    },
  },

  -- Appearance of each rendered piece. Every value is either a highlight-group
  -- name to LINK to (string) or an `nvim_set_hl` spec (table), e.g.
  --   cursor_cell = { reverse = true }          -- attributes
  --   cursor_cell = { bg = '#3b4261', bold = true }
  --   border      = 'Comment'                   -- link to a group
  -- Set a key to false to leave that group untouched.
  highlights = {
    border = 'Comment',
    header = 'Title',
    cell = 'Normal',
    cursor_cell = { reverse = true, bold = true }, -- the focused cell (strong, theme-independent)
    cursor_row = 'CursorLine', -- active-row tint
    cursor_col = 'CursorColumn', -- active-column tint (used when cursor.column_highlight = true)
    selection = 'Visual', -- multi-cell visual selection
    overflow = 'NonText',
    edit = 'IncSearch', -- the cell editor + the mode badge
    hidden_cursor = { blend = 100, nocombine = true },
  },
}

-- Logical key -> the fixed highlight group used in extmarks. `highlights` above
-- configures the *appearance* of these groups.
M.GROUPS = {
  border = 'TableVimBorder',
  header = 'TableVimHeader',
  cell = 'TableVimCell',
  cursor_cell = 'TableVimCursorCell',
  cursor_row = 'TableVimCursorRow',
  cursor_col = 'TableVimCursorColumn',
  selection = 'TableVimSelection',
  overflow = 'TableVimOverflow',
  edit = 'TableVimEdit',
  hidden_cursor = 'TableVimHiddenCursor',
}

M.options = vim.deepcopy(M.defaults)

---@param opts table|nil
---@return table
function M.setup(opts)
  opts = opts or {}
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts)
  -- Highlight specs REPLACE the default for that key (so a user spec can drop
  -- attributes like `reverse`), rather than deep-merging into it.
  if opts.highlights then
    for key, spec in pairs(opts.highlights) do
      M.options.highlights[key] = spec
    end
  end
  return M.options
end

---@return table
function M.get()
  return M.options
end

-- Apply the configured appearance to each fixed group. A string value links;
-- a table value is an nvim_set_hl spec. These are our own groups, so we set them
-- outright (no `default`) — customization goes through `highlights` config, and
-- `highlights.<key> = false` leaves a group untouched for fully manual control.
local function apply_highlights()
  local h = M.options.highlights
  for key, group in pairs(M.GROUPS) do
    local spec = h[key]
    if spec and spec ~= '' then
      if type(spec) == 'string' then
        vim.api.nvim_set_hl(0, group, { link = spec })
      elseif type(spec) == 'table' then
        vim.api.nvim_set_hl(0, group, spec)
      end
    end
  end
end

function M.setup_highlights()
  apply_highlights()
  -- :colorscheme clears all groups; re-apply ours. Recreate (clear) the group so
  -- repeated setup() calls don't stack duplicate autocmds.
  local aug = vim.api.nvim_create_augroup('table-vim-hl', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = aug,
    callback = apply_highlights,
  })
end

return M
