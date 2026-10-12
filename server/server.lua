-- POLICE JOB CHECKING LOGIC --
-- Goes through FenixFramework (server/framework.lua, loaded first): counts
-- real job holders when qb-core/qbx_core is running, 0 standalone -- the
-- only sane count with no job system to check against.

CreateThread(function()
    Wait(5000) -- Ensure clients are loaded first
    while true do
        local polCount = FenixFramework.GetOnlinePoliceCount()

        -- -1 source tells ALL clients connected to update their cops online count and do logic pertaining to it.
        TriggerClientEvent('fenix-police:updateCopsOnline', -1, polCount)

        -- Check every minute if new police online
        Wait(55000)
    end
end)




-- CLEANUP LOGIC --
-- src -> { wanted = bool, updatedAt = os.time() }, from each client's own
-- fenix-police:updateWantedStatus reports.
local playerWantedStatus = {}

-- [Upstate Mafia] AFTERMATH -- src -> os.time() until which that player's
-- client is running a field-revive/scene-hold sequence (client/client.lua's
-- beginAftermath/endAftermath). The wanted level clears the instant the
-- player is incapacitated, so without this the server had no way to tell
-- "no longer wanted because they're being revived" apart from "no longer
-- wanted, clean everything up" -- the cleanup broadcast below would despawn
-- the very officers kneeling over the body. An expiry rather than a flag: a
-- client that never sends the closing aftermathState(false) -- a crash, or
-- one that simply lies -- would otherwise hold its cleanup off for the rest
-- of the session.
local aftermathHolding = {}

-- The client caps one sequence at Config.Aftermath.holdAfterFailedMs from
-- the moment it starts; the extra minute covers the medic's walk and the
-- revive animation on top of that.
local function aftermathHoldSeconds()
    return math.floor(((Config.Aftermath or {}).holdAfterFailedMs or 240000) / 1000) + 60
end

local function holdingAftermath(src)
    local expires = aftermathHolding[src]
    if expires and expires > os.time() then return true end
    aftermathHolding[src] = nil
    return false
end

--- Wanted as far as this resource can tell: what the client last reported,
--- or the wanted level its player is syncing right now, whichever says yes.
--- The synced level is usually the fresher of the two.
local function isPlayerWanted(playerId)
    local id = tonumber(playerId)
    if not id then return false end
    local status = playerWantedStatus[id]
    if status and status.wanted then return true end
    return (GetPlayerWantedLevel(id) or 0) > 0
end

-- server/dispatch.lua reads this to keep a pursuit's own gunfire and crashes
-- from being reported as fresh civilian incidents.
if FenixDispatch then FenixDispatch.isPlayerWanted = isPlayerWanted end

-- SET_PED_COMBAT_ATTRIBUTES, SET_PED_FLEE_ATTRIBUTES, SET_PED_ACCURACY,
-- SET_PED_FIRING_PATTERN, SET_PED_RELATIONSHIP_GROUP_HASH, SET_DRIVER_ABILITY/
-- AGGRESSIVENESS and the TASK_* natives are not registered in the server Lua
-- environment -- calling them here throws "attempt to call a nil value".
-- Dispatch them to the client that owns the ped instead (see
-- client/combat_bridge.lua). Must target the owner only, not broadcast to -1:
-- the vehicle-chase profile re-issues TASK_VEHICLE_DRIVE_TO_COORD every
-- second, which is a real road-pathfinding request. Broadcasting it made
-- every nearby client (not just the owner) re-request pathfinding for the
-- same ped every tick, which blew through the engine's 20-slot
-- CNetworkRoadNodeWorldStateData pool and froze the game.
--
-- A ped that no client owns yet -- a crew member the server created a moment
-- ago usually isn't handed out instantly -- goes to `fallbackTarget`, the
-- player it was spawned for and the client most likely to own it by the time
-- this arrives. A ped that doesn't exist goes nowhere: sending it to -1
-- instead is exactly the broadcast described above.
local function dispatchCombatProfile(pedNetID, profile, fallbackTarget)
    local entity = NetworkGetEntityFromNetworkId(pedNetID)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return end

    local owner = NetworkGetEntityOwner(entity)
    if not owner or owner <= 0 then owner = fallbackTarget end
    if not owner then return end

    TriggerClientEvent('fenix-police:client:applyCombatProfile', owner, pedNetID, profile)
end

--- someoneWanted, allPlayersKnown. Not all known while any connected player
--- has yet to report -- a client still loading can't be assumed idle.
local function anyPlayerWanted()
    local someoneWanted, allKnown = false, true
    for _, playerId in ipairs(GetPlayers()) do
        if isPlayerWanted(playerId) then
            someoneWanted = true
        elseif not playerWantedStatus[tonumber(playerId)] then
            allKnown = false
        end
    end
    return someoneWanted, allKnown
end

-- The "everyone stand down" broadcast fires once, when the server goes from
-- someone wanted to nobody wanted. Re-firing it on every report while nobody
-- is wanted (each client reports once a second) runs handleEndWantedDelete on
-- every client every couple of seconds -- spawn gate shut, counters reset,
-- units deleted -- and a player who has only just gone wanted, before their
-- first report lands, loses their first units to it.
local wantedSinceLastCleanup = false

-- src -> true: left out of the last broadcast because their client was
-- holding an aftermath scene. They get theirs once the hold ends.
local cleanupOwed = {}

local function sendCleanup(id)
    -- The synced wanted level can be newer than the last report: someone
    -- who went wanted this second is not told to stand their units down.
    if (GetPlayerWantedLevel(id) or 0) > 0 then return end
    TriggerClientEvent('fenix-police:cleanupAllPolice', id)
end

local function cleanupIfNoPlayersWanted()
    local someoneWanted, allPlayersKnown = anyPlayerWanted()
    if someoneWanted then
        wantedSinceLastCleanup = true
        return
    end
    if not allPlayersKnown then return end

    if wantedSinceLastCleanup then
        wantedSinceLastCleanup = false
        for _, playerId in ipairs(GetPlayers()) do
            local id = tonumber(playerId)
            if holdingAftermath(id) then
                cleanupOwed[id] = true
            else
                sendCleanup(id)
            end
        end
    end

    for id in pairs(cleanupOwed) do
        if not holdingAftermath(id) then
            cleanupOwed[id] = nil
            sendCleanup(id)
        end
    end
end

RegisterNetEvent('fenix-police:aftermathState')
AddEventHandler('fenix-police:aftermathState', function(active)
    local src = source
    -- Metered on its own, not with the wanted-status reports that arrive
    -- every cycle: a hold refused for their sake lets the cleanup broadcast
    -- delete the officers mid-revive. An honest client sends a few a minute.
    if not FenixGuard.allow(src, 'aftermath', 30) then return end

    if active then
        aftermathHolding[src] = os.time() + aftermathHoldSeconds()
    else
        aftermathHolding[src] = nil
        cleanupIfNoPlayersWanted()
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    playerWantedStatus[src] = nil
    aftermathHolding[src] = nil
    cleanupOwed[src] = nil
    -- Deferred: the leaving player can still be listed by GetPlayers while
    -- this event runs, with no report on file any more, and an unreported
    -- player holds the broadcast back for everyone.
    SetTimeout(1000, cleanupIfNoPlayersWanted)
end)

-- [Upstate Mafia] Client diagnostics relay: client/ambient.lua mirrors its
-- debug trace and any director error here, so they can be read from the server
-- console when a client's F8 console isn't reachable. Print-only, one line per
-- player per second, truncated -- nothing a client sends here does anything
-- but log.
local lastClientDiag = {}
local clientDiagLines = {} -- last 50, for the fenixdiag console command
RegisterNetEvent('fenix-police:clientDiag', function(msg)
    local src = source
    if type(msg) ~= 'string' then return end
    local now = GetGameTimer()
    if lastClientDiag[src] and now - lastClientDiag[src] < 1000 then return end
    lastClientDiag[src] = now
    local line = ('[FENIX-CLIENT %d %s] %s'):format(src, os.date('%H:%M:%S'), msg:sub(1, 300))
    print(line)
    clientDiagLines[#clientDiagLines + 1] = line
    if #clientDiagLines > 50 then table.remove(clientDiagLines, 1) end
end)
AddEventHandler('playerDropped', function() lastClientDiag[source] = nil end)

-- Server console / RCON only (source 0): dumps the buffered relay lines.
RegisterCommand('fenixdiag', function(src)
    if src ~= 0 then return end
    if #clientDiagLines == 0 then print('[FENIX-CLIENT] nothing relayed yet') return end
    for _, line in ipairs(clientDiagLines) do print(line) end
end, true)

-- Clients may report every cycle, or only on a change plus a periodic
-- heartbeat: this keeps the latest, and the cleanup above keys off the
-- someone -> nobody transition, not off how often reports arrive.
--
-- Metered at twice the rate a client reporting every Config.scriptFrequency
-- sends. Any tighter and a server running a faster cycle has reports
-- refused, and a refused "no longer wanted" leaves that player counted as
-- wanted, holding everyone's cleanup back until a later one gets through.
local STATUS_PER_MINUTE = math.max(120,
    math.ceil(120000 / math.max(tonumber(Config.scriptFrequency) or 1000, 100)))

RegisterNetEvent('fenix-police:updateWantedStatus')
AddEventHandler('fenix-police:updateWantedStatus', function(isWanted)
    local src = source
    if not FenixGuard.allow(src, 'status', STATUS_PER_MINUTE) then return end

    playerWantedStatus[src] = {
        wanted = isWanted == true,
        updatedAt = os.time(),
    }

    cleanupIfNoPlayersWanted()

    -- The report and the synced wanted level travel separately, so "no
    -- longer wanted" can land while the server still sees the old level,
    -- which counts as wanted. Look again once the sync has caught up rather
    -- than on the next report -- a heartbeat away for a client that only
    -- reports changes.
    if isWanted ~= true and (GetPlayerWantedLevel(src) or 0) > 0 then
        SetTimeout(2000, cleanupIfNoPlayersWanted)
    end
end)

-- Server event to delete a ped by network ID
RegisterServerEvent('deleteSpawnedPed')
AddEventHandler('deleteSpawnedPed', function(pedNetID)
    local src = source
    if not FenixGuard.allow(src, 'delete') then return end

    local entity = FenixGuard.resolve(src, pedNetID, 'ped', 'deleteSpawnedPed')
    if entity then
        FenixGuard.release(pedNetID)
        DeleteEntity(entity)
    end
end)




-- Server event to delete a vehicle by network ID, this will check if anyone is in the vehicle first.
-- If a ped is in the vehicle we can assume it is a player, because this will not have been called until all officers assigned
-- to the vehicle were already deleted.
RegisterServerEvent('deleteSpawnedVehicle')
AddEventHandler('deleteSpawnedVehicle', function(vehNetID)
    local src = source
    if not FenixGuard.allow(src, 'delete') then return end

    -- The occupied-vehicle check that used to live here is now layer 1 of
    -- FenixGuard.resolve, and applies to every handler rather than just this
    -- one. A refusal here therefore means either "a player is in it" (the
    -- stolen-cruiser case this event already cared about) or one of the checks
    -- it never had. The client is told the same thing in both cases, because
    -- from its side the outcome is identical: this vehicle is not ours to
    -- remove, stop tracking it.
    local entity = FenixGuard.resolve(src, vehNetID, 'vehicle', 'deleteSpawnedVehicle')
    if not entity then
        TriggerClientEvent('deleteSpawnedVehicleResponseStolen', src, vehNetID)
        return
    end

    FenixGuard.release(vehNetID)
    DeleteEntity(entity)
end)




-- HELI / AIR UNIT FUNCTIONS --

-- Function to select a random air unit and its peds based on wanted level and spawn chance
local function getRandomAirUnit(spawnTable, currentWantedLevel)
    local candidates = {}

    -- Loop through each unit in the table returned by region.
    for _, unit in ipairs(spawnTable) do

        -- Check if the unit is applicable at the current wanted level and skip it if not.
        if currentWantedLevel >= unit.wantedLevel then
            -- If applicable create a table of candidates to select from randomly later. This is how the spawnChance variable
            -- is used. If picking a random value from a table that has 10 entries, and 9 of those entries are for the same car model
            -- then we have a 9 in 10 chance to spawn that model. 
            for _ = 1, unit.spawnChance do
                table.insert(candidates, unit)
            end
        end
    end

    if #candidates > 0 then

        -- Use a randomIndex to pick one item from the candidates table.
        local randomIndex = math.random(1, #candidates)
        local selectedUnit = candidates[randomIndex]
        local selectedPilots = {}
        local selectedPeds = {}

        -- Use the numPilots variable to spawn that number of pilots to go with the unit
        for _ = 1, selectedUnit.numPilots do
            -- Use a randomPedIndex to pick a ped from the table of possibilities.
            local randomPedIndex = math.random(1, #selectedUnit.pilots)
            table.insert(selectedPilots, selectedUnit.pilots[randomPedIndex])
        end
        
        -- Use the numPeds variable to spawn that number of peds to go with the unit
        for _ = 1, selectedUnit.numPeds do
            -- Use a randomPedIndex to pick a ped from the table of possibilities.
            local randomPedIndex = math.random(1, #selectedUnit.peds)
            table.insert(selectedPeds, selectedUnit.peds[randomPedIndex])
        end

        -- Return values in table format so you can call .unit or .pilots or .peds to access the selectedVehicle or the peds table later.
        return { unit = selectedUnit, pilots = selectedPilots, peds = selectedPeds }
    else
        return nil
    end
end




-- GROUND UNIT FUNCTIONS --

-- Function to select a random vehicle and its peds based on wanted level and spawn chance
local function getRandomVehicle(region, currentWantedLevel)
    local candidates = {}

    -- Loop through each vehicle in the table returned by region.
    for _, vehicle in ipairs(Config.vehiclesByRegion[region]) do
        -- Check if the vehicle is applicable at the current wanted level and skip it if not.
        if currentWantedLevel >= vehicle.wantedLevel then
            -- If applicable create a table of candidates to select from randomly later. This is how the spawnChance variable
            -- is used. If picking a random value from a table that has 10 entries, and 9 of those entries are for the same car model
            -- then we have a 9 in 10 chance to spawn that model. 
            for _ = 1, vehicle.spawnChance do
                table.insert(candidates, vehicle)
            end
        end
    end

    if #candidates > 0 then
        -- Use a randomIndex to pick one item from the candidates table.
        local randomIndex = math.random(1, #candidates)
        local selectedVehicle = candidates[randomIndex]
        local selectedPeds = {}
        
        -- Use the numPeds variable to spawn that number of peds to go with the car
        for _ = 1, selectedVehicle.numPeds do
            -- Use a randomPedIndex to pick a ped from the table of possibilities.
            local randomPedIndex = math.random(1, #selectedVehicle.peds)
            table.insert(selectedPeds, selectedVehicle.peds[randomPedIndex])
        end

        -- Return values in table format so you can call .vehicle or .peds to access the selectedVehicle or the peds table later.
        return { vehicle = selectedVehicle, peds = selectedPeds }
    else
        return nil
    end
end




-- LOADOUT AND COMBAT FUNCTIONS --

-- Function to select a weighted random item from a list
local function selectWeightedRandom(items)
    local totalWeight = 0
    for _, item in ipairs(items) do
        totalWeight = totalWeight + item.weight
    end

    local randomWeight = math.random() * totalWeight
    local currentWeight = 0

    for _, item in ipairs(items) do
        currentWeight = currentWeight + item.weight
        if randomWeight <= currentWeight then
            return item.name
        end
    end
end




-- ============================================================================
-- OFFICER COMBAT PROFILE (server side)
-- Mirror of the client helper in client/client.lua. Air/heli crews are spawned
-- server-side, so their initial profile has to be set here; the client re-applies
-- the full profile (including relationship group and provocation escalation)
-- every cycle in handleHeliChaseBehavior / handleAirChaseBehavior.
-- ============================================================================

local function combatEnabled()
    return Config.Combat ~= nil and Config.Combat.enabled ~= false
end

local function levelValue(tbl, wantedLevel, default)
    if type(tbl) ~= 'table' then return default end
    local value = tbl[wantedLevel]
    if value == nil then return default end
    return value
end

-- Returns true if this officer should be given a combat task on spawn.
-- `role` is 'air' for heli/aircraft crews (own firing pattern). `requester` is
-- the player the unit was spawned for (see dispatchCombatProfile).
local function applyOfficerCombatProfile(officer, wantedLevel, role, requester)
    if not DoesEntityExist(officer) then return false end

    local pedNetID = NetworkGetNetworkIdFromEntity(officer)

    if not combatEnabled() then
        dispatchCombatProfile(pedNetID, {
            accuracy = math.random(20, 40),
            firingPattern = 'FIRING_PATTERN_FULL_AUTO',
            combatAttributes = {{2, true}},
            relationshipGroup = 'HATES_PLAYER',
        }, requester)
        return true
    end

    local cfg = Config.Combat
    local hostile = math.random() < levelValue(cfg.engageChance, wantedLevel, 1.0)
        or wantedLevel >= (cfg.hostileFromLevel or 4)

    local profile = {
        shootRate = levelValue(cfg.shootRate, wantedLevel, 100),
        combatAbility = levelValue(cfg.combatAbility, wantedLevel, 1),
        combatAttributes = {
            {24, false}, -- cleared wherever the base game sets an explicit shoot rate
            {2, wantedLevel >= (cfg.drivebyFromLevel or 4)},
            {46, hostile},
            {3, false}, -- never bail out of the aircraft
        },
    }

    local accuracy = levelValue(cfg.accuracy, wantedLevel, nil)
    if accuracy then
        profile.accuracy = math.random(accuracy[1], accuracy[2])
    end

    if role == 'air' then
        profile.firingPattern = cfg.firingPatternHeli or 'FIRING_PATTERN_BURST_FIRE_HELI'
    elseif wantedLevel >= (cfg.fullAutoFromLevel or 5) then
        profile.firingPattern = cfg.firingPatternAuto or 'FIRING_PATTERN_FULL_AUTO'
    else
        profile.firingPattern = cfg.firingPatternBurst or 'FIRING_PATTERN_BURST_FIRE'
    end

    -- Only claim the hostile group here. The passive group is created client-side
    -- (AddRelationshipGroup / SetRelationshipBetweenGroups are client natives),
    -- so leaving the default group until the client's first cycle is correct.
    if hostile then
        profile.relationshipGroup = cfg.relationshipHostile or 'HATES_PLAYER'
    end

    dispatchCombatProfile(pedNetID, profile, requester)

    return hostile
end


-- Function to give a loadout to a ped.
-- MUST be called while the ped is still ON FOOT (before seating).
-- GiveWeaponToPed does not reliably sync to clients when the ped is already in a vehicle.
local function givePedLoadout(ped, loadout)
    if not DoesEntityExist(ped) then return end

    -- Primary weapon — always given and set as the active weapon.
    local primaryWeapon = selectWeightedRandom(loadout.primaryWeapons)
    local primaryHash = GetHashKey(primaryWeapon)
    GiveWeaponToPed(ped, primaryHash, 999, false, true)
    SetCurrentPedWeapon(ped, primaryHash, true)

    -- Optional secondary weapon (holstered, primary stays active)
    if #loadout.secondaryWeapons > 0 and math.random() < loadout.secondaryChance then
        local secondaryWeapon = selectWeightedRandom(loadout.secondaryWeapons)
        GiveWeaponToPed(ped, GetHashKey(secondaryWeapon), 999, false, false)
    end

    if math.random() < loadout.armorChance then
        SetPedArmour(ped, loadout.armorValue)
    end

    if math.random() < loadout.helmetChance then
        SetPedPropIndex(ped, 0, loadout.helmetModel, 0, true)
    end
end




-- SPAWNING FUNCTIONS --




-- GROUND UNITS --
RegisterNetEvent('spawnPoliceUnitNet')
AddEventHandler('spawnPoliceUnitNet', function(wantedLevel, _, regionCode, spawnPoint, spawnHeading)
    local src = source
    -- Every way out of here answers the client. Its pending-spawn counter only
    -- comes back down on a reply, and at five in flight it stops asking for
    -- ground units for the rest of the pursuit.
    local function fail() TriggerClientEvent('spawnPoliceUnitNetResponse', src, nil, nil) end

    if not FenixGuard.allow(src, 'spawn') then return fail() end

    local level = math.floor(tonumber(wantedLevel) or 0)
    if level < 1 or type(spawnPoint) ~= 'vector3' then return fail() end

    -- A region with no spawn list of its own -- a custom Config.Jurisdiction
    -- zone, say -- would throw on ipairs(nil) in getRandomVehicle and never
    -- answer.
    local regions = Config.vehiclesByRegion or {}
    if type(regionCode) ~= 'string' or not regions[regionCode] then
        regionCode = regions.losSantos and 'losSantos' or next(regions)
    end
    if not regionCode then return fail() end

    -- Pick the vehicle to choose to spawn for this region, vehicle determines which peds spawn with it, and the peds determine combat behavior and weapons.
    -- pcall: an entry missing its spawnChance or peds would otherwise throw
    -- here and the request would never be answered.
    local ok, selectedEntry = pcall(getRandomVehicle, regionCode, level)
    if not ok then
        print(('[fenix-police] Config.vehiclesByRegion.%s: %s'):format(regionCode, tostring(selectedEntry)))
        return fail()
    end
    if not selectedEntry then
        if Config.isDebug then print('No suitable vehicle found for the given wanted level.') end
        return fail()
    end

    -- Ground vehicles/peds are spawned client-side. In this server/runtime,
    -- server-side ped creation can leave valid police vehicles with no driver.
    -- The client can create the vehicle and its crew atomically, verify the
    -- driver seat, and start pursuit without an ownership race.
    -- Ground units are created client-side, so the server cannot record
    -- them at creation the way it does for helicopters and planes. Instead it
    -- issues a single-use ticket with the authorisation; the client quotes it
    -- back with the entities it made, and only then are those entities
    -- recorded as belonging to this player. A client can therefore only ever
    -- register entities the server just told it to create.
    local ticket = FenixGuard.issueTicket(src)
    TriggerClientEvent('fenix-police:spawnPoliceUnitClient', src, selectedEntry.vehicle, selectedEntry.peds, spawnPoint, spawnHeading, ticket)
end)


-- [Upstate Mafia] Ambient-to-pursuit promotion. A patrol/convoy scene the
-- client already spawned (client/ambient.lua) is client-local and
-- non-networked -- it isn't a pursuit unit, and FenixGuard has no record of
-- it. When the player goes wanted near one, the client networks it in place
-- (NetworkRegisterEntityAsNetworked, see PromoteAmbientUnit in client.lua)
-- rather than deleting it and spawning a fresh unit, then needs the same
-- ticket handshake spawnPoliceUnitNet above uses so the existing
-- fenix-police:registerSpawnedUnit handler (server/guard.lua) will actually
-- claim it. No vehicle/ped selection here -- unlike a fresh spawn, the
-- entities already exist; this only proves the request came from a real
-- client under the resource's own rate limit.
RegisterNetEvent('fenix-police:server:promoteAmbientUnit')
AddEventHandler('fenix-police:server:promoteAmbientUnit', function()
    local src = source
    if not FenixGuard.allow(src, 'spawn') then return end

    local ticket = FenixGuard.issueTicket(src)
    TriggerClientEvent('fenix-police:promoteAmbientUnitTicket', src, ticket)
end)




-- HELI / AIR SPAWN REQUESTS --

-- Which of Config.polHelis / milHelis / milPlanes a request draws from: the
-- same choice maintainPoliceUnits() in client/client.lua makes from what the
-- player is sitting in (a plane: military planes and no helicopters; a
-- helicopter: military helicopters and military planes; anything else or on
-- foot: police helicopters and no planes), made from the server's own view
-- of that player. Taking the table from the request instead lets any client
-- spawn any model with any crew, and a spawnChance or numPeds of a billion
-- hangs the server building the candidate list. nil = none of this kind is
-- sent.
local function airSpawnTableFor(ped, kind)
    local veh = GetVehiclePedIsIn(ped, false)
    local vehType = (veh and veh ~= 0) and GetVehicleType(veh) or nil
    if kind == 'heli' then
        if vehType == 'plane' then return nil end
        if vehType == 'heli' then return Config.milHelis end
        return Config.polHelis
    end
    if vehType == 'plane' or vehType == 'heli' then return Config.milPlanes end
    return nil
end

-- client.lua's getRandomPointInRange offsets X and Y independently, so a
-- spawn point can sit anywhere in a square around the player -- a corner is
-- maxDistance * 1.41 out -- and minHeight..maxHeight above them. Checked per
-- axis to match, with slack for the player moving while the request was in
-- flight.
local AIR_SPAWN_SLACK = 100.0

local function airSpawnPointPlausible(spawnPoint, here, maxDistance, maxHeight)
    return math.abs(spawnPoint.x - here.x) <= maxDistance + AIR_SPAWN_SLACK
        and math.abs(spawnPoint.y - here.y) <= maxDistance + AIR_SPAWN_SLACK
        and math.abs(spawnPoint.z - here.z) <= maxHeight + AIR_SPAWN_SLACK
end

--- The checks that need nothing from the rate limiter. Returns wantedLevel,
--- spawnTable, the first unit pick and the requester's coords, or nil when
--- there is nothing to send. Kept ahead of FenixGuard.allow on purpose: at a
--- wanted level with no air unit configured for it (two stars, by default)
--- the client asks again every cycle, and those answers must not use up the
--- spawn budget ground units share.
local function prepareAirRequest(src, kind, wantedLevel, spawnPoint)
    local level = math.floor(tonumber(wantedLevel) or 0)
    if level < 1 or type(spawnPoint) ~= 'vector3' then return nil end
    if level > 5 then level = 5 end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end

    local spawnTable = airSpawnTableFor(ped, kind)
    if not spawnTable then return nil end

    -- pcall: a malformed config entry still has to end in a reply.
    local ok, pick = pcall(getRandomAirUnit, spawnTable, level)
    if not ok or not pick then return nil end

    return level, spawnTable, pick, GetEntityCoords(ped)
end

local function deleteIfExists(entity)
    if entity and entity ~= 0 and DoesEntityExist(entity) then DeleteEntity(entity) end
end

-- GTA heading (degrees, 0 = north, counter-clockwise) facing `to` from `from`.
local function headingTowards(from, to)
    return math.deg(math.atan(-(to.x - from.x), to.y - from.y)) % 360.0
end

-- Server-side CreatePed/CreateVehicleServerSetter can hand back a handle a
-- moment before the entity exists. Calling CreatePed again on every pass of
-- a wait loop turns one slow ped into up to ten, most of them dropping out of
-- the sky never seated and never cleaned up.
local function awaitEntity(entity)
    if not entity or entity == 0 then return false end
    local waited = 0
    while not DoesEntityExist(entity) and waited < 3000 do
        Wait(50)
        waited = waited + 50
    end
    return DoesEntityExist(entity)
end

--- Runs one heli/plane spawn to completion, and always answers the client.
--- `build(spawned)` does the work and returns the vehicle's net ID and its
--- crew's, or nil. Everything it creates goes through `spawned`, which waits
--- for the entity to exist and moves it into the requester's routing bucket
--- (otherwise a player in an instance is chased by a helicopter only the
--- default world can see). On nil, a Lua error, or the requester leaving
--- mid-spawn, everything created is deleted and the reply is nil, nil.
---
--- Without a reply the client's pending-spawn counter never comes back down,
--- and at five it stops asking: a handful of failures would ground air
--- support for the rest of the pursuit.
local function runAirSpawn(src, responseEvent, build)
    local created = {}
    local bucket = GetPlayerRoutingBucket(src)

    local function spawned(entity)
        created[#created + 1] = entity
        if not awaitEntity(entity) then return nil end
        if bucket and bucket ~= 0 then SetEntityRoutingBucket(entity, bucket) end
        return entity
    end

    local ok, vehNetID, officers = pcall(build, spawned)
    if not ok then
        print(('[fenix-police] %s for %s failed: %s'):format(responseEvent, tostring(src), tostring(vehNetID)))
    end

    if not ok or not vehNetID or not GetPlayerName(src) then
        for i = #created, 1, -1 do deleteIfExists(created[i]) end
        TriggerClientEvent(responseEvent, src, nil, nil)
        return
    end

    -- Anything made along the way that didn't end up in the unit -- a handle
    -- that only came into existence after awaitEntity gave up on it -- goes.
    local keep = { [vehNetID] = true }
    for _, pedNetID in ipairs(officers) do keep[pedNetID] = true end
    for _, entity in ipairs(created) do
        if entity and entity ~= 0 and DoesEntityExist(entity)
            and not keep[NetworkGetNetworkIdFromEntity(entity)] then
            DeleteEntity(entity)
        end
    end

    -- Helicopters and planes are created here, on the server, so ownership is
    -- recorded directly at the point of creation -- no ticket round-trip is
    -- needed and there is nothing for a client to assert. This is what the
    -- ground path has to reconstruct with FenixGuard.issueTicket.
    FenixGuard.claim(src, vehNetID, 'vehicle')
    for _, pedNetID in ipairs(officers) do
        FenixGuard.claim(src, pedNetID, 'ped')
    end

    -- Return the netIDs to the client
    TriggerClientEvent(responseEvent, src, vehNetID, officers)
end

--- The checks every air request makes once it is going to cost something.
--- Returns true to go ahead.
local function airRequestAllowed(src, what, spawnPoint, here, maxDistance, maxHeight)
    if not FenixGuard.allow(src, 'spawn') then return false end

    if not airSpawnPointPlausible(spawnPoint, here, maxDistance, maxHeight) then
        FenixGuard.refuse(src, what, 'spawn point is nowhere near the requester')
        return false
    end

    -- Server-created units count against the same per-player ceiling the
    -- ground registration path has always enforced.
    if FenixGuard.ownedCount(src) >= FenixGuard.ownedCap() then
        if Config.isDebug then print(('[fenix-police] %s for %s refused: owned-entity cap'):format(what, tostring(src))) end
        return false
    end

    return true
end




-- HELI UNITS --
-- The trailing spawn table older clients still send is ignored; see
-- airSpawnTableFor.
RegisterNetEvent('spawnPoliceHeliNet')
AddEventHandler('spawnPoliceHeliNet', function(wantedLevel, _, spawnPoint)
    local src = source
    local function fail() TriggerClientEvent('spawnPoliceHeliNetResponse', src, nil, nil) end

    local level, spawnTable, firstPick, here = prepareAirRequest(src, 'heli', wantedLevel, spawnPoint)
    if not level then return fail() end
    if not airRequestAllowed(src, 'heli spawn', spawnPoint, here,
        Config.maxHeliSpawnDistance or 500.0, Config.maxHeliSpawnHeight or 200.0) then
        return fail()
    end

    local spawnHeading = headingTowards(spawnPoint, here)

    runAirSpawn(src, 'spawnPoliceHeliNetResponse', function(spawned)
        local seatIndex = -1

        -- Variable will be set true as soon as a vehicle has a driver. I'm less worried about a crew member not warping in properly.
        local vehicleCrewed = false
        local hasDriverCount = 0
        local vehNetID = nil
        local officers = {}
        local selectedEntry = firstPick

        while (not vehicleCrewed) and hasDriverCount < Config.hasDriverWaitCount do

            -- Pick the vehicle to choose to spawn for this region, vehicle determines which peds spawn with it, and the peds determine combat behavior and weapons.
            -- The first pass uses the pick prepareAirRequest already made.
            selectedEntry = selectedEntry or getRandomAirUnit(spawnTable, level)
            if not selectedEntry then
                if Config.isDebug then print('No suitable heli found for the given wanted level.') end
                return nil
            end
            local vehicleHash = GetHashKey(selectedEntry.unit.model)

            local vehicle = spawned(CreateVehicleServerSetter(vehicleHash, 'heli', spawnPoint.x, spawnPoint.y, spawnPoint.z, spawnHeading))
            if not vehicle then
                if Config.isDebug then print('Spawning '..selectedEntry.unit.model.. ' failed.') end
                return nil
            end
            vehNetID = NetworkGetNetworkIdFromEntity(vehicle)

            -- [Upstate Mafia] Was SetEntityDistanceCullingRadius(vehicle, 10000.0).
            -- citizenfx/fivem#1828: a large culling radius on a server-created
            -- entity, combined with a client-issued task (exactly this heli's
            -- TaskHeliChase), is the reported trigger for OneSync silently
            -- teleporting the entity back to its spawn point or dropping its task
            -- once another player comes near it. A CitizenFX contributor's answer
            -- in that thread is blunt: "you should not ever use that option."
            -- Default culling is already enough to keep a heli loaded for the one
            -- player it's actively chasing.

            -- [Upstate Mafia patch] Unlock doors + set statebag so qbx_vehiclekeys skips auto-lock
            SetVehicleDoorsLocked(vehicle, 1)  -- 1 = unlocked
            Entity(vehicle).state:set('doorslockstate', 1, true)  -- synced statebag

            officers = {}

            -- [Upstate Mafia patch] Wait for heli entity to fully initialise before seating peds
            Wait(500)

            -- Spawn pilots
            for _, pedModel in ipairs(selectedEntry.pilots) do
                local pedHash = GetHashKey(pedModel)

                -- Spawn ped at the heli (not 20 units away). One that never
                -- appears is handled exactly like one that won't sit down.
                local officer = spawned(CreatePed(4, pedHash, spawnPoint.x, spawnPoint.y, spawnPoint.z + 1.0, spawnHeading, true, true))
                local seated = false
                if not officer then
                    if Config.isDebug then print('Spawning pilot '..pedModel.. ' failed.') end
                else
                    -- SetEntityDistanceCullingRadius removed -- see the note above the
                    -- heli's own creation, same citizenfx/fivem#1828 concern.
                    Wait(200)

                    -- Give weapon BEFORE seating so it persists through vehicle-entry state changes.
                    GiveWeaponToPed(officer, GetHashKey('weapon_combatpistol'), 999, false, true)
                    SetCurrentPedWeapon(officer, GetHashKey('weapon_combatpistol'), true)

                    -- Try multiple seating methods (same approach as ground units)
                    for attempt = 1, 20 do
                        SetPedIntoVehicle(officer, vehicle, seatIndex)
                        Wait(100)
                        local pedInSeat = GetPedInVehicleSeat(vehicle, seatIndex)
                        if pedInSeat and pedInSeat ~= 0 then
                            seated = true
                            break
                        end
                        TaskWarpPedIntoVehicle(officer, vehicle, seatIndex)
                        Wait(150)
                        pedInSeat = GetPedInVehicleSeat(vehicle, seatIndex)
                        if pedInSeat and pedInSeat ~= 0 then
                            seated = true
                            break
                        end
                        if Config.isDebug and attempt % 5 == 0 then
                            print(('Heli pilot seat attempt %d for %s vehNetID=%s seat=%d'):format(attempt, selectedEntry.unit.model, tostring(vehNetID), seatIndex))
                        end
                    end
                end

                if not seated then
                    if Config.isDebug then print('Pilot FAILED to seat in ' .. selectedEntry.unit.model .. ' vehNetID = ' .. tostring(vehNetID) .. ' seat = ' .. seatIndex .. ', deleting ped') end
                    deleteIfExists(officer)
                    if seatIndex == -1 then
                        -- Driver failed, no point continuing
                        break
                    end
                else
                    seatIndex = seatIndex + 1
                    local pedNetID = NetworkGetNetworkIdFromEntity(officer)
                    if Config.isDebug then print('NET pilot ' ..pedModel .. ' SEATED with pedNetID = ' ..pedNetID .. ' for vehNetID = ' .. tostring(vehNetID)) end
                    if DoesEntityExist(officer) then
                        -- NOTE: weapon was already given before the seating loop (above).
                        -- Giving again here tops up ammo and forces it into hand in case
                        -- the seating state cleared the active-weapon slot.
                        GiveWeaponToPed(officer, GetHashKey('weapon_combatpistol'), 999, false, true)
                        SetCurrentPedWeapon(officer, GetHashKey('weapon_combatpistol'), true)
                        -- Combat/task setup for heli pilot.
                        dispatchCombatProfile(pedNetID, {
                            combatAttributes = {{52, true}, {53, true}}, -- can vehicle attack / use mounted weapons
                            fleeAttributes = {0, false},
                            driverAbility = 1.0,
                            heliChaseTarget = src,
                        }, src)
                        -- Accuracy / firing pattern / hostility scale with wanted level.
                        applyOfficerCombatProfile(officer, level, 'air', src)
                    end
                    table.insert(officers, pedNetID)
                    vehicleCrewed = true
                end

                if not vehicleCrewed then
                    break
                end
            end

            -- Spawn crew peds (only if we have a pilot)
            if vehicleCrewed then
                for _, pedModel in ipairs(selectedEntry.peds) do
                    local pedHash = GetHashKey(pedModel)

                    local officer = spawned(CreatePed(4, pedHash, spawnPoint.x, spawnPoint.y, spawnPoint.z + 1.0, spawnHeading, true, true))
                    if not officer then
                        -- One gunner short, not a reason to scrap a crewed heli.
                        if Config.isDebug then print('Spawning crew '..pedModel.. ' failed.') end
                    else
                        -- SetEntityDistanceCullingRadius removed -- see the note above the
                        -- heli's own creation, same citizenfx/fivem#1828 concern.
                        Wait(200)

                        -- Give loadout BEFORE seating so weapons persist through vehicle-entry state.
                        givePedLoadout(officer, Config.loadouts[selectedEntry.unit.loadout])

                        local seated = false
                        for attempt = 1, 20 do
                            SetPedIntoVehicle(officer, vehicle, seatIndex)
                            Wait(100)
                            local pedInSeat = GetPedInVehicleSeat(vehicle, seatIndex)
                            if pedInSeat and pedInSeat ~= 0 then
                                seated = true
                                break
                            end
                            TaskWarpPedIntoVehicle(officer, vehicle, seatIndex)
                            Wait(150)
                            pedInSeat = GetPedInVehicleSeat(vehicle, seatIndex)
                            if pedInSeat and pedInSeat ~= 0 then
                                seated = true
                                break
                            end
                            if Config.isDebug and attempt % 5 == 0 then
                                print(('Heli crew seat attempt %d for %s vehNetID=%s seat=%d'):format(attempt, selectedEntry.unit.model, tostring(vehNetID), seatIndex))
                            end
                        end

                        if not seated then
                            if Config.isDebug then print('Crew FAILED to seat in ' .. selectedEntry.unit.model .. ' vehNetID = ' .. tostring(vehNetID) .. ' seat = ' .. seatIndex .. ', deleting ped') end
                            DeleteEntity(officer)
                        else
                            seatIndex = seatIndex + 1
                            local pedNetID = NetworkGetNetworkIdFromEntity(officer)
                            if Config.isDebug then print('NET crew ' ..pedModel .. ' SEATED with pedNetID = ' ..pedNetID .. ' for vehNetID = ' .. tostring(vehNetID)) end
                            -- Loadout already given before seating; re-apply to ensure active weapon is set
                            givePedLoadout(officer, Config.loadouts[selectedEntry.unit.loadout])
                            -- Combat/task setup for heli crew.
                            dispatchCombatProfile(pedNetID, { fleeAttributes = {0, false} }, src)
                            -- Crew only open fire once hostile for this wanted level; below
                            -- that they ride along and the heli just shadows the player.
                            local crewHostile = applyOfficerCombatProfile(officer, level, 'air', src)
                            if crewHostile then
                                dispatchCombatProfile(pedNetID, { combatTarget = src }, src)
                            end
                            table.insert(officers, pedNetID)
                        end
                    end
                end
            end

            if not vehicleCrewed then
                if Config.isDebug then print('Vehicle ' .. selectedEntry.unit.model .. ' failed to be crewed, deleting vehNetID = ' .. vehNetID .. ' and starting over ') end
                deleteIfExists(vehicle)
                vehNetID = nil
                selectedEntry = nil
                Wait(100)
                -- Add 1 and try again
                hasDriverCount = hasDriverCount + 1
            end
        end

        return vehNetID, officers
    end)
end)




-- AIR UNITS --
-- Same request shape and checks as the heli handler above.
RegisterNetEvent('spawnPoliceAirNet')
AddEventHandler('spawnPoliceAirNet', function(wantedLevel, _, spawnPoint)
    local src = source
    local function fail() TriggerClientEvent('spawnPoliceAirNetResponse', src, nil, nil) end

    local level, spawnTable, firstPick, here = prepareAirRequest(src, 'plane', wantedLevel, spawnPoint)
    if not level then return fail() end
    if not airRequestAllowed(src, 'plane spawn', spawnPoint, here,
        Config.maxAirSpawnDistance or 600.0, Config.maxAirSpawnHeight or 300.0) then
        return fail()
    end

    local spawnHeading = headingTowards(spawnPoint, here)

    runAirSpawn(src, 'spawnPoliceAirNetResponse', function(spawned)
        local seatIndex = -1

        -- Variable will be set true as soon as a vehicle has a driver. I'm less worried about a crew member not warping in properly.
        local vehicleCrewed = false
        local hasDriverCount = 0
        local vehNetID = nil
        local officers = {}
        local selectedEntry = firstPick

        while (not vehicleCrewed) and hasDriverCount < Config.hasDriverWaitCount do

            -- Pick the vehicle to choose to spawn for this region, vehicle determines which peds spawn with it, and the peds determine combat behavior and weapons.
            -- The first pass uses the pick prepareAirRequest already made.
            selectedEntry = selectedEntry or getRandomAirUnit(spawnTable, level)
            if not selectedEntry then
                if Config.isDebug then print('No suitable air unit found for the given wanted level.') end
                return nil
            end
            local vehicleHash = GetHashKey(selectedEntry.unit.model)

            local vehicle = spawned(CreateVehicleServerSetter(vehicleHash, 'plane', spawnPoint.x, spawnPoint.y, spawnPoint.z, spawnHeading))
            if not vehicle then
                if Config.isDebug then print('Spawning '..selectedEntry.unit.model.. ' failed.') end
                return nil
            end
            vehNetID = NetworkGetNetworkIdFromEntity(vehicle)

            -- SetEntityDistanceCullingRadius removed -- see the note in
            -- spawnPoliceHeliNet above, same citizenfx/fivem#1828 concern.

            officers = {}

            for _, pedModel in ipairs(selectedEntry.pilots) do


                local pedHash = GetHashKey(pedModel)


                local warpCount = 0
                local pedInSeat = nil
                while (not pedInSeat or pedInSeat == 0) and warpCount < Config.warpWaitCount do

                    -- A ped that never appears counts as one failed warp.
                    local officer = spawned(CreatePed(4, pedHash, spawnPoint.x+20, spawnPoint.y+20, spawnPoint.z, spawnHeading, true, true))
                    if not officer then
                        if Config.isDebug then print('Spawning '..pedModel.. ' failed.') end
                        warpCount = warpCount + 1
                    else
                        -- SetEntityDistanceCullingRadius removed -- see the note in
                        -- spawnPoliceHeliNet above, same citizenfx/fivem#1828 concern.
                        Wait(50)
                        TaskWarpPedIntoVehicle(officer, vehicle, seatIndex)
                        Wait(50)
                        pedInSeat = GetPedInVehicleSeat(vehicle, seatIndex)
                        local waitCount = 0
                        while (not pedInSeat or pedInSeat == 0) and waitCount < Config.spawnWaitCount do
                            -- Try warping them again
                            if Config.isDebug then print('Officer failed to warp into ' .. selectedEntry.unit.model .. ' vehNetID = ' .. vehNetID .. ' seat = ' .. seatIndex .. ' trying again ' .. waitCount) end
                            TaskWarpPedIntoVehicle(officer, vehicle, seatIndex)
                            Wait(20)
                            pedInSeat = GetPedInVehicleSeat(vehicle, seatIndex)
                            waitCount = waitCount + 1
                        end

                        if (not pedInSeat or pedInSeat == 0) then
                            -- Delete the officer and start over with a fresh one until they warp into the vehicle properly.
                            if Config.isDebug then print('Officer failed to warp into ' .. selectedEntry.unit.model .. ' vehNetID = ' .. vehNetID .. ' too many times, deleting entity and starting over ') end
                            DeleteEntity(officer)
                            Wait(100)
                            warpCount = warpCount + 1
                        else
                            -- Put this here so if a ped fails to be warped in it will still fill the driver seat first.
                            seatIndex = seatIndex + 1 -- Increase seat index so each seat is filled from driver, to passenger, to rear passengers etc.

                            -- Network setup for pilot
                            local pedNetID = NetworkGetNetworkIdFromEntity(officer)
                            if Config.isDebug then print('NET ped ' ..pedModel .. ' spawned with pedNetID = ' ..pedNetID .. ' for vehNetID = ' .. vehNetID) end

                            -- Combat/task setup for air pilot.
                            if DoesEntityExist(officer) then
                                GiveWeaponToPed(officer, GetHashKey('weapon_combatpistol'), 999, false, false)
                                dispatchCombatProfile(pedNetID, {
                                    combatAttributes = {{52, true}, {53, true}, {85, true}, {86, true}}, -- vehicle attack / mounted weapons / prefer air targets / dogfighting
                                    fleeAttributes = {0, false},
                                    driverAbility = 1.0,
                                    planeChaseTarget = src,
                                }, src)
                                -- Accuracy / firing pattern / hostility scale with wanted level.
                                applyOfficerCombatProfile(officer, level, 'air', src)
                            end

                            -- Add pilot to table to return
                            table.insert(officers, pedNetID)

                            -- We spawned a ped into the vehicle, ensure vehicleCrewed is true.
                            vehicleCrewed = true
                        end
                    end

                end

                if not vehicleCrewed then
                    -- Should break the ped loop and move straight to deleting the vehicle. In my experience if the first one fails to warp they all will.
                    break
                end

            end

            if not vehicleCrewed then
                if Config.isDebug then print('Vehicle ' .. selectedEntry.unit.model .. ' failed to be crewed, deleting vehNetID = ' .. vehNetID .. ' and starting over ') end
                deleteIfExists(vehicle)
                vehNetID = nil
                selectedEntry = nil
                Wait(100)
                -- Add 1 and try again
                hasDriverCount = hasDriverCount + 1
            end

        end

        return vehNetID, officers
    end)
end)


-- Keep a spawned police vehicle unlocked so cops can re-enter after a foot chase.
-- qbx_vehiclekeys monitors unoccupied vehicles and auto-locks them; re-applying the
-- unlocked state here (triggered by the client each cycle during re-entry) fights that.
RegisterNetEvent('fenix-police:unlockOfficerVehicle')
AddEventHandler('fenix-police:unlockOfficerVehicle', function(vehNetID)
    local src = source
    if not FenixGuard.allow(src, 'unlock') then return end

    -- Was: unlock any vehicle on the server by network id. On a QBCore server
    -- that is a theft primitive.
    local vehicle = FenixGuard.resolve(src, vehNetID, 'vehicle', 'unlockOfficerVehicle')
    if not vehicle then return end

    SetVehicleDoorsLocked(vehicle, 1)
    Entity(vehicle).state:set('doorslockstate', 1, true)
end)


-- [Upstate Mafia] Server-side re-arm: client detects unarmed cop and asks server to fix it.
-- Server owns the entities, so GiveWeaponToPed works reliably here.
-- loadoutKey is optional — falls back to a pistol if not provided or not found.
RegisterNetEvent('fenix-police:rearmOfficer')
AddEventHandler('fenix-police:rearmOfficer', function(pedNetID, loadoutKey)
    local src = source
    if not FenixGuard.allow(src, 'rearm') then return end

    -- Was: give a weapon to any ped by network id, a player's included. Free
    -- guns for anybody who can send an event.
    local officer = FenixGuard.resolve(src, pedNetID, 'ped', 'rearmOfficer')
    if not officer then return end

    -- The loadout key indexes a config table, so an unknown key has to fall
    -- through to the default rather than being used as-is.
    local loadout = (type(loadoutKey) == 'string') and Config.loadouts[loadoutKey] or nil
    if loadout then
        givePedLoadout(officer, loadout)
    else
        GiveWeaponToPed(officer, GetHashKey('weapon_pistol'), 999, false, true)
        SetCurrentPedWeapon(officer, GetHashKey('weapon_pistol'), true)
    end
end)


-- [Upstate Mafia] TRAFFIC CITATIONS --
--
-- The money half of Config.TicketSystem. The client reports that a roadside stop
-- completed and at what wanted level; everything that costs the player anything
-- is decided here. A client that sends level 99 gets the same fine as one that
-- sends 1, because the level is clamped to the configured ceiling before it is
-- used as an index.
RegisterNetEvent('fenix-police:server:issueTicket')
AddEventHandler('fenix-police:server:issueTicket', function(level)
    local src = source
    local c = Config.TicketSystem
    if not c or not c.enabled then return end

    -- A citation needs a stop to be a citation: the player wanted, and one of
    -- their own officers standing at the car. Without that this is a
    -- complied_with_police honor hook on demand, as often as a client cares to
    -- send it.
    if not FenixGuard.allow(src, 'ticket', 3) then return end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 or not isPlayerWanted(src)
        or not FenixGuard.officerNear(src, GetEntityCoords(ped), (c.windowDistance or 3.5) + 6.0) then
        FenixGuard.refuse(src, 'citation', 'no traffic stop in progress')
        -- Still an outcome for the client to show: a warning, nothing charged.
        TriggerClientEvent('fenix-police:client:ticketIssued', src, 0, true)
        return
    end

    local fine = c.fine or {}
    if not fine.enabled then
        -- Warning-only server: still answer, so the client shows an outcome
        -- rather than waiting out its timeout on a reply that never comes.
        TriggerClientEvent('fenix-police:client:ticketIssued', src, 0, true)
        return
    end

    -- Clamp before indexing. Levels past the end of the list use the last entry,
    -- so `amounts` only has to be as long as maxWantedLevel.
    local amounts = fine.amounts or { 750 }
    level = math.floor(tonumber(level) or 1)
    if level < 1 then level = 1 end
    if level > (c.maxWantedLevel or 1) then level = c.maxWantedLevel or 1 end
    local amount = amounts[level] or amounts[#amounts] or 750
    if amount <= 0 then
        TriggerClientEvent('fenix-police:client:ticketIssued', src, 0, true)
        return
    end

    -- FenixFramework.RemoveMoney/GetHeldMoney go through qb-core/qbx_core
    -- when running; standalone (no framework, no money system to charge
    -- against) they always report false/0, so the ticket is still issued
    -- but never actually paid -- see the allowUnpaid handling below.
    local account = fine.account or 'bank'
    local reason  = fine.reason or 'traffic-citation'
    local paid    = FenixFramework.RemoveMoney(src, account, amount, reason)

    if not paid and fine.fallbackToCash ~= false and account ~= 'cash' then
        paid = FenixFramework.RemoveMoney(src, 'cash', amount, reason)
    end

    if not paid and fine.allowUnpaid == false then
        -- Take what there is and write the rest off. Deliberately never an
        -- arrest: turning "you're broke" into a teleport to a station is exactly
        -- the outcome this whole feature exists to avoid.
        local held = FenixFramework.GetHeldMoney(src, account)
        if held > 0 then
            FenixFramework.RemoveMoney(src, account, held, reason)
            amount = held
            paid = true
        end
    end

    if Config.isDebug then
        print(('[fenix-police] citation for %s: $%d at level %d, paid=%s')
            :format(GetPlayerName(src) or src, amount, level, tostring(paid)))
    end

    -- qbx_honor: pulling over for a ticket instead of running or fighting is
    -- the "complied" half of the shootout-vs-comply distinction (see
    -- qbx_honor/config.lua's Config.Hooks.complied_with_police). Not a
    -- dependency -- pcall degrades to no honor change if qbx_honor isn't
    -- running, same pattern every other resource hooking into it uses.
    -- Only for a citation actually paid: with allowUnpaid on, a player with no
    -- money could otherwise farm it from every stop for free.
    if paid then
        pcall(function() exports.qbx_honor:ApplyHook(src, 'complied_with_police') end)
    end

    TriggerClientEvent('fenix-police:client:ticketIssued', src, amount, paid == true)
end)


--Added wanted levels for basic QB robbery etc

--used to get the players near an alert
function GetPlayersInRadius(centerCoords, radius)
    local playersInRadius = {}

    for _, playerId in ipairs(GetPlayers()) do
        local ped = GetPlayerPed(playerId)
        -- A player still loading in has no ped yet.
        if ped and ped ~= 0 then
            local playerCoords = GetEntityCoords(ped)

            local dist = #(vector3(centerCoords.x, centerCoords.y, centerCoords.z) - playerCoords)
            if dist <= radius then
                table.insert(playersInRadius, playerId)
            end
        end
    end

    return playersInRadius
end

--Used to round the location
function round(val, decimal)
    local power = 10 ^ (decimal or 0)
    return math.floor(val * power + 0.5) / power
end
--This function gets the wanted level from the coordinates in the config file - this way you can set a different wanted level based on the crime being commited
function GetWantedLevelFromCoords(alertCoords)
    local coords = vector3(
        round(alertCoords.x, 2),
        round(alertCoords.y, 2),
        round(alertCoords.z, 2)
    )

    -- Leftover development logging. It ran unconditionally — three lines per
    -- configured location, on every alert — and concatenated vector3 values
    -- straight onto strings with `..`, which that type does not support. Now
    -- gated behind Config.isDebug and routed through tostring().
    if Config.isDebug then
        print("[fenix-police] wanted lookup at " .. tostring(coords))
    end

    for index, location in pairs(Config.locations) do
        local locCoords = location[1]
        if locCoords then
            local distance = #(coords - locCoords)
            if Config.isDebug then
                print(("[fenix-police]   location %s: %.2f away"):format(tostring(index), distance))
            end

            if distance < 20 then -- adjust this threshold as needed
                return location.wanted
            end
        else
            print("[fenix-police] Config.locations[" .. tostring(index) .. "] has no coords")
        end
    end

    return nil
end

--Uesed to receive alerts from qbpolice trigger fuction
--Needs to be added to QB-Police police:server:policeAlert
-- Applies a wanted level to everyone standing near a reported crime at one of
-- Config.locations.
--
-- Server-side only: another resource calls it with TriggerEvent, passing the
-- reporting player and the alert (see the README). Nothing in this
-- resource's own client sends it, and as a net event it would let any client
-- star whoever stands near a configured location. A server-local
-- TriggerEvent arrives with source "" rather than 0, so there is no caller to
-- measure the coordinates against either: a caller-distance check here takes
-- every legitimate call for a player with no ped and drops it.
--
-- A crime anywhere other than a configured location stars nobody. Sending
-- wanted level 0 isn't harmless: the client's SetWantedLevel turns it into
-- clearing and re-applying whatever level the player already has, which
-- re-centres their search area for free.
AddEventHandler('fenix:server:trigger', function(pdata, alertData)
    if type(alertData) ~= 'table' then return end
    local at = alertData.coords
    if type(at) ~= 'table' and type(at) ~= 'vector3' then return end

    local x = tonumber(at.x)
    local y = tonumber(at.y)
    local z = tonumber(at.z)
    if not x or not y or not z then return end

    local coords = vector3(x, y, z)
    local wantedlevel = tonumber(GetWantedLevelFromCoords(coords))
    if not wantedlevel or wantedlevel <= 0 then return end

    -- Was unconditional. Five console lines per call is a flood vector by
    -- itself, and none of it is useful outside debugging.
    if Config.isDebug then
        print(('[fenix-police] crime alert at %.1f, %.1f, %.1f -> wanted %d')
            :format(x, y, z, wantedlevel))
    end

    -- Routed through FenixDispatch (server/dispatch.lua) so every incident,
    -- whether it came from this legacy event or a newer call site, goes
    -- through the same FenixIncident lifecycle. wantedLevel from
    -- Config.locations is applied exactly as configured, so existing
    -- per-location tuning keeps working unchanged. The reporter's routing
    -- bucket keeps the stars to players in the same one, either way: an
    -- instanced interior shares its coordinates with every other copy of it.
    local reporter = tonumber(pdata)
    local bucket = (reporter and GetPlayerName(reporter)) and GetPlayerRoutingBucket(reporter) or nil
    if (Config.Dispatch or {}).enabled and FenixDispatch then
        FenixDispatch.createIncident('LEGACY_ALERT', coords, nil, {
            wantedRadius = 10.0,
            directWanted = wantedlevel,
            bucket = bucket,
        })
    else
        for _, playerId in ipairs(GetPlayersInRadius(coords, 10.0)) do
            if bucket == nil or GetPlayerRoutingBucket(playerId) == bucket then
                TriggerClientEvent('fenix-police:client:SetWantedLevel', playerId, wantedlevel)
            end
        end
    end
end)

-- [Upstate Mafia] Resource-stop sweep. Heli and plane units are created
-- server-side (see spawnPoliceHeliNet / spawnPoliceAirNet above), so a
-- `restart fenix-police` / crash / deploy mid-chase leaves that vehicle and
-- its crew behind with nothing left to delete them -- client.lua's own
-- onClientResourceStop cleanup only knows about entities it spawned itself,
-- and the client-side ground units it does track go down with the same
-- restart before their own cleanup can run. FenixGuard.allOwned() is the one
-- registry that already covers every entity this resource has claimed,
-- ground or air, so sweeping it here on server stop is a single catch-all
-- rather than a second bespoke tracking table to keep in sync.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end

    local swept = 0
    for _, rec in ipairs(FenixGuard.allOwned()) do
        local entity = NetworkGetEntityFromNetworkId(rec.netID)
        if entity and entity ~= 0 and DoesEntityExist(entity) then
            DeleteEntity(entity)
            swept = swept + 1
        end
    end
    if Config.isDebug then
        print(('[fenix-police] resource stop: swept %d leftover entit%s'):format(swept, swept == 1 and 'y' or 'ies'))
    end
end)

-- Field revive: the "aftermath" system (client.lua) can pick a downed
-- player back up on its own after a chase, without EMS ever showing up.
-- Server-side only because qbx_medical:Revive is a server export, not
-- something the client can trigger on itself -- see client.lua's own
-- fieldRevive TriggerServerEvent for the fuller story (this used to be a
-- bare 'wasabi_ambulance:revive' client event before the wasabi_ambulance ->
-- qbx_medical migration, 2026-09-09).
--
-- Left open, this is a free revive for anyone, any time, from anywhere, so
-- it needs what the real sequence always has: the player's client holding an
-- aftermath scene, one of that player's own officers beside them, and no
-- other field revive inside Config.Security.fieldReviveCooldown.
local lastFieldRevive = {}
AddEventHandler('playerDropped', function() lastFieldRevive[source] = nil end)

RegisterServerEvent('fenix-police:server:fieldRevive')
AddEventHandler('fenix-police:server:fieldRevive', function()
    local src = source
    if not FenixGuard.allow(src, 'revive', 6) then return end

    if not holdingAftermath(src) then
        FenixGuard.refuse(src, 'field revive', 'no aftermath scene in progress')
        return
    end

    local now = os.time()
    local cooldown = (Config.Security or {}).fieldReviveCooldown or 300
    if lastFieldRevive[src] and now - lastFieldRevive[src] < cooldown then
        FenixGuard.refuse(src, 'field revive', 'field revive cooldown')
        return
    end

    -- The medic works within Config.Aftermath.reviveRange of where the
    -- player went down; the slack covers the body moving since.
    local ped = GetPlayerPed(src)
    local range = ((Config.Aftermath or {}).reviveRange or 8.0) + 6.0
    if not ped or ped == 0 or not FenixGuard.officerNear(src, GetEntityCoords(ped), range) then
        FenixGuard.refuse(src, 'field revive', 'none of their officers is with them')
        return
    end

    lastFieldRevive[src] = now
    -- One revive per scene. The client closes the sequence itself straight
    -- after sending this; nothing here waits on that.
    aftermathHolding[src] = nil

    local ok, err = pcall(function()
        exports.qbx_medical:Revive(src)
    end)
    if not ok and Config.isDebug then
        print(('[fenix-police] field revive export failed for %s: %s'):format(src, tostring(err)))
    end
end)
