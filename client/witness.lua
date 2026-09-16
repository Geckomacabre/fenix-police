-- Civilian witness reporting: "gunfire happened near me" -> 911 call.
--
-- This resource has no general-purpose "something bad just happened, call it
-- in" pipeline -- pursuit.lua's contact model only starts once a police
-- officer already exists nearby, and violations.lua only covers moving
-- violations. This file is the missing link for the design spec's civilian
-- AI section: a local player (standing in for "a civilian is present here")
-- periodically checks for nearby gunfire and reports it to the server,
-- which turns it into a real SHOOTING incident via FenixDispatch.
--
-- Deliberately NOT trying to identify the shooter: IS_ANY_PED_SHOOTING_IN_AREA
-- only confirms shots happened somewhere in the checked box, not who fired
-- them or the exact origin. Reporting the box center as the incident
-- location is an approximation, not omniscience -- see server/dispatch.lua's
-- reportGunshot handler for why this never touches wanted levels.
--
-- Entirely opt-in: no-ops unless both Config.Dispatch.enabled and
-- Config.Witness.enabled are true, so it has zero effect on a server that
-- hasn't turned on the new incident system.

local function cfg()
    return Config.Witness or {}
end

local function dbg(...)
    if cfg().debug then
        print('[fenix-police:witness]', ...)
    end
end

local lastReportAt = 0

local function checkForGunfire()
    local playerPed = PlayerPedId()
    local coords = GetEntityCoords(playerPed)
    local radius = cfg().radius or 60.0

    local anyShooting = IsAnyPedShootingInArea(
        coords.x - radius, coords.y - radius, coords.z - radius,
        coords.x + radius, coords.y + radius, coords.z + radius,
        false, false
    )

    if not anyShooting then return end

    local now = GetGameTimer()
    local cooldownMs = cfg().reportCooldownMs or 20000
    if now - lastReportAt < cooldownMs then return end
    lastReportAt = now

    dbg(('gunfire detected within %.0fm, reporting'):format(radius))
    TriggerServerEvent('fenix-police:server:reportGunshot', coords)
end

CreateThread(function()
    while true do
        local interval = cfg().intervalMs or 4000

        if (Config.Dispatch or {}).enabled and cfg().enabled then
            local ok, err = pcall(checkForGunfire)
            if not ok then
                print('[fenix-police:witness] error:', err)
            end
        else
            interval = 5000 -- config disabled: idle-poll cheaply in case it's toggled at runtime
        end

        Wait(interval)
    end
end)

RegisterCommand('fenixwitness', function()
    print(('[FENIX-WITNESS] enabled=%s radius=%.0fm intervalMs=%d cooldownMs=%d')
        :format(tostring(cfg().enabled == true), cfg().radius or 60.0, cfg().intervalMs or 4000, cfg().reportCooldownMs or 20000))
end, false)
