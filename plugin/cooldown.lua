if vim.g.loaded_cooldown then return end
vim.g.loaded_cooldown = 1

local subcommands = { 'dry', 'now', 'new', 'status', 'bootstrap' }

local function run(sub)
  local cooldown = require('cooldown')
  local cfg      = require('cooldown.config').get()
  local report   = require('cooldown.report')

  -- bootstrap derives everything from the lockfile, so it runs even before any
  -- plugins.lua exists: it writes plugins.lua, shows the init.lua snippet, and
  -- seeds the cooldown clock.
  if sub == 'bootstrap' then
    cooldown.bootstrap()
    return
  end

  local specs = cfg._specs or {}

  if #specs == 0 then
    vim.notify('cooldown: no plugins configured. Call require("cooldown").setup({...}) first.',
               vim.log.levels.WARN)
    return
  end

  if sub == 'status' then
    local result = cooldown.apply_ready(specs, { dry_run = true })
    report.print(result)
    return
  end

  local mode = {
    dry_run    = sub == 'dry',
    bypass_all = sub == 'now',
    bypass_new = sub == 'new',
  }

  vim.notify(('cooldown: checking %d plugin(s) on GitHub...'):format(#specs), vim.log.levels.INFO)

  mode.on_progress = function(done, total, _)
    if done == total then return end
    if done % 5 == 0 then
      vim.notify(('cooldown: %d/%d'):format(done, total), vim.log.levels.INFO)
    end
  end

  cooldown.check_async(specs, mode, function(check)
    local result = cooldown.apply_ready(specs, mode)
    for _, e in ipairs(check.errors) do result.errors[#result.errors + 1] = e end

    report.print(result, mode)

    if mode.dry_run or not cfg.auto_sync or #result.ready == 0 then return end

    local applied_repos, new_pack_specs = {}, {}
    for _, r in ipairs(result.ready) do
      if r.is_new then
        new_pack_specs[#new_pack_specs + 1] = {
          src = ('https://github.com/%s/%s.git'):format(r.owner, r.repo),
        }
      else
        applied_repos[#applied_repos + 1] = r.repo
      end
    end

    if vim.pack then
      if #applied_repos > 0 then
        pcall(vim.pack.update, applied_repos, { force = true, target = 'lockfile' })
      end
      if #new_pack_specs > 0 then
        pcall(vim.pack.add, new_pack_specs)
      end
    end
  end)
end

vim.api.nvim_create_user_command('Cooldown', function(opts)
  run(opts.fargs[1] or '')
end, {
  nargs = '?',
  complete = function(arg)
    local matches = {}
    for _, s in ipairs(subcommands) do
      if s:sub(1, #arg) == arg then matches[#matches + 1] = s end
    end
    return matches
  end,
  desc = 'Check GitHub for plugin updates, applying any that have cleared cooldown.',
})
