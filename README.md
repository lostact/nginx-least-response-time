# nginx-least-response-time
A lua module to implement least response time balancing for nginx.

# Usage
The update_data function is used for saving data in log phase:

    log_by_lua_block
    {
        local lrt_balancer = require("lrt_balancer")
        lrt_balancer.update_data(ngx.var.upstream_name, ngx.var.upstream_addr, ngx.var.upstream_status, ngx.var.upstream_connect_time, ngx.var.upstream_response_time)
    }

And update_weights function is used as a timer in each worker to update weights:

    init_worker_by_lua_block
    {
        local lrt_balancer = require("lrt_balancer")
        local ok, err = ngx.timer.every(lrt_balancer.WEIGHTS_UPDATE_INTERVAL, lrt_balancer.update_weights)
        if not ok then
            ngx.log(ngx.ERR, "failed to create timer: ", err)
        end
        lrt_balancer.update_weights()
    }
