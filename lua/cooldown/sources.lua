local util = require('cooldown.util')
local lockfile = require('cooldown.lockfile')

local M = {}

-- Parse an 'owner/repo' shorthand or a full git URL into a normalized identity:
--   spec  pending-queue + display key (unique per host)
--   name  lockfile key (repo name = last path segment)
--   src   git clone URL (always with .git)
--   host  'github' (release tracking available) or 'other' (HEAD only, Tier 1)
--   owner/repo  path segments (for GitHub release endpoints + build ctx)
local function parse_target(str)
  -- Full URL: https://host/path[.git]  or  git@host:path[.git]
  local host = str:match('^%w+://([^/]+)/')
  local path
  if host then
    path = str:gsub('^%w+://[^/]+/', '')
  else
    host, path = str:match('^git@([^:]+):(.+)$')
  end

  if host and path then
    path = path:gsub('%.git$', ''):gsub('/+$', '')
    local owner, repo = path:match('^(.*)/([^/]+)$')
    if not repo then return nil end
    local is_gh = host:lower() == 'github.com'
    local src
    if str:match('^git@') then
      src = str:match('%.git$') and str or (str:gsub('/+$', '') .. '.git')
    else
      src = ('https://%s/%s.git'):format(host, path)
    end
    return {
      spec  = is_gh and (owner .. '/' .. repo) or (host .. '/' .. path),
      name  = repo,
      src   = src,
      host  = is_gh and 'github' or 'other',
      owner = owner,
      repo  = repo,
    }
  end

  -- 'owner/repo' shorthand → GitHub
  local owner, repo = str:match('^([^/]+)/([^/]+)$')
  if not owner then return nil end
  return {
    spec  = owner .. '/' .. repo,
    name  = repo,
    src   = ('https://github.com/%s/%s.git'):format(owner, repo),
    host  = 'github',
    owner = owner,
    repo  = repo,
  }
end

local function normalize_entry(entry)
  local str, track, build
  if type(entry) == 'string' then
    str = entry
  elseif type(entry) == 'table' then
    str = entry.spec or entry.src or entry[1]
    track, build = entry.track, entry.build
  end
  if type(str) ~= 'string' then return nil end

  local t = parse_target(str)
  if not t then return nil end
  t.track = track or 'auto'
  t.build = build
  -- Non-GitHub hosts can't (yet) detect releases, so 'auto' tracks HEAD.
  if t.host ~= 'github' and t.track == 'auto' then t.track = 'head' end
  return t
end

local function from_list(list)
  local out = {}
  for _, raw in ipairs(list) do
    local e = normalize_entry(raw)
    if e then out[#out + 1] = e end
  end
  return out
end

local function from_file(path)
  if not path or vim.fn.filereadable(path) == 0 then return nil end
  local data = util.read_json(path)
  if type(data) ~= 'table' then return {} end
  return from_list(data)
end

local function from_lockfile(path)
  local data = lockfile.read(path)
  local out = {}
  for _, info in pairs(lockfile.plugins(data)) do
    local e = normalize_entry(info.src or '')
    if e then out[#out + 1] = e end
  end
  return out
end

function M.resolve(opts)
  if opts.plugins and type(opts.plugins) == 'table' and #opts.plugins > 0 then
    return from_list(opts.plugins), 'inline'
  end
  if opts.plugins_file then
    local list = from_file(opts.plugins_file)
    if list then return list, 'file' end
  end
  return from_lockfile(opts.lockfile), 'lockfile'
end

return M
