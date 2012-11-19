static_lgcms = { type="dir" }

static_default = { type="dir" }


handler_lgcms = { type="handler", 
		send_spec='tcp://127.0.0.1:1234',
		recv_spec='tcp://127.0.0.1:1235', 
		recv_ident=''}


server = {
    name="server1",
    bind_addr = "127.0.0.1",
    port=8080,
    access_log="logs/access.log",
    error_log="logs/error.log",
    default_host="lgcms",
    hosts = { 
        {       
			name="lgcms",
			--matching="lgcms",
			root_dir = "/home/xen/workspace/lgcms_tg/",

			-- ['max-age'] = 60,
			routes={
				--		['/'] = static_lgcms,
				['/'] = handler_lgcms,
				['/media/'] = static_lgcms,
				['/favicon.ico'] = static_lgcms
			}
        },


    }
}

