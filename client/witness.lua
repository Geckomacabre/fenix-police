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
-- Deliberately NOT trying to identify other shooters: IS_ANY_PED_SHOOTING_IN_AREA
-- only confirms shots happened somewhere in the checked box, not who fired
-- them or the exact origin. Reporting the box center as the incident
-- location is an approximation, not omniscience. The one shooter a client
-- can name without guessing is its own player -- it saw the shot leave the
-- gun -- so a report says whether the caller fired themselves in the moments
-- before, and the server lists them as a suspect on the call. A cheating
-- client can only leave that out, which is exactly where things stood before;
-- it can never name anybody else. Nothing here touches wanted levels: a
-- suspect is only starred once an investigating officer actually sees them
-- armed at the scene (client/investigate.lua, server/dispatch.lua).
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
local lastReportSelfFired = false

-- When the local player last fired a gun, and whether they were standing in
-- one of Config.Investigate.exemptZones at the time. nil until they have.
local lastOwnShotAt = nil
local lastOwnShotExempt = false

-- "Weapons" that count as shooting without being gunfire. A fire crew
-- working a blaze with an extinguisher (client/fire.lua), or someone pouring
-- petrol, trips IS_ANY_PED_SHOOTING_IN_AREA exactly like a gun does -- and
-- would turn every fire call into a SHOOTING call as well.
local NOT_GUNFIRE = {
    [GetHashKey('WEAPON_FIREEXTINGUISHER')] = true,
    [GetHashKey('WEAPON_PETROLCAN')] = true,
    [GetHashKey('WEAPON_HAZARDCAN')] = true,
}

-- Shooting ranges (Config.Investigate.exemptZones). The helper lives with
-- the investigation code, which needs the same answer for a suspect.
local function inExemptZone(pos)
    return FenixInvestigate ~= nil and FenixInvestigate.inExemptZone(pos)
end

--- Is naming the caller as a suspect switched on? Only means anything while
--- an investigating unit can go and look for them.
local function suspectsEnabled()
    local invCfg = Config.Investigate or {}
    return invCfg.enabled == true and invCfg.findSuspects ~= false
end

-- True only when someone in the box is seen shooting and every such shooter
-- is excused: holding one of the NOT_GUNFIRE "weapons", or standing on a
-- shooting range. A box where no shooter can be picked out still counts as
-- gunfire, so this can only ever drop a report, never invent one. Height is
-- ignored on purpose: a wider net here only ever keeps a report.
local function onlyExcusedShooting(coords, radius)
    local sawExcused = false
    for _, ped in ipairs(GetGamePool('CPed')) do
        if IsPedShooting(ped) then
            local pos = GetEntityCoords(ped)
            if math.abs(pos.x - coords.x) <= radius and math.abs(pos.y - coords.y) <= radius then
                if not NOT_GUNFIRE[GetSelectedPedWeapon(ped)] and not inExemptZone(pos) then return false end
                sawExcused = true
            end
        end
    end
    return sawExcused
end

--- Did the local player fire a gun since the last poll (with a second's
--- slack), somewhere other than a range? Never for a player who can't be
--- starred anyway (client.lua's SetWantedLevel exemption), so an on-duty
--- officer's own shots never put them on a call's suspect list.
local function firedThemselves(now)
    if not suspectsEnabled() or not lastOwnShotAt or lastOwnShotExempt then return false end
    if now - lastOwnShotAt > (cfg().intervalMs or 4000) + 1000 then return false end
    return not (FenixInvestigate ~= nil and FenixInvestigate.wantedExempt())
end

local function checkForGunfire()
    -- A wanted player never calls gunfire in: mid-pursuit the shots in the box
    -- are this resource's own officers (or the player shooting back), and each
    -- report would send an ambulance and an investigation unit into the chase.
    if GetPlayerWantedLevel(PlayerId()) > 0 then return end

    local playerPed = PlayerPedId()
    local coords = GetEntityCoords(playerPed)

    -- Nobody on a range calls the range in.
    if inExemptZone(coords) then return end

    local radius = cfg().radius or 60.0

    local anyShooting = IsAnyPedShootingInArea(
        coords.x - radius, coords.y - radius, coords.z - radius,
        coords.x + radius, coords.y + radius, coords.z + radius,
        false, false
    )

    if not anyShooting then return end

    local now = GetGameTimer()
    local selfFired = firedThemselves(now)

    -- A report that names the caller as the shooter may follow one that
    -- didn't inside the cooldown: someone returning fire a moment after the
    -- first shots were called in is exactly the suspect the call needs.
    local cooldownMs = cfg().reportCooldownMs or 20000
    if now - lastReportAt < cooldownMs and (lastReportSelfFired or not selfFired) then return end
    if onlyExcusedShooting(coords, radius) then return end
    lastReportAt = now
    lastReportSelfFired = selfFired

    dbg(('gunfire detected within %.0fm, reporting%s'):format(radius, selfFired and ' (caller fired)' or ''))
    TriggerServerEvent('fenix-police:server:reportGunshot', coords, selfFired)
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

-- Own-shot tracker. IS_PED_SHOOTING is only true on the frame a shot goes
-- off, so it needs a per-frame look -- but only while a gun is actually in
-- hand; the rest of the time this sleeps.
CreateThread(function()
    while true do
        local ped = PlayerPedId()
        if (Config.Dispatch or {}).enabled and cfg().enabled and suspectsEnabled() and IsPedArmed(ped, 6) then
            if IsPedShooting(ped) and not NOT_GUNFIRE[GetSelectedPedWeapon(ped)] then
                lastOwnShotAt = GetGameTimer()
                lastOwnShotExempt = inExemptZone(GetEntityCoords(ped))
            end
            Wait(0)
        else
            Wait(500)
        end
    end
end)

RegisterCommand('fenixwitness', function()
    print(('[FENIX-WITNESS] enabled=%s radius=%.0fm intervalMs=%d cooldownMs=%d')
        :format(tostring(cfg().enabled == true), cfg().radius or 60.0, cfg().intervalMs or 4000, cfg().reportCooldownMs or 20000))
    print(('[FENIX-WITNESS] name own shots=%s last own shot=%s%s standing in an exempt zone=%s')
        :format(tostring(suspectsEnabled()),
            lastOwnShotAt and ('%dms ago'):format(GetGameTimer() - lastOwnShotAt) or 'never',
            lastOwnShotExempt and ' (in an exempt zone)' or '',
            tostring(inExemptZone(GetEntityCoords(PlayerPedId())))))
end, false)
