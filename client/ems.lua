-- EMS ground response: dispatch -> drive to scene -> treat -> transport -> clear.
--
-- Built fresh (design spec section 11), not adapted from the police officer
-- loop in client.lua -- EMS never fights, never chases, and has exactly one
-- job per call, so it doesn't need that loop's complexity. Reuses this
-- resource's existing plumbing wherever it already fits: FenixRoads for a
-- legal spawn point, the same ticket/register handshake ground police units
-- use (server/guard.lua), and shared/unit_fsm.lua for the per-unit state
-- machine -- this is that FSM helper's first real user.
--
-- LIMITATION, stated plainly: there is no "patient" ped. A real casualty
-- model (a downed NPC/player entity EMS actually walks up to, checks, and
-- loads into the ambulance) isn't built yet -- this treats the incident
-- COORDINATES as the patient, which gets the response sequence and timing
-- right without pretending there's an entity here that doesn't exist. See
-- the incident's `victims` field (server/incident.lua) for where a real
-- casualty reference belongs once one exists.
--
-- Entirely opt-in: no-ops unless Config.EMS.enabled is true.

local function cfg()
    return Config.EMS or {}
end

local function dbg(...)
    if cfg().debug then
        print('[fenix-police:ems]', ...)
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

-- vehNetID -> { vehicle, peds = {netID = ped}, fsm, incidentId, hospital }
local units = {}
local pendingRequests = {} -- requestId -> incidentData
local nextRequestId = 1

local UNIT_STATES = {
    'DRIVING_TO_SCENE', 'STAGING', 'TREATING', 'DRIVING_TO_HOSPITAL', 'CLEARING',
}

-- Real "has police actually been assigned to this incident yet" signal
-- (server/dispatch.lua), checked once per tick while STAGING rather than
-- only ever waiting out a fixed timer. stagingHoldMs (Config.EMS) still
-- applies as a hard ceiling -- if no investigation unit was ever dispatched
-- (e.g. nobody was in host range), this stops the ambulance staging forever.
RegisterNetEvent('fenix-police:client:incidentHasRoleReply')
AddEventHandler('fenix-police:client:incidentHasRoleReply', function(incidentId, role, has)
    if role ~= 'investigating' or not has then return end
    for _, unit in pairs(units) do
        if unit.incidentId == incidentId and unit.fsm:is('STAGING') then
            unit.fsm.data.policeConfirmed = true
        end
    end
end)

local function unitCount()
    local n = 0
    for _ in pairs(units) do n = n + 1 end
    return n
end

RegisterNetEvent('fenix-police:client:emsIncidentCreated')
AddEventHandler('fenix-police:client:emsIncidentCreated', function(data)
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

    TriggerServerEvent('fenix-police:server:spawnEmsUnit', requestId, spawnPoint, heading)
end)

RegisterNetEvent('fenix-police:spawnEmsUnitClient')
AddEventHandler('fenix-police:spawnEmsUnitClient', function(requestId, vehicleInfo, spawnPoint, spawnHeading, ticket)
    local incidentData = pendingRequests[requestId]
    pendingRequests[requestId] = nil
    if not incidentData then return end

    local vehicleHash = GetHashKey(vehicleInfo.vehicle)
    if not loadModel(vehicleHash) then
        dbg('failed to load ambulance model')
        return
    end

    local vehicle = CreateVehicle(vehicleHash, spawnPoint.x, spawnPoint.y, spawnPoint.z, spawnHeading or 0.0, true, true)
    if not DoesEntityExist(vehicle) then
        dbg('failed to create ambulance client-side')
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

    local peds = {}
    local pedSeats = {}
    local pedNetIDs = {}

    for i, modelName in ipairs(vehicleInfo.peds) do
        local seatIndex = i - 2 -- first entry rides in the driver seat (-1), rest fill passenger seats from 0 up
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
        dbg('ambulance has no driver, aborting')
        for _, ped in pairs(peds) do DeleteEntity(ped) end
        DeleteEntity(vehicle)
        return
    end

    TriggerServerEvent('fenix-police:registerSpawnedUnit', ticket, vehNetID, pedNetIDs)

    local fsm = FenixFSM.new(UNIT_STATES, 'DRIVING_TO_SCENE')
    fsm.data.driver = driver
    fsm.data.incidentCoords = incidentData.coords
    fsm.data.severity = incidentData.severity or 1

    units[vehNetID] = {
        vehicle = vehicle,
        peds = peds,
        pedSeats = pedSeats,
        fsm = fsm,
        incidentId = incidentData.id,
    }

    TriggerServerEvent('fenix-police:server:assignIncidentUnit', incidentData.id, vehNetID, 'ems')

    TaskVehicleDriveToCoordLongrange(driver, vehicle, incidentData.coords.x, incidentData.coords.y, incidentData.coords.z,
        cfg().driveSpeed or 20.0, 1, (cfg().arriveDistance or 8.0))

    dbg(('#%s ambulance dispatched, veh %d'):format(tostring(incidentData.id), vehNetID))
end)

-- The medic who gets out and treats -- any non-driver crew, never the
-- driver (who needs to stay put to drive to the hospital afterward).
local function medicPed(unit)
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

    -- Ownership/model bookkeeping (FenixGuard) lives server-side and expects
    -- an explicit delete request, same as the police cleanup paths in
    -- client.lua -- an EMS unit just vanishing client-side would leave the
    -- server thinking it still owns entities that no longer exist.
    TriggerServerEvent('deleteSpawnedVehicle', vehNetID)
    for pedNetID in pairs(unit.peds) do
        TriggerServerEvent('deleteSpawnedPed', pedNetID)
    end

    units[vehNetID] = nil
end

-- Ticked at a moderate rate: EMS calls are far rarer than pursuit units and
-- each one runs a simple linear sequence, so this doesn't need client.lua's
-- 1-second cadence.
CreateThread(function()
    while true do
        Wait(cfg().tickMs or 1500)
        if cfg().enabled then
            for vehNetID, unit in pairs(units) do
                local ok, err = pcall(function()
                    local fsm = unit.fsm
                    local vehicle = unit.vehicle
                    local driver = fsm.data.driver

                    if not DoesEntityExist(vehicle) or not DoesEntityExist(driver) or IsEntityDead(driver) then
                        dbg(('unit %d lost its vehicle/driver, clearing'):format(vehNetID))
                        clearUnit(vehNetID)
                        return
                    end

                    if fsm:is('DRIVING_TO_SCENE') then
                        local dist = #(GetEntityCoords(vehicle) - fsm.data.incidentCoords)
                        if dist <= (cfg().arriveDistance or 8.0) + 4.0 then
                            local dangerThreshold = cfg().dangerousSeverity or 3
                            if fsm.data.severity >= dangerThreshold and (cfg().stagingHoldMs or 0) > 0 then
                                fsm:transition('STAGING')
                            else
                                fsm:transition('TREATING')
                            end
                        end
                    elseif fsm:is('STAGING') then
                        -- Prefers the real signal (an investigation/patrol
                        -- unit actually assigned to this incident,
                        -- server/dispatch.lua) over the timer; the timer is
                        -- a ceiling so a call nobody responds to doesn't
                        -- stage forever, not the primary mechanism anymore.
                        TriggerServerEvent('fenix-police:server:queryIncidentHasRole', unit.incidentId, 'investigating')

                        if fsm.data.policeConfirmed or fsm:timeInState() >= (cfg().stagingHoldMs or 8000) then
                            fsm:transition('TREATING')
                        end
                    elseif fsm:is('TREATING') then
                        if not fsm.data.treatmentStarted then
                            fsm.data.treatmentStarted = true
                            local medic = medicPed(unit)
                            if medic then
                                TaskLeaveVehicle(medic, vehicle, 0)
                            end
                        end

                        if fsm:timeInState() >= (cfg().treatmentTimeMs or 8000) then
                            local medic, seat = medicPed(unit)
                            if medic and DoesEntityExist(medic) then
                                ClearPedTasks(medic)
                                TaskEnterVehicle(medic, vehicle, 8000, seat, 1.0, 1, nil)
                            end
                            fsm:transition('DRIVING_TO_HOSPITAL')
                        elseif fsm:timeInState() > 500 then
                            local medic = medicPed(unit)
                            if medic and DoesEntityExist(medic) and not IsPedUsingScenario(medic, 'CODE_HUMAN_MEDIC_KNEEL') then
                                local coords = fsm.data.incidentCoords
                                TaskStartScenarioAtPosition(medic, 'CODE_HUMAN_MEDIC_KNEEL', coords.x, coords.y, coords.z, 0.0, -1, false, false)
                            end
                        end
                    elseif fsm:is('DRIVING_TO_HOSPITAL') then
                        if not fsm.data.hospitalTaskGiven then
                            fsm.data.hospitalTaskGiven = true
                            local hospital = cfg().hospitalCoords or vector3(304.27, -600.33, 43.28)
                            TaskVehicleDriveToCoordLongrange(driver, vehicle, hospital.x, hospital.y, hospital.z,
                                cfg().driveSpeed or 25.0, 1, 10.0)
                        end

                        local hospital = cfg().hospitalCoords or vector3(304.27, -600.33, 43.28)
                        if #(GetEntityCoords(vehicle) - hospital) <= 12.0 then
                            fsm:transition('CLEARING')
                        end
                    elseif fsm:is('CLEARING') then
                        clearUnit(vehNetID)
                    end
                end)

                if not ok then
                    print('[fenix-police:ems] tick error:', err)
                    clearUnit(vehNetID)
                end
            end
        end
    end
end)

RegisterCommand('fenixems', function()
    print(('[FENIX-EMS] enabled=%s active units=%d'):format(tostring(cfg().enabled == true), unitCount()))
    for vehNetID, unit in pairs(units) do
        print(('  veh %d: incident #%s state=%s (%dms)'):format(
            vehNetID, tostring(unit.incidentId), unit.fsm.state, unit.fsm:timeInState()))
    end
end, false)
