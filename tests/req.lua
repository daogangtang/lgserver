local zmq = require"zmq"


local ctx = zmq.init()
local s = ctx:socket(zmq.REQ)

s:connect("tcp://localhost:5555")

for i=1, 100 do
	s:send("SELECT * FROM mytable")
	local data, err = s:recv()
	if data then
		print(data)
	else
		print("s:recv() error:", err)
	end
end

s:close()
ctx:term()

