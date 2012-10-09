-- includes
local luv = require 'luv'
local lhp = require 'http.parser'
local mimetypes = require 'mime'


local HTTP_FORMAT = 'HTTP/1.1 %s %s\r\n%s\r\n\r\n%s'

local function http_response(body, code, status, headers)
    headers['content-length'] = #body

    local raw = {}
    for k, v in pairs(headers) do
        table.insert(raw, string.format('%s: %s', tostring(k), tostring(v)))
    end

    return string.format(HTTP_FORMAT, code, status, table.concat(raw, '\r\n'), body)
end

local function http_response_header(code, status, headers)
    local raw = {}
    for k, v in pairs(headers) do
        table.insert(raw, string.format('%s: %s', tostring(k), tostring(v)))
    end

    return string.format(HTTP_FORMAT, code, status, table.concat(raw, '\r\n'), '')
end

local function parse_path_query_fragment(uri)
    local path, query, fragment, off
    -- parse path
    path, off = uri:match('([^?]*)()')
    -- parse query
    if uri:sub(off, off) == '?' then
        query, off = uri:match('([^#]*)()', off + 1)
    end
    -- parse fragment
    if uri:sub(off, off) == '#' then
        fragment = uri:sub(off + 1)
        off = #uri
    end
    return path or '/', query, fragment
end

local req = nil
function init_parser()
   local reqs	= {}
   local cur	= {}
   local cb     = {}

   function cb.on_message_begin()
	cur = {headers = {}, body={}}
   end

   function cb.on_url(url)
	print(os.date("%Y-%m-%d %H:%M:%S", os.time()), 'request ', url)
	cur.url = url
	cur.path, cur.query_string, cur.fragment = parse_path_query_fragment(url)
   end

   function cb.on_header(field, value)
       cur.headers[field] = value
   end

   function cb.on_body(body)
--	if ( nil == cur.body ) then
--		cur.body = {}
--	end
	table.insert(cur.body, body)
   end
   
   function cb.on_message_complete()
	--table.remove(reqs)
	--table.insert(reqs, cur)
	req = cur
	cur = {headers = {}, body={}}
   end

   return lhp.request(cb)
end


local parser = init_parser()


function findtype(req)
	local content_type
	-- now req is the incoming request data
	local ext = req.path:match('(%.%w+)$')
	if ext then
		content_type = mimetypes[ext]
	end
	req['content-type'] = content_type or 'text/plain'
end


function feedfile(client, req)
	local f1 = luv.fiber.create(function()
		local path = '.'..req.path
		local file_t = luv.fs.stat(path)
		local size = 0
		if file_t then size = file_t.size end
		local file = luv.fs.open(path, "r", "664")
		--print(file_t)
		if not file_t then
			client:write(http_response('Not Found', 404, 'Not Found', {
				['content-type'] = 'text/plain'
			}))
		else
			local res = http_response_header(200, 'OK', {
				['content-type'] = req['content-type'],
				['content-length'] = size
			})
			client:write(res)
			while true do
				local nread, content = file:read(4096)	
				if nread then
					client:write(content)
				else
					break
				end
			end

			file:close()
		end
	end)

	f1:ready()
end


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
            if got then
		-- print(str)
            	local bytes_read = parser:execute(str)
		-- print('bytes_read', bytes_read)
		if bytes_read > 0 then
			feedfile(client, req)
		end
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

