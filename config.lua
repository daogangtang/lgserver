static_mmshuxia = { type="dir", base='sites/mmsx/', index_file='index.html', default_ctype='text/html' }

static_default = { type="dir", base='media/', index_file='index.html', default_ctype='text/html' }


handler_mmshuxia = { type="handler", 
		sender_id="mmshuxia",
		send_spec='tcp://127.0.0.1:1234',
                send_ident='mmshuxia',
                recv_spec='tcp://127.0.0.1:1235', 
		recv_ident=''}


server1 = {
    name="server1",
    root_dir = "/home/xen/workspace/lgserver/tmp/",
    bind_addr = "0.0.0.0",
    port=80,
    access_log="logs/access.log",
    error_log="logs/error.log",
    default_host="mmshuxia.com",
    hosts = { 
        {       name="mmshuxia.com",
		matching="mmshuxia.com",
		['max-age'] = 60,
                routes={
			['/'] = static_mmshuxia,
	--		['/'] = handler_mmshuxia,
	--		['/media/'] = static_mmshuxia,
                }
        },


    }
}

servers = {server1}
