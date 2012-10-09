local luv = require 'luv'
local main = luv.fiber.create(function()
   local server = luv.net.tcp()
   server:bind("127.0.0.1", 8080)
   server:listen()

   while true do
      local client = luv.net.tcp()
      server:accept(client)

      local child = luv.fiber.create(function()
         while true do
            local got, str = client:read()
            if got then
               client:write("you said: "..str)
            else
               client:close()
               break
            end
         end
      end)

      -- put it in the ready queue
      child:ready()
   end
end)

main:ready()
main:join()

