local luv = require('luv')

local zmq = luv.zmq.create(2)

local cons = luv.fiber.create(function()
	   local sub = zmq:socket(luv.zmq.PULL)
	   sub:connect('tcp://127.0.0.1:1234')

	--local pub = zmq:socket(luv.zmq.PUB)
	--pub:bind('tcp://127.0.0.1:12315')
	local pub = zmq:socket(luv.zmq.PUSH)
	pub:bind('tcp://127.0.0.1:1235')
	print("enter cons")

	while true do
	      local msg = sub:recv()
		if msg then
			print(msg)
			--pub:send('haha, I have receive your request '.. msg)
			pub:send(msg)
		end
		--luv.sleep(1)
	end
	sub:close()
	pub:close()
end)

cons:ready()
cons:join()

