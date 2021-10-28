local state = {
    ['running'] = true,
    ['modem'] = nil,
    ['channel'] = 0
}

local setRunning = function(running)
    state.running = running
end

local printState = function()
    print("Running: " .. state.running)
    print("Modem: " .. state.modem)
    print("Location: " .. state.x .. ", " .. state.y .. ", " .. state.z .. " - Facing " .. state.direction)
end

local setModem = function(modem)
    state.modem = modem
end

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

local eventLoop = function()
    while state.running do
        print("loop")
        if state.channel == 0 then
            print("Enter the slave channel: ")
            state.channel = read()
            term.clear()
        end
        local input = read()
        sendMessage(state.channel, input)
    end
end

local networkLoop = function()
    while state.running do
        print("receiving")
        local sender, message, protocol = rednet.receive()
        print(sender .. " : " .. message)
    end
end

setModem(findModem())

parallel.waitForAny(eventLoop, networkLoop)
