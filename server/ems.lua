-- EMS ground-unit spawn authorization.
--
-- Mirrors spawnPoliceUnitNet's client-creates/server-authorises pattern
-- (server/server.lua) rather than inventing a new one: the server issues a
-- single-use FenixGuard ticket and tells the requesting client what to
-- build; the client creates the vehicle/peds locally and quotes the ticket
-- back via the existing fenix-police:registerSpawnedUnit handler
-- (server/guard.lua), which is what actually grants ownership. No new
-- ownership mechanism needed -- EMS units are just another allowlisted kind
-- of unit as far as FenixGuard is concerned (see the buildAllowlist
-- addition in server/guard.lua).
--
-- requestId is an opaque value the client made up and is echoed back
-- unchanged, so a client juggling multiple in-flight EMS responses (one per
-- incident) can tell which spawn response belongs to which incident.

RegisterNetEvent('fenix-police:server:spawnEmsUnit')
AddEventHandler('fenix-police:server:spawnEmsUnit', function(requestId, spawnPoint, spawnHeading)
    local src = source
    if not (Config.EMS or {}).enabled then return end
    if not FenixGuard.allow(src, 'spawn') then return end

    if type(spawnPoint) ~= 'vector3' then return end

    local emsCfg = Config.EMS or {}
    local ticket = FenixGuard.issueTicket(src)

    TriggerClientEvent('fenix-police:spawnEmsUnitClient', src, requestId, {
        vehicle = emsCfg.vehicle or 'ambulance',
        peds = emsCfg.peds or { 's_m_m_paramedic_01', 's_m_m_paramedic_01' },
    }, spawnPoint, spawnHeading, ticket)
end)
