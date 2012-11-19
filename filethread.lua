
return 
[==[
	local host, port = ...
	local lgstring = require 'lgstring'
	local posix = require 'posix'
	local socket = require 'socket'

	local zlib = require 'zlib'
	local CompressStream = zlib.deflate()

	local COMPRESS_FILETYPE_DICT = {
		 ['text/css'] = true,
		 ['application/x-javascript'] = true,
		 ['text/html'] = true,
		 ['text/plain'] = true
	}

	local tmpdir = '/tmp/lgserverzipfiles/'

    -- create connection, make enter file server
    -- here, client is a luasocket client 
	local client = assert(socket.connect(host, port))
	client:settimeout(0.01)

	local mimetypes = require 'mime'

    local HTTP_FORMAT = 'HTTP/1.1 %s %s\r\n%s\r\n\r\n%s'

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

	os.execute('mkdir -p ' .. tmpdir)

	local reqstr
	-- keep this thread to server file
	while true do
		
		while true do
			local s, errmsg, partial = client:receive()
			if s or (errmsg == 'timeout' and partial and #partial > 0) then
				reqstr = s or partial
				break
			elseif errmsg == 'closed' then
				-- reconnect
				client = assert(socket.connect(host, port))
			end
		end
		local key, path, last_modified_time, max_age = unpack(lgstring.split(reqstr:sub(1,-2), ' '))
		if last_modified_time then last_modified_time = tonumber(last_modified_time) end
		if max_age then max_age = tonumber(max_age) end
--		print('~~~in file thread', key, path, last_modified_time, max_age)

		if path then
			local file_t = posix.stat(path)
			--print(file_t)
			local last_modified_time = last_modified_time
			if not file_t or file_t.type == 'directory' then
				client:send(string.format('%s %s', key, 404))
			elseif last_modified_time and file_t.mtime and last_modified_time >= file_t.mtime then
				client:send(string.format('%s %s', key, 304))
			else
				local filename = path:match('/([%w%-_%.]+)$')
				local tmpfile_t = posix.stat(tmpdir..filename)
				-- print('tmpfile_t', tmpfile_t)
				local file_type = findType(path)

				if not tmpfile_t or not COMPRESS_FILETYPE_DICT[file_type] or tmpfile_t.mtime < file_t.mtime  then
					-- read new file
					local file = posix.open(path, posix.O_RDONLY, "664")
					--print('ready to read file...', path)
					local size = 0
					if file_t then size = file_t.size end
					local res = http_response_header(200, 'OK', {
														 ['content-type'] = file_type,
														 ['content-length'] = size,
														 ['last-modified'] = file_t.mtime,
														 ['cache-control'] = 'max-age='..(max_age or '0')
																})
					-- send header
					client:send(string.format('%s:%s:%s', key, size+#res, res))
					-- tangg
					local content, s
					local file_bufs = {}
					while true do
						content = posix.read(file, 4096)	
						-- if no data read, nread is 0, not nil
						if #content > 0 then
							client:send(content)
							table.insert(file_bufs, content)
						else
							break
						end
					end
					posix.close(file)
					
					-- write tmp zip file
					if #file_bufs > 0 and filename and COMPRESS_FILETYPE_DICT[file_type] then
						local allcontent = table.concat(file_bufs)
						-- print('--->', #allcontent)
						allcontent = CompressStream(allcontent, 'full')
						-- print('--=>', #allcontent)

						local fd = io.open(tmpdir .. filename, 'w')
						fd:write(allcontent)
						fd:close()
					end
				else
					-- read buffed zip file
					local file = posix.open(tmpdir..filename, posix.O_RDONLY, "664")
					--print('ready to read file...', path)
					local res = http_response_header(200, 'OK', {
														 ['content-type'] = file_type,
														 ['content-length'] = tmpfile_t.size,
														 ['last-modified'] = tmpfile_t.mtime,
														 ['content-encoding'] = 'deflate',
														 ['cache-control'] = 'max-age='..(max_age or '0')
																})
					-- send header
					client:send(string.format('%s:%s:%s', key, tmpfile_t.size+#res, res))
					-- tangg
					local content, s
					local file_bufs = {}
					while true do
						content = posix.read(file, 4096)	
						-- if no data read, nread is 0, not nil
						if #content > 0 then
							client:send(content)
							table.insert(file_bufs, content)
						else
							break
						end
					end
					posix.close(file)
					

				end
			end
		end
	end	

]==]

