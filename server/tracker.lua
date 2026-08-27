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
    same set client/tracker.lua tracks from), and the requesting player is the
    one currently in its driver's seat.
]]

local function cfg() return Config.Tracker or {} end

RegisterServerEvent('fenix-police:removeTracker')
AddEventHandler('fenix-police:removeTracker', function(netId)
    local src = source
    if not cfg().enabled then return end
    if not FenixGuard.allow(src, 'tracker', 20) then return end

    netId = tonumber(netId)
    local vehicle = netId and NetworkGetEntityFromNetworkId(netId)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return end

    if GetEntityType(vehicle) ~= 2 then
        FenixGuard.refuse(src, 'tracker removal', 'entity is not a vehicle')
        return
    end

    if not FenixGuard.isAllowedVehicleModel(GetEntityModel(vehicle)) then
        FenixGuard.refuse(src, 'tracker removal', 'not a dispatch vehicle model')
        return
    end

    local driverPed = GetPedInVehicleSeat(vehicle, -1)
    if driverPed ~= GetPlayerPed(src) then
        FenixGuard.refuse(src, 'tracker removal', 'requester is not this vehicle\'s driver')
        return
    end

    if cfg().removeTool and cfg().removeTool ~= '' then
        local ok, count = pcall(function() return exports.ox_inventory:Search(src, 'count', cfg().removeTool) end)
        if not ok or not count or count < 1 then
            FenixGuard.refuse(src, 'tracker removal', 'missing required tool')
            return
        end
    end

    Entity(vehicle).state:set('trackerRemoved', true, true)
end)
