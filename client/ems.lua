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
local pendingRequests = {} -- requestId -> { data = incidentData, at = GetGameTimer() }
local nextRequestId = 1

local UNIT_STATES = {
    'DRIVING_TO_SCENE', 'STAGING', 'TREATING', 'DRIVING_TO_HOSPITAL', 'CLEARING',
}

local DEFAULT_HOSPITAL = vector3(294.58, -574.76, 43.18)
local MEDIC_SCENARIO = 'CODE_HUMAN_MEDIC_KNEEL'

-- GetScriptTaskStatus reports TaskVehicleDriveToCoordLongrange under this
-- hash; 7 means the task has finished (or isn't running at all).
local DRIVE_TASK = GetHashKey('SCRIPT_TASK_VEHICLE_DRIVE_TO_COORD_LONGRANGE')
local TASK_FINISHED = 7

-- A long-range drive ends at the nearest road node, which for a call placed
-- off-road, indoors or up on a roof can be well short of the coordinates
-- themselves -- without this the unit sits there forever, never "arriving".
-- Within this distance a finished drive counts as arrived.
local ROAD_END_ARRIVE_DISTANCE = 60.0

-- How long crew get to climb back aboard before the unit moves on anyway.
local BOARD_TIMEOUT_MS = 15000

-- A departing unit is deleted once it's out of sight this far from the
-- player, or after DEPART_DELETE_MS regardless.
local DEPART_DELETE_DISTANCE = 150.0
local DEPART_DELETE_MS = 60000

-- The server drops a refused spawn request without replying, so a request
-- only holds a maxUnits slot for this long.
local PENDING_REQUEST_TTL_MS = 10000

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

-- What counts against maxUnits: units still working a call (one already
-- driving off doesn't), plus spawn requests still waiting on the server --
-- without those, two calls a moment apart would both get past the cap.
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

-- Does this call bring police at all? Staging only means something while
-- police are on the way; a FIRE call (fire + ems) never gets an
-- investigation unit, so staging on one would always sit out the full timer.
-- Uses the payload's own list when the server sends one, otherwise the same
-- Config.Dispatch.unitsNeeded table the server dispatched from.
local function policeResponding(data)
    local agencies = data.agencies
    if type(agencies) ~= 'table' then
        agencies = ((Config.Dispatch or {}).unitsNeeded or {})[data.type] or { 'police' }
    end
    for _, agency in ipairs(agencies) do
        if agency == 'police' then return true end
    end
    return false
end

local function driveTo(driver, vehicle, coords, speed, stopRange)
    TaskVehicleDriveToCoordLongrange(driver, vehicle, coords.x, coords.y, coords.z,
        speed, cfg().drivingStyle or 786469, stopRange)
end

RegisterNetEvent('fenix-police:client:emsIncidentCreated')
AddEventHandler('fenix-police:client:emsIncidentCreated', function(data)
    if not cfg().enabled then return end
    if type(data) ~= 'table' or type(data.coords) ~= 'vector3' then return end

    if busyCount() >= (cfg().maxUnits or 1) then
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
    pendingRequests[requestId] = { data = data, at = GetGameTimer() }

    TriggerServerEvent('fenix-police:server:spawnEmsUnit', requestId, spawnPoint, heading)
end)

RegisterNetEvent('fenix-police:spawnEmsUnitClient')
AddEventHandler('fenix-police:spawnEmsUnitClient', function(requestId, vehicleInfo, spawnPoint, spawnHeading, ticket)
    local request = pendingRequests[requestId]
    if not request or request.spawning then return end
    local incidentData = request.data

    -- The request keeps its maxUnits slot while the models load (which
    -- yields); if the spawn fails below, it simply ages out.
    request.spawning = true
    request.at = GetGameTimer()

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
    fsm.data.policeExpected = policeResponding(incidentData)

    pendingRequests[requestId] = nil
    units[vehNetID] = {
        vehicle = vehicle,
        peds = peds,
        pedSeats = pedSeats,
        fsm = fsm,
        incidentId = incidentData.id,
    }

    TriggerServerEvent('fenix-police:server:assignIncidentUnit', incidentData.id, vehNetID, 'ems')

    driveTo(driver, vehicle, incidentData.coords, cfg().driveSpeed or 20.0, cfg().arriveDistance or 8.0)

    dbg(('#%s ambulance dispatched, veh %d'):format(tostring(incidentData.id), vehNetID))
end)

-- The medic who gets out and treats -- any non-driver crew, never the
-- driver (who needs to stay put to drive to the hospital afterward). A
-- dead one doesn't count: the unit carries on as if it had no medic.
local function medicPed(unit)
    for pedNetID, ped in pairs(unit.peds) do
        if DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true) and unit.pedSeats[pedNetID] ~= -1 then
            return ped, unit.pedSeats[pedNetID]
        end
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
                        local coords = fsm.data.incidentCoords
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

                        local dangerous = fsm.data.policeExpected
                            and fsm.data.severity >= (cfg().dangerousSeverity or 3)
                            and (cfg().stagingHoldMs or 0) > 0

                        if dangerous and not fsm.data.staged and dist <= (cfg().stagingDistance or 60.0) then
                            -- Hold back short of a dangerous scene instead of
                            -- pulling up in the middle of it and waiting there.
                            -- TA_WAIT outlasts the hold; STAGING re-issues the
                            -- drive once it's over.
                            fsm.data.staged = true
                            TaskVehicleTempAction(driver, vehicle, 1, (cfg().stagingHoldMs or 8000) + 5000)
                            fsm:transition('STAGING')
                        elseif dist <= (cfg().arriveDistance or 8.0) + 4.0 then
                            fsm:transition('TREATING')
                        elseif driveTaskFinished(driver) then
                            if dist <= ROAD_END_ARRIVE_DISTANCE then
                                fsm:transition('TREATING')
                            else
                                -- Knocked off its task short of the scene (an
                                -- event reaction, a collision) -- carry on.
                                driveTo(driver, vehicle, coords, cfg().driveSpeed or 20.0, cfg().arriveDistance or 8.0)
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
                            driveTo(driver, vehicle, fsm.data.incidentCoords, cfg().driveSpeed or 20.0, cfg().arriveDistance or 8.0)
                            fsm:transition('DRIVING_TO_SCENE')
                        end
                    elseif fsm:is('TREATING') then
                        local medic, seat = medicPed(unit)
                        if medic then
                            -- Re-issued only once the sequence has actually
                            -- ended (cut short by an event reaction), never
                            -- while it is still walking the medic over.
                            if not fsm.data.treatmentStarted
                                or (GetSequenceProgress(medic) == -1 and not IsPedUsingScenario(medic, MEDIC_SCENARIO))
                            then
                                fsm.data.treatmentStarted = true
                                exitIntoScenario(medic, vehicle, MEDIC_SCENARIO, fsm.data.incidentCoords)
                            end
                            if not fsm.data.treatingSince and IsPedUsingScenario(medic, MEDIC_SCENARIO) then
                                fsm.data.treatingSince = GetGameTimer()
                            end
                        elseif not fsm.data.treatingSince then
                            fsm.data.treatingSince = GetGameTimer()
                        end

                        -- The treatment beat counts from when the medic is
                        -- actually kneeling; otherwise getting out and
                        -- walking over eats most of it. The ceiling covers a
                        -- medic who never gets there.
                        local treatmentMs = cfg().treatmentTimeMs or 8000
                        local treatedFor = fsm:msSince('treatingSince')
                        if (treatedFor and treatedFor >= treatmentMs) or fsm:timeInState() >= treatmentMs + 30000 then
                            if medic then
                                ClearPedTasks(medic)
                                TaskEnterVehicle(medic, vehicle, BOARD_TIMEOUT_MS, seat, 1.0, 1, 0)
                            end
                            fsm:transition('DRIVING_TO_HOSPITAL')
                        end
                    elseif fsm:is('DRIVING_TO_HOSPITAL') then
                        local hospital = cfg().hospitalCoords or DEFAULT_HOSPITAL

                        if not fsm.data.hospitalTaskGiven then
                            -- Pull away only with the medic back aboard;
                            -- otherwise the drive goes out the very next tick
                            -- and leaves them standing at the scene.
                            local medic, seat = medicPed(unit)
                            if medic and not IsPedInVehicle(medic, vehicle, false) then
                                if fsm:timeInState() < BOARD_TIMEOUT_MS then return end
                                if IsVehicleSeatFree(vehicle, seat) then
                                    SetPedIntoVehicle(medic, vehicle, seat)
                                end
                            end
                            fsm.data.hospitalTaskGiven = true
                            driveTo(driver, vehicle, hospital, cfg().driveSpeed or 25.0, 10.0)
                            return
                        end

                        local vehCoords = GetEntityCoords(vehicle)
                        local dist = #(vehCoords - hospital)
                        if GetPedInVehicleSeat(vehicle, -1) ~= driver then
                            dbg(('unit %d lost its driver on the way to hospital, clearing'):format(vehNetID))
                            clearUnit(vehNetID)
                        elseif dist <= 40.0 or (driveTaskFinished(driver) and dist <= ROAD_END_ARRIVE_DISTANCE) then
                            fsm:transition('CLEARING')
                        elseif fsm:timeInState() > (cfg().maxHospitalDriveMs or 180000)
                            or (not IsEntityOnScreen(vehicle)
                                and #(vehCoords - GetEntityCoords(PlayerPedId())) > DEPART_DELETE_DISTANCE)
                        then
                            -- Stuck, or the rest of the trip happens where
                            -- nobody can see it -- and, past this client's
                            -- scope, where it can't really be driven anyway.
                            fsm:transition('CLEARING')
                        elseif driveTaskFinished(driver) then
                            driveTo(driver, vehicle, hospital, cfg().driveSpeed or 25.0, 10.0)
                        end
                    elseif fsm:is('CLEARING') then
                        -- Back into service: siren off, drive away, and only
                        -- disappear once nobody can see it, rather than the
                        -- whole unit vanishing on the spot.
                        if not fsm.data.departedAt then
                            if crewAboard(unit) or fsm:timeInState() >= BOARD_TIMEOUT_MS then
                                fsm.data.departedAt = GetGameTimer()
                                unit.departing = true
                                releaseIncident(unit, vehNetID)
                                SetVehicleSiren(vehicle, false)
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
