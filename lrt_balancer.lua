local _M = {}

_M.WEIGHTS_UPDATE_INTERVAL = 60 --interval between weight update cycles

local RESPONSE_TIMEOUT = 2 --if upstream responsed slower than this, consider it as a failure
local FAIL_PENALTY = 0.9 --how much we penalize upstream for each fail
local FAILS_TTL = _M.WEIGHTS_UPDATE_INTERVAL --same as update interval to ensure fail penalty is applied only once
local EWMA_ALPHA = 0.1 --how much we prefere newer data over older data
local MIN_WEIGHT = 10 --this is because nginx does not accept float numbers for weights so we multiply by 10 to have some wiggle room
local MAX_WEIGHT = 10000 --maximum weight and initial weight for all upstreams, this ensures all upstreams are tested 
local WEIGHT_EXP = 2 --how aggressive we prefere faster upstreams

local json = require("cjson")
local upstream = require("ngx.upstream")

local function get_max_response_time(response_times)
    local max_response_time = 0
    for _, response_time in pairs(response_times) do
        if response_time > max_response_time then
            max_response_time = response_time
        end
    end
    return max_response_time
end

local function calculate_weights(response_times)
    local max_response_time = get_max_response_time(response_times)
    local weights = {}
    for peer_name, response_time in pairs(response_times) do
        -- worst performing peer always gets MIN_WEIGHT weight, other peers get more weights exponentially proportional to how much faster they are
        local weight = math.min(MAX_WEIGHT, math.floor(math.pow(max_response_time / response_time, WEIGHT_EXP) * MIN_WEIGHT))
        weights[peer_name] = weight
    end
    return weights
end

function _M.update_weights()
    local start_time = os.clock()
    local performance_data_dict = ngx.shared.performance_data
    local fails_data_dict = ngx.shared.fails_data
    -- get a list of upstream names
    local upstreams = upstream.get_upstreams()

    for _, upstream_name in ipairs(upstreams) do
        local response_times_json = performance_data_dict:get(upstream_name)
        local weights = {}
        if response_times_json then
            local response_times = json.decode(response_times_json)
            weights = calculate_weights(response_times)
        end
        local peers = upstream.get_primary_peers(upstream_name)
        for _, peer in ipairs(peers) do
            local old_weight = peer.weight
            local new_weight = weights[peer.name] or old_weight
            local fails = fails_data_dict:get(upstream_name .. "/" .. peer.name)
            if fails then
                new_weight = math.max(MIN_WEIGHT, math.floor(new_weight * math.pow(FAIL_PENALTY, fails)))
            end
            if new_weight ~= old_weight then
                upstream.set_peer_weight(upstream_name, false, peer.id, new_weight)
            end
        end
    end
    --ngx.log(ngx.ERR, "updated weights for worker " .. ngx.worker.id() .. " in " .. os.clock() - start_time )
end

local function calculate_ewma(average, new_value, alpha)
    if not average then
        return new_value
    end
    return alpha * new_value + (1 - alpha) * average
end

function _M.update_data(upstream_name, peer_name, status_code, connect_time, response_time)
    local connect_time = tonumber(connect_time)
    local response_time = tonumber(response_time)

    if not ngx.re.find(status_code, "^2") or (connect_time == 0 and response_time > RESPONSE_TIMEOUT) then
        local fails_data_dict = ngx.shared.fails_data
        fails_data_dict:incr(upstream_name .. "/" .. peer_name, 1, 0, FAILS_TTL)
        return
    end
    
    if connect_time > 0 or response_time == 0 then
        --if connect_time is not zero it means keepalive wasn't used, so the response_time is inaccurate and we discard it | response_time of zero is just not valid
        return
    end
    
    local performance_data_dict = ngx.shared.performance_data
    local performance_data = performance_data_dict:get(upstream_name)

    local response_times = {}
    local average_response_time = nil
    if performance_data then
        response_times = json.decode(performance_data)
        average_response_time = response_times[peer_name]
    end

    response_times[peer_name] = calculate_ewma(average_response_time, response_time, EWMA_ALPHA)
    performance_data_dict:set(upstream_name, json.encode(response_times))
end


return _M
