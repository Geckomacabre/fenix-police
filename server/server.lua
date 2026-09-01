-- POLICE JOB CHECKING LOGIC --
QBCore = exports['qb-core']:GetCoreObject()

CreateThread(function()
    Wait(5000) -- Ensure clients are loaded first
    while true do
        local polCount = 0
        local players = QBCore.Functions.GetQBPlayers()
        for _, Player in pairs(players) do
            for _, job in ipairs(Config.PoliceJobsToCheck) do
                if Player.PlayerData.job.name == job.jobName then

                    -- Check if configured to only count on-duty players?
                    if job.onDutyOnly then
                        if Player.PlayerData.job.onduty then
                            polCount = polCount + 1
                        end
                    else
                        polCount = polCount + 1
                    end
                end
            end
        end

        -- -1 source tells ALL clients connected to update their cops online count and do logic pertaining to it.
        TriggerClientEvent('fenix-police:updateCopsOnline', -1, polCount)

        -- Check every minute if new police online
        Wait(55000)
    end
end)




-- CLEANUP LOGIC --
local activeGroundUnits = {}
local playerWantedStatus = {}
local lastGlobalCleanup = 0

-- [Upstate Mafia] AFTERMATH -- src -> true while that player's client is
-- running a field-revive/scene-hold sequence (client/client.lua's
-- beginAftermath/endAftermath). The wanted level clears the instant the
-- player is incapacitated, so without this the server had no way to tell
-- "no longer wanted because they're being revived" apart from "no longer
-- wanted, clean everything up" -- applyGroundPursuitTask kept re-tasking
-- units to shoot at and ram the player's body every second, and
-- cleanupIfNoPlayersWanted() kept wiping activeGroundUnits and broadcasting
-- a global despawn every couple of seconds, regardless of what the client
-- was doing with those same officers.
local aftermathHolding = {}

RegisterNetEvent('fenix-police:aftermathState')
AddEventHandler('fenix-police:aftermathState', function(active)
    local src = source
    if active then
        aftermathHolding[src] = true
    else
        aftermathHolding[src] = nil
    end
end)

local function removeActiveGroundUnit(vehNetID)
    activeGroundUnits[vehNetID] = nil
end

local function getDistanceBetweenEntities(a, b)
    local aCoords = GetEntityCoords(a)
    local bCoords = GetEntityCoords(b)
    local dx = aCoords.x - bCoords.x
    local dy = aCoords.y - bCoords.y
    local dz = aCoords.z - bCoords.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

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
local function dispatchCombatProfile(pedNetID, profile)
    local entity = NetworkGetEntityFromNetworkId(pedNetID)
    local owner = DoesEntityExist(entity) and NetworkGetEntityOwner(entity) or -1
    TriggerClientEvent('fenix-police:client:applyCombatProfile', owner, pedNetID, profile)
end

local function applyGroundPursuitTask(unit)
    -- Player's client owns these officers now (walking one over for a field
    -- revive, parking others to hold the scene) -- re-issuing combat/chase
    -- tasks every second on top of that just fights it, which is how a unit
    -- ends up shooting at and running over a body it should be reviving.
    if aftermathHolding[unit.target] then return end

    local vehicle = NetworkGetEntityFromNetworkId(unit.vehNetID)
    local targetPed = GetPlayerPed(unit.target)

    if not DoesEntityExist(vehicle) or not DoesEntityExist(targetPed) then
        removeActiveGroundUnit(unit.vehNetID)
        return
    end

    SetVehicleDoorsLocked(vehicle, 1)
    Entity(vehicle).state:set('doorslockstate', 1, true)
    SetSirenKeepOn(vehicle, true)

    local targetCoords = GetEntityCoords(targetPed)

    for _, pedNetID in ipairs(unit.officers) do
        local officer = NetworkGetEntityFromNetworkId(pedNetID)
        if DoesEntityExist(officer) then
            dispatchCombatProfile(pedNetID, {
                relationshipGroup = 'HATES_PLAYER',
                fleeAttributes = {0, false},
            })

            if GetVehiclePedIsIn(officer, false) ~= vehicle then
                -- No foot patrol behavior: if the car still exists, force officers back in.
                if pedNetID == unit.driverNetID then
                    SetPedIntoVehicle(officer, vehicle, -1)
                else
                    local seats = GetVehicleModelNumberOfSeats and GetVehicleModelNumberOfSeats(GetEntityModel(vehicle)) or 4
                    for seat = 0, seats - 2 do
                        if GetPedInVehicleSeat(vehicle, seat) == 0 then
                            SetPedIntoVehicle(officer, vehicle, seat)
                            break
                        end
                    end
                end
            end
        end
    end

    local driver = NetworkGetEntityFromNetworkId(unit.driverNetID)
    if not DoesEntityExist(driver) or GetPedInVehicleSeat(vehicle, -1) ~= driver then
        return
    end

    dispatchCombatProfile(unit.driverNetID, {
        combatAttributes = {{3, false}}, -- do not voluntarily leave vehicle
        driverAbility = 1.0,
        driverAggressiveness = 1.0,
    })

    local distance = getDistanceBetweenEntities(driver, targetPed)
    if distance > 45.0 then
        -- Direct response phase. Every unit used to drive straight at the
        -- player's live position, which reads as a conga line converging from
        -- one direction rather than a real response -- especially with
        -- several units all spawned behind the player at once (see
        -- Config.Roads' rear-arc spawn bias).
        --
        -- Half the units (by a stable per-vehicle split, so a unit doesn't
        -- flip roles every second) instead drive to where the player is
        -- HEADING: current position plus their velocity projected forward
        -- Config.Driving.interceptLeadDistance metres. No road graph lookup
        -- needed -- GET_ENTITY_VELOCITY/COORDS are synced entity state, valid
        -- server side, unlike the AI/task natives combat_bridge exists for.
        -- Falls back to tailing (the old behaviour) below the configured
        -- minimum speed: leading a target that isn't meaningfully moving just
        -- means driving to nowhere in particular.
        local dc = Config.Driving or {}
        local driveTarget = targetCoords
        if (tonumber(unit.vehNetID) or 0) % 2 == 0 then
            local vel = GetEntityVelocity(targetPed)
            local speed = #(vector2(vel.x, vel.y))
            if speed >= (dc.interceptMinSpeed or 4.0) then
                local lead = dc.interceptLeadDistance or 70.0
                driveTarget = targetCoords + (vector3(vel.x, vel.y, 0.0) / speed) * lead
            end
        end

        dispatchCombatProfile(unit.driverNetID, {
            vehicleDriveTo = {
                x = driveTarget.x, y = driveTarget.y, z = targetCoords.z,
                speed = 42.0,
                vehicleModelHash = GetEntityModel(vehicle),
                drivingStyle = 6,
                stopRange = 2.0,
            },
        })
    else
        -- Close phase: native GTA pursuit behavior, PIT/boxing/etc.
        dispatchCombatProfile(unit.driverNetID, { vehicleChase = unit.target })
    end

    for _, pedNetID in ipairs(unit.officers) do
        if pedNetID ~= unit.driverNetID then
            local officer = NetworkGetEntityFromNetworkId(pedNetID)
            if DoesEntityExist(officer) then
                dispatchCombatProfile(pedNetID, { combatTarget = unit.target })
            end
        end
    end
end

CreateThread(function()
    while true do
        Wait(1000)
        for _, unit in pairs(activeGroundUnits) do
            applyGroundPursuitTask(unit)
        end
    end
end)

local function anyPlayerWanted()
    local players = GetPlayers()
    if #players == 0 then return false, true end

    for _, playerId in ipairs(players) do
        local src = tonumber(playerId)
        local status = playerWantedStatus[src]
        if not status then
            return false, false
        end

        if status.wanted then
            return true, true
        end
    end

    return false, true
end

local function anyPlayerHoldingAftermath()
    for _, holding in pairs(aftermathHolding) do
        if holding then return true end
    end
    return false
end

local function cleanupIfNoPlayersWanted()
    if anyPlayerHoldingAftermath() then return end

    local someoneWanted, allPlayersKnown = anyPlayerWanted()
    if not someoneWanted and allPlayersKnown then
        local now = os.time()
        if now - lastGlobalCleanup >= 2 then
            lastGlobalCleanup = now
            activeGroundUnits = {}
            TriggerClientEvent('fenix-police:cleanupAllPolice', -1)
        end
    end
end

AddEventHandler('playerDropped', function()
    local src = source
    playerWantedStatus[src] = nil
    aftermathHolding[src] = nil
    for vehNetID, unit in pairs(activeGroundUnits) do
        if unit.target == src then
            removeActiveGroundUnit(vehNetID)
        end
    end
    cleanupIfNoPlayersWanted()
end)

RegisterNetEvent('fenix-police:updateWantedStatus')
AddEventHandler('fenix-police:updateWantedStatus', function(isWanted)
    local src = source
    playerWantedStatus[src] = {
        wanted = isWanted == true,
        updatedAt = os.time(),
    }

    cleanupIfNoPlayersWanted()
end)

-- Server event to delete a vehicle or officer entity from the network ID.
RegisterServerEvent('deleteSpawnedEntity')
AddEventHandler('deleteSpawnedEntity', function(entityNetID)
    local src = source
    if not FenixGuard.allow(src, 'delete') then return end

    -- Was: resolve the net ID and delete whatever came back. Network IDs are
    -- small integers, so that was "delete any entity on the server, by counting".
    -- See server/guard.lua.
    local entity = FenixGuard.resolve(src, entityNetID, 'any', 'deleteSpawnedEntity')
    if not entity then return end

    FenixGuard.release(entityNetID)
    DeleteEntity(entity)
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
    for vehNetID, unit in pairs(activeGroundUnits) do
        if unit.driverNetID == pedNetID then
            removeActiveGroundUnit(vehNetID)
        else
            for _, officerNetID in ipairs(unit.officers) do
                if officerNetID == pedNetID then
                    removeActiveGroundUnit(vehNetID)
                    break
                end
            end
        end
    end
end)




-- Server event to delete a vehicle by network ID, this will check if anyone is in the vehicle first.
-- If a ped is in the vehicle we can assume it is a player, because this will not have been called until all officers assigned
-- to the vehicle were already deleted. 
RegisterServerEvent('deleteSpawnedVehicle')
AddEventHandler('deleteSpawnedVehicle', function(vehNetID)
    local src = source
    if not FenixGuard.allow(src, 'delete') then return end

    removeActiveGroundUnit(vehNetID)

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
-- `role` is 'air' for heli/aircraft crews (own firing pattern).
local function applyOfficerCombatProfile(officer, wantedLevel, role)
    if not DoesEntityExist(officer) then return false end

    local pedNetID = NetworkGetNetworkIdFromEntity(officer)

    if not combatEnabled() then
        dispatchCombatProfile(pedNetID, {
            accuracy = math.random(20, 40),
            firingPattern = 'FIRING_PATTERN_FULL_AUTO',
            combatAttributes = {{2, true}},
            relationshipGroup = 'HATES_PLAYER',
        })
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

    dispatchCombatProfile(pedNetID, profile)

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




-- Function to add a weapon with attachments to a ped
local function giveWeaponWithAttachments(ped, weaponHash, attachments)
    if not DoesEntityExist(ped) then
        return
    end
    -- Give the weapon to the ped
    GiveWeaponToPed(ped, GetHashKey(weaponHash), 999, false, true)

    -- Add each attachment to the weapon
    for _, attachment in ipairs(attachments) do
        GiveWeaponComponentToPed(ped, GetHashKey(weaponHash), GetHashKey(attachment))
    end
end




-- SPAWNING FUNCTIONS --




-- Function to generate a random float between min and max
local function randomFloat(min, max)
    return min + math.random() * (max - min)
end



-- GROUND UNITS --
RegisterNetEvent('spawnPoliceUnitNet')
AddEventHandler('spawnPoliceUnitNet', function(wantedLevel, playerCoords, regionCode, spawnPoint, spawnHeading)
    local src = source
    if not FenixGuard.allow(src, 'spawn') then return end

    local seatIndex = -1

    -- Variable will be set true as soon as a vehicle has a driver. I'm less worried about a crew member not warping in properly.
    local vehicleCrewed = false
    local hasDriverCount = 0
    local vehNetID = nil
    local officers = {}
    local driverNetID = nil

    while (not vehicleCrewed) and hasDriverCount < Config.hasDriverWaitCount do


        vehNetID = nil

        -- Pick the vehicle to choose to spawn for this region, vehicle determines which peds spawn with it, and the peds determine combat behavior and weapons. 
        local selectedEntry = getRandomVehicle(regionCode, wantedLevel)
        if not selectedEntry then
            if Config.isDebug then print('No suitable vehicle found for the given wanted level.') end
            TriggerClientEvent('spawnPoliceUnitNetResponse', src, nil, nil)
            return
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
        return
        -- Dead code below this point (old server-side vehicle/ped spawn loop,
        -- superseded by the client-side delegation above) was left in place
        -- after a prior patch added the early `return`. Lua requires `return`
        -- to be the last statement in its block, so this was a hard syntax
        -- error that prevented this entire file — all of fenix-police's
        -- server-side logic, not just ground unit spawning — from loading at
        -- all. Removed the unreachable block; this while loop is now a
        -- single-pass wrapper around the client delegation, which matches
        -- what was already actually happening (return exits before any
        -- second iteration could occur).
    end
end)




-- HELI UNITS --
RegisterNetEvent('spawnPoliceHeliNet')
AddEventHandler('spawnPoliceHeliNet', function(wantedLevel, playerCoords, spawnPoint, spawnTable)
    local src = source
    if not FenixGuard.allow(src, 'spawn') then return end

    local seatIndex = -1
    
    -- Variable will be set true as soon as a vehicle has a driver. I'm less worried about a crew member not warping in properly.
    local vehicleCrewed = false
    local hasDriverCount = 0
    local vehNetID = nil
    local officers = {}
    

    while (not vehicleCrewed) and hasDriverCount < Config.hasDriverWaitCount do

        vehNetID = nil

        -- Pick the vehicle to choose to spawn for this region, vehicle determines which peds spawn with it, and the peds determine combat behavior and weapons. 
        local selectedEntry = getRandomAirUnit(spawnTable, wantedLevel)
        if not selectedEntry then
            if Config.isDebug then print('No suitable heli found for the given wanted level.') end
            return
        end
        local vehicleHash = GetHashKey(selectedEntry.unit.model)

        local vehicle = CreateVehicleServerSetter(vehicleHash, 'heli', spawnPoint.x, spawnPoint.y, spawnPoint.z, 0.0)
        local waitCount = 0 
        while not DoesEntityExist(vehicle) and waitCount < Config.spawnWaitCount do
            Wait(10)
            waitCount = waitCount + 1
        end
        if not DoesEntityExist(vehicle) then
            if Config.isDebug then print('Spawning '..selectedEntry.unit.model.. ' failed.') end
            return
        end
        vehNetID = NetworkGetNetworkIdFromEntity(vehicle)

        SetEntityDistanceCullingRadius(vehicle, 10000.0)

        -- [Upstate Mafia patch] Unlock doors + set statebag so qbx_vehiclekeys skips auto-lock
        SetVehicleDoorsLocked(vehicle, 1)  -- 1 = unlocked
        Entity(vehicle).state:set('doorslockstate', 1, true)  -- synced statebag

        officers = {}

        -- [Upstate Mafia patch] Wait for heli entity to fully initialise before seating peds
        Wait(500)

        -- Spawn pilots
        for _, pedModel in ipairs(selectedEntry.pilots) do
            local pedHash = GetHashKey(pedModel)

            -- Spawn ped at the heli (not 20 units away)
            local officer = CreatePed(4, pedHash, spawnPoint.x, spawnPoint.y, spawnPoint.z + 1.0, spawnHeading, true, true)
            local waitCount = 0
            while not DoesEntityExist(officer) and waitCount < Config.spawnWaitCount do
                if Config.isDebug then print('Waiting to spawn heli pilot...') end
                officer = CreatePed(4, pedHash, spawnPoint.x, spawnPoint.y, spawnPoint.z + 1.0, spawnHeading, true, true)
                Wait(10)
                waitCount = waitCount + 1
            end
            if not DoesEntityExist(officer) then
                if Config.isDebug then print('Spawning pilot '..pedModel.. ' failed.') end
                return
            end
            SetEntityDistanceCullingRadius(officer, 10000.0)
            Wait(200)

            -- Give weapon BEFORE seating so it persists through vehicle-entry state changes.
            GiveWeaponToPed(officer, GetHashKey('weapon_combatpistol'), 999, false, true)
            SetCurrentPedWeapon(officer, GetHashKey('weapon_combatpistol'), true)

            -- Try multiple seating methods (same approach as ground units)
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
                    print(('Heli pilot seat attempt %d for %s vehNetID=%s seat=%d'):format(attempt, selectedEntry.unit.model, tostring(vehNetID), seatIndex))
                end
            end

            if not seated then
                if Config.isDebug then print('Pilot FAILED to seat in ' .. selectedEntry.unit.model .. ' vehNetID = ' .. tostring(vehNetID) .. ' seat = ' .. seatIndex .. ', deleting ped') end
                DeleteEntity(officer)
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
                    })
                    -- Accuracy / firing pattern / hostility scale with wanted level.
                    applyOfficerCombatProfile(officer, wantedLevel, 'air')
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

                local officer = CreatePed(4, pedHash, spawnPoint.x, spawnPoint.y, spawnPoint.z + 1.0, spawnHeading, true, true)
                local waitCount = 0
                while not DoesEntityExist(officer) and waitCount < Config.spawnWaitCount do
                    if Config.isDebug then print('Waiting to spawn heli crew...') end
                    officer = CreatePed(4, pedHash, spawnPoint.x, spawnPoint.y, spawnPoint.z + 1.0, spawnHeading, true, true)
                    Wait(10)
                    waitCount = waitCount + 1
                end
                if not DoesEntityExist(officer) then
                    if Config.isDebug then print('Spawning crew '..pedModel.. ' failed.') end
                    return
                end
                SetEntityDistanceCullingRadius(officer, 10000.0)
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
                    dispatchCombatProfile(pedNetID, { fleeAttributes = {0, false} })
                    -- Crew only open fire once hostile for this wanted level; below
                    -- that they ride along and the heli just shadows the player.
                    local crewHostile = applyOfficerCombatProfile(officer, wantedLevel, 'air')
                    if crewHostile then
                        dispatchCombatProfile(pedNetID, { combatTarget = src })
                    end
                    table.insert(officers, pedNetID)
                end
            end
        end

        if not vehicleCrewed then
            if Config.isDebug then print('Vehicle ' .. selectedEntry.unit.model .. ' failed to be crewed, deleting vehNetID = ' .. vehNetID .. ' and starting over ') end
            DeleteEntity(vehicle)
            vehNetID = nil
            Wait(100)
            -- Add 1 and try again
            hasDriverCount = hasDriverCount + 1   
        end
    end


    -- Helicopters and planes are created here, on the server, so ownership is
    -- recorded directly at the point of creation -- no ticket round-trip is
    -- needed and there is nothing for a client to assert. This is what the
    -- ground path has to reconstruct with FenixGuard.issueTicket.
    if vehNetID then FenixGuard.claim(src, vehNetID, 'vehicle') end
    for _, pedNetID in ipairs(officers or {}) do
        FenixGuard.claim(src, pedNetID, 'ped')
    end

    -- Return the netIDs to the client
    TriggerClientEvent('spawnPoliceHeliNetResponse', src, vehNetID, officers)
end)




-- AIR UNITS --
RegisterNetEvent('spawnPoliceAirNet')
AddEventHandler('spawnPoliceAirNet', function(wantedLevel, playerCoords, spawnPoint, spawnTable)
    local src = source
    if not FenixGuard.allow(src, 'spawn') then return end

    local seatIndex = -1

    -- Variable will be set true as soon as a vehicle has a driver. I'm less worried about a crew member not warping in properly.
    local vehicleCrewed = false
    local hasDriverCount = 0
    local vehNetID = nil
    local officers = {}
    

    while (not vehicleCrewed) and hasDriverCount < Config.hasDriverWaitCount do

        vehNetID = nil

        -- Pick the vehicle to choose to spawn for this region, vehicle determines which peds spawn with it, and the peds determine combat behavior and weapons. 
        local selectedEntry = getRandomAirUnit(spawnTable, wantedLevel)
        if not selectedEntry then
            if Config.isDebug then print('No suitable air unit found for the given wanted level.') end
            return
        end
        local vehicleHash = GetHashKey(selectedEntry.unit.model)

        local vehicle = CreateVehicleServerSetter(vehicleHash, 'plane', spawnPoint.x, spawnPoint.y, spawnPoint.z, 0.0)
        local waitCount = 0 
        while not DoesEntityExist(vehicle) and waitCount < Config.spawnWaitCount do
            Wait(10)
            waitCount = waitCount + 1
        end
        if not DoesEntityExist(vehicle) then
            if Config.isDebug then print('Spawning '..selectedEntry.unit.model.. ' failed.') end
            return
        end
        vehNetID = NetworkGetNetworkIdFromEntity(vehicle)

        SetEntityDistanceCullingRadius(vehicle, 10000.0)
        

        officers = {}

        for _, pedModel in ipairs(selectedEntry.pilots) do


            local pedHash = GetHashKey(pedModel)


            local warpCount = 0
            local pedInSeat = nil
            while (not pedInSeat or pedInSeat == 0) and warpCount < Config.warpWaitCount do

                local officer = CreatePed(4, pedHash, spawnPoint.x+20, spawnPoint.y+20, spawnPoint.z, spawnHeading, true, true)
                local waitCount = 0
                while not DoesEntityExist(officer) and waitCount < Config.spawnWaitCount do
                    if Config.isDebug then print('Waiting to spawn officer...') end
                    officer = CreatePed(4, pedHash, spawnPoint.x+20, spawnPoint.y+20, spawnPoint.z, spawnHeading, true, true)
                    Wait(10)
                    waitCount = waitCount + 1
                end
                if not DoesEntityExist(officer) then
                    if Config.isDebug then print('Spawning '..pedModel.. ' failed.') end
                    return
                end
                SetEntityDistanceCullingRadius(officer, 10000.0)
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
                        })
                        -- Accuracy / firing pattern / hostility scale with wanted level.
                        applyOfficerCombatProfile(officer, wantedLevel, 'air')
                    end

                    -- Add pilot to table to return
                    table.insert(officers, pedNetID)

                    -- We spawned a ped into the vehicle, ensure vehicleCrewed is true.
                    vehicleCrewed = true
                end

            end


            --seatIndex = seatIndex + 1 -- Increase seat index so each seat is filled from driver, to passenger, to rear passengers etc.

            
            

            if not vehicleCrewed then
                -- Should break the ped loop and move straight to deleting the vehicle. In my experience if the first one fails to warp they all will. 
                break 
            end

        end

        if not vehicleCrewed then
            if Config.isDebug then print('Vehicle ' .. selectedEntry.unit.model .. ' failed to be crewed, deleting vehNetID = ' .. vehNetID .. ' and starting over ') end
            DeleteEntity(vehicle)
            vehNetID = nil
            Wait(100)
            -- Add 1 and try again
            hasDriverCount = hasDriverCount + 1   
        end

    end


    -- Helicopters and planes are created here, on the server, so ownership is
    -- recorded directly at the point of creation -- no ticket round-trip is
    -- needed and there is nothing for a client to assert. This is what the
    -- ground path has to reconstruct with FenixGuard.issueTicket.
    if vehNetID then FenixGuard.claim(src, vehNetID, 'vehicle') end
    for _, pedNetID in ipairs(officers or {}) do
        FenixGuard.claim(src, pedNetID, 'ped')
    end

    -- Return the netIDs to the client
    TriggerClientEvent('spawnPoliceAirNetResponse', src, vehNetID, officers)
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

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local account = fine.account or 'bank'
    local reason  = fine.reason or 'traffic-citation'
    local paid    = Player.Functions.RemoveMoney(account, amount, reason)

    if not paid and fine.fallbackToCash ~= false and account ~= 'cash' then
        paid = Player.Functions.RemoveMoney('cash', amount, reason)
    end

    if not paid and fine.allowUnpaid == false then
        -- Take what there is and write the rest off. Deliberately never an
        -- arrest: turning "you're broke" into a teleport to a station is exactly
        -- the outcome this whole feature exists to avoid.
        local held = (Player.PlayerData.money and Player.PlayerData.money[account]) or 0
        if held > 0 then
            Player.Functions.RemoveMoney(account, held, reason)
            amount = held
            paid = true
        end
    end

    if Config.isDebug then
        print(('[fenix-police] citation for %s: $%d at level %d, paid=%s')
            :format(GetPlayerName(src) or src, amount, level, tostring(paid)))
    end

    TriggerClientEvent('fenix-police:client:ticketIssued', src, amount, paid == true)
end)


--Added wanted levels for basic QB robbery etc

--used to get the players near an alert
function GetPlayersInRadius(centerCoords, radius)
    local playersInRadius = {}

    for _, playerId in ipairs(GetPlayers()) do
        local ped = GetPlayerPed(playerId)
        local playerCoords = GetEntityCoords(ped)

        local dist = #(vector3(centerCoords.x, centerCoords.y, centerCoords.z) - playerCoords)
        if dist <= radius then
            table.insert(playersInRadius, playerId)
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
-- Applies a wanted level to everyone standing near a reported crime.
--
-- [Upstate Mafia] Hardened. As written this took coordinates straight from the
-- client and handed a wanted level to every player within 10m of them, so any
-- client could pick a victim anywhere on the map and star them repeatedly -- a
-- wanted-level cannon aimed by whoever sent the event. It also printed five
-- lines to the server console per call, unconditionally, which is a console
-- flood on its own.
--
-- The fix is to stop trusting the location: a player reporting a crime is
-- reporting one they are AT. Coordinates further than
-- Config.Security.maxAlertDistance from the caller are refused. Calls that did
-- not come from a player (another resource triggering this server-side, where
-- source is 0) skip that check, because there is no caller to measure against
-- and server-side callers are already trusted.
RegisterNetEvent('fenix:server:trigger')
AddEventHandler('fenix:server:trigger', function(pdata, alertData)
    local src = source

    if type(alertData) ~= 'table' or type(alertData.coords) ~= 'table' then return end

    local x = tonumber(alertData.coords.x)
    local y = tonumber(alertData.coords.y)
    local z = tonumber(alertData.coords.z)
    if not x or not y or not z then return end

    if src and src ~= 0 then
        if not FenixGuard.allow(src, 'alert') then return end

        local maxDistance = (Config.Security or {}).maxAlertDistance or 100.0
        if maxDistance > 0 then
            local ped = GetPlayerPed(src)
            if not ped or ped == 0 then return end

            local here = GetEntityCoords(ped)
            local dx, dy, dz = here.x - x, here.y - y, here.z - z
            if math.sqrt((dx * dx) + (dy * dy) + (dz * dz)) > maxDistance then
                FenixGuard.refuse(src, 'crime alert',
                    'reported coordinates are not where the caller is')
                return
            end
        end
    end

    local coords = { x = x, y = y, z = z }
    local wantedlevel = GetWantedLevelFromCoords(coords) or 0

    -- Was unconditional. Five console lines per call is a flood vector by
    -- itself, and none of it is useful outside debugging.
    if Config.isDebug then
        print(('[fenix-police] crime alert at %.1f, %.1f, %.1f -> wanted %d')
            :format(x, y, z, wantedlevel))
    end

    for _, playerId in ipairs(GetPlayersInRadius(coords, 10.0)) do
        if Config.isDebug then
            print(('[fenix-police]   applying wanted %d to %s'):format(wantedlevel, tostring(playerId)))
        end
        TriggerClientEvent('fenix-police:client:SetWantedLevel', playerId, wantedlevel)
    end
end)
