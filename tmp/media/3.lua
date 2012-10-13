local luv = require 'luv'
local zmq = luv.zmq.create(1)

local pub = zmq:socket(luv.zmq.PUSH)
pub:bind('inproc://127.0.0.1:1234')

local prod = luv.fiber.create(function()
   for i=1, 10 do
      pub:send("tick: "..i)
   end
end)

local cons = luv.fiber.create(function()
   local sub = zmq:socket(luv.zmq.PULL)
   sub:connect('inproc://127.0.0.1:1234')

   for i=1, 1000000 do
      local msg = sub:recv()
      print("GOT: "..msg)
   end

   sub:close()
end)

prod:ready()
cons:ready()

cons:join()

