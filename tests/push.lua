local zmq = require"zmq"


local ctx = zmq.init()
local s = ctx:socket(zmq.PUSH)
s:connect("tcp://localhost:5555")

local l = ctx:socket(zmq.PULL)
l:bind("tcp://lo:5556")


for i=1, 100 do
	s:send("SELECT * FROM mytable")
	
	local data, err
	repeat
		data, err = l:recv(zmq.NOBLOCK)
		if not data then
			if err == 'timeout' then
				print('wait....')
				require('posix').sleep(1)
			else
				error("socket recv error:" .. err)
			end
		end
	until data

	-- 	local more = src:getopt(zmq.RCVMORE) > 0
	-- dst:send(data,more and zmq.SNDMORE or 0)
	if data then
		print(data)
	else
		print("s:recv() error:", err)
	end
end

s:close()
ctx:term()

