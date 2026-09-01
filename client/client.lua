--TODOs:
--
-- Allow adding attachments to Config.loadouts so they have flashlights for eg.
--
-- Remove player stolen police cars if they are abandoned for a long time and far away from players.
--
-- Send player to prison if killed by cops, while player is in lastStand/bleedout the cops can approach you and if they reach player they go to jail. If you die before they reach you
-- then you go to hospital. Idea: Lookup lastStand code, lookup sendToPrison code and get help leveraging the two features?
--
-- Add criminal database that will track crimes: 
-- a) Allow criminal record check, just for fun stats. Should track anything you were wanted for whether you escaped or not. And also any convictions where you end up in prison.
-- b) If player has evaded police add a warrant for them and any vehicle they were last in at the time of evasion. Re-sets when they go to prison.
-- c) If cop is near player with warrant: 
--     -If player is on foot the cops spot you from farther away and set shorter timer to trigger wanted level.
--     -If player is in vehicle and vehicle is not wanted then the cops can only spot you from close by and the timer is longer to trigger wanted level.
--     -If player is in vehicle and vehicle is wanted then same distance/timer as when on foot.
--
-- Track kill count and if player has caused enough destruction at wanted level 5 then switch spawnpool to military units.
-- Track if player got into a military vehicle at any wanted level and switch spawnpool to military units. 
-- Track if player has escaped x amount of times without going to prison and chance to spawn hitmen or PMC contractors randomly (without wanted stars) to try and kill player. 
-- Also perhaps FIB agents can follow you around if warrant + very high crime stat, keeping distance but watching you so they can pounce when you commit a crime. 
--
--
-- Add gang relation database that will track gang relationships:
-- a) Set relationships of the peds so gang members out in the world will attack the player if relations are poor.
-- b) Track if player has killed x amount of gang members, if so chance to spawn gang hit one time then re-set flag. 
-- c) Way to increase relations? Messing with members of one gang could make another happy. Bribes? Drugs? Weapons?
-- d) Have this affect prison experience when that is working. Rival gangs in prison will cause problems for the player.
--
-- Add Gangs, Territories, and takeovers. Gang wars! Players could hire their own peds etc. This might need to be a separate mod.

-- USER REQUESTS:
-- Add command to manually activate/de-activate AI police that police-job users can use.
-- Prevent Police Job users from being wanted by this script. 







-- ****BEGIN CODE**** --

-- Get the QBCore object so we can do notifications, check for nearest vehicle using their improved call, and handle isDying and isLastStand situations for the player. 
QBCore = exports['qb-core']:GetCoreObject()

-- [Upstate Mafia] Suppress policet (police transporter) globally on resource start
Citizen.CreateThread(function()
    SetVehicleModelIsSuppressed(GetHashKey('policet'), true)
end)


-- [Upstate Mafia] Aftermath state, declared here (not down by the functions
-- that use it, see the AFTERMATH section below) specifically so the
-- independent cleanup watchdog thread further down this file -- which runs
-- BEFORE that section and would otherwise have no visibility into a `local`
-- declared after it -- can check aftermath.active too. That watchdog exists
-- precisely to hammer handleEndWantedDelete() regardless of what the main
-- loop is doing; without this it deleted every officer mid field-revive
-- attempt within half a second of the wanted level clearing, the exact bug
-- this comment is here to stop from happening again.
local aftermath = {
    active            = false, -- a sequence currently owns nearby units
    until_            = 0,     -- GetGameTimer() hard cap on how long a failed attempt holds the scene
    attemptedThisDown = false, -- at most one attempt per down, not per tick
}

-- A resource restart while aftermath.active was true (a crash, a manual
-- `restart fenix-police` mid-sequence) wipes this client's Lua state clean,
-- but the server's aftermathHolding[src] flag it was told about has no way
-- to know that happened -- it would stay stuck true forever, permanently
-- blocking that player's units from being re-tasked and blocking the global
-- cleanup sweep for every player. Clear it on every start so a restart can't
-- leave the flag stranded.
AddEventHandler('onClientResourceStart', function(res)
    if res == GetCurrentResourceName() then
        TriggerServerEvent('fenix-police:aftermathState', false)
    end
end)

-- TABLES --
-- Tables to keep track of spawned police units
local spawnedVehicles = {} -- Table to store {vehicle = vehicle, officers = {driver = officer1, passenger = officer2...}, officerTasks = {}}
local deadPeds = {} -- Table to store {officer = ped, timer = 0}
local farOfficers = {} -- Table to store {officer = ped, timer = 0}

local spawnedHeliUnits = {} -- Table to store {unit = unit, officers = {driver = officer1, passenger = officer2...}, officerTasks = {}}
local deadHeliPeds = {} -- Table to store {officer = ped, timer = 0}
local farHeliPeds = {} -- Table to store {officer = ped, timer = 0}

local spawnedAirUnits = {} -- Table to store {unit = unit, officers = {driver = officer1, passenger = officer2...}, officerTasks = {}}
local deadAirPeds = {} -- Table to store {officer = ped, timer = 0}
local farAirPeds = {} -- Table to store {officer = ped, timer = 0}

local stuckAttempts = {}  -- Table to keep track of the number of attempts to unstick vehicle for each vehicle
local stolenVehicles = {} -- Table to store vehicles by netID that the player stole and were not cleaned up, to delete later when the player has abandoned them

local isSpawning = false -- Variable to prevent spawning more units when spawning is already in progress.
local pendingGroundSpawns = 0 -- Tracks concurrent ground-unit spawn requests in flight.
local pendingHeliSpawns   = 0 -- Tracks concurrent heli spawn requests in flight.
local pendingAirSpawns    = 0 -- Tracks concurrent air spawn requests in flight.
local MAX_CONCURRENT_SPAWNS = 5 -- Allow up to 5 requests to the server at once per unit type.

-- spawnGate: when false, any in-flight spawnPoliceUnitClient / heli / air events that
-- arrive after handleEndWantedDelete() has run are silently discarded.  The gate is
-- opened again on the first cycle where the player is wanted again.
local spawnGate = true

local disableAIPolice = nil -- Toggle to turn AI police response on and off if players are online or not if that config option is used. 

local playerHasShot = false

-- Arrest system state
local isSurrendering = false
local isBeingArrested = false

-- Traffic ticket state. Declared up here rather than in the ticket section
-- because the chase loop (~1200 lines below, still above that section) has to
-- read them to know a unit is working a roadside stop instead of a pursuit.
--   isPullingOver   you have signalled a stop; nobody is at your window yet
--   isBeingTicketed an officer is at the window writing
--   ticketWrapUp    citation handed over, units driving off, wanted not yet cleared
local isPullingOver   = false
local isBeingTicketed = false
local ticketWrapUp    = false


-- [Upstate Mafia patch] Forward declaration. isPlayerPoliceOfficer is defined
-- ~2250 lines below as a file-scope local, so every reference above its
-- definition resolved to a nil GLOBAL instead. That silently disabled
-- Config.PoliceWantedProtection in both wanted-level entry points: the guard
-- read `and isPlayerPoliceOfficer` (nil -> falsy) and always fell through to
-- applying the level. Declaring it here puts it in scope for them.
--
-- Note both call sites also lacked `()`. A function reference is always truthy,
-- so fixing only the scoping would have flipped the bug the other way and
-- blocked wanted levels for everyone. Both fixes have to land together.
local isPlayerPoliceOfficer

-- EXPORTS --
function ApplyWantedLevel(level)
    Citizen.CreateThread(function()
        if Config.PoliceWantedProtection and isPlayerPoliceOfficer() then
            -- If wanted protection is enabled and the player is a cop we skip doing anything
        else
            -- Apply wanted
            local wantedLevel = GetPlayerWantedLevel(PlayerId())
            local newWanted = wantedLevel + level
            if newWanted > 5 then
                newWanted = 5
            end
            ClearPlayerWantedLevel(PlayerId())
            SetPlayerWantedLevelNow(PlayerId(),false)
            Citizen.Wait(10)
            SetPlayerWantedLevel(PlayerId(),newWanted,false)
            SetPlayerWantedLevelNow(PlayerId(),false)
            local playerVehicle = GetVehiclePedIsIn(PlayerPedId(), true)
            if playerVehicle ~= 0 then
                SetVehicleIsWanted(playerVehicle, true)
            end
        end
        
    end)
end
exports('ApplyWantedLevel', ApplyWantedLevel)
-- Use this in other scripts by calling the function like below. 
-- This allows you to set a wanted level from a script action that the normal GTA V code would not consider.
-- For eg. a robery script, chop-shop script, car theft mission etc. might call this to set a wanted level.
--  exports['fenix-police']:ApplyWantedLevel(wantedLevelHere)

RegisterNetEvent('fenix-police:client:ApplyWantedLevel', function(level)
    exports['fenix-police']:ApplyWantedLevel(level)
end)


function SetWantedLevel(level)
    Citizen.CreateThread(function()
        if Config.PoliceWantedProtection and isPlayerPoliceOfficer() then
            -- If wanted protection is enabled and the player is a cop we skip doing anything
        else
            -- Apply wanted
            local wantedLevel = GetPlayerWantedLevel(PlayerId())
            local newWanted = level
            if level < wantedLevel then
                newWanted = wantedLevel
            else
                newWanted = level
            end
            ClearPlayerWantedLevel(PlayerId())
            SetPlayerWantedLevelNow(PlayerId(),false)
            Citizen.Wait(10)
            SetPlayerWantedLevel(PlayerId(),newWanted,false)
            SetPlayerWantedLevelNow(PlayerId(),false)
            local playerVehicle = GetVehiclePedIsIn(PlayerPedId(), true)
            if playerVehicle ~= 0 then
                SetVehicleIsWanted(playerVehicle, true)
            end
        end
    end)
end
exports('SetWantedLevel', SetWantedLevel)

RegisterNetEvent('fenix-police:client:SetWantedLevel', function(level)
    exports['fenix-police']:SetWantedLevel(level)
end)
-- Use this in other scripts by calling the function like below. 
-- This allows you to set a wanted level from a script action that the normal GTA V code would not consider.
-- For eg. a robery script, chop-shop script, car theft mission etc. might call this to set a wanted level.
--  exports['fenix-police']:SetWantedLevel(wantedLevelHere)




-- **HELPER FUNCTIONS** --



-- SPAWNING --

-- Get player zone for determining spawn tables
local function getPlayerZoneCode()
    local playerPed = PlayerPedId()
    local playerCoords = GetEntityCoords(playerPed)

    -- Get the zone name from the player's coordinates
    local zoneName = GetNameOfZone(playerCoords.x, playerCoords.y, playerCoords.z)
    
    return zoneName
end




-- Function to get the formatted zone key
local function getZoneKey(zoneName)
    return Config.ZoneEnum[zoneName] or zoneName  -- Return the mapped key or the original zoneName if not found
end




-- Function to get a safe spawn point on a road near the player.
--
-- The placement itself lives in client/roads.lua, which resolves the sample
-- point to a real road and returns a lane centre with a legal heading rather
-- than the raw vehicle node -- see that file's header for why the raw node is
-- wrong. This function is the pursuit system's view of it: rear-arc bias so
-- units do not appear in front of the player, and the configured spawn band.
--
-- Returns coords, heading -- or nil, which callers must handle. Failing to find
-- a spot is a normal outcome now: it is what happens when the player is airside,
-- offshore or somewhere with no real road in range, and spawning anyway is the
-- behaviour being removed.
local function getSafeSpawnPoint(playerCoords, minDistance, maxDistance, playerForward)
    local pos, heading = FenixRoads.findSpawnPoint(playerCoords, {
        minDistance  = minDistance,
        maxDistance  = maxDistance,
        behindVector = playerForward,
        towards      = playerCoords,
    })
    if pos then return pos, heading end

    -- Widening the band once covers the common near-miss: the player is on a
    -- long rural road where the only qualifying tarmac is just past maxDistance.
    pos, heading = FenixRoads.findSpawnPoint(playerCoords, {
        minDistance  = minDistance,
        maxDistance  = maxDistance * 1.75,
        behindVector = playerForward,
        towards      = playerCoords,
    })
    if pos then return pos, heading end

    -- Last resort, and the only pass that will place a unit ahead of the player.
    -- Strictly-behind is right almost always, but "almost" is doing work: park
    -- facing the end of a cul-de-sac and there is no road behind you at all, and
    -- a response that never arrives is worse than one you saw coming. The front
    -- cone stays excluded (0.7 is a 90-degree arc), so this can put a unit
    -- alongside or diagonally ahead but never straight into the windscreen.
    return FenixRoads.findSpawnPoint(playerCoords, {
        minDistance   = minDistance,
        maxDistance   = maxDistance * 1.75,
        behindVector  = playerForward,
        towards       = playerCoords,
        maxForwardDot = 0.7,
    })
end




-- Get air unit spawn point within range
local function getRandomPointInRange(playerCoords, minDistance, maxDistance, minHeight, maxHeight)
    local minDist = minDistance -- or 300 -- can uncomment this to default, but I want a debug message for now. "somevar = anothervar or defaultvalue" syntax will default if first is nil
    local maxDist = maxDistance -- or 500
    
    if not minDistance then
        if Config.isDebug then print('GetRandomPointInRange: minDistance was nil, using default') end
        minDist = 300 -- Some fallback defaults
    end
    if not maxDistance then
        if Config.isDebug then print('GetRandomPointInRange: maxDistance was nil, using default') end
        maxDist = 500 -- Some fallback defaults
    end

    local offsetX = math.random(minDist, maxDist)
    local offsetY = math.random(minDist, maxDist)
    if math.random(0, 1) == 0 then offsetX = -offsetX end
    if math.random(0, 1) == 0 then offsetY = -offsetY end

    local x = playerCoords.x + offsetX
    local y = playerCoords.y + offsetY
    local z = playerCoords.z + math.random(minHeight, maxHeight) 
    return vector3(x, y, z)
end




-- VEHICLE FUNCTIONS --

-- Function to check if a vehicle contains any ped
local function isVehicleOccupied(vehicle)
    if DoesEntityExist(vehicle) then
        for seat = -1, GetVehicleMaxNumberOfPassengers(vehicle) do
            local ped = GetPedInVehicleSeat(vehicle, seat)
            if ped and ped ~= 0 then
                return true -- There is a ped in the vehicle
            end
        end
    end
    return false -- No ped found in the vehicle
end




-- Check if the vehicle seems stuck
function IsVehicleStuck(vehicle)
    if not DoesEntityExist(vehicle) or not IsPedInAnyVehicle(GetPedInVehicleSeat(vehicle, -1), false) then
        return false
    end

    local vehicleSpeed = GetEntitySpeed(vehicle)
    local isStuck = false

    if vehicleSpeed < 0.2 then
        local stuckTime = 0
        while vehicleSpeed < 0.2 and stuckTime < 8000 do -- Check if the vehicle is stuck for 8 seconds
            Citizen.Wait(1000)
            vehicleSpeed = GetEntitySpeed(vehicle)
            stuckTime = stuckTime + 1000
        end

        -- If stuck for 8 seconds continuously set isStuck = true. 
        if stuckTime >= 8000 then
            isStuck = true
        end
    end

    return isStuck
end




-- Function to continuously check if a vehicle is stuck
function MonitorVehicle(vehNetID)
    Citizen.CreateThread(function()
        local playerPed = PlayerPedId()

        while GetPlayerWantedLevel(PlayerId()) > 0 and stuckAttempts[vehNetID] ~= 999 do
            local vehicle = NetToVeh(vehNetID) 
            
            -- I've found that one call isn't enough, and it can take multiple NetToVeh calls before it is not nil or == 0 regardless of the time that has passed since spawn. 
            local waitCount = 0
            while (not vehicle or vehicle == 0) and waitCount < Config.controlWaitCount do
                vehicle = NetToVeh(vehNetID)
                Wait(Config.netWaitTime)
                waitCount = waitCount + 1
            end

            if (not vehicle or vehicle == 0) then
                if Config.isDebug then print('MonitorVehicle vehicle ID ' .. vehNetID .. ' NetToVeh still nil or 0, gave up ') end
            else
                if IsVehicleStuck(vehicle) then
                    GetVehicleUnstuck(vehicle, math.random(0, 1) == 0, vehNetID)
                else
                    stuckAttempts[vehNetID] = 0 -- Re-set counter if unstuck, so we can start fresh if it gets stuck
                end
            end
            Citizen.Wait(5000) -- Check every 5 seconds
        end

    end)
end




-- If stuck try reversing and then driving forward left or forward right before going back to task.
-- Usually police ram into things head first and get stuck on walls so reversing and then going left or right might help them get around it.
function GetVehicleUnstuck(vehicle, isLeft, vehNetID)
    local driver = GetPedInVehicleSeat(vehicle, -1) 
    local maxUnstuckAttempts

    if DoesEntityExist(driver) then
        local vehicleId = vehicle

        local playerCoords = GetEntityCoords(playerPed)
        local officerCoords = GetEntityCoords(driver)
        local distance = Vdist(playerCoords.x, playerCoords.y, playerCoords.z, officerCoords.x, officerCoords.y, officerCoords.z)

        if distance > 200 then 
            
            maxUnstuckAttempts = Config.maxFarUnstuckAttempts 

            -- Let's not do anything special if far away, I tried teleportation but it doesn't work well
            if stuckAttempts[vehNetID] == maxUnstuckAttempts then

                -- +1 so it stops trying but not permanently if it somehow gets unstuck again. 
                stuckAttempts[vehNetID] = stuckAttempts[vehNetID] + 1

                -- -- Teleport the vehicle to the nearest road node
                -- local vehCoords = GetEntityCoords(vehicle)
                -- local found, outPosition = GetClosestVehicleNode(vehCoords.x, vehCoords.y, vehCoords.z, 0, 3.0, 0)
                -- if found then
                --     SetEntityCoords(vehicle, outPosition.x, outPosition.y, outPosition.z, false, false, false, true)
                --     SetVehicleOnGroundProperly(vehicle)
                --     stuckAttempts[vehicleId] =  stuckAttempts[vehicleId] + 1 
                --     if Config.isDebug then print('Teleported far stuck vehicle') end
                -- end

    
                -- return  -- Exit the function after teleporting the vehicle

            elseif stuckAttempts[vehNetID] < maxUnstuckAttempts then

                -- Create a task sequence to unstick the vehicle
                local taskSequence = OpenSequenceTask(0)
                
                TaskVehicleTempAction(0, vehicle, 28, 4000) -- Strong brake + reverse
                if isLeft then
                    if Config.isDebug then print('Vehicle ' .. vehNetID .. ' seems stuck, trying to free it left') end
                    TaskVehicleTempAction(0, vehicle, 7, 2000)  -- Turn left + accelerate
                else
                    if Config.isDebug then print('Vehicle ' .. vehNetID .. ' seems stuck, trying to free it right') end
                    TaskVehicleTempAction(0, vehicle, 8, 2000)  -- Turn right + accelerate
                end
                
                TaskVehicleTempAction(0, vehicle, 27, 2000) -- Brake until car stop or until time ends
                CloseSequenceTask(taskSequence)

                -- Clear current tasks and perform the unstick sequence
                ClearPedTasks(driver)
                TaskPerformSequence(driver, taskSequence)
                ClearSequenceTask(taskSequence)
                Wait(10000) -- Wait for 10 seconds so the sequence can execute fully!
                --TaskVehicleDriveToCoord(driver, vehicle, playerCoords.x, playerCoords.y, playerCoords.z, 30.0, 1, GetEntityModel(vehicle), 787004, 5.0, true)
                TaskVehicleChase(driver, playerPed)
                stuckAttempts[vehNetID] =  stuckAttempts[vehNetID] + 1 
            else
                -- Do nothing if we exceeded attempts. 
            end
            

        else 
            maxUnstuckAttempts = Config.maxCloseUnstuckAttempts 

            -- If exactly == max, stop trying to unstick it. Do not make cops abandon
            -- the vehicle; ground units should behave like vanilla police cars, not
            -- spawn/convert into foot patrols.
            if stuckAttempts[vehNetID] == maxUnstuckAttempts then
                if Config.isDebug then print('Nearby police vehicle stuck too long; stopping unstick attempts') end
                stuckAttempts[vehNetID] = 999

                return
            elseif stuckAttempts[vehNetID] < maxUnstuckAttempts then

                -- Create a task sequence to unstick the vehicle
                local taskSequence = OpenSequenceTask(0)
                
                TaskVehicleTempAction(0, vehicle, 28, 4000) -- Strong brake + reverse
                if isLeft then
                    if Config.isDebug then print('Vehicle ' .. vehNetID .. ' seems stuck, trying to free it left') end
                    TaskVehicleTempAction(0, vehicle, 7, 2000)  -- Turn left + accelerate
                else
                    if Config.isDebug then print('Vehicle ' .. vehNetID .. ' seems stuck, trying to free it right') end
                    TaskVehicleTempAction(0, vehicle, 8, 2000)  -- Turn right + accelerate
                end
                
                TaskVehicleTempAction(0, vehicle, 27, 2000) -- Brake until car stop or until time ends
                CloseSequenceTask(taskSequence)

                -- Clear current tasks and perform the unstick sequence
                ClearPedTasks(driver)
                TaskPerformSequence(driver, taskSequence)
                ClearSequenceTask(taskSequence)
                Wait(10000) -- Wait for 10 seconds so the sequence can execute fully!
                --TaskVehicleDriveToCoord(driver, vehicle, playerCoords.x, playerCoords.y, playerCoords.z, 30.0, 1, GetEntityModel(vehicle), 787004, 5.0, true)
                TaskVehicleChase(driver, playerPed)
                stuckAttempts[vehNetID] =  stuckAttempts[vehNetID] + 1 
            else
                -- Do nothing if we exceeded attempts. 
            end

        end
    end
end




-- Abandon a vehicle, usually due to being stuck on roof. 
function GetPedsOutOfVehicle(vehicle)
    local seats = GetVehicleModelNumberOfSeats(GetEntityModel(vehicle))
    for i = -1, seats - 2 do
        local ped = GetPedInVehicleSeat(vehicle, i)
        if DoesEntityExist(ped) then
            TaskLeaveVehicle(ped, vehicle, 0)
        end
    end
end




-- Function to handle if the server tried to delete a vehicle and someone was in driver seat still. 
RegisterNetEvent('deleteSpawnedVehicleResponseStolen')
AddEventHandler('deleteSpawnedVehicleResponseStolen', function(vehNetID)
    -- Add to stolen vehicle list to delete later. 
    stolenVehicles[vehNetID] = vehNetID
    if Config.isDebug then print('Added vehicle/heli/air ID ' .. vehNetID .. ' to stolenVehicles table ') end
end)




-- MAIN LOGIC --


-- AIR UNITS --

-- This function will tell the server to spawn a police unit, and the server will pass back the Network ID of the vehicle + officers spawned so the client can handle them. 
local function spawnHeliUnitNet(wantedLevel, spawnTable)
    local playerPed = PlayerPedId()
    local playerCoords = GetEntityCoords(playerPed)   

    -- Get a safe spawn point
    local spawnCoords = getRandomPointInRange(playerCoords, Config.minHeliSpawnDistance, Config.maxHeliSpawnDistance, Config.minHeliSpawnHeight, Config.maxHeliSpawnHeight)

    if not spawnCoords then
        if Config.isDebug then print('No safe spawn point found') end
        return
    end

    TriggerServerEvent('spawnPoliceHeliNet', wantedLevel, playerCoords, spawnCoords, spawnTable)

end




-- This handles the response from the server after a vehicle and officers are spawned, so they can be tasked and otherwise handled by the client. 
RegisterNetEvent('spawnPoliceHeliNetResponse')
AddEventHandler('spawnPoliceHeliNetResponse', function(vehNetID, officers)
    -- Discard in-flight heli spawns that arrived after handleEndWantedDelete() closed the gate.
    if not spawnGate then
        if pendingHeliSpawns > 0 then pendingHeliSpawns = pendingHeliSpawns - 1 end
        -- Server already created this heli — ask it to clean up.
        if vehNetID then
            if officers then
                for _, pedNetID in ipairs(officers) do
                    TriggerServerEvent('deleteSpawnedPed', pedNetID)
                end
            end
            TriggerServerEvent('deleteSpawnedVehicle', vehNetID)
        end
        return
    end

    local playerPed = PlayerPedId()
    local playerCoords = GetEntityCoords(playerPed)


    if vehNetID and officers then
        local vehicle = NetToVeh(vehNetID) -- Try to set the local vehicle entity from the network ID returned by the server

        -- I've found that one call isn't enough, and it can take multiple NetToVeh calls before it is not nil or = 0 regardless of the time that has passed since spawn. 
        local waitCount = 0
        while (not vehicle or vehicle == 0) and waitCount < Config.spawnWaitCount do
            if Config.isDebug then print('HeliSpawn waiting for vehicle = NetToVeh to not be nil or 0') end
            vehicle = NetToVeh(vehNetID)
            Wait(Config.netWaitTime)
            waitCount = waitCount + 1
        end
        --if Config.isDebug then print('CLIENT NetToVeh for netID ' ..vehNetID .. ' returned entityID ' .. vehicle)  end
        --if Config.isDebug then print('CLIENT VehToNet for entityID ' ..vehicle.. ' returned NetID = ' .. VehToNet(vehicle))  end

        NetworkSetNetworkIdDynamic(vehNetID, false)  -- Allow the networked vehicle to be controlled dynamically.
        SetNetworkIdCanMigrate(vehNetID, false) -- Allow the network ID to be migrated to other clients.
        SetNetworkIdExistsOnAllMachines(vehNetID, true)
        SetEntityAsMissionEntity(vehicle, true, true) -- Prevent despawning by game garbage collection

        spawnedHeliUnits[vehNetID] = {vehicle = vehicle, officers = {}, officerTasks = {} }

        for i, pedNetID in ipairs(officers) do 
            local officer = NetToPed(pedNetID)

            local waitCount = 0
            while (not officer or officer == 0) and waitCount < Config.spawnWaitCount do
                if Config.isDebug then print('HeliSpawn waiting for officer = NetToPed to not be nil') end
                officer = NetToPed(pedNetID)
                Wait(Config.netWaitTime)
                waitCount = waitCount + 1
            end
            --if Config.isDebug then print('CLIENT NetToPed for netID ' ..pedNetID .. ' returned entityID ' .. officer)  end
            --if Config.isDebug then print('CLIENT PedToNet for entityID ' ..officer.. ' returned NetID = ' .. PedToNet(officer))  end

            SetHeliBladesFullSpeed(vehicle)
            SetVehicleEngineOn(vehicle, true, true, false)

            NetworkSetNetworkIdDynamic(pedNetID, false)
            SetNetworkIdCanMigrate(pedNetID, false)
            SetNetworkIdExistsOnAllMachines(pedNetID, true)
            SetEntityAsMissionEntity(officer, true, true)

            -- [Upstate Mafia] All combat attributes, weapons, and initial tasks are set
            -- SERVER-SIDE. Client only tracks for ongoing behavior updates.
            if i == 1 then
                spawnedHeliUnits[vehNetID].officerTasks[pedNetID] = 'HeliChase'
            else
                spawnedHeliUnits[vehNetID].officerTasks[pedNetID] = 'CombatPed'
            end

            -- Adds the spawned ped "officer" to the .officers table by key pedNetID so it can be retrieved by key pedNetID later.
            spawnedHeliUnits[vehNetID].officers[pedNetID] = officer
        end

    end

    if pendingHeliSpawns > 0 then pendingHeliSpawns = pendingHeliSpawns - 1 end

end)




-- This function will tell the server to spawn a police unit, and the server will pass back the Network ID of the vehicle + officers spawned so the client can handle them. 
local function spawnAirUnitNet(wantedLevel, spawnTable)
    local playerPed = PlayerPedId()
    local playerCoords = GetEntityCoords(playerPed)   


    -- Get a safe spawn point
    local spawnCoords = getRandomPointInRange(playerCoords, Config.minAirSpawnDistance, Config.maxAirSpawnDistance, Config.minAirSpawnHeight, Config.maxAirSpawnHeight)

    if not spawnCoords then
        if Config.isDebug then print('No safe spawn point found') end
        return
    end

    TriggerServerEvent('spawnPoliceAirNet', wantedLevel, playerCoords, spawnCoords, spawnTable)

end




-- This handles the response from the server after a vehicle and officers are spawned, so they can be tasked and otherwise handled by the client.
RegisterNetEvent('spawnPoliceAirNetResponse')
AddEventHandler('spawnPoliceAirNetResponse', function(vehNetID, officers)
    -- Discard in-flight air spawns that arrived after handleEndWantedDelete() closed the gate.
    if not spawnGate then
        if pendingAirSpawns > 0 then pendingAirSpawns = pendingAirSpawns - 1 end
        if vehNetID then
            if officers then
                for _, pedNetID in ipairs(officers) do
                    TriggerServerEvent('deleteSpawnedPed', pedNetID)
                end
            end
            TriggerServerEvent('deleteSpawnedVehicle', vehNetID)
        end
        return
    end

    local playerPed = PlayerPedId()
    local playerCoords = GetEntityCoords(playerPed)   


    if vehNetID and officers then
        local vehicle = NetToVeh(vehNetID) -- Try to set the local vehicle entity from the network ID returned by the server

        -- I've found that one call isn't enough, and it can take multiple NetToVeh calls before it is not nil or = 0 regardless of the time that has passed since spawn. 
        local waitCount = 0
        while (not vehicle or vehicle == 0) and waitCount < Config.spawnWaitCount do
            if Config.isDebug then print('AirSpawn waiting for vehicle = NetToVeh to not be nil or 0') end
            vehicle = NetToVeh(vehNetID)
            Wait(Config.netWaitTime)
            waitCount = waitCount + 1
        end
        --if Config.isDebug then print('CLIENT NetToVeh for netID ' ..vehNetID .. ' returned entityID ' .. vehicle)  end
        --if Config.isDebug then print('CLIENT VehToNet for entityID ' ..vehicle.. ' returned NetID = ' .. VehToNet(vehicle))  end

        SetHeliBladesFullSpeed(vehicle)
        SetVehicleEngineOn(vehicle, true, true, false)

        NetworkSetNetworkIdDynamic(vehNetID, false)  -- Allow the networked vehicle to be controlled dynamically.
        SetNetworkIdCanMigrate(vehNetID, false) -- Allow the network ID to be migrated to other clients.
        SetNetworkIdExistsOnAllMachines(vehNetID, true)
        SetEntityAsMissionEntity(vehicle, true, true) -- Prevent despawning by game garbage collection

        spawnedAirUnits[vehNetID] = {vehicle = vehicle, officers = {}, officerTasks = {} }

        for i, pedNetID in ipairs(officers) do 
            local officer = NetToPed(pedNetID)

            local waitCount = 0
            while (not officer or officer == 0) and waitCount < Config.spawnWaitCount do
                if Config.isDebug then print('AirSpawn waiting for officer = NetToPed to not be nil') end
                officer = NetToPed(pedNetID)
                Wait(Config.netWaitTime)
                waitCount = waitCount + 1
            end
            --if Config.isDebug then print('CLIENT NetToPed for netID ' ..pedNetID .. ' returned entityID ' .. officer)  end
            --if Config.isDebug then print('CLIENT PedToNet for entityID ' ..officer.. ' returned NetID = ' .. PedToNet(officer))  end

            NetworkSetNetworkIdDynamic(pedNetID, false)
            SetNetworkIdCanMigrate(pedNetID, false)
            SetNetworkIdExistsOnAllMachines(pedNetID, true)
            SetEntityAsMissionEntity(officer, true, true)

            ControlLandingGear(vehicle, 3) -- Retract the gear

            -- [Upstate Mafia] All combat attributes, weapons, and tasks set SERVER-SIDE.
            if i == 1 then
                spawnedAirUnits[vehNetID].officerTasks[pedNetID] = 'PlaneChase'
            else
                spawnedAirUnits[vehNetID].officerTasks[pedNetID] = 'CombatPed'
            end

            -- Adds the spawned ped "officer" to the .officers table by key pedNetID so it can be retrieved by key pedNetID later.
            spawnedAirUnits[vehNetID].officers[pedNetID] = officer
        end

    end

    if pendingAirSpawns > 0 then pendingAirSpawns = pendingAirSpawns - 1 end

end)




-- GROUND UNITS --

-- This function will tell the server to spawn a police unit, and the server will pass back the Network ID of the vehicle + officers spawned so the client can handle them. 
local function spawnPoliceUnitNet(wantedLevel)
    print(('[FENIX-SPAWN] spawnPoliceUnitNet called, wantedLevel=%d'):format(wantedLevel))
    local playerPed = PlayerPedId()
    local playerCoords = GetEntityCoords(playerPed)
    local zoneCode = getPlayerZoneCode() -- Zone for determining spawnlists
    local zone = Config.zones[zoneCode]
    local regionCode = nil
    if zone then
        regionCode = getZoneKey(zone.location)
    else
        print(('[FENIX-SPAWN] WARNING: no zone for code=%s, defaulting losSantos'):format(tostring(zoneCode)))
        regionCode = 'losSantos'
    end
    print(('[FENIX-SPAWN] zone=%s region=%s'):format(tostring(zoneCode), tostring(regionCode)))

    -- Get a safe spawn point
    local spawnPoint, spawnHeading = getSafeSpawnPoint(playerCoords, Config.minPoliceSpawnDistance, Config.maxPoliceSpawnDistance, GetEntityForwardVector(playerPed))
    if not spawnPoint then
        -- Not an error. There is genuinely nowhere legal to put a car when the
        -- player is on a runway, out at sea or deep in the hills, and the whole
        -- point of the road checks is that we skip the dispatch instead of
        -- inventing a spot. The next spawn tick tries again.
        if Config.isDebug or (Config.Roads and Config.Roads.debug) then
            print('[FENIX-SPAWN] no legal road spawn point in range, skipping this unit')
        end
        if pendingGroundSpawns > 0 then pendingGroundSpawns = pendingGroundSpawns - 1 end
        return
    end
    print(('[FENIX-SPAWN] sending server event, spawnPoint=%.1f,%.1f,%.1f'):format(spawnPoint.x, spawnPoint.y, spawnPoint.z))

    TriggerServerEvent('spawnPoliceUnitNet', wantedLevel, playerCoords, regionCode, spawnPoint, spawnHeading)

end




local function requestModelLoaded(modelHash)
    RequestModel(modelHash)
    local waitCount = 0
    while not HasModelLoaded(modelHash) and waitCount < 100 do
        Wait(10)
        waitCount = waitCount + 1
    end
    return HasModelLoaded(modelHash)
end

local function pickLoadoutWeapon(items)
    local totalWeight = 0
    for _, item in ipairs(items) do totalWeight = totalWeight + item.weight end
    if totalWeight <= 0 then return nil end

    local roll = math.random() * totalWeight
    local currentWeight = 0
    for _, item in ipairs(items) do
        currentWeight = currentWeight + item.weight
        if roll <= currentWeight then return item.name end
    end
end

local function giveClientPedLoadout(ped, loadout)
    if not DoesEntityExist(ped) or not loadout then return end

    local primaryWeapon = pickLoadoutWeapon(loadout.primaryWeapons)
    if primaryWeapon then
        GiveWeaponToPed(ped, GetHashKey(primaryWeapon), 999, false, true)
        SetCurrentPedWeapon(ped, GetHashKey(primaryWeapon), true)
    end

    if loadout.secondaryWeapons and #loadout.secondaryWeapons > 0 and math.random() < loadout.secondaryChance then
        local secondaryWeapon = pickLoadoutWeapon(loadout.secondaryWeapons)
        if secondaryWeapon then
            GiveWeaponToPed(ped, GetHashKey(secondaryWeapon), 999, false, false)
        end
    end

    if math.random() < loadout.armorChance then
        SetPedArmour(ped, loadout.armorValue)
    end
end

-- ============================================================================
-- OFFICER COMBAT PROFILE
-- Scales accuracy, rate of fire and willingness to open fire with the wanted
-- level so low-level chases stay pursuits instead of instant firefights.
-- See Config.Combat.
-- ============================================================================

-- Timestamp (GetGameTimer) until which every officer is treated as fully
-- hostile because the player shot or damaged one of them.
local provokedUntil = 0

-- Cached hash of the runtime-created pursuit-only relationship group.
local passiveGroupHash = nil

local function combatEnabled()
    return Config.Combat ~= nil and Config.Combat.enabled ~= false
end

local function isProvoked()
    return provokedUntil > 0 and GetGameTimer() < provokedUntil
end

local function provokePolice()
    local duration = Config.Combat and Config.Combat.provokedDuration or 30000
    if duration <= 0 then return end
    provokedUntil = GetGameTimer() + duration
end

-- Reads a per-wanted-level value out of a Config.Combat table.
local function levelValue(tbl, wantedLevel, default)
    if type(tbl) ~= 'table' then return default end
    local value = tbl[wantedLevel]
    if value == nil then return default end
    return value
end

-- Officers in pursuit-only mode need a relationship group that will not make
-- them start a fight on their own. COP is not safe for this: the game rewires
-- COP/PLAYER dynamically off the wanted level. A group we own is deterministic.
local function ensurePassiveGroup()
    if passiveGroupHash then return passiveGroupHash end
    local groupName = Config.Combat and Config.Combat.relationshipPassive or 'FENIX_PURSUIT'
    AddRelationshipGroup(groupName)
    -- The group hash is the joaat of its name, so GetHashKey is equivalent to the
    -- out-param AddRelationshipGroup fills and avoids depending on its return shape.
    passiveGroupHash = GetHashKey(groupName)
    -- 1 = Respect. Officers pursue but will not open fire unprovoked.
    SetRelationshipBetweenGroups(1, passiveGroupHash, GetHashKey('PLAYER'))
    SetRelationshipBetweenGroups(1, GetHashKey('PLAYER'), passiveGroupHash)
    return passiveGroupHash
end

-- Rolls whether this officer is one of the ones willing to shoot at this wanted
-- level. Rolled once per officer and stored, so units don't flip every cycle.
local function rollEngage(wantedLevel)
    if not combatEnabled() then return true end
    return math.random() < levelValue(Config.Combat.engageChance, wantedLevel, 1.0)
end

-- Applies the wanted-level-scaled combat profile to one officer.
-- `engages` is that officer's stored open-fire roll. `role` is 'air' for
-- helicopter and aircraft crews, which use their own firing pattern.
-- Returns true if the officer should be given a combat task this cycle.
local function applyOfficerCombatProfile(officer, wantedLevel, engages, role)
    if not DoesEntityExist(officer) or officer == 0 then return false end

    if not combatEnabled() then
        -- Legacy always-hostile behaviour.
        SetPedAccuracy(officer, math.random(25, 50))
        SetPedRelationshipGroupHash(officer, GetHashKey('HATES_PLAYER'))
        SetPedFiringPattern(officer, GetHashKey('FIRING_PATTERN_FULL_AUTO'))
        SetPedCombatAttributes(officer, 2, true)
        SetPedCombatAttributes(officer, 46, true)
        return true
    end

    local cfg = Config.Combat
    local provoked = isProvoked()
    local hostile = provoked or engages == true or wantedLevel >= (cfg.hostileFromLevel or 4)

    local accuracy = levelValue(cfg.accuracy, wantedLevel, nil)
    if accuracy then
        SetPedAccuracy(officer, math.random(accuracy[1], accuracy[2]))
    end

    SetPedShootRate(officer, levelValue(cfg.shootRate, wantedLevel, 100))
    SetPedCombatAbility(officer, levelValue(cfg.combatAbility, wantedLevel, 1))
    SetPedCombatRange(officer, levelValue(cfg.combatRange, wantedLevel, 1))

    -- Full auto only once things are serious. Burst fire keeps early chases
    -- survivable. Air crews get the base game's mounted-weapon pattern instead.
    local pattern
    if role == 'air' then
        pattern = cfg.firingPatternHeli or 'FIRING_PATTERN_BURST_FIRE_HELI'
    elseif provoked or wantedLevel >= (cfg.fullAutoFromLevel or 5) then
        pattern = cfg.firingPatternAuto or 'FIRING_PATTERN_FULL_AUTO'
    else
        pattern = cfg.firingPatternBurst or 'FIRING_PATTERN_BURST_FIRE'
    end
    SetPedFiringPattern(officer, GetHashKey(pattern))

    -- 24 off: the base game clears this attribute on every ped it gives an
    -- explicit SetPedShootRate to, so it doesn't fight the rate we just set.
    SetPedCombatAttributes(officer, 24, false)

    -- 2 = CanDoDrivebys. Held back until the shootout tiers.
    SetPedCombatAttributes(officer, 2, provoked or wantedLevel >= (cfg.drivebyFromLevel or 4))
    -- 46 = AlwaysFight. Off below the hostile threshold so officers only return
    -- fire when engaged instead of opening up the moment they see the player.
    SetPedCombatAttributes(officer, 46, hostile)

    if hostile then
        SetPedRelationshipGroupHash(officer, GetHashKey(cfg.relationshipHostile or 'HATES_PLAYER'))
    else
        SetPedRelationshipGroupHash(officer, ensurePassiveGroup())
    end

    return hostile
end

-- Escalates every unit if the player has damaged this officer since last check.
local function checkOfficerProvocation(officer, playerPed)
    if not combatEnabled() then return end
    if HasEntityBeenDamagedByEntity(officer, playerPed, true) then
        provokePolice()
        ClearEntityLastDamageEntity(officer)
    end
end

RegisterNetEvent('fenix-police:spawnPoliceUnitClient')
AddEventHandler('fenix-police:spawnPoliceUnitClient', function(vehicleInfo, pedModels, spawnPoint, spawnHeading, spawnTicket)
    -- Discard in-flight spawns that arrived after handleEndWantedDelete() cleared the gate.
    -- This prevents the race condition where a server response arrives after cleanup and
    -- re-populates spawnedVehicles with cops that will never be cleaned up.
    if not spawnGate then
        if pendingGroundSpawns > 0 then pendingGroundSpawns = pendingGroundSpawns - 1 end
        return
    end
    local playerPed = PlayerPedId()
    local vehicleHash = GetHashKey(vehicleInfo.model)

    if not requestModelLoaded(vehicleHash) then
        print(('[FENIX-SPAWN] failed to load vehicle model %s'):format(tostring(vehicleInfo.model)))
        if pendingGroundSpawns > 0 then pendingGroundSpawns = pendingGroundSpawns - 1 end
        return
    end

    local vehicle = CreateVehicle(vehicleHash, spawnPoint.x, spawnPoint.y, spawnPoint.z, spawnHeading or 0.0, true, true)
    if not DoesEntityExist(vehicle) then
        print(('[FENIX-SPAWN] failed to create vehicle %s client-side'):format(tostring(vehicleInfo.model)))
        if pendingGroundSpawns > 0 then pendingGroundSpawns = pendingGroundSpawns - 1 end
        return
    end

    SetEntityAsMissionEntity(vehicle, true, true)
    SetVehicleDoorsLocked(vehicle, 1)
    SetVehicleOnGroundProperly(vehicle)
    SetVehicleSiren(vehicle, true)
    SetSirenKeepOn(vehicle, true)

    local vehNetID = VehToNet(vehicle)
    NetworkSetNetworkIdDynamic(vehNetID, false)
    SetNetworkIdCanMigrate(vehNetID, false)
    SetNetworkIdExistsOnAllMachines(vehNetID, true)

    local officers = {}
    -- pedNetID -> bool: whether this officer rolled "willing to open fire" for the
    -- wanted level they spawned at. Kept for the officer's lifetime.
    local engageFlags = {}
    local spawnWantedLevel = GetPlayerWantedLevel(PlayerId())
    local pedCount = vehicleInfo.numPeds or #pedModels
    local maxSeats = GetVehicleModelNumberOfSeats(vehicleHash)
    if maxSeats and maxSeats > 0 then
        pedCount = math.min(pedCount, maxSeats)
    end

    for seatIndex = -1, pedCount - 2 do
        local modelName = pedModels[((seatIndex + 2 - 1) % #pedModels) + 1]
        local pedHash = GetHashKey(modelName)
        if requestModelLoaded(pedHash) then
            -- Create ped on foot first so loadout is applied before seating.
            -- GiveWeaponToPed does not reliably persist when called on an already-seated ped.
            local officer = CreatePed(4, pedHash, spawnPoint.x, spawnPoint.y, spawnPoint.z, spawnHeading or 0.0, true, true)
            local pedWait = 0
            while (not DoesEntityExist(officer) or officer == 0) and pedWait < 30 do
                Wait(10)
                pedWait = pedWait + 1
            end
            if DoesEntityExist(officer) and officer ~= 0 then
                SetEntityAsMissionEntity(officer, true, true)
                SetPedCombatAttributes(officer, 0, true)
                SetPedCombatAttributes(officer, 1, true)
                SetPedCombatAttributes(officer, 3, false)
                SetPedCombatAttributes(officer, 5, true)
                SetPedFleeAttributes(officer, 0, false)
                -- Drive-bys (2), always-fight (46), accuracy, shoot rate, firing
                -- pattern and relationship group are all set by wanted level.
                local officerEngages = rollEngage(spawnWantedLevel)
                applyOfficerCombatProfile(officer, spawnWantedLevel, officerEngages)
                -- Give loadout while on foot (pre-seat pass).
                giveClientPedLoadout(officer, Config.loadouts[vehicleInfo.loadout])
                -- Now seat the ped
                SetPedIntoVehicle(officer, vehicle, seatIndex)
                Wait(100)
                if GetPedInVehicleSeat(vehicle, seatIndex) == officer then
                    -- Client-side re-give (belt)
                    giveClientPedLoadout(officer, Config.loadouts[vehicleInfo.loadout])
                    local pedNetID = PedToNet(officer)
                    NetworkSetNetworkIdDynamic(pedNetID, false)
                    SetNetworkIdCanMigrate(pedNetID, false)
                    SetNetworkIdExistsOnAllMachines(pedNetID, true)
                    -- Server-side arm (suspenders): GiveWeaponToPed on client-created
                    -- networked peds is silently discarded by FiveM's sync layer in some
                    -- configurations.  The server is always authoritative, so arming from
                    -- the server-side is the only reliable guarantee.
                    TriggerServerEvent('fenix-police:rearmOfficer', pedNetID, vehicleInfo.loadout)
                    engageFlags[pedNetID] = officerEngages
                    table.insert(officers, pedNetID)
                else
                    DeleteEntity(officer)
                end
            end
            SetModelAsNoLongerNeeded(pedHash)
        end
    end

    local driver = GetPedInVehicleSeat(vehicle, -1)
    if not DoesEntityExist(driver) or driver == 0 then
        print(('[FENIX-SPAWN] deleting driverless client police vehicle %s'):format(tostring(vehicleInfo.model)))
        for _, pedNetID in ipairs(officers) do
            local ped = NetToPed(pedNetID)
            if DoesEntityExist(ped) then DeleteEntity(ped) end
        end
        DeleteEntity(vehicle)
        if pendingGroundSpawns > 0 then pendingGroundSpawns = pendingGroundSpawns - 1 end
        return
    end

    -- Tell the server what we actually created, quoting the ticket it issued
    -- with the authorisation. Until this lands the server has no record of these
    -- entities, and every later request to delete, unlock or re-arm one is
    -- judged on model alone -- see server/guard.lua.
    TriggerServerEvent('fenix-police:registerSpawnedUnit', spawnTicket, vehNetID, officers)

    spawnedVehicles[vehNetID] = { vehicle = vehicle, officers = {}, officerTasks = {}, officerEngage = engageFlags, clientOwned = true, loadout = vehicleInfo.loadout }

    for i, pedNetID in ipairs(officers) do
        spawnedVehicles[vehNetID].officers[pedNetID] = NetToPed(pedNetID)
        spawnedVehicles[vehNetID].officerTasks[pedNetID] = i == 1 and 'VehicleChase' or 'Standby'
    end

    TaskVehicleDriveToCoord(driver, vehicle, GetEntityCoords(playerPed).x, GetEntityCoords(playerPed).y, GetEntityCoords(playerPed).z, 42.0, 1, GetEntityModel(vehicle), 6, 2.0, true)
    SetDriveTaskDrivingStyle(driver, 6)
    SetDriverAbility(driver, 1.0)
    SetDriverAggressiveness(driver, 1.0)

    -- Only passengers who rolled hostile for this wanted level get a combat task.
    -- The rest ride along; handleChaseBehavior promotes them if the level rises
    -- or the player provokes the unit.
    for i = 2, #officers do
        local pedNetID = officers[i]
        local officer = NetToPed(pedNetID)
        if DoesEntityExist(officer) then
            local hostile = applyOfficerCombatProfile(officer, spawnWantedLevel, engageFlags[pedNetID])
            if hostile then
                TaskCombatPed(officer, playerPed, 0, 16)
                spawnedVehicles[vehNetID].officerTasks[pedNetID] = 'CombatPed'
            end
        end
    end

    MonitorVehicle(vehNetID)
    SetModelAsNoLongerNeeded(vehicleHash)
    if pendingGroundSpawns > 0 then pendingGroundSpawns = pendingGroundSpawns - 1 end
end)


-- This handles the response from the server after a vehicle and officers are spawned, so they can be tasked and otherwise handled by the client. 
RegisterNetEvent('spawnPoliceUnitNetResponse')
AddEventHandler('spawnPoliceUnitNetResponse', function(vehNetID, officers)
    print(('[FENIX-SPAWN] got server response: vehNetID=%s officers=%s'):format(tostring(vehNetID), tostring(officers and #officers or 'nil')))

    local playerPed = PlayerPedId()
    local playerCoords = GetEntityCoords(playerPed)


    if vehNetID and officers then
        local vehicle = NetToVeh(vehNetID) -- Try to set the local vehicle entity from the network ID returned by the server

        -- I've found that one call isn't enough, and it can take multiple NetToVeh calls before it is not nil or = 0 regardless of the time that has passed since spawn. 
        local waitCount = 0
        while (not vehicle or vehicle == 0) and waitCount < Config.spawnWaitCount do
            if Config.isDebug then print('UnitSpawn waiting for vehicle = NetToVeh to not be nil or 0') end
            vehicle = NetToVeh(vehNetID)
            Wait(Config.netWaitTime)
            waitCount = waitCount + 1
        end
        --if Config.isDebug then print('CLIENT NetToVeh for netID ' ..vehNetID .. ' returned entityID ' .. vehicle)  end
        --if Config.isDebug then print('CLIENT VehToNet for entityID ' ..vehicle.. ' returned NetID = ' .. VehToNet(vehicle))  end

        NetworkSetNetworkIdDynamic(vehNetID, false)
        SetNetworkIdCanMigrate(vehNetID, false)
        SetNetworkIdExistsOnAllMachines(vehNetID, true)
        SetEntityAsMissionEntity(vehicle, true, true)

        spawnedVehicles[vehNetID] = {vehicle = vehicle, officers = {}, officerTasks = {} }

        for i, pedNetID in ipairs(officers) do
            local officer = NetToPed(pedNetID)

            local waitCount = 0
            while (not officer or officer == 0) and waitCount < Config.spawnWaitCount do
                if Config.isDebug then print('UnitSpawn waiting for officer = NetToPed to not be nil') end
                officer = NetToPed(pedNetID)
                Wait(Config.netWaitTime)
                waitCount = waitCount + 1
            end

            if not officer or officer == 0 then
                print(('[FENIX] WARNING: officer entity never resolved for pedNetID=%s'):format(tostring(pedNetID)))
            end

            NetworkSetNetworkIdDynamic(pedNetID, false)
            SetNetworkIdCanMigrate(pedNetID, false)
            SetNetworkIdExistsOnAllMachines(pedNetID, true)
            SetEntityAsMissionEntity(officer, true, true)

            -- [Upstate Mafia] Combat attributes + weapons + initial tasks are all set
            -- SERVER-SIDE now (server owns the entity). The client only tracks the entity
            -- for ongoing chase behavior updates (re-tasking when tasks complete).
            -- Set initial task status to match what the server assigned.
            if i == 1 then
                spawnedVehicles[vehNetID].officerTasks[pedNetID] = 'VehicleChase'
            else
                spawnedVehicles[vehNetID].officerTasks[pedNetID] = 'CombatPed'
            end
            
            -- Adds the spawned ped "officer" to the .officers table by key pedNetID so it can be retrieved by key pedNetID later. 
            spawnedVehicles[vehNetID].officers[pedNetID] = officer
        end

        -- Will check if vehicle is stuck and try to free it.
        MonitorVehicle(vehNetID)

    end

    if pendingGroundSpawns > 0 then pendingGroundSpawns = pendingGroundSpawns - 1 end

end)





-- Function to maintain the desired number of police units
local function maintainPoliceUnits(wantedLevel)
    local playerPed = PlayerPedId()
    local playerVeh = GetVehiclePedIsIn(playerPed, false)

    local maxUnits = Config.maxUnitsPerLevel[wantedLevel] or 0
    local currentUnits = 0

    local maxHeliUnits = Config.maxHeliUnitsPerLevel[wantedLevel] or 0
    local currentHeliUnits = 0

    local maxAirUnits = Config.maxAirUnitsPerLevel[wantedLevel] or 0
    local currentAirUnits = 0


    -- Do Ground Units --
    local spawnGroundUnits = false
    if playerVeh ~= 0 then
        if IsThisModelAPlane(GetEntityModel(playerVeh)) then
            -- Player is in a plane
            spawnGroundUnits = Config.spawnGroundUnitsInPlane
        elseif IsThisModelAHeli(GetEntityModel(playerVeh)) then
            -- Player is in a helicopter
            spawnGroundUnits = Config.spawnGroundUnitsInHeli
        else
            -- Player is in a car
            spawnGroundUnits = true
        end
    else
        -- Player is on foot
        spawnGroundUnits = true
    end

    if spawnGroundUnits then
        
        for _, vehicleData in pairs(spawnedVehicles) do
            currentUnits = currentUnits + 1
        end

        --if Config.isDebug then print('currentUnits = ' ..currentUnits.. ' and maxUnits = ' ..maxUnits .. ' and isSpawning = ' .. tostring(isSpawning)) end

        -- Spawn additional units if needed, allowing up to MAX_CONCURRENT_SPAWNS requests in flight at once.
        while currentUnits < maxUnits and pendingGroundSpawns < MAX_CONCURRENT_SPAWNS do
            pendingGroundSpawns = pendingGroundSpawns + 1
            spawnPoliceUnitNet(wantedLevel)
            currentUnits = currentUnits + 1
        end
    end
    

    -- Do Heli Units --
    local heliSpawnTable = nil

    if playerVeh ~= 0 then
        if IsThisModelAPlane(GetEntityModel(playerVeh)) then
            -- Player is in a plane
            -- We don't spawn helis anymore if player is in a plane.
        elseif IsThisModelAHeli(GetEntityModel(playerVeh)) then
            -- Player is in a helicopter
            heliSpawnTable = Config.milHelis
        else
            -- Player is in a car
            heliSpawnTable = Config.polHelis
        end
    else
        -- Player is on foot
        heliSpawnTable = Config.polHelis 
    end

    if heliSpawnTable then
        for _, vehicleData in pairs(spawnedHeliUnits) do
            currentHeliUnits = currentHeliUnits + 1
        end

        --if Config.isDebug then print('currentHeliUnits = ' ..currentHeliUnits.. ' and maxHeliUnits = ' ..maxHeliUnits .. ' and isSpawning = ' .. tostring(isSpawning)) end
        -- Spawn additional units if needed
        while currentHeliUnits < maxHeliUnits and pendingHeliSpawns < MAX_CONCURRENT_SPAWNS do
            pendingHeliSpawns = pendingHeliSpawns + 1
            spawnHeliUnitNet(wantedLevel, heliSpawnTable)
            currentHeliUnits = currentHeliUnits + 1
        end
    end
    


    -- Do Air Units --
    local airSpawnTable = nil

    if playerVeh ~= 0 then
        if IsThisModelAPlane(GetEntityModel(playerVeh)) then
            -- Player is in a plane
            airSpawnTable = Config.milPlanes
        elseif IsThisModelAHeli(GetEntityModel(playerVeh)) then
            -- Player is in a helicopter
            airSpawnTable = Config.milPlanes
        else
            -- Player is in a car
            -- We don't spawn planes anymore if player is in a car
        end
    else
        -- Player is on foot
        -- We don't spawn planes anymore if player is on foot
    end


    if airSpawnTable then
        for _, vehicleData in pairs(spawnedAirUnits) do
            currentAirUnits = currentAirUnits + 1
        end

        --if Config.isDebug then print('currentAirUnits = ' ..currentAirUnits.. ' and maxAirUnits = ' ..maxAirUnits .. ' and isSpawning = ' .. tostring(isSpawning)) end
        -- Spawn additional units if needed
        while currentAirUnits < maxAirUnits and pendingAirSpawns < MAX_CONCURRENT_SPAWNS do
            pendingAirSpawns = pendingAirSpawns + 1
            spawnAirUnitNet(wantedLevel, airSpawnTable)
            currentAirUnits = currentAirUnits + 1
        end
    end
    



end




-- Driving-style bitfields, named because "6" and "262571" appear in enough
-- places to be worth reading.
--   PURSUIT  4 (avoid vehicles) + 2 (stop before peds). No traffic-light bit, so
--            units run reds, and no wrong-way bit, so they stay on their side.
--   SEARCH   the normal-driving field: obey lights, keep to the road. A unit
--            sweeping for a suspect it cannot see is not running reds to do it.
local DRIVING_STYLE_PURSUIT = 6
local DRIVING_STYLE_SEARCH  = 262571

--- Random float in [range[1], range[2]], falling back to the given bounds when
--- no range is configured.
local function randRange(range, fallbackLo, fallbackHi)
    local lo = (range and range[1]) or fallbackLo
    local hi = (range and range[2]) or fallbackHi
    if hi < lo then hi = lo end
    return lo + (math.random() * (hi - lo))
end

--- Per-officer driving profile, rolled once and kept for that officer's lifetime.
---
--- Every driver used to be handed SetDriverAbility(1.0) and
--- SetDriverAggressiveness(1.0), re-applied every cycle. Maximum skill and
--- maximum aggression on everyone meant every unit in every pursuit drove
--- identically: all ramming, all cornering the same, none of them ever making a
--- mistake. Rolling a profile per officer -- the way rollEngage already rolls
--- willingness to open fire -- makes the response a group of individuals, and
--- gives the wanted level somewhere to show up in the driving rather than only
--- in the shooting.
local function officerDrivingProfile(vehicleData, pedNetID, wantedLevel, vehicle)
    vehicleData.officerDriving = vehicleData.officerDriving or {}
    local existing = vehicleData.officerDriving[pedNetID]
    if existing then return existing end

    local c = Config.Driving or {}

    -- Commanded speed follows the car. A riot van and an interceptor were both
    -- told 42 m/s; the van never reached it and spent the pursuit driving like
    -- it was late for something.
    local speed = c.speed or 42.0
    if c.matchVehicleSpeed ~= false and vehicle and vehicle ~= 0 then
        local top = GetVehicleEstimatedMaxSpeed(vehicle)
        if top and top > 5.0 then
            speed = math.min(speed, top * (c.speedFraction or 0.92))
        end
    end

    local profile = {
        ability     = randRange(levelValue(c.ability, wantedLevel, nil), 0.6, 1.0),
        aggression  = randRange(levelValue(c.aggression, wantedLevel, nil), 0.4, 1.0),
        speed       = speed * randRange(c.speedVariance, 0.9, 1.05),
        searchSpeed = c.searchSpeed or 16.0,
    }

    vehicleData.officerDriving[pedNetID] = profile
    return profile
end

-- [Upstate Mafia] Forward declarations: the surrender and traffic-stop handlers
-- are defined ~1200 lines below, alongside the rest of the arrest system, but
-- have to be reachable from the chase loop here.
local handleSurrenderApproach
local handleTicketApproach

-- Function to handle police foot chase and vehicle retrieval
local function handleChaseBehavior(vehicleData, playerPed, vehNetID, playerHasShot)
    -- [Upstate Mafia] Citation written, everyone standing down. The wanted level
    -- hasn't cleared yet (that's what triggers the delete sweep), so without this
    -- the chase loop would re-task the units it just dismissed.
    if ticketWrapUp then return end

    -- [Upstate Mafia] Roadside stop in progress: this unit is either working it
    -- or standing down for it, and either way it isn't chasing.
    if Config.TicketSystem and Config.TicketSystem.enabled and (isPullingOver or isBeingTicketed) then
        if handleTicketApproach(vehicleData, playerPed, vehNetID) then return end
    end

    -- [Upstate Mafia] Hands up: stop chasing, start arresting. Returning early
    -- leaves every combat and driving task below unassigned for this unit, which
    -- is what stops officers shooting a surrendering player.
    if Config.ArrestSystem.enabled and (isSurrendering or isBeingArrested) then
        if handleSurrenderApproach(vehicleData, playerPed, vehNetID) then return end
    end

    local playerCoords = GetEntityCoords(playerPed)
    local wantedLevel = GetPlayerWantedLevel(PlayerId())
    local vehicle = NetToVeh(vehNetID)
        
    -- I've found that one call isn't enough, and it can take multiple NetToVeh calls before it is not nil or == 0 regardless of the time that has passed since spawn. 
    local waitCount = 0
    while (not vehicle or vehicle == 0) and waitCount < Config.controlWaitCount do
        vehicle = NetToVeh(vehNetID)
        Wait(Config.netWaitTime)
        waitCount = waitCount + 1
    end

    if (not vehicle or vehicle == 0) then
        if Config.isDebug then print('HandleChase vehicle ID ' .. vehNetID .. ' NetToVeh still nil or 0, gave up ') end
        return
    end

    for pedNetID, officerData in pairs(vehicleData.officers) do
        local officer = NetToPed(pedNetID)

        local waitCount = 0
        while (not officer or officer == 0) and waitCount < Config.controlWaitCount do
            officer = NetToPed(pedNetID)
            Wait(Config.netWaitTime)
            waitCount = waitCount + 1
        end

        if not DoesEntityExist(officer) or officer == 0 then
            if Config.isDebug then print('HandleChase ped ID ' .. pedNetID .. ' NetToPed still nil or 0, gave up ') end
        else
            local officerCoords = GetEntityCoords(officer)
            local distance = Vdist(playerCoords.x, playerCoords.y, playerCoords.z, officerCoords.x, officerCoords.y, officerCoords.z)

            -- This officer is now a pair of eyes for the pursuit: they get an AI
            -- blip with a view cone, and whether they can see the player feeds
            -- the contact state every unit's tasking reads. Refreshing every
            -- cycle is also how a deleted officer leaves the set -- pursuit.lua
            -- prunes anything that stops being refreshed.
            FenixPursuit.noteObserver(officer, 'ground')

            -- Re-apply the wanted-level combat profile every cycle: GTA's combat AI
            -- resets accuracy/attributes on task changes, and the wanted level (or
            -- provocation state) can have moved since this officer spawned.
            checkOfficerProvocation(officer, playerPed)
            vehicleData.officerEngage = vehicleData.officerEngage or {}
            if vehicleData.officerEngage[pedNetID] == nil then
                vehicleData.officerEngage[pedNetID] = rollEngage(wantedLevel)
            end
            local officerHostile = applyOfficerCombatProfile(officer, wantedLevel, vehicleData.officerEngage[pedNetID])

            -- Far-ped tracking for cleanup
            if distance > Config.officerTooFarDistance then
                if farOfficers[pedNetID] then
                    farOfficers[pedNetID].timer = farOfficers[pedNetID].timer + 1
                else
                    farOfficers[pedNetID] = { officer = officer, timer = 0 }
                end
            else
                farOfficers[pedNetID] = nil
            end

            if IsPedInAnyVehicle(officer, false) then
                -- Back in the car: forget how long they spent getting there.
                if vehicleData.officerReboard then vehicleData.officerReboard[pedNetID] = nil end

                if vehicleData.clientOwned then
                    local polVehicle = GetVehiclePedIsIn(officer, false)
                    -- Re-enforce stay-in-vehicle each cycle so combat AI doesn't override it
                    SetPedCombatAttributes(officer, 3, false)
                    if GetPedInVehicleSeat(polVehicle, -1) == officer then
                        -- Driver. WHERE they drive is now a question for
                        -- client/pursuit.lua rather than a straight read of the
                        -- player's coordinates: units get the player's real
                        -- position only while somebody can actually see them.
                        local profile = officerDrivingProfile(vehicleData, pedNetID, wantedLevel, polVehicle)
                        local target, inContact = FenixPursuit.targetCoords(playerCoords)
                        local taskStatus = spawnedVehicles[vehNetID].officerTasks[pedNetID]

                        if FenixPursuit.isSearching() then
                            -- Contact lost. TaskVehicleChase is not an option
                            -- here: it tracks the player ENTITY, which is
                            -- precisely the omniscience being removed. Drive to
                            -- the last known position, then sweep out from it.
                            --
                            -- Issued on transition only. A wander task re-issued
                            -- every second never gets anywhere, because each
                            -- re-issue picks a fresh direction.
                            local sweepRadius = math.max(25.0, FenixPursuit.searchRadius() * 0.5)
                            if #(GetEntityCoords(polVehicle) - target) < sweepRadius then
                                if taskStatus ~= 'Sweep' then
                                    ClearPedTasks(officer)
                                    TaskVehicleDriveWander(officer, polVehicle, profile.searchSpeed, DRIVING_STYLE_SEARCH)
                                    spawnedVehicles[vehNetID].officerTasks[pedNetID] = 'Sweep'
                                end
                            elseif taskStatus ~= 'ToLastKnown' then
                                TaskVehicleDriveToCoord(officer, polVehicle, target.x, target.y, target.z, profile.speed, 1, GetEntityModel(polVehicle), DRIVING_STYLE_PURSUIT, 8.0, true)
                                spawnedVehicles[vehNetID].officerTasks[pedNetID] = 'ToLastKnown'
                            end
                        elseif distance > 45.0 or not inContact then
                            TaskVehicleDriveToCoord(officer, polVehicle, target.x, target.y, target.z, profile.speed, 1, GetEntityModel(polVehicle), DRIVING_STYLE_PURSUIT, 2.0, true)
                            SetDriveTaskDrivingStyle(officer, DRIVING_STYLE_PURSUIT)
                            spawnedVehicles[vehNetID].officerTasks[pedNetID] = 'VehicleChase'
                        else
                            TaskVehicleChase(officer, playerPed)
                            SetTaskVehicleChaseBehaviorFlag(officer, 8, true)
                            spawnedVehicles[vehNetID].officerTasks[pedNetID] = 'VehicleChase'
                        end

                        SetDriverAbility(officer, profile.ability)
                        SetDriverAggressiveness(officer, profile.aggression)

                        -- Lights stay on throughout; the wail is what stops. A
                        -- unit that has lost the suspect wants to hear the
                        -- street, not announce itself to it.
                        SetVehicleHasMutedSirens(polVehicle, not FenixPursuit.sirenWanted())
                    else
                        -- Passenger: only issue tasks on transition (task caching prevents
                        -- re-issuing every second which causes GTA AI to reconsider exiting)
                        local taskStatus = spawnedVehicles[vehNetID].officerTasks[pedNetID]
                        -- Nobody shoots at a suspect nobody can see. Without the
                        -- contact test a passenger keeps firing through walls at
                        -- the player's live position all the way through a
                        -- search, which gives the hiding place away and reads as
                        -- the aimbot it is.
                        if officerHostile and FenixPursuit.hasContact() then
                            if taskStatus ~= 'CombatPed' then
                                TaskCombatPed(officer, playerPed, 0, 16)
                                spawnedVehicles[vehNetID].officerTasks[pedNetID] = 'CombatPed'
                            end
                        elseif taskStatus ~= 'Standby' then
                            -- De-escalated (wanted level dropped or provocation expired):
                            -- drop the combat task so they ride along instead of shooting.
                            ClearPedTasks(officer)
                            spawnedVehicles[vehNetID].officerTasks[pedNetID] = 'Standby'
                        end
                    end
                    -- Weapon persistence check (runs every cycle for client-owned peds).
                    -- Use server-side rearm: client GiveWeaponToPed on networked peds is
                    -- silently discarded by FiveM sync in some configurations.
                    local bestWeapon = GetBestPedWeapon(officer, false)
                    if bestWeapon == GetHashKey('weapon_unarmed') or bestWeapon == 0 then
                        local loadoutKey = vehicleData.loadout
                        TriggerServerEvent('fenix-police:rearmOfficer', pedNetID, loadoutKey)
                    end
                else
                    -- Non-clientOwned: server owns and handles tasks — just track state
                    spawnedVehicles[vehNetID].officerTasks[pedNetID] = 'VehicleChase'
                end
            else
                -- ---- ON FOOT (police car exists but ped exited, or car destroyed) ----
                local polVehicle = NetToVeh(vehNetID)

                if DoesEntityExist(polVehicle) and polVehicle ~= 0 then
                    -- Car still exists — teleport back in and re-arm
                    if vehicleData.clientOwned then
                        local seat = -1
                        if GetPedInVehicleSeat(polVehicle, -1) ~= 0 then
                            seat = 0
                            local seats = GetVehicleModelNumberOfSeats(GetEntityModel(polVehicle))
                            for candidateSeat = 0, seats - 2 do
                                if GetPedInVehicleSeat(polVehicle, candidateSeat) == 0 then
                                    seat = candidateSeat
                                    break
                                end
                            end
                        end

                        -- Walk back and get in, rather than teleporting. The
                        -- original SetPedIntoVehicle ran every cycle, so an
                        -- officer who got out -- or was dragged out -- snapped
                        -- into the seat in front of you. TaskEnterVehicle plays
                        -- the whole thing: turn, walk over, open the door.
                        --
                        -- The warp is kept as a last resort, because something
                        -- genuinely does get officers stuck (ragdolled under the
                        -- car, wedged in scenery, holding a task that will not
                        -- clear) and a pursuit unit standing in the road forever
                        -- is a worse outcome than one visible teleport.
                        local driveCfg = Config.Driving or {}
                        vehicleData.officerReboard = vehicleData.officerReboard or {}
                        local waited = (vehicleData.officerReboard[pedNetID] or 0) + 1
                        vehicleData.officerReboard[pedNetID] = waited

                        local strandedDistance = #(GetEntityCoords(officer) - GetEntityCoords(polVehicle))

                        if waited > (driveCfg.reboardPatience or 12)
                            or strandedDistance > (driveCfg.reboardGiveUpDistance or 45.0) then
                            SetPedIntoVehicle(officer, polVehicle, seat)
                            vehicleData.officerReboard[pedNetID] = nil
                        elseif spawnedVehicles[vehNetID].officerTasks[pedNetID] ~= 'Reboarding' then
                            ClearPedTasks(officer)
                            TaskEnterVehicle(officer, polVehicle, 20000, seat, 2.0, 1, 0)
                            spawnedVehicles[vehNetID].officerTasks[pedNetID] = 'Reboarding'
                        end

                        -- Re-apply loadout in case weapons were lost during the exit
                        local loadoutKey = vehicleData.loadout
                        if loadoutKey and Config.loadouts[loadoutKey] then
                            giveClientPedLoadout(officer, Config.loadouts[loadoutKey])
                        end
                    end
                    TriggerServerEvent('fenix-police:unlockOfficerVehicle', vehNetID)
                    -- Only reset the marker if the re-board logic above didn't
                    -- set one. Overwriting 'Reboarding' here would make its
                    -- transition test true every cycle, re-issuing the enter
                    -- task forever and leaving the officer walking on the spot.
                    if spawnedVehicles[vehNetID].officerTasks[pedNetID] ~= 'Reboarding' then
                        spawnedVehicles[vehNetID].officerTasks[pedNetID] = 'VehicleChase'
                    end
                else
                    -- Car gone — fight on foot
                    TriggerServerEvent('deleteSpawnedPed', pedNetID)
                    spawnedVehicles[vehNetID].officers[pedNetID] = nil
                    spawnedVehicles[vehNetID].officerTasks[pedNetID] = nil
                    if not next(spawnedVehicles[vehNetID].officers) then
                        TriggerServerEvent('deleteSpawnedVehicle', vehNetID)
                        spawnedVehicles[vehNetID] = nil
                    end
                end
            end
        end
    end
end




-- Function to handle heli chase
local function handleHeliChaseBehavior(vehicleData, playerPed, vehNetID, playerHasShot)
    -- Air crews are the pursuit's best eyes and register as such: pursuit.lua
    -- gives them a longer sight range and no forward cone, because a helicopter
    -- carries a spotter whose entire job is looking down. A heli overhead is
    -- what stops you breaking contact by turning a corner.
    for pedNetID in pairs(vehicleData.officers or {}) do
        local eyes = NetToPed(pedNetID)
        if eyes and eyes ~= 0 and DoesEntityExist(eyes) then
            FenixPursuit.noteObserver(eyes, 'heli')
        end
    end
    -- [Upstate Mafia] Hold fire on a surrendering player. Returning early leaves
    -- the heli on its existing task, so it keeps circling overhead rather than
    -- engaging — which is the shot you want during the arrest cinematic anyway.
    if Config.ArrestSystem.enabled and (isSurrendering or isBeingArrested) then return end

    -- [Upstate Mafia] Same for a roadside stop. Air support shouldn't be there at
    -- a citation-level wanted level, but nothing guarantees a heli spawned for an
    -- earlier, more serious phase of the same pursuit has despawned yet.
    if ticketWrapUp or isPullingOver or isBeingTicketed then return end

    local playerCoords = GetEntityCoords(playerPed)
    local heliWantedLevel = GetPlayerWantedLevel(PlayerId())
    local vehicle = NetToVeh(vehNetID)
        
    -- I've found that one call isn't enough, and it can take multiple NetToVeh calls before it is not nil or == 0 regardless of the time that has passed since spawn. 
    local waitCount = 0
    while (not vehicle or vehicle == 0) and waitCount < Config.controlWaitCount do
        vehicle = NetToVeh(vehNetID)
        Wait(Config.netWaitTime)
        waitCount = waitCount + 1
    end

    if (not vehicle or vehicle == 0) then
        if Config.isDebug then print('HandleHeli vehicle ID ' .. vehNetID .. ' NetToVeh still nil or 0, gave up ') end
    end

    for pedNetID, officerData in pairs(vehicleData.officers) do
        local officer = NetToPed(pedNetID) 

        -- I've found that one call isn't enough, and it can take multiple NetToPed calls before it is not nil or == 0 regardless of the time that has passed since spawn. 
        local waitCount = 0
        while (not officer or officer == 0) and waitCount < Config.controlWaitCount do
            officer = NetToPed(pedNetID)
            Wait(Config.netWaitTime)
            waitCount = waitCount + 1
        end

        if not DoesEntityExist(officer) or officer == 0 then
            if Config.isDebug then print('HandleHeli ped ID ' .. pedNetID .. ' NetToPed still nil or 0, gave up ') end
        else
            local officerCoords = GetEntityCoords(officer)
            local distance = Vdist(playerCoords.x, playerCoords.y, playerCoords.z, officerCoords.x, officerCoords.y, officerCoords.z)

            -- Wanted-level combat profile. Below the hostile threshold the crew
            -- shadow the player with the spotlight instead of shooting.
            checkOfficerProvocation(officer, playerPed)
            vehicleData.officerEngage = vehicleData.officerEngage or {}
            if vehicleData.officerEngage[pedNetID] == nil then
                vehicleData.officerEngage[pedNetID] = rollEngage(heliWantedLevel)
            end
            local officerHostile = applyOfficerCombatProfile(officer, heliWantedLevel, vehicleData.officerEngage[pedNetID], 'air')
            SetPedCombatAttributes(officer, 3, false) -- never bail out of the heli

            --Equivalent to checkDeadPeds but for farPeds, done here to leverage distance check
            if distance > Config.heliTooFarDistance then
                if farHeliPeds[pedNetID] then
                    farHeliPeds[pedNetID].timer = farHeliPeds[pedNetID].timer + 1
                else
                    farHeliPeds[pedNetID] = { officer = officer, timer = 0 }
                end
            else
                farHeliPeds[pedNetID] = nil
            end
            
            -- [Upstate Mafia patch] Heli always pursues aggressively — no playerHasShot gate
            if IsPedInAnyVehicle(officer, false) then
                if GetPedInVehicleSeat(GetVehiclePedIsIn(officer), -1) == officer then
                    -- Pilot — chase
                    local taskStatus = spawnedHeliUnits[vehNetID].officerTasks[pedNetID]
                    if taskStatus ~= 'HeliChase' then
                        TaskHeliChase(officer, playerPed, 0, 0, 120)
                        spawnedHeliUnits[vehNetID].officerTasks[pedNetID] = 'HeliChase'
                    end
                else
                    -- Crew — shoot only once hostile for this wanted level
                    local taskStatus = spawnedHeliUnits[vehNetID].officerTasks[pedNetID]
                    if officerHostile then
                        if taskStatus ~= 'CombatPed' then
                            TaskCombatPed(officer, playerPed, 0, 16)
                            spawnedHeliUnits[vehNetID].officerTasks[pedNetID] = 'CombatPed'
                        end
                    elseif taskStatus ~= 'Standby' then
                        ClearPedTasks(officer)
                        spawnedHeliUnits[vehNetID].officerTasks[pedNetID] = 'Standby'
                    end
                end
                -- Weapon persistence check for server-owned heli peds.
                -- Server owns these entities so ask the server to re-arm rather than calling
                -- GiveWeaponToPed directly (client-side calls on server-owned entities fail silently).
                if GetBestPedWeapon(officer, false) == GetHashKey('weapon_unarmed') or GetBestPedWeapon(officer, false) == 0 then
                    TriggerServerEvent('fenix-police:rearmOfficer', pedNetID, 'airPatrol')
                end
            else
                -- Officer somehow on foot — fight or commandeer a vehicle
                local nearbyVehicle = QBCore.Functions.GetClosestVehicle(vector3(officerCoords.x, officerCoords.y, officerCoords.z), 100, false)
                if nearbyVehicle then
                    local taskStatus = spawnedHeliUnits[vehNetID].officerTasks[pedNetID]
                    if taskStatus ~= 'EnterVehicle' then
                        TaskEnterVehicle(officer, nearbyVehicle, 20000, -1, 1.5, 8, 0)
                        spawnedHeliUnits[vehNetID].officerTasks[pedNetID] = 'EnterVehicle'
                    end
                else
                    local taskStatus = spawnedHeliUnits[vehNetID].officerTasks[pedNetID]
                    if taskStatus ~= 'CombatPed' then
                        TaskCombatPed(officer, playerPed, 0, 16)
                        spawnedHeliUnits[vehNetID].officerTasks[pedNetID] = 'CombatPed'
                    end
                end
            end
        end
    end
end




-- Function to handle air chase
local function handleAirChaseBehavior(vehicleData, playerPed, vehNetID, playerHasShot)
    for pedNetID in pairs(vehicleData.officers or {}) do
        local eyes = NetToPed(pedNetID)
        if eyes and eyes ~= 0 and DoesEntityExist(eyes) then
            FenixPursuit.noteObserver(eyes, 'air')
        end
    end
    -- [Upstate Mafia] Hold fire on a surrendering player, as above.
    if Config.ArrestSystem.enabled and (isSurrendering or isBeingArrested) then return end
    if ticketWrapUp or isPullingOver or isBeingTicketed then return end

    local playerCoords = GetEntityCoords(playerPed)
    local airWantedLevel = GetPlayerWantedLevel(PlayerId())
    local vehicle = NetToVeh(vehNetID)
        
    -- I've found that one call isn't enough, and it can take multiple NetToVeh calls before it is not nil or == 0 regardless of the time that has passed since spawn. 
    local waitCount = 0
    while (not vehicle or vehicle == 0) and waitCount < Config.controlWaitCount do
        vehicle = NetToVeh(vehNetID)
        Wait(Config.netWaitTime)
        waitCount = waitCount + 1
    end

    if (not vehicle or vehicle == 0) then
        if Config.isDebug then print('HandleAir vehicle ID ' .. vehNetID .. ' NetToVeh still nil or 0, gave up ') end
    end

    for pedNetID, officerData in pairs(vehicleData.officers) do
        local officer = NetToPed(pedNetID) 

        -- I've found that one call isn't enough, and it can take multiple NetToPed calls before it is not nil or == 0 regardless of the time that has passed since spawn. 
        local waitCount = 0
        while (not officer or officer == 0) and waitCount < Config.controlWaitCount do
            officer = NetToPed(pedNetID)
            Wait(Config.netWaitTime)
            waitCount = waitCount + 1
        end

        if not DoesEntityExist(officer) or officer == 0 then
            if Config.isDebug then print('HandleAir ped ID ' .. pedNetID .. ' NetToPed still nil or 0, gave up ') end
        else
            local officerCoords = GetEntityCoords(officer)
            local distance = Vdist(playerCoords.x, playerCoords.y, playerCoords.z, officerCoords.x, officerCoords.y, officerCoords.z)

            -- Wanted-level combat profile (air units only spawn at 4-5, so this is
            -- mostly an accuracy/rate-of-fire cap rather than a hold-fire gate).
            checkOfficerProvocation(officer, playerPed)
            vehicleData.officerEngage = vehicleData.officerEngage or {}
            if vehicleData.officerEngage[pedNetID] == nil then
                vehicleData.officerEngage[pedNetID] = rollEngage(airWantedLevel)
            end
            local officerHostile = applyOfficerCombatProfile(officer, airWantedLevel, vehicleData.officerEngage[pedNetID], 'air')
            SetPedCombatAttributes(officer, 3, false) -- never bail out of the aircraft

            --Equivalent to checkDeadPeds but for farPeds, done here to leverage distance check
            if distance > Config.planeTooFarDistance then
                if farAirPeds[pedNetID] then
                    farAirPeds[pedNetID].timer = farAirPeds[pedNetID].timer + 1
                else
                    farAirPeds[pedNetID] = { officer = officer, timer = 0 }
                end
            else
                farAirPeds[pedNetID] = nil
            end

            -- [Upstate Mafia patch] Air units always pursue aggressively — no playerHasShot gate
            if IsPedInAnyVehicle(officer, false) then
                if GetPedInVehicleSeat(GetVehiclePedIsIn(officer), -1) == officer then
                    -- Pilot
                    if IsPedInAnyVehicle(playerPed, false) then
                        local playerVeh = GetVehiclePedIsIn(playerPed, false)
                        local taskStatus = spawnedAirUnits[vehNetID].officerTasks[pedNetID]
                        if taskStatus ~= 'VehicleChase' then
                            TaskVehicleMission(officer, vehicle, playerVeh, 6, 1000.0, 1073741824, 1, 0.0, true)
                            spawnedAirUnits[vehNetID].officerTasks[pedNetID] = 'VehicleChase'
                        end
                    else
                        local taskStatus = spawnedAirUnits[vehNetID].officerTasks[pedNetID]
                        if taskStatus ~= 'PlaneChase' then
                            TaskPlaneChase(officer, playerPed, 20, 20, 150)
                            spawnedAirUnits[vehNetID].officerTasks[pedNetID] = 'PlaneChase'
                        end
                    end
                else
                    -- Crew — shoot only once hostile for this wanted level
                    local taskStatus = spawnedAirUnits[vehNetID].officerTasks[pedNetID]
                    if officerHostile then
                        if taskStatus ~= 'CombatPed' then
                            TaskCombatPed(officer, playerPed, 0, 16)
                            spawnedAirUnits[vehNetID].officerTasks[pedNetID] = 'CombatPed'
                        end
                    elseif taskStatus ~= 'Standby' then
                        ClearPedTasks(officer)
                        spawnedAirUnits[vehNetID].officerTasks[pedNetID] = 'Standby'
                    end
                end
            else
                -- On foot somehow — commandeer a vehicle or fight
                local nearbyVehicle = QBCore.Functions.GetClosestVehicle(vector3(officerCoords.x, officerCoords.y, officerCoords.z), 100, false)
                if nearbyVehicle then
                    local taskStatus = spawnedAirUnits[vehNetID].officerTasks[pedNetID]
                    if taskStatus ~= 'EnterVehicle' then
                        TaskEnterVehicle(officer, nearbyVehicle, 20000, -1, 1.5, 8, 0)
                        spawnedAirUnits[vehNetID].officerTasks[pedNetID] = 'EnterVehicle'
                    end
                else
                    local taskStatus = spawnedAirUnits[vehNetID].officerTasks[pedNetID]
                    if taskStatus ~= 'CombatPed' then
                        TaskCombatPed(officer, playerPed, 0, 16)
                        spawnedAirUnits[vehNetID].officerTasks[pedNetID] = 'CombatPed'
                    end
                end
            end
        end
    end
end




-- Function to check for dead peds and start the timer
local function checkDeadPeds()

    -- Ground Units --
    for vehNetID, vehicleData in pairs(spawnedVehicles) do
        for pedNetID, officerData in pairs(vehicleData.officers) do
            local officer = NetToPed(pedNetID) 

            -- I've found that one call isn't enough, and it can take multiple NetToPed calls before it is not nil or == 0 regardless of the time that has passed since spawn. 
            local waitCount = 0
            while (not officer or officer == 0) and waitCount < Config.controlWaitCount do
                officer = NetToPed(pedNetID)
                Wait(Config.netWaitTime)
                waitCount = waitCount + 1
            end
            if not DoesEntityExist(officer) or officer == 0 then
                if Config.isDebug then print('CheckDeadUnit ped ID ' .. pedNetID .. ' NetToPed still nil or 0, gave up ') end
            end
            --if Config.isDebug then print('CLIENT NetToPed for netID ' ..pedNetID .. ' returned entityID ' .. officer)  end
            --if Config.isDebug then print('CLIENT PedToNet for entityID ' ..officer.. ' returned NetID = ' .. PedToNet(officer))  end


            if IsPedDeadOrDying(officer, true) then
                local deadPed = deadPeds[pedNetID]
                --If they are already added don't add them again
                if not deadPed then
                    deadPeds[pedNetID] = { officer = officer, timer = 0 }
                end   
            end
        end
    end

    -- Heli Units --
    for vehNetID, vehicleData in pairs(spawnedHeliUnits) do
        for pedNetID, officerData in pairs(vehicleData.officers) do
            local officer = NetToPed(pedNetID) 

            -- I've found that one call isn't enough, and it can take multiple NetToPed calls before it is not nil or == 0 regardless of the time that has passed since spawn. 
            local waitCount = 0
            while (not officer or officer == 0) and waitCount < Config.controlWaitCount do
                officer = NetToPed(pedNetID)
                Wait(Config.netWaitTime)
                waitCount = waitCount + 1
            end
            if not DoesEntityExist(officer) or officer == 0 then
                if Config.isDebug then print('CheckDeadHeli ped ID ' .. pedNetID .. ' NetToPed still nil or 0, gave up ') end
            end
            --if Config.isDebug then print('CLIENT NetToPed for netID ' ..pedNetID .. ' returned entityID ' .. officer)  end
            --if Config.isDebug then print('CLIENT PedToNet for entityID ' ..officer.. ' returned NetID = ' .. PedToNet(officer))  end

            if IsPedDeadOrDying(officer, true) then
                local deadPed = deadHeliPeds[pedNetID]
                --If they are already added don't add them again
                if not deadPed then
                    deadHeliPeds[pedNetID] = { officer = officer, timer = 0 }
                end   
            end
        end
    end

    -- Air Units --
    for vehNetID, vehicleData in pairs(spawnedAirUnits) do
        for pedNetID, officerData in pairs(vehicleData.officers) do
            local officer = NetToPed(pedNetID) 

            -- I've found that one call isn't enough, and it can take multiple NetToPed calls before it is not nil or == 0 regardless of the time that has passed since spawn. 
            local waitCount = 0
            while (not officer or officer == 0) and waitCount < Config.controlWaitCount do
                officer = NetToPed(pedNetID)
                Wait(Config.netWaitTime)
                waitCount = waitCount + 1
            end
            if not DoesEntityExist(officer) or officer == 0 then
                if Config.isDebug then print('CheckDeadAir ped ID ' .. pedNetID .. ' NetToPed still nil or 0, gave up ') end
            end
            --if Config.isDebug then print('CLIENT NetToPed for netID ' ..pedNetID .. ' returned entityID ' .. officer)  end
            --if Config.isDebug then print('CLIENT PedToNet for entityID ' ..officer.. ' returned NetID = ' .. PedToNet(officer))  end

            if IsPedDeadOrDying(officer, true) then
                local deadPed = deadAirPeds[pedNetID]
                --If they are already added don't add them again
                if not deadPed then
                    deadAirPeds[pedNetID] = { officer = officer, timer = 0 }
                end   
            end
        end
    end


end




-- Function to handle the deletion of dead peds after timer
local function handleDeadPeds()

    -- Ground Units --
    for pedNetID, deadPed in pairs(deadPeds) do

        deadPed.timer = deadPed.timer + 1

        if deadPed.timer >= (Config.deadOfficerCleanupTimer / Config.scriptFrequencyModulus) then

            -- We should be able to tell the server to delete the NetID whether it exists locally for us or not and trust that it will be removed and remove it from the table now
            if Config.isDebug then print('Removing DeadOfficer ID = ' .. pedNetID) end
            TriggerServerEvent('deleteSpawnedPed', pedNetID)
            deadPeds[pedNetID] = nil

            -- Loop through all stored vehicles and set officers[pedNetID] = nil
            -- If our officer exists for that vehicle, they are removed. Otherwise does nothing. 
            for vehNetID, vehicleData in pairs(spawnedVehicles) do

                if Config.isDebug then print('Checking vehNetID = '.. vehNetID .. ' for dead ped = ' ..pedNetID) end
                if vehicleData.officers[pedNetID] then
                    if Config.isDebug then print('Found ped in vehicleData.officers for pedNetID = ' .. pedNetID) end
                    vehicleData.officers[pedNetID] = nil

                    if not next(vehicleData.officers) then
                        -- If no officers left assigned tells server to delete vehicle. Server will check if there is a ped in the driver seat first.
                        -- If they are, the server will not delete the vehicle but send back a response to the client to add to stolenVehicles table instead.
                        if Config.isDebug then print('Removing DeadOfficerVehicle ID = ' .. vehNetID) end
                        TriggerServerEvent('deleteSpawnedVehicle', vehNetID)
                        spawnedVehicles[vehNetID] = nil  
                    end
                    break
                end
            end

        end
    end


    -- Heli Units --
    for pedNetID, deadPed in pairs(deadHeliPeds) do

        deadPed.timer = deadPed.timer + 1

        if deadPed.timer >= (Config.deadHeliPilotCleanupTimer / Config.scriptFrequencyModulus) then

            -- We should be able to tell the server to delete the NetID whether it exists locally for us or not and trust that it will be removed and remove it from the table now
            if Config.isDebug then print('Removing HeliPilot ID = ' .. pedNetID) end
            TriggerServerEvent('deleteSpawnedPed', pedNetID)
            deadHeliPeds[pedNetID] = nil

            -- Loop through all stored vehicles and set officers[pedNetID] = nil
            -- If our officer exists for that vehicle, they are removed. Otherwise does nothing. 
            for vehNetID, vehicleData in pairs(spawnedHeliUnits) do
                if vehicleData.officers[pedNetID] then
                    vehicleData.officers[pedNetID] = nil

                    if not next(vehicleData.officers) then
                        -- If no officers left tells server to delete vehicle. Server will check if there is a ped in the driver seat first.
                        -- If they are, the server will not delete the vehicle but send back a response to the client to add to stolenVehicles table instead.
                        if Config.isDebug then print('Removing DeadOfficerHeli ID = ' .. vehNetID) end
                        TriggerServerEvent('deleteSpawnedVehicle', vehNetID)
                        spawnedHeliUnits[vehNetID] = nil  
                    end
                    break
                end
            end

        end
    end


    -- Air Units --
    for pedNetID, deadPed in pairs(deadAirPeds) do

        deadPed.timer = deadPed.timer + 1

        if deadPed.timer >= (Config.deadAirPilotCleanupTimer / Config.scriptFrequencyModulus) then

            -- We should be able to tell the server to delete the NetID whether it exists locally for us or not and trust that it will be removed and remove it from the table now
            if Config.isDebug then print('Removing AirPilot ID = ' .. pedNetID) end
            TriggerServerEvent('deleteSpawnedPed', pedNetID)
            deadAirPeds[pedNetID] = nil

            -- Loop through all stored vehicles and set officers[pedNetID] = nil
            -- If our officer exists for that vehicle, they are removed. Otherwise does nothing. 
            for vehNetID, vehicleData in pairs(spawnedAirUnits) do
                if vehicleData.officers[pedNetID] then
                    vehicleData.officers[pedNetID] = nil

                    if not next(vehicleData.officers) then
                        -- If no officers left tells server to delete vehicle. Server will check if there is a ped in the driver seat first.
                        -- If they are, the server will not delete the vehicle but send back a response to the client to add to stolenVehicles table instead.
                        if Config.isDebug then print('Removing DeadOfficerHeli ID = ' .. vehNetID) end
                        TriggerServerEvent('deleteSpawnedVehicle', vehNetID)
                        spawnedAirUnits[vehNetID] = nil    
                    end
                    break
                end
            end

        end
    end


end




-- Function to handle the deletion of far peds after timer
local function handleFarPeds()

    -- Ground Units --
    for pedNetID, farPed in pairs(farOfficers) do

        if farPed.timer >= (Config.farOfficerCleanupTimer / Config.scriptFrequencyModulus) then

            -- We should be able to tell the server to delete the NetID whether it exists locally for us or not and trust that it will be removed and remove it from the table now
            if Config.isDebug then print('Remove FarOfficer ID = ' .. pedNetID) end
            TriggerServerEvent('deleteSpawnedPed', pedNetID)
            farOfficers[pedNetID] = nil

            -- Loop through all stored vehicles and set officers[pedNetID] = nil
            -- If our officer exists for that vehicle, they are removed. Otherwise does nothing. 
            for vehNetID, vehicleData in pairs(spawnedVehicles) do
                if vehicleData.officers[pedNetID] then
                    vehicleData.officers[pedNetID] = nil

                    if not next(vehicleData.officers) then
                        -- If no officers left tells server to delete vehicle. Server will check if there is a ped in the driver seat first.
                        -- If they are, the server will not delete the vehicle but send back a response to the client to add to stolenVehicles table instead.
                        if Config.isDebug then print('Remove FarOfficerVehicle ID = ' .. vehNetID) end
                        TriggerServerEvent('deleteSpawnedVehicle', vehNetID)
                        spawnedVehicles[vehNetID] = nil  
                    end
                    break
                end
            end

        end
    end

    -- Heli Units --
    for pedNetID, farPed in pairs(farHeliPeds) do

        if farPed.timer >= (Config.farHeliPilotCleanupTimer / Config.scriptFrequencyModulus) then

            -- We should be able to tell the server to delete the NetID whether it exists locally for us or not and trust that it will be removed and remove it from the table now
            if Config.isDebug then print('Remove FarHeliPilot ID = ' .. pedNetID) end
            TriggerServerEvent('deleteSpawnedPed', pedNetID)
            farHeliPeds[pedNetID] = nil

            -- Loop through all stored vehicles and set officers[pedNetID] = nil
            -- If our officer exists for that vehicle, they are removed. Otherwise does nothing. 
            for vehNetID, vehicleData in pairs(spawnedHeliUnits) do
                if vehicleData.officers[pedNetID] then
                    vehicleData.officers[pedNetID] = nil

                    if not next(vehicleData.officers) then
                        -- If no officers left tells server to delete vehicle. Server will check if there is a ped in the driver seat first.
                        -- If they are, the server will not delete the vehicle but send back a response to the client to add to stolenVehicles table instead.
                        if Config.isDebug then print('Remove FarOfficerHeli ID = ' .. vehNetID) end
                        TriggerServerEvent('deleteSpawnedVehicle', vehNetID)
                        spawnedHeliUnits[vehNetID] = nil 
                    end
                    break
                end
            end

        end
    end

    -- Air Units --
    for pedNetID, farPed in pairs(farAirPeds) do

        if farPed.timer >= (Config.farAirPilotCleanupTimer / Config.scriptFrequencyModulus) then

             -- We should be able to tell the server to delete the NetID whether it exists locally for us or not and trust that it will be removed and remove it from the table now
             if Config.isDebug then print('Remove FarAirPilot ID = ' .. pedNetID) end
            TriggerServerEvent('deleteSpawnedPed', pedNetID)
            farAirPeds[pedNetID] = nil
 
             -- Loop through all stored vehicles and set officers[pedNetID] = nil
             -- If our officer exists for that vehicle, they are removed. Otherwise does nothing. 
             for vehNetID, vehicleData in pairs(spawnedAirUnits) do
                 if vehicleData.officers[pedNetID] then
                     vehicleData.officers[pedNetID] = nil
 
                     if not next(vehicleData.officers) then
                         -- If no officers left tells server to delete vehicle. Server will check if there is a ped in the driver seat first.
                         -- If they are, the server will not delete the vehicle but send back a response to the client to add to stolenVehicles table instead.
                         if Config.isDebug then print('Remove FarOfficerAir ID = ' .. vehNetID) end
                        TriggerServerEvent('deleteSpawnedVehicle', vehNetID)
                        spawnedAirUnits[vehNetID] = nil
                     end
                     break
                 end
             end

        end
    end


end




-- This function handles re-tasking the police when you first lose your wanted level so they drive off and stop pursuing the player.
local function handleEndWantedTasks()


    for vehNetID, vehicleData in pairs(spawnedVehicles) do
        local vehicle = NetToVeh(vehNetID) -- vehicleData.vehicle -- NetToVeh(vehNetID)
        
        -- I've found that one call isn't enough, and it can take multiple NetToVeh calls before it is not nil or == 0 regardless of the time that has passed since spawn. 
        local waitCount = 0
        while (not vehicle or vehicle == 0) and waitCount < Config.controlWaitCount do
            vehicle = NetToVeh(vehNetID)
            Wait(Config.netWaitTime)
            waitCount = waitCount + 1
        end
        if (not vehicle or vehicle == 0) then
            if Config.isDebug then print('EndWantedUnit vehicle ID ' .. vehNetID .. ' NetToVeh still nil or 0, gave up ') end
        end
        --if Config.isDebug then print('CLIENT NetToVeh for netID ' ..vehNetID .. ' returned entityID ' .. vehicle)  end
        --if Config.isDebug then print('CLIENT VehToNet for entityID ' ..vehicle.. ' returned NetID = ' .. VehToNet(vehicle))  end

        for pedNetID, officerData in pairs(vehicleData.officers) do
            local officer = NetToPed(pedNetID) --officerData -- NetToPed(pedNetID)

            -- I've found that one call isn't enough, and it can take multiple NetToPed calls before it is not nil or == 0 regardless of the time that has passed since spawn. 
            local waitCount = 0
            while (not officer or officer == 0) and waitCount < Config.controlWaitCount do
                officer = NetToPed(pedNetID)
                Wait(Config.netWaitTime)
                waitCount = waitCount + 1
            end
            if not DoesEntityExist(officer) or officer == 0 then
                if Config.isDebug then print('EndWantedUnit ped ID ' .. pedNetID .. ' NetToPed still nil or 0, gave up ') end
            end
            --if Config.isDebug then print('CLIENT NetToPed for netID ' ..pedNetID .. ' returned entityID ' .. officer)  end
            --if Config.isDebug then print('CLIENT PedToNet for entityID ' ..officer.. ' returned NetID = ' .. PedToNet(officer))  end

            if DoesEntityExist(officer) then
                if Config.isDebug then print('Terminating tasks and setting cruise') end 

                
                if IsPedInVehicle(officer, vehicle, false) then
                    ClearPedTasks(officer)
                    TaskVehicleDriveWander(officer, vehicle, 30.0, 262571) 
                    SetSirenKeepOn(vehicle, false) 
                else
                    ClearPedTasksImmediately(officer)
                    if DoesEntityExist(vehicle) then
                        -- Try to get back into own vehicle, not sure if tasks will be executed in order or if they will fail to drive off after?
                        TaskEnterVehicle(officer, vehicle, 20000, -1, 1.5, 8, 0)
                        TaskVehicleDriveWander(officer, vehicle, 30.0, 262571) 
                    else
                        TaskWanderStandard(officer, 10.0, 10)
                    end    
                end
            end
        end
    end

    for vehNetID, vehicleData in pairs(spawnedHeliUnits) do
        local vehicle = NetToVeh(vehNetID)
        
        -- I've found that one call isn't enough, and it can take multiple NetToVeh calls before it is not nil or == 0 regardless of the time that has passed since spawn. 
        local waitCount = 0
        while (not vehicle or vehicle == 0) and waitCount < Config.controlWaitCount do
            vehicle = NetToVeh(vehNetID)
            Wait(Config.netWaitTime)
            waitCount = waitCount + 1
        end
        if (not vehicle or vehicle == 0) then
            if Config.isDebug then print('EndWantedHeli vehicle ID ' .. vehNetID .. ' NetToVeh still nil or 0, gave up ') end
        end
        --if Config.isDebug then print('CLIENT NetToVeh for netID ' ..vehNetID .. ' returned entityID ' .. vehicle)  end
        --if Config.isDebug then print('CLIENT VehToNet for entityID ' ..vehicle.. ' returned NetID = ' .. VehToNet(vehicle))  end


        for pedNetID, officerData in pairs(vehicleData.officers) do
            local officer = NetToPed(pedNetID)

            -- I've found that one call isn't enough, and it can take multiple NetToPed calls before it is not nil or == 0 regardless of the time that has passed since spawn. 
            local waitCount = 0
            while (not officer or officer == 0) and waitCount < Config.controlWaitCount do
                officer = NetToPed(pedNetID)
                Wait(Config.netWaitTime)
                waitCount = waitCount + 1
            end
            if not DoesEntityExist(officer) or officer == 0 then
                if Config.isDebug then print('EndWantedHeli ped ID ' .. pedNetID .. ' NetToPed still nil or 0, gave up ') end
            end
            --if Config.isDebug then print('CLIENT NetToPed for netID ' ..pedNetID .. ' returned entityID ' .. officer)  end
            --if Config.isDebug then print('CLIENT PedToNet for entityID ' ..officer.. ' returned NetID = ' .. PedToNet(officer))  end

            if DoesEntityExist(officer) then

                local driver = GetPedInVehicleSeat(vehicle, -1) 
                if driver == officer then
                    ClearPedTasks(officer)
                    -- Re-use this logic to get point near here to fly to
                    local flyPoint, spawnHeading = getRandomPointInRange(GetEntityCoords(officer), Config.minHeliSpawnDistance, Config.maxHeliSpawnDistance, Config.minHeliSpawnHeight, Config.maxHeliSpawnHeight) 
                    if flyPoint then
                        TaskVehicleDriveToCoord(officer, vehicle, flyPoint.x, flyPoint.y, flyPoint.z, 60.0, 1, GetEntityModel(vehicle), 16777248, 70.0, true)
                    end
                else
                    -- Prevent ped from leaving the vehicle
                    TaskSetBlockingOfNonTemporaryEvents(officer, true)
                    -- Clear specific combat-related tasks
                    ClearPedTasks(officer)
                    TaskSetBlockingOfNonTemporaryEvents(officer, false)
                end
            end
        end
    end

    for vehNetID, vehicleData in pairs(spawnedAirUnits) do
        local vehicle = NetToVeh(vehNetID)
        
        -- I've found that one call isn't enough, and it can take multiple NetToVeh calls before it is not nil or == 0 regardless of the time that has passed since spawn. 
        local waitCount = 0
        while (not vehicle or vehicle == 0) and waitCount < Config.controlWaitCount do
            vehicle = NetToVeh(vehNetID)
            Wait(Config.netWaitTime)
            waitCount = waitCount + 1
        end
        if (not vehicle or vehicle == 0) then
            if Config.isDebug then print('EndWantedAir vehicle ID ' .. vehNetID .. ' NetToVeh still nil or 0, gave up ') end
        end
        --if Config.isDebug then print('CLIENT NetToVeh for netID ' ..vehNetID .. ' returned entityID ' .. vehicle)  end
        --if Config.isDebug then print('CLIENT VehToNet for entityID ' ..vehicle.. ' returned NetID = ' .. VehToNet(vehicle))  end


        for pedNetID, officerData in pairs(vehicleData.officers) do
            local officer = NetToPed(pedNetID)

            -- I've found that one call isn't enough, and it can take multiple NetToPed calls before it is not nil or == 0 regardless of the time that has passed since spawn. 
            local waitCount = 0
            while (not officer or officer == 0) and waitCount < Config.controlWaitCount do
                officer = NetToPed(pedNetID)
                Wait(Config.netWaitTime)
                waitCount = waitCount + 1
            end
            if not DoesEntityExist(officer) or officer == 0 then
                if Config.isDebug then print('EndWantedAir ped ID ' .. pedNetID .. ' NetToPed still nil or 0, gave up ') end
            end
            --if Config.isDebug then print('CLIENT NetToPed for netID ' ..pedNetID .. ' returned entityID ' .. officer)  end
            --if Config.isDebug then print('CLIENT PedToNet for entityID ' ..officer.. ' returned NetID = ' .. PedToNet(officer))  end

            if DoesEntityExist(officer) then
                if Config.isDebug then print('Terminating tasks and setting cruise') end

                local driver = GetPedInVehicleSeat(vehicle, -1) 
                if driver == officer then
                    ClearPedTasks(officer)
                    -- Re-use this logic to get point near here to fly to
                    local flyPoint, spawnHeading = getRandomPointInRange(GetEntityCoords(officer), Config.minAirSpawnDistance, Config.maxAirSpawnDistance, Config.minAirSpawnHeight, Config.maxAirSpawnHeight) 
                    if flyPoint then
                        TaskVehicleDriveToCoord(officer, vehicle, flyPoint.x, flyPoint.y, flyPoint.z, 60.0, 1, GetEntityModel(vehicle), 16777248, 70.0, true)
                    end
                else
                    -- Prevent ped from leaving the vehicle
                    TaskSetBlockingOfNonTemporaryEvents(officer, true)
                    -- Clear specific combat-related tasks
                    ClearPedTasks(officer)
                    TaskSetBlockingOfNonTemporaryEvents(officer, false)
                end
                
            end
        end
    end

end




-- This function handles deleting the police units when you have lost your wanted level and the timer has expired.
-- The above function + this function attempts to have the police drive off, then when far enough away delete them.
--
-- [Upstate Mafia] Single choke point for the aftermath.active guard, rather
-- than gating every caller individually. There are THREE independent paths
-- that call this: the main loop, a standalone watchdog thread, and the
-- fenix-police:cleanupAllPolice net event the server broadcasts. Gating them
-- one at a time missed the third one -- the server-triggered broadcast has
-- no idea aftermath exists at all, so it kept nuking every officer regardless
-- of what the client was doing. Gating the function itself covers all three
-- (and any future caller) in one place instead of relying on every call site
-- remembering to check.

--- Best-effort delete of a networked entity this client might not actually
--- own yet. NetworkRequestControlOfEntity is a REQUEST, not an instant grant
--- -- the transfer happens over subsequent network frames -- so calling
--- DeleteEntity in the same tick can silently no-op if it hasn't landed yet.
--- That is what a pursuit unit that "won't die" on cleanup actually is: not
--- every entity below requested control at the same moment, and only the
--- ones whose transfer happened to land before this ran got deleted, leaving
--- the rest (a heli is a single entity with no second chance from the 5-pass
--- watchdog's per-officer redundancy, which is why it tends to be the one
--- that visibly survives). Waits up to 150ms for control to actually land;
--- still attempts the delete either way, since an entity nobody else claims
--- ownership of eventually falls to whichever client is left holding it.
local function deleteNetworkedEntity(entity)
    if not DoesEntityExist(entity) then return end
    if not NetworkHasControlOfEntity(entity) then
        NetworkRequestControlOfEntity(entity)
        local waited = 0
        while not NetworkHasControlOfEntity(entity) and waited < 150 do
            Wait(25)
            waited = waited + 25
        end
    end
    DeleteEntity(entity)
end

local function handleEndWantedDelete()
    if aftermath.active then return end

    -- Collect keys BEFORE iterating so that nilling entries mid-loop (which Lua's
    -- pairs iterator can silently skip) doesn't leave orphan units behind.

    -- Ground units
    local groundKeys = {}
    for k in pairs(spawnedVehicles) do table.insert(groundKeys, k) end
    for _, vehNetID in ipairs(groundKeys) do
        local vehicleData = spawnedVehicles[vehNetID]
        if vehicleData then
            local pedKeys = {}
            for k in pairs(vehicleData.officers) do table.insert(pedKeys, k) end
            for _, pedNetID in ipairs(pedKeys) do
                local ped = NetToPed(pedNetID)
                deleteNetworkedEntity(ped)
                TriggerServerEvent('deleteSpawnedPed', pedNetID)
                if Config.isDebug then print('Cleaned up police officer ' .. pedNetID) end
            end
            local vehicle = NetToVeh(vehNetID)
            deleteNetworkedEntity(vehicle)
            TriggerServerEvent('deleteSpawnedVehicle', vehNetID)
            if Config.isDebug then print('Cleaned up police vehicle ' .. vehNetID) end
            spawnedVehicles[vehNetID] = nil
        end
    end

    -- Heli units
    local heliKeys = {}
    for k in pairs(spawnedHeliUnits) do table.insert(heliKeys, k) end
    for _, vehNetID in ipairs(heliKeys) do
        local vehicleData = spawnedHeliUnits[vehNetID]
        if vehicleData then
            local pedKeys = {}
            for k in pairs(vehicleData.officers) do table.insert(pedKeys, k) end
            for _, pedNetID in ipairs(pedKeys) do
                local ped = NetToPed(pedNetID)
                deleteNetworkedEntity(ped)
                TriggerServerEvent('deleteSpawnedPed', pedNetID)
                if Config.isDebug then print('Cleaned up heli officer ' .. pedNetID) end
            end
            local vehicle = NetToVeh(vehNetID)
            deleteNetworkedEntity(vehicle)
            TriggerServerEvent('deleteSpawnedVehicle', vehNetID)
            if Config.isDebug then print('Cleaned up heli unit ' .. vehNetID) end
            spawnedHeliUnits[vehNetID] = nil
        end
    end

    -- Air units
    local airKeys = {}
    for k in pairs(spawnedAirUnits) do table.insert(airKeys, k) end
    for _, vehNetID in ipairs(airKeys) do
        local vehicleData = spawnedAirUnits[vehNetID]
        if vehicleData then
            local pedKeys = {}
            for k in pairs(vehicleData.officers) do table.insert(pedKeys, k) end
            for _, pedNetID in ipairs(pedKeys) do
                local ped = NetToPed(pedNetID)
                deleteNetworkedEntity(ped)
                TriggerServerEvent('deleteSpawnedPed', pedNetID)
                if Config.isDebug then print('Cleaned up air officer ' .. pedNetID) end
            end
            local vehicle = NetToVeh(vehNetID)
            deleteNetworkedEntity(vehicle)
            TriggerServerEvent('deleteSpawnedVehicle', vehNetID)
            if Config.isDebug then print('Cleaned up air unit ' .. vehNetID) end
            spawnedAirUnits[vehNetID] = nil
        end
    end

    -- Reset pending spawn counters so the next chase starts clean
    pendingGroundSpawns = 0
    pendingHeliSpawns   = 0
    pendingAirSpawns    = 0

    -- Close the spawn gate so any in-flight server responses that arrive AFTER this
    -- cleanup are discarded rather than re-populating the tracking tables with cops
    -- that will never be cleaned up again.
    spawnGate = false

    if Config.isDebug then print('All Units Cleaned Up') end
end

RegisterNetEvent('fenix-police:cleanupAllPolice')
AddEventHandler('fenix-police:cleanupAllPolice', function()
    handleEndWantedDelete()
end)

-- ============================================================================
-- Independent cleanup watchdog thread
-- Watches the wanted level independently of the main loop.  When the wanted
-- level drops to 0, it hammers handleEndWantedDelete() five times over five
-- seconds regardless of wantedTimer state, pcall health, or in-flight spawns.
-- This is completely separate from the main loop so nothing in that loop's
-- error handling or timing can prevent cleanup from firing.
--
-- [Upstate Mafia] Held off while aftermath.active. This ran unconditionally
-- within 500ms of the wanted level clearing -- which happens the instant the
-- player is incapacitated -- so it deleted every officer mid field-revive
-- attempt regardless of anything the aftermath sequence or the main loop
-- were doing. pendingCleanup latches the moment wanted drops rather than
-- re-testing prevWanted, since by the time aftermath actually ends prevWanted
-- has long since settled to false and the falling edge would already be gone.
-- ============================================================================
CreateThread(function()
    local prevWanted = false
    local pendingCleanup = false
    while true do
        Wait(500)
        local plyPed = PlayerPedId()
        if not plyPed or plyPed == 0 then goto cleanupWatchdogContinue end

        local wanted = GetPlayerWantedLevel(PlayerId()) > 0

        if prevWanted and not wanted then
            pendingCleanup = true
        end

        if pendingCleanup and not aftermath.active then
            pendingCleanup = false
            -- Wanted level dropped and nothing is holding the scene — run
            -- cleanup five times over five seconds. Five passes ensures
            -- in-flight server-side spawn responses that arrive up to ~4
            -- seconds after cleanup still get caught and deleted.
            for i = 1, 5 do
                local ok, err = pcall(handleEndWantedDelete)
                if not ok then
                    print('^1[FENIX-CLEANUP] watchdog error pass ' .. i .. ': ' .. tostring(err) .. '^7')
                end
                if i < 5 then Wait(1000) end
            end
            print('[FENIX-CLEANUP] watchdog finished 5-pass cleanup')
        end

        prevWanted = wanted
        ::cleanupWatchdogContinue::
    end
end)


-- ENABLE DISPATCH FEATURES --

-- Server will tell clients whether to enable/disable disaptch services.
-- This could be based on whether players with police jobs are online or not if configured.
local function UpdateDispatchServices()

    Citizen.CreateThread(function()

        if disableAIPolice == true then

            QBCore.Functions.Notify('Fenix Police Response: Disabled')
            if Config.isDebug then print('Fenix Police Response: Disabled') end


            SetAudioFlag('PoliceScannerDisabled', true)
            SetCreateRandomCops(false)
            SetCreateRandomCopsNotOnScenarios(false)

            -- NOTE this can cause problems with some mods and will crash your game if set to false for some reason. Disabling a particular mod resolved it
            -- for me. Or you can leave it true if you use those mods.
            SetCreateRandomCopsOnScenarios(false) 
            
            DistantCopCarSirens(false)

            -- [Upstate Mafia patch] Original was SetMaxWantedLevel(0) which prevented
            -- ANY wanted level from rising when player cops are online — meaning
            -- killing peds did nothing, no map indicator, no ps-dispatch alerts.
            -- We keep wanted level enabled (so stars/HUD/dispatch work) but fenix
            -- still skips its AI-dispatch spawning because disableAIPolice=true.
            SetMaxWantedLevel(5)

            -- This removes vehicles from generating at PDs when police are online.
            if Config.RemoveVehicleGenerators == true then
                RemoveVehiclesFromGeneratorsInArea(335.2616 - 300.0, -1432.455 - 300.0, 46.51 - 300.0, 335.2616 + 300.0, -1432.455 + 300.0, 346.51)
                RemoveVehiclesFromGeneratorsInArea(441.8465 - 500.0, -987.99 - 500.0, 30.68 -500.0, 441.8465 + 500.0, -987.99 + 500.0, 30.68 + 500.0)
                RemoveVehiclesFromGeneratorsInArea(316.79 - 300.0, -592.36 - 300.0, 43.28 - 300.0, 316.79 + 300.0, -592.36 + 300.0, 43.28 + 300.0)
                RemoveVehiclesFromGeneratorsInArea(-2150.44 - 500.0, 3075.99 - 500.0, 32.8 - 500.0, -2150.44 + 500.0, -3075.99 + 500.0, 32.8 + 500.0)
                RemoveVehiclesFromGeneratorsInArea(-1108.35 - 300.0, 4920.64 - 300.0, 217.2 - 300.0, -1108.35 + 300.0, 4920.64 + 300.0, 217.2 + 300.0)
                RemoveVehiclesFromGeneratorsInArea(-458.24 - 300.0, 6019.81 - 300.0, 31.34 - 300.0, -458.24 + 300.0, 6019.81 + 300.0, 31.34 + 300.0)
                RemoveVehiclesFromGeneratorsInArea(1854.82 - 300.0, 3679.4 - 300.0, 33.82 - 300.0, 1854.82 + 300.0, 3679.4 + 300.0, 33.82 + 300.0)
                RemoveVehiclesFromGeneratorsInArea(-724.46 - 300.0, -1444.03 - 300.0, 5.0 - 300.0, -724.46 + 300.0, -1444.03 + 300.0, 5.0 + 300.0)
            end

        else

            QBCore.Functions.Notify('Fenix Police Response: Enabled')
            if Config.isDebug then print('Fenix Police Response: Enabled') end

            SetAudioFlag('PoliceScannerDisabled', false)
            -- Keep native random cops OFF — fenix-police handles its own spawning.
            -- Native ambient cops follow traffic laws and show flashing search-mode blips,
            -- which conflicts with the script's pursuit system.
            SetCreateRandomCops(false)
            SetCreateRandomCopsNotOnScenarios(false)
            SetCreateRandomCopsOnScenarios(false)
            DistantCopCarSirens(false)

            SetMaxWantedLevel(5) -- Uses max 5 star wanted level
        end

        -- Always enable the dispatch services, as they are only meant for non-police things like Ambulance/Fire as this mod handles police separately.
        for i = 1, 15 do
            local toggle = Config.AIResponse.dispatchServices[i]
            EnableDispatchService(i, toggle)
        end

        -- [Upstate Mafia] Suppress policet (police transporter) from spawning anywhere
        SetVehicleModelIsSuppressed(GetHashKey('policet'), true)
        SetCreateRandomCops(false)
        SetCreateRandomCopsNotOnScenarios(false)
        SetCreateRandomCopsOnScenarios(false)
        EnableDispatchService(1, false)
        EnableDispatchService(4, false)
        EnableDispatchService(6, false)
        EnableDispatchService(7, false)
        EnableDispatchService(8, false)
        EnableDispatchService(9, false)
        EnableDispatchService(10, false)


        -- Always update evasion times for when this mod handles police.
        for i, evasionTime in ipairs(Config.evasionTimes) do
            SetWantedLevelHiddenEvasionTime(PlayerId(), i, evasionTime)
        end
    
    end)

end



-- COPS ONLINE CHECKING --

RegisterNetEvent('fenix-police:updateCopsOnline', function(polCount)
    if polCount >= Config.numberOfPoliceRequired and Config.onlyWhenPlayerPoliceOffline == true then
        if disableAIPolice == true then
            -- Already disabled no need to do the same thing again.
        else
            disableAIPolice = true
            UpdateDispatchServices()
        end
    elseif (Config.onlyWhenPlayerPoliceOffline == false) or (polCount < Config.numberOfPoliceRequired and Config.onlyWhenPlayerPoliceOffline == true)  then
        if disableAIPolice == false then
            -- Already enabled no need to do the same thing again.
        else
            disableAIPolice = false
            UpdateDispatchServices()
        end
    end
end)

-- checks if a player is one of the police jobs configured and returns true if they are.
-- [Upstate Mafia patch] Assigns to the forward-declared local near the top of
-- this file (was `local function`, which made it invisible to everything above).
function isPlayerPoliceOfficer()

    local playerData = QBCore.Functions.GetPlayerData()
    local isPolice = false

    if not playerData or not playerData.job then return false end

    for _, job in ipairs(Config.PoliceJobsToCheck) do
        if playerData.job.name == job.jobName then
            -- Check if configured to only count on-duty players?
            if Config.PlayerPoliceOnlyOnDuty then
                if playerData.job.onduty then
                    isPolice = true
                else
                    isPolice = false
                end
            else
                isPolice = true
            end
        end
    end

    return isPolice

end

-- [Upstate Mafia] Exposed so client/ambient.lua (a separate file, and therefore
-- outside this file's locals) can skip enforcement against on-duty officers
-- before it starts a pursuit, rather than relying on the wanted level being
-- blocked after the chase has already begun.
exports('IsPlayerPoliceOfficer', function() return isPlayerPoliceOfficer() end)


    

-------------------------------------------------
-- SURRENDER & ARREST SYSTEM (Upstate Mafia)   --
-------------------------------------------------

local HANDS_UP_DICT = 'random@mugging3'
local HANDS_UP_ANIM = 'handsup_standing_base'
local KNEEL_DICT    = 'random@arrests@busted'
local KNEEL_ANIM    = 'idle_a'

-- [Upstate Mafia] Forward declarations. The traffic-ticket path lives in its own
-- section below triggerArrest, but shares this key mapping — one key for one
-- intent ("I'm stopping"), with where you are deciding what that means.
local beginPullOver, cancelPullOver

-- Toggle surrender when player presses H
-- [Upstate Mafia] Command name deliberately unchanged — renaming it would drop
-- every existing player's rebind. Only the label reflects the second outcome.
RegisterKeyMapping('surrendertopolice', 'Surrender / Pull Over for Police', 'keyboard', 'H')
RegisterCommand('surrendertopolice', function()
    if isBeingArrested or isBeingTicketed then return end

    -- [Upstate Mafia] Either system can be turned off independently, so this can
    -- no longer gate on the arrest system alone — that would leave the key dead
    -- on a server running tickets only.
    local arrestEnabled = Config.ArrestSystem and Config.ArrestSystem.enabled
    local ticketEnabled = Config.TicketSystem and Config.TicketSystem.enabled
    if not (arrestEnabled or ticketEnabled) then return end

    -- Nothing to surrender to without a wanted level.
    if GetPlayerWantedLevel(PlayerId()) < 1 then
        if isSurrendering then
            isSurrendering = false
            ClearPedTasks(PlayerPedId())
        end
        if isPullingOver then cancelPullOver() end
        return
    end

    local playerPed = PlayerPedId()

    if isPullingOver then
        -- Toggle back off: hazards off, and the pursuit resumes.
        cancelPullOver()
        return
    end

    if isSurrendering then
        -- Toggle back off: hands down, carry on.
        isSurrendering = false
        ClearPedTasks(playerPed)
        return
    end

    -- Hands up on foot only. Surrendering through a windscreen looks absurd and
    -- leaves the officer walking up to a car they can't reach into — which is
    -- what the ticket path handles instead, by having them walk to the window.
    if IsPedInAnyVehicle(playerPed, false) then
        if ticketEnabled then
            beginPullOver()
        elseif Config.isDebug then
            print('[fenix-police] surrender ignored: in a vehicle')
        end
        return
    end

    if not arrestEnabled then return end

    isSurrendering = true

    CreateThread(function()
        RequestAnimDict(HANDS_UP_DICT)
        local waited = 0
        while not HasAnimDictLoaded(HANDS_UP_DICT) and waited < 200 do
            Wait(10)
            waited = waited + 1
        end
        if not isSurrendering then return end

        ClearPedTasks(playerPed)
        -- Flag 49 = upper-body only + looping, so the player can still be turned
        -- and doesn't slide out of the pose.
        TaskPlayAnim(playerPed, HANDS_UP_DICT, HANDS_UP_ANIM, 8.0, -8.0, -1, 49, 0, false, false, false)

        -- Hold the pose until arrested, cancelled, or the wanted level clears.
        while isSurrendering and not isBeingArrested do
            if GetPlayerWantedLevel(PlayerId()) < 1 then
                isSurrendering = false
                ClearPedTasks(PlayerPedId())
                break
            end
            if not IsEntityPlayingAnim(PlayerPedId(), HANDS_UP_DICT, HANDS_UP_ANIM, 3) then
                TaskPlayAnim(PlayerPedId(), HANDS_UP_DICT, HANDS_UP_ANIM, 8.0, -8.0, -1, 49, 0, false, false, false)
            end
            Wait(250)
        end
    end)
end, false)

-- Disable controls while surrendering or being arrested (runs every frame)
--
-- [Upstate Mafia] isBeingTicketed is held to the same rule, but isPullingOver
-- deliberately is NOT. Between signalling and the officer reaching your window
-- you are still driving — you have to be able to brake, steer onto the verge,
-- and press the key again to call it off. Locking controls there would also kill
-- the key mapping that cancels it, since a disabled control never fires the
-- command bound to it.
Citizen.CreateThread(function()
    while true do
        if isSurrendering or isBeingArrested or isBeingTicketed then
            DisableAllControlActions(0)
            EnableControlAction(0, 1, true)   -- Look L/R
            EnableControlAction(0, 2, true)   -- Look U/D
            EnableControlAction(0, 245, true) -- Chat / T
            EnableControlAction(0, 249, true) -- N (push to talk)
            Wait(0)
        else
            Wait(500)
        end
    end
end)

-- Find the nearest police station from Config
local function getNearestStation(coords)
    local best = Config.ArrestSystem.stations[1]
    local bestDist = 999999.0
    for _, s in ipairs(Config.ArrestSystem.stations) do
        local d = #(coords - vector3(s.x, s.y, s.z))
        if d < bestDist then bestDist = d; best = s end
    end
    return best
end

--- Officers respond to a surrendering player instead of shooting.
---
--- Rewritten after the original was disabled. That version told EVERY officer in
--- EVERY responding unit to leave their vehicle the moment you surrendered,
--- which emptied the entire pursuit and broke the vehicle-driven chase loop it
--- shares this file with.
---
--- This version exits exactly ONE officer, and only once their car has actually
--- stopped. Everyone else stays seated and simply holds fire. The pursuit loop
--- is left intact, so if you cancel the surrender it just carries on.
---
--- @return boolean handled  true if this unit is participating in the surrender
--- Assigns to the forward-declared local near handleChaseBehavior.
function handleSurrenderApproach(vehicleData, playerPed, vehNetID)
    if isBeingArrested then return true end

    local playerCoords = GetEntityCoords(playerPed)
    local vehicle = NetToVeh(vehNetID)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return false end

    local tasks = spawnedVehicles[vehNetID] and spawnedVehicles[vehNetID].officerTasks
    if not tasks then return false end

    -- Only the unit that is genuinely closest supplies the arresting officer.
    -- Everything else holds, which is what keeps the rest of the pursuit seated.
    local unitDist = #(playerCoords - GetEntityCoords(vehicle))
    local isArrestingUnit = unitDist <= (Config.ArrestSystem.approachDistance or 35.0)

    -- Bring this unit to a stop first. Pulling a ped out of a moving car is what
    -- produced the ragdolling officers that got this feature switched off.
    if isArrestingUnit and GetEntitySpeed(vehicle) > 1.0 then
        local driver = GetPedInVehicleSeat(vehicle, -1)
        if driver and driver ~= 0 and DoesEntityExist(driver) then
            if not NetworkHasControlOfEntity(driver) then NetworkRequestControlOfEntity(driver) end
            -- Clear the chase task first, or the driver keeps steering at the
            -- player under TaskVehicleChase while BringVehicleToHalt fights it
            -- for control -- the ram this feature exists to prevent.
            ClearPedTasks(driver)
            BringVehicleToHalt(vehicle, 6.0, 2, false)
        end
        return true
    end

    local arrester, arresterDist = nil, 9999.0

    for pedNetID, _ in pairs(vehicleData.officers) do
        local officer = NetToPed(pedNetID)
        if DoesEntityExist(officer) and officer ~= 0 and not IsPedDeadOrDying(officer, true) then
            if not NetworkHasControlOfEntity(officer) then NetworkRequestControlOfEntity(officer) end

            local seated = IsPedInAnyVehicle(officer, false)
            local d = #(playerCoords - GetEntityCoords(officer))

            if isArrestingUnit and not seated and d < arresterDist then
                arrester, arresterDist = pedNetID, d
            end

            if isArrestingUnit and seated and tasks[pedNetID] ~= 'ExitForArrest' and not arrester then
                -- One officer out, from a stopped car, once only.
                TaskLeaveVehicle(officer, vehicle, 0)
                tasks[pedNetID] = 'ExitForArrest'
                break
            end
        end
    end

    if arrester then
        local officer = NetToPed(arrester)
        if tasks[arrester] ~= 'ApproachArrest' then
            GiveWeaponToPed(officer, GetHashKey('WEAPON_PISTOL'), 999, false, true)
            SetCurrentPedWeapon(officer, GetHashKey('WEAPON_PISTOL'), true)
            TaskGoToEntity(officer, playerPed, -1, 1.0, 1.5, 1073741824, 0)
            tasks[arrester] = 'ApproachArrest'
        end

        if arresterDist <= (Config.ArrestSystem.arrestDistance or 2.0) then
            triggerArrest(officer)
        end
    end

    return isArrestingUnit
end

-- Helis hover overhead during surrender (stop shooting, keep circling)
--- Superseded and never called. Air units now hold fire via an early return in
--- handleHeliChaseBehavior / handleAirChaseBehavior, which leaves them on their
--- existing circling task instead of re-tasking them mid-surrender. Kept only so
--- the diff against upstream stays legible.
local function handleHeliSurrenderHover(vehicleData, playerPed, vehNetID)
    do return end
    for pedNetID, _ in pairs(vehicleData.officers) do
        local officer = NetToPed(pedNetID)
        if not DoesEntityExist(officer) or officer == 0 or IsPedDeadOrDying(officer, true) then
            goto nextCrew
        end

        local taskStatus = spawnedHeliUnits[vehNetID].officerTasks[pedNetID]

        if IsPedInAnyVehicle(officer, false) then
            if GetPedInVehicleSeat(GetVehiclePedIsIn(officer, false), -1) == officer then
                -- Pilot: circle at low altitude
                if taskStatus ~= 'SurrenderHover' then
                    TaskHeliChase(officer, playerPed, 0, 0, 50)
                    spawnedHeliUnits[vehNetID].officerTasks[pedNetID] = 'SurrenderHover'
                end
            else
                -- Crew: just aim, don't shoot
                if taskStatus ~= 'AimCover' then
                    TaskAimGunAtEntity(officer, playerPed, -1, false)
                    spawnedHeliUnits[vehNetID].officerTasks[pedNetID] = 'AimCover'
                end
            end
        end
        ::nextCrew::
    end
end

-- ============================
-- BUSTED SCREEN & ARREST FLOW
-- ============================

function triggerArrest(arrestingCop)
    if isBeingArrested then return end
    isBeingArrested = true
    isSurrendering  = false

    Citizen.CreateThread(function()
        local playerPed    = PlayerPedId()
        local arrestCoords = GetEntityCoords(playerPed)

        -- Freeze player and play kneel animation
        FreezeEntityPosition(playerPed, true)
        RequestAnimDict(KNEEL_DICT)
        while not HasAnimDictLoaded(KNEEL_DICT) do Wait(10) end
        ClearPedTasks(playerPed)
        TaskPlayAnim(playerPed, KNEEL_DICT, KNEEL_ANIM, 8.0, -8.0, -1, 33, 0, false, false, false)

        -- Make the arresting cop face the player
        if DoesEntityExist(arrestingCop) and not IsPedDeadOrDying(arrestingCop, true) then
            TaskTurnPedToFaceEntity(arrestingCop, playerPed, 2000)
        end

        Wait(800)

        -- ---- BUSTED CINEMATIC ----

        -- 1. Load scaleform
        local sf = RequestScaleformMovie('MP_BIG_MESSAGE_FREEMODE')
        while not HasScaleformMovieLoaded(sf) do Wait(0) end

        BeginScaleformMovieMethod(sf, 'SHOW_SHARD_WASTED_MP_MESSAGE')
        BeginTextCommandScaleformString('STRING')
        AddTextComponentSubstringPlayerName('~r~BUSTED')
        EndTextCommandScaleformString()
        BeginTextCommandScaleformString('STRING')
        AddTextComponentSubstringPlayerName(Config.ArrestSystem.bustedSubtitle or '')
        EndTextCommandScaleformString()
        EndScaleformMovieMethod()

        -- 2. Screen effect + sound
        StartScreenEffect('DeathFailOut', 0, false)
        PlaySoundFrontend(-1, 'ScreenFlash', 'MissionFailedSounds', true)
        SetTimeScale(0.15)

        -- 3. Cinematic camera — slowly pull back and rise
        local heading  = GetEntityHeading(playerPed)
        local rad      = math.rad(heading + 160.0)
        local startDist, endDist = 2.0, 6.0
        local startZ,   endZ    = 0.8, 3.0

        local cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
        local startPos = arrestCoords + vector3(math.sin(rad) * startDist, math.cos(rad) * startDist, startZ)
        SetCamCoord(cam, startPos.x, startPos.y, startPos.z)
        PointCamAtCoord(cam, arrestCoords.x, arrestCoords.y, arrestCoords.z + 0.4)
        SetCamActive(cam, true)
        RenderScriptCams(true, true, 800, true, true)

        -- 4. Draw loop — render scaleform and animate camera
        --
        -- [Upstate Mafia patch] Timed off GetNetworkTime(), NOT GetGameTimer().
        -- SetTimeScale(0.15) above slows game time to 15%, and GetGameTimer
        -- advances with it — so a 6000ms window took ~40 SECONDS of real time,
        -- and the cinematic appeared to hang. GetNetworkTime is real time and is
        -- unaffected by the local time scale.
        local t0       = GetNetworkTime()
        local duration = math.min(Config.ArrestSystem.bustedDuration or 6000,
                                  (Config.ArrestSystem.bustedMaxDuration or 30000))
        local skippable = Config.ArrestSystem.bustedSkippable ~= false
        local skipped  = false

        while (GetNetworkTime() - t0) < duration and not skipped do
            local progress = (GetNetworkTime() - t0) / duration
            -- Ease-out for smooth decel
            local ease = 1.0 - (1.0 - progress) * (1.0 - progress)

            if skippable then
                -- Controls are disabled below, so this has to read the DISABLED
                -- state. 201 = INPUT_FRONTEND_ACCEPT (Enter), 22 = jump (Space).
                if IsDisabledControlJustPressed(0, 201) or IsDisabledControlJustPressed(0, 22) then
                    skipped = true
                end

                SetTextFont(4)
                SetTextScale(0.42, 0.42)
                SetTextColour(255, 255, 255, 180)
                SetTextCentre(true)
                SetTextEntry('STRING')
                AddTextComponentString('Press ~b~SPACE~w~ to skip')
                DrawText(0.5, 0.88)
            end

            local curDist = startDist + (endDist - startDist) * ease
            local curZ    = startZ   + (endZ   - startZ)   * ease
            -- Slow rotate (15 degrees over the full duration)
            local curRad  = rad + math.rad(15.0 * ease)
            local camPos  = arrestCoords + vector3(math.sin(curRad) * curDist, math.cos(curRad) * curDist, curZ)

            SetCamCoord(cam, camPos.x, camPos.y, camPos.z)
            PointCamAtCoord(cam, arrestCoords.x, arrestCoords.y, arrestCoords.z + 0.3)
            DrawScaleformMovieFullscreen(sf, 255, 255, 255, 255, 0)
            DisableAllControlActions(0)
            Wait(0)
        end

        -- 5. Restore time before fade (so fade isn't in slow-mo)
        SetTimeScale(1.0)
        StopScreenEffect('DeathFailOut')

        -- 6. Fade to black
        DoScreenFadeOut(1500)
        while not IsScreenFadedOut() do Wait(50) end

        -- 7. Cleanup camera & scaleform
        SetCamActive(cam, false)
        RenderScriptCams(false, false, 0, true, true)
        DestroyCam(cam, false)
        SetScaleformMovieAsNoLongerNeeded(sf)

        -- 8. Clear wanted & teleport to nearest station
        ClearPlayerWantedLevel(PlayerId())
        SetPlayerWantedLevel(PlayerId(), 0, false)
        SetPlayerWantedLevelNow(PlayerId(), false)

        -- [Upstate Mafia] This cinematic used to be the entire consequence -
        -- clear wanted, wake up at a station, done. qbx_arrest (standalone
        -- resource) turns "got busted" into an actual rcore_prison sentence,
        -- scaled by qbx_reputation's criminal tier. One report, best-effort:
        -- if qbx_arrest isn't running this plays exactly like it did before.
        if GetResourceState('um_livingworld') == 'started' then
            TriggerServerEvent('qbx_arrest:server:reportArrest')
        end

        local station
        if (Config.ArrestSystem.releaseAt or 'nearest') == 'random' then
            station = Config.ArrestSystem.stations[math.random(#Config.ArrestSystem.stations)]
        else
            station = getNearestStation(arrestCoords)
        end

        ClearPedTasks(playerPed)
        FreezeEntityPosition(playerPed, false)
        SetEntityCoords(playerPed, station.x, station.y, station.z, false, false, false, false)
        SetEntityHeading(playerPed, station.w)

        -- 9. Clean up all spawned units (same as end-of-wanted)
        handleEndWantedDelete()

        Wait(2000)

        -- 10. Fade back in at the station
        DoScreenFadeIn(2000)
        while not IsScreenFadedIn() do Wait(50) end

        isBeingArrested = false
    end)
end


-------------------------------------------------
-- TRAFFIC TICKET SYSTEM (Upstate Mafia)       --
-------------------------------------------------
--
-- The roadside outcome, on the same key as the surrender above and with the
-- opposite consequence: an officer walks to your window, writes a citation, and
-- you drive away from where you stopped instead of waking up at a station with
-- whatever you were doing abandoned.
--
-- Structurally parallel to the arrest path on purpose — exactly ONE officer out
-- of exactly one stopped car, everyone else holds — because that shape is what
-- made the arrest system work after the original version emptied every
-- responding unit the moment you put your hands up.

local MPS_TO_MPH = 2.23694   -- GetEntitySpeed is metres per second

local ticketUnit        = nil    -- vehNetID of the unit working the stop
local pullOverStopped   = false  -- you have actually come to a stop at least once
local pullOverStartedAt = 0
local pendingTicket     = nil    -- the server's reply: { amount, paid }

local function ticketCfg() return Config.TicketSystem or {} end
local function ticketMsg(key) return (ticketCfg().messages or {})[key] end

local function ticketNotify(msg)
    if not msg or msg == '' then return end
    -- QBCore is the only notification path this resource has. If it isn't there,
    -- fall back to chat rather than swallowing the message — every one of these
    -- is telling the player why something did or didn't happen.
    local ok = pcall(function() QBCore.Functions.Notify(msg) end)
    if not ok then
        TriggerEvent('chat:addMessage', { args = { '[Police]', msg } })
    end
end

--- 12345 -> "12,345". Amounts are read at a glance off a notification.
local function formatMoney(amount)
    local s = tostring(math.floor(amount or 0))
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    return (out:gsub('^,', ''))
end

--- Instructional help box, redrawn every frame it's wanted.
local function drawTicketHint(msg)
    if not msg or msg == '' then return end
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName(msg)
    EndTextCommandDisplayHelp(0, false, true, -1)
end

--- Can this be settled at the roadside right now?
--- @return boolean ok, string|nil reason
local function ticketEligible()
    local c = ticketCfg()
    if not c.enabled then return false, 'disabled' end

    local playerPed = PlayerPedId()
    local veh = GetVehiclePedIsIn(playerPed, false)
    if veh == 0 then return false, 'on foot' end
    if c.driverOnly ~= false and GetPedInVehicleSeat(veh, -1) ~= playerPed then
        return false, 'not driving'
    end

    local level = GetPlayerWantedLevel(PlayerId())
    if level < 1 then return false, 'not wanted' end
    if level > (c.maxWantedLevel or 1) then return false, 'too serious' end
    if c.denyAfterShooting ~= false and playerHasShot then return false, 'shots fired' end

    return true
end

--- Drop the task markers this system wrote onto a unit, so the chase loop
--- re-tasks it from scratch. Without this a cancelled stop leaves an officer
--- standing in the road carrying an 'ApproachWindow' marker that the loop reads
--- as "already handled" and never touches again.
local function releaseTicketUnit()
    if not ticketUnit then return end

    local data = spawnedVehicles[ticketUnit]
    if data and data.officerTasks then
        for pedNetID, task in pairs(data.officerTasks) do
            if task == 'ExitForTicket' or task == 'ApproachWindow' then
                data.officerTasks[pedNetID] = nil
                local officer = NetToPed(pedNetID)
                if officer and officer ~= 0 and DoesEntityExist(officer) then
                    SetPedKeepTask(officer, false)
                    ClearPedTasks(officer)
                end
            end
        end
    end

    local veh = NetToVeh(ticketUnit)
    if veh and veh ~= 0 and DoesEntityExist(veh) then
        SetVehicleHasMutedSirens(veh, false)
    end

    ticketUnit = nil
end

--- Sirens off, back to an ordinary patrol drive. Used to send the response away
--- at the end of a stop, before the wanted level clears — the cleanup sweep
--- deletes every spawned unit the instant you stop being wanted, and a car that
--- is already driving is far less jarring to lose than one at your bumper.
local function dismissUnit(vehNetID)
    local veh = NetToVeh(vehNetID)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return end

    SetVehicleHasMutedSirens(veh, false)
    SetSirenKeepOn(veh, false)
    SetVehicleSiren(veh, false)

    local driver = GetPedInVehicleSeat(veh, -1)
    if driver and driver ~= 0 and DoesEntityExist(driver) then
        if not NetworkHasControlOfEntity(driver) then NetworkRequestControlOfEntity(driver) end
        ClearPedTasks(driver)
        SetDriverAbility(driver, 0.9)
        SetDriverAggressiveness(driver, 0.2)
        -- 786603: obeys lights, avoids traffic. The same style the ambient system
        -- uses to end a traffic stop, so both read identically from the kerb.
        TaskVehicleDriveWander(driver, veh, 16.0, 786603)
    end
end

local function dismissAllUnits(exceptNetID)
    for vehNetID in pairs(spawnedVehicles) do
        if vehNetID ~= exceptNetID then dismissUnit(vehNetID) end
    end
end

--- Officer at the window: write it, hand it over, and put everyone back on the
--- road. This is the counterpart to triggerArrest, and the whole point of the
--- feature is what it does NOT do — no fade, no teleport, no lost position.
local function triggerTicket(officer, copVeh)
    if isBeingTicketed then return end
    isBeingTicketed = true
    isPullingOver   = false

    Citizen.CreateThread(function()
        local c = ticketCfg()
        local playerPed = PlayerPedId()
        local level = GetPlayerWantedLevel(PlayerId())
        if level < 1 then level = 1 end

        -- Ask the server for the citation. It owns the amount and the charge —
        -- the client reports that it was stopped, never what it will pay.
        pendingTicket = nil
        TriggerServerEvent('fenix-police:server:issueTicket', level)

        if DoesEntityExist(officer) then
            SetPedKeepTask(officer, true)
            TaskTurnPedToFaceEntity(officer, playerPed, 1500)
        end
        Wait(1200)
        if DoesEntityExist(officer) then
            TaskStartScenarioInPlace(officer, 'WORLD_HUMAN_CLIPBOARD', 0, true)
        end

        -- Writing. Timed on GetNetworkTime for the same reason the busted screen
        -- is: it is real time and can't be stretched by a local time scale.
        local t0 = GetNetworkTime()
        local duration = (c.writeSeconds or 8) * 1000
        while (GetNetworkTime() - t0) < duration do
            -- Bailing out of the car mid-citation ends the stop as a stop; the
            -- wanted level survives and the pursuit picks it up from there.
            if GetVehiclePedIsIn(PlayerPedId(), false) == 0 then
                isBeingTicketed = false
                releaseTicketUnit()
                if DoesEntityExist(officer) then ClearPedTasks(officer) end
                return
            end
            Wait(100)
        end

        if DoesEntityExist(officer) then ClearPedTasks(officer) end

        local t = pendingTicket
        if t and (t.amount or 0) > 0 then
            local text = t.paid and ticketMsg('issued') or ticketMsg('unpaid')
            ticketNotify((text or 'Citation issued: $%s'):format(formatMoney(t.amount)))
        else
            -- Fines off, or the server declined to charge: still an outcome.
            ticketNotify(ticketMsg('warning'))
        end

        -- Hazards off — you're released.
        local playerVeh = GetVehiclePedIsIn(PlayerPedId(), false)
        if playerVeh ~= 0 then
            SetVehicleIndicatorLights(playerVeh, 0, false)
            SetVehicleIndicatorLights(playerVeh, 1, false)
        end

        -- Wrap-up: you have your controls back and the wanted level is still on,
        -- which is what holds the cleanup sweep off while everyone drives away.
        ticketWrapUp    = true
        isBeingTicketed = false
        pullOverStopped = false

        dismissAllUnits(ticketUnit)

        -- The officer who wrote it walks back to their own car first.
        if DoesEntityExist(officer) and copVeh and DoesEntityExist(copVeh) then
            ClearPedTasks(officer)
            TaskEnterVehicle(officer, copVeh, 15000, -1, 1.5, 1, 0)
            local waited = 0
            while waited < 12000 do
                if not DoesEntityExist(officer) then break end
                if GetVehiclePedIsIn(officer, false) == copVeh then break end
                Wait(250)
                waited = waited + 250
            end
        end

        local stopUnit = ticketUnit
        releaseTicketUnit()
        if stopUnit then dismissUnit(stopUnit) end

        Wait((c.dispersalSeconds or 6) * 1000)

        ClearPlayerWantedLevel(PlayerId())
        SetPlayerWantedLevel(PlayerId(), 0, false)
        SetPlayerWantedLevelNow(PlayerId(), false)

        playerVeh = GetVehiclePedIsIn(PlayerPedId(), false)
        if playerVeh ~= 0 then SetVehicleIsWanted(playerVeh, false) end

        ticketWrapUp = false
    end)
end

--- Officers work a roadside stop instead of a pursuit.
---
--- Same contract as handleSurrenderApproach: return true and this unit skips its
--- chase logic entirely for this cycle. The differences are that every unit
--- holds once a stop is under way (a traffic stop with three cars circling isn't
--- one), that the officer walks to the driver's window rather than to the ped,
--- and that nothing here draws a weapon — a citation delivered at gunpoint is an
--- arrest with extra steps.
---
--- Assigns to the forward-declared local near handleChaseBehavior.
function handleTicketApproach(vehicleData, playerPed, vehNetID)
    if isBeingTicketed then return true end

    local c = ticketCfg()
    local playerVeh = GetVehiclePedIsIn(playerPed, false)
    if playerVeh == 0 then return false end

    local vehicle = NetToVeh(vehNetID)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return false end

    local tasks = spawnedVehicles[vehNetID] and spawnedVehicles[vehNetID].officerTasks
    if not tasks then return false end

    -- The unit working the stop can be culled out from under us — too far, dead,
    -- despawned. Drop the claim so another unit picks the stop up instead of
    -- leaving the player sat at the kerb until the timeout.
    if ticketUnit and not spawnedVehicles[ticketUnit] then ticketUnit = nil end

    local playerCoords = GetEntityCoords(playerPed)
    local unitDist = #(playerCoords - GetEntityCoords(vehicle))
    local approach = c.approachDistance or 40.0

    -- Backup that isn't working the stop. Beyond approachDistance it is returned
    -- to the chase loop, which is what actually drives it here — hold it too
    -- early and units spawned for this stop sit at their spawn point forever.
    -- Inside that range it stops where it is rather than circling and boxing in
    -- a car that has already pulled over.
    if ticketUnit and ticketUnit ~= vehNetID then
        if unitDist > approach then return false end
        if GetEntitySpeed(vehicle) > 1.0 then
            local driver = GetPedInVehicleSeat(vehicle, -1)
            if driver and driver ~= 0 and DoesEntityExist(driver) then
                if not NetworkHasControlOfEntity(driver) then NetworkRequestControlOfEntity(driver) end
                -- Drop the chase task before forcing a halt. Without this the
                -- driver is still under TaskVehicleChase, actively steering and
                -- accelerating at the player, and fights the forced braking the
                -- whole way down — which is what reads as a ram or a PIT on a
                -- car that has already pulled over.
                ClearPedTasks(driver)
                BringVehicleToHalt(vehicle, 8.0, 2, false)
            end
        end
        return true
    end

    -- One unit works the stop, and once chosen it keeps it — re-electing the
    -- closest unit every cycle would hand the stop to whichever car rolled a
    -- metre closer, halfway through the first officer's walk.
    if not ticketUnit then
        if unitDist > approach then return false end
        ticketUnit = vehNetID
    end

    -- Nobody gets out until both cars are stopped. Pulling a ped out of a moving
    -- car is what produced the ragdolling officers the arrest path had to fix.
    if GetEntitySpeed(playerVeh) * MPS_TO_MPH > (c.stoppedSpeedMph or 3.0) then return true end

    if GetEntitySpeed(vehicle) > 1.0 then
        local driver = GetPedInVehicleSeat(vehicle, -1)
        if driver and driver ~= 0 and DoesEntityExist(driver) then
            if not NetworkHasControlOfEntity(driver) then NetworkRequestControlOfEntity(driver) end
            -- Same reason as the backup-unit branch above: clear the live
            -- chase task first, or this unit fights its own forced stop.
            ClearPedTasks(driver)
            BringVehicleToHalt(vehicle, 6.0, 2, false)
        end
        return true
    end

    -- Lights on, wail off: the standing look for a stationary traffic stop, and
    -- what the ambient `stop` scenes already use.
    SetVehicleSiren(vehicle, true)
    SetVehicleHasMutedSirens(vehicle, true)

    local walker, walkerDist = nil, 9999.0

    for pedNetID, _ in pairs(vehicleData.officers) do
        local officer = NetToPed(pedNetID)
        if DoesEntityExist(officer) and officer ~= 0 and not IsPedDeadOrDying(officer, true) then
            if not NetworkHasControlOfEntity(officer) then NetworkRequestControlOfEntity(officer) end

            local seated = IsPedInAnyVehicle(officer, false)
            local d = #(playerCoords - GetEntityCoords(officer))

            if not seated and d < walkerDist then
                walker, walkerDist = pedNetID, d
            end

            if seated and tasks[pedNetID] ~= 'ExitForTicket' and not walker then
                -- One officer out, from a stopped car, once only.
                TaskLeaveVehicle(officer, vehicle, 0)
                tasks[pedNetID] = 'ExitForTicket'
                break
            end
        end
    end

    if walker then
        local officer = NetToPed(walker)
        -- Driver's window, turned toward the car. Same offset the ambient traffic
        -- stops use, so a scripted stop and an ambient one look the same.
        local window = GetOffsetFromEntityInWorldCoords(playerVeh, -1.9, -0.6, 0.0)

        if tasks[walker] ~= 'ApproachWindow' then
            SetPedKeepTask(officer, true)
            TaskGoStraightToCoord(officer, window.x, window.y, window.z, 1.0, 20000,
                GetEntityHeading(playerVeh) - 90.0, 0.5)
            tasks[walker] = 'ApproachWindow'
        end

        if #(GetEntityCoords(officer) - window) <= (c.windowDistance or 3.5) then
            triggerTicket(officer, vehicle)
        end
    end

    return true
end

--- Call off a stop in progress. Safe to call when none is running.
--- Assigns to the forward-declared local in the arrest section above.
function cancelPullOver(reason)
    if not isPullingOver then return end

    isPullingOver   = false
    pullOverStopped = false

    local veh = GetVehiclePedIsIn(PlayerPedId(), false)
    if veh ~= 0 then
        SetVehicleIndicatorLights(veh, 0, false)
        SetVehicleIndicatorLights(veh, 1, false)
    end

    releaseTicketUnit()

    if reason then ticketNotify(reason) end
    if Config.isDebug then
        print(('[fenix-police] roadside stop cancelled (%s)'):format(reason or 'by player'))
    end
end

--- Signal that you're pulling over. Assigns to the forward-declared local above.
function beginPullOver()
    local c = ticketCfg()
    local ok, reason = ticketEligible()
    if not ok then
        -- The one refusal a player will actually run into is "this is past a
        -- ticket". Saying nothing there is indistinguishable from a dead keybind.
        if reason == 'too serious' then ticketNotify(ticketMsg('serious')) end
        if Config.isDebug then
            print(('[fenix-police] roadside stop refused: %s'):format(reason))
        end
        return
    end

    isPullingOver     = true
    pullOverStopped   = false
    pullOverStartedAt = GetGameTimer()
    pendingTicket     = nil
    ticketUnit        = nil

    ticketNotify(ticketMsg('prompt'))

    Citizen.CreateThread(function()
        while isPullingOver do
            local veh   = GetVehiclePedIsIn(PlayerPedId(), false)
            local level = GetPlayerWantedLevel(PlayerId())

            if level < 1 then
                cancelPullOver()
            elseif level > (c.maxWantedLevel or 1) then
                cancelPullOver(ticketMsg('serious'))
            elseif veh == 0 then
                cancelPullOver()
            elseif c.denyAfterShooting ~= false and playerHasShot then
                cancelPullOver()
            elseif GetGameTimer() - pullOverStartedAt > (c.timeoutSeconds or 90) * 1000 then
                cancelPullOver()
            else
                local speedMph = GetEntitySpeed(veh) * MPS_TO_MPH
                if speedMph <= (c.stoppedSpeedMph or 3.0) then
                    pullOverStopped = true
                elseif pullOverStopped and speedMph > (c.fleeSpeedMph or 12.0) then
                    -- Stopped, then took off again. That's not a traffic stop.
                    cancelPullOver(ticketMsg('fled'))
                end

                if isPullingOver then
                    -- Re-applied every pass: the game clears indicators on some
                    -- vehicles when the engine or lights state changes.
                    SetVehicleIndicatorLights(veh, 0, true)
                    SetVehicleIndicatorLights(veh, 1, true)
                end
            end

            Wait(200)
        end
    end)

    -- The prompt needs a frame-rate thread; the state loop above deliberately
    -- doesn't run at one.
    Citizen.CreateThread(function()
        while isPullingOver or isBeingTicketed do
            drawTicketHint(isBeingTicketed and ticketMsg('writing') or ticketMsg('hint'))
            Wait(0)
        end
    end)
end

--- The server has priced and charged the citation.
RegisterNetEvent('fenix-police:client:ticketIssued', function(amount, paid)
    pendingTicket = { amount = amount or 0, paid = paid == true }
end)

--- True from the moment a stop is signalled until the wanted level clears.
--- Exported for the ambient layer: the radar trap that clocked you is still
--- carrying its own chase task, and it has to be told to stand down rather than
--- circling and PITting a car that has already pulled over.
exports('IsPlayerAtTrafficStop', function()
    return isPullingOver or isBeingTicketed or ticketWrapUp
end)


-- =============================================================================
-- [Upstate Mafia] AFTERMATH: what happens after officers actually win
-- =============================================================================
-- Previously the wanted level cleared and handleEndWantedDelete() wiped every
-- responding unit within a couple of ticks of the player going down -- cops
-- that just fought a whole pursuit vanish mid-frame, no different from the
-- player simply losing them. This gives the scene a beat instead: the nearest
-- officer attempts field first aid, other nearby units hold the road, and
-- only once that resolves (revived, or given up and left for EMS) does the
-- normal despawn path run.
--
-- Deliberately NOT a replacement for EMS -- ps-dispatch already raises its own
-- automatic PlayerDowned alert to on-duty medics the moment the player goes
-- down, independent of anything here. A failed field revive doesn't call
-- anything itself; it just means the scene holds in case that alert gets
-- answered, instead of the units already on scene disappearing first.

--- Framework-agnostic incapacitation check, shared by the wanted-clear logic
--- below and the aftermath hold check further down (client/client.lua's main
--- loop). Both used to run this independently, and the copy guarding
--- handleEndWantedDelete() was missing the metadata fallback -- meaning on any
--- framework where incapacitation only shows up in metadata (not the native
--- IsEntityDead/IsPedFatallyInjured checks), aftermath saw "recovered" the
--- instant the wanted level cleared and let the despawn sweep run immediately,
--- before a field revive ever got a chance to start.
local function isPlayerIncapacitated(playerPed)
    if IsEntityDead(playerPed) or IsPedFatallyInjured(playerPed) then return true end
    local pd = QBCore and QBCore.Functions and QBCore.Functions.GetPlayerData and QBCore.Functions.GetPlayerData()
    local md = pd and pd.metadata or nil
    return md ~= nil and (md['isdead'] or md['inlaststand'] or md['dead']) == true
end

local function aftermathCfg() return Config.Aftermath or {} end

-- aftermath itself is declared near the top of the file (see the comment
-- there) so the cleanup watchdog thread, which runs before this section,
-- can see it too.

--- Drops one officer's hostility back to the same passive relationship group
--- pursuit-only mode uses (ensurePassiveGroup(), see applyOfficerCombatProfile
--- near the top of the file) and clears the AlwaysFight attribute so they
--- stop being willing to open fire on their own. Shared by the medic and
--- every held unit -- an officer that was mid-pursuit when the player went
--- down is still flagged HATES_PLAYER and still combat-tasked at that
--- moment, and neither the revive attempt nor holding position actually
--- calms that down by itself.
local function standDownOfficer(ped)
    if not DoesEntityExist(ped) then return end
    if not NetworkHasControlOfEntity(ped) then NetworkRequestControlOfEntity(ped) end
    SetPedRelationshipGroupHash(ped, ensurePassiveGroup())
    SetPedCombatAttributes(ped, 46, false) -- AlwaysFight off
    SetPedFleeAttributes(ped, 0, false)
end

--- Nearest ground officer peds to `coords`, nearest first. Air/heli units are
--- excluded -- nobody is landing a helicopter to perform CPR.
local function nearbyGroundOfficers(coords, maxDist)
    local found = {}
    for _, vehicleData in pairs(spawnedVehicles) do
        for pedNetID in pairs(vehicleData.officers or {}) do
            local ped = NetToPed(pedNetID)
            if ped and ped ~= 0 and DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true) then
                local d = #(GetEntityCoords(ped) - coords)
                if d <= maxDist then
                    found[#found + 1] = { ped = ped, dist = d }
                end
            end
        end
    end
    table.sort(found, function(a, b) return a.dist < b.dist end)
    return found
end

local function endAftermath()
    aftermath.active = false
    TriggerServerEvent('fenix-police:aftermathState', false)
end

--- Officer walks to the player and attempts field CPR (CODE_HUMAN_MEDIC_KNEEL,
--- the same kneel-over-patient scenario the base game's own EMTs use). Rolls
--- once after reviveDuration -- success revives the player directly
--- (TriggerEvent, not TriggerClientEvent: this already IS the player's own
--- client). A failed roll does not end the sequence; it leaves aftermath
--- active so nearby units keep holding the scene for real EMS, until either
--- the player recovers or the hold cap in the main loop below gives up.
local function attemptFieldRevive(medicPed, playerCoords)
    Citizen.CreateThread(function()
        local c = aftermathCfg()
        if not DoesEntityExist(medicPed) then return end
        standDownOfficer(medicPed)
        ClearPedTasks(medicPed)
        TaskSetBlockingOfNonTemporaryEvents(medicPed, true)
        TaskGoStraightToCoord(medicPed, playerCoords.x, playerCoords.y, playerCoords.z, 1.5, 8000, 0.0, 0.5)

        local approachStart = GetGameTimer()
        while aftermath.active and DoesEntityExist(medicPed)
            and #(GetEntityCoords(medicPed) - playerCoords) > (c.reviveRange or 8.0)
            and GetGameTimer() - approachStart < 10000 do
            Wait(250)
        end

        if not aftermath.active or not DoesEntityExist(medicPed) then return end

        TaskStartScenarioAtPosition(medicPed, 'CODE_HUMAN_MEDIC_KNEEL',
            playerCoords.x, playerCoords.y, playerCoords.z, GetEntityHeading(medicPed), 0, false, false)

        Wait(c.reviveDuration or 8000)

        if not aftermath.active then return end
        if DoesEntityExist(medicPed) then ClearPedTasks(medicPed) end

        local stillDown = isPlayerIncapacitated(cache.ped)
        if stillDown and math.random() < (c.reviveChance or 0.35) then
            if Config.isDebug then print('[fenix-police] field revive succeeded') end
            TriggerEvent('wasabi_ambulance:revive')
            endAftermath()
        elseif Config.isDebug then
            print('[fenix-police] field revive failed, holding scene for EMS')
        end
    end)
end

--- A unit besides the medic holds position near the scene instead of idling
--- mid-road -- lights on, parked, ped standing by. Deliberately not
--- Config.Tactics' roadblock placement: that system finds a spot AHEAD of a
--- moving pursuit along a route, and there is no route here, just a fixed
--- point where the player went down.
local function holdSceneWithOfficer(entry)
    local ped = entry.ped
    if not DoesEntityExist(ped) then return end
    standDownOfficer(ped)

    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle == 0 then return end
    if not NetworkHasControlOfEntity(vehicle) then NetworkRequestControlOfEntity(vehicle) end

    BringVehicleToHalt(vehicle, 8.0, 3, false)
    SetVehicleIndicatorLights(vehicle, 0, true)
    SetVehicleIndicatorLights(vehicle, 1, true)
    SetVehicleSiren(vehicle, true)
    SetSirenKeepOn(vehicle, true)

    ClearPedTasks(ped)
    TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_GUARD_STAND', 0, true)
end

--- Called once, the instant the player is newly detected incapacitated while
--- ground officers are nearby. No-ops (leaves the previous instant-despawn
--- behaviour alone) if nothing is close enough to plausibly react.
local function beginAftermath(playerCoords)
    local c = aftermathCfg()
    if c.enabled == false or aftermath.active then return end

    local nearby = nearbyGroundOfficers(playerCoords, c.responseRange or 60.0)
    if #nearby == 0 then return end

    aftermath.active = true
    aftermath.until_ = GetGameTimer() + (c.holdAfterFailedMs or 240000)
    -- Tell the server so it stops re-tasking these officers (see
    -- applyGroundPursuitTask/cleanupIfNoPlayersWanted in server/server.lua) --
    -- otherwise the pursuit dispatch loop keeps shooting at and ramming a
    -- body someone is supposed to be reviving.
    TriggerServerEvent('fenix-police:aftermathState', true)

    local medicPed = nearby[1].ped
    attemptFieldRevive(medicPed, playerCoords)

    -- Every OTHER responding officer, not capped to the nearest few and not
    -- limited to responseRange: a wanted level 4-5 response is commonly 6-10
    -- units (Config.maxUnitsPerLevel), and a unit that wasn't in the first
    -- handful found -- or was still a hundred metres out when the player went
    -- down -- was still going to arrive fully hostile and ram whoever ends up
    -- kneeling over the body. Calming down doesn't need them to be close the
    -- way the medic's approach does, only reaching the scene does, so this
    -- sweeps every officer currently tracked for this pursuit.
    local held = 0
    for _, vehicleData in pairs(spawnedVehicles) do
        for pedNetID in pairs(vehicleData.officers or {}) do
            local ped = NetToPed(pedNetID)
            if ped and ped ~= 0 and DoesEntityExist(ped) and ped ~= medicPed then
                holdSceneWithOfficer({ ped = ped })
                held = held + 1
            end
        end
    end

    if Config.isDebug then
        print(('[fenix-police] aftermath started: 1 medic, %d unit(s) holding'):format(held))
    end
end


-- MAIN THREAD --
-- Monitor the player's wanted level and maintain police units
Citizen.CreateThread(function()
    local wantedTimer = 0
    local lastReportedWantedState = nil
    -- Whether this pursuit has already been called in on the radio. Also doubles
    -- as "a pursuit is running", which is what tells us to tear the contact
    -- state down exactly once when it ends rather than every idle cycle.
    local pursuitAnnounced = false

    -- Create a thread that continuously loops
    while true do

        Citizen.Wait(Config.scriptFrequency)

        local ok, err = pcall(function()

        local playerPed = PlayerPedId()
        if not playerPed or playerPed == 0 then return end  -- ped not ready yet

        local wantedLevel = GetPlayerWantedLevel(PlayerId())
        local isWantedNow = wantedLevel > 0
        if lastReportedWantedState ~= isWantedNow then
            TriggerServerEvent('fenix-police:updateWantedStatus', isWantedNow)
            lastReportedWantedState = isWantedNow
        else
            TriggerServerEvent('fenix-police:updateWantedStatus', isWantedNow)
        end
        SetCreateRandomCops(false)
        SetCreateRandomCopsNotOnScenarios(false)
        SetCreateRandomCopsOnScenarios(false)
        EnableDispatchService(1, false)
        EnableDispatchService(4, false)
        EnableDispatchService(6, false)
        EnableDispatchService(7, false)
        EnableDispatchService(8, false)
        EnableDispatchService(9, false)
        EnableDispatchService(10, false)

        -- Keep policet suppressed every cycle — the game can reset this suppression flag.
        SetVehicleModelIsSuppressed(GetHashKey('policet'), true)

        -- [Upstate Mafia patch] SetMaxWantedLevel(5) previously only ran
        -- reactively inside UpdateDispatchServices(), itself only called from
        -- the server's fenix-police:updateCopsOnline broadcast (server/server.lua,
        -- every 55s) when disableAIPolice actually CHANGES value. Observed on a
        -- live server: GetMaxWantedLevel() reads back 0 even though that path
        -- had already run (disableAIPolice was correctly false, not its nil
        -- default) — the engine's own cap was never actually reaching 5, so
        -- SET_PLAYER_WANTED_LEVEL silently clamped every crime to 0 stars, no
        -- matter the cause (killing peds, ApplyWantedLevel, even a manual
        -- SetPlayerWantedLevel). Re-asserted here every cycle instead, same
        -- reasoning as the policet suppression above it and the ambient
        -- dispatch-service disables below it: cheap, idempotent, and no longer
        -- depends on one event's timing/logic ever landing correctly.
        SetMaxWantedLevel(Config.MaxWantedLevel or 5)

        if wantedLevel > 0 then
            print(('[FENIX-LOOP] wanted=%d disableAI=%s pendingGround=%d'):format(wantedLevel, tostring(disableAIPolice), pendingGroundSpawns))
            -- Open spawn gate so new spawns are accepted for this chase.
            spawnGate = true

            -- Check if the player is shooting and set the flag
            if IsPedShooting(playerPed) then
                playerHasShot = true
                -- Escalate every unit to full hostility for Config.Combat.provokedDuration.
                -- This is what lets a low wanted level stay a pursuit until you start it.
                provokePolice()
            end

            -- If police are protected we should check if player is a cop and prevent being wanted
            if Config.PoliceWantedProtection then
                local playerIsOfficer = isPlayerPoliceOfficer()
                if playerIsOfficer == true then
                    wantedLevel = 0
                    ClearPlayerWantedLevel(PlayerId())
                end
            end
            
            -- [Upstate Mafia patch] Framework-agnostic incapacitation check.
            -- Original line read metadata['isdead'] / ['inlaststand'] from qb-ambulancejob.
            -- wasabi_ambulance doesn't set those keys, so dead players never cleared their wanted level.
            -- Native checks work regardless of EMS resource. Metadata kept as fallback for qbx_ambulancejob users.
            -- See isPlayerIncapacitated() above the aftermath section -- shared
            -- with the recovery check below so the two can't drift apart again.
            local _incapacitated = isPlayerIncapacitated(playerPed)
            if _incapacitated then
                if not aftermath.attemptedThisDown then
                    aftermath.attemptedThisDown = true
                    beginAftermath(GetEntityCoords(playerPed))
                end

                local vehicle = GetVehiclePedIsIn(playerPed, false)

                if vehicle and vehicle ~= 0 then 
                    local seats = GetVehicleModelNumberOfSeats(GetEntityModel(vehicle))
                    local otherPeds = false

                    for seat = -1, seats - 2 do
                        local pedInSeat = GetPedInVehicleSeat(vehicle, seat)
                        if pedInSeat ~= 0 and pedInSeat ~= playerPed then
                            otherPeds = true
                            break
                        end
                    end

                    if otherPeds then
                        -- If there are other players in the vehicle we don't want to clear wanted level or it will affect all players in the vehicle!
                    else
                        ClearPlayerWantedLevel(PlayerId())
                    end
                else
                    ClearPlayerWantedLevel(PlayerId())
                end
                
                
            else

                wantedTimer = 0

                -- Just marks a pursuit as live, for the reset-guard at the
                -- "pursuit over" branch below. The opening radio call itself
                -- (FenixPursuit.callItIn) no longer fires here, see the
                -- contact thread in pursuit.lua, `firstEver`. Firing it here
                -- meant dispatch had the player's outfit and vehicle the
                -- instant ANY witness (not necessarily a cop) triggered the
                -- wanted level, before an officer had ever actually laid eyes
                -- on them: cops "knew what you look like" from the moment
                -- you were wanted, which defeats changing your outfit/vehicle
                -- to shake a pursuit that never had real contact yet.
                if not pursuitAnnounced then
                    pursuitAnnounced = true
                end

                -- [Upstate Mafia] Don't reinforce a response that is standing
                -- down. From the moment an officer is at your window the wanted
                -- level is only still on to hold the delete sweep off, and a
                -- fresh cruiser spawning into a finished stop reads as a bug.
                -- isPullingOver is deliberately not included: before anyone is at
                -- the window a stop still needs a unit sent to work it.
                if not (isBeingTicketed or ticketWrapUp) then
                    maintainPoliceUnits(wantedLevel) -- Checks if we need to spawn more units, or remove excess units.
                end
                checkDeadPeds() -- Check for dead peds
                handleDeadPeds() -- Handle the deletion of dead peds.
                handleFarPeds() -- Handle the deletion of far peds. 

                for vehNetID, vehicleData in pairs(spawnedVehicles) do
                    handleChaseBehavior(vehicleData, playerPed, vehNetID, playerHasShot)
                end

                for vehNetID, vehicleData in pairs(spawnedHeliUnits) do
                    handleHeliChaseBehavior(vehicleData, playerPed, vehNetID, playerHasShot)
                end

                for vehNetID, vehicleData in pairs(spawnedAirUnits) do
                    handleAirChaseBehavior(vehicleData, playerPed, vehNetID, playerHasShot)
                end

            end
        else
            playerHasShot = false
            provokedUntil = 0
            isSurrendering = false

            -- Pursuit over: drop the AI blips and forget the last known
            -- position, so the next one starts from no knowledge instead of
            -- inheriting where this one left off. Guarded so it runs once rather
            -- than every cycle we spend not wanted.
            if pursuitAnnounced then
                pursuitAnnounced = false
                FenixPursuit.reset()
                FenixTactics.clearAll()
                FenixRoads.clearReservations()
            end
            -- [Upstate Mafia] Roadside stop state follows the same rule: no wanted
            -- level, nothing to stop for. ticketWrapUp is left alone — it is
            -- cleared by the stop that set it, immediately after clearing the
            -- wanted level that got us here.
            if isPullingOver then cancelPullOver() end

            -- [Upstate Mafia] Aftermath: hold the despawn sweep off while a
            -- field-revive/scene-hold sequence owns nearby units. Ends itself
            -- once the player recovers (field revive, real EMS, an admin
            -- command -- any of them) or the hold cap runs out.
            local recovered = not isPlayerIncapacitated(playerPed)
            if recovered then
                aftermath.attemptedThisDown = false
                if aftermath.active then endAftermath() end
            elseif aftermath.active and GetGameTimer() > aftermath.until_ then
                endAftermath() -- gave up waiting on EMS, hand off to the normal despawn path
            end

            if aftermath.active then
                -- Scene held: skip the delete sweep entirely and leave
                -- wantedTimer where it is, so normal cleanup resumes at
                -- whatever cycle it was on instead of finding it already past
                -- 3 and never running once this ends.
            else
                -- Wanted level just cleared — delete all spawned units.
                --
                -- We run for 3 cycles (wantedTimer < 3) instead of just once so that any
                -- in-flight server responses that arrive late still get cleaned up.  The
                -- spawnGate flag (closed by handleEndWantedDelete) prevents those late
                -- responses from re-populating the tracking tables between cleanup cycles.
                if wantedTimer < 3 then
                    handleEndWantedDelete()
                end
                wantedTimer = wantedTimer + 1
            end
        end

        end) -- end pcall
        if not ok then
            print('^1[FENIX-ERROR] Main loop error: ' .. tostring(err) .. '^7')
        end
    end
end)




-- MONITOR POLICE VEHICLES AND ADD CAMERAMAN FOR LINE OF SIGHT --
-- Monitor police vehicles and spawn cameraman to allow for visibility and detection of player to work correctly. 




-- Function to check if the ped model is a cop
function IsCopPed(model)
    local copModels = {
        's_m_y_cop_01', -- LSPD
        -- 's_f_y_cop_01', -- Female LSPD
        -- 's_m_y_sheriff_01', -- Sheriff
        -- 's_f_y_sheriff_01', -- Female Sheriff
        -- 's_m_y_hwaycop_01', -- Highway Cop
        -- 's_m_y_swat_01', -- SWAT (NOOSE)
        -- 's_m_m_snowcop_01', -- Snow Cop
        -- 's_m_m_fibsec_01' -- FIB Security
    }

    for _, copModel in ipairs(copModels) do
        if model == GetHashKey(copModel) then
            return true
        end
    end
    return false
end




-- This thread creates a "cameraman" for police vehicles. Essentially spawning an invisible cop above the car for a 1/4 second, just long enough to spot players, before deleting the cameraman. 
-- These are created clientside only, and NOT networked so it should only create them on the client PC and not try to sync them to the server.
-- When these were synced/networked I ran into issues where hundreds of invisible police officers would be all over the place. In theory this is because the server is being told to create them 
-- and the lag time means all the other clients are being told to create these peds too, long after the initial client had already deleted them, and that delete was not being communicated for some reason.
-- Since the purpose of these peds is only to allow vehicles to actually spot a wanted player there is no reason other clients need to know they exist. 
CreateThread(function ()
    local cleanupCameras = false
    while true do
        if GetPlayerWantedLevel(PlayerId()) >= 1 then 

            cleanupCameras = true
            local allVehicles = QBCore.Functions.GetVehicles()

            -- Loop through all cars and look for emergency vehicles driven by police.
            -- This will add a cameraman, disabling their vision cone to prevent duplicates on minimap. This will allow cops to actually
            -- see the player instead of being able to easily drive right past them while actively wanted without them noticing you. 
            for _, vehicle in pairs(allVehicles) do 

                -- Check for emergency vehicles only
                if GetVehicleClass(vehicle) == 18 then 
                    CreateThread(function () 
                        local carPos = GetEntityCoords(vehicle)
                        local theDriver = GetPedInVehicleSeat(vehicle, -1)
                        if theDriver then
                            local carheading = GetEntityHeading(theDriver)
                            local pedHash = GetHashKey('s_m_y_cop_01')
                            local cameraman = CreatePed(0, pedHash, carPos.x, carPos.y, carPos.z+10, carheading, false, false)
                            SetPedAiBlipHasCone(cameraman, false)  
                            SetPedAsCop(cameraman)  
                            SetEntityInvincible(cameraman, true)
                            SetEntityVisible(cameraman, false, 0)
                            SetEntityCompletelyDisableCollision(cameraman, true, false)
                            
                            Wait(250) -- Wait for 1/4 second to allow the cameraman to observe players and allow the game to handle wanted logic
                            DeletePed(cameraman) -- Remove the cameraman when done. 
                        end
                    end)
                end
            end
            Wait(200) -- Wait 1/5th second when wanted
        else

            -- Only loop through all peds once and delete cameramen. 
            if cleanupCameras == true then
                local pedPool = GetGamePool('CPed') -- Get all peds in the game world

                for _, ped in ipairs(pedPool) do
                    if IsPedHuman(ped) and IsPedAPlayer(ped) == false then -- Check if the ped is a human and not a player
                        local pedModel = GetEntityModel(ped)
        
                        if IsPedInAnyPoliceVehicle(ped) or IsCopPed(pedModel) then -- Check if the ped is a cop or in a police vehicle
                            if not IsEntityVisible(ped) then -- Check if the ped is invisible
                                if Config.isDebug then print('Found invisible cameraman officer and deleted it') end
                                DeleteEntity(ped) -- Delete the invisible ped
                            end
                        end
                    end
                end
                cleanupCameras = false
            end
            Wait(1000) -- Wait 10 seconds when not wanted

            
        end
    end
end)





-- **HELPFUL NATIVE FUNCTION INFO** --

--void TASK_ENTER_VEHICLE(Ped ped, Vehicle vehicle, int timeout, int seat, float speed, int p5, Any p6) // 0xC20E50AA46D09CA8 0xB8689B4E
-- Example usage  
-- VEHICLE::GET_CLOSEST_VEHICLE(x, y, z, radius, hash, unknown leave at 70)   
-- x, y, z: Position to get closest vehicle to.  
-- radius: Max radius to get a vehicle.  
-- modelHash: Limit to vehicles with this model. 0 for any.  
-- flags: The bitwise flags altering the function's behaviour.  
-- Does not return police cars or helicopters.  
-- It seems to return police cars for me, does not seem to return helicopters, planes or boats for some reason  
-- Only returns non police cars and motorbikes with the flag set to 70 and modelHash to 0. ModelHash seems to always be 0 when not a modelHash in the scripts, as stated above.   
-- These flags were found in the b617d scripts: 0,2,4,6,7,23,127,260,2146,2175,12294,16384,16386,20503,32768,67590,67711,98309,100359.  
-- Converted to binary, each bit probably represents a flag as explained regarding another native here: gtaforums.com/topic/822314-guide-driving-styles  
-- Conversion of found flags to binary: pastebin.com/kghNFkRi  
-- At exactly 16384 which is 0100000000000000 in binary and 4000 in hexadecimal only planes are returned.   
-- It's probably more convenient to use worldGetAllVehicles(int *arr, int arrSize) and check the shortest distance yourself and sort if you want by checking the vehicle type with for example VEHICLE::IS_THIS_MODEL_A_BOAT  
-- -------------------------------------------------------------------------  
-- Conclusion: This native is not worth trying to use. Use something like this instead: pastebin.com/xiFdXa7h
-- Use flag 127 to return police cars

-- -- TASK_ARREST_PED
-- TaskArrestPed(
-- 	ped --[[ Ped ]], 
-- 	target --[[ Ped ]]
-- )


-- -- SET_PED_COMBAT_ATTRIBUTES
-- SetPedCombatAttributes(
-- 	ped --[[ Ped ]], 
-- 	attributeIndex --[[ integer ]], 
-- 	enabled --[[ boolean ]]
-- )
-- enum eCombatAttribute
-- {
--   CA_INVALID = -1,	
--   CA_USE_COVER = 0, // AI will only use cover if this is set
--   CA_USE_VEHICLE = 1, // AI will only use vehicles if this is set
--   CA_DO_DRIVEBYS = 2, // AI will only driveby from a vehicle if this is set
--   CA_LEAVE_VEHICLES = 3, // Will be forced to stay in a ny vehicel if this isn't set
--   CA_CAN_USE_DYNAMIC_STRAFE_DECISIONS	= 4, // This ped can make decisions on whether to strafe or not based on distance to destination, recent bullet events, etc.
--   CA_ALWAYS_FIGHT = 5, // Ped will always fight upon getting threat response task
--   CA_FLEE_WHILST_IN_VEHICLE = 6, // If in combat and in a vehicle, the ped will flee rather than attacking
--   CA_JUST_FOLLOW_VEHICLE = 7, // If in combat and chasing in a vehicle, the ped will keep a distance behind rather than ramming
--   CA_PLAY_REACTION_ANIMS = 8, // Deprecated
--   CA_WILL_SCAN_FOR_DEAD_PEDS = 9, // Peds will scan for and react to dead peds found
--   CA_IS_A_GUARD = 10, // Deprecated
--   CA_JUST_SEEK_COVER = 11, // The ped will seek cover only 
--   CA_BLIND_FIRE_IN_COVER = 12, // Ped will only blind fire when in cover
--   CA_AGGRESSIVE = 13, // Ped may advance
--   CA_CAN_INVESTIGATE = 14, // Ped can investigate events such as distant gunfire, footsteps, explosions etc
--   CA_CAN_USE_RADIO = 15, // Ped can use a radio to call for backup (happens after a reaction)
--   CA_CAN_CAPTURE_ENEMY_PEDS = 16, // Deprecated
--   CA_ALWAYS_FLEE = 17, // Ped will always flee upon getting threat response task
--   CA_CAN_TAUNT_IN_VEHICLE = 20, // Ped can do unarmed taunts in vehicle
--   CA_CAN_CHASE_TARGET_ON_FOOT = 21, // Ped will be able to chase their targets if both are on foot and the target is running away
--   CA_WILL_DRAG_INJURED_PEDS_TO_SAFETY = 22, // Ped can drag injured peds to safety
--   CA_REQUIRES_LOS_TO_SHOOT = 23, // Ped will require LOS to the target it is aiming at before shooting
--   CA_USE_PROXIMITY_FIRING_RATE = 24, // Ped is allowed to use proximity based fire rate (increasing fire rate at closer distances)
--   CA_DISABLE_SECONDARY_TARGET = 25, // Normally peds can switch briefly to a secondary target in combat, setting this will prevent that
--   CA_DISABLE_ENTRY_REACTIONS = 26, // This will disable the flinching combat entry reactions for peds, instead only playing the turn and aim anims
--   CA_PERFECT_ACCURACY = 27, // Force ped to be 100% accurate in all situations (added by Jay Reinebold)
--   CA_CAN_USE_FRUSTRATED_ADVANCE	= 28, // If we don't have cover and can't see our target it's possible we will advance, even if the target is in cover
--   CA_MOVE_TO_LOCATION_BEFORE_COVER_SEARCH = 29, // This will have the ped move to defensive areas and within attack windows before performing the cover search
--   CA_CAN_SHOOT_WITHOUT_LOS = 30, // Allow shooting of our weapon even if we don't have LOS (this isn't X-ray vision as it only affects weapon firing)
--   CA_MAINTAIN_MIN_DISTANCE_TO_TARGET = 31, // Ped will try to maintain a min distance to the target, even if using defensive areas (currently only for cover finding + usage) 
--   CA_CAN_USE_PEEKING_VARIATIONS	= 34, // Allows ped to use steamed variations of peeking anims
--   CA_DISABLE_PINNED_DOWN = 35, // Disables pinned down behaviors
--   CA_DISABLE_PIN_DOWN_OTHERS = 36, // Disables pinning down others
--   CA_OPEN_COMBAT_WHEN_DEFENSIVE_AREA_IS_REACHED = 37, // When defensive area is reached the area is cleared and the ped is set to use defensive combat movement
--   CA_DISABLE_BULLET_REACTIONS = 38, // Disables bullet reactions
--   CA_CAN_BUST = 39, // Allows ped to bust the player
--   CA_IGNORED_BY_OTHER_PEDS_WHEN_WANTED = 40, // This ped is ignored by other peds when wanted
--   CA_CAN_COMMANDEER_VEHICLES = 41, // Ped is allowed to 'jack' vehicles when needing to chase a target in combat
--   CA_CAN_FLANK = 42, // Ped is allowed to flank
--   CA_SWITCH_TO_ADVANCE_IF_CANT_FIND_COVER = 43,	// Ped will switch to advance if they can't find cover
--   CA_SWITCH_TO_DEFENSIVE_IF_IN_COVER = 44, // Ped will switch to defensive if they are in cover
--   CA_CLEAR_PRIMARY_DEFENSIVE_AREA_WHEN_REACHED = 45, // Ped will clear their primary defensive area when it is reached
--   CA_CAN_FIGHT_ARMED_PEDS_WHEN_NOT_ARMED = 46, // Ped is allowed to fight armed peds when not armed
--   CA_ENABLE_TACTICAL_POINTS_WHEN_DEFENSIVE = 47, // Ped is not allowed to use tactical points if set to use defensive movement (will only use cover)
--   CA_DISABLE_COVER_ARC_ADJUSTMENTS = 48, // Ped cannot adjust cover arcs when testing cover safety (atm done on corner cover points when  ped usingdefensive area + no LOS)
--   CA_USE_ENEMY_ACCURACY_SCALING	= 49, // Ped may use reduced accuracy with large number of enemies attacking the same local player target
--   CA_CAN_CHARGE = 50, // Ped is allowed to charge the enemy position
--   CA_REMOVE_AREA_SET_WILL_ADVANCE_WHEN_DEFENSIVE_AREA_REACHED = 51, // When defensive area is reached the area is cleared and the ped is set to use will advance movement
--   CA_USE_VEHICLE_ATTACK = 52, // Use the vehicle attack mission during combat (only works on driver)
--   CA_USE_VEHICLE_ATTACK_IF_VEHICLE_HAS_MOUNTED_GUNS = 53, // Use the vehicle attack mission during combat if the vehicle has mounted guns (only works on driver)
--   CA_ALWAYS_EQUIP_BEST_WEAPON = 54, // Always equip best weapon in combat
--   CA_CAN_SEE_UNDERWATER_PEDS = 55, // Ignores in water at depth visibility check
--   CA_DISABLE_AIM_AT_AI_TARGETS_IN_HELIS = 56, // Will prevent this ped from aiming at any AI targets that are in helicopters
--   CA_DISABLE_SEEK_DUE_TO_LINE_OF_SIGHT = 57, // Disables peds seeking due to no clear line of sight
--   CA_DISABLE_FLEE_FROM_COMBAT = 58, // To be used when releasing missions peds if we don't want them fleeing from combat (mission peds already prevent flee)
--   CA_DISABLE_TARGET_CHANGES_DURING_VEHICLE_PURSUIT = 59, // Disables target changes during vehicle pursuit
--   CA_CAN_THROW_SMOKE_GRENADE = 60, // Ped may throw a smoke grenade at player loitering in combat
--   CA_CLEAR_AREA_SET_DEFENSIVE_IF_DEFENSIVE_CANNOT_BE_REACHED = 62, // Will clear a set defensive area if that area cannot be reached
--   CA_DISABLE_BLOCK_FROM_PURSUE_DURING_VEHICLE_CHASE = 64, // Disable block from pursue during vehicle chases
--   CA_DISABLE_SPIN_OUT_DURING_VEHICLE_CHASE = 65, // Disable spin out during vehicle chases
--   CA_DISABLE_CRUISE_IN_FRONT_DURING_BLOCK_DURING_VEHICLE_CHASE = 66, // Disable cruise in front during block during vehicle chases
--   CA_CAN_IGNORE_BLOCKED_LOS_WEIGHTING = 67, // Makes it more likely that the ped will continue targeting a target with blocked los for a few seconds
--   CA_DISABLE_REACT_TO_BUDDY_SHOT = 68, // Disables the react to buddy shot behaviour.
--   CA_PREFER_NAVMESH_DURING_VEHICLE_CHASE = 69, // Prefer pathing using navmesh over road nodes
--   CA_ALLOWED_TO_AVOID_OFFROAD_DURING_VEHICLE_CHASE = 70, // Ignore road edges when avoiding
--   CA_PERMIT_CHARGE_BEYOND_DEFENSIVE_AREA = 71, // Permits ped to charge a target outside the assigned defensive area.
--   CA_USE_ROCKETS_AGAINST_VEHICLES_ONLY = 72, // This ped will switch to an RPG if target is in a vehicle, otherwise will use alternate weapon.
--   CA_DISABLE_TACTICAL_POINTS_WITHOUT_CLEAR_LOS = 73, // Disables peds moving to a tactical point without clear los
--   CA_DISABLE_PULL_ALONGSIDE_DURING_VEHICLE_CHASE = 74, // Disables pull alongside during vehicle chase
--   CA_DISABLE_ALL_RANDOMS_FLEE = 78,	// If set on a ped, they will not flee when all random peds flee is set to TRUE (they are still able to flee due to other reasons)
--   CA_WILL_GENERATE_DEAD_PED_SEEN_SCRIPT_EVENTS = 79, // This ped will send out a script DeadPedSeenEvent when they see a dead ped
--   CA_USE_MAX_SENSE_RANGE_WHEN_RECEIVING_EVENTS = 80, // This will use the receiving peds sense range rather than the range supplied to the communicate event
--   CA_RESTRICT_IN_VEHICLE_AIMING_TO_CURRENT_SIDE = 81, // When aiming from a vehicle the ped will only aim at targets on his side of the vehicle
--   CA_USE_DEFAULT_BLOCKED_LOS_POSITION_AND_DIRECTION = 82, // LOS to the target is blocked we return to our default position and direction until we have LOS (no aiming)
--   CA_REQUIRES_LOS_TO_AIM = 83, // LOS to the target is blocked we return to our default position and direction until we have LOS (no aiming)
--   CA_CAN_CRUISE_AND_BLOCK_IN_VEHICLE = 84, // Allow vehicles spawned infront of target facing away to enter cruise and wait to block approaching target
--   CA_PREFER_AIR_COMBAT_WHEN_IN_AIRCRAFT = 85, // Peds flying aircraft will prefer to target other aircraft over entities on the ground
--   CA_ALLOW_DOG_FIGHTING = 86, //Allow peds flying aircraft to use dog fighting behaviours
--   CA_PREFER_NON_AIRCRAFT_TARGETS = 87, // This will make the weight of targets who aircraft vehicles be reduced greatly compared to targets on foot or in ground based vehicles
--   CA_PREFER_KNOWN_TARGETS_WHEN_COMBAT_CLOSEST_TARGET = 88, //When peds are tasked to go to combat, they keep searching for a known target for a while before forcing an unknown one
--   CA_FORCE_CHECK_ATTACK_ANGLE_FOR_MOUNTED_GUNS = 89, // Only allow mounted weapons to fire if within the correct attack angle (default 25-degree cone). On a flag in order to keep exiting behaviour and only fix in specific cases.
--   CA_BLOCK_FIRE_FOR_VEHICLE_PASSENGER_MOUNTED_GUNS = 90 // Blocks the firing state for passenger-controlled mounted weapons. Existing flags CA_USE_VEHICLE_ATTACK and CA_USE_VEHICLE_ATTACK_IF_VEHICLE_HAS_MOUNTED_GUNS only work for drivers.
-- };


-- -- SET_PED_FIRING_PATTERN
-- SetPedFiringPattern(
-- 	ped --[[ Ped ]], 
-- 	patternHash --[[ Hash ]]
-- )

-- FIRING_PATTERN_BURST_FIRE = 0xD6FF6D61 ( 1073727030 )  
-- FIRING_PATTERN_BURST_FIRE_IN_COVER = 0x026321F1 ( 40051185 )  
-- FIRING_PATTERN_BURST_FIRE_DRIVEBY = 0xD31265F2 ( -753768974 )  
-- FIRING_PATTERN_FROM_GROUND = 0x2264E5D6 ( 577037782 )  
-- FIRING_PATTERN_DELAY_FIRE_BY_ONE_SEC = 0x7A845691 ( 2055493265 )  
-- FIRING_PATTERN_FULL_AUTO = 0xC6EE6B4C ( -957453492 )  
-- FIRING_PATTERN_SINGLE_SHOT = 0x5D60E4E0 ( 1566631136 )  
-- FIRING_PATTERN_BURST_FIRE_PISTOL = 0xA018DB8A ( -1608983670 )  
-- FIRING_PATTERN_BURST_FIRE_SMG = 0xD10DADEE ( 1863348768 )  
-- FIRING_PATTERN_BURST_FIRE_RIFLE = 0x9C74B406 ( -1670073338 )  
-- FIRING_PATTERN_BURST_FIRE_MG = 0xB573C5B4 ( -1250703948 )  
-- FIRING_PATTERN_BURST_FIRE_PUMPSHOTGUN = 0x00BAC39B ( 12239771 )  
-- FIRING_PATTERN_BURST_FIRE_HELI = 0x914E786F ( -1857128337 )  
-- FIRING_PATTERN_BURST_FIRE_MICRO = 0x42EF03FD ( 1122960381 )  
-- FIRING_PATTERN_SHORT_BURSTS = 0x1A92D7DF ( 445831135 )  
-- FIRING_PATTERN_SLOW_FIRE_TANK = 0xE2CA3A71 ( -490063247 )  
-- if anyone is interested firing pattern info: pastebin.com/Px036isB  




-- -- _SET_WANTED_LEVEL_HIDDEN_EVASION_TIME
-- SetWantedLevelHiddenEvasionTime(
-- 	player --[[ Player ]],
-- 	wantedLevel --[[ integer ]],
-- 	lossTime --[[ integer ]]
-- )

-- ============================================================================
-- /fenix:diag - diagnostic dump of all key state variables
-- ============================================================================
RegisterCommand('fenix:diag', function()
    local groundCount = 0
    for _ in pairs(spawnedVehicles) do groundCount = groundCount + 1 end
    local heliCount = 0
    for _ in pairs(spawnedHeliUnits) do heliCount = heliCount + 1 end
    local airCount = 0
    for _ in pairs(spawnedAirUnits) do airCount = airCount + 1 end

    local wl = GetPlayerWantedLevel(PlayerId())
    local maxWl = GetMaxWantedLevel()

    print('====== FENIX DIAG ======')
    print(('  wantedLevel        = %d'):format(wl))
    print(('  maxWantedLevel     = %d'):format(maxWl))
    print(('  disableAIPolice    = %s'):format(tostring(disableAIPolice)))
    print(('  pendingGroundSpawns= %d'):format(pendingGroundSpawns))
    print(('  pendingHeliSpawns  = %d'):format(pendingHeliSpawns))
    print(('  pendingAirSpawns   = %d'):format(pendingAirSpawns))
    print(('  groundUnits        = %d'):format(groundCount))
    print(('  heliUnits          = %d'):format(heliCount))
    print(('  airUnits           = %d'):format(airCount))
    print(('  playerHasShot      = %s'):format(tostring(playerHasShot)))
    print(('  isSurrendering     = %s'):format(tostring(isSurrendering)))
    print(('  isBeingArrested    = %s'):format(tostring(isBeingArrested)))
    print(('  isPullingOver      = %s'):format(tostring(isPullingOver)))
    print(('  isBeingTicketed    = %s'):format(tostring(isBeingTicketed)))
    print(('  ticketWrapUp       = %s'):format(tostring(ticketWrapUp)))
    print(('  isPoliceOfficer    = %s'):format(tostring(isPlayerPoliceOfficer())))
    print(('  PoliceWantedProt   = %s'):format(tostring(Config.PoliceWantedProtection)))
    print(('  onlyWhenOffline    = %s'):format(tostring(Config.onlyWhenPlayerPoliceOffline)))
    print(('  scriptFrequency    = %d'):format(Config.scriptFrequency))
    print('========================')
end, false)


-- -- GIVE_WEAPON_TO_PED
-- GiveWeaponToPed(
-- 	ped --[[ Ped ]], 
-- 	weaponHash --[[ Hash ]], 
-- 	ammoCount --[[ integer ]], 
-- 	isHidden --[[ boolean ]], 
-- 	bForceInHand --[[ boolean ]]
-- )
