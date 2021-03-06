-- includes

-- run as daemon
require 'daemon'
daemon.daemonize('nochdir,nostdfds,noumask0')

local lhp = require 'http.parser'
local cmsgpack = require 'cmsgpack'
local mimetypes = require 'mime'
local copas = require 'copas'
local utils = require 'utils'
local posix = require 'posix'
local llthreads = require "llthreads"
local zlib = require 'zlib'
local CompressStream = zlib.deflate()
local zmq = require"zmq"


local file_log_driver = require "logging.file"
local log_dir = '/tmp/'
local logger = file_log_driver(log_dir.."lgserver_access_%s.log", "%Y-%m-%d")


-- add callback to receive SIGTERM  kill or kill -15
require 'signal'
signal.signal("SIGTERM", function (...)
	print('lgserver receive SIGTERM, os.exit')
	os.exit()
end)

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
      return nil, nil
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

function regularPath(host, path, handle_t)
	local orig_path = path
	if handle_t and handle_t.removeprefix then
		local start, stop = path:find(handle_t.removeprefix)
		if start == 1 then
			path = path:sub(stop+1)
		end
	end
	if handle_t and handle_t.addprefix then
		path = handle_t.addprefix ..  path
	end

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
		cur.headers['remote_ip'] = remote_ip

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
		
		if cur.headers['lgserver_cmd'] then
			cur.meta.cmd = cur.headers['lgserver_cmd']
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

function feedfile(host, client, req, handle_t)
	local path, err = regularPath(host, req.path, handle_t)
	if not path then
		logger:info(err)
		sendData(client, http_response('Forbidden', 403, 'Forbidden'))
		return false
	elseif path == host.root_dir then 
		path = host.root_dir..'index.html' 
	end

	local file_t = posix.stat(path)
	local last_modified_time = req.headers['if-modified-since']
	local isie = req.meta.isie
	if isie and last_modified_time then
		last_modified_time = changeGMT2Timestamp(last_modified_time)
	else
		last_modified_time = tonumber(last_modified_time)
	end

	if not file_t or file_t.type == 'directory' then

		sendData(client, http_response('Not Found', 404, 'Not Found'))

	elseif last_modified_time and file_t.mtime and last_modified_time >= file_t.mtime then

		sendData(client, http_response('Not Changed', 304, 'Not Changed'))

	else
        local max_age = host['max-age'] or 0
		local filename = path:match('/([^/]+)$')
        if not filename then return end 
		
		local tmpfile_t = posix.stat(tmpdir..filename)
		local file_type = findType(path)
		if not tmpfile_t or not COMPRESS_FILETYPE_DICT[file_type] or tmpfile_t.mtime < file_t.mtime or isie then
			-- read new file
			local file = posix.open(path, posix.O_RDONLY, "664")
			if not file then return nil end
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
					s = sendData(client, content)
					if not s then break end

					table.insert(file_bufs, content)
					-- switch to another coroutine
					-- client:next()
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
			if not file then return nil end
			local res = http_response_header(200, 'OK', {
												 ['content-type'] = file_type,
												 ['content-length'] = tmpfile_t.size,
												 ['last-modified'] = tmpfile_t.mtime,
												 ['content-encoding'] = 'deflate',
												 ['cache-control'] = 'max-age='..max_age
														})
			-- send header
			sendData(client, res)

			local content, s
			while true do
				content = posix.read(file, 8192)	
				-- if no data read, nread is 0, not nil
				if #content > 0 then
					s = sendData(client, content)
					if not s then break end
					
                    -- client:next()
				else
					break
				end
			end
			posix.close(file)

		end
	end
end


local handlerProcessing = function (processor, client, req)
	
	local channel_push = getPushChannel(processor)

	sendPushZmqMsg(channel_push, req)
	
end

local checkStaticFile = function (host, req, handle_t)
  local path, err = regularPath(host, req.path, handle_t)
  
	if not path then
		return nil
	elseif path == host.root_dir then 
		path = host.root_dir..'index.html' 
	end

	return posix.stat(path)
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
  --print('pattern', pattern, handle_t)
	if pattern then
    if pattern == '/' then
      local r = checkStaticFile(host, req, handle_t)
      if r or handle_t.type == 'dir' then
        feedfile(host, client, req, handle_t)
      elseif handle_t.type == 'handler' then
        handlerProcessing(handle_t, client, req)
      end
    else
    
      if handle_t.type == 'dir' then

        feedfile(host, client, req, handle_t)

      elseif handle_t.type == 'handler' then

        handlerProcessing(handle_t, client, req)

      end
    end
	else
    --print('no pattern', req.path)
    -- default find url file in root_dir, act as '/' base
    feedfile(host, client, req, handle_t)
		-- sendData(client, http_response('Not Found', 404, 'Not Found'))
	end
end


local cb_from_zmq_thread = function (client_skt)
	local client = copas.wrap(client_skt)
	
	local status, message = pcall(function()

		local strs = {}
		-- may have more than 1 messages
		while true do
			local s, errmsg, partial = client:receive(8192)
--			print(s and #s, errmsg, partial and #partial)
			table.insert(strs, s or partial)
            		if errmsg == 'closed' then break end
		end
		
		local msg = table.concat(strs)
		local res = cmsgpack.unpack(msg)
		

		local res_data = http_response(res.data, res.code, res.status, res.headers)
		if res.meta then
			-- protocol define: res.conns must be a table
			if res.meta.conns and #res.meta.conns > 0 then
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

	end)

	if not status then
		logger:error('Error while serving request:' .. message)
	end
			
		-- end
--	end
end


-- client_skt: tcp connection to browser
local cb_from_http = function (client_skt)
	-- client is copas wrapped object
	local client = copas.wrap(client_skt)

	local status, message = pcall(function()
--<<
        local req, key, parser
        req = {headers={}, meta={}}
        key = recordConnection(client, req)
        parser = init_parser(req)

        -- while here, for keep-alive
        while true do

            local s, errmsg, partial = client:receive(8192)
            --print('--->', s, errmsg, partial)
            if not s and errmsg == 'closed' then 
                break
            end

            local reqstr = s or partial
            parser:execute(reqstr)

            if req.meta.cmd then
                --print('--->', req.meta.cmd)
                -- 如果是状态查询，则立即返回
                if req.meta.cmd == '__cmd_lgserver_status' then
                    local res_data = http_response('status ok', 700, 'status ok', {})
                    responseData(key, res_data)
                end
            else 
                if req.meta.completed then
                    req.method = parser:method()
                    req.version = parser:version()
                    serviceDispatcher(key)
                end
            end
        end

    	if not req.meta.cmd then
            cleanConnection (key)
            logger:info('connection '..key..' closed.')
        end
-->>
	end)

	if not status then
		logger:error('Error while serving request:' .. message)
	end

end

local zmqport = allconfig.zmq_port or  '12310'
-- ==========================================================
-- another thread
local zmq_thread = require 'zmqthread'
-- create detached child thread.
local thread = llthreads.new(zmq_thread, '127.0.0.1', zmqport, CHANNEL_SUB_LIST[1])
-- start non-joinable detached child thread.
assert(thread:start(true))

local zmq_server = socket.bind('127.0.0.1', zmqport)
copas.addserver(zmq_server, cb_from_zmq_thread)

local main_server = socket.bind(SERVER.bind_addr, SERVER.port)
copas.addserver(main_server, cb_from_http)
print('lgserver bind to '..SERVER.bind_addr..":"..SERVER.port)
logger:info('lgserver bind to '..SERVER.bind_addr..":"..SERVER.port)


os.execute('mkdir -p ' .. tmpdir)
os.execute('mkdir -p ' .. log_dir)
-- while true do
--  	copas.step()
--  	-- processing for other events from your system here
-- end

-- main loop
print('starting server....')
logger:info('starting server....')
copas.loop()

