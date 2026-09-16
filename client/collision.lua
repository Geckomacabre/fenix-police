-- Crash detection -- the TRAFFIC_COLLISION-incident sibling of
-- client/witness.lua and client/firewatch.lua.
--
-- Unlike gunfire (IS_ANY_PED_SHOOTING_IN_AREA) and fire
-- (GET_NUMBER_OF_FIRES_IN_RANGE), there's no single native that answers
-- "did a crash just happen nearby" -- see the design notes this resource's
-- author left when this was scoped (VEHICLE::GET_VEHICLE_BODY_HEALTH and
-- ENTITY::GET_ENTITY_SPEED are the closest primitives). So this only
-- monitors the LOCAL PLAYER'S OWN vehicle: a sudden body-health drop while
-- it was moving above a threshold speed is treated as a crash. That is a
-- narrower net than "any nearby collision" -- it will not catch two NPCs
-- crashing into each other out of the player's vehicle, and it will not
-- catch a stationary vehicle getting rear-ended (its own speed at impact is
-- ~0). Documented rather than papered over: extending this to arbitrary
-- nearby vehicles means periodically scanning GetGamePool('CVehicle') and
-- tracking a health sample per entity, which is real cost for a case this
-- pass didn't need yet.
--
-- Opt-in: no-ops unless Config.Dispatch.enabled and Config.Collision.enabled
-- are both true.

local function cfg()
    return Config.Collision or {}
end

local function dbg(...)
    if cfg().debug then
        print('[fenix-police:collision]', ...)
    end
end

local lastHealth = nil
local lastSpeed = 0.0
local lastReportAt = 0

local function checkForCrash()
    local playerPed = PlayerPedId()
    if not IsPedInAnyVehicle(playerPed, false) then
        lastHealth = nil
        return
    end

    local vehicle = GetVehiclePedIsIn(playerPed, false)
    local health = GetVehicleBodyHealth(vehicle)
    local speed = GetEntitySpeed(vehicle)

    if lastHealth then
        local drop = lastHealth - health
        local minSpeed = cfg().minSpeedForCrash or 15.0 -- ~54 km/h

        if drop >= (cfg().healthDropThreshold or 150.0) and lastSpeed >= minSpeed then
            local now = GetGameTimer()
            local cooldownMs = cfg().reportCooldownMs or 20000
            if now - lastReportAt >= cooldownMs then
                lastReportAt = now
                local coords = GetEntityCoords(vehicle)
                dbg(('crash detected (health -%.0f at %.0f m/s), reporting'):format(drop, lastSpeed))
                TriggerServerEvent('fenix-police:server:reportCollision', coords)
            end
        end
    end

    lastHealth = health
    lastSpeed = speed
end

CreateThread(function()
    while true do
        local interval = cfg().intervalMs or 1000

        if (Config.Dispatch or {}).enabled and cfg().enabled then
            local ok, err = pcall(checkForCrash)
            if not ok then
                print('[fenix-police:collision] error:', err)
            end
        else
            lastHealth = nil
            interval = 5000
        end

        Wait(interval)
    end
end)
