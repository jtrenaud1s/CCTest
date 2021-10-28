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

local eventLoop = function()
    local sender, message, protocol = rednet.receive()
    print(message)
    return message
end

eventLoop()
