-- includes
local luv = require 'luv'
local lhp = require 'http.parser'

local HTTP_FORMAT = 'HTTP/1.1 %s %s\r\n%s\r\n\r\n%s'

local function http_response(body, code, status, headers)
    headers['content-length'] = #body

    local raw = {}
    for k, v in pairs(headers) do
        table.insert(raw, string.format('%s: %s', tostring(k), tostring(v)))
    end

    return string.format(HTTP_FORMAT, code, status, table.concat(raw, '\r\n'), body)
end
local function http_response2(code, status, headers)
    headers['content-length'] = 139168

    local raw = {}
    for k, v in pairs(headers) do
        table.insert(raw, string.format('%s: %s', tostring(k), tostring(v)))
    end

    return string.format(HTTP_FORMAT, code, status, table.concat(raw, '\r\n'), '')
end




function init_parser()
   local cur          = { body = {} }
   local cb           = {}

   function cb.on_message_begin()
	print('on_message_begin')
       cur = { headers = {}, body={} }
   end

   function cb.on_url(value)
	print('on_url', value)
       cur.url = value;
       --cur.path, cur.query_string, cur.fragment = parse_path_query_fragment(value)
   end

   function cb.on_body(value)
	print('on_body', value)
       table.insert(cur.body, value)
   end

   function cb.on_header(field, value)
	print('on_header', value)
       cur.headers[field] = value
   end

   function cb.on_message_complete()
	print('on_message_complete', value)
       --table.insert(reqs, cur)
       cur = {body={}}
   end

   return lhp.request(cb)
end

local parser = init_parser()



function feedfile(client)
local f1 = luv.fiber.create(function()
   print("enter file read")
   local file = luv.fs.open("1.jpg", "r", "664")
print('file', file)
local res = http_response2(200, 'OK', {['content-type'] = 'image/jpeg'})
client:write(res)
while true do
local nread, content = file:read(4096)	
--print(content, #content)
--client:write(content)
if nread then
client:write(content)
else
break
end
end

print("close:", file:close())
--client:close()
end)

f1:ready()
--f1:join()
end

--local file = luv.fs.open("/tmp/cheese.ric", "r", "664")
--print("READ:", file:read())
--file:close()
--print("DELETE:", luv.fs.unlink("/tmp/cheese.ric"))





local main = luv.fiber.create(function()
   local server = luv.net.tcp()
   --server:bind("127.0.0.1", 8080)
   server:bind("0.0.0.0", 8080)
   server:listen()

   while true do
      local client = luv.net.tcp()
      server:accept(client)

      local child = luv.fiber.create(function()
         while true do
            local got, str = client:read()
	-- print('->got', got)
            if got then
		-- print(str)
            	local bytes_read = parser:execute(str)
		print('bytes_read', bytes_read)
		--local res = http_response('Hello world!', 200, 'OK', {})
               	feedfile(client)
		--client:close()
		-- client:write(res)
		--client:close()
		--break
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

