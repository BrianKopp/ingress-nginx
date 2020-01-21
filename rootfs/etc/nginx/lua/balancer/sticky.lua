local balancer_resty = require("balancer.resty")
local ck = require("resty.cookie")
local ngx_balancer = require("ngx.balancer")
local split = require("util.split")
local same_site = require("util.same_site")

local _M = balancer_resty:new()
local DEFAULT_COOKIE_NAME = "route"

function _M.cookie_name(self)
  return self.cookie_session_affinity.name or DEFAULT_COOKIE_NAME
end

function _M.new(self)
  local o = {
    alternative_backends = nil,
    cookie_session_affinity = nil,
    traffic_shaping_policy = nil
  }

  setmetatable(o, self)
  self.__index = self

  return o
end

function _M.get_cookie(self)
  local cookie, err = ck:new()
  if not cookie then
    ngx.log(ngx.ERR, err)
  end

  return cookie:get(self:cookie_name())
end

function _M.set_cookie(self, value)
  local cookie, err = ck:new()
  if not cookie then
    ngx.log(ngx.ERR, err)
  end

  local cookie_path = self.cookie_session_affinity.path
  if not cookie_path then
    cookie_path = ngx.var.location_path
  end

  local cookie_samesite = self.cookie_session_affinity.samesite
  if cookie_samesite then
    local cookie_conditional_samesite_none = self.cookie_session_affinity.conditional_samesite_none
    if cookie_conditional_samesite_none and cookie_samesite == "None" and not same_site.same_site_none_compatible(ngx.var.http_user_agent) then
      cookie_samesite = nil
    end
  end

  if cookie_samesite then
    cookie_path = cookie_path .. "; SameSite=" .. cookie_samesite
  end

  local cookie_data = {
    key = self:cookie_name(),
    value = value,
    path = cookie_path,
    httponly = true,
    secure = ngx.var.https == "on",
  }

  if self.cookie_session_affinity.expires and self.cookie_session_affinity.expires ~= "" then
      cookie_data.expires = ngx.cookie_time(ngx.time() + tonumber(self.cookie_session_affinity.expires))
  end

  if self.cookie_session_affinity.maxage and self.cookie_session_affinity.maxage ~= "" then
    cookie_data.max_age = tonumber(self.cookie_session_affinity.maxage)
  end

  local ok
  ok, err = cookie:set(cookie_data)
  if not ok then
    ngx.log(ngx.ERR, err)
  end
end

function _M.get_last_failure()
  return ngx_balancer.get_last_failure()
end

local function get_failed_upstreams()
  local indexed_upstream_addrs = {}
  local upstream_addrs = split.split_upstream_var(ngx.var.upstream_addr) or {}

  for _, addr in ipairs(upstream_addrs) do
    indexed_upstream_addrs[addr] = true
  end

  return indexed_upstream_addrs
end

local function should_set_cookie(self)
  if self.cookie_session_affinity.locations and ngx.var.host then
    local locs = self.cookie_session_affinity.locations[ngx.var.host]
    if locs == nil then
      -- Based off of wildcard hostname in ../certificate.lua
      local wildcard_host, _, err = ngx.re.sub(ngx.var.host, "^[^\\.]+\\.", "*.", "jo")
      if err then
        ngx.log(ngx.ERR, "error: ", err);
      elseif wildcard_host then
        locs = self.cookie_session_affinity.locations[wildcard_host]
      end
    end

    if locs ~= nil then
      for _, path in pairs(locs) do
        if ngx.var.location_path == path then
          return true
        end
      end
    end
  end

  return false
end

function _M.balance(self)
  local upstream_from_cookie

  local key = self:get_cookie()
  if key then
    upstream_from_cookie = self.instance:find(key)
  end

  local last_failure = self.get_last_failure()
  local should_pick_new_upstream = last_failure ~= nil and self.cookie_session_affinity.change_on_failure or
    upstream_from_cookie == nil

  if not should_pick_new_upstream then
    return upstream_from_cookie
  end

  local new_upstream

  new_upstream, key = self:pick_new_upstream(get_failed_upstreams())
  if not new_upstream then
    ngx.log(ngx.WARN, string.format("failed to get new upstream; using upstream %s", new_upstream))
  elseif should_set_cookie(self) then
    self:set_cookie(key)
  end

  return new_upstream
end

function _M.sync(self, backend)
  -- reload balancer nodes
  balancer_resty.sync(self, backend)

  self.traffic_shaping_policy = backend.trafficShapingPolicy
  self.alternative_backends = backend.alternativeBackends
  self.cookie_session_affinity = backend.sessionAffinityConfig.cookieSessionAffinity
end

return _M
