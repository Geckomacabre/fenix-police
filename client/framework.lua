-- [Upstate Mafia] Optional framework glue.
--
-- This resource runs standalone: no framework has to be installed for it to
-- work. If qb-core or qbx_core (which also provides 'qb-core') happens to be
-- running, notifications, the on-duty job check, and vehicle lookups use it
-- for a more integrated feel. If not, every one of those falls back to a
-- plain GTA/FiveM native, so nothing here ever errors or silently no-ops for
-- want of a framework.
--
-- Loaded first among the client scripts (see fxmanifest.lua) since every
-- other file that used to reach for QBCore directly now goes through
-- FenixFramework instead.
FenixFramework = {}

local core = nil

local function tryGetCore()
    for _, res in ipairs({ 'qbx_core', 'qb-core' }) do
        if GetResourceState(res) == 'started' then
            local ok, obj = pcall(function() return exports[res]:GetCoreObject() end)
            if ok and obj then return obj end
        end
    end
    return nil
end

CreateThread(function()
    core = tryGetCore()
end)

-- Re-fetch on qb-core/qbx_core restart -- a stale reference from before the
-- restart throws "Execution of function reference in script host failed" on
-- every subsequent call into it, forever, since nothing else here would ever
-- know to ask again.
AddEventHandler('onClientResourceStart', function(resourceName)
    if resourceName == 'qb-core' or resourceName == 'qbx_core' then
        core = tryGetCore()
    end
end)

AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName == 'qb-core' or resourceName == 'qbx_core' then
        core = nil
    end
end)

function FenixFramework.HasFramework()
    return core ~= nil
end

--- Best-effort notification. Prefers qb-core/qbx_core (matches the RP feel
--- players already expect on those servers), then ox_lib (already a hard
--- dependency of this resource), then a native GTA feed message so a
--- standalone server with neither still gets the text on screen.
function FenixFramework.Notify(msg, notifyType, duration)
    if core and core.Functions and core.Functions.Notify then
        local ok = pcall(function() core.Functions.Notify(msg, notifyType, duration) end)
        if ok then return end
    end

    if GetResourceState('ox_lib') == 'started' then
        local ok = pcall(function()
            lib.notify({
                description = msg,
                type = (notifyType == 'police' or notifyType == 'primary') and 'inform' or notifyType,
                duration = duration or 5000
            })
        end)
        if ok then return end
    end

    BeginTextCommandThefeed('STRING')
    AddTextComponentSubstringPlayerName(msg)
    EndTextCommandThefeed('CHAR_DEFAULT', true, true)
end

--- Raw framework player data (job, metadata, ...), or nil standalone.
function FenixFramework.GetPlayerData()
    if not (core and core.Functions and core.Functions.GetPlayerData) then return nil end
    local ok, pd = pcall(function() return core.Functions.GetPlayerData() end)
    if ok then return pd end
    return nil
end

--- Nearest vehicle to `coords` within `maxDistance`, or nil.
--- Uses qb-core/qbx_core's own call when present (matches its own
--- entity-pool filtering), otherwise walks the native vehicle pool.
function FenixFramework.GetClosestVehicle(coords, maxDistance)
    maxDistance = maxDistance or 100.0

    if core and core.Functions and core.Functions.GetClosestVehicle then
        local ok, veh = pcall(function() return core.Functions.GetClosestVehicle(coords, maxDistance, false) end)
        if ok and veh and veh ~= 0 then return veh end
    end

    local closest, closestDist = nil, maxDistance
    for _, veh in ipairs(GetGamePool('CVehicle')) do
        local dist = #(coords - GetEntityCoords(veh))
        if dist < closestDist then
            closest, closestDist = veh, dist
        end
    end
    return closest
end

--- Every vehicle entity handle currently loaded client-side.
function FenixFramework.GetVehicles()
    if core and core.Functions and core.Functions.GetVehicles then
        local ok, vehs = pcall(function() return core.Functions.GetVehicles() end)
        if ok and vehs then return vehs end
    end
    return GetGamePool('CVehicle')
end
