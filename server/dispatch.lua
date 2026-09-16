-- Dispatch reasoning: turns an incident into "who gets told what."
--
-- HONESTY NOTE, read before extending this file: the server has no registry
-- of individual unit *positions*. Ground/heli/air units today are spawned
-- and tasked entirely client-side, per observing player (client.lua's
-- maintainPoliceUnits), and only their net IDs + owning player are known
-- server-side (server/guard.lua's `owned` table has no coords). That means
-- true "nearest unit" / "unit workload" selection across a shared pool of
-- units is NOT implementable yet -- doing it anyway with fake data would be
-- exactly the "scripted fake AI" the design spec warns against (teleporting
-- knowledge instead of real information flow).
--
-- What IS implementable now, and what this file actually does:
--   1. Own the incident lifecycle via FenixIncident (server/incident.lua).
--   2. Decide which AGENCY TYPES an incident needs (police/ems/fire) from
--      config, independent of wanted-level logic.
--   3. Drive the existing, working per-player wanted-level pipeline for the
--      police case, so nothing currently working changes behavior.
--   4. Fire a stub event for EMS/fire so those (not yet built) subsystems
--      have one real integration point to attach to instead of everyone
--      reinventing incident creation later.
--
-- A real nearest-unit dispatcher needs client units to report position via
-- a lightweight periodic net event (or a state bag) into a server-side unit
-- registry first. That is a prerequisite for Phase 3/9 (multi-role response,
-- cross-agency coordination), not something to fake here.

FenixDispatch = {}

local function cfg()
    return Config.Dispatch or {}
end

local function dbg(...)
    if cfg().debug then
        print('[fenix-police:dispatch]', ...)
    end
end

-- Which agencies a given incident type calls for. Configurable so a server
-- can add its own incident types without touching this file.
local function agenciesFor(incidentType)
    local map = cfg().unitsNeeded or {}
    return map[incidentType] or { 'police' }
end

-- Picks a single player to "host" a non-police unit response (EMS/fire).
-- The server can't track where the AI units it spawns end up (see the file
-- header), but it CAN see where every connected player ped is right now --
-- that's a real, current position, not stale unit tracking. Handing the
-- response to the nearest player's client is what stops a naive broadcast
-- from spawning one ambulance per nearby player for the same call.
local function nearestPlayer(coords, maxRadius)
    local best, bestDist = nil, maxRadius
    for _, playerId in ipairs(GetPlayers()) do
        local ped = GetPlayerPed(playerId)
        if ped and ped ~= 0 then
            local dist = #(GetEntityCoords(ped) - coords)
            if dist <= bestDist then
                best, bestDist = playerId, dist
            end
        end
    end
    return best
end

-- Severity -> wanted level, for incident types that should also raise stars
-- on nearby players (the legacy behavior fenix:server:trigger provided).
-- Only used when the incident actually calls for a police response AND a
-- severity->wanted mapping is configured; a pure EMS/fire call does not
-- touch wanted levels at all.
local function severityToWanted(severity)
    local map = cfg().severityToWanted or { 1, 1, 2, 3, 5 }
    return map[math.max(1, math.min(#map, severity))] or 1
end

-- incidentType: string, e.g. 'SHOOTING', 'ROBBERY', 'MEDICAL', 'FIRE'.
-- coords: vector3, where the incident is.
-- severity: 1-5, defaults to config per-type value or 1.
-- opts: see server/incident.lua FenixIncident.create, plus
--       opts.applyWanted (bool, default true for police-agency incidents)
--       opts.wantedRadius (default 10.0)
--       opts.directWanted (number, 0-5) -- bypasses severityToWanted and
--         applies this wanted level exactly. Used by callers (like the
--         legacy fenix:server:trigger handler) that already computed a
--         final wanted level rather than an abstract severity.
-- Multiple witnesses (or multiple clients standing near the same event) can
-- each try to report the same real-world incident independently. Rather
-- than creating one incident per report, fold a new report into an existing
-- unresolved incident of the same type nearby -- this is also what makes
-- "has the incident already been resolved" (design spec section 5) a real
-- check instead of a TODO.
local function findDuplicate(incidentType, coords, radius, windowMs)
    local now = GetGameTimer()
    for _, incident in pairs(FenixIncident.all()) do
        if incident.type == incidentType
            and incident.status ~= 'RESOLVED' and incident.status ~= 'CANCELLED'
            and (now - incident.createdAt) <= windowMs
            and #(incident.location - coords) <= radius
        then
            return incident
        end
    end
    return nil
end

function FenixDispatch.createIncident(incidentType, coords, severity, opts)
    opts = opts or {}

    if opts.dedupeRadius then
        local existing = findDuplicate(incidentType, coords, opts.dedupeRadius, opts.dedupeWindowMs or 20000)
        if existing then
            for _, witness in ipairs((opts.witnesses or {})) do
                table.insert(existing.witnesses, witness)
            end
            dbg(('#%d reused for a duplicate %s report'):format(existing.id, incidentType))
            return existing, true
        end
    end

    if not severity then
        local defaults = cfg().defaultSeverity or {}
        severity = defaults[incidentType] or 1
    end

    local agencies = agenciesFor(incidentType)
    local incident = FenixIncident.create(incidentType, coords, severity, opts)
    FenixIncident.setStatus(incident.id, 'DISPATCHING')

    dbg(('#%d type=%s agencies=%s'):format(incident.id, incidentType, table.concat(agencies, '+')))

    local needsPolice = false
    for _, agency in ipairs(agencies) do
        if agency == 'police' then needsPolice = true end
    end

    if needsPolice then
        if opts.applyWanted ~= false then
            local wanted = opts.directWanted or severityToWanted(incident.severity)
            local radius = opts.wantedRadius or 10.0

            for _, playerId in ipairs(GetPlayersInRadius(coords, radius)) do
                TriggerClientEvent('fenix-police:client:SetWantedLevel', playerId, wanted)
            end
        else
            -- No known suspect (a civilian-witnessed report, typically) --
            -- nobody to star, so send an investigation unit to look around
            -- instead of doing nothing. See server/investigate.lua.
            local host = nearestPlayer(coords, cfg().maxHostSearchRadius or 300.0)
            if host then
                TriggerClientEvent('fenix-police:client:policeInvestigateIncident', host, {
                    id = incident.id,
                    type = incidentType,
                    coords = coords,
                    severity = incident.severity,
                })
            else
                dbg(('#%d wants investigation but no player is within host range'):format(incident.id))
            end
        end
    end

    for _, agency in ipairs(agencies) do
        if agency ~= 'police' then
            local host = nearestPlayer(coords, cfg().maxHostSearchRadius or 300.0)
            if host then
                TriggerClientEvent(('fenix-police:client:%sIncidentCreated'):format(agency), host, {
                    id = incident.id,
                    type = incidentType,
                    coords = coords,
                    severity = incident.severity,
                })
            else
                dbg(('#%d wants %s but no player is within host range'):format(incident.id, agency))
            end
        end
    end

    FenixIncident.setStatus(incident.id, 'ACTIVE')

    return incident
end

-------------------------------------------------------------------------------
-- Civilian witness reports
-------------------------------------------------------------------------------

-- client/witness.lua polls IS_ANY_PED_SHOOTING_IN_AREA around the local
-- player and reports here. The report identifies WHERE gunfire was heard,
-- not WHO fired it -- there is no suspect to pin a wanted level on, so this
-- never touches SetWantedLevel (applyWanted = false). It exists purely to
-- get a SHOOTING incident onto the board so a (future) investigation AI has
-- a scene to respond to, matching the design spec's "believable information
-- flow" requirement (section 19) instead of granting omniscient knowledge.
RegisterNetEvent('fenix-police:server:reportGunshot')
AddEventHandler('fenix-police:server:reportGunshot', function(coords)
    local src = source
    if not src or src == 0 then return end
    if not (Config.Dispatch or {}).enabled then return end
    if not FenixGuard.allow(src, 'witness_gunshot', (Config.Witness or {}).reportsPerMinute or 6) then return end

    if type(coords) ~= 'vector3' then return end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end

    local maxDistance = (Config.Witness or {}).maxReportDistance or 80.0
    if #(GetEntityCoords(ped) - coords) > maxDistance then
        FenixGuard.refuse(src, 'gunshot report', 'reported coordinates are too far from the caller')
        return
    end

    FenixDispatch.createIncident('SHOOTING', coords, nil, {
        applyWanted = false,
        witnesses = { src },
        dedupeRadius = (Config.Witness or {}).dedupeRadius or 60.0,
        dedupeWindowMs = (Config.Witness or {}).dedupeWindowMs or 30000,
    })
end)

-------------------------------------------------------------------------------
-- Unit assignment bookkeeping (EMS/fire)
-------------------------------------------------------------------------------

-- EMS/fire units (client/ems.lua, client/fire.lua) know exactly which
-- incident they were spawned for and report their own lifecycle here, so
-- FenixIncident.assignedUnits reflects reality instead of always reading
-- empty. Not security-sensitive (it's bookkeeping, not ownership -- entity
-- ownership itself is still decided by server/guard.lua), so this only
-- needs a rate limit, not full validation of the unit's identity.
RegisterNetEvent('fenix-police:server:assignIncidentUnit')
AddEventHandler('fenix-police:server:assignIncidentUnit', function(incidentId, unitId, role)
    local src = source
    if not FenixGuard.allow(src, 'incident_assign', 60) then return end
    FenixIncident.assignUnit(incidentId, unitId, role)
end)

RegisterNetEvent('fenix-police:server:releaseIncidentUnit')
AddEventHandler('fenix-police:server:releaseIncidentUnit', function(incidentId, unitId)
    local src = source
    if not FenixGuard.allow(src, 'incident_assign', 60) then return end

    FenixIncident.releaseUnit(incidentId, unitId)

    -- The wanted-level pathway (a suspect being chased) never calls
    -- assignUnit/releaseUnit at all -- only EMS, fire and investigation
    -- units do. So this handler only ever runs for incidents whose full
    -- response IS unit-tracked, meaning "the last tracked unit just
    -- released" really does mean the call is done.
    local incident = FenixIncident.get(incidentId)
    if incident and FenixIncident.countAssigned(incidentId) == 0 then
        FenixIncident.setStatus(incidentId, 'RESOLVED')
    end
end)

-- client/collision.lua reports its own vehicle's crash the same way
-- witness.lua/firewatch.lua report gunfire/fire: no fault determination, so
-- this never applies a wanted level -- a TRAFFIC_COLLISION gets a police
-- investigation unit (Config.Investigate) and an EMS unit, not stars.
RegisterNetEvent('fenix-police:server:reportCollision')
AddEventHandler('fenix-police:server:reportCollision', function(coords)
    local src = source
    if not src or src == 0 then return end
    if not (Config.Dispatch or {}).enabled then return end

    local collisionCfg = Config.Collision or {}
    if not FenixGuard.allow(src, 'report_collision', collisionCfg.reportsPerMinute or 6) then return end
    if type(coords) ~= 'vector3' then return end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end

    local maxDistance = collisionCfg.maxReportDistance or 60.0
    if #(GetEntityCoords(ped) - coords) > maxDistance then
        FenixGuard.refuse(src, 'collision report', 'reported coordinates are too far from the caller')
        return
    end

    FenixDispatch.createIncident('TRAFFIC_COLLISION', coords, nil, {
        applyWanted = false,
        witnesses = { src },
        dedupeRadius = collisionCfg.dedupeRadius or 40.0,
        dedupeWindowMs = collisionCfg.dedupeWindowMs or 30000,
    })
end)

-- Lets a staged EMS/fire unit ask "is a police unit actually assigned to
-- this incident yet" instead of only ever waiting out a fixed timer. Kept
-- as a simple request/reply rather than a push, because only a handful of
-- clients are ever staging on a dangerous call at once and each one polls
-- at most once per tick (client/ems.lua's tickMs) -- a push-notification
-- system for something this infrequent would be more machinery than the
-- problem needs.
RegisterNetEvent('fenix-police:server:queryIncidentHasRole')
AddEventHandler('fenix-police:server:queryIncidentHasRole', function(incidentId, role)
    local src = source
    if not FenixGuard.allow(src, 'incident_query', 120) then return end

    local has = false

    local incident = FenixIncident.get(incidentId)
    if incident then
        for _, assignedRole in pairs(incident.assignedUnits) do
            if assignedRole == role then
                has = true
                break
            end
        end
    end

    TriggerClientEvent('fenix-police:client:incidentHasRoleReply', src, incidentId, role, has)
end)

RegisterCommand('fenixdispatch', function(source)
    if source ~= 0 then return end

    print(('[FENIX-DISPATCH] unitsNeeded map: %s'):format(json.encode(cfg().unitsNeeded or {})))
    print('[FENIX-DISPATCH] see /fenixincidents for the live incident list')
end, true)
