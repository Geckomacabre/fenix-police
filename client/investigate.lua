-- Police investigation response: drive to scene -> look around -> clear.
--
-- The counterpart to client/ems.lua and client/fire.lua for incidents that
-- need police but have no known suspect (a civilian-witnessed gunfire
-- report, typically -- see server/investigate.lua). A single officer parks
-- near the reported location and runs CODE_HUMAN_POLICE_INVESTIGATE for a
-- while, then clears. No combat, no chase, no arrest -- those all assume a
-- target this unit doesn't have.
--
-- What it can find: the players listed as suspects on the call -- a caller
-- whose own client says they had just fired a gun (client/witness.lua). On
-- the way in and while on scene, the crew watches for one of them within
-- spotRange, in line of sight and visibly armed. That's real information,
-- not a lookup: a suspect who walked off, holstered or is out of sight is
-- never found, and the officer clears as before. One who is seen gets
-- reported to the server, which checks the sighting against its own view
-- of the world before starring anybody (server/dispatch.lua). If the
-- suspect is this client's own player, the unit stops being an
-- investigation and joins the pursuit as a real unit (client.lua's
-- PromoteAmbientUnit) -- the officer who saw the gun is the one who chases.
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

local units = {} -- vehNetID -> { vehicle, peds, pedSeats, fsm, incidentId, suspects }
local pendingRequests = {} -- requestId -> { data = incidentData, at = GetGameTimer() }
local nextRequestId = 1

local UNIT_STATES = { 'DRIVING_TO_SCENE', 'INVESTIGATING', 'HANDING_OFF', 'CLEARING' }

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

-- GetScriptTaskStatus's name for TaskEnterVehicle.
local ENTER_TASK = GetHashKey('SCRIPT_TASK_ENTER_VEHICLE')

-- A unit that has seen its own player armed waits this long after the
-- wanted level lands before joining the pursuit. ambient.lua's wanted-onset
-- sweep promotes its own nearby patrols in the first second or so of a
-- wanted level, through the same one-at-a-time PromoteAmbientUnit handshake;
-- going after it rather than alongside keeps the two from taking each
-- other's ticket.
local HANDOFF_SETTLE_MS = 3000

-- How long the hand-off waits for the stars and for the driver to be back
-- behind the wheel. Never starred (wanted levels switched off, an on-duty
-- officer, the server turned the sighting down) or never back in the car:
-- the unit clears like any other call.
local HANDOFF_TIMEOUT_MS = 20000

-- A suspect list is a handful of players near one scene.
local MAX_SUSPECTS = 16

-- A unit only starts watching for suspects this long after it reports for
-- the call. Its assignment can take a couple of seconds to land on the
-- server (assignIncidentUnit waits for the entity to get there first), and
-- a sighting -- or the release that follows one -- from a unit the server
-- doesn't yet know is on the call is simply turned away.
local ASSIGN_SETTLE_MS = 3000

-- Same list client/witness.lua keeps: an extinguisher or a petrol can in
-- hand is not "armed".
local NOT_GUNFIRE = {
    [GetHashKey('WEAPON_FIREEXTINGUISHER')] = true,
    [GetHashKey('WEAPON_PETROLCAN')] = true,
    [GetHashKey('WEAPON_HAZARDCAN')] = true,
}

local RESOURCE = GetCurrentResourceName()

FenixInvestigate = {}

--- Is `pos` inside one of Config.Investigate.exemptZones (the Ammu-Nation
--- shooting ranges, by default)? Gunfire there is somebody's afternoon at
--- the range: client/witness.lua never calls it in, and nobody standing in
--- one is ever "spotted". Malformed entries are skipped, not fatal -- this
--- runs inside per-frame and per-tick loops.
function FenixInvestigate.inExemptZone(pos)
    local zones = cfg().exemptZones
    if type(zones) ~= 'table' or type(pos) ~= 'vector3' then return false end
    for _, zone in ipairs(zones) do
        if type(zone) == 'table' and type(zone.coords) == 'vector3'
            and #(pos - zone.coords) <= (tonumber(zone.radius) or 25.0)
        then
            return true
        end
    end
    return false
end

--- Would a wanted level set through this resource be refused for the local
--- player anyway? The same two conditions client.lua's SetWantedLevel
--- checks: wanted levels switched off (Config.Toggles.wantedLevels), or a
--- protected on-duty officer (Config.PoliceWantedProtection). Such a player
--- is never named as a suspect, and never "found" by their own unit.
function FenixInvestigate.wantedExempt()
    if type(Config.Toggles) == 'table' and Config.Toggles.wantedLevels == false then return true end
    if not Config.PoliceWantedProtection then return false end
    local ok, res = pcall(function() return exports[RESOURCE]:IsPlayerPoliceOfficer() end)
    return ok and res == true
end

--- Is looking for the call's suspects switched on? false keeps the unit to
--- looking around and clearing, as it always did.
local function suspectsEnabled()
    return cfg().findSuspects ~= false
end

--- The server ids in a suspect list off the wire, and nothing else.
local function suspectList(list)
    local out = {}
    if type(list) ~= 'table' then return out end
    for _, id in ipairs(list) do
        local n = tonumber(id)
        if n and n > 0 and n == math.floor(n) then
            out[#out + 1] = math.floor(n)
            if #out >= MAX_SUSPECTS then break end
        end
    end
    return out
end

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

--- The seat `ped` is sitting in, for getting them back into the same one.
local function seatOf(vehicle, ped)
    local seats = GetVehicleModelNumberOfSeats(GetEntityModel(vehicle)) or 2
    for seat = -1, seats - 2 do
        if GetPedInVehicleSeat(vehicle, seat) == ped then return seat end
    end
    return 0
end

--- Common tail for both paths below: register the unit, start its FSM, and
--- send it driving. vehicle/driver/peds/pedSeats are already-networked and
--- already-owned by this point in both callers.
local function beginInvestigating(vehNetID, vehicle, driver, peds, pedSeats, incidentData)
    local fsm = FenixFSM.new(UNIT_STATES, 'DRIVING_TO_SCENE')
    fsm.data.driver = driver
    fsm.data.incidentCoords = incidentData.coords

    units[vehNetID] = {
        vehicle = vehicle, peds = peds, pedSeats = pedSeats, fsm = fsm, incidentId = incidentData.id,
        suspects = suspectList(incidentData.suspects), assignedAt = GetGameTimer(),
    }

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

                -- Matched by net ID, not by list position: a passenger that
                -- wouldn't network is left out of passengerNetIDs, and every
                -- one after it would otherwise be filed under the wrong ped.
                local peds, pedSeats = { [driverNetID] = driver }, { [driverNetID] = -1 }
                local joined = {}
                for _, pedNetID in ipairs(passengerNetIDs or {}) do joined[pedNetID] = true end
                for _, p in ipairs(passengers or {}) do
                    local pedNetID = DoesEntityExist(p) and NetworkGetEntityIsNetworked(p) and PedToNet(p) or nil
                    if pedNetID and joined[pedNetID] then
                        peds[pedNetID] = p
                        pedSeats[pedNetID] = seatOf(veh, p)
                    elseif DoesEntityExist(p) then
                        -- Never joined the unit, and ambient.lua has already
                        -- let go of it: nothing else would ever delete it.
                        DeleteEntity(p)
                    end
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

-- unit.outcome, when set, goes with the release: 'NO_SUSPECT' for a unit
-- that looked and found nobody (shown in the server's /fenixincidents).
local function releaseIncident(unit, vehNetID)
    if unit.released then return end
    unit.released = true
    TriggerServerEvent('fenix-police:server:releaseIncidentUnit', unit.incidentId, vehNetID, unit.outcome)
end

local function deleteUnitEntities(vehNetID, unit)
    TriggerServerEvent('deleteSpawnedVehicle', vehNetID)
    for pedNetID in pairs(unit.peds) do
        TriggerServerEvent('deleteSpawnedPed', pedNetID)
    end
end

local function clearUnit(vehNetID)
    local unit = units[vehNetID]
    if not unit then return end

    releaseIncident(unit, vehNetID)
    deleteUnitEntities(vehNetID, unit)

    units[vehNetID] = nil
end

-------------------------------------------------------------------------------
-- Finding the shooter
-------------------------------------------------------------------------------

--- A listed suspect's ped, if this client has them in scope at all, and
--- whether it is the local player.
local function suspectPed(serverId)
    if serverId == GetPlayerServerId(PlayerId()) then return PlayerPedId(), true end
    local player = GetPlayerFromServerId(serverId)
    if player == -1 then return nil end
    local ped = GetPlayerPed(player)
    if ped == 0 or not DoesEntityExist(ped) then return nil end
    return ped, false
end

--- A gun in hand on foot, or a shot fired from anywhere -- a car window
--- included. A gun resting in a car's footwell isn't anything an officer
--- outside can see.
local function visiblyArmed(ped)
    if NOT_GUNFIRE[GetSelectedPedWeapon(ped)] then return false end
    if IsPedShooting(ped) then return true end
    return not IsPedInAnyVehicle(ped, false) and IsPedArmed(ped, 4)
end

--- The first listed suspect one of this unit's officers can see right now:
--- within spotRange of that officer, in their line of sight, visibly armed,
--- and not on a range. Returns the suspect's server id and whether it is
--- the local player, or nil.
local function spotSuspect(unit)
    local range = cfg().spotRange or 40.0
    for _, serverId in ipairs(unit.suspects) do
        local ped, isSelf = suspectPed(serverId)
        -- The local player is only looked for while not already wanted: a
        -- pursuit under way (or a stop, a surrender, an arrest) already owns
        -- them, and this unit starring them again or joining in would cut
        -- across it. Nor if they can't be starred at all.
        local eligible = ped ~= nil
            and not (isSelf and (GetPlayerWantedLevel(PlayerId()) > 0 or FenixInvestigate.wantedExempt()))
        if eligible and not IsPedDeadOrDying(ped, true) and visiblyArmed(ped) then
            local pos = GetEntityCoords(ped)
            if not FenixInvestigate.inExemptZone(pos) then
                for _, officer in pairs(unit.peds) do
                    if DoesEntityExist(officer) and not IsPedDeadOrDying(officer, true)
                        and #(GetEntityCoords(officer) - pos) <= range
                        and HasEntityClearLosToEntity(officer, ped, 17)
                    then
                        return serverId, isSelf
                    end
                end
            end
        end
    end
    return nil
end

--- Every living crew member who isn't in the car heads back to their own
--- seat. `onlyIdle` leaves anyone already on their way alone, so a repeat
--- call doesn't restart the walk.
local function boardCrew(unit, speed, onlyIdle)
    for pedNetID, ped in pairs(unit.peds) do
        if DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true) and not IsPedInVehicle(ped, unit.vehicle, false)
            and not (onlyIdle and GetScriptTaskStatus(ped, ENTER_TASK) ~= TASK_FINISHED)
        then
            ClearPedTasks(ped)
            TaskEnterVehicle(ped, unit.vehicle, BOARD_TIMEOUT_MS, unit.pedSeats[pedNetID] or 0, speed, 1, 0)
        end
    end
end

--- Takes the unit out of this file and gives it to the pursuit system
--- (client.lua's PromoteAmbientUnit), the same way an ambient patrol joins a
--- chase. Out of `units` first: the promotion waits seconds on a server
--- handshake, and nothing here may task these peds while the pursuit
--- system is taking them on -- or after.
local function handOffToPursuit(vehNetID, unit)
    local vehicle, driver = unit.vehicle, unit.fsm.data.driver
    units[vehNetID] = nil
    releaseIncident(unit, vehNetID)

    local passengers = {}
    for pedNetID, ped in pairs(unit.peds) do
        if ped ~= driver then
            if DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true) then
                passengers[#passengers + 1] = ped
            else
                -- A fallen officer doesn't join the pursuit unit, and with
                -- this file no longer tracking the unit nothing else would
                -- ever delete them.
                TriggerServerEvent('deleteSpawnedPed', pedNetID)
                unit.peds[pedNetID] = nil
            end
        end
    end

    CreateThread(function()
        -- Off the tick's walk over `units` before anything here can put
        -- this unit back into it.
        Wait(0)
        local ok, promoted = pcall(PromoteAmbientUnit, vehicle, driver, passengers)
        if ok and promoted then
            dbg(('unit %d joined the pursuit'):format(vehNetID))
            return
        end
        if not ok then print('[fenix-police:investigate] hand-off error:', promoted) end

        -- The pursuit system didn't take it (the handshake failed, or the
        -- wanted level is already gone): back here, to drive off and clear
        -- like any other call.
        dbg(('unit %d could not join the pursuit, clearing'):format(vehNetID))
        if DoesEntityExist(vehicle) then
            unit.fsm:transition('CLEARING')
            units[vehNetID] = unit
        else
            deleteUnitEntities(vehNetID, unit)
        end
    end)
end

--- Looks for the call's suspects and acts on a sighting. Returns true once
--- the unit has moved on because of one; the caller stops this tick there.
local function watchForSuspects(vehNetID, unit)
    local fsm = unit.fsm
    if not suspectsEnabled() or fsm.data.spotted or #unit.suspects == 0 then return false end
    if GetGameTimer() - unit.assignedAt < ASSIGN_SETTLE_MS then return false end

    local suspect, isSelf = spotSuspect(unit)
    if not suspect then return false end

    -- Once per unit, whatever the server makes of it.
    fsm.data.spotted = suspect
    TriggerServerEvent('fenix-police:server:investigationSpotted', unit.incidentId, vehNetID, suspect)
    boardCrew(unit, 2.0)

    if isSelf and type(PromoteAmbientUnit) == 'function' then
        dbg(('unit %d saw its own player armed, waiting on the wanted level to join the pursuit'):format(vehNetID))
        fsm:transition('HANDING_OFF')
    else
        -- Another player: the stars land on their own client, whose own
        -- pursuit response takes it from there. This unit has done its part.
        dbg(('unit %d saw suspect %d armed, clearing'):format(vehNetID, suspect))
        fsm:transition('CLEARING')
    end
    return true
end

-- The server adds a suspect to a call already being worked when one turns
-- up in a later report (server/dispatch.lua's createIncident). Applies to a
-- unit on that call, or one still on its way to being spawned for it.
RegisterNetEvent('fenix-police:client:investigationSuspects')
AddEventHandler('fenix-police:client:investigationSuspects', function(incidentId, suspects)
    local list = suspectList(suspects)
    for _, unit in pairs(units) do
        if unit.incidentId == incidentId then unit.suspects = list end
    end
    for _, request in pairs(pendingRequests) do
        if type(request.data) == 'table' and request.data.id == incidentId then
            request.data.suspects = list
        end
    end
end)

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

                        -- Close enough to see the scene: the crew watches
                        -- for the call's suspects from the car on the way in.
                        if dist <= (cfg().watchFromDistance or 80.0) and watchForSuspects(vehNetID, unit) then
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
                        if watchForSuspects(vehNetID, unit) then return end

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
                            if suspectsEnabled() then
                                unit.outcome = 'NO_SUSPECT'
                                dbg(('unit %d found nobody on #%s'):format(vehNetID, tostring(unit.incidentId)))
                            end
                            if officer then
                                ClearPedTasks(officer)
                                TaskEnterVehicle(officer, vehicle, BOARD_TIMEOUT_MS, seat, 1.0, 1, 0)
                            end
                            fsm:transition('CLEARING')
                        end
                    elseif fsm:is('HANDING_OFF') then
                        -- Two things before the pursuit system can take the
                        -- unit: the stars the server sends back for the
                        -- sighting, and a driver behind the wheel --
                        -- PromoteAmbientUnit takes a car with its driver in
                        -- it, and a single-officer unit's driver is the one
                        -- who got out to look around.
                        local wanted = GetPlayerWantedLevel(PlayerId()) > 0
                        if wanted and not fsm.data.wantedAt then
                            fsm.data.wantedAt = GetGameTimer()
                        end

                        if wanted and (fsm:msSince('wantedAt') or 0) >= HANDOFF_SETTLE_MS
                            and GetPedInVehicleSeat(vehicle, -1) == driver
                        then
                            handOffToPursuit(vehNetID, unit)
                        elseif fsm:timeInState() >= HANDOFF_TIMEOUT_MS then
                            dbg(('unit %d never got to join the pursuit, clearing'):format(vehNetID))
                            fsm:transition('CLEARING')
                        else
                            boardCrew(unit, 2.0, true)
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
        print(('  veh %d: incident #%s state=%s (%dms) suspects=[%s]%s'):format(
            vehNetID, tostring(unit.incidentId), unit.fsm.state, unit.fsm:timeInState(),
            table.concat(unit.suspects, ','),
            unit.fsm.data.spotted and (' spotted %d'):format(unit.fsm.data.spotted) or ''))
    end
end, false)
