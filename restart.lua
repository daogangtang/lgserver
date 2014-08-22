#!/usr/bin/env lua
require 'lglib'

local killthem = function ()
        local fd = io.popen('ps aux|grep "luajit main.lua"', 'r')
        local output = fd:read("*a")
        fd:close()
        -- print(output)

        local cmd_output = output:split('\n')
        local pattern = "(%d+).+luajit main.lua"
        local pid
        for _, part in ipairs(cmd_output) do
                pid = part:match(pattern)
                print('===>>>>', pid)
                if pid then
                        os.execute(('sudo kill -15 %s'):format(pid))
                end
        end

    end

killthem()

os.execute('sudo luajit main.lua')
print('OK')
