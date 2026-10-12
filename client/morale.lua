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
    for as long as it's regrouping. When the regroup timer elapses a unit that
    has pulled itself together is handed back to client.lua's normal tasking,
    and one that is still broken is RELEASED (FenixMorale.release) so
    client.lua removes it and a fresh unit comes in as relief — which is what
    turns "everyone fights to the death" into "beaten units fall back and get
    replaced" instead of the old silent death-and-replace.

    Deliberately NOT wired into client/tactics.lua's roadblock/spike-strip
    officers — those are static obstacles with no per-officer task state
    machine to retreat out of. Only the chase-unit loops in client.lua use
    this.
]]

FenixMorale = {}

local function cfg() return Config.Morale or {} end
local function dbg(msg) if cfg().debug then print('[FENIX-MORALE] ' .. msg) end end

-- SCRIPT_TASK_ENTER_VEHICLE, for GetScriptTaskStatus.
local TASK_ENTER_VEHICLE = 0x950B6492

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

-- vehNetID -> officer count the unit had the first time assess() ever saw it.
-- Lazily captured rather than set at every spawn call site (there are three,
-- one per unit kind) — assess() runs every cycle starting immediately after a
-- unit registers, well before a casualty could plausibly happen first, so
-- "first cycle observed" and "at full strength" are the same moment in
-- practice. Lowered by officerRemoved() when an officer leaves alive.
local originalCrew = {}

-- vehNetID -> vehicle handle the baseline above was captured against. A
-- vehNetID that later shows up attached to a different car is a recycled id
-- for a brand new unit, which must not inherit the old one's casualties.
local crewVehicle = {}

-- vehNetID -> { [pedNetID] = true } for every officer of that unit known to be
-- dead. Explicit rather than "original minus current headcount": officers also
-- leave the roster alive (a foot chase given up, a far-away cleanup), and
-- counting those as casualties broke units that hadn't lost anybody.
local deaths = {}

-- vehNetID -> { [pedNetID] = true } officers already taken off the baseline by
-- officerRemoved(), so a repeated call can't shrink it twice.
local removed = {}

-- vehNetID -> gameTimer of the first cycle this unit showed ANY trouble
-- (a casualty or a wounded officer). Not cleared by a quiet minute -- a unit
-- that has already taken a loss doesn't get to reset the clock by having a
-- quiet minute, it just also has the fraction/outnumbered triggers available
-- to fire sooner. Only a completed regroup clears it.
local troubleSince = {}

-- vehNetID -> losses (dead + badly wounded) the unit was carrying when it
-- rejoined after a regroup. Only losses beyond this count as new trouble:
-- health never comes back, so measuring from zero would send a rejoined unit
-- straight back out over the same wounds it just regrouped from, every cycle,
-- for the rest of the pursuit.
local lossesAtRejoin = {}

-- vehNetID -> retreat record: { phase, since, officers = {pedNetID=ped,...},
-- boarding = {pedNetID=seat,...}, vehicle, reason }. Presence in this table
-- IS "this unit is retreating".
local retreating = {}

-- vehNetID -> reason. A released unit is finished with this pursuit: it drives
-- away and client.lua deletes it once it's out of sight, which frees its slot
-- for a fresh unit. See FenixMorale.release().
local released = {}

local lastAnnounceAt = 0

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

--- The unit's car, re-resolved from its net id rather than trusted from a
--- stored handle: a handle outlives the entity it named and can be handed to
--- a different one, and tasking that would steer somebody else's car.
local function unitVehicle(vehNetID, r)
    if not NetworkDoesEntityExistWithNetworkId(vehNetID) then return nil end
    local veh = NetToVeh(vehNetID)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return nil end
    if r and r.vehicle and r.vehicle ~= 0 and veh ~= r.vehicle then return nil end
    return veh
end

--- The unit's car if it can still carry anyone away: intact, drivable, and not
--- currently being driven by a player who has taken it.
local function usableVehicle(vehNetID, r)
    local veh = unitVehicle(vehNetID, r)
    if not veh then return nil end
    if IsEntityDead(veh) or not IsVehicleDriveable(veh, false) then return nil end
    local driver = GetPedInVehicleSeat(veh, -1)
    if driver ~= 0 and IsPedAPlayer(driver) then return nil end
    return veh
end

--- Same idea for an officer: the stored handle only counts while its net id
--- still resolves to it.
local function officerPed(pedNetID, ped)
    if not ped or ped == 0 then return nil end
    if not NetworkDoesEntityExistWithNetworkId(pedNetID) then return nil end
    if NetToPed(pedNetID) ~= ped then return nil end
    return ped
end

--- Losses (dead + badly wounded) and survivors among `list`, an array of
--- { pedNetID, ped, health?, maxHealth? }. An officer found dead on the way
--- through is recorded as a death, so the count never depends on a caller
--- having remembered to report it.
--- @return number losses, number alive
local function tally(vehNetID, list)
    local c = cfg()
    local wounded, alive = 0, 0

    for _, o in ipairs(list) do
        local ped = o.ped
        local dead = deaths[vehNetID]
        if o.pedNetID ~= nil and ped and ped ~= 0 and DoesEntityExist(ped)
            and not (dead and dead[o.pedNetID]) then
            if IsPedDeadOrDying(ped, true) then
                FenixMorale.reportDeath(vehNetID, o.pedNetID)
            else
                alive = alive + 1
                local health = o.health or GetEntityHealth(ped)
                local maxHealth = o.maxHealth or GetEntityMaxHealth(ped)
                if maxHealth and maxHealth > 0 and (health / maxHealth) < (c.woundedHealthFraction or 0.3) then
                    wounded = wounded + 1
                end
            end
        end
    end

    return count(deaths[vehNetID]) + wounded, alive
end

--- Why a unit in this state is (still) unfit to fight, or nil when it isn't.
--- Shared by assess() and the end of a regroup, so "broke" and "still broken"
--- can never disagree about what broken means.
local function brokenReason(losses, alive, original, wantedLevel)
    local c = cfg()

    if (losses / original) >= (c.casualtyFraction or 0.5) then
        return 'casualties'
    end

    -- Only a unit that has actually been whittled down to one: a unit that
    -- STARTED with a single officer (a motorbike) isn't outnumbered by
    -- existing. Guns only (6 = explosives + firearms) -- a drawn knife is not
    -- a reason for a cruiser to flee.
    if original > 1 and alive <= 1 and (wantedLevel or 0) >= (c.outnumberedWantedLevel or 3)
        and IsPedArmed(PlayerPedId(), 6) then
        return 'outnumbered'
    end

    return nil
end

-------------------------------------------------------------------------------
-- Decision
-------------------------------------------------------------------------------

--- Should this unit break off right now?
---
--- @param vehNetID number
--- @param vehicleData table the spawnedVehicles[vehNetID] entry — officers is
---        read for the CURRENT (post-casualty) roster.
--- @param liveOfficers table array of { pedNetID, ped, health, maxHealth } for
---        officers client.lua's own loop already resolved this cycle — morale
---        doesn't re-resolve NetToPed itself, it reuses what tasking already did.
--- @param wantedLevel number
--- @return boolean, string|nil  shouldRetreat, reason
function FenixMorale.assess(vehNetID, vehicleData, liveOfficers, wantedLevel)
    local c = cfg()
    if c.enabled == false then return false end
    if vehNetID == nil or type(vehicleData) ~= 'table' then return false end

    if crewVehicle[vehNetID] ~= nil and crewVehicle[vehNetID] ~= (vehicleData.vehicle or 0) then
        FenixMorale.clearUnit(vehNetID)
    end
    if retreating[vehNetID] or released[vehNetID] then return false end -- already handled

    local roster = vehicleData.officers or {}
    local currentCount = count(roster)
    if currentCount == 0 then return false end

    if not originalCrew[vehNetID] then
        originalCrew[vehNetID] = currentCount
        crewVehicle[vehNetID] = vehicleData.vehicle or 0
    end
    local original = math.max(1, originalCrew[vehNetID])

    local losses = tally(vehNetID, liveOfficers or {})

    local dead = deaths[vehNetID] or {}
    local alive = 0
    for pedNetID in pairs(roster) do
        if not dead[pedNetID] then alive = alive + 1 end
    end
    -- Nobody left standing to fall back.
    if alive == 0 then return false end

    local troubled = losses > (lossesAtRejoin[vehNetID] or 0)
    if troubled and not troubleSince[vehNetID] then
        troubleSince[vehNetID] = GetGameTimer()
    end

    local reason = brokenReason(losses, alive, original, wantedLevel)
    if reason then return true, reason end

    if troubled and troubleSince[vehNetID]
        and (GetGameTimer() - troubleSince[vehNetID]) >= (c.suppressedMs or 25000) then
        return true, 'suppressed'
    end

    return false
end

--- An officer of this unit has died. Idempotent per officer — client.lua
--- reports the moment it first sees the death, and assess() also records any
--- it finds itself, so either order is fine.
function FenixMorale.reportDeath(vehNetID, pedNetID)
    if vehNetID == nil or pedNetID == nil then return end
    if removed[vehNetID] and removed[vehNetID][pedNetID] then return end

    local set = deaths[vehNetID]
    if not set then
        set = {}
        deaths[vehNetID] = set
    end
    set[pedNetID] = true
end

--- An officer left this unit ALIVE (a foot chase given up, a far-away
--- cleanup). Takes them off the unit's baseline so their absence doesn't read
--- as a casualty. Idempotent per officer; a no-op for an officer already
--- recorded dead, whose removal is just the body being cleared away.
function FenixMorale.officerRemoved(vehNetID, pedNetID)
    if vehNetID == nil or pedNetID == nil then return end
    if deaths[vehNetID] and deaths[vehNetID][pedNetID] then return end

    local set = removed[vehNetID]
    if not set then
        set = {}
        removed[vehNetID] = set
    end
    if set[pedNetID] then return end
    set[pedNetID] = true

    if originalCrew[vehNetID] then
        originalCrew[vehNetID] = math.max(0, originalCrew[vehNetID] - 1)
    end

    local r = retreating[vehNetID]
    if r then
        r.officers[pedNetID] = nil
        r.boarding[pedNetID] = nil
    end
end

--- True while this unit is mid-retreat/regroup, or released, and client.lua's
--- normal tasking should leave its officers alone.
function FenixMorale.isRetreating(vehNetID)
    if vehNetID == nil then return false end
    return retreating[vehNetID] ~= nil or released[vehNetID] ~= nil
end

--- True once a unit is finished with this pursuit and should be removed so a
--- fresh unit can take its place.
function FenixMorale.isReleased(vehNetID)
    if vehNetID == nil then return false end
    return released[vehNetID] ~= nil
end

--- Forget a unit entirely — it fully despawned, reboarded, or the pursuit
--- ended. Called from client.lua wherever a vehNetID is dropped from
--- spawnedVehicles.
function FenixMorale.clearUnit(vehNetID)
    if vehNetID == nil then return end
    originalCrew[vehNetID] = nil
    crewVehicle[vehNetID] = nil
    deaths[vehNetID] = nil
    removed[vehNetID] = nil
    troubleSince[vehNetID] = nil
    lossesAtRejoin[vehNetID] = nil
    retreating[vehNetID] = nil
    released[vehNetID] = nil
end

--- Full reset, every unit at once. Called from handleEndWantedDelete's
--- whole-roster wipe — cheaper than clearUnit-ing every key individually, and
--- correct for the same reason: nothing survives that sweep anyway.
function FenixMorale.resetAll()
    originalCrew = {}
    crewVehicle = {}
    deaths = {}
    removed = {}
    troubleSince = {}
    lossesAtRejoin = {}
    retreating = {}
    released = {}
    lastAnnounceAt = 0
end

-------------------------------------------------------------------------------
-- The retreat itself
-------------------------------------------------------------------------------

--- Put a surviving officer behind the wheel and drive the car away. Returns
--- false when nobody can drive it.
local function startDriving(r, veh)
    local driver = GetPedInVehicleSeat(veh, -1)

    if driver == 0 then
        -- Nobody made it into the driver's seat. Move across an officer who
        -- is already inside the car -- a seat swap, not a teleport -- rather
        -- than leave a car full of officers parked in the line of fire.
        for _, ped in pairs(r.officers) do
            if DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true)
                and GetVehiclePedIsIn(ped, false) == veh then
                SetPedIntoVehicle(ped, veh, -1)
                driver = ped
                break
            end
        end
    end

    if driver == 0 or not DoesEntityExist(driver) or IsPedDeadOrDying(driver, true)
        or IsPedAPlayer(driver) then
        return false
    end

    for _, ped in pairs(r.officers) do
        if DoesEntityExist(ped) and GetVehiclePedIsIn(ped, false) == veh then
            SetPedCombatAttributes(ped, 3, false) -- stay in the car, matches tactics.lua's own use
        end
    end
    TaskVehicleDriveWander(driver, veh, 25.0, 786603)
    return true
end

--- Start a unit disengaging. Idempotent — a second call while already
--- retreating does nothing.
--- @param liveOfficers table same shape assess() takes; used to task the
---        officers immediately rather than waiting a cycle for a re-resolve.
function FenixMorale.beginRetreat(vehNetID, vehicleData, liveOfficers, reason)
    if vehNetID == nil or retreating[vehNetID] or released[vehNetID] then return end
    local c = cfg()
    local now = GetGameTimer()

    local record = {
        phase    = 'fleeing',
        since    = now,
        vehicle  = type(vehicleData) == 'table' and vehicleData.vehicle or nil,
        officers = {},
        boarding = {},
        reason   = reason,
    }

    local playerPed = PlayerPedId()
    local car = usableVehicle(vehNetID, record)
    local anyOnFoot = false

    for _, o in ipairs(liveOfficers or {}) do
        if o.pedNetID ~= nil and o.ped and o.ped ~= 0 and DoesEntityExist(o.ped)
            and not IsPedDeadOrDying(o.ped, true) then
            record.officers[o.pedNetID] = o.ped
            -- Not ClearPedTasksImmediately: that warps an officer out of the
            -- car on the spot, which turned every retreat into a walk back to
            -- the car they had just been sitting in.
            ClearPedTasks(o.ped)

            if not (car and GetVehiclePedIsIn(o.ped, false) == car) then
                anyOnFoot = true
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
    end

    -- Everyone is already aboard: nobody to wait for, so the car leaves on the
    -- next tick instead of idling through a flee phase nobody is running.
    if not anyOnFoot then record.phase = 'entering' end

    retreating[vehNetID] = record
    dbg(('unit %s retreating (%s)'):format(vehNetID, tostring(reason)))

    -- A jurisdiction handoff has its own radio call, and several units breaking
    -- in the same exchange of fire are one event on the radio, not one each.
    if reason ~= 'jurisdiction' and FenixPursuit and FenixPursuit.announceRetreat then
        if lastAnnounceAt == 0 or (now - lastAnnounceAt) >= (c.announceCooldownMs or 15000) then
            lastAnnounceAt = now
            FenixPursuit.announceRetreat()
        end
    end
end

--- Mark a unit RELEASED: it is done with this pursuit. Its driver takes the
--- car away (when there is still a car and somebody to drive it), and
--- client.lua deletes the unit once it's out of sight, which frees the slot
--- for a fresh unit. Used for relief (still broken after regrouping) and for
--- jurisdiction handoffs. Idempotent; safe on an id this file has never seen.
function FenixMorale.release(vehNetID, reason)
    if vehNetID == nil or released[vehNetID] then return end
    reason = reason or 'released'
    released[vehNetID] = reason

    local now = GetGameTimer()
    local r = retreating[vehNetID]
    if not r then
        -- Released straight out of the chase (a handoff), so there is no
        -- retreat record with an officer list yet. The car's occupants are the
        -- ones that need driving away.
        r = { vehicle = nil, officers = {}, boarding = {} }
        local veh = unitVehicle(vehNetID, nil)
        if veh then
            r.vehicle = veh
            for seat = -1, GetVehicleMaxNumberOfPassengers(veh) - 1 do
                local ped = GetPedInVehicleSeat(veh, seat)
                if ped ~= 0 and not IsPedAPlayer(ped) and NetworkGetEntityIsNetworked(ped) then
                    r.officers[PedToNet(ped)] = ped
                end
            end
        end
        retreating[vehNetID] = r
    end
    r.phase = 'released'
    r.since = now
    r.reason = reason

    local veh = usableVehicle(vehNetID, r)
    if veh then
        -- Passengers stop shooting out of the windows; the driver gets the
        -- drive-away below.
        for _, ped in pairs(r.officers) do
            if DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true)
                and GetVehiclePedIsIn(ped, false) == veh and GetPedInVehicleSeat(veh, -1) ~= ped then
                ClearPedTasks(ped)
            end
        end
        startDriving(r, veh)
    end

    dbg(('unit %s released (%s)'):format(vehNetID, reason))
end

--- The first free seat for this officer that the car actually has and no
--- squadmate is already heading for. Driver first, so whoever reaches the car
--- first can take it away.
local function pickSeat(r, pedNetID, vehicle)
    local maxSeat = GetVehicleMaxNumberOfPassengers(vehicle) - 1
    for _, seat in ipairs({ -1, 0, 1, 2 }) do
        if seat <= maxSeat and IsVehicleSeatFree(vehicle, seat) then
            local taken = false
            for other, claimed in pairs(r.boarding) do
                if other ~= pedNetID and claimed == seat then
                    taken = true
                    break
                end
            end
            if not taken then return seat end
        end
    end
    return nil
end

--- One officer, one attempt to get back in the car. Returns true once done
--- (in a vehicle, or gave up and is staying on foot for this retreat).
local function tryBoard(r, pedNetID, ped, vehicle)
    if not DoesEntityExist(ped) or IsPedDeadOrDying(ped, true) then
        r.boarding[pedNetID] = nil
        return true
    end
    if IsPedInAnyVehicle(ped, false) then return true end
    if not vehicle then return true end

    -- Already on their way to a seat: leave the task alone. Re-issuing
    -- TaskEnterVehicle every tick restarts the approach each time and leaves
    -- the officer walking on the spot.
    if r.boarding[pedNetID] ~= nil and GetScriptTaskStatus(ped, TASK_ENTER_VEHICLE) ~= 7 then
        return false
    end

    local seat = pickSeat(r, pedNetID, vehicle)
    if seat == nil then
        -- No room left: stay on foot for this retreat.
        r.boarding[pedNetID] = nil
        return true
    end

    r.boarding[pedNetID] = seat
    TaskEnterVehicle(ped, vehicle, 8000, seat, 2.0, 1, 0)
    return false
end

--- End of the regroup timer: back into the fight if the unit is fit again,
--- otherwise released for relief. Handing a still-broken unit back used to
--- make it break again on the very next cycle, forever, holding a unit slot
--- that a fresh unit could have used.
local function finishRegroup(vehNetID, r)
    local list = {}
    for pedNetID, ped in pairs(r.officers) do
        list[#list + 1] = { pedNetID = pedNetID, ped = ped }
    end

    local losses, alive = tally(vehNetID, list)
    local original = math.max(1, originalCrew[vehNetID] or #list)
    local reason = (alive == 0) and 'no crew left'
        or brokenReason(losses, alive, original, GetPlayerWantedLevel(PlayerId()))

    if reason then
        dbg(('unit %s still broken after regrouping (%s), releasing for relief'):format(vehNetID, reason))
        FenixMorale.release(vehNetID, 'relief')
        return
    end

    dbg(('unit %s regrouped, back in the fight'):format(vehNetID))
    retreating[vehNetID] = nil
    lossesAtRejoin[vehNetID] = losses
    troubleSince[vehNetID] = nil
end

--- Advance every retreating unit one tick. Cheap: a pursuit has at most a
--- handful of units, and most cycles most of them are just waiting out the
--- regroup timer.
local function tickRetreats()
    local c = cfg()
    local now = GetGameTimer()

    for vehNetID, r in pairs(retreating) do
        -- Drop officers whose handle no longer names them before anything is
        -- tasked through it.
        for pedNetID, ped in pairs(r.officers) do
            if not officerPed(pedNetID, ped) then
                r.officers[pedNetID] = nil
                r.boarding[pedNetID] = nil
            end
        end

        if next(r.officers) == nil and not unitVehicle(vehNetID, r) then
            -- Car and crew are both gone: the unit was removed without anyone
            -- telling this file. Nothing left to drive or regroup.
            FenixMorale.clearUnit(vehNetID)

        elseif r.phase == 'fleeing' then
            -- Give the flee/cower task a few seconds to actually put distance
            -- down before asking anyone to stop and board a car.
            if (now - r.since) > 3000 then
                r.phase = 'entering'
                r.since = now
            end

        elseif r.phase == 'entering' then
            local veh = usableVehicle(vehNetID, r)
            local allDone = true
            for pedNetID, ped in pairs(r.officers) do
                if not tryBoard(r, pedNetID, ped, veh) then allDone = false end
            end

            if allDone or (now - r.since) > 15000 then
                if veh and startDriving(r, veh) then
                    r.phase = 'driving'
                else
                    r.phase = 'foot_hold'
                end
                r.since = now
            end

        elseif r.phase == 'driving' or r.phase == 'foot_hold' then
            if (now - r.since) >= ((c.regroupSeconds or 35) * 1000) then
                finishRegroup(vehNetID, r)
            end
        end
        -- 'released' has nothing left to advance: client.lua removes the unit.
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
    released = {}
end)

RegisterCommand('fenixmorale', function()
    local n = 0
    for _ in pairs(retreating) do n = n + 1 end
    print(('[FENIX-MORALE] %d unit(s) currently retreating/regrouping/released'):format(n))
    for vehNetID, r in pairs(retreating) do
        print(('  unit %s: %s, %.0fs ago (%s)')
            :format(vehNetID, tostring(r.phase), (GetGameTimer() - (r.since or 0)) / 1000.0, tostring(r.reason)))
    end
end, false)
