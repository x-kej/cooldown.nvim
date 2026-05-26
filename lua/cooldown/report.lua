local M = {}

local function short(sha) return sha and sha:sub(1, 8) or '(none)' end

function M.format(result, opts)
  opts = opts or {}
  local lines = {}
  local function add(s) lines[#lines + 1] = s end

  if #result.ready > 0 then
    add(('%s %d plugin(s):'):format(opts.dry_run and 'Would approve' or 'Approving', #result.ready))
    for _, r in ipairs(result.ready) do
      local verb = r.is_new and 'install' or 'update'
      add(('  [%s] %-40s %s → %s  (%dd, %s)'):format(
        verb, r.spec, short(r.current_sha), short(r.apply_sha), r.days_waited, r.date_source))
    end
  end

  if #result.waiting > 0 then
    add(('Cooling down (%d plugin(s)):'):format(#result.waiting))
    table.sort(result.waiting, function(a, b) return a.days_remaining < b.days_remaining end)
    for _, r in ipairs(result.waiting) do
      local verb   = r.is_new and 'install' or 'update'
      local queued = r.pending_count > 1 and (', %d queued'):format(r.pending_count) or ''
      add(('  [%s] %-40s → %s  (%dd left, ready %s%s)'):format(
        verb, r.spec, short(r.latest_sha), r.days_remaining, r.ready_date, queued))
    end
  end

  local summary = { ('up to date: %d'):format(#result.current) }
  if #result.ready   > 0 then summary[#summary + 1] = ('ready: %d'):format(#result.ready) end
  if #result.waiting > 0 then summary[#summary + 1] = ('cooling: %d'):format(#result.waiting) end
  if #result.errors  > 0 then summary[#summary + 1] = ('errors: %d (%s)'):format(
      #result.errors, table.concat(result.errors, ', ')) end
  add(table.concat(summary, ' | '))

  return table.concat(lines, '\n')
end

function M.print(result, opts)
  local body = M.format(result, opts)
  if body == '' then return end
  vim.notify(body, vim.log.levels.INFO)
end

return M
