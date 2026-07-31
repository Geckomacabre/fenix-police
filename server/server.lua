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

local function applyGroundPursuitTask(unit)
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
            SetPedRelationshipGroupHash(officer, GetHashKey('HATES_PLAYER'))
            SetPedFleeAttributes(officer, 0, false)

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

    SetPedCombatAttributes(driver, 3, false) -- Do not voluntarily leave vehicle
    SetDriverAbility(driver, 1.0)
    SetDriverAggressiveness(driver, 1.0)

    local distance = getDistanceBetweenEntities(driver, targetPed)
    if distance > 45.0 and TaskVehicleDriveToCoord then
        -- Direct response phase: drive to where the wanted player is now.
        TaskVehicleDriveToCoord(driver, vehicle, targetCoords.x, targetCoords.y, targetCoords.z, 42.0, 1, GetEntityModel(vehicle), 6, 2.0, true)
        if SetDriveTaskDrivingStyle then SetDriveTaskDrivingStyle(driver, 6) end
    else
        -- Close phase: native GTA pursuit behavior, PIT/boxing/etc.
        TaskVehicleChase(driver, targetPed)
        SetTaskVehicleChaseBehaviorFlag(driver, 8, true)
    end

    for _, pedNetID in ipairs(unit.officers) do
        if pedNetID ~= unit.driverNetID then
            local officer = NetworkGetEntityFromNetworkId(pedNetID)
            if DoesEntityExist(officer) then
                TaskCombatPed(officer, targetPed, 0, 16)
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

local function cleanupIfNoPlayersWanted()
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
    local entity = NetworkGetEntityFromNetworkId(entityNetID)
    if DoesEntityExist(entity) then
        DeleteEntity(entity)
    end
end)




-- Server event to delete a ped by network ID
RegisterServerEvent('deleteSpawnedPed')
AddEventHandler('deleteSpawnedPed', function(pedNetID)
    local entity = NetworkGetEntityFromNetworkId(pedNetID)
    if DoesEntityExist(entity) then
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
    removeActiveGroundUnit(vehNetID)
    local entity = NetworkGetEntityFromNetworkId(vehNetID)
    if DoesEntityExist(entity) then

        local vehicleHasPlayer = false

        for _, playerId in ipairs(GetPlayers()) do
            local ped = GetPlayerPed(playerId)
            if GetVehiclePedIsIn(ped, false) == entity then
                vehicleHasPlayer = true
                break
            end
        end
        -- Only prevent deletion if the vehicle is occupied by a PLAYER. 
        if vehicleHasPlayer then
            TriggerClientEvent('deleteSpawnedVehicleResponseStolen', src, vehNetID)
        else
            DeleteEntity(entity)
        end 
    end   
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

    if not combatEnabled() then
        SetPedAccuracy(officer, math.random(20, 40))
        SetPedFiringPattern(officer, GetHashKey('FIRING_PATTERN_FULL_AUTO'))
        SetPedCombatAttributes(officer, 2, true)
        SetPedRelationshipGroupHash(officer, GetHashKey('HATES_PLAYER'))
        return true
    end

    local cfg = Config.Combat
    local hostile = math.random() < levelValue(cfg.engageChance, wantedLevel, 1.0)
        or wantedLevel >= (cfg.hostileFromLevel or 4)

    local accuracy = levelValue(cfg.accuracy, wantedLevel, nil)
    if accuracy then
        SetPedAccuracy(officer, math.random(accuracy[1], accuracy[2]))
    end

    -- Not every PED native is exposed to the server runtime; these two are not
    -- used anywhere else server-side in this resource, so check before calling
    -- rather than risking a nil-call that would kill the whole script.
    if SetPedShootRate then
        SetPedShootRate(officer, levelValue(cfg.shootRate, wantedLevel, 100))
    end
    if SetPedCombatAbility then
        SetPedCombatAbility(officer, levelValue(cfg.combatAbility, wantedLevel, 1))
    end

    local pattern
    if role == 'air' then
        pattern = cfg.firingPatternHeli or 'FIRING_PATTERN_BURST_FIRE_HELI'
    elseif wantedLevel >= (cfg.fullAutoFromLevel or 5) then
        pattern = cfg.firingPatternAuto or 'FIRING_PATTERN_FULL_AUTO'
    else
        pattern = cfg.firingPatternBurst or 'FIRING_PATTERN_BURST_FIRE'
    end
    SetPedFiringPattern(officer, GetHashKey(pattern))

    -- Cleared wherever the base game sets an explicit shoot rate.
    SetPedCombatAttributes(officer, 24, false)

    SetPedCombatAttributes(officer, 2, wantedLevel >= (cfg.drivebyFromLevel or 4))
    SetPedCombatAttributes(officer, 46, hostile)
    SetPedCombatAttributes(officer, 3, false) -- never bail out of the aircraft

    -- Only claim the hostile group here. The passive group is created client-side
    -- (AddRelationshipGroup / SetRelationshipBetweenGroups are client natives),
    -- so leaving the default group until the client's first cycle is correct.
    if hostile then
        SetPedRelationshipGroupHash(officer, GetHashKey(cfg.relationshipHostile or 'HATES_PLAYER'))
    end

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
        TriggerClientEvent('fenix-police:spawnPoliceUnitClient', src, selectedEntry.vehicle, selectedEntry.peds, spawnPoint, spawnHeading)
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
                    -- [Upstate Mafia] Server-side combat setup for heli pilot
                    SetPedCombatAttributes(officer, 52, true)  -- Can vehicle attack
                    SetPedCombatAttributes(officer, 53, true)  -- Can use mounted vehicle weapons
                    SetPedFleeAttributes(officer, 0, false)
                    -- Accuracy / firing pattern / hostility scale with wanted level.
                    applyOfficerCombatProfile(officer, wantedLevel, 'air')
                    -- Pilot: chase the player
                    local targetPed = GetPlayerPed(src)
                    TaskHeliChase(officer, targetPed, 0, 0, 120)
                    SetDriverAbility(officer, 1.0)
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
                    -- [Upstate Mafia] Server-side combat setup for heli crew
                    SetPedFleeAttributes(officer, 0, false)
                    -- Crew only open fire once hostile for this wanted level; below
                    -- that they ride along and the heli just shadows the player.
                    local crewHostile = applyOfficerCombatProfile(officer, wantedLevel, 'air')
                    if crewHostile then
                        local targetPed = GetPlayerPed(src)
                        TaskCombatPed(officer, targetPed, 0, 16)
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

    -- Return the netIDs to the client
    TriggerClientEvent('spawnPoliceHeliNetResponse', src, vehNetID, officers)
end)




-- AIR UNITS --
RegisterNetEvent('spawnPoliceAirNet')
AddEventHandler('spawnPoliceAirNet', function(wantedLevel, playerCoords, spawnPoint, spawnTable)
    local src = source
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

                    -- [Upstate Mafia] Server-side combat setup for air pilot
                    if DoesEntityExist(officer) then
                        GiveWeaponToPed(officer, GetHashKey('weapon_combatpistol'), 999, false, false)
                        SetPedCombatAttributes(officer, 52, true) -- Can vehicle attack
                        SetPedCombatAttributes(officer, 53, true) -- Can use mounted vehicle weapons
                        SetPedCombatAttributes(officer, 85, true) -- Prefer air targets
                        SetPedCombatAttributes(officer, 86, true) -- Allow dogfighting
                        SetPedFleeAttributes(officer, 0, false)
                        -- Accuracy / firing pattern / hostility scale with wanted level.
                        applyOfficerCombatProfile(officer, wantedLevel, 'air')
                        -- Pilot: chase the player
                        local targetPed = GetPlayerPed(src)
                        TaskPlaneChase(officer, targetPed, 20, 20, 150)
                        SetDriverAbility(officer, 1.0)
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

    -- Return the netIDs to the client
    TriggerClientEvent('spawnPoliceAirNetResponse', src, vehNetID, officers)
end)


-- Keep a spawned police vehicle unlocked so cops can re-enter after a foot chase.
-- qbx_vehiclekeys monitors unoccupied vehicles and auto-locks them; re-applying the
-- unlocked state here (triggered by the client each cycle during re-entry) fights that.
RegisterNetEvent('fenix-police:unlockOfficerVehicle')
AddEventHandler('fenix-police:unlockOfficerVehicle', function(vehNetID)
    local vehicle = NetworkGetEntityFromNetworkId(vehNetID)
    if vehicle and DoesEntityExist(vehicle) then
        SetVehicleDoorsLocked(vehicle, 1)
        Entity(vehicle).state:set('doorslockstate', 1, true)
    end
end)


-- [Upstate Mafia] Server-side re-arm: client detects unarmed cop and asks server to fix it.
-- Server owns the entities, so GiveWeaponToPed works reliably here.
-- loadoutKey is optional — falls back to a pistol if not provided or not found.
RegisterNetEvent('fenix-police:rearmOfficer')
AddEventHandler('fenix-police:rearmOfficer', function(pedNetID, loadoutKey)
    local officer = NetworkGetEntityFromNetworkId(pedNetID)
    if not officer or not DoesEntityExist(officer) then return end
    local loadout = loadoutKey and Config.loadouts[loadoutKey]
    if loadout then
        givePedLoadout(officer, loadout)
    else
        GiveWeaponToPed(officer, GetHashKey('weapon_pistol'), 999, false, true)
        SetCurrentPedWeapon(officer, GetHashKey('weapon_pistol'), true)
    end
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
RegisterNetEvent('fenix:server:trigger')
AddEventHandler('fenix:server:trigger', function(pdata,alertData)
    
    if alertData.coords then
        local wantedlevel = GetWantedLevelFromCoords({x = alertData.coords.x, y = alertData.coords.y, z = alertData.coords.z })
    
        if wantedlevel then
            print("Wanted Level for this location is " .. wantedlevel)
        else
            print("No wanted level for this locaiton found.. setting to 1")
            wantedlevel = 0
        end 

        print("getting nearbyplayers")
        local nearbyPlayers = GetPlayersInRadius({ x = alertData.coords.x, y = alertData.coords.y, z = alertData.coords.z }, 10.0)
        print("Nearby players: " .. json.encode(nearbyPlayers))   

        for _, playerId in ipairs(nearbyPlayers) do
            print("Player nearby: " .. tostring(playerId))
        
            -- You can get more info about the player
            local ped = GetPlayerPed(playerId)
            print("Player " .. playerId .. " triggered police, applying wanted level: " .. wantedlevel)
            TriggerClientEvent('fenix-police:client:SetWantedLevel', playerId, wantedlevel)
        end
    end  
end)
