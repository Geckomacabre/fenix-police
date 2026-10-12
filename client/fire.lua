-- Fire ground response: dispatch -> drive to scene -> suppress -> clear.
--
-- Structurally identical to client/ems.lua (spawn via the same
-- ticket/register handshake, FenixFSM for state) with a different job on
-- scene: a crew member works the fire with an extinguisher, after which
-- FIRE::STOP_FIRE_IN_RANGE is called around the incident coords until
-- GET_NUMBER_OF_FIRES_IN_RANGE reads zero -- suppression has a real native
-- outcome to drive off of instead of a flat timer standing in for progress.
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
local pendingRequests = {} -- requestId -> { data = incidentData, at = GetGameTimer() }
local nextRequestId = 1

local UNIT_STATES = { 'DRIVING_TO_SCENE', 'SUPPRESSING', 'CLEARING' }

local EXTINGUISHER = GetHashKey('WEAPON_FIREEXTINGUISHER')
local FIRING_PATTERN_FULL_AUTO = GetHashKey('FIRING_PATTERN_FULL_AUTO')

-- The crew works the fire from this far back -- inside an extinguisher's
-- reach without walking into the flames -- and only counts as working it
-- once within SPRAY_RANGE.
local STANDOFF_DISTANCE = 4.5
local SPRAY_RANGE = 10.0

-- GetScriptTaskStatus reports TaskVehicleDriveToCoordLongrange under this
-- hash; 7 means the task has finished (or isn't running at all).
local DRIVE_TASK = GetHashKey('SCRIPT_TASK_VEHICLE_DRIVE_TO_COORD_LONGRANGE')
local TASK_FINISHED = 7

-- A long-range drive ends at the nearest road node, which for a fire off the
-- road can be well short of it -- without this the truck sits there forever,
-- never "arriving". Within this distance a finished drive counts as arrived.
local ROAD_END_ARRIVE_DISTANCE = 60.0

-- How long crew get to climb back aboard before the truck leaves anyway.
local BOARD_TIMEOUT_MS = 15000

-- A departing truck is deleted once it's out of sight this far from the
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

-- What counts against maxUnits: trucks still working a call (one already
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

local function driveTo(driver, vehicle, coords)
    TaskVehicleDriveToCoordLongrange(driver, vehicle, coords.x, coords.y, coords.z,
        cfg().driveSpeed or 20.0, cfg().drivingStyle or 786469, cfg().arriveDistance or 10.0)
end

RegisterNetEvent('fenix-police:client:fireIncidentCreated')
AddEventHandler('fenix-police:client:fireIncidentCreated', function(data)
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

    TriggerServerEvent('fenix-police:server:spawnFireUnit', requestId, spawnPoint, heading)
end)

RegisterNetEvent('fenix-police:spawnFireUnitClient')
AddEventHandler('fenix-police:spawnFireUnitClient', function(requestId, vehicleInfo, spawnPoint, spawnHeading, ticket)
    local request = pendingRequests[requestId]
    if not request or request.spawning then return end
    local incidentData = request.data

    -- The request keeps its maxUnits slot while the models load (which
    -- yields); if the spawn fails below, it simply ages out.
    request.spawning = true
    request.at = GetGameTimer()

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

    pendingRequests[requestId] = nil
    units[vehNetID] = { vehicle = vehicle, peds = peds, pedSeats = pedSeats, fsm = fsm, incidentId = incidentData.id }

    TriggerServerEvent('fenix-police:server:assignIncidentUnit', incidentData.id, vehNetID, 'fire')

    driveTo(driver, vehicle, incidentData.coords)

    dbg(('#%s fire truck dispatched, veh %d'):format(tostring(incidentData.id), vehNetID))
end)

local function crewPed(unit)
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

-- The live fire nearest the scene within the suppression radius, or the
-- scene itself when nothing is burning (the crew still damps it down).
local function fireTarget(coords, radius)
    local found, firePos = GetClosestFirePos(coords.x, coords.y, coords.z)
    if found and #(firePos - coords) <= radius then
        return firePos
    end
    return coords
end

-- Where the crew stands to work the target: STANDOFF_DISTANCE short of it,
-- on the truck's side.
local function standoffPoint(vehicle, target)
    local from = GetEntityCoords(vehicle)
    local dx, dy = from.x - target.x, from.y - target.y
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.1 then return target end
    local k = STANDOFF_DISTANCE / len
    return vector3(target.x + dx * k, target.y + dy * k, target.z)
end

-- Out of the truck, over to the fire and onto it with the extinguisher, as
-- ONE task sequence: issued as separate tasks in the same tick, each
-- replaces the last before it has started, and the crew never visibly does
-- anything.
local function deployCrew(crew, vehicle, target)
    local stand = standoffPoint(vehicle, target)
    local taskSequence = OpenSequenceTask(0)
    if IsPedInAnyVehicle(crew, false) then
        TaskLeaveVehicle(0, vehicle, 0)
    end
    TaskFollowNavMeshToCoord(0, stand.x, stand.y, stand.z, 2.0, 20000, 1.0, 0, 0.0)
    TaskShootAtCoord(0, target.x, target.y, target.z, cfg().maxSuppressMs or 30000, FIRING_PATTERN_FULL_AUTO)
    CloseSequenceTask(taskSequence)
    TaskPerformSequence(crew, taskSequence)
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
                            fsm:transition('SUPPRESSING')
                        elseif driveTaskFinished(driver) then
                            if dist <= ROAD_END_ARRIVE_DISTANCE then
                                fsm:transition('SUPPRESSING')
                            else
                                -- Knocked off its task short of the scene (an
                                -- event reaction, a collision) -- carry on.
                                driveTo(driver, vehicle, coords)
                            end
                        end
                    elseif fsm:is('SUPPRESSING') then
                        local radius = cfg().suppressRadius or 15.0
                        local target = fireTarget(coords, radius)
                        local crew = crewPed(unit)

                        if crew then
                            -- Re-issued only once the sequence has actually
                            -- ended, never while it is still walking the crew
                            -- member over.
                            if not fsm.data.crewDeployed or GetSequenceProgress(crew) == -1 then
                                fsm.data.crewDeployed = true
                                deployCrew(crew, vehicle, target)
                            end

                            -- Handed over on foot: weapons given to a seated
                            -- ped don't reliably end up in hand.
                            if fsm.data.extinguisherGiven ~= crew and not IsPedInAnyVehicle(crew, false) then
                                fsm.data.extinguisherGiven = crew
                                GiveWeaponToPed(crew, EXTINGUISHER, 2000, false, true)
                                SetPedInfiniteAmmo(crew, true, EXTINGUISHER)
                            end

                            if not fsm.data.sprayingSince and not IsPedInAnyVehicle(crew, false)
                                and #(GetEntityCoords(crew) - target) <= SPRAY_RANGE
                            then
                                fsm.data.sprayingSince = GetGameTimer()
                            end
                        elseif not fsm.data.sprayingSince then
                            fsm.data.sprayingSince = GetGameTimer()
                        end

                        -- The fire only goes out once the crew has been on
                        -- it for suppressDelayMs, so the response is
                        -- something you can watch rather than an instant
                        -- STOP_FIRE_IN_RANGE the moment the truck pulls up.
                        -- maxSuppressMs is the ceiling for a crew that can't
                        -- reach it, or a fire that keeps re-igniting.
                        local sprayedFor = fsm:msSince('sprayingSince')
                        local timedOut = fsm:timeInState() >= (cfg().maxSuppressMs or 30000)
                        if (sprayedFor and sprayedFor >= (cfg().suppressDelayMs or 6000)) or timedOut then
                            StopFireInRange(coords.x, coords.y, coords.z, radius)

                            local firesLeft = GetNumberOfFiresInRange(coords.x, coords.y, coords.z, radius)
                            if firesLeft <= 0 or timedOut then
                                if crew then
                                    ClearPedTasks(crew)
                                    local _, seat = crewPed(unit)
                                    TaskEnterVehicle(crew, vehicle, BOARD_TIMEOUT_MS, seat, 1.0, 1, 0)
                                end
                                fsm:transition('CLEARING')
                            end
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
