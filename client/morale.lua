--[[
    client/morale.lua

    What happens to a unit that is LOSING, as opposed to one that hasn't died
    yet.

    Every officer in this resource fights until they are a corpse:
    SetPedFleeAttributes(ped, 0, false) is set on every combat ped this
    resource creates, and a dead officer is simply dropped from
    spawnedVehicles.officers and silently replaced next maintainPoliceUnits()
    pass. There has never been a state between "winning" and "dead" — which is
    also why a pursuit reads as identical waves of cars rather than a response
    that reacts to how it's actually going.

    This file adds that state. FenixMorale.assess() is called once per cycle,
    per unit, from client.lua's existing per-officer loops (the same ones that
    already resolve every officer for tasking purposes) and decides whether a
    unit should break off:

      casualties   the unit has lost (dead) or effectively lost (badly
                   wounded) too large a fraction of the officers it started
                   with
      outnumbered  the unit is down to its last officer, facing an armed
                   suspect at a serious wanted level — one badge against a
                   determined armed suspect, whether or not shots have
                   actually been exchanged yet
      suppressed   the unit has been in trouble for a while without it
                   resolving either way

    Once a unit breaks, THIS file owns it entirely: officers flee or cower
    clear, re-board if their car survived, and drive off — client.lua's own
    tasking loop is told to leave that unit alone (FenixMorale.isRetreating)
    for as long as it's regrouping. When the regroup timer elapses the unit is
    simply handed back to client.lua's normal tasking if the player is still
    around, which is what turns "everyone fights to the death" into "beaten
    units fall back, then get back in the fight" instead of the old silent
    death-and-replace.

    Deliberately NOT wired into client/tactics.lua's roadblock/spike-strip
    officers — those are static obstacles with no per-officer task state
    machine to retreat out of. Only the chase-unit loops in client.lua use
    this.
]]

FenixMorale = {}

local function cfg() return Config.Morale or {} end
local function dbg(msg) if cfg().debug then print('[FENIX-MORALE] ' .. msg) end end

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

-- vehNetID -> officer count the unit had the first time assess() ever saw it.
-- Lazily captured rather than set at every spawn call site (there are three,
-- one per unit kind) — assess() runs every cycle starting immediately after a
-- unit registers, well before a casualty could plausibly happen first, so
-- "first cycle observed" and "at full strength" are the same moment in
-- practice.
local originalCrew = {}

-- vehNetID -> gameTimer of the first cycle this unit showed ANY trouble
-- (a casualty or a wounded officer). Never cleared once set for that unit's
-- lifetime -- a unit that has already taken a loss doesn't get to reset the
-- clock by having a quiet minute, it just also has the fraction/outnumbered
-- triggers available to fire sooner.
local troubleSince = {}

-- vehNetID -> retreat record: { phase, since, officers = {pedNetID=ped,...},
-- vehicle, reason }. Presence in this table IS "this unit is retreating".
local retreating = {}

-------------------------------------------------------------------------------
-- Decision
-------------------------------------------------------------------------------

--- Should this unit break off right now?
---
--- @param vehNetID number
--- @param vehicleData table the spawnedVehicles[vehNetID] entry — officers is
---        read for the CURRENT (post-casualty) headcount.
--- @param liveOfficers table array of { pedNetID, ped, health, maxHealth } for
---        officers client.lua's own loop already resolved this cycle — morale
---        doesn't re-resolve NetToPed itself, it reuses what tasking already did.
--- @param wantedLevel number
--- @return boolean, string|nil  shouldRetreat, reason
function FenixMorale.assess(vehNetID, vehicleData, liveOfficers, wantedLevel)
    local c = cfg()
    if c.enabled == false then return false end
    if retreating[vehNetID] then return false end -- already handled

    local currentCount = 0
    for _ in pairs(vehicleData.officers or {}) do currentCount = currentCount + 1 end
    if currentCount == 0 then return false end

    if not originalCrew[vehNetID] then
        originalCrew[vehNetID] = currentCount
    end
    local original = originalCrew[vehNetID]

    local dead = math.max(0, original - currentCount)

    local wounded = 0
    for _, o in ipairs(liveOfficers or {}) do
        if o.maxHealth and o.maxHealth > 0 and (o.health / o.maxHealth) < (c.woundedHealthFraction or 0.3) then
            wounded = wounded + 1
        end
    end

    local troubled = (dead > 0) or (wounded > 0)
    if troubled and not troubleSince[vehNetID] then
        troubleSince[vehNetID] = GetGameTimer()
    end

    local fraction = (dead + wounded) / original
    if fraction >= (c.casualtyFraction or 0.5) then
        return true, 'casualties'
    end

    if currentCount <= 1 and (wantedLevel or 0) >= (c.outnumberedWantedLevel or 3) then
        local playerPed = PlayerPedId()
        if IsPedArmed(playerPed, 7) then
            return true, 'outnumbered'
        end
    end

    if troubled and troubleSince[vehNetID]
        and (GetGameTimer() - troubleSince[vehNetID]) >= (c.suppressedMs or 25000) then
        return true, 'suppressed'
    end

    return false
end

--- True while this unit is mid-retreat/regroup and client.lua's normal
--- tasking should leave its officers alone.
function FenixMorale.isRetreating(vehNetID)
    return retreating[vehNetID] ~= nil
end

--- Forget a unit entirely — it fully despawned, reboarded, or the pursuit
--- ended. Called from client.lua wherever a vehNetID is dropped from
--- spawnedVehicles today.
function FenixMorale.clearUnit(vehNetID)
    originalCrew[vehNetID] = nil
    troubleSince[vehNetID] = nil
    retreating[vehNetID] = nil
end

--- Full reset, every unit at once. Called from handleEndWantedDelete's
--- whole-roster wipe — cheaper than clearUnit-ing every key individually, and
--- correct for the same reason: nothing survives that sweep anyway.
function FenixMorale.resetAll()
    originalCrew = {}
    troubleSince = {}
    retreating = {}
end

-------------------------------------------------------------------------------
-- The retreat itself
-------------------------------------------------------------------------------

--- Start a unit disengaging. Idempotent — a second call while already
--- retreating does nothing.
--- @param liveOfficers table same shape assess() takes; used to task the
---        officers immediately rather than waiting a cycle for a re-resolve.
function FenixMorale.beginRetreat(vehNetID, vehicleData, liveOfficers, reason)
    if retreating[vehNetID] then return end
    local c = cfg()

    local record = {
        phase   = 'fleeing',
        since   = GetGameTimer(),
        vehicle = vehicleData.vehicle,
        officers = {},
        reason  = reason,
    }

    local playerPed = PlayerPedId()

    for _, o in ipairs(liveOfficers or {}) do
        if o.ped and DoesEntityExist(o.ped) and not IsPedDeadOrDying(o.ped, true) then
            record.officers[o.pedNetID] = o.ped
            ClearPedTasksImmediately(o.ped)

            if (c.retreatStyle or 'flee') == 'cower'
                and not HasEntityClearLosToEntity(o.ped, playerPed, 17) then
                -- Only cower when there's actually cover between them and the
                -- player -- cowering in the open just holds them still to be
                -- shot, which is worse than doing nothing.
                TaskCower(o.ped, 8000)
            else
                -- Away from the player, not toward a fixed point: the native
                -- already picks a path clear of line of sight, which is the
                -- entire behaviour wanted here.
                TaskSmartFleePed(o.ped, playerPed, 60.0, -1, false, false)
            end
        end
    end

    retreating[vehNetID] = record
    dbg(('unit %s retreating (%s)'):format(vehNetID, reason))

    if FenixPursuit and FenixPursuit.announceRetreat then
        FenixPursuit.announceRetreat()
    end
end

--- One officer, one attempt to get back in the car. Returns true once done
--- (in a vehicle, or gave up and is staying on foot for this retreat).
local function tryBoard(ped, vehicle)
    if not DoesEntityExist(ped) or IsPedDeadOrDying(ped, true) then return true end
    if IsPedInAnyVehicle(ped, false) then return true end
    if not vehicle or not DoesEntityExist(vehicle) or IsEntityDead(vehicle) then return true end

    -- Rear seats first (2, 1) so a lone survivor doesn't fight over the
    -- driver's seat with a squadmate who's already boarding; -1/0 as a
    -- fallback for a two-seater.
    for _, seat in ipairs({ 2, 1, -1, 0 }) do
        if GetPedInVehicleSeat(vehicle, seat) == 0 then
            TaskEnterVehicle(ped, vehicle, 8000, seat, 2.0, 1, 0)
            return false
        end
    end
    return false
end

--- Advance every retreating unit one tick. Cheap: a pursuit has at most a
--- handful of units, and most cycles most of them are just waiting out the
--- regroup timer.
local function tickRetreats()
    local c = cfg()
    local now = GetGameTimer()

    for vehNetID, r in pairs(retreating) do
        if r.phase == 'fleeing' then
            -- Give the flee/cower task a few seconds to actually put distance
            -- down before asking anyone to stop and board a car.
            if (now - r.since) > 3000 then
                r.phase = 'entering'
                r.since = now
            end

        elseif r.phase == 'entering' then
            local allDone = true
            for _, ped in pairs(r.officers) do
                if not tryBoard(ped, r.vehicle) then allDone = false end
            end

            if allDone or (now - r.since) > 15000 then
                if r.vehicle and DoesEntityExist(r.vehicle) and not IsEntityDead(r.vehicle) then
                    local driver = GetPedInVehicleSeat(r.vehicle, -1)
                    if driver and driver ~= 0 and DoesEntityExist(driver) then
                        SetPedCombatAttributes(driver, 3, false) -- stay in the car, matches tactics.lua's own use
                        TaskVehicleDriveWander(driver, r.vehicle, 25.0, 786603)
                    end
                    r.phase = 'driving'
                else
                    r.phase = 'foot_hold'
                end
                r.since = now
            end

        elseif r.phase == 'driving' or r.phase == 'foot_hold' then
            if (now - r.since) >= ((c.regroupSeconds or 35) * 1000) then
                dbg(('unit %s regrouped, back in the fight'):format(vehNetID))
                retreating[vehNetID] = nil
                -- originalCrew/troubleSince deliberately kept: a unit that
                -- rejoins and takes ANOTHER loss should break again sooner,
                -- not need to rebuild the same fraction from a reset baseline.
            end
        end
    end
end

CreateThread(function()
    while true do
        Wait(1000)
        if next(retreating) then tickRetreats() end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    retreating = {}
end)

RegisterCommand('fenixmorale', function()
    local n = 0
    for _ in pairs(retreating) do n = n + 1 end
    print(('[FENIX-MORALE] %d unit(s) currently retreating/regrouping'):format(n))
    for vehNetID, r in pairs(retreating) do
        print(('  unit %s: %s, %.0fs ago (%s)')
            :format(vehNetID, r.phase, (GetGameTimer() - r.since) / 1000.0, r.reason))
    end
end, false)
