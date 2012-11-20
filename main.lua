-- includes

local lhp = require 'http.parser'
local cmsgpack = require 'cmsgpack'
local mimetypes = require 'mime'
local copas = require 'copas'
local utils = require 'utils'
local posix = require 'posix'
local llthreads = require "llthreads"
local zlib = require 'zlib'
local CompressStream = zlib.deflate()
local file_log_driver = require "logging.file"

local log_dir = '/var/tmp/logs/'
local logger = file_log_driver(log_dir.."lgserver_access_%s.log", "%Y-%m-%d")

local zmq = require"zmq"

--require 'lglib'
--p = fptable
--p = utils.prettyPrint



local CONNECTION_DICT = {}
local CHANNEL_PUSH_DICT = {}
local CHANNEL_SUB_LIST = {}
local FileThreadMasterSocket

local config_file = arg[1] or './config.lua'

-- ==============================================================
-- load configurations
local allconfig = {}
setfenv(assert(loadfile(config_file)), setmetatable(allconfig, {__index=_G}))()

-- we define: one server in one config file
local SERVER = allconfig.server


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

local ctx = zmq.init(1)
-- walk through hosts
for i, host in ipairs(HOSTS) do
	-- walk through routes in each host
	for pattern, processor in pairs(host.routes) do
		if processor.type == 'handler' then
			local send_spec = processor.send_spec
			local recv_spec = processor.recv_spec
			-- avoid duplicated bindings
			--if not CHANNEL_PUSH_DICT[send_spec] and not CHANNEL_SUB_DICT[recv_spec] then
			if not CHANNEL_PUSH_DICT[send_spec] then
				-- bind push channels
				local channel_push = ctx:socket(zmq.PUSH)
				channel_push:bind(processor.send_spec)
				
				--local channel_sub = ctx:socket(zmq.SUB)
				--channel_sub:setopt(zmq.SUBSCRIBE, "")
				--channel_sub:connect(processor.recv_spec)
				
				-- record all zmq channels
				CHANNEL_PUSH_DICT[processor.send_spec] = channel_push
				table.insert(CHANNEL_SUB_LIST, processor.recv_spec)
			end
		--elseif processor.type == 'dir' then
		end

	end
end


local function findHost(req) 
	if req and req.headers and req.headers.host then
		local ask_host = req.headers.host:match('^([%w%.]+):?')
		for i, host in ipairs(HOSTS) do
			if host.matching and ask_host:match(host.matching..'$') then
				return host
			end
		end
	end

	return nil
end

function findHandle(host, req)
    if req.path then	
	    local path = req.path:gsub('/+', '/')
	    for i, pattern in ipairs(host.patterns) do
		    if path:match('^'..pattern) then
			    return pattern, host.routes[pattern]
		    end
	    end
    else
    	return nil, nil
    end
end


-- ==============================================================
-- http helpers
local HTTP_FORMAT = 'HTTP/1.1 %s %s\r\n%s\r\n\r\n%s'

local function http_response(body, code, status, headers)
    code = code or 200
    status = status or "OK"
    headers = headers or {}
    headers['content-type'] = headers['content-type'] or 'text/plain'
--    if not headers['content-encoding'] then headers['content-length'] = #body end
    headers['content-length'] = #body

    local raw = {}
    for k, v in pairs(headers) do
        table.insert(raw, string.format('%s: %s', tostring(k), tostring(v)))
    end

    return string.format(HTTP_FORMAT, code, status, table.concat(raw, '\r\n'), body)
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
	local client

	function cb.on_message_begin()
	    cur.headers = {}
		cur.data = {}
		cur.bodies = {}
		cur.meta.completed = false

		local conn_obj = CONNECTION_DICT[cur.meta.conn_id]
		if conn_obj then
			client = conn_obj[1]
		end
		--print('msg begin.')
    end

	function cb.on_url(url)
		local info_str = " %s, %s, %s"
		
		local remote_ip = client.socket:getpeername()
		logger:info(string.format(info_str, 
								  req.meta.conn_id, 
								  url, 
								  remote_ip or ''))

		cur.url = url
		cur.path, cur.query_string, cur.fragment = parse_path_query_fragment(url)
	end

	function cb.on_header(field, value)
		cur.headers[field:lower()] = value
	end

	function cb.on_body(chunk)
        if chunk then table.insert(cur.bodies, chunk) end
	end
	
	function cb.on_message_complete()
        cur.body = table.concat(cur.bodies)
		cur.bodies = nil
		cur.meta.completed = true

		local user_agent = req.headers['user-agent']
		if user_agent:find('MSIE') or user_agent:find('Trident') then
			req.meta.isie = 'ie'
		end
	end

	return lhp.request(cb)
end



-- ==============================================================
-- zmq helpers
local function sendPushZmqMsg(channel_push, req)
	channel_push:send(cmsgpack.pack(req))
end

--[[
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
--]]

-- client is copas object
local function sendData (client, data)
	if client then
		local status = client:send(data)
		if not status then return false end
	end
	
	return true
end


math.randomseed(os.time())

local makeUniConnKey = function ()
	-- key is 6 length
	local key
	-- select a new key
	while true do
	 	key = math.random(100000, 999999)
		if not CONNECTION_DICT[key] then break end
	end
	
	return tostring(key)
end

local recordConnection = function (client, req)
	local key = makeUniConnKey()
	
	-- push to bamboo handler
	req.meta.conn_id = key
	CONNECTION_DICT[key] = {client, req}
	return key
end


local cleanConnection = function (key, client, channel_push)
	--if CONNECTION_DICT[key] and CONNECTION_DICT[key][1] == client then
		CONNECTION_DICT[key] = nil
		client.socket:close()

		if channel_push then
			-- send disconnect msg to bamboo handler
			local disconnect_msg = {
				meta = {type = 'disconnect', conn_id = key}
			}
			sendPushZmqMsg(channel_push, disconnect_msg)
		end
end

local function getPushChannel (processor)
--	return CHANNEL_PUSH_DICT[processor.send_spec], CHANNEL_SUB_DICT[processor.recv_spec]
	return CHANNEL_PUSH_DICT[processor.send_spec]
end


local function findPushChannel (req)

	local host = findHost(req)
	if not host then
		host = HOSTS[1]
	end

	local _, processor = findHandle(host, req)
    local channel_push
    if processor then
	    channel_push = CHANNEL_PUSH_DICT[processor.send_spec]
    end

	return channel_push
end

local responseData = function (conn_id, data)
    local conn_obj = CONNECTION_DICT[conn_id]
	if conn_obj then
		local client = conn_obj[1]
		client:send(data)
	end		
end

--[[
local response = function (conn_id, res)
    local conn_obj = CONNECTION_DICT[conn_id]
	if conn_obj then
		local client = conn_obj[1]
		sendData(client, http_response(res.data, res.code, res.status, res.headers))
	end		
end
--]]

-- ====================================================================
-- static file server handler
function feedfile(host, key, client, req)
	local path, err = regularPath(host, req.path)
	if not path then
		print(err)
		sendData(client, http_response('Forbidden', 403, 'Forbidden'))
		--cleanConnection(req.meta.conn_id, client)
		-- need to close
		return false
	elseif path == host.root_dir then 
		path = host.root_dir..'index.html' 
	end

	local params = {}
	table.insert(params, key)
	table.insert(params, path)
	table.insert(params, req.headers['if-modified-since'] or 'nil')
	table.insert(params, host['max-age'] or 'nil')
	table.insert(params, req.meta.isie or 'nil')
	table.insert(params, '\n')

	local reqstr = table.concat(params, '~')
	-- send parameters to file thread
	-- and return immediately
	FileThreadMasterSocket:send(reqstr)

--[[
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
			['cache-control'] = 'max-age='..(host['max-age'] or '0')
		})
		-- send header
		sendData(client, res)
		local content, s
		while true do
			content = posix.read(file, 8192)	
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
--]]	
	-- here, we use one connection to serve one file
	-- cleanConnection(req.meta.conn_id, client)
end

local handlerProcessing = function (processor, client, req)
	
	local channel_push = getPushChannel(processor)

	sendPushZmqMsg(channel_push, req)
	
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
			feedfile(host, key, client, req)

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
	local req, key, parser
	req = {headers={}, meta={}}
	key = recordConnection(client, req)
	parser = init_parser(req)

	
	-- while here, for keep-alive
	while true do

		local s, errmsg, partial = client:receive(8192)
		if not s and errmsg == 'closed' then 
		    break
		end

		local reqstr = s or partial
--print(reqstr)
		parser:execute(reqstr)

		if req.meta.completed then
			req.method = parser:method()
			req.version = parser:version()
			serviceDispatcher(key)
		end
	end

    cleanConnection (key, client, findPushChannel(req))
end

local cb_from_zmq_thread = function (client_skt)
	local client = copas.wrap(client_skt)
	while true do
		local strs = {}
		-- may have more than 1 messages
		while true do
			local s, errmsg, partial = client:receive(8192)
--			if not s and errmsg == 'closed' then end
--			print('s, errmsg, partial', s and #s, errmsg)
			if not s and errmsg == 'timeout' then 
				if partial and #partial > 0 then
					table.insert(strs, partial)
					-- reqstr = reqstr .. partial
				end
				break
			end 
			-- reqstr = reqstr..(s or partial)
			table.insert(strs, s or partial)
		end
		-- print('in thread callback', #reqstr, reqstr:sub(1,10))
		
		local reqstr = table.concat(strs)
		-- retreive messages
		local msgs = {}
		local c, l = 1, 1
		while c < #reqstr do
			l = reqstr:find(' ', c)
			if not l then break end
			
			local msg_length = tonumber(reqstr:sub(c, l-1))
			local msg = reqstr:sub(l+1, l+msg_length)
			table.insert(msgs, msg)

			c = l + msg_length + 1
		end
		
		for _, msg in ipairs(msgs) do
			local res = cmsgpack.unpack(msg)
			if res.meta.isie then
				--print('this is ie...')
				--res.data = '\x78\x9c'..res.data 
				--res.data = res.data:sub(3)
			else
				res.data = CompressStream(res.data, 'full')
				res.headers['content-encoding'] = 'deflate'
			end

			local res_data = http_response(res.data, res.code, res.status, res.headers)

			if res.meta and res.conns then
				-- protocol define: res.conns must be a table
				if #res.conns > 0 then
					-- multi connections reples
					for i, conn_id in ipairs(res.conns) do
						responseData (conn_id, res_data)
					end
				else
					-- single connection reply
					-- XXX: res.meta.conn_id is probably not the same as req.meta.conn_id
					local conn_id = res.meta.conn_id
					-- print('in single sending...', conn_id)
					responseData (conn_id, res_data)
				end
			end
			
		end
	end
end

local cb_from_file_thread = function (client_skt)
	FileThreadMasterSocket = client_skt
--print('FileThreadMasterSocket', FileThreadMasterSocket)
	local client = copas.wrap(client_skt)
	local left_data
	while true do
		local key
		local file_size = 0
		local file_size_string
		local PART_LEN = 8192
		local part_len = PART_LEN
		local received_file_size = 0
		-- one while treate on file
-- tangg
--		print('------> a new file', left_data and #left_data)
		while true do
			local s, errmsg, partial = client:receive(part_len)
--			if not s and errmsg == 'closed' then end
--			print('in file server.  s, errmsg, part, part_len', s and #s, errmsg, partial and #partial, part_len)
			if errmsg == 'closed' then break end
			
			local data = s or partial
--print('data', #data, left_data and #left_data)
			if left_data then 
				data = left_data .. data 
				left_data = nil 
			end
--print('===>')
--print(data:sub(1,20))
--print('key', key)
			-- if stream is continued
			if key and received_file_size < file_size then
--				print('0008', received_file_size, #data)
				-- return file part data immediately
				responseData(key, data)
				received_file_size = received_file_size + #data
--				print('0009', received_file_size)
				part_len = (file_size - received_file_size < PART_LEN) and file_size - received_file_size or PART_LEN
--				print('0010', part_len)
				
			else
				-- for new data
				while #data >= 10 do
					
					key, file_size_string = data:match('^(%d%d%d%d%d%d):(%d+):')
--print('--->', key, file_size_string)
--print(#data, data:sub(1,20))
					if key then
						-- file_size_string containing the http headers of file
						local len2 = 0
						if file_size_string then
							len2 = #file_size_string
						end
						file_size = tonumber(file_size_string)

						local head_len = (6+1+len2+1)
						local left_size = #data - head_len
						if left_size >= file_size then
							-- return all data of this file
							responseData(key, data:sub(head_len+1, head_len+file_size))
							-- copy the rest to left_data
							data = data:sub(head_len+file_size+1)
							received_file_size = file_size
							key = nil
						else
							responseData(key, data:sub(head_len+1))
							part_len = (file_size - left_size < PART_LEN) and file_size - left_size or PART_LEN
							received_file_size = left_size
							left_data = nil
--							print('---part_len received_file_size', part_len, received_file_size)
							break
						end
											
					else
						local key2, code = data:match('^(%d%d%d%d%d%d) (%d%d%d)')
--print('-->2', key2, code)
--print(data:sub(1,20))
						if key2 then
							if code == '404' then
								responseData(key2, http_response('Not Found', 404, 'Not Found'))
							elseif code == '304' then
--								print('in 304 ready return')
								responseData(key2, http_response('Not Changed', 304, 'Not Changed'))
							end
							data = data:sub(11)
							-- key = nil
						else
							print('meet this case, left_data len is shorter than a valid file.')
							left_data = data
							break
							-- error('file protocol data error.')
						end
					end
					left_data = data
					part_len = PART_LEN
				end
			end

--			print('received_size, file_size', received_file_size, file_size)
			-- next file
			if received_file_size >= file_size then break end

		end

		key = nil
	end
end



local zmq_server = socket.bind('127.0.0.1', '12310')
copas.addserver(zmq_server, cb_from_zmq_thread)

local file_server = socket.bind('127.0.0.1', '12311')
copas.addserver(file_server, cb_from_file_thread)

local main_server = socket.bind(SERVER.bind_addr, SERVER.port)
copas.addserver(main_server, cb_from_http)
print('lgserver bind to '..SERVER.bind_addr..":"..SERVER.port)

-- ==========================================================
-- another thread
local zmq_thread = require 'zmqthread'
-- create detached child thread.
local thread = llthreads.new(zmq_thread, '127.0.0.1', '12310', CHANNEL_SUB_LIST[1])
-- start non-joinable detached child thread.
assert(thread:start(true))

local file_thread = require 'filethread'
-- create detached child thread.
local thread = llthreads.new(file_thread, '127.0.0.1', '12311')
-- start non-joinable detached child thread.
assert(thread:start(true))


os.execute('mkdir -p ' .. log_dir)

-- while true do
--  	copas.step()
--  	-- processing for other events from your system here
-- end

print('starting server....')
-- main loop
copas.loop()

