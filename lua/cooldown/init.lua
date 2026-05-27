local config   = require('cooldown.config')
local lockfile = require('cooldown.lockfile')
local pending  = require('cooldown.pending')
local sources  = require('cooldown.sources')
local github   = require('cooldown.github')
local hooks    = require('cooldown.hooks')
local util     = require('cooldown.util')

local M = {}
M.config = config

local function fire_post_apply(cfg, applied)
  if #applied == 0 or type(cfg.post_apply) ~= 'function' then return end
  local ok, err = pcall(cfg.post_apply, applied)
  if not ok then
    vim.notify('cooldown: post_apply hook failed: ' .. tostring(err), vim.log.levels.ERROR)
  end
end

function M.apply_ready(specs, opts)
  opts = opts or {}
  local cfg          = config.get()
  local lock_data    = lockfile.read(cfg.lockfile)
  local pending_data = pending.read(cfg.pending)
  local locked       = lockfile.plugins(lock_data)

  local result = { ready = {}, waiting = {}, current = {}, errors = {} }
  local lockfile_dirty, pending_dirty = false, false
  local build_jobs = {}

  for _, entry in ipairs(specs) do
    if entry.name and entry.src then
      local name        = entry.name
      local is_new      = locked[name] == nil
      local current_sha = is_new and nil or lockfile.locked_sha(locked[name])
      local candidates  = pending.candidates(pending_data, entry.spec, cfg.cooldown_days)

      local bypass = opts.bypass_all or (opts.bypass_new and is_new)
      local cleared, waiting_list = {}, {}
      for _, c in ipairs(candidates) do
        if c.days_remaining == 0 or bypass then
          cleared[#cleared + 1] = c
        else
          waiting_list[#waiting_list + 1] = c
        end
      end

      if #cleared > 0 then
        table.sort(cleared, function(a, b) return a.eff_epoch > b.eff_epoch end)
        local best = cleared[1]
        lockfile.set_plugin(lock_data, name, entry.src, best.sha)
        lockfile_dirty = true
        pending.prune_through(pending_data, entry.spec, best.sha)
        pending_dirty = true
        result.ready[#result.ready + 1] = {
          spec        = entry.spec, owner = entry.owner, repo = entry.repo,
          is_new      = is_new,
          current_sha = current_sha, apply_sha = best.sha,
          days_waited = best.days_waited, date_source = best.source,
        }
        if entry.build then
          build_jobs[#build_jobs + 1] = {
            owner = entry.owner, repo = entry.repo, name = name,
            sha = best.sha, build = entry.build,
          }
        end
      elseif #waiting_list > 0 then
        table.sort(waiting_list, function(a, b) return a.days_remaining < b.days_remaining end)
        local closest = waiting_list[1]
        local newest  = candidates[1]
        for _, c in ipairs(candidates) do
          if c.eff_epoch > newest.eff_epoch then newest = c end
        end
        local ready_epoch = util.epoch_plus_days(closest.eff_epoch, cfg.cooldown_days)
        result.waiting[#result.waiting + 1] = {
          spec           = entry.spec, is_new = is_new,
          current_sha    = current_sha or '(not in lockfile)',
          latest_sha     = newest.sha,
          days_remaining = closest.days_remaining,
          ready_date     = util.epoch_to_date(ready_epoch),
          date_source    = closest.source,
          pending_count  = #candidates,
        }
      elseif not is_new then
        result.current[#result.current + 1] = entry.spec
        -- Re-run the build for already-locked plugins too. Builds are
        -- idempotent, so this is a cheap no-op when the artifact is present
        -- and self-heals a missing one (deleted binary, fresh machine).
        if entry.build then
          build_jobs[#build_jobs + 1] = {
            owner = entry.owner, repo = entry.repo, name = name,
            sha = current_sha, build = entry.build,
          }
        end
      end
    end
  end

  if not opts.dry_run then
    if lockfile_dirty then lockfile.write(cfg.lockfile, lock_data) end
    if pending_dirty  then pending.write(cfg.pending, pending_data) end

    for _, job in ipairs(build_jobs) do
      hooks.run(job.build, {
        owner          = job.owner, repo = job.repo, sha = job.sha,
        lockfile_entry = lockfile.find_repo(lock_data, job.name),
      })
    end

    fire_post_apply(cfg, result.ready)
  end

  return result
end

function M.check_async(specs, opts, cb)
  opts = opts or {}
  local cfg          = config.get()
  local pending_data = pending.read(cfg.pending)
  local lock_data    = lockfile.read(cfg.lockfile)
  local locked       = lockfile.plugins(lock_data)
  local errors       = {}
  local dirty        = false
  local now_iso      = util.now_iso()
  local concurrency  = opts.concurrency or cfg.concurrency or 6

  local total       = #specs
  local done_count  = 0
  local next_idx    = 1

  if total == 0 then return cb({ errors = errors }) end

  local function finalize()
    if dirty and not opts.dry_run then
      pending.write(cfg.pending, pending_data)
    end
    cb({ errors = errors })
  end

  local start_next  -- forward decl
  local function record(entry, target_sha, target_date, err)
    if err then
      errors[#errors + 1] = entry.spec .. ': ' .. err
    elseif target_sha then
      local is_new      = locked[entry.name] == nil
      local current_sha = is_new and nil or lockfile.locked_sha(locked[entry.name])
      if target_sha == current_sha then
        if pending_data[entry.spec] then
          pending.remove(pending_data, entry.spec)
          dirty = true
        end
      else
        if pending.upsert(pending_data, entry.spec, target_sha, target_date, now_iso) then
          dirty = true
        end
      end
    end
    done_count = done_count + 1
    if opts.on_progress then pcall(opts.on_progress, done_count, total, entry.spec) end
    if done_count == total then finalize() else start_next() end
  end

  start_next = function()
    while next_idx <= total do
      local entry = specs[next_idx]
      next_idx = next_idx + 1
      if entry.name and entry.src then
        github.fetch_target_async(entry, function(target_sha, target_date, err)
          record(entry, target_sha, target_date, err)
        end)
        return
      end
      -- malformed entry: count it done immediately, loop for next
      done_count = done_count + 1
      if done_count == total then return finalize() end
    end
  end

  for _ = 1, math.min(concurrency, total) do start_next() end
end

function M.check_sync(specs, opts)
  opts = opts or {}
  local cfg          = config.get()
  local pending_data = pending.read(cfg.pending)
  local lock_data    = lockfile.read(cfg.lockfile)
  local locked       = lockfile.plugins(lock_data)
  local errors       = {}
  local dirty        = false
  local now_iso      = util.now_iso()

  for _, entry in ipairs(specs) do
    if entry.name and entry.src then
      local is_new      = locked[entry.name] == nil
      local current_sha = is_new and nil or lockfile.locked_sha(locked[entry.name])

      local target_sha, target_date, err = github.fetch_target_sync(entry)
      if err then
        errors[#errors + 1] = entry.spec .. ': ' .. err
      elseif target_sha then
        if target_sha == current_sha then
          if pending_data[entry.spec] then
            pending.remove(pending_data, entry.spec)
            dirty = true
          end
        else
          if pending.upsert(pending_data, entry.spec, target_sha, target_date, now_iso) then
            dirty = true
          end
        end
      end
    end
  end

  if dirty and not opts.dry_run then
    pending.write(cfg.pending, pending_data)
  end

  return { errors = errors }
end

function M.locked_plugins()
  local cfg = config.get()
  return lockfile.plugins(lockfile.read(cfg.lockfile))
end

-- Materialize a plugins.lua from the current lockfile (one entry per locked
-- plugin, including cooldown.nvim itself so it cools down like everything
-- else). Refuses to overwrite an existing file. Returns (true, count) or
-- (false, err_message).
function M.write_plugins_file(path)
  if vim.uv.fs_stat(path) then
    return false, ('refusing to overwrite existing %s'):format(path)
  end
  local cfg   = config.get()
  local specs = sources.resolve({ lockfile = cfg.lockfile })
  table.sort(specs, function(a, b) return a.spec < b.spec end)

  local lines = {
    '-- Plugin list for cooldown.nvim, generated by :Cooldown bootstrap from',
    '-- ' .. cfg.lockfile .. ' on ' .. os.date('%Y-%m-%d') .. '.',
    '-- Pinned revisions live in the lockfile. Edit entries to add e.g.',
    "-- `{ 'owner/repo', track = 'head' }` or a `build = ...` step.",
    'return {',
  }
  for _, e in ipairs(specs) do
    -- GitHub → 'owner/repo' shorthand; other hosts → full clone URL (re-parses).
    local ref = (e.host == 'github') and (e.owner .. '/' .. e.repo) or e.src
    lines[#lines + 1] = ("  '%s',"):format(ref)
  end
  lines[#lines + 1] = '}'
  lines[#lines + 1] = ''

  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  local f, err = io.open(path, 'w')
  if not f then return false, ('cannot write %s: %s'):format(path, err or '?') end
  f:write(table.concat(lines, '\n'))
  f:close()
  return true, #specs
end

-- Discover cooldown's own clone URL from the lockfile (it pins itself there
-- once vim.pack has installed it). Falls back to a placeholder.
local function self_src()
  for name, info in pairs(M.locked_plugins()) do
    if name == 'cooldown.nvim' or (info.src or ''):find('cooldown%.nvim') then
      return info.src
    end
  end
  return '<your cooldown.nvim git URL>'
end

-- Open a scratch buffer with the init.lua wiring to paste. We show it rather
-- than editing init.lua ourselves: configs vary too much (modular, symlinked,
-- dotfile-managed) and the wiring must load early — safer for the user to
-- place it consciously.
function M.show_setup_snippet()
  local lines = {
    '-- cooldown.nvim setup — paste this near the TOP of your init.lua, before',
    '-- other plugin configuration, then restart Neovim. (This buffer is scratch;',
    '-- yank what you need and close it.)',
    '',
    ("vim.pack.add({ { src = '%s' } }, { load = true, confirm = false })"):format(self_src()),
    '',
    "local ok, plugins = pcall(require, 'plugins')",
    "require('cooldown').setup({",
    '  plugins         = ok and plugins or nil,  -- missing plugins.lua → lockfile auto-discovery',
    '  manage_vim_pack = true,',
    '})',
  }
  vim.cmd('botright new')
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype   = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile  = false
  vim.bo[buf].filetype  = 'lua'
  pcall(vim.api.nvim_buf_set_name, buf, 'cooldown-setup-snippet')
end

-- One-shot onboarding: materialize plugins.lua from the lockfile, show the
-- init.lua wiring snippet, and seed the cooldown clock for every plugin.
function M.bootstrap(opts)
  opts = opts or {}
  local cfg  = config.get()
  local path = opts.path or (vim.fn.stdpath('config') .. '/lua/plugins.lua')

  local ok, res = M.write_plugins_file(path)
  if ok then
    vim.notify(('cooldown: wrote %d plugin(s) to %s'):format(res, path), vim.log.levels.INFO)
  else
    vim.notify('cooldown: ' .. res, vim.log.levels.WARN)
  end

  if opts.show_snippet ~= false then
    M.show_setup_snippet()
  end

  local specs = sources.resolve({ lockfile = cfg.lockfile })
  vim.notify('cooldown: seeding cooldown dates from GitHub...', vim.log.levels.INFO)
  M.check_async(specs, {
    on_progress = function(d, t)
      if d < t and d % 5 == 0 then vim.notify(('cooldown: %d/%d'):format(d, t)) end
    end,
  }, function(check)
    local tail = #check.errors > 0 and (', %d error(s)'):format(#check.errors) or ''
    vim.notify(('cooldown: bootstrap complete — %d plugin(s) checked%s'):format(#specs, tail),
               vim.log.levels.INFO)
  end)
end

function M.specs()
  return config.get()._specs or {}
end

function M.setup(user_opts)
  config.setup(user_opts)
  local cfg = config.get()

  local specs, _source = sources.resolve(cfg)
  cfg._specs = specs

  M.apply_ready(specs)

  if cfg.manage_vim_pack and vim.pack then
    local pack_specs = {}
    for _, info in pairs(M.locked_plugins()) do
      pack_specs[#pack_specs + 1] = { src = info.src }
    end
    if #pack_specs > 0 then vim.pack.add(pack_specs) end
  end
end

return M
