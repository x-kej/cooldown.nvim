-- Reusable build helpers for cooldown.nvim plugin specs.
--
-- A spec's `build` is just a function(ctx); these are factories that return
-- one. `release_asset{}` covers the common "download a named binary/archive
-- from this plugin's GitHub release" case without the GitHub API or a token:
--   * the latest stable tag comes from the releases/latest redirect
--   * the asset list comes from the releases/expanded_assets page
--   * the asset + its .sha256 come from /releases/download/<tag>/<asset>
--
-- Builds run synchronously before vim.pack loads plugins, and are expected to
-- be idempotent (this helper no-ops when `dest` already exists).

local M = {}

local function notify(msg, level)
  vim.notify('cooldown.build: ' .. msg, level or vim.log.levels.INFO)
end

-- Platform placeholder values. Returns (vars, nil) or (nil, err).
local function platform_vars()
  local u       = vim.loop.os_uname()
  local machine = (u.machine or ''):lower()
  local sysname = (u.sysname or ''):lower()

  local arch
  if machine == 'x86_64' or machine == 'amd64' then arch = 'x86_64'
  elseif machine == 'aarch64' or machine == 'arm64' then arch = 'aarch64'
  else return nil, 'unsupported architecture: ' .. machine end

  local os_name, ext, rust_os
  if sysname:find('linux') then
    os_name, ext, rust_os = 'linux', 'so', 'unknown-linux-gnu'
  elseif sysname:find('darwin') then
    os_name, ext, rust_os = 'macos', 'dylib', 'apple-darwin'
  elseif sysname:find('windows') then
    os_name, ext, rust_os = 'windows', 'dll', 'pc-windows-msvc'
  else
    return nil, 'unsupported OS: ' .. sysname
  end

  return {
    arch           = arch,
    os             = os_name,
    ext            = ext,
    ['rust-triple'] = arch .. '-' .. rust_os,
  }
end

local function expand(template, vars)
  local missing
  local out = template:gsub('{([%w%-_]+)}', function(key)
    local v = vars[key]
    if v == nil then missing = key end
    return v or ('{' .. key .. '}')
  end)
  if missing then error('unknown placeholder {' .. missing .. '} in "' .. template .. '"') end
  return out
end

local function expand_path(template, vars)
  local p = expand(template, vars)
  if p:sub(1, 1) == '~' then p = vim.env.HOME .. p:sub(2) end
  return p
end

-- curl helpers (synchronous; builds already run on a blocking path).
local function curl_redirect(url)
  local res = vim.system(
    { 'curl', '-s', '-o', '/dev/null', '-w', '%{redirect_url}', '--max-time', '30',
      '-H', 'User-Agent: cooldown.nvim', url }, { text = true }):wait(35000)
  if res.code ~= 0 then return nil end
  local location = (res.stdout or ''):gsub('%s+$', '')
  return location
end

local function curl_text(url)
  local res = vim.system(
    { 'curl', '-sSL', '--fail', '--max-time', '30', '-H', 'User-Agent: cooldown.nvim', url },
    { text = true }):wait(35000)
  if res.code ~= 0 then return nil end
  return res.stdout or ''
end

local function curl_download(url, dest)
  vim.fn.mkdir(vim.fn.fnamemodify(dest, ':h'), 'p')
  local res = vim.system(
    { 'curl', '-sSL', '--fail', '--max-time', '120', '-o', dest,
      '-H', 'User-Agent: cooldown.nvim', url }):wait(125000)
  return res.code == 0
end

local function latest_tag(owner, repo)
  local loc = curl_redirect(('https://github.com/%s/%s/releases/latest'):format(owner, repo))
  return loc and loc:match('/releases/tag/(.+)$') or nil
end

-- Asset names available on a release, as a set. nil on fetch failure (so the
-- caller can proceed and let the download fail rather than block on listing).
local function list_assets(owner, repo, tag)
  local body = curl_text(('https://github.com/%s/%s/releases/expanded_assets/%s'):format(owner, repo, tag))
  if not body then return nil end
  local set = {}
  for name in body:gmatch('/releases/download/[^"]-/([^"/]+)"') do
    set[name] = true
  end
  return set
end

local function sha256_of(path)
  local res = vim.system({ 'sha256sum', path }, { text = true }):wait()
  if res.code ~= 0 then return nil end
  return (res.stdout or ''):match('^(%x+)')
end

local function extract(archive, destdir)
  vim.fn.mkdir(destdir, 'p')
  if archive:match('%.zip$') then
    if vim.fn.executable('unzip') ~= 1 then
      return false, 'unzip not found on PATH (needed for .zip assets)'
    end
    return vim.system({ 'unzip', '-oq', archive, '-d', destdir }):wait().code == 0
  end
  -- tar handles .tar.gz/.tgz/.tar.xz/.tar.bz2 etc. via -a/auto-compress detection
  return vim.system({ 'tar', '-xf', archive, '-C', destdir }):wait().code == 0
end

--- Build a `build` function that downloads a release asset.
--- @param opts table
---   asset   string | { linux=string, macos=string, windows=string }  -- asset name template(s)
---   dest    string  -- destination path template (file, or directory when extract is set)
---   extract boolean -- extract the downloaded archive into `dest` (a directory)
---   bin     string  -- optional: file inside `dest` to chmod +x after extract
function M.release_asset(opts)
  assert(type(opts) == 'table' and opts.asset and opts.dest,
         'release_asset requires { asset = ..., dest = ... }')

  return function(ctx)
    local vars, err = platform_vars()
    if not vars then return notify(err, vim.log.levels.WARN) end
    vars.sha   = ctx.sha
    vars.sha7  = ctx.sha:sub(1, 7)

    -- Fast idempotent path: if dest needs no {tag}, check it before any network.
    if not opts.dest:find('{tag}') and not opts.extract then
      local dest = expand_path(opts.dest, vars)
      if vim.uv.fs_stat(dest) then return end
    end

    local tag = latest_tag(ctx.owner, ctx.repo)
    if not tag then
      return notify(('%s/%s: could not resolve a release tag'):format(ctx.owner, ctx.repo),
                    vim.log.levels.WARN)
    end
    vars.tag = tag

    local asset_tmpl = opts.asset
    if type(asset_tmpl) == 'table' then asset_tmpl = asset_tmpl[vars.os] end
    if type(asset_tmpl) ~= 'string' then
      return notify(('%s/%s: no asset configured for OS %q'):format(ctx.owner, ctx.repo, vars.os),
                    vim.log.levels.WARN)
    end

    local ok, asset = pcall(expand, asset_tmpl, vars)
    if not ok then return notify(asset, vim.log.levels.ERROR) end

    local dest = expand_path(opts.dest, vars)
    if not opts.extract and vim.uv.fs_stat(dest) then return end
    if opts.extract and opts.bin and vim.uv.fs_stat(dest .. '/' .. opts.bin) then return end

    -- Catch upstream renaming their assets: alert with the real names instead
    -- of failing on a silent 404.
    local available = list_assets(ctx.owner, ctx.repo, tag)
    if available and next(available) and not available[asset] then
      local names = vim.tbl_keys(available)
      table.sort(names)
      return notify(('%s/%s %s: no asset matches %q. Available: %s — the project may have '
        .. 'changed its asset naming; update the `asset` template.'):format(
        ctx.owner, ctx.repo, tag, asset, table.concat(names, ', ')), vim.log.levels.ERROR)
    end
    if available and not next(available) then return end  -- source-only release

    local base = ('https://github.com/%s/%s/releases/download/%s'):format(ctx.owner, ctx.repo, tag)
    local download_to = opts.extract and (vim.fn.tempname() .. '-' .. asset) or dest

    notify(('downloading %s %s (%s)'):format(ctx.repo, tag, asset))
    if not curl_download(base .. '/' .. asset, download_to) then
      return notify(('%s/%s: download failed for %s'):format(ctx.owner, ctx.repo, asset),
                    vim.log.levels.ERROR)
    end

    -- Checksum: mandatory when the release ships a <asset>.sha256 companion.
    if not available or available[asset .. '.sha256'] then
      local sums = curl_text(base .. '/' .. asset .. '.sha256')
      local want = sums and sums:match('^(%x+)')
      if want then
        local got = sha256_of(download_to)
        if want ~= got then
          os.remove(download_to)
          return notify(('%s/%s: SHA256 mismatch, discarded %s'):format(ctx.owner, ctx.repo, asset),
                        vim.log.levels.ERROR)
        end
      else
        notify(('%s/%s: no checksum available, skipping verification'):format(ctx.owner, ctx.repo),
               vim.log.levels.WARN)
      end
    end

    if opts.extract then
      local ok_x, xerr = extract(download_to, dest)
      os.remove(download_to)
      if not ok_x then
        return notify(('%s/%s: extraction failed%s'):format(
          ctx.owner, ctx.repo, xerr and (': ' .. xerr) or ''), vim.log.levels.ERROR)
      end
      if opts.bin then
        local binpath = dest .. '/' .. opts.bin
        local st = vim.uv.fs_stat(binpath)
        if st then vim.loop.fs_chmod(binpath, tonumber('755', 8)) end
      end
    end

    notify(('installed %s %s'):format(ctx.repo, tag))
  end
end

return M
