local zmq = require"zmq"

require 'zmq.poller'
local poller = zmq.poller(64)


local ctx = zmq.init()
local l = ctx:socket(zmq.PULL)
l:connect("tcp://127.0.0.1:1234")

local s = ctx:socket(zmq.PUSH)
s:connect("tcp://127.0.0.1:1235")
-- local s = ctx:socket(zmq.PUB)
-- s:bind("tcp://127.0.0.1:1235")

local cluster_pubchannel = ctx:socket(zmq.PUB)
cluster_pubchannel:bind("tcp://127.0.0.1:1236")

local cluster_subchannel = ctx:socket(zmq.SUB)
cluster_subchannel:setopt(zmq.SUBSCRIBE, "")
cluster_subchannel:connect("tcp://127.0.0.1:1236")


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

function lgserver_request ()
	print(string.format("Received query: '%s'", l:recv()))
	--require('posix').sleep(1);
	--s:send(cmsgpack.pack(http_response(str)))
	s:send('---->>> hi, I am Tang.')
	print('xxxx')
	cluster_pubchannel:send('haha...')
end


function sub_request ()
	local msg = cluster_subchannel:recv()
	print('sub msg received...', msg)
end


poller:add(l, zmq.POLLIN, lgserver_request)
poller:add(cluster_subchannel, zmq.POLLIN, sub_request)


-- start the main loop
poller:start()


l:close()
s:close()
ctx:term()

