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
local require = require
local setmetatable = setmetatable
local ipairs = ipairs
local type = type
local core = require("apisix.core")
local limit_count = require("apisix.plugins.limit-count.init")

local plugin_name = "ai-rate-limiting"

local MIN_ESTIMATED_TOKENS = 1

local function should_charge_prompt(conf)
    return conf.limit_strategy == "prompt_tokens" or conf.limit_strategy == "total_tokens"
end


local function should_charge_completion(conf)
    return conf.limit_strategy == "completion_tokens" or conf.limit_strategy == "total_tokens"
end


local instance_limit_schema = {
    type = "object",
    properties = {
        name = {type = "string"},
        limit = {type = "integer", minimum = 1},
        time_window = {type = "integer", minimum = 1}
    },
    required = {"name", "limit", "time_window"}
}

local schema = {
    type = "object",
    properties = {
        limit = {type = "integer", exclusiveMinimum = 0},
        time_window = {type = "integer",  exclusiveMinimum = 0},
        show_limit_quota_header = {type = "boolean", default = true},
        limit_strategy = {
            type = "string",
            enum = {"total_tokens", "prompt_tokens", "completion_tokens"},
            default = "total_tokens",
            description = "The strategy to limit the tokens"
        },

        -- Opt-in estimation-based charging mode.
        enable_estimated_token_charging = {
            type = "boolean",
            default = false,
            description = "Enable estimation-based charging to mitigate bypass by closing streaming requests early."
        },

        prompt_tokens_estimator_divisor = {
            type = "integer",
            minimum = 1,
            default = 4,
            description = "Estimated prompt tokens = ceil(utf8_bytes / divisor). Larger divisor => less charging."
        },
        completion_tokens_estimator_divisor = {
            type = "integer",
            minimum = 1,
            default = 4,
            description = "Estimated completion tokens = ceil(utf8_bytes / divisor)."
        },
        stream_commit_tokens = {
            type = "integer",
            minimum = 1,
            default = 50,
            description = "Commit completion token cost in batches to reduce limiter overhead."
        },
        instances = {
            type = "array",
            items = instance_limit_schema,
            minItems = 1,
        },
        rejected_code = {
            type = "integer", minimum = 200, maximum = 599, default = 503
        },
        rejected_msg = {
            type = "string", minLength = 1
        },
    },
    dependencies = {
        limit = {"time_window"},
        time_window = {"limit"}
    },
    anyOf = {
        {
            required = {"limit", "time_window"}
        },
        {
            required = {"instances"}
        }
    }
}

local _M = {
    version = 0.2,
    priority = 1030,
    name = plugin_name,
    schema = schema
}

local limit_conf_cache = core.lrucache.new({
    ttl = 300, count = 512
})


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


local function estimate_tokens_from_text(text, divisor)
    if type(text) ~= "string" or text == "" then
        return 0
    end

    divisor = divisor or 4
    if divisor <= 0 then
        divisor = 4
    end

    return math.ceil(#text / divisor)
end


local function estimate_prompt_tokens(conf, ctx)
    local body_tab, err = core.request.get_json_request_body_table()
    if not body_tab then
        core.log.debug("failed to decode request body for prompt estimation: ",
            err and core.json.delay_encode(err) or "nil")
        return MIN_ESTIMATED_TOKENS
    end

    local messages = body_tab.messages
    if type(messages) ~= "table" then
        return MIN_ESTIMATED_TOKENS
    end

    local parts = {}
    for _, msg in ipairs(messages) do
        if type(msg) == "table" then
            local c = msg.content
            if type(c) == "string" then
                parts[#parts + 1] = c
            elseif type(c) == "table" then
                -- OpenAI-compatible providers may use multipart content like:
                -- {"type":"text","text":"..."}. Prefer extracting text parts.
                local extracted = false
                if #c > 0 then
                    for _, part in ipairs(c) do
                        if type(part) == "table" and part.type == "text" and type(part.text) == "string" then
                            parts[#parts + 1] = part.text
                            extracted = true
                        end
                    end
                elseif c.type == "text" and type(c.text) == "string" then
                    parts[#parts + 1] = c.text
                    extracted = true
                end

                if not extracted then
                    -- Fallback: keep rough size without failing.
                    parts[#parts + 1] = core.json.encode(c)
                end
            end
        end
    end

    local all = table.concat(parts, " ")
    local est = estimate_tokens_from_text(all, conf.prompt_tokens_estimator_divisor)

    if est <= 0 then
        return MIN_ESTIMATED_TOKENS
    end
    return est
end


local function transform_limit_conf(plugin_conf, instance_conf, instance_name)
    local key = plugin_name .. "#global"
    local limit = plugin_conf.limit
    local time_window = plugin_conf.time_window
    local name = instance_name or ""
    if instance_conf then
        name = instance_conf.name
        key = instance_conf.name
        limit = instance_conf.limit
        time_window = instance_conf.time_window
    end
    return {
        _vid = key,

        key = key,
        count = limit,
        time_window = time_window,
        rejected_code = plugin_conf.rejected_code,
        rejected_msg = plugin_conf.rejected_msg,
        show_limit_quota_header = plugin_conf.show_limit_quota_header,
        -- limit-count need these fields
        policy = "local",
        key_type = "constant",
        allow_degradation = false,
        sync_interval = -1,

        limit_header = "X-AI-RateLimit-Limit-" .. name,
        remaining_header = "X-AI-RateLimit-Remaining-" .. name,
        reset_header = "X-AI-RateLimit-Reset-" .. name,
    }
end


local function fetch_limit_conf_kvs(conf)
    local mt = {
        __index = function(t, k)
            if not conf.limit then
                return nil
            end

            local limit_conf = transform_limit_conf(conf, nil, k)
            t[k] = limit_conf
            return limit_conf
        end
    }
    local limit_conf_kvs = setmetatable({}, mt)
    local conf_instances = conf.instances or {}
    for _, limit_conf in ipairs(conf_instances) do
        limit_conf_kvs[limit_conf.name] = transform_limit_conf(conf, limit_conf)
    end
    return limit_conf_kvs
end


function _M.access(conf, ctx)
    local ai_instance_name = ctx.picked_ai_instance_name
    if not ai_instance_name then
        return
    end

    local limit_conf_kvs = limit_conf_cache(conf, nil, fetch_limit_conf_kvs, conf)
    local limit_conf = limit_conf_kvs[ai_instance_name]
    if not conf.enable_estimated_token_charging then
        local code, msg = limit_count.rate_limit(limit_conf, ctx, plugin_name, 1, true)
        ctx.ai_rate_limiting = code and true or false
        return code, msg
    end

    local access_cost
    local prompt_tokens_est
    if should_charge_prompt(conf) then
        prompt_tokens_est = estimate_prompt_tokens(conf, ctx)
        ctx.ai_rate_limiting_prompt_tokens_est = prompt_tokens_est
        access_cost = prompt_tokens_est
    else
        access_cost = MIN_ESTIMATED_TOKENS
    end

    local code, msg = limit_count.rate_limit(limit_conf, ctx, plugin_name, access_cost, true)
    ctx.ai_rate_limiting = code and true or false
    if code then
        return code, msg
    end

    if should_charge_prompt(conf) and access_cost and access_cost > 0 then
        local commit_conf = core.table.clone(limit_conf)
        commit_conf.show_limit_quota_header = false
        limit_count.rate_limit(commit_conf, ctx, plugin_name, access_cost)
        ctx.ai_rate_limiting_prompt_charged = access_cost
    end
end


function _M.check_instance_status(conf, ctx, instance_name)
    if conf == nil then
        local plugins = ctx.plugins
        for i = 1, #plugins, 2 do
            if plugins[i]["name"] == plugin_name then
                conf = plugins[i + 1]
            end
        end
    end
    if not conf then
        return true
    end

    instance_name = instance_name or ctx.picked_ai_instance_name
    if not instance_name then
        return nil, "missing instance_name"
    end

    if type(instance_name) ~= "string" then
        return nil, "invalid instance_name"
    end

    local limit_conf_kvs = limit_conf_cache(conf, nil, fetch_limit_conf_kvs, conf)
    local limit_conf = limit_conf_kvs[instance_name]
    if not limit_conf then
        return true
    end

    local code, _ = limit_count.rate_limit(limit_conf, ctx, plugin_name, 1, true)
    if code then
        core.log.info("rate limit for instance: ", instance_name, " code: ", code)
        return false
    end
    return true
end


local function get_token_usage(conf, ctx)
    local usage = ctx.ai_token_usage
    if not usage then
        return
    end
    return usage[conf.limit_strategy]
end


local function commit_completion_cost(conf, ctx, limit_conf, cost)
    if not cost or cost <= 0 then
        return
    end

    local commit_conf = core.table.clone(limit_conf)
    commit_conf.show_limit_quota_header = false

    local code, err = limit_count.rate_limit(commit_conf, ctx, plugin_name, cost)
    if code then
        ctx.ai_rate_limiting_completion_rejected = true
        core.log.info("ai-rate-limiting completion cost rejected (will block next requests): ",
            "instance=", ctx.picked_ai_instance_name, ", code=", code,
            ", err=", err and core.json.delay_encode(err) or "")
    end
end


function _M.lua_body_filter(conf, ctx, headers, body)
    if not conf.enable_estimated_token_charging then
        return
    end

    if ctx.ai_rate_limiting then
        return
    end

    if not should_charge_completion(conf) then
        return
    end
    local chunk_contents = ctx.llm_response_contents_in_chunk
    local chunk_text
    if type(chunk_contents) == "table" and #chunk_contents > 0 then
        chunk_text = table.concat(chunk_contents, "")
    end

    local add = estimate_tokens_from_text(chunk_text, conf.completion_tokens_estimator_divisor)

    local pending = (ctx.ai_rate_limiting_completion_pending or 0) + add
    ctx.ai_rate_limiting_completion_pending = pending

    local should_flush = false
    if ctx.var.llm_request_done then
        should_flush = true
    elseif pending >= (conf.stream_commit_tokens or 50) then
        should_flush = true
    end

    if not should_flush or pending <= 0 then
        return
    end

    ctx.ai_rate_limiting_completion_pending = 0
    ctx.ai_rate_limiting_completion_charged = (ctx.ai_rate_limiting_completion_charged or 0) + pending

    local instance_name = ctx.picked_ai_instance_name
    if not instance_name then
        return
    end

    local limit_conf_kvs = limit_conf_cache(conf, nil, fetch_limit_conf_kvs, conf)
    local limit_conf = limit_conf_kvs[instance_name]
    if not limit_conf then
        return
    end

    commit_completion_cost(conf, ctx, limit_conf, pending)
end


function _M.log(conf, ctx)
    local instance_name = ctx.picked_ai_instance_name
    if not instance_name then
        return
    end

    if ctx.ai_rate_limiting then
        return
    end

    local used_tokens = get_token_usage(conf, ctx)

    local limit_conf_kvs = limit_conf_cache(conf, nil, fetch_limit_conf_kvs, conf)
    local limit_conf = limit_conf_kvs[instance_name]
    if not limit_conf then
        return
    end

    if not conf.enable_estimated_token_charging then
        if not used_tokens then
            core.log.error("failed to get token usage for llm service")
            return
        end

        core.log.info("instance name: ", instance_name, " used tokens: ", used_tokens)
        limit_count.rate_limit(limit_conf, ctx, plugin_name, used_tokens)
        return
    end

    local pending = ctx.ai_rate_limiting_completion_pending or 0
    if pending > 0 then
        ctx.ai_rate_limiting_completion_pending = 0
        ctx.ai_rate_limiting_completion_charged = (ctx.ai_rate_limiting_completion_charged or 0) + pending
        commit_completion_cost(conf, ctx, limit_conf, pending)
    end
    if should_charge_completion(conf)
            and ctx.var.request_type == "ai_chat"
            and not ctx.ai_rate_limiting_completion_charged then
        local completion_est = estimate_tokens_from_text(ctx.var.llm_response_text,
            conf.completion_tokens_estimator_divisor)
        if completion_est > 0 then
            ctx.ai_rate_limiting_completion_charged = completion_est
            commit_completion_cost(conf, ctx, limit_conf, completion_est)
        end
    end

    if used_tokens then
        core.log.info("instance name: ", instance_name, " used tokens (upstream usage): ", used_tokens,
            ", prompt_est=", ctx.ai_rate_limiting_prompt_tokens_est or 0,
            ", completion_est_charged=", ctx.ai_rate_limiting_completion_charged or 0)
    end
end


return _M
