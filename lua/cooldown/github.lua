-- Discovery layer for cooldown.nvim.
--
-- Intentionally avoids api.github.com so that no authentication is required.
-- Two sources, both unauthenticated and not rate-limited in any meaningful way
-- for our use case:
--
--   git ls-remote <url> HEAD               → latest commit SHA
--   git ls-remote <url> refs/tags/<tag>^{} → commit SHA for a release tag
--   https://github.com/<o>/<r>/releases.atom → latest release tag + published_at
--
-- HTTP fetching for the atom feed prefers curl, with a PowerShell fallback for
-- Windows boxes that lack curl. Git is used directly for ref discovery, which
-- avoids needing any HTTP backend for HEAD-tracked plugins.

local M = {}

local has_curl = vim.fn.executable('curl') == 1
local has_git  = vim.fn.executable('git')  == 1
local has_pwsh = vim.fn.executable('pwsh') == 1 or vim.fn.executable('powershell') == 1
local is_windows = (vim.loop.os_uname().sysname or ''):lower():match('windows') ~= nil

M.backend = has_curl and 'curl' or (is_windows and has_pwsh and 'powershell' or nil)
M.has_git = has_git

local function powershell_exe()
  return vim.fn.executable('pwsh') == 1 and 'pwsh' or 'powershell'
end

local function build_curl_args(url)
  return { 'curl', '-sSL', '--fail', '--max-time', '30',
           '-H', 'User-Agent: cooldown.nvim', url }
end

-- Args to print the redirect target of `url` without following it. Used to read
-- the `releases/latest` redirect, which points at the latest *stable* release
-- tag (honoring the maintainer's "latest" designation) or back at `/releases`
-- when there is none.
local function build_curl_redirect_args(url)
  return { 'curl', '-s', '-o', (is_windows and 'NUL' or '/dev/null'),
           '-w', '%{redirect_url}', '--max-time', '30',
           '-H', 'User-Agent: cooldown.nvim', url }
end

local function build_ps_redirect_args(url)
  local script = table.concat({
    "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12;",
    "try {",
    ("  $r = Invoke-WebRequest -Uri '%s' -MaximumRedirection 0 "):format(url),
    "    -UseBasicParsing -ErrorAction SilentlyContinue;",
    "} catch { $r = $_.Exception.Response }",
    "if ($r -and $r.Headers -and $r.Headers.Location) { Write-Output $r.Headers.Location }",
  }, '')
  return { powershell_exe(), '-NoProfile', '-NonInteractive', '-Command', script }
end

local function build_ps_args(url)
  local script = table.concat({
    "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12;",
    ("$r = Invoke-WebRequest -Uri '%s' -Headers @{'User-Agent'='cooldown.nvim'} "
      .. "-TimeoutSec 30 -UseBasicParsing;"):format(url),
    "$out = [Console]::OpenStandardOutput();",
    "$out.Write($r.Content, 0, $r.Content.Length); $out.Flush();",
  }, '')
  return { powershell_exe(), '-NoProfile', '-NonInteractive', '-Command', script }
end

local function http_args(url)
  if M.backend == 'powershell' then return build_ps_args(url) end
  return build_curl_args(url)
end

function M.fetch_bytes_async(url, _opts, cb)
  if not M.backend then
    return vim.schedule(function() cb(nil, 'no HTTP backend available') end)
  end
  vim.system(http_args(url), { text = false }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        cb(nil, ('HTTP failed for %s'):format(url))
      else
        cb(res.stdout)
      end
    end)
  end)
end

local function fetch_redirect_async(url, cb)
  if not M.backend then
    return vim.schedule(function() cb(nil, 'no HTTP backend available') end)
  end
  local args = M.backend == 'powershell'
    and build_ps_redirect_args(url) or build_curl_redirect_args(url)
  vim.system(args, { text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        cb(nil, ('HTTP redirect probe failed for %s'):format(url))
      else
        local location = (res.stdout or ''):gsub('%s+$', '')
        cb(location)
      end
    end)
  end)
end

local function git_ls_remote(args, cb)
  if not has_git then
    return vim.schedule(function() cb(nil, 'git is not available on PATH') end)
  end
  vim.system(args, { text = true, env = { GIT_TERMINAL_PROMPT = '0' } }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        cb(nil, ('git ls-remote failed: %s'):format(
          ((res.stderr or ''):gsub('%s+$', '')):sub(1, 200)))
      else
        cb(res.stdout or '')
      end
    end)
  end)
end

local function git_url(owner, repo)
  return ('https://github.com/%s/%s.git'):format(owner, repo)
end

-- Host-agnostic: works against any git remote (GitHub, Codeberg, GitLab, ...).
local function git_head_sha(src, cb)
  git_ls_remote({ 'git', 'ls-remote', src, 'HEAD' }, function(out, err)
    if err then return cb(nil, err) end
    local sha = (out or ''):match('^(%x+)')
    if not sha or #sha < 40 then return cb(nil, 'no HEAD ref in response') end
    cb(sha)
  end)
end

local function git_tag_sha(owner, repo, tag, cb)
  local args = { 'git', 'ls-remote', git_url(owner, repo),
                 'refs/tags/' .. tag, 'refs/tags/' .. tag .. '^{}' }
  git_ls_remote(args, function(out, err)
    if err then return cb(nil, err) end
    local deref, fallback
    for line in (out or ''):gmatch('[^\n]+') do
      local s, ref = line:match('^(%x+)%s+(.+)$')
      if ref then
        if ref:sub(-3) == '^{}' then deref = s
        else fallback = s end
      end
    end
    local sha = deref or fallback
    if not sha then return cb(nil, 'tag ' .. tag .. ' not found') end
    cb(sha)
  end)
end

-- Find the <updated> date for a specific release tag in an atom feed body.
-- Returns the ISO date string, or nil if that tag isn't in the (recent) feed.
local function atom_date_for_tag(body, tag)
  if not body or body == '' then return nil end
  for entry in body:gmatch('<entry>(.-)</entry>') do
    local etag = entry:match('/releases/tag/([^"]+)"')
    if etag == tag then
      return entry:match('<updated>([^<]+)</updated>')
    end
  end
  return nil
end

-- Read the latest *stable* release tag via the releases/latest redirect.
-- Calls cb(tag_or_nil, err). tag is nil (no err) when the repo has no
-- release marked latest.
local function latest_stable_tag(owner, repo, cb)
  local url = ('https://github.com/%s/%s/releases/latest'):format(owner, repo)
  fetch_redirect_async(url, function(location, err)
    if err then return cb(nil, err) end
    local tag = (location or ''):match('/releases/tag/(.+)$')
    cb(tag)  -- tag may be nil → no stable release
  end)
end

-- Resolve the target SHA + (optional) release date for a plugin entry.
-- `plug` is a normalized spec: { src, host, owner, repo, track }.
-- Calls cb(target_sha, target_date_iso, err).
--
-- HEAD discovery (git ls-remote) is host-agnostic. Release discovery (the
-- releases/latest redirect, expanded_assets, atom date) is GitHub-only — see
-- the "Roadmap" note in README for non-GitHub release tracking (Tier 2).
function M.fetch_target_async(plug, cb)
  local function via_head()
    git_head_sha(plug.src, function(sha, err) cb(sha, nil, err) end)
  end

  if plug.track == 'head' then return via_head() end

  if plug.host ~= 'github' then
    if plug.track == 'release' then
      return cb(nil, nil, 'release tracking is GitHub-only for now; set track="head"')
    end
    return via_head()  -- 'auto' on a non-GitHub host falls back to HEAD
  end

  latest_stable_tag(plug.owner, plug.repo, function(tag, err)
    if err then
      if plug.track == 'release' then return cb(nil, nil, err) end
      return via_head()
    end
    if not tag then
      if plug.track == 'release' then return cb(nil, nil, 'no GitHub release marked latest') end
      return via_head()
    end
    git_tag_sha(plug.owner, plug.repo, tag, function(sha, gerr)
      if gerr then return cb(nil, nil, gerr) end
      -- Best-effort publish date from the atom feed; fall back to first-seen
      -- (target_date = nil) when the tag is older than the recent feed window.
      local atom_url = ('https://github.com/%s/%s/releases.atom'):format(plug.owner, plug.repo)
      M.fetch_bytes_async(atom_url, nil, function(body)
        cb(sha, atom_date_for_tag(body, tag))
      end)
    end)
  end)
end

-- Kept for tests / non-Neovim scripting. Synchronous form of fetch_target_async.
function M.fetch_target_sync(plug)
  local result_sha, result_date, result_err
  local done = false
  M.fetch_target_async(plug, function(sha, dt, err)
    result_sha, result_date, result_err = sha, dt, err
    done = true
  end)
  vim.wait(35000, function() return done end, 50)
  return result_sha, result_date, result_err
end

return M
