local M = {}

local function defaults()
  return {
    cooldown_days   = 15,
    lockfile        = vim.fn.stdpath('config') .. '/nvim-pack-lock.json',
    pending         = vim.fn.stdpath('config') .. '/nvim-pack-pending.json',
    manage_vim_pack = false,
    auto_sync       = true,
    concurrency     = 6,
    post_apply      = nil,
  }
end

M.current = defaults()

function M.setup(user_opts)
  M.current = vim.tbl_deep_extend('force', defaults(), user_opts or {})
end

function M.get() return M.current end

return M
