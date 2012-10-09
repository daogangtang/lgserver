local luv = require 'luv'

local t = luv.fs.stat("/tmp")
for k,v in pairs(t) do
   print(k, "=>", v)
end

