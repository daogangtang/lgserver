

return 
[==[
	local socket = require 'socket'
	local zmq = require 'zmq'
--	local cmsgpack = require 'cmsgpack'
--	local zlib = require 'zlib'

    local host, port, channel_sub_addr = ...
--  print(host, port, channel_sub_addr)

--    local client = assert(socket.connect(host, port))
    local ctx = zmq.init(1)
    local channel_sub = ctx:socket(zmq.SUB)
	channel_sub:setopt(zmq.SUBSCRIBE, "")
--	channel_sub:connect(channel_sub_addr)
	channel_sub:bind(channel_sub_addr)
		
    while true do
        local client = socket.connect(host, port)
--print('create socket')
        if client then
		    local msg = channel_sub:recv()   -- block wait
		    -- print('return msg...', msg, #msg)

		    local data = string.format("%s %s", #msg, msg)
		    
            local lastIndex = 0
            local s, err
	        while true do
                s, err, lastIndex = client:send(data, lastIndex + 1)
--                print(s, err, lastIndex)
                if s or err ~= "timeout" then
			        break
		        end
            end
--            print('ready close') 
            client:close()
        end 
    end
    
    print('Client Ends.')
]==]

