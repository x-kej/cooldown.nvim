local util = require('cooldown.util')

local M = {}

function M.read(path)
  local data = util.read_json(path)
  if type(data.plugins) ~= 'table' then data.plugins = {} end
  return data
end

function M.write(path, data)
  util.write_json(path, data)
end

function M.plugins(data)
  return data.plugins or {}
end

function M.locked_sha(entry)
  if type(entry) == 'string' then return entry end
  if type(entry) == 'table' then
    return entry.rev or entry.commit or entry.sha or ''
  end
  return ''
end

function M.set_plugin(data, name, src, sha)
  if not name or not src then return false end
  data.plugins = data.plugins or {}
  data.plugins[name] = { rev = sha, src = src }
  return true
end

function M.find_repo(data, repo_name)
  return (data.plugins or {})[repo_name]
end

return M
