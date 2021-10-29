print("Starting")
os.loadAPI('lama')
print("API Loaded")
-- For Testing, set initial location to 0, 0, 0, south relative position.
-- This could be an input prompt
lama.set(0, 0, 0, lama.side.south)
print("Location Zeroed")
-----------STATE-------------
local state = {
    ['running'] = true,
    ['modem'] = nil,
    ['status'] = 'idle'
}

print("State Initialized")

local setRunning = function(running)
    state.running = running
end

local setStatus = function(status)
    state.status = status
end

local printState = function()
    print("Running: ", state.running)
    print("Modem: ", state.modem)
    print("Status: ", state.status)
    print("Location: ", lama.getX(), ", ", lama.getY(), ", ", lama.getZ(), " - Facing ", lama.facing())
end

local setModem = function(modem)
    state.modem = modem
end

local split = function(inputstr, sep)
    if sep == nil then
        sep = "%s"
    end
    local t = {}
    for str in string.gmatch(inputstr, "([^" .. sep .. "]+)") do
        table.insert(t, str)
    end
    return t
end

local findModem = function()
    for i, side in ipairs(rs.getSides()) do
        if peripheral.getType(side) == 'modem' then
            print('Found Modem On Side ', side, "!")
            rednet.open(side)
            return peripheral.wrap(side)
        end
    end
end

local mine = function(x, y, z)
    print("Mine function started")
    print("Moving to ", x, ", ", "y", ", ", z)
    lama.moveTo(x, y, z, lama.facing)
    print("Arrived at mining destination")
    print("Inspecting block below")
    local result = turtle.inspectDown()

    if type(result) ~= "table" then
        print(result)
    else
        for i, v in pairs(result) do
            print(i, v)
        end
    end

    -- goDown()
    -- goBack(x, y, z)

end

local handlePacket = function(sender, command, args)
    if command == "mine" then
        mine(tonumber(args[1]), tonumber(args[2]), tonumber(args[3]))
    end
end

local eventLoop = function()
    print("Event Loop Started")
    while state.running do
        local sender, message, protocol = rednet.receive()
        local tokens = split(message)
        local command = table.remove(tokens, 1)
        handlePacket(sender, command, tokens)
    end
end

print("Finding Modem")
setModem(findModem())
printState()
print("Starting Event Loop")
parallel.waitForAny(eventLoop)
