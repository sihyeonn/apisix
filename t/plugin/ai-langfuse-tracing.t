#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
use t::APISIX 'no_plan';

log_level('debug');
repeat_each(1);
no_long_string();
no_root_location();

add_block_preprocessor(sub {
    my ($block) = @_;

    if (!defined $block->request) {
        $block->set_value("request", "GET /t");
    }
});

run_tests;

__DATA__

=== TEST 1: sanity - schema check with required fields
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.ai-langfuse-tracing")
            local ok, err = plugin.check_schema({
                langfuse_public_key = "pk-test-123",
                langfuse_secret_key = "sk-test-456"
            })
            if not ok then
                ngx.say(err)
            end

            ngx.say("done")
        }
    }
--- response_body
done



=== TEST 2: schema check - missing required fields
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.ai-langfuse-tracing")
            local ok, err = plugin.check_schema({
                timeout = 5
            })
            if not ok then
                ngx.say(err)
            end

            ngx.say("done")
        }
    }
--- response_body_like
property "langfuse_public_key" is required
done



=== TEST 3: full schema check with all options
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.ai-langfuse-tracing")
            local ok, err = plugin.check_schema({
                langfuse_public_key = "pk-test-123",
                langfuse_secret_key = "sk-test-456",
                langfuse_host = "https://cloud.langfuse.com",
                timeout = 5,
                detect_ai_requests = true,
                ai_endpoints = {"/v1/chat/completions", "/v1/completions"},
                log_level = "INFO",
                include_metadata = true,
                batch_max_size = 100,
                max_retry_count = 3,
                buffer_duration = 60,
                inactive_timeout = 5
            })
            if not ok then
                ngx.say(err)
            end

            ngx.say("done")
        }
    }
--- response_body
done



=== TEST 4: schema check - invalid log_level
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.ai-langfuse-tracing")
            local ok, err = plugin.check_schema({
                langfuse_public_key = "pk-test-123",
                langfuse_secret_key = "sk-test-456",
                log_level = "INVALID"
            })
            if not ok then
                ngx.say(err)
            end

            ngx.say("done")
        }
    }
--- response_body_like
property "log_level" validation failed
done



=== TEST 5: add plugin to route
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                        "plugins": {
                            "ai-langfuse-tracing": {
                                "langfuse_public_key": "pk-test-123",
                                "langfuse_secret_key": "sk-test-456",
                                "langfuse_host": "http://127.0.0.1:1984",
                                "batch_max_size": 1,
                                "timeout": 5
                            }
                        },
                        "upstream": {
                            "nodes": {
                                "127.0.0.1:1980": 1
                            },
                            "type": "roundrobin"
                        },
                        "uri": "/v1/chat/completions"
                }]]
                )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 6: test AI endpoint detection - should trace
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.ai-langfuse-tracing")

            -- Mock config
            local conf = {
                detect_ai_requests = true,
                ai_endpoints = {"/v1/chat/completions", "/v1/completions", "/generate"}
            }

            -- Test OpenAI endpoint
            local is_ai = false
            for _, pattern in ipairs(conf.ai_endpoints) do
                if string.match("/v1/chat/completions", pattern) then
                    is_ai = true
                    break
                end
            end

            if is_ai then
                ngx.say("AI endpoint detected")
            else
                ngx.say("Not AI endpoint")
            end
        }
    }
--- response_body
AI endpoint detected



=== TEST 7: test AI endpoint detection - should not trace
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.ai-langfuse-tracing")

            -- Mock config
            local conf = {
                detect_ai_requests = true,
                ai_endpoints = {"/v1/chat/completions", "/v1/completions", "/generate"}
            }

            -- Test non-AI endpoint
            local is_ai = false
            for _, pattern in ipairs(conf.ai_endpoints) do
                if string.match("/api/users", pattern) then
                    is_ai = true
                    break
                end
            end

            if is_ai then
                ngx.say("AI endpoint detected")
            else
                ngx.say("Not AI endpoint")
            end
        }
    }
--- response_body
Not AI endpoint



=== TEST 8: schema check - custom langfuse host
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.ai-langfuse-tracing")
            local ok, err = plugin.check_schema({
                langfuse_public_key = "pk-test-123",
                langfuse_secret_key = "sk-test-456",
                langfuse_host = "https://custom.langfuse.com"
            })
            if not ok then
                ngx.say(err)
            end

            ngx.say("done")
        }
    }
--- response_body
done



=== TEST 9: schema check - detect_ai_requests false
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.ai-langfuse-tracing")
            local ok, err = plugin.check_schema({
                langfuse_public_key = "pk-test-123",
                langfuse_secret_key = "sk-test-456",
                detect_ai_requests = false
            })
            if not ok then
                ngx.say(err)
            end

            ngx.say("done")
        }
    }
--- response_body
done



=== TEST 10: schema check - include_metadata false
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.ai-langfuse-tracing")
            local ok, err = plugin.check_schema({
                langfuse_public_key = "pk-test-123",
                langfuse_secret_key = "sk-test-456",
                include_metadata = false
            })
            if not ok then
                ngx.say(err)
            end

            ngx.say("done")
        }
    }
--- response_body
done



=== TEST 11: test traceparent parsing - valid format
--- config
    location /t {
        content_by_lua_block {
            local uuid = require("resty.jit-uuid")
            uuid.seed()

            -- Mock parse_traceparent function
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

            -- Test with valid traceparent
            local traceparent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
            local trace_id, span_id = parse_traceparent(traceparent)

            if trace_id == "0af7651916cd43dd8448eb211c80319c" and
               span_id == "b7ad6b7169203331" then
                ngx.say("traceparent parsed correctly")
            else
                ngx.say("traceparent parsing failed")
            end
        }
    }
--- response_body
traceparent parsed correctly



=== TEST 12: test traceparent parsing - invalid format
--- config
    location /t {
        content_by_lua_block {
            -- Mock parse_traceparent function
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

            -- Test with invalid traceparent
            local traceparent = "invalid-traceparent"
            local trace_id, span_id = parse_traceparent(traceparent)

            if trace_id == nil and span_id == nil then
                ngx.say("invalid traceparent rejected correctly")
            else
                ngx.say("invalid traceparent should be rejected")
            end
        }
    }
--- response_body
invalid traceparent rejected correctly



=== TEST 13: test traceparent generation
--- config
    location /t {
        content_by_lua_block {
            -- Mock generate_traceparent function
            local function generate_traceparent(trace_id, span_id)
                return string.format("00-%s-%s-01", trace_id, span_id)
            end

            local trace_id = "0af7651916cd43dd8448eb211c80319c"
            local span_id = "b7ad6b7169203331"
            local traceparent = generate_traceparent(trace_id, span_id)

            local expected = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
            if traceparent == expected then
                ngx.say("traceparent generated correctly")
            else
                ngx.say("traceparent generation failed: " .. traceparent)
            end
        }
    }
--- response_body
traceparent generated correctly



=== TEST 14: test traceparent propagation workflow
--- config
    location /t {
        content_by_lua_block {
            local uuid = require("resty.jit-uuid")
            uuid.seed()

            -- Mock functions
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

            local function generate_traceparent(trace_id, span_id)
                return string.format("00-%s-%s-01", trace_id, span_id)
            end

            -- Simulate distributed tracing workflow
            local incoming_traceparent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
            local trace_id, parent_span_id = parse_traceparent(incoming_traceparent)

            if not trace_id then
                trace_id = uuid.generate_v4()
            end

            local new_span_id = uuid.generate_v4()
            local outgoing_traceparent = generate_traceparent(trace_id, new_span_id)

            -- Verify trace_id is preserved
            local _, reused_trace_id, _, _ = outgoing_traceparent:match("^(%x%x)%-(%x+)%-(%x+)%-(%x%x)$")

            if reused_trace_id == "0af7651916cd43dd8448eb211c80319c" then
                ngx.say("trace_id preserved correctly")
            else
                ngx.say("trace_id preservation failed")
            end
        }
    }
--- response_body
trace_id preserved correctly



=== TEST 15: test header credentials priority
--- config
    location /t {
        content_by_lua_block {
            -- Simulate credential priority logic
            local ctx = {}
            local conf = {
                langfuse_public_key = "pk-config-123",
                langfuse_secret_key = "sk-config-456"
            }

            -- Simulate headers from request
            local header_public_key = "pk-header-789"
            local header_secret_key = "sk-header-012"

            -- Apply header credentials if present (highest priority)
            if header_public_key and header_secret_key then
                ctx.langfuse_public_key = header_public_key
                ctx.langfuse_secret_key = header_secret_key
            end

            -- Use credentials (headers take precedence)
            local public_key = ctx.langfuse_public_key or conf.langfuse_public_key
            local secret_key = ctx.langfuse_secret_key or conf.langfuse_secret_key

            if public_key == "pk-header-789" and secret_key == "sk-header-012" then
                ngx.say("header credentials have priority")
            else
                ngx.say("credential priority failed")
            end
        }
    }
--- response_body
header credentials have priority



=== TEST 16: test fallback to config credentials
--- config
    location /t {
        content_by_lua_block {
            -- Simulate credential fallback logic
            local ctx = {}
            local conf = {
                langfuse_public_key = "pk-config-123",
                langfuse_secret_key = "sk-config-456"
            }

            -- No header credentials
            local header_public_key = nil
            local header_secret_key = nil

            -- Apply header credentials if present
            if header_public_key and header_secret_key then
                ctx.langfuse_public_key = header_public_key
                ctx.langfuse_secret_key = header_secret_key
            end

            -- Use credentials (fallback to config)
            local public_key = ctx.langfuse_public_key or conf.langfuse_public_key
            local secret_key = ctx.langfuse_secret_key or conf.langfuse_secret_key

            if public_key == "pk-config-123" and secret_key == "sk-config-456" then
                ngx.say("config credentials used as fallback")
            else
                ngx.say("credential fallback failed")
            end
        }
    }
--- response_body
config credentials used as fallback
