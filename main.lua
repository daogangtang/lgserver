-- includes

local lhp = require 'http.parser'
local cmsgpack = require 'cmsgpack'
local mimetypes = require 'mime'
local copas = require 'copas'

local zmq = require"zmq"
local poller = require('zmq.poller')(64)

-- load configurations
local allconfig = {}
setfenv(assert(loadfile('./config.lua')), setmetatable(allconfig, {__index=_G}))()
local config = allconfig.servers[1]
local host = config.hosts[1]
local routes = config.hosts[1].routes


local CONNECTION_DICT = {}






-- ==============================================================
--
--
-- 
-- ==============================================================

local ctx = zmq.init()
local channel_push = ctx:socket(zmq.PUSH)
channel_push:connect("tcp://localhost:5555")

local channel_pull = ctx:socket(zmq.PULL)
channel_pull:bind("tcp://lo:5556")

-- if config.hosts[1].routes['/'].recv_spec then
-- 	channel_pull = zmq:socket(luv.zmq.PULL)
-- 	channel_pull:bind(config.hosts[1].routes['/'].recv_spec)
-- end

local function sendPushZmqMsg( msg )
	channel_push:send(msg)
end

-- if config.hosts[1].routes['/'].send_spec then
-- 	channel_push = zmq:socket(luv.zmq.PUSH)
-- 	channel_push:connect(config.hosts[1].routes['/'].send_spec)
-- end

local function receivePullZmqMsg()
	local msg, err
	repeat
		-- use noblock zmq to switch to other coroutines
		msg, err = channel_pull:recv(zmq.NOBLOCK)
		if not msg then
			if err == 'timeout' then
				print('wait....')
				-- switch
				skt:next()
			else
				error("socket recv error:" .. err)
			end
		end
	until msg

	-- local more = src:getopt(zmq.RCVMORE) > 0
	-- dst:send(data,more and zmq.SNDMORE or 0)
	print(msg)

	return cmsgpack.unpack(data)
end

-- client is copas object
local function sendData (client, data)
	client:send(data)
end


-- ======================================================================
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


-- ========================================================================
local HTTP_FORMAT = 'HTTP/1.1 %s %s\r\n%s\r\n\r\n%s'

local function http_response(body, code, status, headers)
    code = code or 200
    status = status or "OK"
    headers = headers or {}
    headers['Content-Type'] = headers['Content-Type'] or 'text/plain'
    headers['Content-Length'] = #body

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

function init_parser(req)
	local cur	= req
	local cb    = {}

	function cb.on_message_begin()
		--	cur = {headers = {}, data={}}
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
		cur.body = body
	end
	
	function cb.on_message_complete()
		req['method'] = parser:method()
		req['version'] = parser:version()
	end

	return lhp.request(cb)
end



local makeUniKey = function ()
	math.randomseed(os.time())
	-- key is 6 length
	local key = math.random(100000, 999999)
	return tostring(key)
end


local recordConnection = function (client)
	local key
	-- select a new key
	while true do
		key = makeUniKey()
		if not CONNECTION_DICT[key] then break end
	end

	CONNECTION_DICT[key] = client
	return key
end

local cleanConnection = function (key, client)
	if CONNECTION_DICT[key] == client then
		CONNECTION_DICT[key] = nil
		client:close()
	end
end


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

		local path, err = regularPath(req.path)
		if not path then
			print(err)
			sendData(client, http_response('Forbidden', 403, 'Forbidden'))
			-- need to close
			return false
		elseif path == config.root_dir then 
			path = config.root_dir..'index.html' 
		end
		
		local file_t = luv.fs.stat(path)
		local file = luv.fs.open(path, "r", "664")
		--print(file_t)
		local last_modified_time = tonumber(req.headers['If-Modified-Since'])
		if not file_t or file_t.is_directory then
			sendData(client, http_response('Not Found', 404, 'Not Found', {
				['content-type'] = 'text/plain'
			}))
		elseif last_modified_time and file_t.mtime and last_modified_time >= file_t.mtime then
			sendData(client, http_response('Not Changed', 304, 'Not Changed'))
		else
			local size = 0
			if file_t then size = file_t.size end
			local res = http_response_header(200, 'OK', {
				['content-type'] = req['content-type'],
				['content-length'] = size,
				['Last-Modified'] = file_t.mtime,
				['Cache-Control'] = 'max-age='..host['max-age']
			})
		sendData(client, res)
		while true do
			local nread, content = file:read(4096)	
			-- print(nread, content)
			-- if no data read, nread is 0, not nil
			if nread > 0 then
				sendData(client, content)
			else
				break
			end

		end

		file:close()
	end
	
	-- here, we use one connection to serve one file
	cleanConnection(req.meta.conn_id, client)
end



local handlerProcessing = function (req)

	print('in handler....')
	sendPushZmqMsg(cmsgpack.pack(req))
	-- res is the response string from handler
	local res = receivePullZmqMsg()
	-- return to a single client connection
	if res and res.conns and #res.conns > 0 then
		for i, conn_id in pairs(res.conns) do
			-- need to check client connection is ok now?
			if CONNECTION_DICT[conn_id] then
				local client = CONNECTION_DICT[conn_id]
				sendData(client, http_response(res.data, res.code, res.status, res.headers))
				
				-- here, we may close some connections in one coroutine, 
				-- which can only cotains another connection
				cleanConnection(conn_id, client)
			end
		end
	end
end

function serviceDispatcher(client, req)
	local pattern, handle_t = findHandle(req)
	if pattern then
		if handle_t.type == 'dir' then

			feedfile(client, req)

		elseif handle_t.type == 'handler' then

			handlerProcessing(client, req)

		end
	else
		-- root_dir(req.path, '404 Not Found.')
		sendData(client, http_response('Not Found', 404, 'Not Found', {
			['content-type'] = 'text/plain'
		}))
	end
end



-- client_skt: tcp connection to browser

local cb_from_http = function (client_skt)
	-- client is copas wrapped object
	local client = copas.wrap(client_skt)
	while true do
		local data = client:receive()
		print('received, ', data)
		
		local req = {headers={}, data={}}
		local parser = init_parser(req)
		local bytes_read = parser:execute(reqstr)
		if bytes_read > 0 then
			serviceDispatcher(client, req)
		end

		
		-- skt:send(data)
	end
end


local server_socket = socket.bind("localhost", 8080)
copas.addserver(server_socket, cb_from_http)

while true do
	copas.step()
	-- processing for other events from your system here
end
-- copas.loop()


