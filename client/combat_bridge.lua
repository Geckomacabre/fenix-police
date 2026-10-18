-- Applies ped combat/AI attributes on behalf of server/server.lua. Natives like
-- SET_PED_COMBAT_ATTRIBUTES, SET_PED_FLEE_ATTRIBUTES, SET_PED_ACCURACY,
-- SET_PED_FIRING_PATTERN, SET_PED_RELATIONSHIP_GROUP_HASH, SET_DRIVER_ABILITY/
-- AGGRESSIVENESS and the TASK_* natives don't exist in the server's Lua
-- environment, so the server builds a profile table and fires this event
-- instead of calling them directly. Broadcast to every client; whichever one
-- has the ped streamed in applies it, the rest just no-op.
--
-- Also home to ApplyChaseTactics, the wanted-level chase tactics both that
-- profile and client.lua's own chase loop put on a TaskVehicleChase driver.

-- Every behaviour SET_TASK_VEHICLE_CHASE_BEHAVIOR_FLAG documents: 1 aggressive
-- ramming, 2 ram attempts, 8 boxing in with a bit of PIT, 16 ramming (a little
-- gentler than 1 and 2), 32 stay back with no tactical contact, convoy-like.
local CHASE_FLAGS = { 1, 2, 8, 16, 32 }

-- Config.Driving.chaseTactics as shipped, for a config that doesn't have it.
local DEFAULT_CHASE_TACTICS = {
    [1] = { 32 },
    [2] = { 32 },
    [3] = { 8 },
    [4] = { 8, 16 },
    [5] = { 8, 2 },
}

--- The tactics entry for this wanted level: its own, else the nearest level
--- below it that has one, else boxing (8), the one tactic every chase used to
--- get. Searched by key rather than by counting down, so a wanted level of any
--- size costs one pass over the table.
local function chaseTacticsFor(tactics, wantedLevel)
    local level = tonumber(wantedLevel) or 0
    local best
    for key in pairs(tactics) do
        if type(key) == 'number' and key <= level and (not best or key > best) then
            best = key
        end
    end

    local entry = best and tactics[best]
    if type(entry) == 'number' then return { entry } end
    if type(entry) == 'table' then return entry end
    return { 8 }
end

--- How hard a TaskVehicleChase driver may make contact, by wanted level
--- (Config.Driving.chaseTactics). Every chase used to get flag 8 -- boxing in
--- and PIT -- whatever the wanted level, so a one-star speeder was boxed in at
--- point blank exactly like a five-star cop killer. Every known flag is set
--- explicitly on or off, not just the wanted ones switched on: this runs
--- again on a chase already under way when the wanted level moves, and a
--- flag left over from the old level would otherwise stay set.
---
--- Acts on the ped's running chase task, so call it straight after
--- TaskVehicleChase. Defined here because this file loads before client.lua
--- and has a chase of its own to set up (the server's vehicleChase profile).
--- @param ped number the chasing driver
--- @param wantedLevel number the suspect's wanted level
function ApplyChaseTactics(ped, wantedLevel)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return end

    local tactics = (Config.Driving or {}).chaseTactics
    if tactics == false or (type(tactics) == 'table' and tactics.enabled == false) then
        -- The old fixed tactic at every level.
        SetTaskVehicleChaseBehaviorFlag(ped, 8, true)
        return
    end
    if type(tactics) ~= 'table' then tactics = DEFAULT_CHASE_TACTICS end

    local wanted = {}
    for _, flag in ipairs(chaseTacticsFor(tactics, wantedLevel)) do
        flag = tonumber(flag)
        if flag then wanted[flag] = true end
    end
    for _, flag in ipairs(CHASE_FLAGS) do
        SetTaskVehicleChaseBehaviorFlag(ped, flag, wanted[flag] == true)
    end
end

--- The ped of the player with this server id, or 0 when that player isn't in
--- this client's scope. GetPlayerFromServerId answers -1 for an out-of-scope
--- player, and GetPlayerPed(-1) is THIS client's own ped -- so without the
--- check, the client applying the profile tasked units against its own player
--- instead of the intended target.
local function targetPedOf(serverId)
    serverId = tonumber(serverId)
    if not serverId then return 0 end
    local player = GetPlayerFromServerId(serverId)
    if player == -1 then return 0 end
    return GetPlayerPed(player)
end

RegisterNetEvent('fenix-police:client:applyCombatProfile', function(pedNetID, profile)
    if type(profile) ~= 'table' then return end
    -- Broadcast to every client, most of which don't have this ped at all:
    -- the silent existence test, not a resolve that warns on every miss.
    pedNetID = tonumber(pedNetID)
    if not pedNetID or not NetworkDoesEntityExistWithNetworkId(pedNetID) then return end
    local ped = NetworkGetEntityFromNetworkId(pedNetID)
    if not DoesEntityExist(ped) then return end

    if profile.accuracy then
        SetPedAccuracy(ped, profile.accuracy)
    end
    if profile.firingPattern then
        SetPedFiringPattern(ped, GetHashKey(profile.firingPattern))
    end
    if profile.shootRate then
        SetPedShootRate(ped, profile.shootRate)
    end
    if profile.combatAbility then
        SetPedCombatAbility(ped, profile.combatAbility)
    end
    if profile.combatAttributes then
        for _, entry in ipairs(profile.combatAttributes) do
            SetPedCombatAttributes(ped, entry[1], entry[2])
        end
    end
    if profile.relationshipGroup then
        SetPedRelationshipGroupHash(ped, GetHashKey(profile.relationshipGroup))
    end
    if profile.fleeAttributes then
        SetPedFleeAttributes(ped, profile.fleeAttributes[1], profile.fleeAttributes[2])
    end
    if profile.driverAbility then
        SetDriverAbility(ped, profile.driverAbility)
    end
    if profile.driverAggressiveness then
        SetDriverAggressiveness(ped, profile.driverAggressiveness)
    end

    if profile.heliChaseTarget then
        local targetPed = targetPedOf(profile.heliChaseTarget)
        if targetPed ~= 0 and DoesEntityExist(targetPed) then
            TaskHeliChase(ped, targetPed, 0.0, 0.0, 120.0)
        end
    end
    if profile.planeChaseTarget then
        local targetPed = targetPedOf(profile.planeChaseTarget)
        if targetPed ~= 0 and DoesEntityExist(targetPed) then
            TaskPlaneChase(ped, targetPed, 20.0, 20.0, 150.0)
        end
    end
    if profile.combatTarget then
        local targetPed = targetPedOf(profile.combatTarget)
        if targetPed ~= 0 and DoesEntityExist(targetPed) then
            TaskCombatPed(ped, targetPed, 0, 16)
        end
    end

    if profile.vehicleDriveTo then
        local vehicle = GetVehiclePedIsIn(ped, false)
        if vehicle ~= 0 then
            local v = profile.vehicleDriveTo
            TaskVehicleDriveToCoord(ped, vehicle, v.x, v.y, v.z, v.speed, 1, v.vehicleModelHash, v.drivingStyle, v.stopRange, true)
            SetDriveTaskDrivingStyle(ped, v.drivingStyle)
        end
    end
    if profile.vehicleChase then
        local vehicle = GetVehiclePedIsIn(ped, false)
        local targetPed = targetPedOf(profile.vehicleChase)
        if vehicle ~= 0 and targetPed ~= 0 and DoesEntityExist(targetPed) then
            TaskVehicleChase(ped, targetPed)
            -- The server says which wanted level it is chasing for when it
            -- knows; a middling three otherwise.
            ApplyChaseTactics(ped, tonumber(profile.wantedLevel) or 3)
        end
    end
end)
