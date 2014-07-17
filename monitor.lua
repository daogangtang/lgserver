local socket = require 'socket'
local http = require("socket.http")
http.TIMEOUT = 10

local url = 'http://127.0.0.1:8080/__cmd_lgserver_status'
local code = 700

function request (url)
	
	return http.request {
		url = url,
		headers = {
			lgserver_cmd = '__cmd_lgserver_status'
		}
	}
	

end


while true do
	local response, n, m = request(url)
	print(url, response, n)
	if n ~= code or not response then
		print('TIMEOUT first ', os.date('%x %X', os.time()), n,m)
		local response, n, m = request(url)
		if n ~= code or not response then
			print('TIMEOUT second', os.date('%x %X', os.time()), n,m)
			local response, n, m = request(url)
			if n ~= code or not response then
				print('TIMEOUT ', os.date('%x %X', os.time()), n,m)
				--os.execute('cd ~/workspace/lgserver/ && ./restart.lua ')
			end
		end
	end
	print('tick...', os.date())
	socket.sleep(3)
end

print('end')

