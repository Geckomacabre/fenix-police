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
-- registry first. server/unit_registry.lua is that registry
-- (Config.UnitRegistry); pickHost below uses it only to break ties between
-- players who could host a call anyway, never to send a unit anywhere.

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

-------------------------------------------------------------------------------
-- Hosts
-------------------------------------------------------------------------------

-- Responder role -> the Config block that switches it on and says how far
-- from the scene it spawns. 'investigating' is the police unit sent to a
-- call with no suspect to star.
local ROLE_CONFIG = { investigating = 'Investigate', ems = 'EMS', fire = 'Fire' }

--- Is this role's own feature switched on? A role this resource doesn't
--- implement (a server's own agency in unitsNeeded) is somebody else's to
--- answer, so it is always offered.
local function roleEnabled(role)
    local key = ROLE_CONFIG[role]
    return key == nil or (Config[key] or {}).enabled == true
end

-- The host's client spawns the responder spawnMaxDistance from the scene, on
-- its own side of the network. A host standing much further than
-- hostScopeRadius minus that from the scene puts the spawn outside what it
-- has streamed in (OneSync's scope is ~424 m): no collision under the car,
-- and the unit never arrives.
local function hostRadius(role)
    local agencyCfg = Config[ROLE_CONFIG[role] or ''] or {}
    local reach = (cfg().hostScopeRadius or 400.0) - (agencyCfg.spawnMaxDistance or 140.0)
    return math.min(cfg().maxHostSearchRadius or 300.0, reach)
end

-- Picks a single player to "host" a non-police unit response (EMS/fire).
-- The server can't track where the AI units it spawns end up (see the file
-- header), but it CAN see where every connected player ped is right now --
-- that's a real, current position, not stale unit tracking. Handing the
-- response to the nearest player's client is what stops a naive broadcast
-- from spawning one ambulance per nearby player for the same call.
--
-- `bucket` (nil = any) keeps the call inside the routing bucket it happened
-- in -- a player in an instance would otherwise host a unit for a scene in a
-- world they can't see. `exclude` is the set of players already asked.
local function nearestPlayer(coords, maxRadius, bucket, exclude)
    local best, bestDist = nil, maxRadius
    for _, playerId in ipairs(GetPlayers()) do
        local id = tonumber(playerId)
        if not (exclude and exclude[id]) and (bucket == nil or GetPlayerRoutingBucket(playerId) == bucket) then
            local ped = GetPlayerPed(playerId)
            if ped and ped ~= 0 then
                local dist = #(GetEntityCoords(ped) - coords)
                if dist <= bestDist then
                    best, bestDist = id, dist
                end
            end
        end
    end
    return best
end

--- The host for one responder role. With Config.UnitRegistry collecting, the
--- player whose own ground unit is nearest the scene wins -- their client is
--- already simulating police right there -- as long as they would qualify
--- anyway: same radius, same bucket, not already asked. Otherwise the
--- nearest player.
local function pickHost(coords, role, bucket, exclude)
    local radius = hostRadius(role)

    if (Config.UnitRegistry or {}).enabled and FenixUnitRegistry then
        local _, unit = FenixUnitRegistry.nearest(coords, radius, 'ground', function(u)
            return not (exclude and exclude[u.src])
                and (bucket == nil or GetPlayerRoutingBucket(u.src) == bucket)
        end)
        if unit then
            local ped = GetPlayerPed(unit.src)
            if ped and ped ~= 0 and #(GetEntityCoords(ped) - coords) <= radius then
                return unit.src
            end
        end
    end

    return nearestPlayer(coords, radius, bucket, exclude)
end

-- Players near a point, inside one routing bucket (nil = any).
local function playersNear(coords, radius, bucket)
    local out = {}
    for _, playerId in ipairs(GetPlayers()) do
        if bucket == nil or GetPlayerRoutingBucket(playerId) == bucket then
            local ped = GetPlayerPed(playerId)
            if ped and ped ~= 0 and #(GetEntityCoords(ped) - coords) <= radius then
                out[#out + 1] = playerId
            end
        end
    end
    return out
end

-------------------------------------------------------------------------------
-- Offers
-------------------------------------------------------------------------------

-- Each responder role on an incident is an offer: sent to one host, and if no
-- unit for that role is assigned within Config.Dispatch.reofferAfterMs, sent
-- to the next-nearest player who hasn't been asked. A host can decline
-- without saying so -- already at its maxUnits, or nowhere legal to spawn --
-- and with a single offer the call would just go unanswered.

local function offerEvent(role)
    if role == 'investigating' then return 'fenix-police:client:policeInvestigateIncident' end
    return ('fenix-police:client:%sIncidentCreated'):format(role)
end

--- Offers `role` on `incident` to the best host not yet asked. Returns true
--- if somebody was asked.
local function offer(incident, role)
    if not roleEnabled(role) then return false end

    incident.offers[role] = incident.offers[role] or { tried = {}, count = 0, at = 0, answered = false }
    local o = incident.offers[role]
    o.at = GetGameTimer()

    local host = pickHost(incident.location, role, incident.bucket, o.tried)
    if not host then
        dbg(('#%d wants %s but no player is within host range'):format(incident.id, role))
        return false
    end

    o.tried[host] = true
    o.count = o.count + 1
    TriggerClientEvent(offerEvent(role), host, {
        id = incident.id,
        type = incident.type,
        coords = incident.location,
        severity = incident.severity,
        -- Lets a responder tell whether police are coming at all (EMS
        -- staging waits on them otherwise).
        agencies = incident.agencies,
        -- Who the investigating unit is looking for (server ids). Nobody
        -- else needs to know.
        suspects = role == 'investigating' and incident.suspects or nil,
    })
    return true
end

--- Is any role on this incident still waiting on a unit that may yet come?
local function offersPending(incident)
    local maxOffers = cfg().maxOffersPerRole or 3
    for _, o in pairs(incident.offers or {}) do
        if not o.answered and o.count < maxOffers then return true end
    end
    return false
end

local function reofferPass()
    if not cfg().enabled then return end

    local now = GetGameTimer()
    local after = cfg().reofferAfterMs or 20000
    local maxOffers = cfg().maxOffersPerRole or 3

    for _, incident in pairs(FenixIncident.all()) do
        if incident.status == 'ACTIVE' and incident.offers then
            for role, o in pairs(incident.offers) do
                if not o.answered and o.count < maxOffers and now - o.at >= after then
                    offer(incident, role)
                end
            end
        end
    end
end

CreateThread(function()
    while true do
        Wait(5000)
        local ok, err = pcall(reofferPass)
        if not ok then
            print('[fenix-police:dispatch] re-offer error:', err)
        end
    end
end)

-------------------------------------------------------------------------------
-- Suspects
-------------------------------------------------------------------------------

local function invCfg()
    return Config.Investigate or {}
end

--- Is "find the shooter" switched on (Config.Investigate.findSuspects)? It
--- only means anything while there's an investigating unit to do the
--- finding.
local function findingSuspects()
    return invCfg().enabled == true and invCfg().findSuspects ~= false
end

-- A suspect list is a handful of players near one scene; the cap only
-- bounds what one call can accumulate over its lifetime.
local MAX_SUSPECTS = 16

local function listed(list, value)
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

--- Is `pos` inside one of Config.Investigate.exemptZones (the Ammu-Nation
--- shooting ranges, by default)? The client checks the same list
--- (client/investigate.lua's FenixInvestigate.inExemptZone); this is the
--- server's own answer, not the client's word for it.
local function inExemptZone(pos)
    local zones = invCfg().exemptZones
    if type(zones) ~= 'table' or type(pos) ~= 'vector3' then return false end
    for _, zone in ipairs(zones) do
        if type(zone) == 'table' and type(zone.coords) == 'vector3'
            and #(pos - zone.coords) <= (tonumber(zone.radius) or 25.0)
        then
            return true
        end
    end
    return false
end

--- A suspect added to a call after its investigating unit was asked for has
--- to reach that unit too, or it goes looking with the list it was first
--- sent. Everyone the role was offered to, plus whoever actually holds a
--- unit on it; a client with no unit on the call ignores it.
local function tellInvestigators(incident)
    local hosts = {}
    local o = incident.offers and incident.offers.investigating
    for host in pairs(o and o.tried or {}) do hosts[host] = true end
    for unitId, role in pairs(incident.assignedUnits) do
        local by = incident.assignedBy[unitId]
        if role == 'investigating' and by then hosts[by] = true end
    end
    for host in pairs(hosts) do
        TriggerClientEvent('fenix-police:client:investigationSuspects', host, incident.id, incident.suspects)
    end
end

-------------------------------------------------------------------------------
-- Incidents
-------------------------------------------------------------------------------

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
--       opts.bucket (number) -- routing bucket the incident happened in;
--         only players in it are starred or asked to host. nil = any.
-- Multiple witnesses (or multiple clients standing near the same event) can
-- each try to report the same real-world incident independently. Rather
-- than creating one incident per report, fold a new report into an existing
-- unresolved incident of the same type nearby -- this is also what makes
-- "has the incident already been resolved" (design spec section 5) a real
-- check instead of a TODO.
--
-- "Recent" runs from the latest report, not the first, and a call that still
-- has units on it always absorbs new reports: sustained gunfire or a fire
-- that keeps burning is one incident, not a fresh EMS + investigation
-- response every dedupe window.
local function findDuplicate(incidentType, coords, radius, windowMs, bucket)
    local now = GetGameTimer()
    for _, incident in pairs(FenixIncident.all()) do
        if incident.type == incidentType
            and incident.status ~= 'RESOLVED' and incident.status ~= 'CANCELLED'
            and incident.bucket == bucket
            and ((now - (incident.lastReportAt or incident.createdAt)) <= windowMs
                or FenixIncident.countAssigned(incident.id) > 0)
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
        local existing = findDuplicate(incidentType, coords, opts.dedupeRadius, opts.dedupeWindowMs or 20000, opts.bucket)
        if existing then
            existing.lastReportAt = GetGameTimer()
            for _, witness in ipairs((opts.witnesses or {})) do
                if not listed(existing.witnesses, witness) then table.insert(existing.witnesses, witness) end
            end

            -- The shooter's own report often lands a moment after somebody
            -- else's has already put the call on the board.
            local newSuspect = false
            for _, suspect in ipairs(opts.suspects or {}) do
                if not listed(existing.suspects, suspect) and #existing.suspects < MAX_SUSPECTS then
                    table.insert(existing.suspects, suspect)
                    newSuspect = true
                end
            end
            if newSuspect then tellInvestigators(existing) end

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
    incident.bucket = opts.bucket
    incident.agencies = agencies
    incident.offers = {}
    incident.lastReportAt = incident.createdAt
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

            -- Level 0 is not "no stars" on the client: SetWantedLevel clears
            -- and re-applies whatever the player already has, re-centring
            -- their search area.
            if wanted > 0 then
                for _, playerId in ipairs(playersNear(coords, radius, incident.bucket)) do
                    TriggerClientEvent('fenix-police:client:SetWantedLevel', playerId, wanted)
                end
            end
        else
            -- No known suspect (a civilian-witnessed report, typically) --
            -- nobody to star, so send an investigation unit to look around
            -- instead of doing nothing. See server/investigate.lua.
            offer(incident, 'investigating')
        end
    end

    for _, agency in ipairs(agencies) do
        if agency ~= 'police' then
            offer(incident, agency)
        end
    end

    FenixIncident.setStatus(incident.id, 'ACTIVE')

    return incident
end

-------------------------------------------------------------------------------
-- Civilian witness reports
-------------------------------------------------------------------------------

--- Is a wanted player within `radius` of `coords`? A pursuit makes its own
--- gunfire and crashes -- the AI cops shooting at the player, PIT and ram
--- damage, the player's own shots -- and reported as civilian calls they
--- would spawn EMS and an investigation unit every dedupe window of an armed
--- chase, usually hosted by, and sent to the feet of, the player being
--- chased.
local function wantedPlayerNear(coords, radius)
    for _, playerId in ipairs(GetPlayers()) do
        local ped = GetPlayerPed(playerId)
        if ped and ped ~= 0 and #(GetEntityCoords(ped) - coords) <= radius then
            local wanted
            if FenixDispatch.isPlayerWanted then
                wanted = FenixDispatch.isPlayerWanted(playerId)
            else
                wanted = (GetPlayerWantedLevel(playerId) or 0) > 0
            end
            if wanted then return true end
        end
    end
    return false
end

-- client/witness.lua polls IS_ANY_PED_SHOOTING_IN_AREA around the local
-- player and reports here. The report identifies WHERE gunfire was heard,
-- not WHO fired it -- there is no suspect to pin a wanted level on, so this
-- never touches SetWantedLevel (applyWanted = false). It exists to get a
-- SHOOTING incident onto the board so an investigation unit
-- (client/investigate.lua) has a scene to respond to, matching the design
-- spec's "believable information flow" requirement (section 19) instead of
-- granting omniscient knowledge.
--
-- `selfFired` is the caller's own client saying its player fired a gun in
-- the moments before. That lists the caller -- and only ever the caller --
-- as a suspect: a cheating client can leave the flag off, which is where
-- things stood before, but can't name anybody else. Being listed stars
-- nobody; investigationSpotted below does that, once an officer has seen
-- the suspect armed at the scene.
RegisterNetEvent('fenix-police:server:reportGunshot')
AddEventHandler('fenix-police:server:reportGunshot', function(coords, selfFired)
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

    if wantedPlayerNear(coords, cfg().wantedSuppressRadius or 80.0) then return end

    -- A shooting range is not a crime scene. The honest client never sends
    -- this from one; checked here too, against where the server sees them.
    if inExemptZone(coords) or inExemptZone(GetEntityCoords(ped)) then return end

    FenixDispatch.createIncident('SHOOTING', coords, nil, {
        applyWanted = false,
        witnesses = { src },
        suspects = (selfFired == true and findingSuspects()) and { src } or nil,
        dedupeRadius = (Config.Witness or {}).dedupeRadius or 60.0,
        dedupeWindowMs = (Config.Witness or {}).dedupeWindowMs or 30000,
        bucket = GetPlayerRoutingBucket(src),
    })
end)

-- How far past spotRange a sighting still holds up: the suspect and the
-- officer both keep moving between the client's look and this check, a
-- tick and a network trip apart.
local SPOT_SLACK = 15.0

-- An investigating unit parks up to 60 m short of a scene off the road
-- (client/investigate.lua's ROAD_END_ARRIVE_DISTANCE) and starts watching
-- from watchFromDistance out on its way in; this much again covers it
-- moving in the meantime.
local SCENE_SLACK = 30.0

-- client/investigate.lua: an investigating unit has seen one of the call's
-- suspects armed. The server's own view has to agree before anybody is
-- starred -- the unit is this player's and is on this call, the suspect is
-- listed on it, one of this player's officers really is close to the
-- suspect, and the unit really is at the scene -- and it happens once per
-- call. The stars go to the suspect's own client through the same
-- SetWantedLevel event every other path uses, which only ever raises.
RegisterNetEvent('fenix-police:server:investigationSpotted')
AddEventHandler('fenix-police:server:investigationSpotted', function(incidentId, unitId, suspect)
    local src = source
    if not cfg().enabled or not findingSuspects() then return end
    if not FenixGuard.allow(src, 'incident_assign', 60) then return end

    incidentId, unitId, suspect = tonumber(incidentId), tonumber(unitId), tonumber(suspect)
    if not incidentId or not unitId or not suspect then return end

    local incident = FenixIncident.get(incidentId)
    if not incident or incident.status == 'RESOLVED' or incident.status == 'CANCELLED' then return end
    if incident.outcome == 'SUSPECT_SPOTTED' then return end

    if incident.assignedUnits[unitId] ~= 'investigating' or incident.assignedBy[unitId] ~= src then
        FenixGuard.refuse(src, 'investigation sighting', 'unit is not investigating this call for them')
        return
    end
    local vehicle = FenixGuard.resolve(src, unitId, 'vehicle', 'investigation sighting')
    if not vehicle then return end

    if not listed(incident.suspects, suspect) then
        FenixGuard.refuse(src, 'investigation sighting', 'player is not a suspect on this call')
        return
    end

    -- Gone, or in another world than the call: nothing to star.
    if not GetPlayerName(suspect) then return end
    local suspectPed = GetPlayerPed(suspect)
    if not suspectPed or suspectPed == 0 then return end
    if incident.bucket ~= nil and GetPlayerRoutingBucket(suspect) ~= incident.bucket then return end

    local suspectPos = GetEntityCoords(suspectPed)
    local sceneReach = math.max(invCfg().watchFromDistance or 80.0, 60.0) + SCENE_SLACK
    if #(GetEntityCoords(vehicle) - incident.location) > sceneReach then
        FenixGuard.refuse(src, 'investigation sighting', 'unit is not at the scene')
        return
    end
    if not FenixGuard.officerNear(src, suspectPos, (invCfg().spotRange or 40.0) + SPOT_SLACK) then
        FenixGuard.refuse(src, 'investigation sighting', 'none of their officers is near the suspect')
        return
    end

    -- Stepped onto a range since the client looked: not a sighting.
    if inExemptZone(suspectPos) then return end

    FenixIncident.setOutcome(incidentId, 'SUSPECT_SPOTTED')

    -- Already wanted: a pursuit (or a stop, a surrender, an arrest) already
    -- has them, and stars from here would only cut across it.
    if FenixDispatch.isPlayerWanted and FenixDispatch.isPlayerWanted(suspect) then
        dbg(('#%d suspect %d spotted, already wanted'):format(incidentId, suspect))
        return
    end

    local wanted = severityToWanted(incident.severity)
    dbg(('#%d suspect %d spotted armed by unit %d, wanted %d'):format(incidentId, suspect, unitId, wanted))
    TriggerClientEvent('fenix-police:client:SetWantedLevel', suspect, wanted)
end)

-------------------------------------------------------------------------------
-- Unit assignment bookkeeping (EMS/fire)
-------------------------------------------------------------------------------

-- EMS/fire units (client/ems.lua, client/fire.lua) know exactly which
-- incident they were spawned for and report their own lifecycle here, so
-- FenixIncident.assignedUnits reflects reality instead of always reading
-- empty.
--
-- Bookkeeping, but bookkeeping other things act on: a release can resolve a
-- call, and an 'investigating' assignment is what a staged ambulance waits
-- for. So a unit has to be the reporting player's own (FenixGuard), under a
-- role a responder actually uses, and only the player who assigned a unit
-- can release it.

--- 'investigating', or any non-police agency Config.Dispatch.unitsNeeded
--- can call.
local function validRole(role)
    if role == 'investigating' then return true end
    if type(role) ~= 'string' or role == 'police' then return false end
    for _, agencies in pairs(cfg().unitsNeeded or {}) do
        for _, agency in ipairs(agencies) do
            if agency == role then return true end
        end
    end
    return false
end

-- A responder reports its assignment straight after creating the unit, and
-- the event can reach the server before the entity does -- the two travel
-- separately. Judged at once, an honest unit reads as "not one of theirs",
-- and the role is re-offered to somebody else on top of it.
local function awaitUnit(unitId)
    local waited = 0
    while waited < 2000 do
        local entity = NetworkGetEntityFromNetworkId(unitId)
        if entity and entity ~= 0 and DoesEntityExist(entity) then return end
        Wait(100)
        waited = waited + 100
    end
end

RegisterNetEvent('fenix-police:server:assignIncidentUnit')
AddEventHandler('fenix-police:server:assignIncidentUnit', function(incidentId, unitId, role)
    local src = source
    if not FenixGuard.allow(src, 'incident_assign', 60) then return end

    incidentId, unitId = tonumber(incidentId), tonumber(unitId)
    if not incidentId or not unitId or not validRole(role) then return end
    if not FenixIncident.get(incidentId) then return end

    awaitUnit(unitId)

    local incident = FenixIncident.get(incidentId)
    if not incident or incident.status == 'RESOLVED' or incident.status == 'CANCELLED' then return end

    local by = incident.assignedBy[unitId]
    if (by and by ~= src) or not FenixGuard.isHeldBy(src, unitId) then
        FenixGuard.refuse(src, 'incident assignment', 'unit is not one of theirs')
        return
    end

    FenixIncident.assignUnit(incidentId, unitId, role, src)
    if incident.offers and incident.offers[role] then
        incident.offers[role].answered = true
    end
end)

-- `outcome` is optional: 'NO_SUSPECT' from an investigating unit that
-- looked and found nobody. Bookkeeping only (/fenixincidents), and never
-- over a sighting.
RegisterNetEvent('fenix-police:server:releaseIncidentUnit')
AddEventHandler('fenix-police:server:releaseIncidentUnit', function(incidentId, unitId, outcome)
    local src = source
    if not FenixGuard.allow(src, 'incident_assign', 60) then return end

    incidentId, unitId = tonumber(incidentId), tonumber(unitId)
    local incident = incidentId and FenixIncident.get(incidentId)
    if not incident or not unitId then return end
    if incident.assignedBy[unitId] ~= src then return end

    if outcome == 'NO_SUSPECT' and incident.assignedUnits[unitId] == 'investigating' and not incident.outcome then
        FenixIncident.setOutcome(incidentId, 'NO_SUSPECT')
    end

    FenixIncident.releaseUnit(incidentId, unitId)

    -- The wanted-level pathway (a suspect being chased) never calls
    -- assignUnit/releaseUnit at all -- only EMS, fire and investigation
    -- units do. So this handler only ever runs for incidents whose full
    -- response IS unit-tracked, meaning "the last tracked unit just
    -- released" really does mean the call is done -- unless another role's
    -- unit is still on its way, in which case the call stays open for it.
    if incident.status == 'ACTIVE' and FenixIncident.countAssigned(incidentId) == 0
        and not offersPending(incident) then
        FenixIncident.setStatus(incidentId, 'RESOLVED')
    end
end)

-- A disconnecting host's units go with them (server/guard.lua deletes what
-- they owned), so their assignments come off and those roles go back out to
-- somebody else on the next re-offer pass, instead of the call sitting on
-- units that no longer exist until incidentMaxAgeMs.
--
-- A departing suspect comes off every call too: there's nobody left to
-- find, and the server id is free for whoever connects next.
AddEventHandler('playerDropped', function()
    local src = source
    for id, incident in pairs(FenixIncident.all()) do
        for unitId, by in pairs(incident.assignedBy or {}) do
            if by == src then
                local role = incident.assignedUnits[unitId]
                FenixIncident.releaseUnit(id, unitId)
                local o = incident.offers and incident.offers[role]
                if o then
                    o.answered = false
                    o.at = 0
                end
            end
        end

        local suspects = incident.suspects or {}
        for i = #suspects, 1, -1 do
            if suspects[i] == src then
                table.remove(suspects, i)
                tellInvestigators(incident)
            end
        end
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

    if wantedPlayerNear(coords, cfg().wantedSuppressRadius or 80.0) then return end

    FenixDispatch.createIncident('TRAFFIC_COLLISION', coords, nil, {
        applyWanted = false,
        witnesses = { src },
        dedupeRadius = collisionCfg.dedupeRadius or 40.0,
        dedupeWindowMs = collisionCfg.dedupeWindowMs or 30000,
        bucket = GetPlayerRoutingBucket(src),
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

    local incident = FenixIncident.get(tonumber(incidentId))
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
