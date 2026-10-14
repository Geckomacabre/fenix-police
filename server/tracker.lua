--[[
    server/tracker.lua

    Validates and applies "GPS tracker removed" for a vehicle. The client
    already gated the attempt behind a tool check, a not-currently-seen
    check and a progress bar — none of that is trusted here, because none of
    it can be.

    This deliberately does NOT reuse FenixGuard.resolve(): resolve()'s first
    layer refuses any vehicle a player is currently sitting in, which exists
    to stop player A deleting/unlocking/rearming a vehicle player B is using.
    Here the requesting player removing a tracker from the car THEY are
    driving is the entire point, so that layer would refuse the one case this
    is for. What's checked instead: the vehicle exists, is a real vehicle, is
    one of this resource's own dispatch models (FenixGuard's allowlist — the
    same set client/tracker.lua tracks from), and nobody else is driving it:
    the requester is in its driver's seat, or the seat is empty and the
    requester is standing at the car.

    Every outcome is sent back (fenix-police:client:trackerRemoveResult) so
    the client can say why twelve seconds of progress bar did nothing.
]]

local function cfg() return Config.Tracker or {} end

-- How far from the vehicle's centre the requester may stand. The removal is
-- an on-foot interaction (ox_target, 2 m reach), and the end of a long van is
-- a good 3.5 m from its centre.
local BESIDE_VEHICLE = 6.0

local function reply(src, ok, reason)
    TriggerClientEvent('fenix-police:client:trackerRemoveResult', src, ok, reason)
end

RegisterServerEvent('fenix-police:removeTracker')
AddEventHandler('fenix-police:removeTracker', function(netId)
    local src = source
    if not cfg().enabled then return end
    if not FenixGuard.allow(src, 'tracker', 20) then return end

    netId = tonumber(netId)
    local vehicle = netId and netId ~= 0 and NetworkGetEntityFromNetworkId(netId)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        return reply(src, false, 'There is no tracker on this vehicle.')
    end

    if GetEntityType(vehicle) ~= 2 then
        FenixGuard.refuse(src, 'tracker removal', 'entity is not a vehicle')
        return reply(src, false, 'There is no tracker on this vehicle.')
    end

    if not FenixGuard.isAllowedVehicleModel(GetEntityModel(vehicle)) then
        FenixGuard.refuse(src, 'tracker removal', 'not a dispatch vehicle model')
        return reply(src, false, 'There is no tracker on this vehicle.')
    end

    -- The interaction is done on foot, so the requester is normally standing
    -- beside the car with the driver's seat empty; insisting they be in that
    -- seat would refuse every removal the moment the progress bar finishes.
    local ped = GetPlayerPed(src)
    local driverPed = GetPedInVehicleSeat(vehicle, -1)
    local driving = ped ~= 0 and driverPed == ped
    local beside = ped ~= 0 and driverPed == 0
        and #(GetEntityCoords(ped) - GetEntityCoords(vehicle)) <= BESIDE_VEHICLE
    if not driving and not beside then
        FenixGuard.refuse(src, 'tracker removal', 'requester is not at this vehicle, or someone else is driving it')
        return reply(src, false, 'You need to be at the vehicle, with nobody else driving it.')
    end

    if cfg().removeTool and cfg().removeTool ~= '' then
        local ok, count = pcall(function() return exports.ox_inventory:Search(src, 'count', cfg().removeTool) end)
        if not ok or not count or count < 1 then
            FenixGuard.refuse(src, 'tracker removal', 'missing required tool')
            return reply(src, false, 'You need the right tool for this.')
        end
    end

    Entity(vehicle).state:set('trackerRemoved', true, true)
    reply(src, true)
end)
