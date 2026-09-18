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
local pendingRequests = {}
local nextRequestId = 1

local UNIT_STATES = { 'DRIVING_TO_SCENE', 'INVESTIGATING', 'CLEARING' }

local function unitCount()
    local n = 0
    for _ in pairs(units) do n = n + 1 end
    return n
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

    TaskVehicleDriveToCoordLongrange(driver, vehicle, incidentData.coords.x, incidentData.coords.y, incidentData.coords.z,
        cfg().driveSpeed or 15.0, 1, cfg().arriveDistance or 10.0)

    dbg(('#%s investigation unit dispatched, veh %d'):format(tostring(incidentData.id), vehNetID))
end

RegisterNetEvent('fenix-police:client:policeInvestigateIncident')
AddEventHandler('fenix-police:client:policeInvestigateIncident', function(data)
    if not cfg().enabled then return end
    if type(data) ~= 'table' or type(data.coords) ~= 'vector3' then return end

    if unitCount() >= (cfg().maxUnits or 1) then
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
            local vehNetID, driverNetID, passengerNetIDs = PromoteAmbientUnitForInvestigation(veh, driver, passengers)
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
    pendingRequests[requestId] = data

    TriggerServerEvent('fenix-police:server:spawnInvestigateUnit', requestId, spawnPoint, heading)
end)

RegisterNetEvent('fenix-police:spawnInvestigateUnitClient')
AddEventHandler('fenix-police:spawnInvestigateUnitClient', function(requestId, vehicleInfo, spawnPoint, spawnHeading, ticket)
    local incidentData = pendingRequests[requestId]
    pendingRequests[requestId] = nil
    if not incidentData then return end

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

    beginInvestigating(vehNetID, vehicle, driver, peds, pedSeats, incidentData)
end)

local function officerPed(unit)
    for pedNetID, ped in pairs(unit.peds) do
        if DoesEntityExist(ped) and unit.pedSeats[pedNetID] ~= -1 then
            return ped, unit.pedSeats[pedNetID]
        end
    end
    -- Single-officer units have no passenger -- fall back to the driver.
    for pedNetID, ped in pairs(unit.peds) do
        if DoesEntityExist(ped) then return ped, unit.pedSeats[pedNetID] end
    end
    return nil
end

local function clearUnit(vehNetID)
    local unit = units[vehNetID]
    if not unit then return end

    TriggerServerEvent('fenix-police:server:releaseIncidentUnit', unit.incidentId, vehNetID)

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
                        if dist <= (cfg().arriveDistance or 10.0) + 4.0 then
                            fsm:transition('INVESTIGATING')
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
                        if not fsm.data.officerDeployed then
                            fsm.data.officerDeployed = true
                            local officer = officerPed(unit)
                            if officer then
                                TaskLeaveVehicle(officer, vehicle, 0)
                            end
                        end

                        local officer = officerPed(unit)
                        if officer and DoesEntityExist(officer) and not IsPedUsingScenario(officer, 'CODE_HUMAN_POLICE_INVESTIGATE') then
                            TaskStartScenarioAtPosition(officer, 'CODE_HUMAN_POLICE_INVESTIGATE', coords.x, coords.y, coords.z, 0.0, -1, false, false)
                        end

                        if fsm:timeInState() >= (cfg().investigateTimeMs or 15000) then
                            if officer and DoesEntityExist(officer) then
                                ClearPedTasks(officer)
                                local _, seat = officerPed(unit)
                                TaskEnterVehicle(officer, vehicle, 8000, seat, 1.0, 1, nil)
                            end
                            fsm:transition('CLEARING')
                        end
                    elseif fsm:is('CLEARING') then
                        if fsm:timeInState() >= 6000 then
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
