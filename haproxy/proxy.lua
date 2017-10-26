local socket = require "socket"

local _M = {}

local function receivestatusline(sock)
    local status = assert(sock:receive(5))
    -- identify HTTP/0.9 responses, which do not contain a status line
    -- this is just a heuristic, but is what the RFC recommends
    if status ~= "HTTP/" then return nil, status end
    -- otherwise proceed reading a status line
    status = assert(sock:receive("*l", status))
    local code = socket.skip(2, string.find(status, "HTTP/%d*%.%d* (%d%d%d)"))
    return assert(tonumber(code), status)
end

local function receiveheaders(sock, headers)
    local line, name, value, err
    headers = headers or {}
    -- get first line
    line, err = sock:receive("*l")

    if err then return nil, err end
    -- headers go until a blank line is found
    local cookies = {}
    
    while line ~= "" do
        -- get field-name and value
        name, value = socket.skip(2, string.find(line, "^(.-):%s*(.*)"))
        if not (name and value) then return nil, "malformed reponse headers" end
        name = string.lower(name)
        -- get next line (value might be folded)
        line, err  = sock:receive("*l")
        if err then return nil, err end
        -- unfold any folded values
        while string.find(line, "^%s") do
            value = value .. line
            line = sock:receive("*l")
            if err then return nil, err end
        end

        -- save pair in table
        if name == 'set-cookie' then
            table.insert(cookies, value)
        else
            if headers[name] then headers[name] = headers[name] .. ", " .. value
            else headers[name] = value end
        end
    end
    headers['set-cookie'] = cookies
    return headers
end


function _M.upstream(applet)
    local host, port = "10.10.11.2", 80
    local method = applet.method
    local request_headers do
        request_headers = {}
        local h = applet.headers
        for k, v in pairs(h) do
            local header_string = ''
            for idx, header_v in pairs(v) do
                if idx > 0 then
                    header_string = header_string .. ", " .. header_v
                else
                    header_string = header_v
                end
            end
            request_headers[k] = header_string
        end
        request_headers['accept-encoding'] = nil
    end

    local url
    do
        url = applet.path
        if applet.qs ~= '' then
            url = url .. "?" .. applet.qs
        end
    end

    local data 
    do
        data = string.format("%s %s HTTP/1.0\r\n", method, url)
        for k, v in pairs(request_headers) do
            if k ~= "accept-encoding" then
                data = data .. string.format("%s: %s\r\n", k, v)
            end
        end
        data = data .. "\r\n"
    end

    if method ~= "GET" then
        local body 
        do
            if request_headers["content-length"] ~= '0' then
                body = applet:receive()
            else
                body = ''
            end
        end
        data = data .. string.format("%s\r\n\r\n", body)
    end

    -- core.log(core.info, data)
    local tcp = assert(core.tcp())
    tcp:connect(host, port);
    tcp:send(data);
    
    local response_code = receivestatusline(tcp)
    local response_headers = receiveheaders(tcp)
    local response_content, err = tcp:receive("*a")
    tcp:close()

    if response_headers then
        for k, v in pairs(response_headers) do
            if k == "set-cookie" then
                for _, val in pairs(v) do
                    applet:add_header(k, val)
                end
            else
                applet:add_header(k, v)
            end
        end
    end

    applet:set_status(response_code)
    applet:start_response()
    applet:send(response_content)
end

return _M
