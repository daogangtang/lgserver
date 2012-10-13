local luv = require('luv')

local zmq = luv.zmq.create(2)

local pub = zmq:socket(luv.zmq.PUSH)
pub:bind('tcp://127.0.0.1:1234')
--[[
local sub = zmq:socket(luv.zmq.SUB)
sub:connect('tcp://127.0.0.1:12315')
sub:setsockopt("SUBSCRIBE", '000')
--]]
local sub = zmq:socket(luv.zmq.PULL)
sub:connect('tcp://127.0.0.1:12315')


local prod = luv.fiber.create(function()


	print("enter prod:")
   luv.sleep(3)
   local i = 1
   while i > 0 do
   
      pub:send("tick: "..i)
      luv.sleep(1)
      i=i+1
   end
   --pub:close()
end)
prod:ready()

local ss = luv.fiber.create(function()
	print("enter ss:")
	while true do
		print('ready to receive.')
		local msg = sub:recv()
		print(msg)
		luv.sleep(1)
	end

   
end)

prod:ready()
ss:ready()
ss:join()
