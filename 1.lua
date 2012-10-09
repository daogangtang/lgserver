local luv = require 'luv'

local t = luv.fs.stat("11.jpg")
print(t)
for k,v in pairs(t) do
   print(k, "=>", v)
end

