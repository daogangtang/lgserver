-- includes
local luv = require 'luv'
local lhp = require 'http.parser'
local cmsgpack = require 'cmsgpack'
local mimetypes = require 'mime'

-- load configurations
local allconfig = {}
setfenv(assert(loadfile('./config.lua')), setmetatable(allconfig, {__index=_G}))()
local config = allconfig.servers[1]
local routes = config.hosts[1].routes

local patterns = {}
for pattern, handle_t in pairs(routes) do
	table.insert(patterns, pattern)
end
-- arrage patterns from longest to shorterest
table.sort(patterns, function (a, b) return #a > #b end)

function findHandle(req)
	local path = req.path:gsub('/+', '/')
	for i, pattern in ipairs(patterns) do
		if path:match('^'..pattern) then
			return pattern, routes[pattern]
		end
	end
	
	return nil, nil
end


local HTTP_FORMAT = 'HTTP/1.1 %s %s\r\n%s\r\n\r\n%s'

local function http_response(body, code, status, headers)
    headers = headers or {}
    headers['content-length'] = #body

    local raw = {}
    for k, v in pairs(headers) do
        table.insert(raw, string.format('%s: %s', tostring(k), tostring(v)))
    end

    return string.format(HTTP_FORMAT, code, status, table.concat(raw, '\r\n'), body)
end

local function http_response_header(code, status, headers)
    headers = headers or {}
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

function regularPath(path)
	local orig_path = path
	path = config.root_dir..path
	path = path:gsub('/+', '/')
	
	local l = #config.root_dir
	local count = 0
	while l do
		l = path:find('/', l+1)
		if l and path:sub(l-2, l) == '../' then
			count = count - 1
		end
		if count < 0 then return nil, "[Error]Invald Path "..orig_path end
	end
	
	--print(path)
	return path
end

function feedfile(client, req)
	local f1 = luv.fiber.create(function()
		local path, err = regularPath(req.path)
		if not path then
			print(err)
			client:write(http_response('Forbidden', 403, 'Forbidden'))
			return false
		elseif path == config.root_dir then 
			path = config.root_dir..'index.html' 
		end
		
		local file_t = luv.fs.stat(path)
		local file = luv.fs.open(path, "r", "664")
		--print(file_t)
		local last_modified_time = tonumber(req.headers['If-Modified-Since'])
		if not file_t then
			client:write(http_response('Not Found', 404, 'Not Found', {
				['content-type'] = 'text/plain'
			}))
		elseif last_modified_time and file_t.mtime and last_modified_time >= file_t.mtime then
			client:write(http_response('Not Changed', 304, 'Not Changed'))
		else
			local size = 0
			if file_t then size = file_t.size end
			local res = http_response_header(200, 'OK', {
				['content-type'] = req['content-type'],
				['content-length'] = size,
				['Last-Modified'] = file_t.mtime,
				['Cache-Control'] = 'max-age=60'
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
			client:shutdown()
		end
	end)

	f1:ready()
end



local zmq = luv.zmq.create(1)
local channel_push = zmq:socket(luv.zmq.PUSH)
channel_push:bind(config.hosts[1].routes['/'].send_spec)

local function sendPushZmqMsg( msg )
	local f = luv.fiber.create(function ()
		channel_push:send(msg)
	end)
	
	f:ready()
end

local channel_pull = zmq:socket(luv.zmq.PULL)
channel_pull:connect(config.hosts[1].routes['/'].recv_spec)
local function receivePullZmqMsg()
	local msg = channel_pull:recv()
	return cmsgpack.unpack(msg)
end


function serviceDispatcher(client, req)
	local pattern, handle_t = findHandle(req)
	if pattern then
		if handle_t.type == 'dir' then
			feedfile(client, req)
			
		elseif handle_t.type == 'handler' then
			sendPushZmqMsg(cmsgpack.pack(req))
			-- res is the response string from handler
			local res = receivePullZmqMsg()
			-- client:write(http_response(luv.codec.encode(res), 200, 'OK'))
			client:write(http_response(res, 200, 'OK', {
				['content-type'] = req['content-type']
			}))
			
		end
	end
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
            local got, reqstr = client:read()
            if got then
		-- print(reqstr)
            	local bytes_read = parser:execute(reqstr)
		if bytes_read > 0 then
			-- feedfile(client, req)
			sendPushZmqMsg(cmsgpack.pack(req))
		end
		local res = receivePullZmqMsg()
		client:write(http_response(luv.codec.encode(res), 200, 'OK'))
		-- print(str)
            	--local bytes_read = parser:execute(reqstr)
		-- print('bytes_read', bytes_read)
		--if bytes_read > 0 then
		--	feedfile(client, req)
		--end
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

