local M = {}

-- Run a plugin's build function, catching and reporting errors. Build
-- functions are expected to be idempotent (cheap no-op when their output is
-- already present), since cooldown calls them after every approval and on
-- startup for already-locked plugins.
function M.run(build_fn, ctx)
  if type(build_fn) ~= 'function' then return end
  local ok, err = pcall(build_fn, ctx)
  if not ok then
    vim.notify(('cooldown: build for %s/%s failed: %s'):format(ctx.owner, ctx.repo, err),
               vim.log.levels.ERROR)
  end
end

return M
