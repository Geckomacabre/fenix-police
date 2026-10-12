-- Civilian fire witnessing -- the FIRE-incident sibling of client/witness.lua.
--
-- Uses FIRE::GET_NUMBER_OF_FIRES_IN_RANGE rather than scanning individual
-- vehicles for IsEntityOnFire: it already tracks every active fire instance
-- in range regardless of source (bullet damage, explosions, script fires),
-- so there's no need to enumerate nearby vehicles/peds ourselves.
--
-- Opt-in: no-ops unless Config.Dispatch.enabled and Config.FireWatch.enabled
-- are both true.

local function cfg()
    return Config.FireWatch or {}
end

local function dbg(...)
    if cfg().debug then
        print('[fenix-police:firewatch]', ...)
    end
end

local lastReportAt = 0

local function checkForFire()
    local coords = GetEntityCoords(PlayerPedId())
    local radius = cfg().radius or 50.0

    if GetNumberOfFiresInRange(coords.x, coords.y, coords.z, radius) <= 0 then return end

    -- Report where the fire is, not where the witness is standing: the truck
    -- works (and STOP_FIRE_IN_RANGE clears) a radius around the reported
    -- point, so a fire 30m from the witness would never be put out and
    -- would keep being re-reported.
    local found, firePos = GetClosestFirePos(coords.x, coords.y, coords.z)
    if not found or #(firePos - coords) > radius then return end

    local now = GetGameTimer()
    local cooldownMs = cfg().reportCooldownMs or 20000
    if now - lastReportAt < cooldownMs then return end
    lastReportAt = now

    dbg(('fire detected %.0fm away, reporting'):format(#(firePos - coords)))
    TriggerServerEvent('fenix-police:server:reportFire', firePos)
end

CreateThread(function()
    while true do
        local interval = cfg().intervalMs or 5000

        if (Config.Dispatch or {}).enabled and cfg().enabled then
            local ok, err = pcall(checkForFire)
            if not ok then
                print('[fenix-police:firewatch] error:', err)
            end
        else
            interval = 5000
        end

        Wait(interval)
    end
end)
