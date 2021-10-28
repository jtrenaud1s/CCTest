local state = {}

local findModem = function()
    for i, side in ipairs(rs.getSides()) do
        if peripheral.getType(side) == 'modem' then
            print('Found Modem On Side ' .. side .. "!")
            rednet.open(side)
            state.modem = peripheral.wrap(side)
            break
        end
    end
end

local sendMessage = function(destination, message, protocol)
    if destination and message then
        rednet.send(destination, message, protocol)
    end
end

sendMessage(49, 'hey')