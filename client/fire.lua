-- Fire ground response: dispatch -> drive to scene -> suppress -> clear.
--
-- Structurally identical to client/ems.lua (spawn via the same
-- ticket/register handshake, FenixFSM for state) with a different job on
-- scene: repeatedly call FIRE::STOP_FIRE_IN_RANGE around the incident
-- coords rather than a fixed animation beat, since suppression has a real
-- native outcome to drive off of (GET_NUMBER_OF_FIRES_IN_RANGE reaching
-- zero) instead of a flat timer standing in for progress.
--
-- Entirely opt-in: no-ops unless Config.Fire.enabled is true.

local function cfg()
    return Config.Fire or {}
end

local function dbg(...)
    if cfg().debug then
        print('[fenix-police:fire]', ...)
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

local UNIT_STATES = { 'DRIVING_TO_SCENE', 'SUPPRESSING', 'CLEARING' }

local function unitCount()
    local n = 0
    for _ in pairs(units) do n = n + 1 end
    return n
end

RegisterNetEvent('fenix-police:client:fireIncidentCreated')
AddEventHandler('fenix-police:client:fireIncidentCreated', function(data)
    if not cfg().enabled then return end
    if type(data) ~= 'table' or type(data.coords) ~= 'vector3' then return end

    if unitCount() >= (cfg().maxUnits or 1) then
        dbg(('#%s ignored, at maxUnits'):format(tostring(data.id)))
        return
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

    TriggerServerEvent('fenix-police:server:spawnFireUnit', requestId, spawnPoint, heading)
end)

RegisterNetEvent('fenix-police:spawnFireUnitClient')
AddEventHandler('fenix-police:spawnFireUnitClient', function(requestId, vehicleInfo, spawnPoint, spawnHeading, ticket)
    local incidentData = pendingRequests[requestId]
    pendingRequests[requestId] = nil
    if not incidentData then return end

    local vehicleHash = GetHashKey(vehicleInfo.vehicle)
    if not loadModel(vehicleHash) then
        dbg('failed to load fire truck model')
        return
    end

    local vehicle = CreateVehicle(vehicleHash, spawnPoint.x, spawnPoint.y, spawnPoint.z, spawnHeading or 0.0, true, true)
    if not DoesEntityExist(vehicle) then
        dbg('failed to create fire truck client-side')
        return
    end

    SetEntityAsMissionEntity(vehicle, true, true)
    SetVehicleOnGroundProperly(vehicle)
    SetVehicleSiren(vehicle, true)
    SetSirenKeepOn(vehicle, true)

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
                SetPedCanBeTargetted(ped, false)
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
        dbg('fire truck has no driver, aborting')
        for _, ped in pairs(peds) do DeleteEntity(ped) end
        DeleteEntity(vehicle)
        return
    end

    TriggerServerEvent('fenix-police:registerSpawnedUnit', ticket, vehNetID, pedNetIDs)

    local fsm = FenixFSM.new(UNIT_STATES, 'DRIVING_TO_SCENE')
    fsm.data.driver = driver
    fsm.data.incidentCoords = incidentData.coords

    units[vehNetID] = { vehicle = vehicle, peds = peds, pedSeats = pedSeats, fsm = fsm, incidentId = incidentData.id }

    TriggerServerEvent('fenix-police:server:assignIncidentUnit', incidentData.id, vehNetID, 'fire')

    TaskVehicleDriveToCoordLongrange(driver, vehicle, incidentData.coords.x, incidentData.coords.y, incidentData.coords.z,
        cfg().driveSpeed or 20.0, 1, cfg().arriveDistance or 10.0)

    dbg(('#%s fire truck dispatched, veh %d'):format(tostring(incidentData.id), vehNetID))
end)

local function crewPed(unit)
    for pedNetID, ped in pairs(unit.peds) do
        if DoesEntityExist(ped) and unit.pedSeats[pedNetID] ~= -1 then
            return ped, unit.pedSeats[pedNetID]
        end
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
                            fsm:transition('SUPPRESSING')
                        end
                    elseif fsm:is('SUPPRESSING') then
                        if not fsm.data.crewDeployed then
                            fsm.data.crewDeployed = true
                            local crew = crewPed(unit)
                            if crew then
                                TaskLeaveVehicle(crew, vehicle, 0)
                            end
                        end

                        local radius = cfg().suppressRadius or 15.0
                        StopFireInRange(coords.x, coords.y, coords.z, radius)

                        local crew = crewPed(unit)
                        if crew and DoesEntityExist(crew) and not IsPedUsingScenario(crew, 'WORLD_HUMAN_STAND_FIRE') then
                            TaskStartScenarioAtPosition(crew, 'WORLD_HUMAN_STAND_FIRE', coords.x, coords.y, coords.z, 0.0, -1, false, false)
                        end

                        local firesLeft = GetNumberOfFiresInRange(coords.x, coords.y, coords.z, radius)
                        local timedOut = fsm:timeInState() >= (cfg().maxSuppressMs or 30000)
                        if firesLeft <= 0 or timedOut then
                            if crew and DoesEntityExist(crew) then
                                ClearPedTasks(crew)
                                local _, seat = crewPed(unit)
                                TaskEnterVehicle(crew, vehicle, 8000, seat, 1.0, 1, nil)
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
                    print('[fenix-police:fire] tick error:', err)
                    clearUnit(vehNetID)
                end
            end
        end
    end
end)

RegisterCommand('fenixfire', function()
    print(('[FENIX-FIRE] enabled=%s active units=%d'):format(tostring(cfg().enabled == true), unitCount()))
    for vehNetID, unit in pairs(units) do
        print(('  veh %d: incident #%s state=%s (%dms)'):format(
            vehNetID, tostring(unit.incidentId), unit.fsm.state, unit.fsm:timeInState()))
    end
end, false)
