-- Live unit position registry -- the prerequisite server/dispatch.lua's
-- header comment says real nearest-unit dispatch needs.
--
-- Ground/heli/air police units are created and tasked entirely client-side
-- (see server/guard.lua's own header). The server previously had no idea
-- where any of them were once spawned, only who owned the net ID. This adds
-- exactly one thing: a periodic, low-frequency "here's where my units are"
-- report from each client, so FenixDispatch can pick an actual nearest unit
-- instead of only picking a nearest PLAYER (server/dispatch.lua's
-- nearestPlayer, used for EMS/fire hosting).
--
-- Deliberately NOT a source of truth for anything else -- ownership is
-- still FenixGuard's job, deletion is still the existing delete* events.
-- This is read-only bookkeeping: stale entries just age out.

FenixUnitRegistry = {}

local units = {} -- vehNetID -> { src, kind, role, coords, updatedAt }

local function cfg()
    return Config.UnitRegistry or {}
end

RegisterNetEvent('fenix-police:server:reportUnitPositions')
AddEventHandler('fenix-police:server:reportUnitPositions', function(reports)
    local src = source
    if not (cfg().enabled) then return end
    if not FenixGuard.allow(src, 'unit_report', 30) then return end
    if type(reports) ~= 'table' then return end

    local now = GetGameTimer()
    local cap = cfg().maxReportsPerBatch or 20

    local n = 0
    for vehNetID, report in pairs(reports) do
        n = n + 1
        if n > cap then break end

        if type(vehNetID) == 'number' and type(report) == 'table' and type(report.coords) == 'vector3' then
            units[vehNetID] = {
                src = src,
                kind = report.kind, -- 'ground' | 'heli' | 'air'
                role = report.role, -- e.g. 'VehicleChase', 'Standby' -- informational only
                coords = report.coords,
                updatedAt = now,
            }
        end
    end
end)

function FenixUnitRegistry.all()
    return units
end

-- kind: optional filter ('ground'|'heli'|'air'), nil = any.
function FenixUnitRegistry.nearest(coords, maxRadius, kind)
    local best, bestId, bestDist = nil, nil, maxRadius
    for vehNetID, unit in pairs(units) do
        if not kind or unit.kind == kind then
            local dist = #(unit.coords - coords)
            if dist <= bestDist then
                best, bestId, bestDist = unit, vehNetID, dist
            end
        end
    end
    return bestId, best, bestDist
end

CreateThread(function()
    while true do
        Wait(15000)
        local now = GetGameTimer()
        local maxAgeMs = cfg().staleAfterMs or 20000
        for vehNetID, unit in pairs(units) do
            if now - unit.updatedAt > maxAgeMs then
                units[vehNetID] = nil
            end
        end
    end
end)

RegisterCommand('fenixunits', function(source)
    if source ~= 0 then return end

    local count = 0
    for vehNetID, unit in pairs(units) do
        count = count + 1
        print(('veh %d: kind=%-6s role=%-14s owner=%s age=%dms at %s')
            :format(vehNetID, tostring(unit.kind), tostring(unit.role),
                GetPlayerName(unit.src) or tostring(unit.src),
                GetGameTimer() - unit.updatedAt, tostring(unit.coords)))
    end

    if count == 0 then
        print('[fenix-police] no reported unit positions (Config.UnitRegistry.enabled = ' ..
            tostring(cfg().enabled == true) .. ')')
    end
end, true)
