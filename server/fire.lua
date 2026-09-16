-- Fire: civilian fire reports + fire-unit spawn authorization.
--
-- Same two responsibilities server/ems.lua and part of server/dispatch.lua
-- split across two files, combined here since fire has less surface area
-- than EMS: (1) accept "there's a fire here" reports and turn them into a
-- FIRE incident, (2) authorise the client-side spawn of a fire truck +
-- crew, the same ticket handshake every other unit type in this resource
-- uses (server/guard.lua).

RegisterNetEvent('fenix-police:server:reportFire')
AddEventHandler('fenix-police:server:reportFire', function(coords)
    local src = source
    if not src or src == 0 then return end
    if not (Config.Dispatch or {}).enabled then return end

    local watchCfg = Config.FireWatch or {}
    if not FenixGuard.allow(src, 'witness_fire', watchCfg.reportsPerMinute or 6) then return end
    if type(coords) ~= 'vector3' then return end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end

    local maxDistance = watchCfg.maxReportDistance or 80.0
    if #(GetEntityCoords(ped) - coords) > maxDistance then
        FenixGuard.refuse(src, 'fire report', 'reported coordinates are too far from the caller')
        return
    end

    FenixDispatch.createIncident('FIRE', coords, nil, {
        applyWanted = false,
        witnesses = { src },
        dedupeRadius = watchCfg.dedupeRadius or 50.0,
        dedupeWindowMs = watchCfg.dedupeWindowMs or 30000,
    })
end)

RegisterNetEvent('fenix-police:server:spawnFireUnit')
AddEventHandler('fenix-police:server:spawnFireUnit', function(requestId, spawnPoint, spawnHeading)
    local src = source
    if not (Config.Fire or {}).enabled then return end
    if not FenixGuard.allow(src, 'spawn') then return end
    if type(spawnPoint) ~= 'vector3' then return end

    local fireCfg = Config.Fire or {}
    local ticket = FenixGuard.issueTicket(src)

    TriggerClientEvent('fenix-police:spawnFireUnitClient', src, requestId, {
        vehicle = fireCfg.vehicle or 'firetruk',
        peds = fireCfg.peds or { 's_m_y_fireman_01', 's_m_y_fireman_01' },
    }, spawnPoint, spawnHeading, ticket)
end)
