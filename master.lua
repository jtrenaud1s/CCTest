local state = {}

local findModem = function()
    for i, side in ipairs(rs.getSides()) do
        if peripheral.getType(side) == 'modem' then
            print('Found Modem On Side ' .. side .. "!")
            rednet.open(side)
            return peripheral.wrap(side)
        end
    end
end

local sendMessage = function(destination, message, protocol)
    if destination and message then
        rednet.send(destination, message, protocol)
    end
end

state.modem = findModem()
sendMessage(46, 'hey')
