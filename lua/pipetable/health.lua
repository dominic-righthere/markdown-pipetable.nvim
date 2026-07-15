-- :checkhealth pipetable
local M = {}

-- Plugins that also render markdown tables. pipetable owns tables, so each of
-- these has to be told to leave them alone, or the two borders draw on top of
-- each other. See |pipetable-renderers|.
--
-- `tables_on` reads the other plugin's own config, which is coupling we accept
-- only because the failure mode is soft: if they rename a key, the pcall below
-- turns this into an "unknown" note rather than breaking anything.
local RENDERERS = {
  {
    name = 'markview.nvim',
    mod = 'markview',
    tag = 'pipetable-markview',
    fix = 'markdown = { tables = { enable = false } }',
    tables_on = function()
      return require('markview.spec').get({ 'markdown', 'tables', 'enable' }, { ignore_enable = true })
    end,
  },
  {
    name = 'render-markdown.nvim',
    mod = 'render-markdown',
    tag = 'pipetable-render-markdown',
    fix = 'pipe_table = { enabled = false }',
    tables_on = function()
      return require('render-markdown.state').config.pipe_table.enabled
    end,
  },
}

---Warn about co-resident renderers that are still drawing tables.
---@param health table
local function check_renderers(health)
  local seen = false
  for _, r in ipairs(RENDERERS) do
    -- Deliberately not `require`: loading a plugin as a side effect of a health
    -- check would be rude, and a lazy-loaded one simply isn't our problem yet.
    if package.loaded[r.mod] then
      seen = true
      local ok, on = pcall(r.tables_on)
      if not ok or on == nil then
        health.info(r.name .. ' is loaded, but its table setting could not be read. '
          .. 'If table borders look doubled, see :h ' .. r.tag)
      elseif on == false then
        health.ok(r.name .. ': table rendering off, pipetable owns tables')
      else
        health.warn(r.name .. ' is rendering tables too, so borders will double up', {
          'Let pipetable own tables: ' .. r.fix,
          'See :h ' .. r.tag,
        })
      end
    end
  end
  if not seen then
    health.ok('no conflicting markdown renderer loaded')
  end
end

function M.check()
  local health = vim.health
  health.start('pipetable')

  if vim.fn.has('nvim-0.10') == 1 then
    health.ok('Neovim ' .. tostring(vim.version()))
  else
    health.warn('Neovim 0.10+ recommended (extmark conceal / inline virt_text)')
  end

  health.ok('table detection: regex scanner (primary; handles empty-cell rows)')
  local has_md = pcall(vim.treesitter.language.add, 'markdown')
  if has_md then
    health.ok('treesitter `markdown` parser available (fallback detector)')
  else
    health.info('treesitter `markdown` parser not found (only used as a fallback)')
  end

  local ok = pcall(require, 'pipetable.config')
  if ok then
    health.ok('plugin modules load')
  else
    health.error('failed to load pipetable modules')
  end

  check_renderers(health)
end

return M
