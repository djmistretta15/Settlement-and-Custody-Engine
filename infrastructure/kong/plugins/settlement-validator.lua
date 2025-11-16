-------------------------------------------------------------------------------
-- Kong Custom Plugin: Settlement Request Validator
--
-- Production-grade request validation for Settlement and Custody Engine:
-- - Schema validation for settlement requests
-- - Address format verification (Ethereum, Bitcoin)
-- - Amount validation (overflow, precision)
-- - Chain ID verification
-- - Business rule enforcement
-- - Compliance checks
--
-- @module settlement-validator
-------------------------------------------------------------------------------

local kong = kong
local ngx = ngx
local cjson = require "cjson.safe"
local re_match = ngx.re.match

local SettlementValidatorHandler = {
  VERSION = "1.0.0",
  PRIORITY = 900, -- Run after authentication
}

-------------------------------------------------------------------------------
-- Configuration Schema
-------------------------------------------------------------------------------

local schema = {
  name = "settlement-validator",
  fields = {
    {
      config = {
        type = "record",
        fields = {
          {
            max_amount = {
              type = "string",
              required = false,
              default = "115792089237316195423570985008687907853269984665640564039457584007913129639935", -- uint256 max
            },
          },
          {
            min_amount = {
              type = "string",
              required = false,
              default = "1000000000000000", -- 0.001 ETH in wei
            },
          },
          {
            allowed_source_chains = {
              type = "array",
              elements = { type = "number" },
              required = false,
              default = { 1, 137, 42161, 10, 8453 }, -- Ethereum, Polygon, Arbitrum, Optimism, Base
            },
          },
          {
            allowed_dest_chains = {
              type = "array",
              elements = { type = "number" },
              required = false,
              default = { 1, 137, 42161, 10, 8453 },
            },
          },
          {
            blocked_addresses = {
              type = "array",
              elements = { type = "string" },
              required = false,
              default = {},
            },
          },
          {
            require_kyc_check = {
              type = "boolean",
              required = false,
              default = true,
            },
          },
          {
            kyc_service_url = {
              type = "string",
              required = false,
              default = "http://kyc-service:8082/verify",
            },
          },
          {
            max_daily_volume = {
              type = "string",
              required = false,
              default = "1000000000000000000000000", -- 1M ETH
            },
          },
          {
            enforce_same_chain_restriction = {
              type = "boolean",
              required = false,
              default = true,
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

-- Validate Ethereum address format
local function is_valid_eth_address(address)
  if not address or type(address) ~= "string" then
    return false, "Address must be a string"
  end

  -- Check format: 0x followed by 40 hex characters
  local match, err = re_match(address, "^0x[a-fA-F0-9]{40}$", "jo")
  if err then
    return false, "Regex error: " .. err
  end

  if not match then
    return false, "Invalid Ethereum address format"
  end

  -- Check for zero address
  if address == "0x0000000000000000000000000000000000000000" then
    return false, "Zero address is not allowed"
  end

  return true, nil
end

-- Validate Bitcoin address format (basic check)
local function is_valid_btc_address(address)
  if not address or type(address) ~= "string" then
    return false, "Address must be a string"
  end

  -- Legacy (P2PKH): starts with 1, 25-34 chars
  -- Script (P2SH): starts with 3, 25-34 chars
  -- SegWit (Bech32): starts with bc1, 42-62 chars
  local p2pkh = re_match(address, "^1[a-km-zA-HJ-NP-Z1-9]{25,34}$", "jo")
  local p2sh = re_match(address, "^3[a-km-zA-HJ-NP-Z1-9]{25,34}$", "jo")
  local bech32 = re_match(address, "^bc1[a-z0-9]{39,59}$", "jo")

  if not p2pkh and not p2sh and not bech32 then
    return false, "Invalid Bitcoin address format"
  end

  return true, nil
end

-- Compare large numbers represented as strings
local function compare_big_numbers(a, b)
  -- Remove leading zeros
  a = a:gsub("^0+", "") or "0"
  b = b:gsub("^0+", "") or "0"

  if a == "" then a = "0" end
  if b == "" then b = "0" end

  -- Compare lengths first
  if #a ~= #b then
    return #a < #b and -1 or 1
  end

  -- Same length, compare lexicographically
  if a < b then
    return -1
  elseif a > b then
    return 1
  else
    return 0
  end
end

-- Check if amount is within valid range
local function validate_amount(amount, min_amount, max_amount)
  if not amount or type(amount) ~= "string" then
    return false, "Amount must be a string"
  end

  -- Check format: only digits
  local match = re_match(amount, "^[0-9]+$", "jo")
  if not match then
    return false, "Amount must be a numeric string"
  end

  -- Check minimum
  if compare_big_numbers(amount, min_amount) < 0 then
    return false, "Amount is below minimum threshold"
  end

  -- Check maximum (uint256 overflow protection)
  if compare_big_numbers(amount, max_amount) > 0 then
    return false, "Amount exceeds maximum allowed value"
  end

  return true, nil
end

-- Check if chain ID is allowed
local function is_allowed_chain(chain_id, allowed_chains)
  for _, allowed in ipairs(allowed_chains) do
    if chain_id == allowed then
      return true
    end
  end
  return false
end

-- Check if address is blocked (sanctions, etc.)
local function is_blocked_address(address, blocked_list)
  local normalized = address:lower()
  for _, blocked in ipairs(blocked_list) do
    if normalized == blocked:lower() then
      return true
    end
  end
  return false
end

-- Verify KYC status
local function verify_kyc(config, sender, receiver)
  if not config.require_kyc_check then
    return true, nil
  end

  local http = require "resty.http"
  local httpc = http.new()

  local payload = cjson.encode({
    addresses = { sender, receiver },
    check_type = "settlement",
  })

  local res, err = httpc:request_uri(config.kyc_service_url, {
    method = "POST",
    body = payload,
    headers = {
      ["Content-Type"] = "application/json",
      ["X-Internal-Auth"] = "kong-validator",
    },
    timeout = 5000,
  })

  if not res then
    kong.log.err("KYC service unavailable: ", err)
    -- Fail open or closed based on risk tolerance
    return false, "KYC verification service unavailable"
  end

  if res.status ~= 200 then
    local body = cjson.decode(res.body)
    return false, body and body.message or "KYC verification failed"
  end

  local body = cjson.decode(res.body)
  if not body or not body.verified then
    return false, body and body.reason or "KYC check failed"
  end

  return true, nil
end

-------------------------------------------------------------------------------
-- Plugin Phases
-------------------------------------------------------------------------------

-- Access phase - Validate settlement requests
function SettlementValidatorHandler:access(config)
  local method = kong.request.get_method()
  local path = kong.request.get_path()

  -- Only validate POST/PUT requests to settlement endpoints
  if not (method == "POST" or method == "PUT") then
    return
  end

  if not path:match("/settlements") then
    return
  end

  -- Parse request body
  local body_data = kong.request.get_body()
  if not body_data then
    return kong.response.exit(400, {
      error = "BAD_REQUEST",
      message = "Request body is required",
    })
  end

  -- Validate required fields
  local required_fields = { "sender", "receiver", "amount", "sourceChain", "destChain" }
  for _, field in ipairs(required_fields) do
    if not body_data[field] then
      return kong.response.exit(400, {
        error = "VALIDATION_ERROR",
        field = field,
        message = "Missing required field: " .. field,
      })
    end
  end

  -- Validate sender address
  local valid, err = is_valid_eth_address(body_data.sender)
  if not valid then
    return kong.response.exit(400, {
      error = "VALIDATION_ERROR",
      field = "sender",
      message = err,
    })
  end

  -- Validate receiver address
  valid, err = is_valid_eth_address(body_data.receiver)
  if not valid then
    return kong.response.exit(400, {
      error = "VALIDATION_ERROR",
      field = "receiver",
      message = err,
    })
  end

  -- Check if sender equals receiver
  if body_data.sender:lower() == body_data.receiver:lower() then
    return kong.response.exit(400, {
      error = "VALIDATION_ERROR",
      message = "Sender and receiver cannot be the same address",
    })
  end

  -- Validate amount
  valid, err = validate_amount(body_data.amount, config.min_amount, config.max_amount)
  if not valid then
    return kong.response.exit(400, {
      error = "VALIDATION_ERROR",
      field = "amount",
      message = err,
    })
  end

  -- Validate source chain
  if type(body_data.sourceChain) ~= "number" then
    return kong.response.exit(400, {
      error = "VALIDATION_ERROR",
      field = "sourceChain",
      message = "Source chain must be a number",
    })
  end

  if not is_allowed_chain(body_data.sourceChain, config.allowed_source_chains) then
    return kong.response.exit(400, {
      error = "VALIDATION_ERROR",
      field = "sourceChain",
      message = "Source chain is not supported",
    })
  end

  -- Validate destination chain
  if type(body_data.destChain) ~= "number" then
    return kong.response.exit(400, {
      error = "VALIDATION_ERROR",
      field = "destChain",
      message = "Destination chain must be a number",
    })
  end

  if not is_allowed_chain(body_data.destChain, config.allowed_dest_chains) then
    return kong.response.exit(400, {
      error = "VALIDATION_ERROR",
      field = "destChain",
      message = "Destination chain is not supported",
    })
  end

  -- Check same chain restriction
  if config.enforce_same_chain_restriction and body_data.sourceChain == body_data.destChain then
    return kong.response.exit(400, {
      error = "VALIDATION_ERROR",
      message = "Same-chain settlements are not allowed",
    })
  end

  -- Check blocked addresses
  if is_blocked_address(body_data.sender, config.blocked_addresses) then
    kong.log.err("Blocked sender address: ", body_data.sender)
    return kong.response.exit(403, {
      error = "FORBIDDEN",
      message = "Sender address is not allowed",
    })
  end

  if is_blocked_address(body_data.receiver, config.blocked_addresses) then
    kong.log.err("Blocked receiver address: ", body_data.receiver)
    return kong.response.exit(403, {
      error = "FORBIDDEN",
      message = "Receiver address is not allowed",
    })
  end

  -- Verify KYC status
  valid, err = verify_kyc(config, body_data.sender, body_data.receiver)
  if not valid then
    return kong.response.exit(403, {
      error = "KYC_REQUIRED",
      message = err or "KYC verification required",
    })
  end

  -- Store validated data in context
  kong.ctx.shared.validated_settlement = {
    sender = body_data.sender:lower(),
    receiver = body_data.receiver:lower(),
    amount = body_data.amount,
    sourceChain = body_data.sourceChain,
    destChain = body_data.destChain,
  }

  -- Add validation headers
  kong.service.request.set_header("X-Validated", "true")
  kong.service.request.set_header("X-Validation-Version", SettlementValidatorHandler.VERSION)
end

-- Header filter phase
function SettlementValidatorHandler:header_filter(config)
  if kong.ctx.shared.validated_settlement then
    kong.response.set_header("X-Settlement-Validated", "true")
  end
end

return SettlementValidatorHandler
