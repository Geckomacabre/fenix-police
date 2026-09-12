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

-- [Upstate Mafia] qbx_core declares `provide 'qb-core'` (see its
-- fxmanifest.lua), so the export above transparently resolves there -- but
-- the object it returns is a snapshot from THAT resource's current script
-- environment. Restarting qbx_core (for any reason -- it happened here while
-- iterating on an unrelated admin command) invalidates every reference this
-- resource is still holding, and every subsequent call into it throws
-- "Execution of function reference in script host failed" every single tick
-- forever, since nothing here ever re-fetches it. Live-fire confirmed: this
-- is what filled a client's log with that exact error on a loop until the
-- connection timed out and the game crashed. Re-fetch whenever the resource
-- providing qb-core (co-core itself is never actually running here, only
-- qbx_core is) restarts, so a future qbx_core restart heals instead of
-- wedging every tick until this resource is also manually restarted.
AddEventHandler('onClientResourceStart', function(resourceName)
    if resourceName == 'qb-core' or resourceName == 'qbx_core' then
        QBCore = exports['qb-core']:GetCoreObject()
        if Config.isDebug then
            print('[fenix-police] QBCore reference refreshed after ' .. resourceName .. ' restarted')
        end
    end
end)

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

-- [Upstate Mafia] The one K9 currently out, if any. Tracked here rather than
-- on its unit's vehicleData because a unit can drop out of spawnedVehicles
-- while its dog is still on the ground (last officer lost, foot chaser gave
-- up), and a dog tracked only there would be orphaned in the world. See the
-- K9 UNITS section further down.
--   { ped, vehNetID, handler, state = 'Attack'|'Return', returnUntil, returnTarget }
local activeK9 = nil
local k9CooldownUntil = 0

-- [Upstate Mafia] Response pacing (Config.Response): when the current wanted
-- episode began, and when the last ground unit was dispatched. Both cleared
-- the moment the wanted level drops back to zero.
local responseStartedAt = nil
local lastGroundDispatchAt = nil


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

-- Zone/region lookup now lives in client/jurisdiction.lua
-- (FenixJurisdiction.currentRegion()), which does what getPlayerZoneCode() +
-- getZoneKey() used to do inline here, plus crossing detection for
-- jurisdiction handoff. See spawnPoliceUnitNet below for the call site.




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
    -- [Upstate Mafia] Never inside the player's view on the first two passes
    -- (Config.Response.avoidVisibleSpawns) -- a cruiser popping into existence
    -- on screen is the "out of nowhere" moment. The last-resort pass below
    -- still allows it: a response that never arrives is worse.
    local avoidVisible = (Config.Response or {}).avoidVisibleSpawns ~= false

    local pos, heading = FenixRoads.findSpawnPoint(playerCoords, {
        minDistance  = minDistance,
        maxDistance  = maxDistance,
        behindVector = playerForward,
        towards      = playerCoords,
        avoidVisible = avoidVisible,
    })
    if pos then return pos, heading end

    -- Widening the band once covers the common near-miss: the player is on a
    -- long rural road where the only qualifying tarmac is just past maxDistance.
    pos, heading = FenixRoads.findSpawnPoint(playerCoords, {
        minDistance  = minDistance,
        maxDistance  = maxDistance * 1.75,
        behindVector = playerForward,
        towards      = playerCoords,
        avoidVisible = avoidVisible,
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
            -- Stop monitoring a unit that no longer exists, rather than
            -- re-probing it forever.
            --
            -- NetToVeh on a network ID whose entity is gone makes the engine
            -- log "Warning: [entity] GetNetworkObject: no object by ID N" on
            -- EVERY call. Once a police vehicle was destroyed this loop kept
            -- running for the rest of the pursuit, burning 1 + controlWaitCount
            -- (= 7) of those warnings every 5 seconds, per dead unit, forever.
            -- Three destroyed units produced ~280 warnings in a single session.
            -- NetworkDoesEntityExistWithNetworkId is the existence test that
            -- does NOT warn, so it is safe to ask first.
            if not NetworkDoesEntityExistWithNetworkId(vehNetID) then return end

            local vehicle = NetToVeh(vehNetID)

            -- I've found that one call isn't enough, and it can take multiple NetToVeh calls before it is not nil or == 0 regardless of the time that has passed since spawn.
            local waitCount = 0
            while (not vehicle or vehicle == 0) and waitCount < Config.controlWaitCount do
                Wait(Config.netWaitTime)
                -- It can also go away mid-retry -- bail instead of spending the
                -- rest of the budget warning about it.
                if not NetworkDoesEntityExistWithNetworkId(vehNetID) then return end
                vehicle = NetToVeh(vehNetID)
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

-- [Upstate Mafia, 2026-09-03] Retry cleanup for stolen police vehicles.
--
-- Nothing previously read stolenVehicles back out after the line above added
-- to it, so a vehicle stolen mid-chase stayed in the world forever, long
-- after the player was done with it -- the "known issue" the README used to
-- flag. This retries the same delete request once the vehicle is no longer
-- occupied. Self-correcting: if the server finds it occupied again, it just
-- re-fires deleteSpawnedVehicleResponseStolen above and the entry goes right
-- back into the table for the next pass.
local function checkStolenVehicles()
    for vehNetID in pairs(stolenVehicles) do
        if not NetworkDoesEntityExistWithNetworkId(vehNetID) then
            -- Already gone -- naturally despawned, or cleaned up some other way.
            stolenVehicles[vehNetID] = nil
        else
            local vehicle = NetworkGetEntityFromNetworkId(vehNetID)
            if not DoesEntityExist(vehicle) then
                stolenVehicles[vehNetID] = nil
            elseif GetPedInVehicleSeat(vehicle, -1) == 0 then
                -- Driver's seat empty -- the same "occupied" test the server
                -- used when it first refused to delete this. Safe to retry.
                if Config.isDebug then print('Retrying delete for abandoned stolen vehicle ID ' .. vehNetID) end
                TriggerServerEvent('deleteSpawnedVehicle', vehNetID)
                stolenVehicles[vehNetID] = nil
            end
            -- Still occupied: leave it in the table, try again next sweep.
        end
    end
end

CreateThread(function()
    while true do
        Wait((Config.stolenVehicleRecheckSeconds or 60) * 1000)
        checkStolenVehicles()
    end
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

        -- Nightsun on for the life of the pursuit. AI-controlled (2nd arg true)
        -- so the pilot points it at whatever the crew is currently tasked
        -- against on its own -- the live target while chasing, the search
        -- point while circling one (see handleHeliChaseBehavior below).
        if DoesVehicleHaveSearchlight(vehicle) then
            SetVehicleSearchlight(vehicle, true, true)
        end

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
    if Config.isDebug then
        print(('[FENIX-SPAWN] spawnPoliceUnitNet called, wantedLevel=%d'):format(wantedLevel))
    end
    local playerPed = PlayerPedId()
    local playerCoords = GetEntityCoords(playerPed)
    -- Region for spawnlist selection AND agency ownership -- see
    -- client/jurisdiction.lua. FenixJurisdiction.currentRegion() walks the
    -- exact same Config.zones -> Config.ZoneEnum chain getPlayerZoneCode/
    -- getZoneKey used to do inline here, but checks Config.Jurisdiction.zones
    -- first for servers that want a boundary finer than GTA's own named
    -- zones, and is what maintainPoliceUnits() watches for a crossing.
    local regionCode = FenixJurisdiction and FenixJurisdiction.currentRegion() or 'losSantos'
    if Config.isDebug then
        print(('[FENIX-SPAWN] region=%s'):format(tostring(regionCode)))
    end

    -- Get a safe spawn point. [Upstate Mafia] Config.Response.spawnDistance
    -- pushes low-level responses further out, so a 1-star unit is driving in
    -- from a few blocks away rather than materialising round the corner.
    local response = Config.Response or {}
    local band = response.enabled ~= false and (response.spawnDistance or {})[wantedLevel] or nil
    local minDistance = band and band[1] or Config.minPoliceSpawnDistance
    local maxDistance = band and band[2] or Config.maxPoliceSpawnDistance
    local spawnPoint, spawnHeading = getSafeSpawnPoint(playerCoords, minDistance, maxDistance, GetEntityForwardVector(playerPed))
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
    if Config.isDebug then
        print(('[FENIX-SPAWN] sending server event, spawnPoint=%.1f,%.1f,%.1f'):format(spawnPoint.x, spawnPoint.y, spawnPoint.z))
    end

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
        SetPedCombatMovement(officer, 2) -- Offensive
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
    -- Never called before this: officers took cover/positioning cues from
    -- whatever the engine's default happened to be, not from anything this
    -- resource set. See Config.Combat.combatMovement for the enum.
    SetPedCombatMovement(officer, levelValue(cfg.combatMovement, wantedLevel, 1))

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

    -- 43 = SwitchToAdvanceIfCantFindCover. Rockstar's own police AI sets this
    -- in the same block as the difficulty tiers §13 already anchors accuracy/
    -- shootRate/combatAbility to (fm_content_vehrob_police, func_303). Without
    -- it a Defensive officer with no reachable cover just stands there instead
    -- of doing anything -- this is what stops that.
    SetPedCombatAttributes(officer, 43, true)
    -- 42 = CanFlank. Only meaningful once actually fighting; a passive unit
    -- flanking the player it isn't shooting at would just look like it's
    -- creeping up on them.
    SetPedCombatAttributes(officer, 42, hostile)

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
    -- [Upstate Mafia] Stock cruiser instead of no unit at all if an add-on
    -- pack isn't loaded on this client -- see client/livery.lua.
    local modelName = FenixLivery.resolveModel(vehicleInfo.model, spawnPoint, vehicleInfo.fallback)
    local vehicleHash = GetHashKey(modelName)

    if not requestModelLoaded(vehicleHash) then
        print(('[FENIX-SPAWN] failed to load vehicle model %s'):format(tostring(modelName)))
        if pendingGroundSpawns > 0 then pendingGroundSpawns = pendingGroundSpawns - 1 end
        return
    end

    local vehicle = CreateVehicle(vehicleHash, spawnPoint.x, spawnPoint.y, spawnPoint.z, spawnHeading or 0.0, true, true)
    if not DoesEntityExist(vehicle) then
        print(('[FENIX-SPAWN] failed to create vehicle %s client-side'):format(tostring(modelName)))
        if pendingGroundSpawns > 0 then pendingGroundSpawns = pendingGroundSpawns - 1 end
        return
    end

    SetEntityAsMissionEntity(vehicle, true, true)
    SetVehicleDoorsLocked(vehicle, 1)
    SetVehicleOnGroundProperly(vehicle)
    SetVehicleSiren(vehicle, true)
    SetSirenKeepOn(vehicle, true)
    FenixLivery.apply(vehicle, vehicleInfo.livery, vehicleInfo.unmarked)

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
        if Config.isDebug then
            print(('[FENIX-SPAWN] deleting driverless client police vehicle %s'):format(tostring(modelName)))
        end
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


-- ============================================================================
-- AMBIENT -> PURSUIT PROMOTION (Upstate Mafia)
--
-- Called from client/ambient.lua when the player goes wanted near a patrol/
-- convoy scene it already spawned. Ambient scene entities are client-local
-- and non-networked (see ambient.lua's createPed/createVehicle) -- purely
-- decorative, not real pursuit units -- so the old behaviour, on any wanted
-- level, was to delete every one of them near the player and let the pursuit
-- system spawn brand new networked units to replace them. That reads as "the
-- cops patrolling around just vanished and were swapped for new ones",
-- because that is exactly what happened.
--
-- This networks the existing vehicle and officer(s) in place
-- (NetworkRegisterEntityAsNetworked) and folds them into spawnedVehicles as a
-- real pursuit unit instead, so it's the same car and the same cop that turns
-- and joins the chase. Registers through the same ticket handshake and
-- fenix-police:registerSpawnedUnit path a fresh spawn uses (see
-- server/server.lua's promoteAmbientUnit handler and server/guard.lua),
-- rather than skipping FenixGuard's ownership bookkeeping.
-- ============================================================================

-- Single-slot ticket handshake: ambient.lua only ever promotes one scene at a
-- time (see the promotion loop in ambient.lua's wanted-onset sweep), so there
-- is never a second PromoteAmbientUnit call in flight to race this against.
local promotionTicketResult = nil
local awaitingPromotionTicket = false

RegisterNetEvent('fenix-police:promoteAmbientUnitTicket')
AddEventHandler('fenix-police:promoteAmbientUnitTicket', function(ticket)
    if awaitingPromotionTicket then promotionTicketResult = ticket end
end)

--- Networks an entity that was created locally with isNetwork=false (every
--- ambient scene entity). Returns true once the transfer has actually landed.
local function networkizeEntity(entity)
    if not DoesEntityExist(entity) then return false end
    if not NetworkGetEntityIsNetworked(entity) then
        NetworkRegisterEntityAsNetworked(entity)
        local waited = 0
        while not NetworkGetEntityIsNetworked(entity) and waited < 500 do
            Wait(10)
            waited = waited + 10
        end
        if not NetworkGetEntityIsNetworked(entity) then return false end
    end
    SetEntityAsMissionEntity(entity, true, true)
    return true
end

--- Promotes an already-spawned ambient patrol/convoy scene into a real
--- pursuit unit. `vehicle` and `driverPed` are required; `passengerPeds` is an
--- optional list of any other officers riding along.
---@return boolean success -- false leaves the scene untouched; the caller
--- (ambient.lua) is expected to fall back to its normal despawn on failure.
function PromoteAmbientUnit(vehicle, driverPed, passengerPeds, loadoutName)
    if not DoesEntityExist(vehicle) or not DoesEntityExist(driverPed) then return false end
    if GetPedInVehicleSeat(vehicle, -1) ~= driverPed then return false end
    if not networkizeEntity(vehicle) or not networkizeEntity(driverPed) then return false end

    local vehNetID = VehToNet(vehicle)
    NetworkSetNetworkIdDynamic(vehNetID, false)
    SetNetworkIdCanMigrate(vehNetID, false)
    SetNetworkIdExistsOnAllMachines(vehNetID, true)

    local officers, officerPeds = {}, {}
    local driverNetID = PedToNet(driverPed)
    NetworkSetNetworkIdDynamic(driverNetID, false)
    SetNetworkIdCanMigrate(driverNetID, false)
    SetNetworkIdExistsOnAllMachines(driverNetID, true)
    officers[1] = driverNetID
    officerPeds[driverNetID] = driverPed

    for _, ped in ipairs(passengerPeds or {}) do
        if DoesEntityExist(ped) and networkizeEntity(ped) then
            local pedNetID = PedToNet(ped)
            NetworkSetNetworkIdDynamic(pedNetID, false)
            SetNetworkIdCanMigrate(pedNetID, false)
            SetNetworkIdExistsOnAllMachines(pedNetID, true)
            officers[#officers + 1] = pedNetID
            officerPeds[pedNetID] = ped
        end
    end

    promotionTicketResult = nil
    awaitingPromotionTicket = true
    TriggerServerEvent('fenix-police:server:promoteAmbientUnit')
    local waited = 0
    while promotionTicketResult == nil and waited < 5000 do
        Wait(10)
        waited = waited + 10
    end
    awaitingPromotionTicket = false
    local ticket = promotionTicketResult
    promotionTicketResult = nil
    if not ticket then return false end

    TriggerServerEvent('fenix-police:registerSpawnedUnit', ticket, vehNetID, officers)

    local playerPed = PlayerPedId()
    local playerCoords = GetEntityCoords(playerPed)
    local wantedLevel = GetPlayerWantedLevel(PlayerId())
    local engageFlags = {}
    loadoutName = loadoutName or 'patrol'

    spawnedVehicles[vehNetID] = {
        vehicle = vehicle,
        officers = {},
        officerTasks = {},
        officerEngage = engageFlags,
        clientOwned = true,
        loadout = loadoutName,
    }

    for i, pedNetID in ipairs(officers) do
        spawnedVehicles[vehNetID].officers[pedNetID] = officerPeds[pedNetID]
        spawnedVehicles[vehNetID].officerTasks[pedNetID] = i == 1 and 'VehicleChase' or 'Standby'
    end

    SetVehicleSiren(vehicle, true)
    SetSirenKeepOn(vehicle, true)

    -- Ambient officers were unarmed/pistol-only set dressing (Config.Ambient.
    -- weapon) at neutral relationship. Re-arm and re-profile them exactly like
    -- a freshly spawned unit's crew, same order the spawn handler above uses:
    -- loadout while still easy to reach, then the wanted-level combat profile.
    local driverEngages = rollEngage(wantedLevel)
    engageFlags[driverNetID] = driverEngages
    giveClientPedLoadout(driverPed, Config.loadouts[loadoutName])
    applyOfficerCombatProfile(driverPed, wantedLevel, driverEngages)
    ClearPedTasks(driverPed)
    TaskVehicleDriveToCoord(driverPed, vehicle, playerCoords.x, playerCoords.y, playerCoords.z, 42.0, 1, GetEntityModel(vehicle), 6, 2.0, true)
    SetDriveTaskDrivingStyle(driverPed, 6)
    SetDriverAbility(driverPed, 1.0)
    SetDriverAggressiveness(driverPed, 1.0)

    for i = 2, #officers do
        local pedNetID = officers[i]
        local officer = officerPeds[pedNetID]
        if DoesEntityExist(officer) then
            local engages = rollEngage(wantedLevel)
            engageFlags[pedNetID] = engages
            giveClientPedLoadout(officer, Config.loadouts[loadoutName])
            local hostile = applyOfficerCombatProfile(officer, wantedLevel, engages)
            if hostile then
                TaskCombatPed(officer, playerPed, 0, 16)
                spawnedVehicles[vehNetID].officerTasks[pedNetID] = 'CombatPed'
            end
        end
    end

    MonitorVehicle(vehNetID)
    return true
end


-- This handles the response from the server after a vehicle and officers are spawned, so they can be tasked and otherwise handled by the client.
RegisterNetEvent('spawnPoliceUnitNetResponse')
AddEventHandler('spawnPoliceUnitNetResponse', function(vehNetID, officers)
    if Config.isDebug then
        print(('[FENIX-SPAWN] got server response: vehNetID=%s officers=%s'):format(tostring(vehNetID), tostring(officers and #officers or 'nil')))
    end

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





--- Extra units on top of Config.maxUnitsPerLevel/maxHeliUnitsPerLevel, the
--- longer the player has been under contact (see FenixPursuit.pursuitElapsedMs
--- in client/pursuit.lua). This is what makes dispatch keep piling on units
--- against a suspect who's been spotted and is still running, instead of the
--- response flatlining at whatever the wanted level called for the moment it
--- was raised. See Config.Reinforcement.
local function reinforcementBonus(kind)
    local rc = Config.Reinforcement
    if not rc or rc.enabled == false then return 0 end
    if not FenixPursuit or not FenixPursuit.pursuitElapsedMs then return 0 end

    local elapsed = FenixPursuit.pursuitElapsedMs()
    if elapsed <= 0 then return 0 end

    if kind == 'heli' then
        local interval = rc.heliIntervalMs or 90000
        local per = rc.heliUnitsPerInterval or 1
        local cap = rc.maxBonusHeli or 1
        return math.min(cap, math.floor(elapsed / interval) * per)
    end

    local interval = rc.contactIntervalMs or 45000
    local per = rc.unitsPerInterval or 1
    local cap = rc.maxBonusUnits or 4
    return math.min(cap, math.floor(elapsed / interval) * per)
end

-- Highest ground reinforcement bonus already called in over the radio this
-- pursuit. Drops back to 0 the moment the bonus itself does (pursuit over, or
-- contact never made), so the next pursuit announces fresh from its own first
-- threshold instead of staying silent because "4" was already said once
-- tonight.
local lastAnnouncedReinforcement = 0

local function maybeAnnounceReinforcement(groundBonus)
    if groundBonus <= 0 then
        lastAnnouncedReinforcement = 0
        return
    end
    if groundBonus > lastAnnouncedReinforcement then
        lastAnnouncedReinforcement = groundBonus
        if FenixPursuit and FenixPursuit.announceReinforcement then
            FenixPursuit.announceReinforcement(groundBonus)
        end
    end
end

-- Function to maintain the desired number of police units
--- [Upstate Mafia] Whether dispatch has had time to "get there" yet for the
--- current wanted episode (Config.Response.initialDelay). Skipped outright
--- when the player opens fire, or when an officer already has eyes on them --
--- the delay stands for a unit driving in from elsewhere after a call-in, not
--- for police who watched it happen.
local function responseReady(wantedLevel)
    local r = Config.Response or {}
    if r.enabled == false then return true end

    local now = GetGameTimer()
    responseStartedAt = responseStartedAt or now

    if r.skipDelayWhenShooting ~= false and playerHasShot then return true end
    if r.skipDelayOnContact ~= false and FenixPursuit and FenixPursuit.hasContact() then return true end

    local delay = ((r.initialDelay or {})[wantedLevel] or 0) * 1000
    return (now - responseStartedAt) >= delay
end

--- [Upstate Mafia] Whether enough time has passed since the last ground unit
--- to send the next one (Config.Response.unitInterval) -- units arrive one by
--- one instead of the whole allowance appearing in the same second.
local function groundDispatchDue(wantedLevel)
    local r = Config.Response or {}
    if r.enabled == false or not lastGroundDispatchAt then return true end
    local interval = ((r.unitInterval or {})[wantedLevel] or 0) * 1000
    return (GetGameTimer() - lastGroundDispatchAt) >= interval
end

local function maintainPoliceUnits(wantedLevel)
    local playerPed = PlayerPedId()
    local playerVeh = GetVehiclePedIsIn(playerPed, false)
    local ready = responseReady(wantedLevel)

    -- Jurisdiction crossing check -- once per pass, same cadence this
    -- function already runs at. A non-nil return means units currently on
    -- scene belong to the region being LEFT; hand them to FenixMorale's
    -- retreat/regroup machinery exactly like a casualty-driven retreat, just
    -- with a different reason string for the debug command.
    if FenixJurisdiction then
        local fromRegion, toRegion = FenixJurisdiction.checkCrossing(wantedLevel > 0)
        if fromRegion and FenixMorale then
            for vehNetID, vehicleData in pairs(spawnedVehicles) do
                if not FenixMorale.isRetreating(vehNetID) then
                    local liveOfficers = {}
                    for pedNetID, _ in pairs(vehicleData.officers or {}) do
                        local ped = NetToPed(pedNetID)
                        if ped and ped ~= 0 and DoesEntityExist(ped) then
                            liveOfficers[#liveOfficers + 1] = { pedNetID = pedNetID, ped = ped,
                                health = GetEntityHealth(ped), maxHealth = GetEntityMaxHealth(ped) }
                        end
                    end
                    FenixMorale.beginRetreat(vehNetID, vehicleData, liveOfficers, 'jurisdiction')
                end
            end
        end
    end

    local groundBonus = reinforcementBonus('ground')
    maybeAnnounceReinforcement(groundBonus)

    local backupGroundBonus = FenixBackup and FenixBackup.bonusUnits('ground') or 0
    local backupHeliBonus = FenixBackup and FenixBackup.bonusUnits('heli') or 0
    if FenixBackup then FenixBackup.maybeAnnounce() end

    local maxUnits = (Config.maxUnitsPerLevel[wantedLevel] or 0) + groundBonus + backupGroundBonus
    local currentUnits = 0

    local maxHeliUnits = (Config.maxHeliUnitsPerLevel[wantedLevel] or 0) + reinforcementBonus('heli') + backupHeliBonus
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
        -- [Upstate Mafia] Gated on Config.Response: nothing until the initial
        -- delay has run, then one unit per unitInterval.
        while ready and currentUnits < maxUnits and pendingGroundSpawns < MAX_CONCURRENT_SPAWNS
            and groundDispatchDue(wantedLevel) do
            pendingGroundSpawns = pendingGroundSpawns + 1
            spawnPoliceUnitNet(wantedLevel)
            lastGroundDispatchAt = GetGameTimer()
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
        while ready and currentHeliUnits < maxHeliUnits and pendingHeliSpawns < MAX_CONCURRENT_SPAWNS do
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




-- Driving-style bitfields, named because "46" and "262571" appear in enough
-- places to be worth reading. Bit values confirmed against GTA's own
-- eDriveBehaviorFlags enum.
--   PURSUIT  4 (swerve around all cars) + 2 (stop for peds) + 8 (steer around
--            stationary cars) + 32 (steer around objects). No traffic-light
--            bit, so units run reds, and no wrong-way bit, so they stay on
--            their side -- but they now dodge parked cars and street
--            furniture instead of driving straight through them, which read
--            as careless rather than urgent. Was plain 6 (swerve + stop-for-
--            peds only) before this.
--   SEARCH   the normal-driving field: obey lights, keep to the road. A unit
--            sweeping for a suspect it cannot see is not running reds to do it.
local DRIVING_STYLE_PURSUIT = 46
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

        -- How tight this officer follows once TaskVehicleChase actually takes
        -- over (SET_TASK_VEHICLE_CHASE_IDEAL_PURSUIT_DISTANCE, applied once
        -- below where VehicleChase is first issued). Scaled by wanted level
        -- like ability/aggression -- a level-1 patrol car hangs back further
        -- than a level-5 unit that's decided to end this now.
        pursuitDistance = levelValue(c.pursuitDistance, wantedLevel, 10.0),
    }

    vehicleData.officerDriving[pedNetID] = profile
    return profile
end

--- Pick and task a new search-sweep waypoint for a unit that's lost contact.
---
--- Used to be one TaskVehicleDriveWander for the entire search -- a real
--- random wander with no memory of where it had already looked, which reads
--- as aimless rather than searching. This instead samples a point on a ring
--- around the search centre, resolves it against the real road network
--- (client/roads.lua's FenixRoads.roadInfoAt -- the lightweight read-only
--- primitive, no spawn validation overhead needed for a drive-through point),
--- rejects anywhere too close to this unit's own recent stops or to a point
--- another searching unit already claimed, and drives there.
---
--- Reuses FenixRoads' existing spawn-deconfliction reservation table
--- (isReserved/reserve) for the "another unit already claimed this" check --
--- the identical problem two units picking the same point in the same tick,
--- just for a search waypoint instead of a spawn point.
---
--- Returns true and tasks the drive on success. Returns false having tasked
--- nothing on failure -- the caller falls back to a plain wander for one
--- cycle rather than the unit stalling in place, "degrade rather than
--- disappear" the same way roadInfoAt's own fallback chain does.
local function pickSweepWaypoint(vehicleData, officer, polVehicle, center, radius, searchSpeed)
    local c = Config.Driving or {}
    local minSeparation = c.sweepMinSeparation or 25.0

    local minDist = math.max(10.0, radius * 0.3)
    local maxDist = math.max(minDist + 5.0, radius)

    local sweep = vehicleData.sweep or { history = {} }

    for _ = 1, (c.sweepSampleAttempts or 6) do
        local ang = math.rad(math.random(0, 359))
        local dist = minDist + (math.random() * (maxDist - minDist))
        local sample = vector3(center.x + (math.sin(ang) * dist), center.y + (math.cos(ang) * dist), center.z)

        local road = FenixRoads.roadInfoAt(sample)
        if road then
            local candidate = road.center

            local tooCloseToOwnHistory = false
            for _, prev in ipairs(sweep.history) do
                if #(candidate - prev) < minSeparation then
                    tooCloseToOwnHistory = true
                    break
                end
            end

            if not tooCloseToOwnHistory and not FenixRoads.isReserved(candidate, minSeparation) then
                FenixRoads.reserve(candidate)

                table.insert(sweep.history, candidate)
                while #sweep.history > (c.sweepHistorySize or 3) do
                    table.remove(sweep.history, 1)
                end
                sweep.target = candidate
                sweep.since = GetGameTimer()
                vehicleData.sweep = sweep

                TaskVehicleDriveToCoord(officer, polVehicle, candidate.x, candidate.y, candidate.z,
                    searchSpeed or c.searchSpeed or 16.0,
                    1, GetEntityModel(polVehicle), DRIVING_STYLE_SEARCH, c.sweepArriveDistance or 12.0, true)
                return true
            end
        end
    end

    return false
end

-- [Upstate Mafia] Forward declarations: the surrender and traffic-stop handlers
-- are defined ~1200 lines below, alongside the rest of the arrest system, but
-- have to be reachable from the chase loop here.
local handleSurrenderApproach
local handleTicketApproach
local handleFootChase
local recallK9
local deleteK9

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
    -- is what stops officers shooting a surrendering player -- and calls any
    -- K9 back to its car. A dog isn't in vehicleData.officers, so nothing in
    -- handleSurrenderApproach's own arrester search would otherwise ever touch
    -- it, and it would just keep biting a suspect who's already given up.
    if Config.ArrestSystem.enabled and (isSurrendering or isBeingArrested) then
        recallK9('surrender')
        if handleSurrenderApproach(vehicleData, playerPed, vehNetID) then return end
    end

    -- [Upstate Mafia] On foot, or gone somewhere a car can't follow: send one
    -- officer after the player on foot instead of the driver endlessly trying
    -- (and failing) to path a cruiser through a doorway. See handleFootChase
    -- for the exit/commit logic; it owns this unit's tick entirely once an
    -- officer has committed to the chase.
    if Config.FootChase and Config.FootChase.enabled then
        if handleFootChase(vehicleData, playerPed, vehNetID, GetPlayerWantedLevel(PlayerId())) then
            return
        end
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

    -- Morale / retreat check -- once per UNIT per cycle, not per officer. See
    -- client/morale.lua: a unit that has taken enough losses or is badly
    -- enough outnumbered disengages here, and once it has, this whole
    -- function leaves its officers alone (client/morale.lua's own thread owns
    -- their tasking) until they regroup and moraleRetreating goes false again.
    local moraleRetreating = false
    if FenixMorale then
        moraleRetreating = FenixMorale.isRetreating(vehNetID)
        if not moraleRetreating then
            local liveOfficers = {}
            for livePedNetID in pairs(vehicleData.officers) do
                local liveOfficer = NetToPed(livePedNetID)
                if liveOfficer and liveOfficer ~= 0 and DoesEntityExist(liveOfficer) then
                    liveOfficers[#liveOfficers + 1] = { pedNetID = livePedNetID, ped = liveOfficer,
                        health = GetEntityHealth(liveOfficer), maxHealth = GetEntityMaxHealth(liveOfficer) }
                end
            end

            if FenixBackup then FenixBackup.reportSuspectArmed(wantedLevel) end

            local shouldRetreat, reason = FenixMorale.assess(vehNetID, vehicleData, liveOfficers, wantedLevel)
            if shouldRetreat then
                FenixMorale.beginRetreat(vehNetID, vehicleData, liveOfficers, reason)
                moraleRetreating = true
            end
        end
    end

    for pedNetID, officerData in pairs(vehicleData.officers) do
        local officer = NetToPed(pedNetID)

        local waitCount = 0
        while (not officer or officer == 0) and waitCount < Config.controlWaitCount do
            officer = NetToPed(pedNetID)
            Wait(Config.netWaitTime)
            waitCount = waitCount + 1
        end

        -- Reporting still happens for a retreating unit's officers (a
        -- casualty score should keep reflecting reality), but tasking itself
        -- is left to client/morale.lua entirely -- re-issuing combat/chase
        -- tasks here would fight it for control of the same ped.
        if moraleRetreating then
            if officer and officer ~= 0 and DoesEntityExist(officer) then
                if IsPedDeadOrDying(officer, true) then
                    if FenixBackup then FenixBackup.reportOfficerDown(pedNetID) end
                elseif FenixBackup then
                    FenixBackup.reportOfficerHealth(pedNetID, GetEntityHealth(officer))
                end
            end
            goto continueGroundOfficer
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

            -- Feed this officer's condition into the event-driven backup
            -- score (client/backup.lua) before this cycle's tasking -- a
            -- death or a drop in health here is what lets FenixBackup.
            -- bonusUnits() call in real reinforcements, distinct from
            -- Config.Reinforcement's plain sustained-contact clock.
            if IsPedDeadOrDying(officer, true) then
                if FenixBackup then FenixBackup.reportOfficerDown(pedNetID) end
            elseif FenixBackup then
                FenixBackup.reportOfficerHealth(pedNetID, GetEntityHealth(officer))
            end

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
                            -- The initial drive-to-last-known is issued on
                            -- transition only, same as everywhere else in this
                            -- function. Once inside the sweep radius, though,
                            -- a single task can't just be issued once and left:
                            -- a sweep is a SERIES of stops, not one destination,
                            -- so pickSweepWaypoint is re-consulted whenever the
                            -- current waypoint has been reached or has gone
                            -- stale, not gated to a one-time transition.
                            local sweepRadius = math.max(25.0, FenixPursuit.searchRadius() * 0.5)
                            if #(GetEntityCoords(polVehicle) - target) < sweepRadius then
                                local sweep = vehicleData.sweep
                                local now = GetGameTimer()
                                local arriveDist = (Config.Driving and Config.Driving.sweepArriveDistance) or 12.0
                                local timeoutMs  = (Config.Driving and Config.Driving.sweepWaypointTimeoutMs) or 9000

                                local needsNewWaypoint = taskStatus ~= 'Sweep' or not sweep or not sweep.target
                                    or #(GetEntityCoords(polVehicle) - sweep.target) < arriveDist
                                    or (now - (sweep.since or 0)) > timeoutMs

                                if needsNewWaypoint then
                                    if not pickSweepWaypoint(vehicleData, officer, polVehicle, target,
                                            FenixPursuit.searchRadius(), profile.searchSpeed) then
                                        -- Nothing suitable turned up this attempt --
                                        -- fall back to a plain wander for one cycle
                                        -- rather than the unit stalling in place.
                                        ClearPedTasks(officer)
                                        TaskVehicleDriveWander(officer, polVehicle, profile.searchSpeed, DRIVING_STYLE_SEARCH)
                                        vehicleData.sweep = nil
                                    end
                                    spawnedVehicles[vehNetID].officerTasks[pedNetID] = 'Sweep'
                                end
                            elseif taskStatus ~= 'ToLastKnown' then
                                TaskVehicleDriveToCoord(officer, polVehicle, target.x, target.y, target.z, profile.speed, 1, GetEntityModel(polVehicle), DRIVING_STYLE_PURSUIT, 8.0, true)
                                spawnedVehicles[vehNetID].officerTasks[pedNetID] = 'ToLastKnown'
                                vehicleData.sweep = nil
                            end
                        elseif distance > 45.0 or not inContact then
                            -- [Upstate Mafia] Was re-issued every single cycle for every
                            -- officer beyond 45m, unconditionally -- each one a fresh
                            -- GET_VEHICLE_NODE-style road-pathfinding request. That's the
                            -- CNetworkRoadNodeWorldStateData Pool Full errors this server
                            -- has been logging all night, live-fire confirmed: a heavy
                            -- pursuit (10+ ground units) crashed a client outright with
                            -- "Recursive-recursive error: ... Pool Full, Size == 20" --
                            -- the engine's pool is a hard-capped 20 slots TOTAL, not per
                            -- officer. Re-pathing for a target that moved half a metre
                            -- since the last tick buys nothing; only actually re-request
                            -- once the target has moved far enough that the old path is
                            -- stale, same spacing logic the ambient system already uses
                            -- elsewhere in this resource for "did this move enough to
                            -- matter" checks.
                            local lastTarget = profile.lastDriveTarget
                            if taskStatus ~= 'DriveToCoord' or not lastTarget or #(target - lastTarget) > 15.0 then
                                TaskVehicleDriveToCoord(officer, polVehicle, target.x, target.y, target.z, profile.speed, 1, GetEntityModel(polVehicle), DRIVING_STYLE_PURSUIT, 2.0, true)
                                SetDriveTaskDrivingStyle(officer, DRIVING_STYLE_PURSUIT)
                                profile.lastDriveTarget = target
                                spawnedVehicles[vehNetID].officerTasks[pedNetID] = 'DriveToCoord'
                                if taskStatus == 'Sweep' then vehicleData.sweep = nil end
                            end
                        else
                            -- Gated on transition only, matching handleHeliChaseBehavior's
                            -- TaskHeliChase: the native tracks playerPed itself once issued,
                            -- so reissuing every cycle bought nothing but made the driving AI
                            -- reconsider its approach every second -- visible as a stutter
                            -- ground units had that the heli crews never did.
                            if taskStatus ~= 'VehicleChase' then
                                TaskVehicleChase(officer, playerPed)
                                SetTaskVehicleChaseBehaviorFlag(officer, 8, true)
                                SetTaskVehicleChaseIdealPursuitDistance(officer, profile.pursuitDistance)
                                spawnedVehicles[vehNetID].officerTasks[pedNetID] = 'VehicleChase'
                                if taskStatus == 'Sweep' then vehicleData.sweep = nil end
                            end
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
                    if FenixBackup then FenixBackup.clearOfficer(pedNetID) end
                    if not next(spawnedVehicles[vehNetID].officers) then
                        TriggerServerEvent('deleteSpawnedVehicle', vehNetID)
                        spawnedVehicles[vehNetID] = nil
                        if FenixMorale then FenixMorale.clearUnit(vehNetID) end
                    end
                end
            end
        end
        ::continueGroundOfficer::
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

            -- Feed the event-driven backup score -- see client/backup.lua. A
            -- heli/plane gunner going down or taking fire is just as real an
            -- incident as a ground officer's. (No FenixMorale retreat here:
            -- an aircraft disengaging mid-air is a different, riskier problem
            -- than a ground unit driving off, and isn't attempted by this pass.)
            if IsPedDeadOrDying(officer, true) then
                if FenixBackup then FenixBackup.reportOfficerDown(pedNetID) end
            elseif FenixBackup then
                FenixBackup.reportOfficerHealth(pedNetID, GetEntityHealth(officer))
            end

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
                    -- Pilot — chase while there's real contact; circle the last
                    -- known position while searching instead of flying straight
                    -- at the player's actual live position regardless of whether
                    -- anyone can currently see them. Ground units already read
                    -- FenixPursuit's contact model this way (client/pursuit.lua);
                    -- the heli used to be the one unit that stayed omniscient.
                    local taskStatus = spawnedHeliUnits[vehNetID].officerTasks[pedNetID]

                    if FenixPursuit.hasContact() then
                        if taskStatus ~= 'HeliChase' then
                            TaskHeliChase(officer, playerPed, 0, 0, 120)
                            spawnedHeliUnits[vehNetID].officerTasks[pedNetID] = 'HeliChase'
                        end
                    elseif vehicle and vehicle ~= 0 and DoesEntityExist(vehicle) then
                        local center = FenixPursuit.targetCoords(playerCoords)
                        -- Only re-issued when the search centre actually changes
                        -- (a fresh lost-contact point) -- lastKnown holds steady
                        -- for the whole search otherwise, same as the ground
                        -- units' sweep target.
                        local key = ('%.0f:%.0f'):format(center.x, center.y)
                        if taskStatus ~= 'HeliSearch' or spawnedHeliUnits[vehNetID].searchKey ~= key then
                            -- Mission type 9 = Circle. Orbits the point instead
                            -- of beelining to and landing on it, which reads as
                            -- "searching the area" rather than "already knows
                            -- exactly where you went".
                            TaskHeliMission(officer, vehicle, 0, 0, center.x, center.y, center.z,
                                9, 25.0, 15.0, -1.0, 60, 30, -1.0, 0)
                            spawnedHeliUnits[vehNetID].officerTasks[pedNetID] = 'HeliSearch'
                            spawnedHeliUnits[vehNetID].searchKey = key
                        end
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

            -- Feed the event-driven backup score -- see client/backup.lua.
            if IsPedDeadOrDying(officer, true) then
                if FenixBackup then FenixBackup.reportOfficerDown(pedNetID) end
            elseif FenixBackup then
                FenixBackup.reportOfficerHealth(pedNetID, GetEntityHealth(officer))
            end

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

local function handleEndWantedDelete(force)
    if aftermath.active then return end
    -- [Upstate Mafia] Don't let a stray/global cleanup (the watchdog below, or
    -- the server's cleanupAllPolice broadcast reacting to another player's
    -- wanted status) delete the officer that's mid-approach to arrest you.
    -- Without this, a brief wanted-level blip while you're surrendering wipes
    -- the responding unit before it ever reaches arrestDistance -- the cop
    -- "disappears" and isSurrendering never gets a wanted-level-cleared tick
    -- to release the control lock, so you're stuck. triggerArrest() passes
    -- force=true for its own end-of-cinematic cleanup, which must run even
    -- while isBeingArrested is still true.
    if not force and isSurrendering then return end

    -- [Upstate Mafia] Every officer is about to be wiped below regardless of
    -- which unit/task they belonged to, so any outstanding breach shield
    -- (client.lua's escalation section) goes with them in one pass here
    -- rather than relying on each unit's own foot-chase cleanup path to have
    -- caught its own -- ReleaseAllBreachShields is safe to call even when
    -- nothing is outstanding.
    ReleaseAllBreachShields()

    -- Everything below is about to be wiped regardless of per-unit state, so
    -- the event-driven backup score and any in-progress retreat/regroup
    -- bookkeeping go with it -- the next pursuit starts clean rather than
    -- inheriting a decaying score or a phantom "unit X is retreating" record
    -- for a unit that no longer exists.
    if FenixBackup then FenixBackup.reset() end
    if FenixMorale then FenixMorale.resetAll() end

    -- Collect keys BEFORE iterating so that nilling entries mid-loop (which Lua's
    -- pairs iterator can silently skip) doesn't leave orphan units behind.

    -- K9s are client-local (not networked, not server-owned), so the dog is
    -- the one entity in the whole sweep that's a plain DeleteEntity rather
    -- than deleteNetworkedEntity/deleteSpawnedPed -- see deleteK9 and
    -- Config.K9's header comment. Its car is about to be deleted below, so
    -- there's nothing left for it to run back to.
    deleteK9()

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

-- [Upstate Mafia] A `restart fenix-police` / crash / deploy mid-chase used to
-- leave every ground/heli/air unit this client had spawned wandering the map
-- forever: this file's Lua state (spawnedVehicles etc.) is wiped on stop, so
-- nothing was left to call handleEndWantedDelete(), and it guards on
-- aftermath.active which has no meaning once the resource is gone anyway.
-- Force the gate open and run the same cleanup one last time before the
-- tables holding the entity references disappear.
AddEventHandler('onClientResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    aftermath.active = false
    handleEndWantedDelete(true)
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

-- Shared by the BUSTED (triggerArrest, below) and WASTED (near the bottom of
-- this file) title cards. Draws the bare word in FONT_STYLE_PRICEDOWN (font
-- id 7 -- GTA's own logo/title font, confirmed against FiveM's font id list)
-- with no background band -- see triggerArrest's own comment for why a
-- scaleform (the only thing that could draw a real band) was dropped
-- entirely: MP_BIG_MESSAGE_FREEMODE's band is baked into its compiled
-- sprite and nothing in its exposed arguments can hide it, and the actual
-- reference for this look (a screenshot of vanilla GTA's own WASTED screen)
-- has no band at all.
local function drawBigWord(word, r, g, b)
    SetTextFont(7)
    SetTextScale(1.35, 1.35)
    SetTextColour(r, g, b, 255)
    SetTextCentre(true)
    SetTextDropShadow()
    SetTextEdge(2, 0, 0, 0, 160)
    SetTextEntry('STRING')
    AddTextComponentString(word)
    DrawText(0.5, 0.44)
end

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

        -- Hold the pose until arrested or cancelled (H again).
        --
        -- [Upstate Mafia] Used to also bail out here the instant
        -- GetPlayerWantedLevel() read 0 -- but the star decays on its own while
        -- you stand still surrendering, and that natural decay was cancelling
        -- the surrender out from under an officer who was already walking over
        -- to arrest you. Re-pin the level instead: you're still "wanted" until
        -- triggerArrest() actually clears it (or you cancel manually), same as
        -- how being pulled over already works.
        while isSurrendering and not isBeingArrested do
            if GetPlayerWantedLevel(PlayerId()) < 1 then
                SetPlayerWantedLevel(PlayerId(), 1, false)
                SetPlayerWantedLevelNow(PlayerId(), false)
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

    -- A foot chaser already out of the car also qualifies this unit, even if
    -- their now-parked cruiser is far behind them. handleFootChase can walk/
    -- run an officer well past approachDistance from the vehicle while
    -- chasing on foot (see Config.FootChase.giveUpDistance = 80.0), and the
    -- moment a player is most likely to surrender is exactly when that
    -- chaser has caught up to them -- not when their car happens to also be
    -- close. Without this, surrendering next to a chaser did nothing until
    -- the parked car itself drifted (or the player walked back) into range.
    if not isArrestingUnit then
        for pedNetID in pairs(vehicleData.officers) do
            local officer = NetToPed(pedNetID)
            if DoesEntityExist(officer) and officer ~= 0 and not IsPedDeadOrDying(officer, true)
                and not IsPedInAnyVehicle(officer, false)
                and #(playerCoords - GetEntityCoords(officer)) <= (Config.ArrestSystem.approachDistance or 35.0)
            then
                isArrestingUnit = true
                break
            end
        end
    end

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

        if Config.isDebug then
            print(('[FENIX-ARREST] arrester=%s dist=%.2f speed=%.2f')
                :format(tostring(arrester), arresterDist, GetEntitySpeed(officer)))
        end

        if arresterDist <= (Config.ArrestSystem.arrestDistance or 2.0) then
            triggerArrest(officer)
        end
    elseif Config.isDebug then
        print(('[FENIX-ARREST] unit=%s isArrestingUnit=%s no arrester yet'):format(tostring(vehNetID), tostring(isArrestingUnit)))
    end

    return isArrestingUnit
end

-- ============================================================================
-- FOOT CHASE (Upstate Mafia)
--
-- Until this existed, a unit's driver would just keep trying (and failing) to
-- path a cruiser at the player once they were on foot, and a player who ran
-- into any interior lost every unit outright -- a car cannot follow through a
-- doorway, and nothing here ever told an officer to get out and go in after
-- them on foot. This is what actually does that, plus an escalation ladder
-- for players who fight back and a stack-up beat before entering a building.
-- ============================================================================

-- ---- Escalation -------------------------------------------------------------
-- How much resistance the player has put up against a foot chase/breach
-- recently. Global, not per-unit — shooting the officer at your door should
-- make the next one more careful too, not just that one. Decays back to 0
-- after a stretch with no further resistance (see breachTier), so it reflects
-- "how hot is this right now" rather than a permanent record for the session.
local breachResistance = 0
local lastBreachResistanceAt = 0

--- Current escalation tier's tuning table (armor / loadout / a wanted level
--- floor for the NEXT unit spawned / whether a shield is warranted). Never
--- retroactively reskins an officer already in the field — "reinforcement"
--- means the next spawn favours the same wantedLevel-5 riot/SWAT pool
--- Config.vehiclesByRegion already defines, not a second one built here.
local function breachTier()
    local esc = Config.FootChase.escalation
    local tiers = esc and esc.tiers or {}
    local fallback = tiers[0] or { armor = 25, loadout = 'patrol' }
    if not esc or esc.enabled == false then return fallback end

    if breachResistance > 0 and GetGameTimer() - lastBreachResistanceAt > (esc.resistanceDecayMs or 90000) then
        breachResistance = 0
    end

    local level = breachResistance
    while level > 0 and not tiers[level] do level = level - 1 end
    return tiers[level] or fallback
end

--- Call whenever the player damages an officer who is actively foot-chasing/
--- breaching. Raises the tier and resets the decay clock.
local function registerBreachResistance()
    breachResistance = breachResistance + 1
    lastBreachResistanceAt = GetGameTimer()
    if Config.isDebug then
        print(('[FENIX-FOOTCHASE] resistance escalated to %d'):format(breachResistance))
    end
end

--- Folds the current breach tier into the wanted level used to pick WHICH
--- unit gets spawned next (maintainPoliceUnits' only caller, in the main
--- loop) — never lower than the player's real wanted level, only ever raised
--- by an active tier's forceWantedLevel. This is deliberately the ONLY hook:
--- it reuses spawnPoliceUnitNet's existing wantedLevel-tiered vehicle/ped
--- selection unchanged rather than growing a parallel spawn path.
function EffectiveSpawnWantedLevel(wantedLevel)
    local tier = breachTier()
    if tier.forceWantedLevel then
        return math.max(wantedLevel, tier.forceWantedLevel)
    end
    return wantedLevel
end

-- ---- Shields ------------------------------------------------------------
-- pedNetID -> object handle. Purely decorative — GTA has no vanilla "block
-- bullets with a held prop" mechanic for AI peds, so this is cover in
-- appearance only, not in effect. Created client-local/non-networked, the
-- same precedent client/ambient.lua sets for anything that's just dressing:
-- another client watching the same officer won't see it.
--
-- UNVERIFIED: the attach bone/offset/rotation below is a reasonable guess at
-- how Rockstar's own FIB/SWAT mission peds carry prop_riot_shield /
-- prop_ballistic_shield, not something checked against this build in game.
-- If it clips through the arm or floats, this is the block to retune.
local breachShields = {}

local function attachBreachShield(officer, pedNetID)
    if breachShields[pedNetID] then return end
    local model = GetHashKey(Config.FootChase.shieldObject or 'prop_riot_shield')
    RequestModel(model)
    local waited = 0
    while not HasModelLoaded(model) and waited < 200 do
        Wait(10)
        waited = waited + 10
    end
    if not HasModelLoaded(model) then return end

    local shield = CreateObject(model, 0.0, 0.0, 0.0, false, false, false)
    SetModelAsNoLongerNeeded(model)
    if not DoesEntityExist(shield) then return end

    local boneIndex = GetPedBoneIndex(officer, 0x49D9) -- SKEL_L_Hand
    AttachEntityToEntity(shield, officer, boneIndex, 0.0, 0.05, 0.0, 0.0, 0.0, 0.0, false, false, false, true, 0, true, 0)
    SetEntityCollision(shield, false, false)

    breachShields[pedNetID] = shield
end

local function releaseBreachShield(pedNetID)
    local shield = breachShields[pedNetID]
    if shield then
        if DoesEntityExist(shield) then DeleteEntity(shield) end
        breachShields[pedNetID] = nil
    end
end

--- Called from handleEndWantedDelete's own cleanup sweep (see the call added
--- there) — a wanted-clear wipes every officer regardless of which unit they
--- belonged to, so every outstanding shield goes with it in one pass rather
--- than relying on each unit's own cleanup path to have caught its own.
function ReleaseAllBreachShields()
    for pedNetID in pairs(breachShields) do releaseBreachShield(pedNetID) end
end

--- Re-gears a committing officer to the current tier: armor, loadout weapon,
--- and a shield prop if the tier calls for one. Run once, at the moment they
--- commit to the chase — not every cycle, so escalation reflects the tier at
--- the moment each officer went in, not a rubber-band that changes an
--- officer's loadout mid-chase because someone else drew fire five seconds
--- later.
local function outfitForBreach(officer, pedNetID)
    local tier = breachTier()
    SetPedArmour(officer, tier.armor or 25)
    if tier.loadout and Config.loadouts[tier.loadout] then
        giveClientPedLoadout(officer, Config.loadouts[tier.loadout])
    end
    if tier.shield then
        attachBreachShield(officer, pedNetID)
    else
        releaseBreachShield(pedNetID)
    end
end

-- ---- Stack-up staging -----------------------------------------------------
-- Only used for an interior entry (see handleFootChase below) — pausing
-- outside on open ground reads as an officer just standing there, not a
-- deliberate beat. No specific "stacking" animation clip is verified against
-- this build (see config.lua's own warning about clips that silently no-op
-- on TaskPlayAnim), so this uses TaskAimGunAtCoord — a documented native,
-- guaranteed to actually do something — to read as "covering the door"
-- instead.
local function advanceStaging(chaser, chaserPedNetID, tasks, vehicleData, playerCoords)
    local point = vehicleData.stagingPoint
    if not point then
        -- Shouldn't happen (set alongside the 'Staging' task below), but fall
        -- straight through to a normal chase rather than getting stuck.
        tasks[chaserPedNetID] = nil
        return
    end

    local atPoint = #(GetEntityCoords(chaser) - point) <= 2.0
    if not atPoint then
        if not vehicleData.stagingMoving then
            TaskGoToCoordAnyMeans(chaser, point.x, point.y, point.z, 2.0, 0, false, 786603, 0xbf800000)
            vehicleData.stagingMoving = true
        end
        return
    end

    if vehicleData.stagingMoving then
        -- Just arrived — face and "cover" the door for the rest of the beat.
        TaskAimGunAtCoord(chaser, point.x, point.y, point.z, -1, false, false)
        vehicleData.stagingMoving = false
    end

    if GetGameTimer() >= (vehicleData.stagingUntil or 0) then
        ClearPedTasks(chaser)
        tasks[chaserPedNetID] = nil -- falls through to a normal FootChase assignment below on this same tick
        vehicleData.stagingPoint = nil
        vehicleData.stagingUntil = nil
    end
end

--- One officer per unit commits to a foot chase (matches handleSurrenderApproach's
--- "exactly one, not the whole crew" reasoning above -- emptying every seat the
--- moment the player steps out of a car would gut the rest of the pursuit).
--- Whoever is closest gets out; everyone else stays seated, so the car is
--- still a threat if the player gets back in and drives off.
---@return boolean handled — true if this unit's tick was fully handled here
function handleFootChase(vehicleData, playerPed, vehNetID, wantedLevel)
    local vehicle = NetToVeh(vehNetID)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return false end

    local tasks = vehicleData.officerTasks
    if not tasks then return false end

    local cfg = Config.FootChase

    -- Already have a chaser committed for this unit?
    local chaser, chaserPedNetID = nil, nil
    for pedNetID, task in pairs(tasks) do
        if task == 'Exiting' or task == 'FootChase' or task == 'FootCombat' or task == 'Staging' then
            local officer = NetToPed(pedNetID)
            if DoesEntityExist(officer) and not IsPedDeadOrDying(officer, true) then
                chaser, chaserPedNetID = officer, pedNetID
            else
                tasks[pedNetID] = nil -- chaser died/despawned, free the slot up
                releaseBreachShield(pedNetID)
            end
            break
        end
    end

    local playerCoords = GetEntityCoords(playerPed)

    if not chaser then
        -- Nothing committed yet — decide whether this unit should send one.
        if IsPedInAnyVehicle(playerPed, false) then return false end

        local vehicleCoords = GetEntityCoords(vehicle)
        local dist = #(playerCoords - vehicleCoords)
        local inInterior = GetInteriorFromEntity(playerPed) ~= 0

        -- A car can't follow through a doorway at all, so an interior gets a
        -- more generous radius than "close enough to bother getting out on
        -- open ground" — the whole point of chasing a suspect who just ran
        -- inside is that the alternative is losing them outright.
        local triggerRange = inInterior and (cfg.interiorExitDistance or 40.0) or (cfg.exitDistance or 20.0)
        if dist > triggerRange then return false end

        -- Whoever can actually reach the player fastest, not always the
        -- driver — reads as "the nearest cop gets out", not "the driver
        -- always does".
        local best, bestDist, bestNetID = nil, 9999.0, nil
        for pedNetID in pairs(vehicleData.officers) do
            local officer = NetToPed(pedNetID)
            if DoesEntityExist(officer) and not IsPedDeadOrDying(officer, true) and IsPedInAnyVehicle(officer, false) then
                local d = #(GetEntityCoords(officer) - playerCoords)
                if d < bestDist then best, bestDist, bestNetID = officer, d, pedNetID end
            end
        end
        if not best then return false end

        -- First officer this unit has ever sent after the player on foot.
        -- Only set once; a second exit later this same pursuit (previous
        -- chaser lost/died) doesn't restart the clock.
        vehicleData.footChaseStartedAt = vehicleData.footChaseStartedAt or GetGameTimer()

        if not NetworkHasControlOfEntity(best) then NetworkRequestControlOfEntity(best) end
        TaskLeaveVehicle(best, vehicle, 0)
        outfitForBreach(best, bestNetID)

        -- Interior entries get the stack-up beat; open ground goes straight
        -- to the chase. Either way this is just "left the vehicle, nothing
        -- assigned yet" -- 'FootChase' is NOT set here even for the open-
        -- ground case, because the actual TaskGoToEntity below only fires
        -- when tasks[chaserPedNetID] ~= 'FootChase'. Marking it 'FootChase'
        -- immediately used to make that check pass on the very first tick
        -- the officer was ever seen as "already chasing", so the chase task
        -- was never actually issued and the officer just stood next to the
        -- car once TaskLeaveVehicle finished.
        if inInterior and cfg.staging and cfg.staging.enabled ~= false then
            tasks[bestNetID] = 'Staging'
            vehicleData.stagingPoint = playerCoords
            vehicleData.stagingUntil = GetGameTimer() + (cfg.staging.durationMs or 2500)
            vehicleData.stagingMoving = false
            vehicleData.stagedForInterior = GetInteriorFromEntity(playerPed)
        else
            tasks[bestNetID] = 'Exiting'
        end
        return true
    end

    -- Chaser committed. Bail out of the whole pursuit for this officer if
    -- they've fallen hopelessly behind (player got back in a car and drove
    -- off) — chasing a vehicle on foot forever just leaves a straggling ped.
    local dist = #(GetEntityCoords(chaser) - playerCoords)
    if dist > (cfg.giveUpDistance or 80.0) then
        ClearPedTasks(chaser)
        releaseBreachShield(chaserPedNetID)
        TriggerServerEvent('deleteSpawnedPed', chaserPedNetID)
        vehicleData.officers[chaserPedNetID] = nil
        tasks[chaserPedNetID] = nil
        if not next(vehicleData.officers) then
            TriggerServerEvent('deleteSpawnedVehicle', vehNetID)
            spawnedVehicles[vehNetID] = nil
        end
        return true
    end

    if IsPedInAnyVehicle(chaser, false) then
        -- Still finishing the TaskLeaveVehicle animation.
        return true
    end

    if not NetworkHasControlOfEntity(chaser) then NetworkRequestControlOfEntity(chaser) end

    -- Resistance check, before anything else touches this officer's task this
    -- cycle — being shot mid-stage should still count even though staging can
    -- return early below, before checkOfficerProvocation's own damage check
    -- further down would otherwise get a turn. Self-contained on purpose: it
    -- clears the damage flag and calls provokePolice() itself rather than
    -- relying on checkOfficerProvocation to run afterward, since a staging
    -- early-return means it might not this cycle. Left unconsumed, the flag
    -- would still read true next tick and double-count the same hit.
    if HasEntityBeenDamagedByEntity(chaser, playerPed, true) then
        registerBreachResistance()
        provokePolice()
        ClearEntityLastDamageEntity(chaser)
    end

    -- [Upstate Mafia] Reactive staging: the initial commit above only stages
    -- when the player is ALREADY inside the instant an officer gets out --
    -- the far more common case is they're still outside at that moment (mid
    -- chase across open ground) and only duck into a building afterward.
    -- Without this, that chaser would just walk straight in with no stack-up
    -- beat at all, which reads exactly like "no cinematic happened".
    -- stagedForInterior guards against re-triggering every tick once already
    -- staged for THIS interior (or once the officer has actually caught up
    -- and is inside it too).
    if cfg.staging and cfg.staging.enabled ~= false
        and tasks[chaserPedNetID] ~= 'Staging'
        and GetInteriorFromEntity(playerPed) ~= 0
        and GetInteriorFromEntity(playerPed) ~= vehicleData.stagedForInterior
        and GetInteriorFromEntity(chaser) ~= GetInteriorFromEntity(playerPed)
    then
        tasks[chaserPedNetID] = 'Staging'
        vehicleData.stagingPoint = playerCoords
        vehicleData.stagingUntil = GetGameTimer() + (cfg.staging.durationMs or 2500)
        vehicleData.stagingMoving = false
        vehicleData.stagedForInterior = GetInteriorFromEntity(playerPed)
    end

    if tasks[chaserPedNetID] == 'Staging' then
        advanceStaging(chaser, chaserPedNetID, tasks, vehicleData, playerCoords)
        if tasks[chaserPedNetID] == 'Staging' then return true end
        -- Staging just ended (advanceStaging cleared the task) — fall through
        -- to the normal chase assignment below on this same tick instead of
        -- waiting a full cycle to notice.
    end

    checkOfficerProvocation(chaser, playerPed)
    vehicleData.officerEngage = vehicleData.officerEngage or {}
    if vehicleData.officerEngage[chaserPedNetID] == nil then
        vehicleData.officerEngage[chaserPedNetID] = rollEngage(wantedLevel)
    end
    local hostile = applyOfficerCombatProfile(chaser, wantedLevel, vehicleData.officerEngage[chaserPedNetID])

    if hostile and dist <= (cfg.combatRange or 20.0) and FenixPursuit.hasContact() then
        if tasks[chaserPedNetID] ~= 'FootCombat' then
            TaskCombatPed(chaser, playerPed, 0, 16)
            tasks[chaserPedNetID] = 'FootCombat'
        end
    else
        -- TaskGoToEntity tracks the live entity on its own once issued, same
        -- as TaskVehicleChase above — only (re-)issued on an actual state
        -- change, not every cycle.
        if tasks[chaserPedNetID] ~= 'FootChase' then
            TaskGoToEntity(chaser, playerPed, -1, 1.0, 3.0, 1073741824, 0)
            tasks[chaserPedNetID] = 'FootChase'
        end
    end

    return true
end

-- ============================================================================
-- K9 UNITS (Upstate Mafia)
--
-- A dog closes distance a jogging officer never can -- the answer to "the
-- player can just keep outrunning a foot chase forever", which
-- Config.FootChase.giveUpDistance otherwise has no real counter to.
--
-- A dog is never conjured out of thin air behind the player. It has to come
-- out of a real ground unit that is (a) close to the player, (b) stopped or
-- nearly so, and (c) still has a living officer with it -- the handler, in
-- the car or on foot beside it. The dog gets out at that car's tailgate. When
-- it's called off (surrender, the player back in a car, the chase dragging it
-- too far from its car, its handler and car both gone) it runs back to the
-- car -- or to the handler if the car is gone -- and is loaded up (deleted)
-- on arrival rather than just vanishing mid-street.
--
-- The dog itself needs no bespoke bite/arrest logic: TASK_COMBAT_PED on an
-- animal ped is already GTA's own K9 attack, and a suspect it brings down
-- falls straight into the existing Aftermath system.
--
-- Client-local/non-networked, the same precedent client/tactics.lua's
-- roadblock and spike-strip peds already set for AI helpers that don't need
-- to survive this client disconnecting.
-- ============================================================================

--- Deletes the dog (if any) outright and starts the redeploy cooldown. Used
--- when it has reached its car, died, or its unit is being swept away
--- entirely. Safe to call with no dog out.
function deleteK9()
    if not activeK9 then return end
    -- No network control dance needed -- the dog was created local-only
    -- (CreatePed's isNetwork=false), so this client always owns it outright.
    if activeK9.ped and DoesEntityExist(activeK9.ped) then
        DeleteEntity(activeK9.ped)
    end
    activeK9 = nil
    k9CooldownUntil = GetGameTimer() + (Config.K9.cooldownMs or 60000)
end

--- Calls the dog off: it stops attacking and heads back to its car/handler,
--- where the watcher thread below loads it up. Safe to call with no dog out,
--- or with one already on its way back.
function recallK9(reason)
    local k9 = activeK9
    if not k9 or k9.state == 'Return' then return end

    local dog = k9.ped
    if not DoesEntityExist(dog) or IsPedDeadOrDying(dog, true) then
        deleteK9()
        return
    end

    k9.state = 'Return'
    k9.returnUntil = GetGameTimer() + (Config.K9.returnTimeoutMs or 20000)
    k9.returnTarget = nil -- forces the go-to task to be issued next tick

    ClearPedTasks(dog)
    -- Stops the dog reacting to the (still hated, still nearby) player on the
    -- way back -- same blocking the medic's approach uses to stay on task.
    SetBlockingOfNonTemporaryEvents(dog, true)

    if Config.isDebug then print('[FENIX-K9] recalled: ' .. tostring(reason)) end
end

--- The unit's car if it still exists and isn't wrecked, otherwise the handler
--- if they're still alive, otherwise nil -- where a recalled dog runs to.
local function k9Home(k9)
    if k9.vehNetID and NetworkDoesNetworkIdExist(k9.vehNetID) then
        local vehicle = NetToVeh(k9.vehNetID)
        if vehicle and vehicle ~= 0 and DoesEntityExist(vehicle) and not IsEntityDead(vehicle) then
            return vehicle
        end
    end
    if k9.handler and DoesEntityExist(k9.handler) and not IsPedDeadOrDying(k9.handler, true) then
        return k9.handler
    end
    return nil
end

--- A living officer of this unit close enough to the car to be the dog's
--- handler -- still seated, or on foot within Config.K9.handlerRange.
local function findK9Handler(vehicleData, vehicle)
    local range = Config.K9.handlerRange or 20.0
    local vehCoords = GetEntityCoords(vehicle)
    for pedNetID in pairs(vehicleData.officers or {}) do
        local officer = NetToPed(pedNetID)
        if officer and officer ~= 0 and DoesEntityExist(officer) and not IsPedDeadOrDying(officer, true)
            and #(GetEntityCoords(officer) - vehCoords) <= range then
            return officer
        end
    end
    return nil
end

--- Config.K9.vehicleModels, if set, restricts which cars carry a dog at all.
local function carriesK9(vehicle)
    local models = Config.K9.vehicleModels
    if not models or #models == 0 then return true end
    local model = GetEntityModel(vehicle)
    for _, name in ipairs(models) do
        if GetHashKey(name) == model then return true end
    end
    return false
end

--- Closest ground unit that can put a dog on the ground right now, or nil.
local function findK9Unit(playerCoords)
    local kc = Config.K9
    local best, bestDist = nil, (kc.deployRange or 60.0)
    for vehNetID, vehicleData in pairs(spawnedVehicles) do
        local vehicle = NetToVeh(vehNetID)
        if vehicle and vehicle ~= 0 and DoesEntityExist(vehicle) and not IsEntityDead(vehicle)
            and GetEntitySpeed(vehicle) <= (kc.maxDeploySpeed or 3.0)
            and carriesK9(vehicle)
        then
            local d = #(GetEntityCoords(vehicle) - playerCoords)
            if d <= bestDist then
                local handler = findK9Handler(vehicleData, vehicle)
                if handler then
                    best, bestDist = { vehNetID = vehNetID, vehicle = vehicle, handler = handler }, d
                end
            end
        end
    end
    return best
end

--- Pops the tailgate (door 5) for a few seconds, if this car has one, so
--- the dog visibly comes out of / goes back into the car.
local function popK9Door(vehicle)
    if not GetIsDoorValid(vehicle, 5) then return end
    SetVehicleDoorOpen(vehicle, 5, false, false)
    SetTimeout(3000, function()
        if DoesEntityExist(vehicle) then SetVehicleDoorShut(vehicle, 5, false) end
    end)
end

--- Creates the dog at the unit's tailgate and sets it on the player.
local function deployK9(unit, playerPed)
    local kc = Config.K9
    local hash = GetHashKey(kc.dogModel or 'a_c_shepherd')
    if not requestModelLoaded(hash) then return end
    -- The model load can take a few frames; the car may have gone meanwhile.
    if not DoesEntityExist(unit.vehicle) then
        SetModelAsNoLongerNeeded(hash)
        return
    end

    -- Just past the rear bumper, from the car's own model dimensions rather
    -- than a fixed offset, so a long SUV and a short sedan both work.
    local minDim = GetModelDimensions(GetEntityModel(unit.vehicle))
    local p = GetOffsetFromEntityInWorldCoords(unit.vehicle, 0.0, minDim.y - 0.6, 0.0)
    local okGround, groundZ = GetGroundZFor_3dCoord(p.x, p.y, p.z + 2.0, false)
    local z = (okGround and math.abs(groundZ - p.z) < 3.0) and groundZ or p.z

    local playerCoords = GetEntityCoords(playerPed)
    local heading = GetHeadingFromVector_2d(playerCoords.x - p.x, playerCoords.y - p.y)

    -- false, false: local only, no network object -- see this section's
    -- header comment on why a K9 is client-local.
    local dog = CreatePed(4, hash, p.x, p.y, z, heading, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not DoesEntityExist(dog) then return end

    SetEntityAsMissionEntity(dog, true, true)
    SetEntityMaxHealth(dog, kc.health or 200)
    SetEntityHealth(dog, kc.health or 200)
    SetPedFleeAttributes(dog, 0, false)
    SetPedCombatAttributes(dog, 46, true) -- AlwaysFight
    SetPedRelationshipGroupHash(dog, GetHashKey('HATES_PLAYER'))
    popK9Door(unit.vehicle)
    TaskCombatPed(dog, playerPed, 0, 16)

    activeK9 = { ped = dog, vehNetID = unit.vehNetID, handler = unit.handler, state = 'Attack' }

    if Config.isDebug then print('[FENIX-K9] deployed from unit ' .. tostring(unit.vehNetID)) end
    if FenixPursuit and FenixPursuit.announceK9 then FenixPursuit.announceK9() end
end

--- One tick of a recalled dog heading home. Loads it up on arrival; if home
--- is gone or it can't get there in time, removes it once it's off screen
--- (or unconditionally a while later) rather than leaving a stray dog.
local function tickK9Return(k9)
    local dog = k9.ped
    local now = GetGameTimer()
    local home = k9Home(k9)

    if not home then
        if not IsEntityOnScreen(dog) or now > k9.returnUntil then deleteK9() end
        return
    end

    local arriveDist = IsEntityAVehicle(home) and 4.0 or 2.5
    if #(GetEntityCoords(dog) - GetEntityCoords(home)) <= arriveDist then
        if IsEntityAVehicle(home) then popK9Door(home) end
        deleteK9()
        return
    end

    if now > k9.returnUntil and (not IsEntityOnScreen(dog) or now > k9.returnUntil + 15000) then
        deleteK9()
        return
    end

    if k9.returnTarget ~= home then
        TaskGoToEntity(dog, home, -1, 2.0, 3.0, 1073741824, 0)
        k9.returnTarget = home
    end
end

--- Drives the single dog's whole lifecycle: deploys one from a qualifying
--- unit, recalls it when it should stand down or has strayed too far from
--- home, and walks it back. Runs independently of handleChaseBehavior's
--- per-unit loop so a unit dropping out of spawnedVehicles can't orphan it.
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(500)

        local kc = Config.K9
        if not (kc and kc.enabled) then
            if activeK9 then deleteK9() end
            goto continue
        end

        local playerPed = PlayerPedId()
        local playerCoords = GetEntityCoords(playerPed)
        local wantedLevel = GetPlayerWantedLevel(PlayerId())
        local standDown = wantedLevel < 1
            or IsPedInAnyVehicle(playerPed, false)
            or isSurrendering or isBeingArrested
            or isPullingOver or isBeingTicketed or ticketWrapUp
            or disableAIPolice

        if activeK9 then
            local k9 = activeK9
            local dog = k9.ped
            if not DoesEntityExist(dog) or IsPedDeadOrDying(dog, true) then
                deleteK9()
            elseif k9.state == 'Attack' then
                local home = k9Home(k9)
                if standDown then
                    recallK9('suspect stood down or got in a vehicle')
                elseif not home then
                    recallK9('car and handler both gone')
                elseif #(GetEntityCoords(dog) - playerCoords) > (kc.giveUpDistance or 60.0) then
                    recallK9('suspect outran the dog')
                elseif #(GetEntityCoords(dog) - GetEntityCoords(home)) > (kc.leashDistance or 90.0) then
                    recallK9('too far from its car')
                end
            else
                tickK9Return(k9)
            end
        elseif not standDown
            and wantedLevel >= (kc.minWantedLevel or 2)
            and GetGameTimer() >= k9CooldownUntil
            and not isPlayerPoliceOfficer()
        then
            local unit = findK9Unit(playerCoords)
            if unit then deployK9(unit, playerPed) end
        end

        ::continue::
    end
end)

-- ============================================================================
-- /fenixk9test - TEMPORARY: force-spawns a K9 next to the player to check the
-- model/behaviour without setting up a real foot chase. Delete this block
-- (and the RegisterCommand below) once confirmed working -- it bypasses
-- Config.K9.minWantedLevel and every other gate deployK9 normally goes
-- through, so it has no place in a real pursuit.
-- ============================================================================
local testK9Ped = nil
RegisterCommand('fenixk9test', function()
    if testK9Ped and DoesEntityExist(testK9Ped) then
        DeleteEntity(testK9Ped)
        testK9Ped = nil
        print('[FENIX-K9-TEST] removed')
        return
    end

    local kc = Config.K9 or {}
    local hash = GetHashKey(kc.dogModel or 'a_c_shepherd')
    if not requestModelLoaded(hash) then
        print('[FENIX-K9-TEST] model failed to load: ' .. tostring(kc.dogModel))
        return
    end

    local playerPed = PlayerPedId()
    local coords = GetEntityCoords(playerPed)
    local heading = GetEntityHeading(playerPed)
    local rad = math.rad(heading)
    local fx, fy = -math.sin(rad), math.cos(rad)
    local x, y = coords.x - (fx * 4.0), coords.y - (fy * 4.0)

    local dog = CreatePed(4, hash, x, y, coords.z, heading, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not DoesEntityExist(dog) then
        print('[FENIX-K9-TEST] CreatePed failed')
        return
    end

    SetEntityAsMissionEntity(dog, true, true)
    SetEntityMaxHealth(dog, kc.health or 200)
    SetEntityHealth(dog, kc.health or 200)
    SetPedFleeAttributes(dog, 0, false)
    SetPedCombatAttributes(dog, 46, true) -- AlwaysFight
    SetPedRelationshipGroupHash(dog, GetHashKey('HATES_PLAYER'))
    TaskCombatPed(dog, playerPed, 0, 16)

    testK9Ped = dog
    print('[FENIX-K9-TEST] spawned -- run /fenixk9test again to remove it')
end, false)

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

        -- ---- ESCORT TO VEHICLE ----
        --
        -- Used to go straight from the kneel to the BUSTED fade -- no cuffing,
        -- no car, just a jump cut to waking up at the station. This is the one
        -- place in the whole flow that puts anyone in the back of a car: stand
        -- the player up cuffed (SetEnableHandcuffs -- the game's own cuffed
        -- walk/idle anim, not a hand-authored one), have nearby officers
        -- converge for a beat, walk to the nearest responding vehicle and
        -- TaskEnterVehicle into whichever rear seat is actually free.
        --
        -- Deliberately NOT a scripted drive to the station afterwards -- the
        -- BUSTED fade already reads as "the ride happens off-screen", and a
        -- real drive on every single arrest would turn a payoff into a chore.
        if Config.ArrestSystem.escortToVehicle ~= false then
            local escortOfficers = {}
            if DoesEntityExist(arrestingCop) and not IsPedDeadOrDying(arrestingCop, true) then
                table.insert(escortOfficers, arrestingCop)
            end

            local wantCount = Config.ArrestSystem.escortOfficerCount or 2
            for _, vehicleData in pairs(spawnedVehicles) do
                if #escortOfficers >= wantCount then break end
                for pedNetID in pairs(vehicleData.officers or {}) do
                    if #escortOfficers >= wantCount then break end
                    local ped = NetToPed(pedNetID)
                    if ped and ped ~= 0 and DoesEntityExist(ped) and ped ~= arrestingCop
                        and not IsPedDeadOrDying(ped, true)
                        and #(GetEntityCoords(ped) - arrestCoords) < 20.0 then
                        table.insert(escortOfficers, ped)
                    end
                end
            end

            -- Nearest vehicle belonging to any responding unit -- same
            -- spawnedVehicles registry every other loop in this file reads,
            -- not a new search.
            local escortVehicle, escortVehicleDist
            for vehNetID in pairs(spawnedVehicles) do
                local veh = NetToVeh(vehNetID)
                if veh and veh ~= 0 and DoesEntityExist(veh) then
                    local d = #(GetEntityCoords(veh) - arrestCoords)
                    if not escortVehicleDist or d < escortVehicleDist then
                        escortVehicle, escortVehicleDist = veh, d
                    end
                end
            end

            if escortVehicle and escortVehicleDist
                and escortVehicleDist <= (Config.ArrestSystem.escortMaxVehicleDistance or 40.0) then
                ClearPedTasks(playerPed)
                FreezeEntityPosition(playerPed, false)
                SetEnableHandcuffs(playerPed, true)

                -- Officers converge and stand around the player -- the
                -- "surrounded" beat -- before anyone starts walking.
                local officerCount = math.max(1, #escortOfficers)
                for i, cop in ipairs(escortOfficers) do
                    if DoesEntityExist(cop) and not IsPedDeadOrDying(cop, true) then
                        local ang = math.rad((i - 1) * (360.0 / officerCount))
                        local px = arrestCoords.x + (math.sin(ang) * 2.2)
                        local py = arrestCoords.y + (math.cos(ang) * 2.2)
                        TaskGoStraightToCoord(cop, px, py, arrestCoords.z, 1.0, -1, 0.0, 0.0)
                    end
                end
                Wait(1500)
                for _, cop in ipairs(escortOfficers) do
                    if DoesEntityExist(cop) and not IsPedDeadOrDying(cop, true) then
                        TaskTurnPedToFaceEntity(cop, playerPed, 1000)
                    end
                end
                Wait(500)

                -- Walk to the car, one officer following a step behind.
                local vc = GetEntityCoords(escortVehicle)
                local vHeading = GetEntityHeading(escortVehicle)
                TaskGoStraightToCoord(playerPed, vc.x, vc.y, vc.z,
                    Config.ArrestSystem.escortWalkSpeed or 1.0, -1, vHeading, 1.0)

                local escort = escortOfficers[1]
                if escort and DoesEntityExist(escort) then
                    TaskGoToEntity(escort, playerPed, -1, 1.5, 1.0, 1073741824, 0)
                end

                -- Time budget rather than polling distance forever -- a
                -- blocked path (traffic, a wall) shouldn't hold the whole
                -- cinematic hostage.
                local walkDeadline = GetGameTimer() + (Config.ArrestSystem.escortWalkTimeoutMs or 6000)
                while GetGameTimer() < walkDeadline
                    and #(GetEntityCoords(playerPed) - vc) > 3.0 do
                    Wait(100)
                end

                -- Into whichever rear seat is actually free.
                local seat = IsVehicleSeatFree(escortVehicle, 2) and 2
                    or (IsVehicleSeatFree(escortVehicle, 1) and 1) or 2
                SetVehicleDoorsLocked(escortVehicle, 1) -- unlocked, so the enter task can open it
                TaskEnterVehicle(playerPed, escortVehicle, 5000, seat, 1.0, 1, 0)

                local enterDeadline = GetGameTimer() + 5000
                while GetGameTimer() < enterDeadline and not IsPedInVehicle(playerPed, escortVehicle, false) do
                    Wait(100)
                end

                SetEnableHandcuffs(playerPed, false)
                UncuffPed(playerPed)
                FreezeEntityPosition(playerPed, true)

                -- The BUSTED cinematic below revolves its camera around
                -- arrestCoords -- re-centre it on wherever the player actually
                -- ended up (in the car) rather than the empty pavement they
                -- were kneeling on a few seconds ago.
                arrestCoords = GetEntityCoords(playerPed)
            end
        end

        -- ---- BUSTED CINEMATIC ----

        local duration = math.min(Config.ArrestSystem.bustedDuration or 6000,
                                  (Config.ArrestSystem.bustedMaxDuration or 30000))
        local skippable = Config.ArrestSystem.bustedSkippable ~= false

        -- 1. The BUSTED word itself.
        --
        -- [Fix history] This went through several scaleform-based attempts --
        -- SHOW_SHARD_WASTED_MP_MESSAGE (wrong method entirely, decompiles to
        -- the small MP kill-feed toast), then the movie's real
        -- SHOW_BUSTED_MP_MESSAGE (right method, but its band is baked into
        -- the compiled sprite -- see _tools/gtav_scaleforms_decompiled,
        -- MP_BIG_MESSAGE_FREEMODE.as -- and nothing in its exposed arguments
        -- can hide it). The actual reference look (a screenshot of vanilla
        -- GTA's own WASTED screen) has no band at all -- just the bare word.
        -- Since that band can't be removed from the scaleform, this drops
        -- the scaleform entirely and draws the word as plain native text:
        -- FONT_STYLE_PRICEDOWN (font id 7 -- GTA's own logo/title font,
        -- confirmed against FiveM's font id list) is the actual font this
        -- screen uses, so there's no styling compromise from going this
        -- route -- if anything it's a closer match than the scaleform ever
        -- was, and it sidesteps the scaleform-pool reliability issues this
        -- screen hit entirely (see server.cfg's ScaleformStore pool-size
        -- increase for that whole saga).
        local function drawBigWord(word, r, g, b)
            SetTextFont(7)
            SetTextScale(1.35, 1.35)
            SetTextColour(r, g, b, 255)
            SetTextCentre(true)
            SetTextDropShadow()
            SetTextEdge(2, 0, 0, 0, 160)
            SetTextEntry('STRING')
            AddTextComponentString(word)
            DrawText(0.5, 0.44)
        end

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

        -- 4. Draw loop — render the BUSTED word, red wash, and camera.
        --
        -- [Upstate Mafia patch] Timed off GetNetworkTime(), NOT GetGameTimer().
        -- SetTimeScale(0.15) above slows game time to 15%, and GetGameTimer
        -- advances with it — so a 6000ms window took ~40 SECONDS of real time,
        -- and the cinematic appeared to hang. GetNetworkTime is real time and is
        -- unaffected by the local time scale.
        local t0      = GetNetworkTime()
        local skipped = false

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

            -- DeathFailOut (started below) is a fixed built-in postFX with no
            -- colour parameter -- there's no native way to make IT red. Drawn
            -- ourselves instead: a translucent red wash under the word, so
            -- the whole screen reads red-hued, matching the reference.
            DrawRect(0.5, 0.5, 1.0, 1.0, 160, 20, 20, 70)

            drawBigWord('busted', 70, 140, 230)

            DisableAllControlActions(0)
            Wait(0)
        end

        -- 5. Restore time before fade (so fade isn't in slow-mo)
        SetTimeScale(1.0)
        StopScreenEffect('DeathFailOut')

        -- 6. Fade to black
        DoScreenFadeOut(1500)
        while not IsScreenFadedOut() do Wait(50) end

        -- 7. Cleanup camera
        SetCamActive(cam, false)
        RenderScriptCams(false, false, 0, true, true)
        DestroyCam(cam, false)

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
        handleEndWantedDelete(true)

        Wait(2000)

        -- 10. Fade back in at the station
        DoScreenFadeIn(2000)
        while not IsScreenFadedIn() do Wait(50) end

        isBeingArrested = false
    end)
end


-------------------------------------------------
-- WASTED SCREEN (qbx_medical)                 --
-------------------------------------------------
-- [Added, 2026-09-09] Fires on qbx_medical's own confirmed-death signal --
-- 'qbx_medical:client:onPlayerDied', a LOCAL client event
-- qbx_medical/client/dead.lua's OnDeath() fires only once a death is truly
-- final, never on a revivable last-stand knockdown (checked its source: the
-- gameEventTriggered handler only calls OnDeath on the SECOND fatal hit,
-- after EndLastStand()). This is exactly the reliable "confirmed dead, not
-- just downed" signal wasabi_ambulance's escrow made impossible to get --
-- see server.cfg's own comments for why wasabi_ambulance was replaced with
-- qbx_medical + qbx_ambulancejob at all.
--
-- Deliberately does NOT freeze position, disable controls, or teleport --
-- qbx_medical already owns all of that itself (OnDeath disables controls
-- and plays a dead animation for as long as DeathState stays DEAD, and
-- CheckForRespawn handles the actual hold-to-respawn flow). This only adds
-- the camera pull-back + red wash + WASTED word on top, then gets out of
-- the way. qbx_medical has no screen fade of its own (checked
-- client/dead.lua) -- this fades back in itself at the end rather than
-- leaving the screen black through qbx_medical's own respawn flow.
local WASTED_DURATION = 4000

local function runWasted()
    local playerPed   = PlayerPedId()
    local deathCoords = GetEntityCoords(playerPed)

    StartScreenEffect('DeathFailOut', 0, false)
    PlaySoundFrontend(-1, 'ScreenFlash', 'MissionFailedSounds', true)
    SetTimeScale(0.15)

    local heading = GetEntityHeading(playerPed)
    local rad = math.rad(heading + 160.0)
    local startDist, endDist = 2.0, 6.0
    local startZ,   endZ    = 0.8, 3.0

    local cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    local startPos = deathCoords + vector3(math.sin(rad) * startDist, math.cos(rad) * startDist, startZ)
    SetCamCoord(cam, startPos.x, startPos.y, startPos.z)
    PointCamAtCoord(cam, deathCoords.x, deathCoords.y, deathCoords.z + 0.4)
    SetCamActive(cam, true)
    RenderScriptCams(true, true, 800, true, true)

    -- GetNetworkTime, not GetGameTimer -- SetTimeScale(0.15) above would
    -- stretch a GetGameTimer-based window by ~6.5x, same reasoning as
    -- the BUSTED cinematic's own draw loop.
    local t0 = GetNetworkTime()
    while (GetNetworkTime() - t0) < WASTED_DURATION do
        local progress = (GetNetworkTime() - t0) / WASTED_DURATION
        local ease = 1.0 - (1.0 - progress) * (1.0 - progress)

        local curDist = startDist + (endDist - startDist) * ease
        local curZ    = startZ   + (endZ   - startZ)   * ease
        local curRad  = rad + math.rad(15.0 * ease)
        local camPos  = deathCoords + vector3(math.sin(curRad) * curDist, math.cos(curRad) * curDist, curZ)

        SetCamCoord(cam, camPos.x, camPos.y, camPos.z)
        PointCamAtCoord(cam, deathCoords.x, deathCoords.y, deathCoords.z + 0.3)

        DrawRect(0.5, 0.5, 1.0, 1.0, 160, 20, 20, 70)
        drawBigWord('wasted', 220, 40, 40)

        Wait(0)
    end

    SetTimeScale(1.0)
    StopScreenEffect('DeathFailOut')

    DoScreenFadeOut(1000)
    while not IsScreenFadedOut() do Wait(50) end

    -- [Re-added, 2026-09-09] qbx_medical waits for this before resurrecting/
    -- posing the player, so that snap happens with the screen already
    -- black instead of before/during the cinematic. (This was added once
    -- before and reverted when it appeared to break death handling --
    -- the actual cause was an unrelated bug in qbx_medical's own file, since
    -- fixed, not this event.)
    TriggerEvent('fenix-police:client:wastedScreenFadedOut')

    SetCamActive(cam, false)
    RenderScriptCams(false, false, 0, true, true)
    DestroyCam(cam, false)

    DoScreenFadeIn(1000)
    while not IsScreenFadedIn() do Wait(50) end
end

local function triggerWasted()
    Citizen.CreateThread(function()
        -- pcall wraps the actual cinematic body (runWasted), not just this
        -- CreateThread call -- CreateThread returns immediately, before the
        -- thread body ever runs, so a pcall around triggerWasted() itself
        -- (as the qbx_medical:client:onPlayerDied handler below used to do)
        -- can never catch an error that happens later inside the thread.
        local ok, err = pcall(runWasted)
        if not ok then
            print(('[fenix-police] WASTED cinematic errored: %s'):format(tostring(err)))
        end
    end)
end

-- Unconditional print (not gated behind Config.isDebug) -- fires at most
-- once per death, kept to nail down whether the qbx_medical event itself
-- fires at all vs. something inside the cinematic silently failing (first
-- live report, 2026-09-09: no WASTED screen, nothing to tell the two apart
-- after the fact). The cinematic's own error reporting lives in
-- triggerWasted itself, above.
AddEventHandler('qbx_medical:client:onPlayerDied', function()
    print('[fenix-police] qbx_medical:client:onPlayerDied received -- starting WASTED')
    triggerWasted()
end)


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
    -- [Upstate Mafia] Live-tested against this server's actual EMS
    -- (wasabi_ambulance): neither native check above nor the metadata fallback
    -- below ever trips during its last-stand -- confirmed both IsEntityDead/
    -- IsPedFatallyInjured false AND wasabi never calls SetMetaData for isdead/
    -- inlaststand anywhere in its own source. Aftermath silently never
    -- triggered as a result. wasabi_ambulance/game/client/client.lua now mirrors
    -- its own (otherwise unreadable -- the real death handling is escrowed)
    -- isDead global onto this state bag; check it first since it is the one
    -- signal actually proven to reflect this server's EMS state.
    if LocalPlayer.state.wsbDeadOrLastStand == true then return true end
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
            -- [Fix, 2026-09-09] wasabi_ambulance's own client-side
            -- 'wasabi_ambulance:revive' event doesn't exist under
            -- qbx_medical -- Revive there is a SERVER export
            -- (exports.qbx_medical:Revive(src)), not something the client
            -- can trigger on itself. Routed through server/server.lua's own
            -- fieldRevive handler instead.
            TriggerServerEvent('fenix-police:server:fieldRevive')
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

    -- [Upstate Mafia] Real police call it in the moment they find someone
    -- down, they don't wait to see if their own first aid works. This used to
    -- rely on ps-dispatch's own automatic CEventNetworkEntityDamage alert --
    -- but that only fires on a genuine engine-level death, and wasabi_ambulance
    -- (this server's EMS) deliberately keeps the ped alive during last-stand
    -- so it CAN be revived. That alert never fired, so EMS was never actually
    -- called and a failed field revive just left the player bleeding out with
    -- nobody coming. Call it directly instead of assuming another resource's
    -- side effect covers it.
    if GetResourceState('ps-dispatch') == 'started' then
        local ok, err = pcall(function() exports['ps-dispatch']:InjuriedPerson() end)
        if not ok and Config.isDebug then
            print('[fenix-police] ps-dispatch InjuriedPerson call failed: ' .. tostring(err))
        end
    end

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

    -- A K9 mid-attack has the same problem heli/air gunners do below: the
    -- native AI target is still alive (last-stand isn't IsEntityDead), so it
    -- would keep biting straight through a field-revive attempt. Sent back to
    -- its car rather than just stood down -- there's no "guard the downed
    -- suspect" pose for a dog the way there is for an officer.
    recallK9('aftermath')

    -- [Upstate Mafia] Heli/plane gunners never get physically parked (nobody
    -- lands a helicopter for this), and the per-tick handleHeliChaseBehavior /
    -- handleAirChaseBehavior calls are skipped outright while the player is
    -- incapacitated (see the main loop) -- but a TaskCombatPed issued before
    -- the player went down keeps running regardless: the native AI target is
    -- still alive (last-stand is a framework/metadata state, not
    -- IsEntityDead), so an airborne gunner mid-attack kept strafing right
    -- through a field-revive attempt. standDownOfficer() only touches
    -- relationship group and combat attributes -- no ClearPedTasks -- so it is
    -- safe to call on a ped still mid-flight-task.
    for _, vehicleData in pairs(spawnedHeliUnits) do
        for pedNetID in pairs(vehicleData.officers or {}) do
            local ped = NetToPed(pedNetID)
            if ped and ped ~= 0 and DoesEntityExist(ped) then
                standDownOfficer(ped)
                held = held + 1
            end
        end
    end
    for _, vehicleData in pairs(spawnedAirUnits) do
        for pedNetID in pairs(vehicleData.officers or {}) do
            local ped = NetToPed(pedNetID)
            if ped and ped ~= 0 and DoesEntityExist(ped) then
                standDownOfficer(ped)
                held = held + 1
            end
        end
    end

    if Config.isDebug then
        print(('[fenix-police] aftermath started: 1 medic, %d unit(s) holding'):format(held))
    end
end


-- Compile-time hash instead of a runtime GetHashKey('policet') call every
-- cycle of the main thread below.
local POLICET_MODEL_HASH = `policet`

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
        SetVehicleModelIsSuppressed(POLICET_MODEL_HASH, true)

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

        -- [Upstate Mafia] Keep running the chase/arrest loop through a surrender
        -- or an in-progress arrest even if the star has already decayed to 0.
        -- Without this, natural wanted-level decay while you stand still with
        -- your hands up stops handleChaseBehavior from ever being called again,
        -- which means handleSurrenderApproach's arrestDistance check stops
        -- running too -- the officer can be standing right next to you and the
        -- BUSTED cinematic still never triggers.
        if wantedLevel > 0 or isSurrendering or isBeingArrested then
            -- Diagnostic left over from tracing the SetMaxWantedLevel bug above.
            -- This branch runs on every loop cycle for as long as the player is
            -- wanted, so unguarded it floods the client console during any
            -- pursuit (222 lines in one session log). Gated behind Config.isDebug
            -- like the rest of the resource's tracing.
            if Config.isDebug then
                print(('[FENIX-LOOP] wanted=%d disableAI=%s pendingGround=%d'):format(wantedLevel, tostring(disableAIPolice), pendingGroundSpawns))
            end
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
                -- the window a stop still needs a unit sent to work it. Surrender/
                -- arrest follows the same rule -- don't let unit-count reconciliation
                -- touch the responding unit while it's mid-approach or mid-cinematic.
                if not (isBeingTicketed or ticketWrapUp or isSurrendering or isBeingArrested) then
                    -- [Upstate Mafia] EffectiveSpawnWantedLevel folds in the
                    -- current breach-resistance tier, so a player who's been
                    -- fighting a foot chase gets heavier reinforcements sent
                    -- next, on top of whatever their actual star count calls
                    -- for. See client/client.lua's escalation section.
                    maintainPoliceUnits(EffectiveSpawnWantedLevel(wantedLevel)) -- Checks if we need to spawn more units, or remove excess units.
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
            -- [Fix, 2026-09-09] isBeingArrested had no equivalent safety net
            -- -- if an arrest cinematic (triggerArrest, ~line 3642) never
            -- reached its normal completion at ~line 3818 (resource
            -- restart, disconnect, or any other interruption mid-arrest),
            -- this flag stayed stuck true for the rest of the session,
            -- silently skipping handleFootChase (and normal combat
            -- response) in handleChaseBehavior for every future pursuit --
            -- reads exactly like "cops just stand next to their car" with
            -- no error anywhere. Reset here alongside isSurrendering, which
            -- already gets this same treatment.
            isBeingArrested = false

            -- [Upstate Mafia] Next wanted episode starts its response delay
            -- from scratch (Config.Response).
            responseStartedAt = nil
            lastGroundDispatchAt = nil

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
