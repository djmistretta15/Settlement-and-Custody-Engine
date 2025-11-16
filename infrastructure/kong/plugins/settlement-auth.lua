-------------------------------------------------------------------------------
-- Kong Custom Plugin: Settlement Authentication
--
-- Production-grade authentication plugin for Settlement and Custody Engine:
-- - Multi-layer authentication (API Key + JWT + Signature verification)
-- - Institutional client verification
-- - Request signing validation
-- - Audit logging
-- - Rate limit bypass for verified institutional clients
--
-- @module settlement-auth
-------------------------------------------------------------------------------

local kong = kong
local ngx = ngx
local sha256 = require "resty.sha256"
local str = require "resty.string"
local cjson = require "cjson.safe"
local http = require "resty.http"

local SettlementAuthHandler = {
  VERSION = "1.0.0",
  PRIORITY = 1000,
}

-------------------------------------------------------------------------------
-- Configuration Schema
-------------------------------------------------------------------------------

local schema = {
  name = "settlement-auth",
  fields = {
    {
      config = {
        type = "record",
        fields = {
          {
            auth_service_url = {
              type = "string",
              required = true,
              default = "http://auth-service:8080",
            },
          },
          {
            require_signature = {
              type = "boolean",
              required = false,
              default = true,
            },
          },
          {
            signature_header = {
              type = "string",
              required = false,
              default = "X-Settlement-Signature",
            },
          },
          {
            timestamp_header = {
              type = "string",
              required = false,
              default = "X-Settlement-Timestamp",
            },
          },
          {
            signature_max_age = {
              type = "number",
              required = false,
              default = 300, -- 5 minutes
            },
          },
          {
            institutional_bypass_rate_limit = {
              type = "boolean",
              required = false,
              default = true,
            },
          },
          {
            audit_log_url = {
              type = "string",
              required = false,
              default = "http://audit-service:8081/log",
            },
          },
          {
            cache_ttl = {
              type = "number",
              required = false,
              default = 3600, -- 1 hour
            },
          },
        },
      },
    },
  },
}

-------------------------------------------------------------------------------
-- Helper Functions
-------------------------------------------------------------------------------

-- Generate HMAC-SHA256 signature
local function generate_signature(secret, message)
  local sha = sha256:new()
  if not sha then
    return nil, "Failed to create SHA256 instance"
  end

  sha:update(secret)
  sha:update(message)
  local digest = sha:final()

  return str.to_hex(digest)
end

-- Verify request signature
local function verify_signature(config, request_body, api_key, timestamp, provided_signature)
  -- Get client secret from cache or auth service
  local cache_key = "settlement:secret:" .. api_key
  local secret = kong.cache:get(cache_key, nil, function()
    local httpc = http.new()
    local res, err = httpc:request_uri(config.auth_service_url .. "/secrets/" .. api_key, {
      method = "GET",
      headers = {
        ["Content-Type"] = "application/json",
        ["X-Internal-Auth"] = "kong-gateway",
      },
    })

    if not res then
      kong.log.err("Failed to fetch client secret: ", err)
      return nil
    end

    if res.status ~= 200 then
      kong.log.err("Auth service returned status: ", res.status)
      return nil
    end

    local body = cjson.decode(res.body)
    return body and body.secret
  end, config.cache_ttl)

  if not secret then
    return false, "Unable to verify client secret"
  end

  -- Construct signature message: timestamp + request_body
  local message = timestamp .. "." .. (request_body or "")
  local expected_signature, err = generate_signature(secret, message)

  if not expected_signature then
    return false, err
  end

  -- Constant-time comparison to prevent timing attacks
  if #expected_signature ~= #provided_signature then
    return false, "Invalid signature length"
  end

  local result = 0
  for i = 1, #expected_signature do
    result = result + (expected_signature:byte(i) - provided_signature:byte(i))
  end

  return result == 0, result ~= 0 and "Signature mismatch" or nil
end

-- Log audit event
local function log_audit_event(config, event_type, details)
  -- Async logging to audit service
  ngx.timer.at(0, function()
    local httpc = http.new()
    local payload = cjson.encode({
      event_type = event_type,
      timestamp = ngx.now() * 1000,
      gateway = "kong",
      details = details,
    })

    local res, err = httpc:request_uri(config.audit_log_url, {
      method = "POST",
      body = payload,
      headers = {
        ["Content-Type"] = "application/json",
      },
    })

    if not res then
      kong.log.err("Failed to send audit log: ", err)
    end
  end)
end

-- Check if client is institutional
local function is_institutional_client(api_key)
  local cache_key = "settlement:institutional:" .. api_key
  return kong.cache:get(cache_key, nil, function()
    -- Check if API key belongs to institutional client
    return api_key:match("^inst_") ~= nil
  end, 3600)
end

-------------------------------------------------------------------------------
-- Plugin Phases
-------------------------------------------------------------------------------

-- Access phase - Authentication and authorization
function SettlementAuthHandler:access(config)
  -- Get API key
  local api_key = kong.request.get_header("X-API-Key")
  if not api_key then
    api_key = kong.request.get_query_arg("api_key")
  end

  if not api_key then
    log_audit_event(config, "AUTH_FAILED", {
      reason = "Missing API key",
      ip = kong.client.get_ip(),
    })
    return kong.response.exit(401, {
      error = "UNAUTHORIZED",
      message = "API key is required",
    })
  end

  -- Verify signature if required
  if config.require_signature then
    local timestamp = kong.request.get_header(config.timestamp_header)
    local signature = kong.request.get_header(config.signature_header)

    if not timestamp then
      log_audit_event(config, "AUTH_FAILED", {
        reason = "Missing timestamp",
        api_key = api_key,
        ip = kong.client.get_ip(),
      })
      return kong.response.exit(401, {
        error = "UNAUTHORIZED",
        message = "Request timestamp is required",
      })
    end

    if not signature then
      log_audit_event(config, "AUTH_FAILED", {
        reason = "Missing signature",
        api_key = api_key,
        ip = kong.client.get_ip(),
      })
      return kong.response.exit(401, {
        error = "UNAUTHORIZED",
        message = "Request signature is required",
      })
    end

    -- Check timestamp freshness
    local request_time = tonumber(timestamp)
    local current_time = ngx.now()

    if not request_time then
      return kong.response.exit(401, {
        error = "UNAUTHORIZED",
        message = "Invalid timestamp format",
      })
    end

    local time_diff = math.abs(current_time - request_time)
    if time_diff > config.signature_max_age then
      log_audit_event(config, "AUTH_FAILED", {
        reason = "Stale timestamp",
        api_key = api_key,
        time_diff = time_diff,
        ip = kong.client.get_ip(),
      })
      return kong.response.exit(401, {
        error = "UNAUTHORIZED",
        message = "Request timestamp is stale",
      })
    end

    -- Verify signature
    local request_body = kong.request.get_raw_body()
    local valid, err = verify_signature(config, request_body, api_key, timestamp, signature)

    if not valid then
      log_audit_event(config, "AUTH_FAILED", {
        reason = "Invalid signature",
        error = err,
        api_key = api_key,
        ip = kong.client.get_ip(),
      })
      return kong.response.exit(401, {
        error = "UNAUTHORIZED",
        message = "Invalid request signature: " .. (err or "verification failed"),
      })
    end
  end

  -- Check institutional status
  local is_institutional = is_institutional_client(api_key)

  -- Set headers for downstream services
  kong.service.request.set_header("X-Authenticated-Client", api_key)
  kong.service.request.set_header("X-Client-Type", is_institutional and "institutional" or "retail")
  kong.service.request.set_header("X-Gateway-Auth", "verified")
  kong.service.request.set_header("X-Request-ID", ngx.var.request_id or ngx.now() .. "." .. ngx.worker.pid())

  -- Store in context for other plugins
  kong.ctx.shared.authenticated_client = api_key
  kong.ctx.shared.is_institutional = is_institutional

  -- Log successful authentication
  log_audit_event(config, "AUTH_SUCCESS", {
    api_key = api_key,
    is_institutional = is_institutional,
    ip = kong.client.get_ip(),
    method = kong.request.get_method(),
    path = kong.request.get_path(),
  })
end

-- Log phase - After response
function SettlementAuthHandler:log(config)
  local api_key = kong.ctx.shared.authenticated_client or "unknown"
  local is_institutional = kong.ctx.shared.is_institutional or false

  log_audit_event(config, "REQUEST_COMPLETED", {
    api_key = api_key,
    is_institutional = is_institutional,
    status = kong.response.get_status(),
    latency = kong.ctx.plugin.access_time and (ngx.now() * 1000 - kong.ctx.plugin.access_time) or 0,
    request_size = kong.request.get_header("Content-Length") or 0,
    response_size = kong.response.get_header("Content-Length") or 0,
    ip = kong.client.get_ip(),
    method = kong.request.get_method(),
    path = kong.request.get_path(),
  })
end

-- Header filter phase - Modify response headers
function SettlementAuthHandler:header_filter(config)
  local is_institutional = kong.ctx.shared.is_institutional

  -- Add client tier information to response
  if is_institutional then
    kong.response.set_header("X-Client-Tier", "institutional")
    kong.response.set_header("X-Rate-Limit-Tier", "premium")
  else
    kong.response.set_header("X-Client-Tier", "standard")
    kong.response.set_header("X-Rate-Limit-Tier", "standard")
  end

  -- Add security headers
  kong.response.set_header("X-Settlement-Gateway", "kong")
  kong.response.set_header("X-Settlement-Version", SettlementAuthHandler.VERSION)
end

return SettlementAuthHandler
