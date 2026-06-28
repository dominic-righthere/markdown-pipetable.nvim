-- table-vim: interactive, fit-to-width, inline markdown tables.
local config = require('table-vim.config')
local manager = require('table-vim.manager')

local M = {}

---@param opts table|nil
function M.setup(opts)
  config.setup(opts)
  config.setup_highlights()
  if not config.get().enabled then
    return
  end
  manager.init()
  require('table-vim.commands').setup()
end

---Force a repaint of the current buffer.
function M.refresh()
  manager.refresh(vim.api.nvim_get_current_buf())
end

---Toggle table mode on the current buffer.
function M.toggle()
  manager.toggle()
end

---Current table mode of the current buffer ('inactive' if none).
---@return string
function M.mode()
  local st = require('table-vim.state').peek(vim.api.nvim_get_current_buf())
  return (st and st.mode) or 'inactive'
end

---Statusline component, e.g. `TBL NAV 2:3`. Empty string when not in a table.
---@return string
function M.status()
  local st = require('table-vim.state').peek(vim.api.nvim_get_current_buf())
  if not st or st.mode == 'inactive' or not st.active then
    return ''
  end
  return string.format('TBL %s %d:%d', manager.MODE_LABEL[st.mode] or 'TBL', st.active.row, st.active.col)
end

return M
