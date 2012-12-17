-- includes

-- Load the Lua/APR binding.
local apr = require 'apr'
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

local queue, zmqqueue

--require 'lglib'
--p = fptable
--p = utils.prettyPrint


local CONNECTION_DICT = {}
local CHANNEL_PUSH_DICT = {}
local CHANNEL_SUB_LIST = {}


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
		local ask_host = req.headers.host:match('^([%w%-%.]+):?')
		if ask_host then
            for i, host in ipairs(HOSTS) do
			    if host.matching and ask_host:match(host.matching..'$') then
				    return host
			    end 
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



function findType(path)
	local content_type
	-- now req is the incoming request data
	local ext = path:match('(%.%w+)$')
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
		if user_agent and (user_agent:find('MSIE') or user_agent:find('Trident')) then
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

-- client is copas object
local function sendData (client, data)
	local s = client:send(data)
	if s then 
		return true 
	else
		return false
	end
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
	
	conn_queue:push(client)

	return key
end


local cleanConnection = function (key, client)
	CONNECTION_DICT[key] = nil

	-- send disconnect msg to bamboo handler
	local disconnect_msg = {
		meta = {type = 'disconnect', conn_id = key}
	}

    for key, chan in pairs(CHANNEL_PUSH_DICT) do 
		sendPushZmqMsg(chan, disconnect_msg)
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


-- ====================================================================
-- static file server handler
local COMPRESS_FILETYPE_DICT = {
	['text/css'] = true,
	['application/x-javascript'] = true,
	['text/html'] = true,
	['text/plain'] = true
}

local tmpdir = '/tmp/lgserverzipfiles/'

local function changeGMT2Timestamp (gmt_date)
	local p="%a+, (%d+) (%a+) (%d+) (%d+):(%d+):(%d+) GMT"
	local day,month,year,hour,min,sec = gmt_date:match(p)
	if day and month and year and hour and min and sec then
		local MON = {Jan=1,Feb=2,Mar=3,Apr=4,May=5,Jun=6,Jul=7,Aug=8,Sep=9,Oct=10,Nov=11,Dec=12}
		local month = MON[month]
		local offset = os.time()-os.time(os.date("!*t"))
		local timestamp = os.time({day=day,month=month,year=year,hour=hour,min=min,sec=sec}) + offset
		return timestamp
	else
		return nil
	end
end


local handlerProcessing = function (processor, client, req)
	
	local channel_push = getPushChannel(processor)

	sendPushZmqMsg(channel_push, req)
	
end

function serviceDispatcher(key)
	local conn_obj = CONNECTION_DICT[key]
	if not conn_obj then return end

	local client = conn_obj[1]
	local req = conn_obj[2]

	local host = findHost(req)
	if not host then
		host = HOSTS[1]
	end
	local pattern, handle_t = findHandle(host, req)
	if pattern then
		if handle_t.type == 'dir' then
			local path, err = regularPath(host, req.path)
			if not path then
				logger:info(err)
				sendData(client, http_response('Forbidden', 403, 'Forbidden'))
				return false
			elseif path == host.root_dir then 
				path = host.root_dir..'/static_default/index.html' 
			end
			
			local extra = {
				['if-modified-since'] = req.headers['if-modified-since'],
				['isie'] = req.meta.isie,
				['max-age'] = host['max-age'] or req.headers['max-age'],
			}

			queue:push(client, path, extra)

		elseif handle_t.type == 'handler' then

			handlerProcessing(handle_t, client, req)

		end
	else
		sendData(client, http_response('Not Found', 404, 'Not Found'))
	end
end


-- local cb_from_zmq_thread = function (client_skt)
-- 	local client = copas.wrap(client_skt)
-- --	while true do
-- -- print('in cb_from_zmq_thread')
-- 		local strs = {}
-- 		-- may have more than 1 messages
-- 		while true do
-- 			local s, errmsg, partial = client:receive(8192)
-- --			print(s and #s, errmsg, partial and #partial)
-- 			table.insert(strs, s or partial)
--             if errmsg == 'closed' then break end
-- 		end
		
-- 		-- local reqstr = table.concat(strs)
-- 		local msg = table.concat(strs)
--         --print('reqstr----', reqstr)
-- --        print('reqstr----', #reqstr)
-- 		-- retreive messages
-- 		-- local msgs = {}
-- 		-- local c, l = 1, 1
-- 		-- while c < #reqstr do
-- 		-- 	l = reqstr:find(' ', c)
-- 		-- 	if not l then break end
			
-- 		-- 	table.insert(msgs, msg)

-- 		-- 	c = l + msg_length + 1
-- 		-- end

-- 		-- for _, msg in ipairs(msgs) do
-- 		local res = cmsgpack.unpack(msg)

-- 		local res_data = http_response(res.data, res.code, res.status, res.headers)
-- 		if res.meta and res.conns then
-- 			-- protocol define: res.conns must be a table
-- 			if #res.conns > 0 then
-- 				-- multi connections reples
-- 				for i, conn_id in ipairs(res.conns) do
-- 					-- logger:debug('Ready to multi response '..conn_id )
-- 					responseData (conn_id, res_data)
-- 				end
-- 			else
-- 				-- single connection reply
-- 				-- XXX: res.meta.conn_id is probably not the same as req.meta.conn_id
-- 				local conn_id = res.meta.conn_id
-- 				-- logger:debug('Ready to single response '..conn_id )
-- 				-- print('in single sending...', conn_id)
-- 				responseData (conn_id, res_data)
-- 			end
-- 		end
			
-- 		-- end
-- --	end
-- end


-- -- client_skt: tcp connection to browser
-- local cb_from_http = function (client_skt)
-- 	-- client is copas wrapped object
-- 	local client = copas.wrap(client_skt)
-- 	local req, key, parser
-- 	req = {headers={}, meta={}}
-- 	key = recordConnection(client, req)
-- 	parser = init_parser(req)

-- 	-- while here, for keep-alive
-- 	while true do

-- 		local s, errmsg, partial = client:receive(8192)
-- 		if not s and errmsg == 'closed' then 
-- 		    break
-- 		end

-- 		local reqstr = s or partial
-- 		parser:execute(reqstr)

-- 		if req.meta.completed then
-- 			req.method = parser:method()
-- 			req.version = parser:version()
-- 			serviceDispatcher(key)
-- 		end
-- 	end

--     cleanConnection (key)
-- 	logger:info('connection '..key..' closed.')
-- end


-- ==========================================================
-- another thread
local zmq_thread = require 'zmqthread'
-- create detached child thread.
local thread = llthreads.new(zmq_thread, '127.0.0.1', '12310', CHANNEL_SUB_LIST[1])
-- start non-joinable detached child thread.
assert(thread:start(true))

local zmq_server = socket.bind('127.0.0.1', '12310')
copas.addserver(zmq_server, cb_from_zmq_thread)


local server = assert(apr.socket_create())
assert(server:bind(SERVER.bind_addr, SERVER.port))
assert(server:listen(1024))
local pollset_size = 1024
local pollset = assert(apr.pollset(pollset_size))
assert(pollset:add(server, 'input'))

--print("Running webserver with " .. num_threads .. " client threads on http://localhost:" .. port_number .. " ..")
-- local main_server = socket.bind(SERVER.bind_addr, SERVER.port)
-- copas.addserver(main_server, cb_from_http)
local str = 'lgserver bind to '..SERVER.bind_addr..":"..SERVER.port
print(str);logger:info(str)





-- Define the function to execute in each child thread.
function file_server(thread_id, queue)
--  pcall(require, 'luarocks.require')
	local apr = require 'apr'
	local posix = require 'posix'
	local zlib = require 'zlib'
	local CompressStream = zlib.deflate()


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



	function findType(path)
		local content_type
		-- now req is the incoming request data
		local ext = path:match('(%.%w+)$')
		if ext then
			content_type = mimetypes[ext]
		end

		return content_type or 'text/plain'
	end


	local COMPRESS_FILETYPE_DICT = {
		['text/css'] = true,
		['application/x-javascript'] = true,
		['text/html'] = true,
		['text/plain'] = true
	}

	local tmpdir = '/tmp/lgserverzipfiles/'

	local function changeGMT2Timestamp (gmt_date)
		local p="%a+, (%d+) (%a+) (%d+) (%d+):(%d+):(%d+) GMT"
		local day,month,year,hour,min,sec = gmt_date:match(p)
		if day and month and year and hour and min and sec then
			local MON = {Jan=1,Feb=2,Mar=3,Apr=4,May=5,Jun=6,Jul=7,Aug=8,Sep=9,Oct=10,Nov=11,Dec=12}
			local month = MON[month]
			local offset = os.time()-os.time(os.date("!*t"))
			local timestamp = os.time({day=day,month=month,year=year,hour=hour,min=min,sec=sec}) + offset
			return timestamp
		else
			return nil
		end
	end


	while true do
		-- local client, msg, code = queue:pop()
		local client, path, extra = queue:pop()
		-- assert(client)
		if client then
			local status, message = pcall 
			(function()
				 local file_t = posix.stat(path)
				 local last_modified_time = extra['if-modified-since']
				 local isie = extra['isie']
				 if isie and last_modified_time then
					 last_modified_time = changeGMT2Timestamp(last_modified_time)
				 else
					 last_modified_time = tonumber(last_modified_time)
				 end

				 if not file_t or file_t.type == 'directory' then

					 client:write(http_response('Not Found', 404, 'Not Found'))

				 elseif last_modified_time and file_t.mtime and last_modified_time >= file_t.mtime then

					 client:write(http_response('Not Changed', 304, 'Not Changed'))

				 else
					 local max_age = extra['max-age'] or 0
					 local filename = path:match('/([^/]+)$')
					 if not filename then return end 
					 
					 local tmpfile_t = posix.stat(tmpdir..filename)
					 local file_type = findType(path)
					 if not tmpfile_t or not COMPRESS_FILETYPE_DICT[file_type] or tmpfile_t.mtime < file_t.mtime or isie then
						 -- read new file
						 local file = posix.open(path, posix.O_RDONLY, "664")
						 local res = http_response_header(200, 'OK', {
															  ['content-type'] = file_type,
															  ['content-length'] = file_t.size,
															  ['last-modified'] = file_t.mtime,
															  ['cache-control'] = 'max-age='..max_age
																	 })
						 -- send header
						 sendData(client, res)
						 local content, s
						 local file_bufs = {}
						 while true do
							 content = posix.read(file, 8192)	
							 -- if no data read, nread is 0, not nil
							 if #content > 0 then
								 s = client:write(content)
								 if not s then break end

								 table.insert(file_bufs, content)
							 else
								 break
							 end
						 end
						 posix.close(file)
						 
						 -- write tmp zip file
						 if #file_bufs > 0 
							 and filename 
							 and COMPRESS_FILETYPE_DICT[file_type] 
							 and not isie 
						 then
							 local allcontent = table.concat(file_bufs)
							 allcontent = CompressStream(allcontent, 'full')
							 
							 local base = req.path:match('^(.*/)[^/]+$')
							 -- print('base-->', base)
							 local fd
							 if base == '' then
								 fd = io.open(tmpdir .. filename, 'w')
							 else
								 os.execute('mkdir -p ' .. tmpdir..base)
								 fd = io.open(tmpdir .. base .. filename, 'w')
							 end
							 if fd then
								 fd:write(allcontent)
								 fd:close()
							 end
						 end
					 else
						 -- read buffed zip file
						 local file = posix.open(tmpdir..filename, posix.O_RDONLY, "664")
						 local res = http_response_header(200, 'OK', {
															  ['content-type'] = file_type,
															  ['content-length'] = tmpfile_t.size,
															  ['last-modified'] = tmpfile_t.mtime,
															  ['content-encoding'] = 'deflate',
															  ['cache-control'] = 'max-age='..max_age
																	 })
						 -- send header
						 client:write(res)

						 local content, s
						 while true do
							 content = posix.read(file, 8192)	
							 -- if no data read, nread is 0, not nil
							 if #content > 0 then
								 s = client:write(content)
								 
								 -- client:next()
							 else
								 break
							 end
						 end
						 posix.close(file)

					 end
				 end
			)

			if not status then
				print('Error while serving request:', message)
			end
		end
	end
end


local function zmq_server (channel_sub_addr, zmqqueue)
	local cmsgpack = require 'cmsgpack'
	local zmq = require 'zmq'

    local ctx = zmq.init(1)
    local channel_sub = ctx:socket(zmq.SUB)
	channel_sub:setopt(zmq.SUBSCRIBE, "")
--	channel_sub:connect(channel_sub_addr)
	channel_sub:bind(channel_sub_addr)

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

	local responseData = function (conn_id, data)
		local conn_obj = CONNECTION_DICT[conn_id]
		if conn_obj then
			local client = conn_obj[1]
			client:send(data)
		end		
	end
	

    while true do

		local client = zmqqueue:pop()
        if client then
		    local msg = channel_sub:recv()   -- block wait
			local res = cmsgpack.unpack(msg)

			local res_data = http_response(res.data, res.code, res.status, res.headers)
			if res.meta and res.conns then
				-- protocol define: res.conns must be a table
				if #res.conns > 0 then
					-- multi connections reples
					for i, conn_id in ipairs(res.conns) do
						-- logger:debug('Ready to multi response '..conn_id )
						responseData (conn_id, res_data)
					end
				else
					-- single connection reply
					-- XXX: res.meta.conn_id is probably not the same as req.meta.conn_id
					local conn_id = res.meta.conn_id
					-- logger:debug('Ready to single response '..conn_id )
					-- print('in single sending...', conn_id)
					responseData (conn_id, res_data)
				end
			end


            client:write(msg)
			client:close()
        end 
    end
    
    print('Client Ends.')


end


-- Create the thread queue (used to pass sockets between threads).
file_queue = apr.thread_queue(10)
zmq_queue = apr.thread_queue(1)
conn_queue = apr.thread_queue(1)

-- Create the child threads and keep them around in a table (so that they are
-- not garbage collected while we are still using them).
local pool = {}
for i = 1, num_threads do
  table.insert(pool, apr.thread(file_server, i, file_queue))
end
table.insert(pool, apr.thread(zmq_server, CHANNEL_SUB_LIST[1], zmq_queue, conn_queue))



os.execute('mkdir -p ' .. tmpdir)
os.execute('mkdir -p ' .. log_dir)



-- Enter the accept() loop in the parent thread.
while true do
  local status, message = pcall(function()

  local readable, writable = assert(pollset:poll(-1))
  -- Process requests.
  for _, socket in ipairs(readable) do
	  if socket == server then
		  -- first create each client connection
		  local client = assert(server:accept())
		  assert(pollset:add(client, 'input'))
	  else
		  -- client recieved some data
		  local client = socket
		  local req, key, parser

		  req = { headers={}, meta={} }
		  key = recordConnection(client, req)
		  parser = init_parser(req)

		  local lines = {}
		  local lines[1] = assert(client:read(), "Failed to receive request from client!")
		  for line in client:lines() do
			  table.insert(lines, line)
		  end

		  local reqstr = table.concat(lines, '\r\n')
		  parser:execute(reqstr)

		  if req.meta.completed then

			  assert(pollset:remove(client))
			  assert(pollset:add(client, 'output'))

			  req.method = parser:method()
			  req.version = parser:version()
			  serviceDispatcher(key)
		  end

	  end
  end

  end)
  if not status then
	  print('Error while serving request:', message)
  end
end
