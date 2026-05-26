local util = require('cooldown.util')

local M = {}

function M.read(path)
  return util.read_json(path)
end

function M.write(path, data)
  util.write_json(path, data)
end

local function migrate(raw)
  if type(raw) ~= 'table' then return {} end
  if raw.available_sha then
    local sha = raw.available_sha
    return { [sha] = { first_seen = raw.first_seen, release_date = raw.release_date } }
  end
  return raw
end

function M.entries_for(data, spec)
  data[spec] = migrate(data[spec] or {})
  return data[spec]
end

function M.effective_epoch(entry)
  if entry.release_date and entry.release_date ~= vim.NIL then
    return util.iso_to_epoch(entry.release_date), 'release'
  end
  return util.iso_to_epoch(entry.first_seen), 'first-seen'
end

function M.upsert(data, spec, sha, target_date, now_iso)
  local p = M.entries_for(data, spec)
  if not p[sha] then
    p[sha] = { first_seen = now_iso, release_date = target_date or vim.NIL }
    return true
  end
  if target_date and (p[sha].release_date == nil or p[sha].release_date == vim.NIL) then
    p[sha].release_date = target_date
    return true
  end
  return false
end

function M.candidates(data, spec, cooldown_days)
  local p = M.entries_for(data, spec)
  local out = {}
  for sha, entry in pairs(p) do
    local eff, source = M.effective_epoch(entry)
    if eff then
      local waited    = util.days_since(eff)
      local remaining = math.max(0, cooldown_days - waited)
      out[#out + 1] = {
        sha            = sha,
        eff_epoch      = eff,
        source         = source,
        days_waited    = waited,
        days_remaining = remaining,
      }
    end
  end
  return out
end

function M.remove(data, spec)
  data[spec] = nil
end

function M.prune_through(data, spec, applied_sha)
  local p = data[spec]
  if not p or not p[applied_sha] then return end
  local applied_eff = M.effective_epoch(p[applied_sha])
  local kept = {}
  for sha, entry in pairs(p) do
    local eff = M.effective_epoch(entry)
    if eff and eff > applied_eff then kept[sha] = entry end
  end
  if next(kept) then
    data[spec] = kept
  else
    data[spec] = nil
  end
end

return M
