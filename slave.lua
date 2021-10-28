local state = {
    ['running'] = true,
    ['modem'] = nil,
    ['location'] = {
        ['x'] = nil,
        ['y'] = nil,
        ['z'] = nil,
        ['direction'] = nil
    }
}

local setRunning = function(running)
    state.running = running
end

local setLocation = function(x, y, z, direction)
    state.location.x = x
    state.location.y = y
    state.location.z = z
    state.location.direction = direction
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

local eventLoop = function()
    while state.running do
        local sender, message, protocol = rednet.receive()
        print(sender .. " : " .. message)
        printState()
    end
end

setModem(findModem())
parallel.waitForAll(eventLoop)
