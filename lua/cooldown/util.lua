local M = {}

function M.read_json(path)
  local f = io.open(path, 'r')
  if not f then return {} end
  local body = f:read('*a')
  f:close()
  if not body or body == '' then return {} end
  local ok, data = pcall(vim.json.decode, body)
  if not ok or type(data) ~= 'table' then return {} end
  return data
end

local function escape_string(s)
  return (s:gsub('\\', '\\\\'):gsub('"', '\\"')
           :gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t'))
end

local pretty_encode

local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= 'number' then return false end
    n = n + 1
  end
  for i = 1, n do if t[i] == nil then return false end end
  return true, n
end

pretty_encode = function(value, indent, depth)
  if value == nil or value == vim.NIL then return 'null' end
  local t = type(value)
  if t == 'boolean' then return tostring(value) end
  if t == 'number' then return tostring(value) end
  if t == 'string' then return '"' .. escape_string(value) .. '"' end
  if t ~= 'table' then error('cooldown: cannot encode ' .. t) end

  local pad   = string.rep(indent, depth)
  local inner = string.rep(indent, depth + 1)
  local arr, n = is_array(value)

  if arr then
    if n == 0 then return '[]' end
    local parts = {}
    for i = 1, n do parts[i] = inner .. pretty_encode(value[i], indent, depth + 1) end
    return '[\n' .. table.concat(parts, ',\n') .. '\n' .. pad .. ']'
  end

  local keys = {}
  for k in pairs(value) do keys[#keys + 1] = tostring(k) end
  if #keys == 0 then return '{}' end
  table.sort(keys)
  local parts = {}
  for i, k in ipairs(keys) do
    parts[i] = inner .. '"' .. escape_string(k) .. '": ' .. pretty_encode(value[k], indent, depth + 1)
  end
  return '{\n' .. table.concat(parts, ',\n') .. '\n' .. pad .. '}'
end

function M.write_json(path, data)
  local body = pretty_encode(data, '  ', 0) .. '\n'
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  local f, err = io.open(path, 'w')
  if not f then error(('cooldown: cannot write %s: %s'):format(path, err or '?')) end
  f:write(body)
  f:close()
end

local function local_utc_offset()
  local now = os.time()
  return now - os.time(os.date('!*t', now))
end

function M.iso_to_epoch(s)
  if not s or s == '' then return nil end
  local y, mo, d, h, mi, se = s:match('(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)')
  if not y then return nil end
  local as_local = os.time({
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min  = tonumber(mi), sec = tonumber(se),
  })
  return as_local + local_utc_offset()
end

function M.now_epoch()
  return os.time()
end

function M.now_iso()
  return os.date('!%Y-%m-%dT%H:%M:%S+00:00')
end

function M.days_since(epoch)
  return math.floor((M.now_epoch() - epoch) / 86400)
end

function M.epoch_plus_days(epoch, days)
  return epoch + days * 86400
end

function M.epoch_to_date(epoch)
  return os.date('!%Y-%m-%d', epoch)
end

return M
