--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--

local bp_manager_mod  = require("apisix.utils.batch-processor-manager")
local core            = require("apisix.core")
local http            = require("resty.http")
local uuid            = require("resty.jit-uuid")
local ngx             = ngx
local ngx_time        = ngx.time
local ngx_now         = ngx.now
local tostring        = tostring
local ipairs          = ipairs
local pairs           = pairs
local type            = type
local math            = math
local string_match    = string.match
local ngx_encode_base64 = ngx.encode_base64

local plugin_name = "ai-langfuse-tracing"
local batch_processor_manager = bp_manager_mod.new("ai-langfuse-tracing")

local schema = {
    type = "object",
    properties = {
        langfuse_public_key = {
            type = "string",
            description = "Langfuse public key for authentication"
        },
        langfuse_secret_key = {
            type = "string",
            description = "Langfuse secret key for authentication"
        },
        langfuse_host = {
            type = "string",
            default = "https://cloud.langfuse.com",
            description = "Langfuse API endpoint"
        },
        timeout = {
            type = "integer",
            minimum = 1,
            default = 5,
            description = "HTTP timeout in seconds"
        },
        detect_ai_requests = {
            type = "boolean",
            default = true,
            description = "Only trace AI API requests"
        },
        ai_endpoints = {
            type = "array",
            items = {
                type = "string",
            },
            default = {"/v1/chat/completions", "/v1/completions", "/generate"},
            description = "AI endpoint patterns to detect"
        },
        log_level = {
            type = "string",
            enum = {"DEBUG", "INFO", "WARN", "ERROR"},
            default = "INFO",
            description = "Plugin logging level"
        },
        include_metadata = {
            type = "boolean",
            default = true,
            description = "Include request metadata (headers, route info)"
        },
    },
    required = {"langfuse_public_key", "langfuse_secret_key"}
}

local metadata_schema = {
    type = "object",
    properties = {
        max_pending_entries = {
            type = "integer",
            description = "Maximum number of pending entries in batch processor",
            minimum = 1,
        },
    },
}

local _M = {
    version = 0.1,
    priority = 1050,
    name = plugin_name,
    schema = batch_processor_manager:wrap_schema(schema),
    metadata_schema = metadata_schema,
}

function _M.check_schema(conf, schema_type)
    if schema_type == core.schema.TYPE_METADATA then
        return core.schema.check(metadata_schema, conf)
    end

    local check = {"langfuse_host"}
    core.utils.check_https(check, conf, plugin_name)

    return core.schema.check(schema, conf)
end

-- Detect AI endpoint
local function is_ai_request(conf, uri)
    if not conf.detect_ai_requests then
        return true
    end

    for _, pattern in ipairs(conf.ai_endpoints) do
        if string_match(uri, pattern) then
            return true
        end
    end

    return false
end

-- Collect request/response body
local function get_body_data(ctx)
    local req_body = ctx.request_body
    local resp_body = ctx.response_body

    if req_body then
        local ok, req_json = pcall(core.json.decode, req_body)
        if ok then
            req_body = req_json
        end
    end

    if resp_body then
        local ok, resp_json = pcall(core.json.decode, resp_body)
        if ok then
            resp_body = resp_json
        end
    end

    return req_body, resp_body
end

-- Extract token usage
local function extract_token_usage(resp_body)
    if type(resp_body) ~= "table" then
        return nil
    end

    local usage = resp_body.usage
    if not usage then
        return nil
    end

    return {
        prompt_tokens = usage.prompt_tokens,
        completion_tokens = usage.completion_tokens,
        total_tokens = usage.total_tokens,
    }
end

-- Generate ISO 8601 timestamp
local function get_iso8601_timestamp(time)
    time = time or ngx_time()
    return os.date("!%Y-%m-%dT%H:%M:%S", time) .. "Z"
end

-- Parse W3C traceparent (00-{trace_id}-{span_id}-{flags})
local function parse_traceparent(traceparent)
    if not traceparent then
        return nil, nil
    end

    local version, trace_id, parent_span_id, flags =
        traceparent:match("^(%x%x)%-(%x+)%-(%x+)%-(%x%x)$")

    if version == "00" and trace_id and parent_span_id then
        return trace_id, parent_span_id
    end

    return nil, nil
end

-- Generate W3C traceparent
local function generate_traceparent(trace_id, span_id)
    -- version: 00 (W3C Trace Context v1)
    -- trace-flags: 01 (sampled)
    return string.format("00-%s-%s-01", trace_id, span_id)
end

-- Create Langfuse batch (trace + generation)
local function create_langfuse_batch(conf, ctx, req_body, resp_body)
    local var = ctx.var
    local start_time = ctx.start_time or ngx_now()
    local end_time = ngx_now()
    local latency = math.floor((end_time - start_time) * 1000) -- milliseconds

    -- Check traceparent header (distributed tracing)
    local incoming_traceparent = core.request.header(ctx, "traceparent")
    local trace_id, parent_span_id = parse_traceparent(incoming_traceparent)

    -- Generate new trace_id if not present
    if not trace_id then
        trace_id = uuid.generate_v4()
    end

    -- Generate new generation_id (span_id)
    local generation_id = uuid.generate_v4()
    local timestamp = get_iso8601_timestamp()

    local batch = {}

    -- 1. Create Trace
    local trace_body = {
        id = trace_id,
        name = var.method .. " " .. var.uri,
        userId = core.request.header(ctx, "X-User-Id"),
        sessionId = core.request.header(ctx, "X-Session-Id"),
        metadata = {},
        timestamp = timestamp,
    }

    if conf.include_metadata then
        trace_body.metadata = {
            method = var.method,
            uri = var.uri,
            status = ngx.status,
            latency_ms = latency,
            route_id = ctx.route_id,
            route_name = ctx.route_name,
            service_id = ctx.service_id,
            user_agent = var.http_user_agent,
            remote_addr = var.remote_addr,
        }

        -- Add traceparent info (distributed tracing)
        if incoming_traceparent then
            trace_body.metadata.traceparent = incoming_traceparent
            if parent_span_id then
                trace_body.metadata.parent_span_id = parent_span_id
            end
        end
    end

    -- Propagate traceparent for next call
    ctx.langfuse_traceparent = generate_traceparent(trace_id, generation_id)

    -- Reuse trace_id for batch item id
    core.table.insert(batch, {
        id = trace_id,
        type = "trace-create",
        timestamp = timestamp,
        body = trace_body,
    })

    -- 2. Create Generation (LLM call)
    local generation_body = {
        id = generation_id,
        traceId = trace_id,
        type = "generation",
        name = "LLM Generation",
        startTime = get_iso8601_timestamp(start_time),
        endTime = get_iso8601_timestamp(end_time),
        input = req_body,
        output = resp_body,
        metadata = {},
    }

    -- Extract model information
    if type(req_body) == "table" then
        if req_body.model then
            generation_body.model = req_body.model
        end
        if req_body.temperature then
            generation_body.modelParameters = {
                temperature = req_body.temperature,
                max_tokens = req_body.max_tokens,
                top_p = req_body.top_p,
            }
        end
    end

    -- Add token usage
    local token_usage = extract_token_usage(resp_body)
    if token_usage then
        generation_body.usage = {
            promptTokens = token_usage.prompt_tokens,
            completionTokens = token_usage.completion_tokens,
            totalTokens = token_usage.total_tokens,
        }

        if token_usage.total_tokens and latency > 0 then
            generation_body.metadata.tokens_per_second =
                math.floor(token_usage.total_tokens / (latency / 1000))
        end
    end

    -- Reuse generation_id for batch item id
    core.table.insert(batch, {
        id = generation_id,
        type = "generation-create",
        timestamp = timestamp,
        body = generation_body,
    })

    return batch
end

-- Send to Langfuse API
local function send_to_langfuse(conf, batch_data, ctx)
    local httpc = http.new()
    httpc:set_timeout(conf.timeout * 1000)

    local host_port = conf.langfuse_host:match("https?://([^/]+)")
    local host = host_port
    local port = 443

    if host_port:find(":") then
        host = host_port:match("([^:]+)")
        port = tonumber(host_port:match(":(%d+)"))
    end

    local ok, err = httpc:connect(host, port)
    if not ok then
        return false, "failed to connect to Langfuse: " .. err
    end

    if conf.langfuse_host:match("^https://") then
        ok, err = httpc:ssl_handshake(true, host, false)
        if not ok then
            return false, "SSL handshake failed: " .. err
        end
    end

    -- Basic Authentication
    -- Use credentials from headers if available (highest priority)
    local public_key = ctx.langfuse_public_key or conf.langfuse_public_key
    local secret_key = ctx.langfuse_secret_key or conf.langfuse_secret_key
    local auth_string = public_key .. ":" .. secret_key
    local auth_header = "Basic " .. ngx_encode_base64(auth_string)

    -- Langfuse ingestion API requires { batch: [...] } format
    local payload = {
        batch = batch_data
    }

    local body, encode_err = core.json.encode(payload)
    if not body then
        return false, "failed to encode batch data: " .. encode_err
    end

    local res, req_err = httpc:request({
        method = "POST",
        path = "/api/public/ingestion",
        body = body,
        headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = auth_header,
        }
    })

    if not res then
        return false, "request failed: " .. req_err
    end

    if res.status >= 400 then
        local res_body = res:read_body() or ""
        return false, "Langfuse API error [" .. res.status .. "]: " .. res_body
    end

    return true
end

-- rewrite phase: propagate traceparent
function _M.rewrite(conf, ctx)
    -- Check if AI request
    if not is_ai_request(conf, ctx.var.uri) then
        return
    end

    -- Record request start time
    ctx.start_time = ngx_now()

    -- Check for Langfuse credentials in headers (highest priority)
    -- This allows per-request credentials for multi-tenant scenarios
    local header_public_key = core.request.header(ctx, "X-Langfuse-Public-Key")
    local header_secret_key = core.request.header(ctx, "X-Langfuse-Secret-Key")

    if header_public_key and header_secret_key then
        ctx.langfuse_public_key = header_public_key
        ctx.langfuse_secret_key = header_secret_key
        core.log.info("Using Langfuse credentials from request headers")
    end
end

-- header_filter phase: propagate traceparent to downstream
function _M.header_filter(conf, ctx)
    if ctx.langfuse_traceparent then
        -- Propagate traceparent to upstream
        core.response.set_header("traceparent", ctx.langfuse_traceparent)
    end
end

-- body_filter phase: collect request/response body
function _M.body_filter(conf, ctx)
    -- Collect request body
    if not ctx.request_body then
        local req_body = core.request.get_body()
        if req_body then
            ctx.request_body = req_body
        end
    end

    -- Collect response body
    if ngx.arg[2] then  -- last buffer
        local resp_body_chunks = ngx.ctx.resp_body_chunks or {}
        if ngx.arg[1] then
            core.table.insert(resp_body_chunks, ngx.arg[1])
        end
        ctx.response_body = core.table.concat(resp_body_chunks, "")
    else
        ngx.ctx.resp_body_chunks = ngx.ctx.resp_body_chunks or {}
        if ngx.arg[1] then
            core.table.insert(ngx.ctx.resp_body_chunks, ngx.arg[1])
        end
    end
end

-- log phase: send to Langfuse
function _M.log(conf, ctx)
    -- Check if AI request
    if not is_ai_request(conf, ctx.var.uri) then
        return
    end

    local req_body, resp_body = get_body_data(ctx)

    if not req_body and not resp_body then
        core.log.warn("no request or response body to trace")
        return
    end

    local batch = create_langfuse_batch(conf, ctx, req_body, resp_body)

    local metadata = require("apisix.plugin").plugin_metadata(plugin_name)
    local max_pending_entries = metadata and metadata.value and
                                metadata.value.max_pending_entries or nil

    if batch_processor_manager:add_entry(conf, batch, max_pending_entries) then
        return
    end

    -- batch processor function
    local func = function(entries, batch_max_size)
        -- Each entry is already a batch array
        -- Combine batches from multiple requests
        local combined_batch = {}
        for _, entry in ipairs(entries) do
            for _, item in ipairs(entry) do
                core.table.insert(combined_batch, item)
            end
        end

        return send_to_langfuse(conf, combined_batch, ctx)
    end

    batch_processor_manager:add_entry_to_new_processor(conf, batch, ctx, func, max_pending_entries)
end

return _M
