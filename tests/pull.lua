local zmq = require"zmq"

local ctx = zmq.init(1)
local l = ctx:socket(zmq.PULL)
l:bind("tcp://lo:5555")

local s = ctx:socket(zmq.PUSH)
s:connect("tcp://localhost:5556")


while true do
	print(string.format("Received query: '%s'", l:recv()))
	--require('posix').sleep(5);
	s:send("OK")
end

l:close()
s:close()
ctx:term()

