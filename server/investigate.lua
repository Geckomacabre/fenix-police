-- Police investigation-unit spawn authorization.
--
-- Closes a real gap, not a future phase: client/witness.lua reports gunfire
-- with no known suspect, so FenixDispatch.createIncident is called with
-- applyWanted = false (there's no one to star) -- which meant, until this
-- file, that a witnessed SHOOTING incident did nothing visible at all. A
-- patrol unit responding to LOOK AROUND rather than chase/arrest anyone is
-- the correct behavior for "someone reported gunfire, no suspect in sight"
-- (design spec section 9), and is a different job from every existing
-- police code path in this resource, all of which assume a wanted player to
-- chase. Same ticket/spawn pattern as server/ems.lua and server/fire.lua.

RegisterNetEvent('fenix-police:server:spawnInvestigateUnit')
AddEventHandler('fenix-police:server:spawnInvestigateUnit', function(requestId, spawnPoint, spawnHeading)
    local src = source
    if not (Config.Investigate or {}).enabled then return end
    if not FenixGuard.allow(src, 'spawn') then return end
    if type(spawnPoint) ~= 'vector3' then return end

    local invCfg = Config.Investigate or {}
    local ticket = FenixGuard.issueTicket(src)

    TriggerClientEvent('fenix-police:spawnInvestigateUnitClient', src, requestId, {
        vehicle = invCfg.vehicle or 'onx_polbuff',
        vehicleFallback = invCfg.vehicleFallback or 'police',
        peds = invCfg.peds or { 's_m_y_cop_01' },
    }, spawnPoint, spawnHeading, ticket)
end)

-- Deliberately a separate ticket flow from server.lua's own
-- fenix-police:server:promoteAmbientUnit (used for pursuit promotion): the
-- client side (client.lua's PromoteAmbientUnitForInvestigation, appended at
-- the end of that file) needs its own independent ticket-await so it can
-- never race the existing pursuit-promotion path's shared single-slot
-- ticket variables.
RegisterNetEvent('fenix-police:server:promoteAmbientUnitForInvestigation')
AddEventHandler('fenix-police:server:promoteAmbientUnitForInvestigation', function()
    local src = source
    if not (Config.Investigate or {}).enabled then return end
    if not FenixGuard.allow(src, 'spawn') then return end

    local ticket = FenixGuard.issueTicket(src)
    TriggerClientEvent('fenix-police:promoteAmbientUnitForInvestigationTicket', src, ticket)
end)
