local zmq = require"zmq"

local ctx = zmq.init()
local s = ctx:socket(zmq.REP)

s:bind("tcp://lo:5555")

while true do
	print(string.format("Received query: '%s'", s:recv()))
	require('posix').sleep(1);
	s:send("OK")
end

