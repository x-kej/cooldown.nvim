# cooldown.nvim

A supply-chain cooldown for Neovim's built-in `vim.pack` plugin manager.

When a new commit (or release) appears on a plugin you use, **wait N days before
adopting it**. That lag is a cheap defense against compromised upstream releases:
most malicious packages are pulled or burned within a week of going public, so a
15-day cooldown blocks the bulk of supply-chain attacks while costing you nothing
when nothing is wrong.

`cooldown.nvim` is a thin gatekeeper around the lockfile that `vim.pack` reads at
startup. It never touches Git itself — `vim.pack` still does all the cloning,
fetching, and checking out. Cooldown just decides which SHAs get written into the
lockfile, and when.

## Status

Experimental. The API may shift. See `doc/cooldown.txt` for help tags.

## Installation

cooldown is the gatekeeper, so it has to load before it can manage anything —
which means a one-time, deliberate first install. Two steps:

**1.** In Neovim, run this once (adjust the URL if you fork it):

```vim
:lua vim.pack.add({{src='https://github.com/x-kej/cooldown.nvim.git'}}, {load=true, confirm=false}) require('cooldown').bootstrap()
```

That installs cooldown (which pins it in your `nvim-pack-lock.json`
automatically), then `bootstrap()`:
- writes a `lua/plugins.lua` listing every plugin in your lockfile (including
  cooldown.nvim itself — it won't overwrite an existing file),
- seeds the cooldown clock so each plugin's wait starts now, and
- opens a scratch buffer with the exact `init.lua` snippet to paste.

**2.** Paste that snippet near the **top** of your `init.lua` (before other
plugin config) and restart. It looks like:

```lua
vim.pack.add({ { src = 'https://github.com/x-kej/cooldown.nvim.git' } },
             { load = true, confirm = false })

local ok, plugins = pcall(require, 'plugins')
require('cooldown').setup({
  plugins         = ok and plugins or nil,  -- missing plugins.lua → lockfile auto-discovery
  manage_vim_pack = true,
})
```

That's the whole setup. cooldown doesn't edit your `init.lua` for you — configs
vary too much (modular, symlinked, dotfile-managed) and the wiring must load
early, so you place it consciously.

### cooldown updates itself, too

cooldown.nvim is listed in `plugins.lua` like any other plugin, so its own
updates go through the same cooldown. One nuance from how `vim.pack` works:
updates to an already-installed plugin are applied by `vim.pack.update` during
`:Cooldown` (not by a plain restart), and because cooldown's Lua is already
loaded for the session, a new cooldown.nvim version **takes effect on the next
restart**. The early `vim.pack.add` line stays pinned to the lockfile rev, so
you're never silently pulled to upstream `HEAD`.

## Requirements

- Neovim 0.12+ (for `vim.pack`)
- `git` on PATH (you already have it — `vim.pack` needs it too)
- `curl` on PATH (or PowerShell on Windows when `curl` isn't available)

**No GitHub authentication required.** cooldown.nvim never touches
`api.github.com`, so there's no rate limit to worry about and no token to set
up. It discovers updates using only:

- `git ls-remote` — for commit SHAs (HEAD and release tags)
- the `releases/latest` redirect on `github.com` — for the latest *stable*
  release tag (honors the maintainer's "latest" designation)
- the `releases.atom` feed — for the release publish date

> Note: the release date comes from the atom feed's `<updated>` field rather
> than the API's `published_at`. The two are usually identical; `<updated>`
> only differs if a maintainer edits a release after publishing, which can push
> the cooldown later (never earlier), so it stays on the safe side. For tags
> older than the recent atom window, cooldown falls back to a local first-seen
> timestamp.

## Quickstart

```lua
-- early in init.lua, before any vim.pack.add() calls
require('cooldown').setup({
  plugins = {
    'stevearc/oil.nvim',
    'ibhagwan/fzf-lua',
    { spec = 'folke/which-key.nvim', track = 'head' },  -- ignore releases for this one
  },
  manage_vim_pack = true,  -- have cooldown call vim.pack.add() with the locked specs
})
```

That's it. On startup, cooldown promotes any SHA that has cleared the 15-day
cooldown into the lockfile, then `vim.pack` reads the lockfile and installs the
right versions.

Run `:Cooldown` whenever you want to check for new updates from GitHub:

```
:Cooldown            " check GitHub, apply any cleared updates, sync vim.pack in-session
:Cooldown dry        " same but write nothing
:Cooldown new        " bypass cooldown for plugins not yet installed
:Cooldown now        " bypass cooldown for everything (fresh-machine setup)
:Cooldown status     " show the current pending queue without hitting GitHub
:Cooldown bootstrap  " generate lua/plugins.lua from the lockfile + seed cooldown dates
```

`:Cooldown bootstrap` is for adopting cooldown when you already have a
`vim.pack` lockfile (or recovering a lost `plugins.lua`): it writes a
`lua/plugins.lua` listing every locked plugin (refusing to overwrite an
existing one), then runs an initial check so each plugin's cooldown clock
starts from now. Pair it with a `pcall(require, 'plugins')` fallback in your
config so a missing `plugins.lua` degrades to lockfile auto-discovery rather
than erroring — that's what keeps `:Cooldown` reachable to run bootstrap in the
first place.

## How it tracks updates

Cooldown distinguishes between plugins that publish GitHub releases and those
that don't:

- **Has releases (default for `track='auto'`)**: only release commits are
  considered. The cooldown clock starts from the release's `published_at` date —
  a server-assigned timestamp that can't be backdated by the author.
- **No releases (or `track='head'`)**: HEAD commits are tracked using a local
  "first seen" timestamp. Commit dates are intentionally ignored — they are
  user-controlled and trivially backdated.

Each pending SHA has its own independent clock. A new release does not reset the
cooldown on an older one that's already cooling down.

## Plugin list sources

Three ways to declare the plugin list — pick one:

```lua
-- 1. Inline Lua table
require('cooldown').setup({
  plugins = {
    'stevearc/oil.nvim',
    { spec = 'folke/which-key.nvim', track = 'head' },
  },
})

-- 2. JSON file (handy if you want to share the list across tools)
require('cooldown').setup({
  plugins_file = vim.fn.stdpath('config') .. '/plugins.json',
})

-- 3. Auto-discover from the existing lockfile
require('cooldown').setup({})  -- no plugins or plugins_file → reads nvim-pack-lock.json
```

JSON format:

```json
[
  "stevearc/oil.nvim",
  { "spec": "folke/which-key.nvim", "track": "head" }
]
```

### Non-GitHub hosts

`owner/repo` shorthand resolves to GitHub. To use another host, give the full
clone URL — Codeberg, GitLab, self-hosted Forgejo, anything `git` can reach:

```lua
plugins = {
  'stevearc/oil.nvim',                          -- github.com shorthand
  'https://codeberg.org/foo/bar.nvim',          -- full URL → any host
  { 'https://gitlab.com/group/proj', track = 'head' },
}
```

Update detection for non-GitHub hosts uses `git ls-remote` (HEAD commits) with
cooldown's local first-seen timestamps — no host API or auth needed. Because
release detection currently relies on GitHub-specific endpoints, **non-GitHub
hosts track HEAD only**: `track = 'auto'` is treated as `'head'`, and
`track = 'release'` errors.

> **Roadmap — Tier 2 (not yet implemented):** release tracking and
> `release_asset` downloads for non-GitHub hosts. This needs per-host adapters
> (GitLab's `/-/releases`, Forgejo/Gitea release endpoints) for "latest stable
> tag + date" and asset listing/download. HEAD tracking already works
> everywhere; this would extend release/auto tracking and binary builds to
> those hosts.

## Builds

Some plugins ship a native binary that must be fetched out-of-band (e.g.
`blink.cmp`'s fuzzy matcher), or need a compile step. Give the entry a `build`
function — cooldown calls it after a new SHA is approved, and again on startup
for already-locked plugins. Builds must be **idempotent**: a cheap no-op when
their output is already present, so the startup re-run is free and a missing
artifact (deleted binary, fresh machine) self-heals.

```lua
{ 'owner/repo',
  build = function(ctx)
    -- ctx = { owner, repo, sha, lockfile_entry }
    if vim.uv.fs_stat(my_output_path(ctx.sha)) then return end  -- idempotency guard
    -- ... fetch / compile
  end,
}
```

### `release_asset` — download a GitHub release binary (no API, no token)

For the common "grab a named asset off this plugin's release" case, use the
built-in helper instead of hand-rolling it:

```lua
{ 'Saghen/blink.cmp',
  build = require('cooldown.build').release_asset({
    asset = '{rust-triple}.{ext}',
    dest  = '~/.local/share/nvim/site/lib/libblink_cmp_fuzzy.{ext}.{sha7}',
  }),
}
```

It resolves the latest stable tag (via the `releases/latest` redirect),
downloads `/releases/download/<tag>/<asset>`, verifies a `<asset>.sha256`
companion when present, and places the result at `dest`. No `api.github.com`,
no token.

**Placeholders** (substituted into `asset` and `dest`):

| `{arch}` | `x86_64` / `aarch64` | `{tag}` | release tag, e.g. `v1.10.2` |
| `{os}` | `linux` / `macos` / `windows` | `{sha}` / `{sha7}` | full / short commit SHA |
| `{ext}` | `so` / `dylib` / `dll` | `{rust-triple}` | `{arch}-unknown-linux-gnu` / `-apple-darwin` / `-pc-windows-msvc` |

**Options:**

| `asset`   | string, or per-OS table `{ linux=…, macos=…, windows=… }` — the asset name template |
| `dest`    | path template (a file; or a directory when `extract` is set; `~` expands) |
| `extract` | `true` to unpack the downloaded archive into `dest` (tar formats via `tar`; `.zip` needs `unzip`) |
| `bin`     | optional file inside `dest` to `chmod +x` after extraction |

If a release is found but **no asset matches** your template (e.g. the project
renamed their assets), `release_asset` aborts with an alert listing the actual
asset names — so silent breakage surfaces immediately instead of as a 404.

For anything the helper can't express (compiling from source, multi-step
setup), use a plain `build` function. See `examples/` for both.

## Configuration

| Option            | Default                                              | Description                                                              |
| ----------------- | ---------------------------------------------------- | ------------------------------------------------------------------------ |
| `cooldown_days`   | `15`                                                 | Days a SHA must have been visible before it can be promoted.             |
| `plugins`         | `nil`                                                | Inline Lua list. See above for shapes.                                   |
| `plugins_file`    | `nil`                                                | Path to a JSON file with the plugin list.                                |
| `lockfile`        | `<stdpath('config')>/nvim-pack-lock.json`            | vim.pack-compatible lockfile path.                                       |
| `pending`         | `<stdpath('config')>/nvim-pack-pending.json`         | Where the pending queue lives.                                           |
| `manage_vim_pack` | `false`                                              | When true, `setup()` calls `vim.pack.add()` with the resolved specs.     |
| `auto_sync`       | `true`                                               | When true, `:Cooldown` calls `vim.pack.update()` to apply mid-session.   |
| `concurrency`     | `6`                                                  | Max number of plugins checked in parallel during `:Cooldown`.            |
| `post_apply`      | `nil`                                                | Called once after each successful apply with the list of applied items.  |

Per-plugin `build` functions are declared on the spec entry itself (see
[Builds](#builds)), not in `setup()`.

## Prior art

- [`nvim_up.py`](https://gist.github.com/) — the Python CLI predecessor of this
  plugin, designed around the same data files.
- [lazy.nvim #2141](https://github.com/folke/lazy.nvim/issues/2141) — open
  feature request for `minimumReleaseAge`. Same idea, different ecosystem.
- pnpm/yarn `minimumReleaseAge`, Renovate `minimumReleaseAge`, Dependabot
  `cooldown` — established pattern in language ecosystems for the same
  supply-chain reasoning.

## Provenance

The original `nvim_up.py` script was written by hand. The conversion to this
Lua plugin was done with human direction and AI assistance.

## License

MIT
