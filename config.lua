static_lgcms = { type="dir", removeprefix='/media' }

static_default = { type="dir" }


handler_lgcms = { type="handler", 
		send_spec='tcp://127.0.0.1:1234',
		recv_spec='tcp://127.0.0.1:1235', 
		recv_ident=''}


server = {
    name="server1",
    bind_addr = "0.0.0.0",
    port=8080,
    access_log="logs/access.log",
    error_log="logs/error.log",
    default_host="lgcms",
    hosts = { 
        {       
			name="lgcms",
			--matching="lgcms",
			--root_dir = "/home/xen/workspace/lgcms/",
			root_dir = "/home/xen/workspace/lgcms2/media/",

			--['max-age'] = 600,
			routes={
				['/'] = handler_lgcms,
				['/media/'] = static_lgcms,
			}
        },


    }
}

