-- includes

local lhp = require 'http.parser'
local cmsgpack = require 'cmsgpack'
local mimetypes = require 'mime'
local copas = require 'copas'
local utils = require 'utils'
local posix = require 'posix'

local zmq = require"zmq"

require 'lglib'
p = fptable
--p = utils.prettyPrint


local config_file = arg[1] or './config.lua'

-- load configurations
local allconfig = {}
setfenv(assert(loadfile(config_file)), setmetatable(allconfig, {__index=_G}))()

-- we define: one server in one config file
local SERVER = allconfig.server


local CONNECTION_DICT = {}
local CHANNEL_DICT = {}
-- ==============================================================
local ctx = zmq.init(1)

local HOSTS = SERVER.hosts
-- arrage hosts from longest to shorterest by matching hostname
table.sort(HOSTS, function (a, b) return #(a.matching or '') > #(b.matching or '') end)

for i, host in ipairs(HOSTS) do
	local patterns = {}
	for pattern, handle_t in pairs(host.routes) do
		table.insert(patterns, pattern)
	end
	-- arrage patterns from longest to shorterest
	table.sort(patterns, function (a, b) return #a > #b end)
	host.patterns = patterns
end

-- walk through hosts
for i, host in ipairs(HOSTS) do
	-- walk through routes in each host
	for pattern, processor in pairs(host.routes) do
		if processor.type == 'handler' then
			local send_spec = processor.send_spec
			local recv_spec = processor.recv_spec
			-- avoid duplicated bindings
			if not CHANNEL_DICT[send_spec] and not CHANNEL_DICT[recv_spec] then
				local channel_push = ctx:socket(zmq.PUSH)
				channel_push:bind(processor.send_spec)
				local channel_pull = ctx:socket(zmq.PULL)
				channel_pull:bind(processor.recv_spec)
				
				-- record all zmq channels
				CHANNEL_DICT[processor.send_spec] = channel_push
				CHANNEL_DICT[processor.recv_spec] = channel_pull
			end
		--elseif processor.type == 'dir' then
		end

	end
end

local function sendPushZmqMsg(channel_push, msg)
	channel_push:send(msg)
end

local function receivePullZmqMsg(channel_pull, client)
	local msg, err
	repeat
		-- use noblock zmq to switch to other coroutines
		msg, err = channel_pull:recv(zmq.NOBLOCK)
		if not msg then
			if err == 'timeout' then
				-- print('wait....')
				-- switch
				client:next()
			else
				error("socket recv error:" .. err)
			end
		end
	until msg

	-- local more = src:getopt(zmq.RCVMORE) > 0
	-- dst:send(data,more and zmq.SNDMORE or 0)

	return cmsgpack.unpack(msg)
end

-- client is copas object
local function sendData (client, data)
	if client then
		local status = client:send(data)
		if not status then return false end
	end
	
	return true
end


-- ======================================================================
local function findHost(req) 
	local ask_host = req.headers.host:match('^([%w%.]+):?')
	for i, host in ipairs(HOSTS) do
		if host.matching and ask_host:match(host.matching..'$') then
			return host
		end
	end

	return nil
end

function findHandle(host, req)

	local path = req.path:gsub('/+', '/')
	for i, pattern in ipairs(host.patterns) do
		if path:match('^'..pattern) then
			return pattern, host.routes[pattern]
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
    headers['content-type'] = headers['content-type'] or 'text/plain'
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

function init_parser(req)
	local cur	= req
	local cb    = {}

	function cb.on_message_begin()
	end

	function cb.on_url(url)
		print(os.date("%Y-%m-%d %H:%M:%S", os.time()), req.meta.conn_id, url)
		cur.url = url
		cur.path, cur.query_string, cur.fragment = parse_path_query_fragment(url)
	end

	function cb.on_header(field, value)
		cur.headers[field:lower()] = value
	end

	function cb.on_body(body)
		cur.body = body
	end
	
	function cb.on_message_complete()
		-- print('http parser complete')
--		req['method'] = parser:method()
--		req['version'] = parser:version()

		req.meta.completed = true
	end

	return lhp.request(cb)
end


math.randomseed(os.time())

local makeUniKey = function ()
	-- key is 6 length
	local key = math.random(100000, 999999)
	return tostring(key)
end


local recordConnection = function (client, req)
	local key
	-- select a new key
	while true do
		key = makeUniKey()
		if not CONNECTION_DICT[key] then break end
	end
	
	-- push to bamboo handler
	req.meta.conn_id = key
	CONNECTION_DICT[key] = {client, req}
	return key
end

local cleanConnection = function (key, client, channel_push)
	if CONNECTION_DICT[key][1] == client then
		CONNECTION_DICT[key] = nil
		client.socket:close()
		client = nil

		if channel_push then
			-- send disconnect msg to bamboo handler
			local disconnect_msg = {
				meta = {type = 'disconnect', conn_id = key}
			}
			sendPushZmqMsg(channel_push, cmsgpack.pack(disconnect_msg))
		end
	end
end


function findType(req)
	local content_type
	-- now req is the incoming request data
	local ext = req.path:match('(%.%w+)$')
	if ext then
		content_type = mimetypes[ext]
	end

	return content_type or 'text/plain'
end

function regularPath(host, path)
	local orig_path = path
	path = host.root_dir..path
	path = path:gsub('/+', '/') 
	
	local l = #host.root_dir
	local count = 0
	while l do
		l = path:find('/', l+1)
		if l and path:sub(l-2, l) == '../' then
			count = count - 1
		end
		if count < 0 then return nil, "[Error]Invald Path "..orig_path end
	end
	
	return path
end

function feedfile(host, client, req)
	local path, err = regularPath(host, req.path)
	if not path then
		print(err)
		sendData(client, http_response('Forbidden', 403, 'Forbidden'))
		cleanConnection(req.meta.conn_id, client)
		-- need to close
		return false
	elseif path == host.root_dir then 
		path = host.root_dir..'index.html' 
	end

	local file_t = posix.stat(path)
	local file = posix.open(path, posix.O_RDONLY, "664")
	--print(file_t)
	local last_modified_time = tonumber(req.headers['if-modified-since'])
	if not file_t or file_t.type == 'directory' then
		sendData(client, http_response('Not Found', 404, 'Not Found', {
										   ['content-type'] = 'text/plain'
																	  }))
	elseif last_modified_time and file_t.mtime and last_modified_time >= file_t.mtime then
		sendData(client, http_response('Not Changed', 304, 'Not Changed'))
	else
		local size = 0
		if file_t then size = file_t.size end
		local res = http_response_header(200, 'OK', {
											 ['content-type'] = findType(req),
											 ['content-length'] = size,
											 ['last-modified'] = file_t.mtime,
											 ['cache-control'] = 'max-age='..host['max-age']
													})
		-- send header
		sendData(client, res)
		local content, s
		while true do
			content = posix.read(file, 4096)	
			-- if no data read, nread is 0, not nil
			if #content > 0 then
				s = sendData(client, content)
				-- if connection is broken
				if not s then break end
				-- switch to another coroutine
				client:next()
			else
				break
			end
		end
		posix.close(file)
	end
	
	-- here, we use one connection to serve one file
	cleanConnection(req.meta.conn_id, client)
end

local function findChannelsByProcessor (processor)
	return CHANNEL_DICT[processor.send_spec], CHANNEL_DICT[processor.recv_spec]
end

local handlerProcessing = function (processor, client, req)
	
	local channel_push, channel_pull = findChannelsByProcessor(processor)

	sendPushZmqMsg(channel_push, cmsgpack.pack(req))
	-- res is the response string from handler
	local res = receivePullZmqMsg(channel_pull, client)
	-- temporary test
	-- client:send(res)
	-- client:send(http_response('Hello world!', res.code, res.status, res.headers))
	-- cleanConnection(req.meta.conn_id, client)
	-- print('return from zmq pull')

	if not res.meta or not res.conns then return end

	-- return to a single client connection
	-- protocol define: res.conns must be a table
	if #res.conns > 0 then
		local conns_i = #res.conns
		-- multi connections reples
		for i, conn_id in pairs(res.conns) do
			-- need to check client connection is ok now?
			if CONNECTION_DICT[conn_id] then
				local client = CONNECTION_DICT[conn_id][1]
				sendData(client, http_response(res.data, res.code, res.status, res.headers))
				
				-- pop #conns - 1 coroutines from copas's _reading and _writing set
				if conns_i >= 2 then
					client:popcoes(client)
					conns_i = conns_i - 1
				end

				-- here, we may close some connections in one coroutine, 
				-- which can only cotains another connection
				cleanConnection(conn_id, client, channel_push)
			end
		end
	else
		-- single connection reply
		-- XXX: res.meta.conn_id is probably not the same as req.meta.conn_id
		local conn_id = res.meta.conn_id
		if CONNECTION_DICT[conn_id] then
			local client = CONNECTION_DICT[conn_id][1]
			sendData(client, http_response(res.data, res.code, res.status, res.headers))
			
			cleanConnection(conn_id, client, channel_push)
		end					
		
	end
end

function serviceDispatcher(key)
	local client = CONNECTION_DICT[key][1]
	local req = CONNECTION_DICT[key][2]

	local host = findHost(req)
	if not host then
		host = HOSTS[1]
	end
	local pattern, handle_t = findHandle(host, req)
	if pattern then
		if handle_t.type == 'dir' then
			feedfile(host, client, req)

		elseif handle_t.type == 'handler' then
			handlerProcessing(handle_t, client, req)

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
	local req = {headers={}, data={}, meta={completed = false}}
	local key = recordConnection(client, req)
	local parser = init_parser(req)
	

	-- read all http strings
	while true do
		-- read one line each time
		local reqstr = client:receive()
		if not reqstr then break end
		
		local bytes_read = parser:execute(reqstr..'\r\n')
		
		if req.meta.completed then break end
	end

	if req.meta.completed then
		req['method'] = parser:method()
		req['version'] = parser:version()

		serviceDispatcher(key)
	else
		client:send('invalid http request')
	end
	
	-- close after finishing processing
	-- client.socket:close()

end


local server_socket = socket.bind(SERVER.bind_addr, SERVER.port)
copas.addserver(server_socket, cb_from_http)
print('lgserver bind to '..SERVER.bind_addr..":"..SERVER.port)

-- while true do
-- 	copas.step()
-- 	-- processing for other events from your system here
-- end

copas.loop()


