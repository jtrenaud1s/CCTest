--[[
    LAMA - Location Aware Movement API - 2013 Sangar

    This program is licensed under the MIT license.
    http://opensource.org/licenses/mit-license.php

    The API will keep track of the turtle's position and facing, even across
    multiple games: the state is persistent. In particular it is very robust,
    i.e. even if the turtle is currently moving when it is forced to shut down
    because its chunk is unloaded, the coordinates will always be correct after
    it resumes. In theory, anyways. It's the only actually working approach I'm
    aware of, using the turtle's fuel level to check if it moved in such cases.

    The API is relatively basic, in that it is purely focused on movement. It's
    essentially a rich drop-in replacement for the the original navigational
    functions in the turtle API:
        turtle.forward   -> lama.forward
        turtle.back      -> lama.back
        turtle.up        -> lama.up
        turtle.down      -> lama.down
        turtle.turnRight -> lama.turnRight
        turtle.turnLeft  -> lama.turnLeft

    When using this API, you must not use any other functions that alter
    the turtle's position or facing. In particular:

        DO NOT USE turtle.forward, turtle.back, turtle.up, turtle.down,
        turtle.turnRight or turtle.turnLeft NOR THEIR NATIVE EQUIVALENTS.

    Any other external force changing the turtle's position will also
    invalidate the coordinates, of course (such as the player pickaxing the
    turtle and placing it somewhere else or RP2 frames).

    The utility function lama.hijackTurtleAPI() can be used to override the
    original turtle API functions, to make it easier to integrate this API into
    existing programs.
    When starting a new program it is recommended using the functions directly
    though, to make full use of their capabilities (in particular automatically
    clearing the way). See the function's documentation for more information.
]] -------------------------------------------------------------------------------
-- Config                                                                    --
-------------------------------------------------------------------------------
-- The absolute path to this file. This is used for generating startup logic
-- which initializes the API by loading it into the OS.
local apiPath = "apis/lama"

-- This is the name of the file in which we store our state, i.e. the position
-- and facing of the turtle, as well as whether it is currently moving or not.
-- We split this up into several files to keep file i/o while moving minimal.
-- You may want to change this if it collides with another program or API.
local stateFile = {
    position = "/.lama-state",
    waypoints = "/.lama-waypoints",
    fuel = "/.lama-fuel",
    move = "/.lama-move-state",
    path = "/.lama-path-state",
    wrap = "/.lama-wrap-state"
}

-- The file used to mark the API state as invalid. If this file exists we will
-- not allow any interaction besides lama.set(), but always throw an error
-- instead. This is to ensure that turtles don't do weird things after the
-- position cannot be guaranteed to be correct anymore (e.g. due to hard server
-- crashes resulting in a rollback).
local invalidStateFile = "/.lama-invalid"

-- If this computer uses a multi-startup script (e.g. Forairan's or mine) this
-- determins the 'priority' with which the API is initialized after a reboot.
-- This should be an integer value in the interval [0, 99], where lower values
-- represent a higher priority.
local startupPriority = 10

-- The filename of the file to backup any original startup file to when
-- creating the startup file used to finish any running moves in case the
-- turtle is forced to shut down during the move. This is only used if no
-- multi-startup-script system is found on the computer.
-- You may want to change this if it collides with another program or API.
local startupBackupFile = "/.lama-startup-backup"

-- Whether to use the same coordinate system Minecraft uses internally. This
-- only influences how the API works from the outside; the state file will
-- always use the internal coordinate system, to provide compatibility.
local useMinecraftCoordinates = true

-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
-- API variables and methods follow; do not change them.                     --
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------

-- If this API was loaded before, reuse it to avoid unnecessarily reloading the
-- state and whatnot. In particular if some coroutine gets funny ideas like
-- reloading it while we're performing a move...
if lama then
    local env = getfenv()
    for k, v in pairs(lama) do
        env[k] = v
    end
    return
end

-- Internal forward declarations. They have to be declared here so that
-- functions can access them.
local state, private

-------------------------------------------------------------------------------
-- Constants                                                                 --
-------------------------------------------------------------------------------

-- The current version of the API.
version = "1.4c"

-- Constants for a turtle's facing, used for turn() and get()/set(). Note that
-- these are adjusted in the initialization of the API if the setting
-- useMinecraftCoordinates is set to true.
side = {
    forward = 0,
    right = 1,
    back = 2,
    left = 3,
    north = 0,
    east = 1,
    south = 2,
    west = 3,
    front = 0,
    ["0"] = 0,
    ["1"] = 1,
    ["2"] = 2,
    ["3"] = 3,
    -- Reverse mapping for name lookup based on the used coordinate system.
    [0] = "north",
    [1] = "east",
    [2] = "south",
    [3] = "west"
}

-- Reasons for movement failure. One of these is returned as a second value by
-- the movement functions (forward, back, up, down) if they fail.
reason = {
    -- We could not determine what was blocking us. Mostly used when moving
    -- backwards, since we cannot detect anything in that direction.
    unknown = "unknown",

    -- The VM's event queue is full, meaning no further commands can be issued
    -- until some of them are processed first.
    queue_full = "queue_full",

    -- Another corouting is still waiting for a move to finish.
    coroutine = "coroutine",

    -- The fuel's empty so we cannot move at all.
    fuel = "fuel",

    -- Some block is in the way. If we had multiple tries, this means the block
    -- respawned/regenerated, so we either have a stack of sand/gravel that is
    -- higher than the number of tries was, or a cobblestone generator or
    -- something similar.
    block = "block",

    -- Another turtle got in our way. If we had multiple tries, this means the
    -- turtle did not move out of the way, so it's either not moving or wants
    -- to move to where this turtle is (direct opposite move direction).
    turtle = "turtle",

    -- Some unbreakable block is in the way. This can only be determined when
    -- we have multiple tries, in which case this is returned if the dig()
    -- command returns false.
    unbreakable_block = "unbreakable_block",

    -- Some entity is in our way. This is the case when we're blocked but no
    -- block is detected in the desired direction.
    entity = "entity",

    -- Some invulnerable entity is our way. This can only be determined when we
    -- have multiple tries and we're aggressive, in which case this is returned
    -- if the attack() command fails.
    invulnerable_entity = "invulnerable_entity"
}

-----------------------------
-- State related functions --
-----------------------------

--[[
Note: all coordinates are initially relative to the turtle's origin,
      i.e. to where it has been placed and this API was first used.
      If the turtle is moved in some way other than via the functions
      of this API (pickaxed by player and placed somewhere else, RP2
      frames, ...) the coordinates will refer to somewhere else in
      world space, since the origin has changed!
]]

--[[
    Get the position and facing of the turtle.

    @return a tuple (x, y, z, facing).
]]
function get()
    private.resume()
    local position = state.position
    return private.toMC(position.x, position.y, position.z, position.f)
end

--[[
    Get the current X coordinate of the turtle.

    @return the turtle's current X position.
]]
function getX()
    local x, _, _, _ = get()
    return x
end

--[[
    Get the current Y coordinate of the turtle.

    @return the turtle's current Y position.
]]
function getY()
    local _, y, _, _ = get()
    return y
end

--[[
    Get the current Z coordinate of the turtle.

    @return the turtle's current Z position.
]]
function getZ()
    local _, _, z, _ = get()
    return z
end

--[[
    Get the current X,Y,Z coordinates of the turtle as a vector.

    @return a vector instance representing the turtle's position.
]]
function getPosition()
    return vector.new(get())
end

--[[
    Get the direction the turtle is currently facing.

    @return the current orientation of the turtle.
    @see lama.side
]]
function getFacing()
    local _, _, _, f = get()
    return f
end

--[[
    Sets the position and facing of the turtle.

    This can be useful to calibrate the turtle to a new origin, e.g. after
    placing it, to match the actual world coordinates. The facing must be one
    of the lama.side constants.

    @param x the X coordinate to set the position to.
    @param y the Y coordinate to set the position to.
    @param z the Z coordinate to set the position to.
    @param facing the facing to set.
    @return the new position and facing of the turtle (like lama.get()).
]]
function set(x, y, z, facing)
    -- Type checks.
    assert(private.isInteger(x), "'x' must be an integral number")
    assert(private.isInteger(y), "'y' must be an integral number")
    assert(private.isInteger(z), "'z' must be an integral number")
    assert(private.isFacing(facing), "'facing' must be one of the lama.side constants")

    -- Thread safety.
    private.resume(true)
    if private.isLocked() then
        error("Cannot set position while moving or refueling.")
    end

    -- Reset the complete state before applying our new position.
    private.reset()

    -- Convert coordinates.
    x, y, z, facing = private.fromMC(x, y, z, facing)

    local position = state.position
    position.x = x
    position.y = y
    position.z = z
    position.f = facing
    private.save("position")
    return get()
end

--------------------------------
-- Movement related functions --
--------------------------------

--[[
    Try to move the turtle forward.

    @param tries how often to try to move. If this larger than zero, the turtle
        will try to dig its way through any obstructions as many times (e.g. to
        get through stacks of sand or gravel).
    @param aggressive if set to true, will also try to attack to clear its way
        when obstructed.
    @return true if the turtle moved successfully, (false, reason) if it failed
        and is still in the same position.
]]
function forward(tries, aggressive)
    private.resume()
    if private.isLocked() then
        return false, reason.coroutine
    end
    return private.forward(tries, aggressive)
end

--[[
    Try to move the turtle backward.

    Note that this does not have the 'tries' and 'aggressive' parameters, since
    the turtle would have to turn around first in order to dig or attack.

    @param tries how often to try to move. If this larger than zero, the turtle
        will try to wait for any obstructions it hits to go away as many times.
        As opposed to the other movement functions this will not dig nor attack
        and only wait for other turtle to pass. In the other cases it will
        immediately return false.
    @return true if the turtle moved successfully, (false, reason) if it failed
        and is still in the same position.
]]
function back(tries)
    private.resume()
    if private.isLocked() then
        return false, reason.coroutine
    end
    return private.back(tries)
end

--[[
    Try to move the turtle up.

    @param tries how often to try to move. If this larger than zero, the turtle
        will try to dig its way through any obstructions as many times (e.g. to
        get through stacks of sand or gravel).
    @param aggressive if set to true, will also try to attack to clear its way
        when obstructed.
    @return true if the turtle moved successfully, (false, reason) if it failed
        and is still in the same position.
]]
function up(tries, aggressive)
    private.resume()
    if private.isLocked() then
        return false, reason.coroutine
    end
    return private.up(tries, aggressive)
end

--[[
    Try to move the turtle down.

    @param tries how often to try to move. If this larger than zero, the turtle
        will try to dig its way through any obstructions as many times (e.g. to
        get through stacks of sand or gravel).
    @param aggressive if set to true, will also try to attack to clear its way
        when obstructed.
    @return true if the turtle moved successfully, (false, reason) if it failed
        and is still in the same position.
]]
function down(tries, aggressive)
    private.resume()
    if private.isLocked() then
        return false, reason.coroutine
    end
    return private.down(tries, aggressive)
end

--[[
    Moves the turtle to the specified location and turns it to face in the
    specified direction if any.

    If the turtle is shut down while moving to the specified target coordinates
    it will continue moving after booting up again. After it finished moving,
    either because it reached its target or because it encountered a problem,
    the remaining startup scripts will be executed and the result of the move
    command can be queried via lama.startupResult().

    This is actually just a shortcut for
        lama.navigate({x, y, z, facing}, tries, aggressive)

    @param x the target X position.
    @param x the target Y position.
    @param x the target Z position.
    @param facing the final facing, after reaching the target position. This
        parameter is options; if omitted the turtle will remain in the
        orientation it arrived in.
    @param tries how often to try to move for each single move. If this larger
        than zero, the turtle will try to dig its way through any obstructions
        as many times (e.g. to get through stacks of sand or gravel).
    @param aggressive if set to true, will also try to attack to clear its way
        when obstructed.
    @param longestFirst whether to move along the longer axes first. This an be
        used to control how the turtle moves along its path. For example, when
        moving from (0, 0, 0) to (1, 0, 3), when this is true the turtle will
        move along the Z-axis first, then along the X-axis, if it is false the
        other way around.
    @return true if the turtle moved successfully, (false, reason) if it failed
        and stopped somewhere along the way.
]]
function moveto(x, y, z, facing, tries, aggressive, longestFirst)
    return navigate({{
        x = x,
        y = y,
        z = z,
        facing = facing
    }}, tries, aggressive, longestFirst)
end

-- Alias for moveto, usable as long as it's not a keyword, so why not.
getfenv()["goto"] = moveto

--[[
    Moves the turtle along the specified path.

    Each path entry can either be a waypoint or a set of coordinates. Note that
    waypoints are resolved once in the beginning, so if a waypoint is changed
    asynchronously (e.g. coroutine or interrupted due to forced shut down) that
    change will not influence how the turtle will move.

    If the turtle is shut down while moving along the specified path it will
    continue moving after booting up again. After it finished moving, either
    because it reached its final target or because it encountered a problem,
    the remaining startup scripts will be executed and the result of the move
    command can be queried via lama.startupResult().

    Note that all facings for intermediate steps will be ignored, only the
    facing in the final waypoint will be applied after the turtle arrived.

    @param path the list of coordinates or waypoints to move along. Note that
        only array entries are considered (i.e. with a numerical key) because
        record entries (arbitrary key) have no guaranteed order.
    @param tries how often to try to move for each single move. If this larger
        than zero, the turtle will try to dig its way through any obstructions
        as many times (e.g. to get through stacks of sand or gravel).
    @param aggressive if set to true, will also try to attack to clear its way
        when obstructed.
    @param longestFirst whether to move along the longer axes first. This an be
        used to control how the turtle moves along its path. For example, when
        moving from (0, 0, 0) to (1, 0, 3), when this is true the turtle will
        move along the Z-axis first, then along the X-axis, if it is false the
        other way around.
    @return true if the turtle moved successfully, (false, reason) if it failed
        and stopped somewhere along the way.
    @throw if the path contains an unknown waypoint or an invalid entry.
]]
function navigate(path, tries, aggressive, longestFirst)
    -- Type checks.
    assert(type(path) == "table", "'path' must be a table")
    assert(tries == nil or private.isInteger(tries), "'tries' must be an integral number or omitted")
    assert(aggressive == nil or type(aggressive) == "boolean", "'aggressive' must be a boolean or omitted")
    assert(longestFirst == nil or type(longestFirst) == "boolean", "'longestFirst' must be a boolean or omitted")

    -- Thread safety.
    private.resume()
    if private.isLocked() then
        return false, reason.coroutine
    end

    -- Resolve path to be all absolute and validate coordinates.
    local absPath = {}
    for k, v in ipairs(path) do
        if type(v) == "string" then
            -- It's a waypoint. Add the coordinate to the list.
            local x, y, z, f = private.fromMC(waypoint.get(v))
            table.insert(absPath, {
                x = x,
                y = y,
                z = z,
                f = f
            })
        elseif type(v) == "table" then
            -- It's a coordinate. Do some type checking.
            local x, y, z, f = v.x, v.y, v.z, v.facing
            assert(private.isInteger(x), "'x' at index " .. k .. " must be an integral number")
            assert(private.isInteger(y), "'y' at index " .. k .. " must be an integral number")
            assert(private.isInteger(z), "'z' at index " .. k .. " must be an integral number")
            assert(f == nil or private.isFacing(f),
                "'facing' at index " .. k .. " must be one of the lama.side constants or omitted")

            -- Convert coordinates.
            x, y, z, f = private.fromMC(x, y, z, f)

            -- Add the coordinate to the list.
            table.insert(absPath, {
                x = x,
                y = y,
                z = z,
                f = f
            })
        else
            error("Invalid path entry at index " .. k)
        end
    end

    -- If we have no steps at all we can stop right here.
    if #absPath == 0 then
        return true
    end

    -- Strip facings for all except the last entry (because those don't matter
    -- and will only slow us down).
    for i = 1, #absPath - 1 do
        absPath[i].f = nil
    end

    -- Set our new target and start moving.
    state.path = {
        steps = absPath,
        tries = tries or 0,
        aggressive = aggressive or nil,
        longestFirst = longestFirst or nil
    }
    private.save("path")
    return private.navigate()
end

-----------------------------------
-- Orientation related functions --
-----------------------------------

--[[
    Turn the turtle right.

    @return true if the turtle turned successfully, false otherwise.
]]
function turnRight()
    return turn((getFacing() + 1) % 4)
end

--[[
    Turn the turtle left.

    @return true if the turtle turned successfully, false otherwise.
]]
function turnLeft()
    return turn((getFacing() - 1) % 4)
end

--[[
    Turn the turtle around.

    @return true if the turtle turned successfully, (false, reason) if it
        failed - in this case the turtle may also have turned around halfway.
        Only fails if the event queue is full.
]]
function turnAround()
    return turn((getFacing() + 2) % 4)
end

--[[
    Turn the turtle to face the specified direction.

    @param towards the direction in which the turtle should face.
    @return true if the turtle turned successfully, (false, reason) if it
        failed - in this case the turtle may already have turned partially
        towards the specified facing. Only fails if the event queue is full.
    @see lama.side
]]
function turn(towards)
    -- Type check, ensuring it's in bounds.
    assert(private.isFacing(towards), "'towards' must be one of the lama.side constants")

    -- Thread safety.
    private.resume()
    if private.isLocked() then
        return false, reason.coroutine
    end

    return private.turn(towards)
end

---------------
-- Refueling --
---------------

--[[
    Uses the items in the currently select slot to refuel the turtle.

    @param count the number of items to consume; complete stack if omitted.
    @return true if the item was successfully consumed; false otherwise.
]]
function refuel(count)
    -- Type check.
    assert(count == nil or (private.isInteger(count) and count >= 0 and count <= 64),
        "'count' must be a positive integral number in [0, 64] or omitted")

    -- Thread safety.
    private.resume()
    if private.isLocked() then
        return false, reason.coroutine
    end

    -- Issue the command, remember we're currently refueling and wait.
    local id
    -- We have to split it like this because otherwise count being nil is still
    -- counted as an argument, leading to an "Expected a number" error.
    if count then
        id = turtle.native.refuel(count)
    else
        id = turtle.native.refuel()
    end
    if id == -1 then
        return false, reason.queue_full
    end
    state.fuel.id = id
    private.save("fuel")
    local result = private.waitForResponse(id)
    state.fuel.id = nil
    state.fuel.current = turtle.getFuelLevel()
    private.save("fuel")
    return result
end

---------------
-- Waypoints --
---------------

-- Namespace for waypoint related functions.
waypoint = {}

--[[
    Adds a new waypoint to the list of known waypoints.

    Note that the coordiantes are optional. If they are not specified,
    the current coordiantes will be used. If all three coordinates are omitted
    the facing of the waypoint will be set to the current facing; otherwise the
    waypoint's facing will be unspecified.

    @param name the name of the waypoint.
    @param x the X coordinate of the waypoint.
    @param y the Y coordinate of the waypoint.
    @param z the Z coordinate of the waypoint.
    @param facing the optional facing of the waypoint.
    @return true if a waypoint of that name already existed and was
        overwritten; false otherwise.
]]
function waypoint.add(name, x, y, z, facing)
    private.resume()

    -- Type checking.
    assert(type(name) == "string" and name ~= "", "'name' must be a non-empty string")
    assert(x == nil or private.isInteger(x), "'x' must be an integral number or omitted")
    assert(y == nil or private.isInteger(y), "'y' must be an integral number or omitted")
    assert(z == nil or private.isInteger(z), "'z' must be an integral number or omitted")
    assert(facing == nil or private.isFacing(facing), "'facing' must be one of the lama.side constants or omitted")

    -- Convert coordinates.
    x, y, z, facing = private.fromMC(x, y, z, facing)

    -- Default to current position; also take facing if we use the exact
    -- coordinates, i.e. we wouldn't have to move to reach the waypoint.
    local position = state.position
    if x == nil and y == nil and z == nil and facing == nil then
        facing = position.f
    end
    x = x or position.x
    y = y or position.y
    z = z or position.z

    local wasOverwritten = waypoint.exists(name)
    state.waypoints[name] = {
        x = math.floor(x),
        y = math.floor(y),
        z = math.floor(z),
        f = facing
    }
    private.save("waypoints")
    return wasOverwritten
end

--[[
    Removes a waypoint from the list of known waypoints.

    @param name the name of the waypoint to remove.
    @return true if the waypoint was removed; false if there was no such
        waypoint.
]]
function waypoint.remove(name)
    private.resume()
    if not waypoint.exists(name) then
        return false
    end
    state.waypoints[name] = nil
    private.save("waypoints")
    return true
end

--[[
    Checks if a waypoint with the specified name exists.

    @param name the name of the waypoint to test for.
    @return true if a waypoint of that name exists; false otherwise.
]]
function waypoint.exists(name)
    private.resume()
    assert(type(name) == "string" and name ~= "", "'name' must be a non-empty string")
    return state.waypoints[name] ~= nil
end

--[[
    Get the coordinates of the waypoint with the specified name.

    @param the name of the waypoint to get.
    @return (x, y, z, facing) or nil if there is no such waypoint.
    @throw if there is no waypoint with the specified name.
]]
function waypoint.get(name)
    private.resume()
    assert(waypoint.exists(name), "no such waypoint, '" .. tostring(name) .. "'")
    local w = state.waypoints[name]
    return private.toMC(w.x, w.y, w.z, w.f)
end

--[[
    Returns an iterator function to be used in a for loop.

    Usage: for name, x, y, z, facing in lama.waypoint.iter() do ... end
    Note that the facing may be nil.

    @return an iterator over all known waypoints.
]]
function waypoint.iter()
    private.resume()
    local name
    return function()
        local coordinate
        name, coordinate = next(state.waypoints, name)
        if name then
            return name, private.toMC(coordinate.x, coordinate.y, coordinate.z, coordinate.f)
        end
    end
end

--[[
    Moves the turtle to the specified waypoint.

    If the turtle is shut down while moving to the specified target coordinates
    it will continue moving after booting up again. After it finished moving,
    either because it reached its target or because it encountered a problem,
    the remaining startup scripts will be executed and the result of the move
    command can be queried via lama.startupResult().

    This just calls lama.moveto() with the waypoint's coordinates, which in
    turn is an alias for lama.navigate() for single length paths.

    @param name the name of the waypoint to move to.
    @param tries how often to try to move for each single move. If this larger
        than zero, the turtle will try to dig its way through any obstructions
        as many times (e.g. to get through stacks of sand or gravel).
    @param aggressive if set to true, will also try to attack to clear its way
        when obstructed.
    @param longestFirst whether to move along the longer axes first. This an be
        used to control how the turtle moves along its path. For example, when
        moving from (0, 0, 0) to (1, 0, 3), when this is true the turtle will
        move along the Z-axis first, then along the X-axis, if it is false the
        other way around.
    @return true if the turtle moved successfully, (false, reason) if it failed
        and stopped somewhere along the way.
    @throw if there is no waypoint with the specified name.
]]
function waypoint.moveto(name, tries, aggressive, longestFirst)
    x, y, z, facing = waypoint.get(name)
    return moveto(x, y, z, facing, tries, aggressive, longestFirst)
end

-- Alias for waypoint.moveto, usable as long as it's not a keyword, so why not.
waypoint["goto"] = waypoint.moveto

-----------------------
-- Utility functions --
-----------------------

--[[
    This function can be called to fully initialize the API.

    This entrails loading any previous state and resuming any incomplete
    movement orders (including paths, so it can take a while for this function
    to return the first time it is called).

    This function is idempotent.
]]
function init()
    private.resume()
end

--[[
    Gets the result of resuming a move on startup.

    This can be used to query whether a move that was interrupted and continued
    on startup finished successfully or not, and if not for what reason.

    For example: imagine you issue lama.forward() and the program stops. Your
    program restores its state and knows it last issued the forward command,
    but further execution depends on whether that move was successful or not.
    To check this after resuming across unloading you'd use this function.

    Note that this will return true in case the startup did not continue a move
    (program was not interrupted during a move).

    @return true or a tuple (result, reason) based on the startup move result.
]]
function startupResult()
    private.resume()
    if not private.startupResult then
        return true
    end
    return private.startupResult.result, private.startupResult.reason
end

--[[
    Replaces the movement related functions in the turtle API.

    This makes it easier to integrate this API into existing programs.
    This does NOT touch the native methods.
    The injected functions will NOT be the same as calling the API function
    directly, to avoid changes in existing programs when this is dropped in.

    For example: a call to turtle.forward(1) will return false if the turtle is
    blocked, whereas lama.forward(1) would try to destroy the block, and then
    move. The function replacing turtle.forward() will behave the same as the
    old one, in that the parameter will be ignored. This follows the principle
    of least astonishment.

    @param restore whether to restore the original turtle API functions.
]]
function hijackTurtleAPI(restore)
    -- Wrap methods to avoid accidentally passing parameters along. This is
    -- done to make sure behavior is the same even if the functions are
    -- called with (unused/invalid) parameters.
    if restore then
        if not turtle._lama then
            return
        end
        turtle.forward = turtle._lama.forward
        turtle.back = turtle._lama.back
        turtle.up = turtle._lama.up
        turtle.down = turtle._lama.down
        turtle.turnRight = turtle._lama.turnRight
        turtle.turnLeft = turtle._lama.turnLeft
        turtle.refuel = turtle._lama.refuel
        turtle._lama = nil
    else
        if turtle._lama then
            return
        end
        turtle._lama = {
            forward = turtle.forward,
            back = turtle.back,
            up = turtle.up,
            down = turtle.down,
            turnRight = turtle.turnRight,
            turnLeft = turtle.turnLeft,
            refuel = turtle.refuel
        }
        turtle.forward = function()
            return forward() ~= false
        end
        turtle.back = function()
            return back() ~= false
        end
        turtle.up = function()
            return up() ~= false
        end
        turtle.down = function()
            return down() ~= false
        end
        turtle.turnRight = function()
            return turnRight() ~= false
        end
        turtle.turnLeft = function()
            return turnLeft() ~= false
        end
        turtle.refuel = function()
            return refuel() ~= false
        end
    end
end

-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
-- Internal methods follow; you cannot call these, so you can probably stop  --
-- reading right here, unless you're interested in implementation details.   --
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------

-- Adjust constants depending on coordinate system.
if useMinecraftCoordinates then
    -- Constants.
    for k, v in pairs(side) do
        if type(v) == "number" then
            side[k] = (v + 2) % 4
        end
    end
    -- Reverse lookup.
    side[0], side[1], side[2], side[3] = side[2], side[3], side[0], side[1]
end

-- Raise error when trying to access invalid key in the constant tables. This
-- is meant to make it easier to track down typos.
do
    local function makeReadonly(table, name)
        setmetatable(table, {
            __index = function(t, k)
                error("Trying to access invalid '" .. name .. "' constant '" .. k .. "'.")
            end,
            __newindex = function()
                error("Trying to modify readonly table.")
                -- Yes, existing entries can be overwritten like this, but I
                -- prefer to keep the table enumerable via pairs(). And this is
                -- just a utility "feature" anyway.
            end
        })
    end
    makeReadonly(side, "lama.side")
    makeReadonly(reason, "lama.reason")
end

-- Namespace for private functions.
private = {}

-- Movement directions, used for move state, as a bidirectional map.
private.direction = {
    [1] = "forward",
    [2] = "back",
    [3] = "up",
    [4] = "down",
    forward = 1,
    back = 2,
    up = 3,
    down = 4
}

-- Initialize state variable with defaults.
state = {
    -- Coordinates and facing.
    position = {
        x = 0,
        y = 0,
        z = 0,
        f = 0
    },

    -- List of registered waypoints.
    waypoints = {},

    -- The last known fuel state. This is used to ensure our coordinates are
    -- still valid (might be broken due to invalid API use or server rollback).
    -- Also stores command ID when currently refueling (to detect rollback).
    fuel = {
        current = turtle.getFuelLevel()
    },

    -- The current movement state, i.e. the direction we're moving in, the fuel
    -- level before the move started, the remaining tries and whether we're
    -- moving aggressively or not.
    move = nil,

    -- The path we're currently moving along when performing a multi-block
    -- movement (via lama.navigate() or lama.moveto()/lama.waypoint.moveto()).
    path = nil,

    -- This is used to keep track of how many times we tried to wrap the
    -- startup file in a nested fashion. We need to store this in the
    -- persistent state in case the API is loaded again (which would reset
    -- normal variables) and it helps us to check whether we need to unwrap
    -- the startup file when resuming after a reboot.
    wrap = 0
}

-- Schemas for the state variable. This defines the expected value types and
-- value presence in the state, which we use to validate a loaded state.
private.schema = {}
private.schema[version] = {
    position = {
        type = "table",
        properties = {
            x = {
                type = "number",
                value = private.isInteger
            },
            y = {
                type = "number",
                value = private.isInteger
            },
            z = {
                type = "number",
                value = private.isInteger
            },
            f = {
                type = "number",
                value = private.isFacing
            }
        }
    },
    waypoints = {
        type = "table",
        entries = {
            type = "table",
            keytype = "string",
            properties = {
                x = {
                    type = "number",
                    value = private.isInteger
                },
                y = {
                    type = "number",
                    value = private.isInteger
                },
                z = {
                    type = "number",
                    value = private.isInteger
                },
                f = {
                    type = "number",
                    value = private.isFacing,
                    optional = true
                }
            }
        }
    },
    fuel = {
        type = "table",
        properties = {
            current = {
                type = "number",
                value = private.isInteger
            },
            id = {
                type = "number",
                value = private.isInteger,
                optional = true
            }
        }
    },
    move = {
        type = "table",
        properties = {
            direction = {
                type = "number",
                value = function(v)
                    return private.direction[v] ~= nil
                end
            },
            tries = {
                type = "number",
                value = private.isInteger
            },
            aggressive = {
                type = "boolean",
                optional = true
            }
        }
    },
    path = {
        type = "table",
        properties = {
            steps = {
                type = "table",
                entries = {
                    type = "table",
                    properties = {
                        x = {
                            type = "number",
                            value = private.isInteger
                        },
                        y = {
                            type = "number",
                            value = private.isInteger
                        },
                        z = {
                            type = "number",
                            value = private.isInteger
                        },
                        f = {
                            type = "number",
                            value = private.isFacing,
                            optional = true
                        }
                    }
                }
            },
            tries = {
                type = "number",
                value = private.isInteger
            },
            aggressive = {
                type = "boolean",
                optional = true
            },
            longestFirst = {
                type = "boolean",
                optional = true
            }
        }
    },
    wrap = {
        type = "number",
        value = private.isInteger
    }
}

-- Schema delta for version 1.2 to 1.3 state files (used for upgrading).
private.schema["1.2"] = {
    move = {
        type = "table",
        optional = true,
        properties = {
            direction = {
                type = "number",
                value = function(v)
                    return private.direction[v] ~= nil
                end
            },
            preMoveFuel = {
                type = "number",
                value = private.isInteger
            },
            tries = {
                type = "number",
                value = private.isInteger
            },
            aggressive = {
                type = "boolean"
            }
        },
        upgrade = function(value)
            state.fuel.current = value.preMoveFuel
            private.save("fuel")
            return {value.direction, value.tries, value.aggressive}
        end
    }
}

-- Schema for version 1.0 state files (used for upgrading).
private.schema["1.0"] = {
    type = "table",
    properties = {
        position = {
            type = "table",
            properties = {
                x = {
                    type = "number",
                    value = private.isInteger
                },
                y = {
                    type = "number",
                    value = private.isInteger
                },
                z = {
                    type = "number",
                    value = private.isInteger
                },
                f = {
                    type = "number",
                    value = private.isFacing
                }
            }
        },
        moving = {
            type = {"boolean", "string"},
            value = function(v)
                if type(v) == "string" then
                    return v == "forward" or v == "back" or v == "up" or v == "down"
                end
                return true
            end
        },
        preMoveFuel = {
            type = "number",
            value = private.isInteger
        },
        tries = {
            type = "number",
            value = private.isInteger
        },
        aggressive = {
            type = "boolean"
        }
    }
}

-------------------------------------------------------------------------------
-- Schema based value validation                                             --
-------------------------------------------------------------------------------

--[[
    Validates a value based on a schema.

    This checks if the value fits the specified schema (i.e. types are correct)
    which is used when loading states, to avoid loading a corrupted state.

    @param value the value to validate.
    @param schema the schema to use to validate the value.
    @return true if the value fits the schema; (false, reason) otherwise.
    @private
]]
function private.validate(value, schema)
    assert(schema ~= nil, "no schema given")
    local function validate(value, schema, path)
        -- Is the value optional? We do this first because we still want to
        -- return false if the type mismatches if the value is optional but not
        -- nil.
        if schema.optional and value == nil then
            return true
        end

        -- Is the value type correct?
        if type(schema.type) == "table" then
            -- Value may have multiple types, check if any one fits.
            local ok = false
            for _, valueType in pairs(schema.type) do
                if type(value) == valueType then
                    ok = true
                    break
                end
            end
            if not ok then
                return false, path .. ": invalid type; is " .. type(value) .. ", should be one of [" ..
                    table.concat(schema.type, ", ") .. "]"
            end
        elseif schema.type and type(value) ~= schema.type then
            return false, path .. ": invalid type; is " .. type(value) .. ", should be " .. schema.type
        end

        -- See if we have a custom validator function.
        if schema.value and not schema.value(value) then
            return false, path .. ": invalid value"
        end

        -- Recursively check properties of the value.
        if schema.properties then
            for property, propertySchema in pairs(schema.properties) do
                local result, location = validate(value[property], propertySchema, path .. "." .. property)
                if not result then
                    return result, location
                end
            end
        end

        -- Recursively check entries of a table.
        if schema.entries then
            for key, entry in pairs(value) do
                if schema.entries.keytype and type(key) ~= schema.entries.keytype then
                    return false, path .. "[" .. key .. "]: invalid key type; is " .. type(key) .. ", should be " ..
                        schema.entries.keytype
                end
                local result, location = validate(entry, schema.entries, path .. "[" .. key .. "]")
                if not result then
                    return result, location
                end
            end
        end

        -- No issues.
        return true
    end
    return validate(value, schema, "value")
end

--[[
    Checks if the specified number is integral.

    @param value the number to check.
    @return true if the number is integral; false otherwise.
    @private
]]
function private.isInteger(value)
    return type(value) == "number" and value == math.floor(value)
end

--[[
    Checks if the specified number is a valid facing.

    @param value the number to check.
    @return true if the number is a valid facing; false otherwise.
    @private
]]
function private.isFacing(value)
    return type(value) == "number" and private.isInteger(value) and value >= 0 and value < 4
end

-------------------------------------------------------------------------------
-- State saving/loading                                                      --
-------------------------------------------------------------------------------

--[[
    Saves the specified state section to its corresponding file.

    @param the name of the section to save.
    @private
]]
function private.save(what)
    -- Serialize before opening the file, just in case.
    local data = textutils.serialize(state[what])
    local file = fs.open(stateFile[what], "w")
    if not file then
        private.invalidate()
        error("Could not opens state file '" .. what .. "' for writing.")
    end
    file.write(data)
    file.close()
end

--[[
    Restores the complete state.

    @return true if the state was restored successfully; false otherwise.
    @private
]]
function private.load()
    -- Check if we may have upgraded and the state file is of an old version.
    if private.upgrade() then
        return true
    end

    -- Utility function for loading single sections.
    local function load(section)
        local filename = stateFile[section]
        if not fs.exists(filename) then
            return true
        end
        assert(not fs.isDir(filename), "Invalid state filename '" .. filename .. "': it's a folder.")

        local success, result = private.unserialize(filename)
        if success then
            -- Validate the read state.
            local valid, failureReason = private.validate(result, private.schema[version][section])
            if valid then
                -- All green, keep the new state.
                state[section] = result
                return true
            elseif private.schema["1.2"][section] and private.validate(result, private.schema["1.2"][section]) then
                -- We can upgrade this section. Let's.
                state[section] = private.schema["1.2"][section].upgrade(result)
                return true
            else
                print("LAMA: Invalid state file '" .. filename .. "' (" .. failureReason .. ").")
            end
        end
        return false
    end

    -- Read all state sections one by one.
    for section, _ in pairs(stateFile) do
        if not load(section) then
            return false
        end
    end

    -- Everything is fine.
    return true
end

--[[
    Utility function for unserializing data from a file.

    @param filename the name of the file to deserialize the data from.
    @return (true, result) if the file exists, false otherwise.
    @private
]]
function private.unserialize(filename)
    -- Read the text data from the file.
    local file = assert(fs.open(filename, "r"))
    local data = file.readAll()
    file.close()

    -- Unserialize after closing the file, just in case. I don't fully
    -- trust CC Lua's GC in this regard because I had to actually close
    -- MC once or twice because some files stayed locked even though I
    -- already returned to the menu.

    -- Custom implementation of textutils.unserialize() that properly handles
    -- serialized math.huge values...
    local result, _ = loadstring("return " .. data, filename)
    if not result then
        return true, data
    else
        return true, setfenv(result, {
            ["inf"] = math.huge
        })()
    end
end

--[[
    Utility function for trying to upgrade a state file from previous versions.

    @return true if a state file was upgraded; false otherwise.
    @private
]]
function private.upgrade()
    -- Skip if no state file of the expected old name exists.
    if not fs.exists(stateFile.position) or fs.isDir(stateFile.position) then
        return false
    end

    -- Try to parse the 'main' state file.
    local success, result = private.unserialize(stateFile.position)
    if not success or not private.validate(result, private.schema["1.0"]) then
        return false
    end

    -- It's a version 1.0 format state file. Convert to current
    -- format and return.
    state.position = result.position
    if type(result.moving) == "string" then
        state.fuel.current = result.preMoveFuel
        state.move = {
            direction = private.direction[result.moving],
            tries = result.tries,
            aggressive = result.aggressive
        }
        -- We did not track this explicitly in version 1.0, but
        -- when in a moving state we definitely had the startup
        -- file wrapped.
        state.wrap = 1
    end

    -- Write back the new format.
    private.save("position")
    private.save("move")
    private.save("fuel")
    private.save("wrap")

    return true
end

--[[
    Resets our internal state.

    This is used if we run into any unexpected errors, for example invalid
    state files or an unexpected fuel level on startup.

    @private
]]
function private.reset()
    state.position.x = 0
    state.position.y = 0
    state.position.z = 0
    state.position.f = 0
    -- No state.waypoints = {}. Keep waypoints intact.
    state.fuel = {
        current = turtle.getFuelLevel()
    }
    state.move = nil
    state.path = nil
    state.wrap = 0
    state.isInitializing = nil
    state.isInitialized = true

    fs.delete(stateFile.position)
    -- No fs.delete(stateFile.waypoints). Keep the waypoints intact.
    fs.delete(stateFile.fuel)
    fs.delete(stateFile.move)
    fs.delete(stateFile.path)
    fs.delete(stateFile.wrap)

    fs.delete(invalidStateFile)
end

--[[
    Checks whether the API is currently locked (because we're moving e.g.).

    @return true if we're locked; false otherwise.
]]
function private.isLocked()
    return state.move or state.path or state.fuel.id
end

-------------------------------------------------------------------------------
-- Resume command on startup stuff                                           --
-------------------------------------------------------------------------------

-- The script we use for automatically initializing the API after a reboot.
local startupScript = string.format([[assert(os.loadAPI(%q))
lama.init()
lama.hijackTurtleAPI()]], apiPath)

-- List of 'handlers'. This makes it easy to add support for different startup
-- script implementations (e.g. from different OSs or utility scripts).
--
-- The logic works like this: the active handler is determined by looking for
-- the first implementation that returns true from its 'test' function, else
-- the default handler is used. For the selected handler 'init' is called once
-- when the API is loaded. After that, wrap and unwrap are called like so:
--   move command -> wrap -> actual move -> unwrap
--   multimove -> wrap -> single moves (nested wraps!) -> unwrap
--   startup -> unwrap(true)
local startupHandlers = {
    -- Default implementation creates a wrapper startup script and moves the
    -- original startup script, if any, to a backup location to be restored
    -- when the startup script is run. This has rather bad performance because
    -- it adds one file write, one deletion and two moves to each move command.
    default = {
        init = function()
            assert(type(startupBackupFile) == "string" and startupBackupFile ~= "",
                "The setting 'startupBackupFile' must be a non-empty string.")
        end,
        wrap = function()
            local haveStartup = fs.exists("/startup")
            if haveStartup then
                fs.move("/startup", startupBackupFile)
            end

            local f = assert(fs.open("/startup", "w"), "Could not open startup script for writing.")
            f.writeLine(startupScript)
            if haveStartup then
                f.writeLine("shell.run('/startup')")
            else
            end
            f.close()
        end,
        unwrap = function()
            fs.delete("/startup")
            if fs.exists(startupBackupFile) then
                fs.move(startupBackupFile, "/startup")
            end
        end,
        test = function()
            -- Ignore when determining handler.
            return false
        end
    },

    -- Implementation for using Forairan's init-script startup program. This
    -- will only create a startup script once, which has no side effects if
    -- there were no pending moves, so performance impact is minimal.
    forairan = {
        init = function()
            -- Overwrite the startup file since the apiPath or the startup
            -- script's priority may have changed.
            local priority = type(startupPriority) == "number" and string.format("%2d") or tostring(startupPriority)
            local path = "/init-scripts/" .. priority .. "_lama"
            local f = assert(fs.open(path, "w"), "Could not open startup script for writing.")
            f.write(startupScript)
            f.close()
        end,
        test = function()
            -- Assume we use Forairan's startup logic if the init-scripts
            -- folder exists.
            return fs.exists("/init-scripts") and fs.isDir("/init-scripts")
        end
    },

    -- Implementation for my own little startup API. This will only create
    -- a startup script once, which has no side effects if there were no
    -- pending moves, so performance impact is minimal.
    sangar = {
        init = function()
            -- Overwrite the startup file since the apiPath or the startup
            -- script's priority may have changed.
            startup.remove("lama")
            startup.addString("lama", startupPriority, startupScript)
        end,
        test = function()
            -- Check if the startup API is loaded.
            return startup ~= nil and startup.version ~= nil
        end
    }
}

--[[
    Initializes startup script management.
    @private
]]
function private.initStartup()
    -- Validate configuration related to startup.
    assert(private.isInteger(startupPriority), "The setting 'startupPriority' must be an integral number.")

    -- Detect which handler to use, initialized to default as fallback.
    private.startupHandler = startupHandlers.default
    for _, handler in pairs(startupHandlers) do
        if handler.test() then
            private.startupHandler = handler
            break
        end
    end

    -- Run handler's init code.
    if private.startupHandler.init then
        private.startupHandler.init()
    end
end

--[[
    Actual behavior depends on the active handler.

    This allows for nested calling, where only the first nesting level performs
    an actual call to the wrap implementation.

    @private
]]
function private.wrapStartup()
    if state.wrap == 0 then
        if private.startupHandler.wrap then
            private.startupHandler.wrap()
        end
    end
    state.wrap = state.wrap + 1
    private.save("wrap")
end

--[[
    Actual behavior depends on the active handler.

    This allows for nested calling, where only the first nesting level performs
    an actual call to the unwrap implementation.

    @param force whether to force the unwrapping, used in init.
    @private
]]
function private.unwrapStartup(force)
    if state.wrap == 1 or (force and state.wrap > 0) then
        if private.startupHandler.unwrap then
            private.startupHandler.unwrap()
        end
        state.wrap = 0
        fs.delete(stateFile.wrap)
    elseif state.wrap > 0 then
        state.wrap = state.wrap - 1
        private.save("wrap")
    end
end

--[[
    Initializes the API by restoring a previous state and finishing any pending
    moves.

    This is used for lazy initialization, to avoid blocking when actually
    loading the API (i.e. when calling os.loadAPI("lama")). The first call to
    any function of the API will trigger this logic. An alternative "no-op"
    function to get() (which isn't very clear when reading) is the init()
    function, which should make the purpose of the call clear.

    @param dontCrash don't throw an error if the API is in an invalid state.
    @private
]]
function private.resume(dontCrash)
    if state.isInitialized then
        -- Already initialized successfully, nothing to do here.
        return
    end
    while state.isInitializing do
        -- Already being initialized by another thread, wait for it to finish.
        os.sleep(1)
    end
    if fs.exists(invalidStateFile) then
        -- API is in an invalid state, don't allow use of any functions.
        if dontCrash then
            -- Except those that explicitly allow it, which is set() for now.
            return
        end
        error("Invalid state. Please reinitialize the turtle's position.")
    end

    -------------------------------------------------------------------------------
    -- Environment checking                                                      --
    -------------------------------------------------------------------------------

    -- MT: Moved assertions here from end of API file because assert failures were
    --     preventing the API from loading when stored in ROM (e.g. when included in a
    --     resource pack

    assert(turtle, "The lama API can only run on turtles.")
    assert(os.getComputerLabel(), "Turtle has no label, required for state persistence.")
    assert(turtle.getFuelLevel() ~= "unlimited", "Turtles must use fuel for this API to work correctly.")

    if bapil then
        apiPath = bapil.resolveAPI(apiPath)
    else
        -- MT: Allow locally installed versions on each turtle to override the ROM version
        local i
        local tryPaths = {"/rom/apis/lama", "/rom/apis/turtle/lama", "/apis/lama", "/apis/turtle/lama"}
        for i = 1, #tryPaths do
            if fs.exists(tryPaths[i]) and not fs.isDir(tryPaths[i]) then
                apiPath = tryPaths[i]
            end
        end
    end

    -- MT: Re-set startupScript to include the chosen apiPath
    startupScript = string.format([[assert(os.loadAPI(%q))
lama.init()
lama.hijackTurtleAPI()]], apiPath)

    assert(type(apiPath) == "string" and apiPath ~= "", "The setting 'apiPath' must be a non-empty string.")
    assert(fs.exists(apiPath) and not fs.isDir(apiPath),
        "No file found at 'apiPath', please make sure it points to the lama API.")

    -- Thread safety: engaged!
    state.isInitializing = true

    -- Initialize startup script management.
    private.initStartup()

    -- Load state, if any.
    local valid = private.load()

    -- Process event queue (blocks until processed) and get the ID which is
    -- indicative of how long the turtle has lived (since command IDs grow
    -- steadily over the lifetime of a computer). This is used for the validity
    -- checks below.
    local id
    repeat
        os.sleep(0.1)
        id = turtle.native.detect()
    until id ~= -1
    private.waitForResponse(id)

    -- Force unwrapping if we have at least one level of startup wrapper.
    private.unwrapStartup(true)

    -- Ensure state validity using some tricks...
    if state.fuel.id then
        -- If the ID we just got from our detect() call was larger than the one
        -- we got when refueling we're OK. If it wasn't we can be sure there
        -- was a rollback, in which case we can't say where we are anymore.
        if id > state.fuel.id then
            state.fuel.current = turtle.getFuelLevel()
        else
            valid = false
        end
    elseif state.move then
        -- If we're moving it must match the stored one or be one less.
        valid = valid and turtle.getFuelLevel() == state.fuel.current or turtle.getFuelLevel() == state.fuel.current - 1
    else
        -- If we're not moving our fuel state must match the stored one.
        valid = valid and turtle.getFuelLevel() == state.fuel.current
    end

    -- If any validity check failed lock down the API.
    if not valid then
        -- This should not be possible if the API is used correctly, i.e. no
        -- other movement functions of the turtle are used. Another possibility
        -- why this can happen is a hard server crash (rollback).
        state.isInitializing = nil
        assert(fs.open(invalidStateFile, "w"), "Failed to create invalidation file.").close()
        error("Invalid state. Please reinitialize the turtle's position.")
    end

    -- Check if we performed a single move and finish any pending multi-try
    -- single moves.
    if state.move then
        -- We can use that fuel state to check whether we moved successfully or
        -- not: if we were moving, the fuel can only be equal to the previous
        -- level, or one less. Equal meaning we didn't move, one less meaning
        -- we did move.
        if turtle.getFuelLevel() == state.fuel.current then
            -- No fuel was used, so we didn't move. If we have some tries left,
            -- continue trying.
            if state.move.tries > 0 then
                local result, failureReason =
                    private.move(state.move.direction, state.move.tries, state.move.aggressive)
                private.startupResult = {
                    result = result,
                    reason = failureReason
                }
            else
                private.startupResult = {
                    result = false,
                    reason = private.tryGetReason(state.move.direction)
                }
                -- We do this after trying to get the reason, because that can
                -- yield (detect) so we might lose the result when we're reset
                -- in that phase.
                private.endMove()
            end
        elseif turtle.getFuelLevel() == state.fuel.current - 1 then
            -- We used one fuel so we made our move! As with the case above,
            -- this can only be wrong if refueling is involved somewhere,
            -- which, again, can only happen using coroutines.
            private.updateState()
            private.endMove()
        else
            -- Other cases handled in validation above!
            assert(false)
        end
    else
        -- We can assume we're in a valid non-moving state, so update our fuel.
        -- This is used to avoid having to save the fuel state again before
        -- each attempt to move and to finalize refuel operations.
        state.fuel.current = turtle.getFuelLevel()
        state.fuel.id = nil
        private.save("fuel")
    end

    -- If we're currently traveling towards a target location, continue doing
    -- so after resolving possibly active single moves above.
    if state.path then
        -- See if the previous move was successful. This isn't *really*
        -- necessary, because we could just try to continue moving, which would
        -- then result in the same failure, again. But we can avoid repeating
        -- work, so let's do it like this.
        local result, _ = not private.startupResult or private.startupResult.result
        if result then
            -- Everything is still OK, continue moving.
            private.navigate()
        else
            -- Something went wrong, exit travel mode. We don't have to touch
            -- the startup result, it's obviously already set.
            private.endNavigate()
        end
    end

    -- Done, don't run again, release thread lock!
    state.isInitializing = nil
    state.isInitialized = true
end

-------------------------------------------------------------------------------
-- Coordinate conversion                                                     --
-------------------------------------------------------------------------------

--[[
    Converts a coordinate from the internal system to Minecraft's system.

    This does nothing if useMinecraftCoordinates is false.

    @param x the X coordinate.
    @param y the Y coordinate.
    @param z the Z coordinate.
    @param facing the optional facing.
    @private
]]
function private.toMC(x, y, z, facing)
    if useMinecraftCoordinates then
        return y, z, -x, facing and (facing + 2) % 4 or nil
    else
        return x, y, z, facing
    end
end

--[[
    Converts a coordinate from Minecraft's system to the internal system.

    This does nothing if useMinecraftCoordinates is false.

    @param x the X coordinate.
    @param y the Y coordinate.
    @param z the Z coordinate.
    @param facing the optional facing.
    @private
]]
function private.fromMC(x, y, z, facing)
    if useMinecraftCoordinates then
        return -z, x, y, facing and (facing + 2) % 4 or nil
    else
        return x, y, z, facing
    end
end

-------------------------------------------------------------------------------
-- Movement implementation                                                   --
-------------------------------------------------------------------------------

--[[
    Waits for queued commands to finish.

    @param ids the response ID or list of IDs of the commands to wait for.
    @return true if the commands were executed successfully, false otherwise.
    @private
]]
function private.waitForResponse(ids)
    if type(ids) ~= "table" then
        ids = {ids}
    elseif #ids == 0 then
        return true
    end
    local success = true
    repeat
        local event, responseID, result = os.pullEvent("turtle_response")
        if event == "turtle_response" then
            for i = 1, #ids do
                if ids[i] == responseID then
                    success = success and result
                    table.remove(ids, i)
                    break
                end
            end
        end
    until #ids == 0
    return success
end

--[[
    Figures out why a turtle cannot move in the specified direction.

    @param direction the direction to check for.
    @return one of the lama.reason constants.
    @private
]]
function private.tryGetReason(direction)
    local detect = ({
        [private.direction.forward] = turtle.detect,
        [private.direction.up] = turtle.detectUp,
        [private.direction.down] = turtle.detectDown
    })[direction]
    local sideName = ({
        [private.direction.forward] = "front",
        [private.direction.up] = "top",
        [private.direction.down] = "bottom"
    })[direction]

    -- Check for turtles first, because it's non-yielding.
    if peripheral.getType(sideName) == "turtle" then
        -- A turtle is blocking us.
        return reason.turtle
    elseif detect then
        if detect() then
            -- Some other block is in our way.
            return reason.block
        else
            -- Not a block, so we can assume it's some entity.
            return reason.entity
        end
    else
        -- Cannot determine what's blocking us.
        return reason.unknown
    end
end

--[[
    Internal forward() implementation, used to ignore lock while navigating.

    @private
]]
function private.forward(tries, aggressive)
    return private.move(private.direction.forward, tries, aggressive)
end

--[[
    Internal back() implementation, used to ignore lock while navigating.

    @private
]]
function private.back(tries)
    return private.move(private.direction.back, tries)
end

--[[
    Internal up() implementation, used to ignore lock while navigating.

    @private
]]
function private.up(tries, aggressive)
    return private.move(private.direction.up, tries, aggressive)
end

--[[
    Internal down() implementation, used to ignore lock while navigating.

    @private
]]
function private.down(tries, aggressive)
    return private.move(private.direction.down, tries, aggressive)
end

--[[
    Internal turn() implementation, used to ignore lock while navigating.

    @private
]]
function private.turn(towards)
    -- Turn towards the target facing.
    local ids, position = {}, state.position
    if useMinecraftCoordinates then
        towards = (towards + 2) % 4
    end
    while position.f ~= towards do
        -- We do not use the turnLeft() and turnRight() functions, because we
        -- want full control: we push all native events in one go and then wait
        -- for all of them to finish. This way we can stick to the pattern of
        -- immediately returning (non-yielding) if the turn fails due to a full
        -- event queue.
        local id
        if towards == (position.f + 1) % 4 then
            -- Special case for turning clockwise, to avoid turning three times
            -- when once is enough, in particular for the left -> forward case,
            -- where we wrap around (from 3 -> 0).
            id = turtle.native.turnRight()
            if id == -1 then
                return false, reason.queue_full
            end
            position.f = (position.f + 1) % 4
        else
            id = turtle.native.turnLeft()
            if id == -1 then
                return false, reason.queue_full
            end
            position.f = (position.f - 1) % 4
        end
        private.save("position")
        table.insert(ids, id)
    end
    return private.waitForResponse(ids)
end

--[[
    Tries to move the turtle in the specified direction.

    If it doesn't work. checks whether we should try harder: if a number of
    tries is specified we'll dig (and if aggressive is set attack) as many
    times in the hope of getting somewhere.

    Use math.huge for infinite tries.

    @param direction the direction in which to move, i.e. forward, back, up or
        down. The appropriate functions are selected based on this value.
    @param tries if specified, the number of times to retry the move after
        trying to remove obstacles in our way. We may want to try more than
        once for stacks of sand/gravel or enemy entities.
    @param aggressive whether to allow attacking in addition to digging when
        trying to remove obstacles (only used if tries larger than zero).
    @param true if the move was successful, false otherwise.
    @private
]]
function private.move(direction, tries, aggressive)
    -- Type checks.
    assert(tries == nil or type(tries) == "number", "'tries' must be a number or omitted")
    assert(aggressive == nil or type(aggressive) == "boolean", "'aggressive' must be a boolean or omitted")

    -- Check our fuel.
    if turtle.getFuelLevel() < 1 then
        return false, reason.fuel
    end

    -- Clean up arguments.
    tries = tonumber(tries or 0)
    aggressive = aggressive and true or nil

    -- Mapping for functions based on movement direction.
    local move = ({
        [private.direction.forward] = turtle.native.forward,
        [private.direction.back] = turtle.native.back,
        [private.direction.up] = turtle.native.up,
        [private.direction.down] = turtle.native.down
    })[direction]
    local detect = ({
        [private.direction.forward] = turtle.detect,
        [private.direction.up] = turtle.detectUp,
        [private.direction.down] = turtle.detectDown
    })[direction]
    local dig = ({
        [private.direction.forward] = turtle.dig,
        [private.direction.up] = turtle.digUp,
        [private.direction.down] = turtle.digDown
    })[direction]
    local attack = ({
        [private.direction.forward] = turtle.attack,
        [private.direction.up] = turtle.attackUp,
        [private.direction.down] = turtle.attackDown
    })[direction]
    local side = ({
        [private.direction.forward] = "front",
        [private.direction.back] = "back",
        [private.direction.up] = "top",
        [private.direction.down] = "bottom"
    })[direction]

    -- Set up our move state. This is cleared if we fail for any reason, and
    -- only saved to disk if we actually start moving.
    state.move = {
        direction = direction,
        tries = tries,
        aggressive = aggressive
    }

    -- Try to move until we're out of tries (or successful).
    while true do
        -- Check if there's a turtle in our way. We do this first because it's
        -- non-yielding. If we didn't there's a very (very!) tiny chance for a
        -- turtle to block us but move away in the same tick, leading us to
        -- wrongly believe what blocked us was actually an invulnerable entity.
        if peripheral.getType(side) == "turtle" then
            -- There really is a turtle in our way. Reuse failure handling
            -- logic from below and just save the move state. Don't waste I/O.
            if state.move.tries > 0 then
                private.save("move")
            end
        else
            -- Initialize the move by calling the native function.
            local moveId = move()
            if moveId == -1 then
                private.endMove()
                return false, reason.queue_full
            end
            private.save("move")

            -- Wait for the result while having our startup file active.
            private.wrapStartup()
            local success = private.waitForResponse(moveId)
            private.unwrapStartup()

            -- Update state and flush it to disk if we actually moved.
            if success then
                private.updateState()
                private.endMove()
                return true
            end
        end

        -- If something went wrong check whether we should try again.
        if state.move.tries == 0 then
            private.endMove()
            return false, private.tryGetReason(direction)
        end

        -- See what seems to be blocking us. We do a peripheral check after
        -- each yielding function because I'm pretty sure that turtles can move
        -- into our way inbetween those yielding calls, which could lead us to
        -- believe that there's an indestructible block or invulnerable entity
        -- in front of us, not a turtle.
        -- This might actually happen with *any* moving... thing. Turtles are
        -- just the most likely, and really the only thing we can properly
        -- check for, so... yeah.
        if peripheral.getType(side) == "turtle" then
            -- It's a turtle. Wait and hope it goes away.
            os.sleep(1)
        elseif dig and dig() then
            -- We got rid of some block in our way. Wait a little to allow
            -- sand/gravel to drop down. I've had cases where the turtle
            -- would get into a weird state in which it moved below a
            -- dropping sand block, causing bad behavior.
            os.sleep(0.5)
        elseif peripheral.getType(side) == "turtle" then
            -- A turtle moved in while we dug... more waiting...
            os.sleep(1)
        elseif aggressive and attack and attack() then
            -- We successfully attacked something. Try again immediately!
        elseif peripheral.getType(side) == "turtle" then
            -- A turtle moved in while we attacked! Wait for it to leave.
            os.sleep(1)
        elseif detect then
            -- See if we can try to detect something.
            local block = detect()
            if peripheral.getType(side) == "turtle" then
                -- A turtle moved in... you know the deal.
                os.sleep(1)
            elseif block then
                -- Some block we can't dig. Stop right here, there's
                -- nothing we can do about it. Well, in theory it might
                -- go away due to it being moved by a frame/carriage,
                -- but we really don't want to count on that...
                private.endMove()
                return false, reason.unbreakable_block
            else
                -- Not a block but nothing we can/may attack. Unlike
                -- for unbreakable blocks, we'll keep trying even if
                -- we have infinite tries, because entities might just
                -- move.
                if state.move.tries == 1 then
                    private.endMove()
                    return false, reason.invulnerable_entity
                end
                os.sleep(1)
            end
        else
            -- We cannot determine what's in our way. Keep going until
            -- we're out of tries...
            os.sleep(0.5)
        end

        -- Let's try again. Doin' it right. Dat bass.
        state.move.tries = state.move.tries - 1
    end
end

--[[
    Finishes a movement.

    Based on whether it was successful or not it adjusts and then saves the new
    persistent state.

    @private
]]
function private.updateState()
    -- Shortcuts.
    local position = state.position
    local direction = private.direction[state.move.direction]

    -- Yes, update our state. Build a table with the displacement we'd
    -- have to apply in our identity state.
    local delta = {
        forward = {1, 0, 0},
        right = {0, 1, 0},
        back = {-1, 0, 0},
        left = {0, -1, 0},
        up = {0, 0, 1},
        down = {0, 0, -1}
    }

    -- Apply our facing.
    for i = 1, position.f do
        delta.forward, delta.right, delta.back, delta.left = delta.right, delta.back, delta.left, delta.forward
    end

    -- Finally, apply the actual displacement, based on the movement
    -- direction. This means we may do some extra work when moving
    -- up or down (where the facing doesn't matter), but it's not that
    -- bad, considering how long one move takes.
    position.x = position.x + delta[direction][1]
    position.y = position.y + delta[direction][2]
    position.z = position.z + delta[direction][3]

    -- Save new state.
    private.save("position")

    -- Also update our fuel level.
    state.fuel.current = turtle.getFuelLevel()
    private.save("fuel")
end

--[[
    Cleans up the movement state.

    This is really just for better readability.

    @private
]]
function private.endMove()
    state.move = nil
    fs.delete(stateFile.move)
end

--[[
    Makes a turtle move to the position currently set as the target.

    @return true if the turtle successfully reached the target; (false, reason)
        otherwise.
    @private
]]
function private.navigate()
    -- Validate state. This function should only be called when the list of
    -- steps is not empty; if it is it's a bug.
    assert(#state.path.steps > 0, "you found a bug")

    -- Utility function for moving a specified distance along a single axis.
    local function travel(axis, distance)
        -- If we make no moves along this axis we can skip the rest.
        if distance == 0 then
            return true
        end

        -- Turn to face the axis if necessary, in a way that we can move
        -- forwards (we don't want to move backwards because we cannot dig or
        -- attack when moving backwards). This is unnecessary for the z axis,
        -- because facing doesn't matter there.
        local directions = ({
            x = {side.north, side.south},
            y = {side.east, side.west}
        })[axis]
        if directions then
            local direction = distance > 0 and directions[1] or directions[2]
            local result, failureReason = private.turn(direction)
            if not result then
                return result, failureReason
            end
        end

        -- Move in the appropriate direction as often as necessary.
        local action = ({
            x = private.forward,
            y = private.forward,
            z = distance > 0 and private.up or private.down
        })[axis]
        distance = math.abs(distance)
        local tries, aggressive = state.path.tries, state.path.aggressive
        while distance > 0 do
            local result, failureReason = action(tries, aggressive)
            if not result then
                return result, failureReason
            end
            distance = distance - 1
        end

        -- All green.
        return true
    end

    -- Wrap startup in case we break down while not actually moving (e.g. while
    -- turning) so that we still resume moving.
    private.wrapStartup()

    -- Used for determining which way to go first.
    local function shortestFirstComparator(a, b)
        return math.abs(a.distance) < math.abs(b.distance)
    end
    local function longestFirstComparator(a, b)
        return math.abs(a.distance) > math.abs(b.distance)
    end

    -- Process all remaining waypoints.
    local result, failureReason = true
    local comparator = state.path.longestFirst and longestFirstComparator or shortestFirstComparator
    repeat
        -- Figure out how far we have to move along each axis.
        local position = state.position
        local x, y, z = position.x, position.y, position.z, position.f
        local step = state.path.steps[1]
        local dx, dy, dz = step.x - x, step.y - y, step.z - z
        local axisCount = (dx ~= 0 and 1 or 0) + (dy ~= 0 and 1 or 0) + (dz ~= 0 and 1 or 0)

        -- If we move along several axes and should move along the longest axis
        -- first, we split the move into several moves, one for each axis. This
        -- is to ensure that we move the same way even if we're interrupted. If
        -- we didn't do this and we were to be interrupted while moving along
        -- the longest axis, it could become shorter than one of the other axes
        -- and thus lead to us suddenly changing direction. We do this on the
        -- fly instead of once in the beginning to keep the state file small.
        if state.path.longestFirst and axisCount > 1 then
            -- Build the one (or two) intermediate points.
            local axes = {{
                axis = 1,
                distance = dx
            }, {
                axis = 2,
                distance = dy
            }, {
                axis = 3,
                distance = dz
            }}
            table.sort(axes, shortestFirstComparator)
            local stopover = {step.x, step.y, step.z}
            for _, entry in ipairs(axes) do
                stopover[entry.axis] = stopover[entry.axis] - entry.distance
                if stopover[1] == x and stopover[2] == y and stopover[3] == z then
                    break
                end
                -- Copy it so as not to change ones we already inserted and to
                -- get it in the right format (named keys).
                local stopoverCopy = {
                    x = stopover[1],
                    y = stopover[2],
                    z = stopover[3]
                }
                table.insert(state.path.steps, 1, stopoverCopy)
            end
        else
            -- Then move that distance along each axis.
            local axes = {{
                axis = "x",
                distance = dx
            }, {
                axis = "y",
                distance = dy
            }, {
                axis = "z",
                distance = dz
            }}
            table.sort(axes, comparator)
            for _, entry in ipairs(axes) do
                result, failureReason = travel(entry.axis, entry.distance)
                if not result then
                    break
                end
            end

            -- Finally, adjust our facing.
            if result and step.f ~= nil then
                if useMinecraftCoordinates then
                    step.f = (step.f + 2) % 4
                end
                result, failureReason = private.turn(step.f)
            end

            -- Done, we reached this waypoint so we can remove it from the list.
            table.remove(state.path.steps, 1)
        end
        private.save("path")
    until not result or #state.path.steps == 0

    -- Clear the state so we don't try to continue moving next startup.
    private.endNavigate()

    -- Unwrap the startup to restore the previous startup file, if any.
    private.unwrapStartup()

    -- And we're done.
    return result, failureReason
end

--[[
    Cleans up the navigation state.

    This is really just for better readability.

    @private
]]
function private.endNavigate()
    state.path = nil
    fs.delete(stateFile.path)
end

-------------------------------------------------------------------------------
-- Environment checking                                                      --
-------------------------------------------------------------------------------

-- MT: Environment checking moved to the private.resume() method because assert failures were
--     preventing the API from loading when stored in ROM (e.g. when included in a resource pack
