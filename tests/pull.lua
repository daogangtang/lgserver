local zmq = require"zmq"

local ctx = zmq.init()
local l = ctx:socket(zmq.PULL)
l:connect("tcp://127.0.0.1:1234")
--l:bind("tcp://lo:1234")
--l:bind("tcp://127.0.0.1:1234")

local s = ctx:socket(zmq.PUSH)
s:bind("tcp://127.0.0.1:1235")
--s:connect("tcp://127.0.0.1:1235")

local cmsgpack = require 'cmsgpack'

local HTTP_FORMAT = 'HTTP/1.1 %s %s\r\n%s\r\n\r\n%s'

local function http_response(body, code, status, headers)
    code = code or 200
    status = status or "OK"
    headers = headers or {}
    headers['Content-Type'] = headers['Content-Type'] or 'text/plain'
    headers['Content-Length'] = #body

    local raw = {}
    for k, v in pairs(headers) do
        table.insert(raw, string.format('%s: %s', tostring(k), tostring(v)))
    end

    return string.format(HTTP_FORMAT, code, status, table.concat(raw, '\r\n'), body)
end

local str = "Hello World Hello World Hello World Hello World Hello World Hello World Hello World Hello World Hello World Hello World Hello World Hello World Hello World "

while true do
	print(string.format("Received query: '%s'", l:recv()))
--	require('posix').sleep(1);
	s:send(cmsgpack.pack(http_response(str)))
end

l:close()
s:close()
ctx:term()

