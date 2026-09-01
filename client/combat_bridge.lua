-- Applies ped combat/AI attributes on behalf of server/server.lua. Natives like
-- SET_PED_COMBAT_ATTRIBUTES, SET_PED_FLEE_ATTRIBUTES, SET_PED_ACCURACY,
-- SET_PED_FIRING_PATTERN, SET_PED_RELATIONSHIP_GROUP_HASH, SET_DRIVER_ABILITY/
-- AGGRESSIVENESS and the TASK_* natives don't exist in the server's Lua
-- environment, so the server builds a profile table and fires this event
-- instead of calling them directly. Broadcast to every client; whichever one
-- has the ped streamed in applies it, the rest just no-op.
RegisterNetEvent('fenix-police:client:applyCombatProfile', function(pedNetID, profile)
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
        local targetPed = GetPlayerPed(GetPlayerFromServerId(profile.heliChaseTarget))
        if DoesEntityExist(targetPed) then
            TaskHeliChase(ped, targetPed, 0.0, 0.0, 120.0)
        end
    end
    if profile.planeChaseTarget then
        local targetPed = GetPlayerPed(GetPlayerFromServerId(profile.planeChaseTarget))
        if DoesEntityExist(targetPed) then
            TaskPlaneChase(ped, targetPed, 20.0, 20.0, 150.0)
        end
    end
    if profile.combatTarget then
        local targetPed = GetPlayerPed(GetPlayerFromServerId(profile.combatTarget))
        if DoesEntityExist(targetPed) then
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
        local targetPed = GetPlayerPed(GetPlayerFromServerId(profile.vehicleChase))
        if vehicle ~= 0 and DoesEntityExist(targetPed) then
            TaskVehicleChase(ped, targetPed)
            SetTaskVehicleChaseBehaviorFlag(ped, 8, true)
        end
    end
end)
