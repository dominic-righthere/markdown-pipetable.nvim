-- Display-width helpers (multibyte / double-width aware) and pipe escaping.
local M = {}

local strdisplaywidth = vim.fn.strdisplaywidth
local strcharpart = vim.fn.strcharpart
local strchars = vim.fn.strchars

---Display width of a string.
---@param s string
---@return integer
function M.width(s)
  return strdisplaywidth(s)
end

---Truncate `s` to display width `n`, appending `ellipsis`.
---Result display width is exactly `n` when truncation happens (pads one space on a
---double-width straddle so columns stay aligned).
---@param s string
---@param n integer
---@param ellipsis string|nil
---@return string
function M.truncate(s, n, ellipsis)
  ellipsis = ellipsis or '…'
  if strdisplaywidth(s) <= n then
    return s
  end
  local ell_w = strdisplaywidth(ellipsis)
  local target = n - ell_w
  if target < 0 then
    target = n
    ellipsis = ''
  end
  local out, acc = {}, 0
  local nchars = strchars(s)
  for i = 0, nchars - 1 do
    local ch = strcharpart(s, i, 1)
    local w = strdisplaywidth(ch)
    if acc + w > target then
      break
    end
    out[#out + 1] = ch
    acc = acc + w
  end
  local result = table.concat(out)
  if acc < target then
    result = result .. string.rep(' ', target - acc)
  end
  return result .. ellipsis
end

---Pad `s` to display width `n`. `side` is 'left' | 'right' | 'center'.
---@param s string
---@param n integer
---@param side string|nil
---@param fill string|nil
---@return string
function M.align(s, n, side, fill)
  fill = fill or ' '
  local w = strdisplaywidth(s)
  if w >= n then
    return s
  end
  local pad = n - w
  if side == 'right' then
    return string.rep(fill, pad) .. s
  elseif side == 'center' then
    local left = math.floor(pad / 2)
    return string.rep(fill, left) .. s .. string.rep(fill, pad - left)
  end
  return s .. string.rep(fill, pad)
end

---Fit `s` to exactly display width `n` (truncate if long, pad if short).
---@param s string
---@param n integer
---@param side string|nil
---@param ellipsis string|nil
---@return string
function M.fit(s, n, side, ellipsis)
  if strdisplaywidth(s) > n then
    return M.truncate(s, n, ellipsis)
  end
  return M.align(s, n, side)
end

---Turn every literal pipe into an escaped pipe (idempotent).
---@param s string
---@return string
function M.escape_pipe(s)
  return (M.unescape_pipe(s):gsub('|', '\\|'))
end

---Turn escaped pipes back into literal pipes for display / editing.
---@param s string
---@return string
function M.unescape_pipe(s)
  return (s:gsub('\\|', '|'))
end

return M
