local zmq = require"zmq"


local ctx = zmq.init()
local s = ctx:socket(zmq.PUSH)
s:bind("tcp://127.0.0.1:1234")

local l = ctx:socket(zmq.PULL)
l:bind("tcp://127.0.0.1:1235")
-- local l = ctx:socket(zmq.SUB)
-- l:setopt(zmq.SUBSCRIBE, "MMM")
-- l:connect("tcp://127.0.0.1:1235")


print('ready to print')
for i=1, 100 do
	s:send("SELECT * FROM mytable")

	print('ready to receive')
	local data, err = l:recv()
	print(data)

	-- local data, err
	-- repeat
	-- 	data, err = l:recv(zmq.NOBLOCK)
	-- 	if not data then
	-- 		if err == 'timeout' then
	-- 			print('wait....')
	-- 			require('posix').sleep(1)
	-- 		else
	-- 			error("socket recv error:" .. err)
	-- 		end
	-- 	end
	-- until data

	-- -- 	local more = src:getopt(zmq.RCVMORE) > 0
	-- -- dst:send(data,more and zmq.SNDMORE or 0)
	-- if data then
	-- 	print(data)
	-- else
	-- 	print("s:recv() error:", err)
	-- end
end

s:close()
ctx:term()

