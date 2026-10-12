-- Police investigation response: drive to scene -> look around -> clear.
--
-- The counterpart to client/ems.lua and client/fire.lua for incidents that
-- need police but have no known suspect (a civilian-witnessed gunfire
-- report, typically -- see server/investigate.lua). A single officer parks
-- near the reported location and runs CODE_HUMAN_POLICE_INVESTIGATE for a
-- while, then clears. No combat, no chase, no arrest -- those all assume a
-- target this unit doesn't have.
--
-- LIMITATION, stated plainly: this never finds anything. There's no suspect
-- entity or evidence object for it to discover -- it's a believable-looking
-- presence on scene, not a real investigation outcome. A real "sometimes
-- finds a clue / spots a fleeing suspect" mechanic needs an actual
-- witness/suspect entity model, which doesn't exist in this resource yet
-- (see server/incident.lua's `witnesses`/`suspects` fields, currently just
-- player-source-id lists with nothing built to read them further).
--
-- Entirely opt-in: no-ops unless Config.Investigate.enabled is true.

local function cfg()
    return Config.Investigate or {}
end

local function dbg(...)
    if cfg().debug then
        print('[fenix-police:investigate]', ...)
    end
end

local function loadModel(hash)
    if HasModelLoaded(hash) then return true end
    RequestModel(hash)
    local waited = 0
    while not HasModelLoaded(hash) and waited < 500 do
        Wait(10)
        waited = waited + 10
    end
    return HasModelLoaded(hash)
end

local units = {} -- vehNetID -> { vehicle, peds, pedSeats, fsm, incidentId }
local pendingRequests = {} -- requestId -> { data = incidentData, at = GetGameTimer() }
local nextRequestId = 1

local UNIT_STATES = { 'DRIVING_TO_SCENE', 'INVESTIGATING', 'CLEARING' }

local OFFICER_SCENARIO = 'CODE_HUMAN_POLICE_INVESTIGATE'

-- GetScriptTaskStatus reports TaskVehicleDriveToCoordLongrange under this
-- hash; 7 means the task has finished (or isn't running at all).
local DRIVE_TASK = GetHashKey('SCRIPT_TASK_VEHICLE_DRIVE_TO_COORD_LONGRANGE')
local TASK_FINISHED = 7

-- A long-range drive ends at the nearest road node, which for a call placed
-- off-road, indoors or up on a roof can be well short of the coordinates
-- themselves -- without this the unit sits there forever, never "arriving".
-- Within this distance a finished drive counts as arrived.
local ROAD_END_ARRIVE_DISTANCE = 60.0

-- How long the officer gets to climb back aboard before the car leaves anyway.
local BOARD_TIMEOUT_MS = 15000

-- A departing unit is deleted once it's out of sight this far from the
-- player, or after DEPART_DELETE_MS regardless.
local DEPART_DELETE_DISTANCE = 150.0
local DEPART_DELETE_MS = 60000

-- The server drops a refused spawn request without replying, so a request
-- only holds a maxUnits slot for this long.
local PENDING_REQUEST_TTL_MS = 10000

local function unitCount()
    local n = 0
    for _ in pairs(units) do n = n + 1 end
    return n
end

-- What counts against maxUnits: units still working a call (one already
-- driving off doesn't), plus spawn requests and patrol promotions still
-- waiting on the server -- without those, two calls a moment apart would
-- both get past the cap.
local function busyCount()
    local n = 0
    for _, unit in pairs(units) do
        if not unit.departing then n = n + 1 end
    end
    local now = GetGameTimer()
    for requestId, request in pairs(pendingRequests) do
        if now - request.at > PENDING_REQUEST_TTL_MS then
            pendingRequests[requestId] = nil
        else
            n = n + 1
        end
    end
    return n
end

local function driveTo(driver, vehicle, coords)
    TaskVehicleDriveToCoordLongrange(driver, vehicle, coords.x, coords.y, coords.z,
        cfg().driveSpeed or 15.0, cfg().drivingStyle or 786603, cfg().arriveDistance or 10.0)
end

--- Common tail for both paths below: register the unit, start its FSM, and
--- send it driving. vehicle/driver/peds/pedSeats are already-networked and
--- already-owned by this point in both callers.
local function beginInvestigating(vehNetID, vehicle, driver, peds, pedSeats, incidentData)
    local fsm = FenixFSM.new(UNIT_STATES, 'DRIVING_TO_SCENE')
    fsm.data.driver = driver
    fsm.data.incidentCoords = incidentData.coords

    units[vehNetID] = { vehicle = vehicle, peds = peds, pedSeats = pedSeats, fsm = fsm, incidentId = incidentData.id }

    TriggerServerEvent('fenix-police:server:assignIncidentUnit', incidentData.id, vehNetID, 'investigating')

    driveTo(driver, vehicle, incidentData.coords)

    dbg(('#%s investigation unit dispatched, veh %d'):format(tostring(incidentData.id), vehNetID))
end

RegisterNetEvent('fenix-police:client:policeInvestigateIncident')
AddEventHandler('fenix-police:client:policeInvestigateIncident', function(data)
    if not cfg().enabled then return end
    if type(data) ~= 'table' or type(data.coords) ~= 'vector3' then return end

    if busyCount() >= (cfg().maxUnits or 1) then
        dbg(('#%s ignored, at maxUnits'):format(tostring(data.id)))
        return
    end

    -- Prefer reusing an already-wandering ambient patrol (client/ambient.lua)
    -- over always spawning a fresh unit -- same idea as the existing
    -- ambient-to-pursuit promotion, applied to investigation instead.
    local reuseRadius = cfg().reuseNearbyPatrolRadius or 120.0
    if reuseRadius > 0 and ClaimNearbyPatrolForInvestigation then
        local veh, driver, passengers = ClaimNearbyPatrolForInvestigation(data.coords, reuseRadius)
        if veh then
            -- The promotion waits on a server ticket; hold a slot meanwhile
            -- so a second call can't slip past maxUnits.
            local requestId = nextRequestId
            nextRequestId = nextRequestId + 1
            pendingRequests[requestId] = { data = data, at = GetGameTimer() }
            local vehNetID, driverNetID, passengerNetIDs = PromoteAmbientUnitForInvestigation(veh, driver, passengers)
            pendingRequests[requestId] = nil
            if vehNetID then
                -- Repaint for the incident's actual jurisdiction: this
                -- vehicle's livery reflects wherever the ambient patrol
                -- originally spawned, not necessarily this scene (see
                -- FenixLivery.labelsFor's header).
                FenixLivery.apply(veh, FenixLivery.labelsFor(veh, data.coords))

                local peds, pedSeats = { [driverNetID] = driver }, { [driverNetID] = -1 }
                for i, pedNetID in ipairs(passengerNetIDs or {}) do
                    peds[pedNetID] = passengers[i]
                    pedSeats[pedNetID] = i - 1 -- seat 0, 1, ... in the same order NumberOfSeats iterated them
                end

                dbg(('#%s reusing an ambient patrol instead of spawning fresh'):format(tostring(data.id)))
                beginInvestigating(vehNetID, veh, driver, peds, pedSeats, data)
                return
            end

            -- Promotion failed after the scene was already claimed (ticket
            -- timeout, networking failure) -- the entities are now orphaned
            -- from ambient.lua's own bookkeeping with nobody else owning
            -- them either. Same failure handling client.lua's
            -- tryPromoteScene uses for the pursuit-promotion equivalent:
            -- delete rather than leak.
            dbg(('#%s ambient patrol promotion failed, deleting the orphaned entities'):format(tostring(data.id)))
            for _, p in ipairs(passengers or {}) do
                if DoesEntityExist(p) then DeleteEntity(p) end
            end
            if driver and DoesEntityExist(driver) then DeleteEntity(driver) end
            if DoesEntityExist(veh) then DeleteEntity(veh) end
            return
        end
    end

    local spawnPoint, heading = FenixRoads.findSpawnPoint(data.coords, {
        minDistance = cfg().spawnMinDistance or 60.0,
        maxDistance = cfg().spawnMaxDistance or 140.0,
        towards = data.coords,
    })
    if not spawnPoint then
        dbg(('#%s no legal spawn point found near scene'):format(tostring(data.id)))
        return
    end

    local requestId = nextRequestId
    nextRequestId = nextRequestId + 1
    pendingRequests[requestId] = { data = data, at = GetGameTimer() }

    TriggerServerEvent('fenix-police:server:spawnInvestigateUnit', requestId, spawnPoint, heading)
end)

RegisterNetEvent('fenix-police:spawnInvestigateUnitClient')
AddEventHandler('fenix-police:spawnInvestigateUnitClient', function(requestId, vehicleInfo, spawnPoint, spawnHeading, ticket)
    local request = pendingRequests[requestId]
    if not request or request.spawning then return end
    local incidentData = request.data

    -- The request keeps its maxUnits slot while the models load (which
    -- yields); if the spawn fails below, it simply ages out.
    request.spawning = true
    request.at = GetGameTimer()

    -- Same install-check/fallback chain the marked pursuit fleet uses
    -- (client/livery.lua) -- without this, a missing/renamed add-on model
    -- would silently fail to load rather than falling back to stock.
    local modelName = FenixLivery.resolveModel(vehicleInfo.vehicle, spawnPoint, vehicleInfo.vehicleFallback)
    local vehicleHash = GetHashKey(modelName)
    if not loadModel(vehicleHash) then
        dbg('failed to load patrol vehicle model')
        return
    end

    local vehicle = CreateVehicle(vehicleHash, spawnPoint.x, spawnPoint.y, spawnPoint.z, spawnHeading or 0.0, true, true)
    if not DoesEntityExist(vehicle) then
        dbg('failed to create patrol vehicle client-side')
        return
    end

    SetEntityAsMissionEntity(vehicle, true, true)
    SetVehicleOnGroundProperly(vehicle)
    FenixLivery.apply(vehicle)

    local vehNetID = VehToNet(vehicle)
    NetworkSetNetworkIdDynamic(vehNetID, false)
    SetNetworkIdCanMigrate(vehNetID, false)
    SetNetworkIdExistsOnAllMachines(vehNetID, true)

    local peds, pedSeats, pedNetIDs = {}, {}, {}

    for i, modelName in ipairs(vehicleInfo.peds) do
        local seatIndex = i - 2
        local pedHash = GetHashKey(modelName)
        if loadModel(pedHash) then
            local ped = CreatePed(4, pedHash, spawnPoint.x, spawnPoint.y, spawnPoint.z, spawnHeading or 0.0, true, true)
            if DoesEntityExist(ped) then
                SetEntityAsMissionEntity(ped, true, true)
                SetPedFleeAttributes(ped, 0, false)
                SetPedIntoVehicle(ped, vehicle, seatIndex)
                Wait(50)

                local pedNetID = PedToNet(ped)
                NetworkSetNetworkIdDynamic(pedNetID, false)
                SetNetworkIdCanMigrate(pedNetID, false)
                SetNetworkIdExistsOnAllMachines(pedNetID, true)

                peds[pedNetID] = ped
                pedSeats[pedNetID] = seatIndex
                table.insert(pedNetIDs, pedNetID)
            end
            SetModelAsNoLongerNeeded(pedHash)
        end
    end

    local driver = GetPedInVehicleSeat(vehicle, -1)
    if not DoesEntityExist(driver) then
        dbg('patrol vehicle has no driver, aborting')
        for _, ped in pairs(peds) do DeleteEntity(ped) end
        DeleteEntity(vehicle)
        return
    end

    TriggerServerEvent('fenix-police:registerSpawnedUnit', ticket, vehNetID, pedNetIDs)

    pendingRequests[requestId] = nil
    beginInvestigating(vehNetID, vehicle, driver, peds, pedSeats, incidentData)
end)

local function officerPed(unit)
    for pedNetID, ped in pairs(unit.peds) do
        if DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true) and unit.pedSeats[pedNetID] ~= -1 then
            return ped, unit.pedSeats[pedNetID]
        end
    end
    -- Single-officer units have no passenger -- fall back to the driver.
    for pedNetID, ped in pairs(unit.peds) do
        if DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true) then return ped, unit.pedSeats[pedNetID] end
    end
    return nil
end

-- Every living crew member is seated in the unit's own vehicle.
local function crewAboard(unit)
    for _, ped in pairs(unit.peds) do
        if DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true) and not IsPedInVehicle(ped, unit.vehicle, false) then
            return false
        end
    end
    return true
end

-- Gets the ped out of the vehicle and into the scenario as ONE task
-- sequence. Issued as two separate tasks, the scenario replaces the exit
-- mid-animation, and re-issuing it every tick while the ped is still
-- walking over keeps restarting the walk.
local function exitIntoScenario(ped, vehicle, scenario, coords)
    local taskSequence = OpenSequenceTask(0)
    if IsPedInAnyVehicle(ped, false) then
        TaskLeaveVehicle(0, vehicle, 0)
    end
    TaskStartScenarioAtPosition(0, scenario, coords.x, coords.y, coords.z, 0.0, -1, false, false)
    CloseSequenceTask(taskSequence)
    TaskPerformSequence(ped, taskSequence)
    ClearSequenceTask(taskSequence)
end

local function driveTaskFinished(driver)
    return GetScriptTaskStatus(driver, DRIVE_TASK) == TASK_FINISHED
end

local function releaseIncident(unit, vehNetID)
    if unit.released then return end
    unit.released = true
    TriggerServerEvent('fenix-police:server:releaseIncidentUnit', unit.incidentId, vehNetID)
end

local function clearUnit(vehNetID)
    local unit = units[vehNetID]
    if not unit then return end

    releaseIncident(unit, vehNetID)

    TriggerServerEvent('deleteSpawnedVehicle', vehNetID)
    for pedNetID in pairs(unit.peds) do
        TriggerServerEvent('deleteSpawnedPed', pedNetID)
    end

    units[vehNetID] = nil
end

CreateThread(function()
    while true do
        Wait(cfg().tickMs or 1500)
        if cfg().enabled then
            for vehNetID, unit in pairs(units) do
                local ok, err = pcall(function()
                    local fsm = unit.fsm
                    local vehicle = unit.vehicle
                    local driver = fsm.data.driver
                    local coords = fsm.data.incidentCoords

                    if not DoesEntityExist(vehicle) or not DoesEntityExist(driver) or IsEntityDead(driver) then
                        dbg(('unit %d lost its vehicle/driver, clearing'):format(vehNetID))
                        clearUnit(vehNetID)
                        return
                    end

                    if fsm:is('DRIVING_TO_SCENE') then
                        local dist = #(GetEntityCoords(vehicle) - coords)

                        -- Nothing else ever moves a unit on from here: one
                        -- whose driver was dragged out of the seat, or that
                        -- is wedged somewhere, would hold its maxUnits slot
                        -- for good.
                        if GetPedInVehicleSeat(vehicle, -1) ~= driver or fsm:timeInState() > (cfg().maxDriveMs or 120000) then
                            dbg(('unit %d never reached the scene, clearing'):format(vehNetID))
                            clearUnit(vehNetID)
                            return
                        end

                        if dist <= (cfg().arriveDistance or 10.0) + 4.0 then
                            fsm:transition('INVESTIGATING')
                        elseif driveTaskFinished(driver) then
                            if dist <= ROAD_END_ARRIVE_DISTANCE then
                                fsm:transition('INVESTIGATING')
                            else
                                -- Knocked off its task short of the scene (an
                                -- event reaction, a collision) -- carry on.
                                driveTo(driver, vehicle, coords)
                            end
                        end
                    elseif fsm:is('INVESTIGATING') then
                        -- officerPed falls back to the driver when there's no
                        -- separate passenger (the default single-officer
                        -- config, and every reused ambient patrol -- those
                        -- only ever have one ped, see client/ambient.lua's
                        -- spawnPatrol). That officer still needs to physically
                        -- get out and investigate even though they're also
                        -- "the driver" -- there's nobody else to leave behind
                        -- minding the car, and there doesn't need to be; it
                        -- just sits parked until they re-board.
                        local officer, seat = officerPed(unit)
                        if officer then
                            -- Re-issued only once the sequence has actually
                            -- ended (cut short by an event reaction), never
                            -- while it is still walking the officer over.
                            if not fsm.data.officerDeployed
                                or (GetSequenceProgress(officer) == -1 and not IsPedUsingScenario(officer, OFFICER_SCENARIO))
                            then
                                fsm.data.officerDeployed = true
                                exitIntoScenario(officer, vehicle, OFFICER_SCENARIO, coords)
                            end
                            if not fsm.data.investigatingSince and IsPedUsingScenario(officer, OFFICER_SCENARIO) then
                                fsm.data.investigatingSince = GetGameTimer()
                            end
                        elseif not fsm.data.investigatingSince then
                            fsm.data.investigatingSince = GetGameTimer()
                        end

                        -- Counts from when the officer is actually on scene
                        -- looking around; otherwise getting out and walking
                        -- over eats a good part of it. The ceiling covers an
                        -- officer who never gets there.
                        local investigateMs = cfg().investigateTimeMs or 15000
                        local investigatedFor = fsm:msSince('investigatingSince')
                        if (investigatedFor and investigatedFor >= investigateMs) or fsm:timeInState() >= investigateMs + 30000 then
                            if officer then
                                ClearPedTasks(officer)
                                TaskEnterVehicle(officer, vehicle, BOARD_TIMEOUT_MS, seat, 1.0, 1, 0)
                            end
                            fsm:transition('CLEARING')
                        end
                    elseif fsm:is('CLEARING') then
                        -- Back into service: drive away, and only disappear
                        -- once nobody can see it, rather than the car and
                        -- officer vanishing on the spot.
                        if not fsm.data.departedAt then
                            if crewAboard(unit) or fsm:timeInState() >= BOARD_TIMEOUT_MS then
                                fsm.data.departedAt = GetGameTimer()
                                unit.departing = true
                                releaseIncident(unit, vehNetID)
                                TaskVehicleDriveWander(driver, vehicle, 15.0, 786603)
                            end
                        elseif fsm:msSince('departedAt') >= DEPART_DELETE_MS
                            or (not IsEntityOnScreen(vehicle)
                                and #(GetEntityCoords(vehicle) - GetEntityCoords(PlayerPedId())) > DEPART_DELETE_DISTANCE)
                        then
                            clearUnit(vehNetID)
                        end
                    end
                end)

                if not ok then
                    print('[fenix-police:investigate] tick error:', err)
                    clearUnit(vehNetID)
                end
            end
        end
    end
end)

RegisterCommand('fenixinvestigate', function()
    print(('[FENIX-INVESTIGATE] enabled=%s active units=%d'):format(tostring(cfg().enabled == true), unitCount()))
    for vehNetID, unit in pairs(units) do
        print(('  veh %d: incident #%s state=%s (%dms)'):format(
            vehNetID, tostring(unit.incidentId), unit.fsm.state, unit.fsm:timeInState()))
    end
end, false)
