-- Examples of `build` on a cooldown.nvim plugin entry.
--
-- A build runs after a new SHA is approved, and on startup for already-locked
-- plugins, so it must be idempotent (cheap no-op when its output is present).
-- Drop these into your `plugins` list.

return {
  -- 1. Download a release binary with the bundled helper (no GitHub API/token).
  --    blink.cmp ships its fuzzy matcher as a per-platform release asset.
  { 'Saghen/blink.cmp',
    build = require('cooldown.build').release_asset({
      asset = '{rust-triple}.{ext}',
      dest  = '~/.local/share/nvim/site/lib/libblink_cmp_fuzzy.{ext}.{sha7}',
    }),
  },

  -- 2. A release that ships a tarball; extract it and mark a binary executable.
  { 'some/tool.nvim',
    build = require('cooldown.build').release_asset({
      asset   = 'tool-{os}-{arch}.tar.gz',
      dest    = '~/.local/share/nvim/site/tool',  -- a directory when extracting
      extract = true,
      bin     = 'tool',                            -- chmod +x <dest>/tool
    }),
  },

  -- 3. The escape hatch: a plain function for anything the helper can't express
  --    (compiling from source, multi-step setup, non-GitHub downloads). Note
  --    the idempotency guard at the top.
  { 'nvim-telescope/telescope-fzf-native.nvim',
    build = function(ctx)
      local marker = vim.fn.stdpath('data') .. '/fzf-native-built.' .. ctx.sha:sub(1, 7)
      if vim.uv.fs_stat(marker) then return end
      -- (run your compile step here, e.g. make in the plugin's checkout)
      io.open(marker, 'w'):close()
    end,
  },
}
