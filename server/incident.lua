-- Persistent incident (calls-for-service) registry.
--
-- Previously the only "incident" concept in this resource was
-- server.lua's fenix:server:trigger -> GetWantedLevelFromCoords, a one-shot
-- lookup that applies stars and is immediately forgotten. That is fine for
-- "player commits crime -> player gets stars" but has nowhere to hang
-- multi-unit coordination, EMS/fire response, or NPC-originated calls that
-- don't involve a wanted level at all.
--
-- FenixIncident is server-authoritative (no client copy, no networking of
-- the object itself -- units are told what to do via existing per-unit
-- events, not by syncing this table). It is pure bookkeeping: no natives.

FenixIncident = {}

local incidents = {}
local nextId = 1

local VALID_STATUS = {
    CREATED = true,
    DISPATCHING = true,
    UNITS_RESPONDING = true,
    ACTIVE = true,
    CONTAINED = true,
    RESOLVED = true,
    CANCELLED = true,
}

local function cfg()
    return Config.Dispatch or {}
end

local function dbg(...)
    if cfg().debug then
        print('[fenix-police:incident]', ...)
    end
end

-- type: string, e.g. 'SHOOTING', 'MEDICAL', 'FIRE', 'TRAFFIC_STOP'.
-- coords: vector3.
-- severity: 1-5.
-- opts: optional { witnesses = {}, suspects = {}, victims = {}, region = string }
function FenixIncident.create(incidentType, coords, severity, opts)
    opts = opts or {}

    local id = nextId
    nextId = nextId + 1

    local incident = {
        id = id,
        type = incidentType,
        location = coords,
        severity = math.max(1, math.min(5, tonumber(severity) or 1)),
        region = opts.region,
        suspects = opts.suspects or {},
        victims = opts.victims or {},
        witnesses = opts.witnesses or {},
        evidence = opts.evidence or {},
        assignedUnits = {}, -- unitId -> role string ('primary'|'backup'|'perimeter'|'ems'|'fire'|...)
        status = 'CREATED',
        createdAt = GetGameTimer(),
        lastUpdate = GetGameTimer(),
    }

    incidents[id] = incident
    dbg(('created #%d type=%s severity=%d at %s'):format(id, incidentType, incident.severity, tostring(coords)))

    return incident
end

function FenixIncident.get(id)
    return incidents[id]
end

function FenixIncident.all()
    return incidents
end

function FenixIncident.setStatus(id, status)
    local incident = incidents[id]
    if not incident then return false end
    if not VALID_STATUS[status] then
        error(('FenixIncident.setStatus: "%s" is not a valid status'):format(tostring(status)), 2)
    end

    incident.status = status
    incident.lastUpdate = GetGameTimer()
    dbg(('#%d -> %s'):format(id, status))

    return true
end

-- unitId is caller-defined (e.g. a vehicle net ID) -- this registry doesn't
-- care what a "unit" is, only that something was assigned a role on a call.
function FenixIncident.assignUnit(id, unitId, role)
    local incident = incidents[id]
    if not incident then return false end

    incident.assignedUnits[unitId] = role or 'primary'
    incident.lastUpdate = GetGameTimer()
    dbg(('#%d assigned unit %s as %s'):format(id, tostring(unitId), incident.assignedUnits[unitId]))

    return true
end

function FenixIncident.releaseUnit(id, unitId)
    local incident = incidents[id]
    if not incident then return false end

    incident.assignedUnits[unitId] = nil
    incident.lastUpdate = GetGameTimer()

    return true
end

function FenixIncident.countAssigned(id)
    local incident = incidents[id]
    if not incident then return 0 end

    local n = 0
    for _ in pairs(incident.assignedUnits) do
        n = n + 1
    end
    return n
end

-- Drops CREATED/DISPATCHING calls that never got units and RESOLVED/
-- CANCELLED calls past the config'd retention window, so the table doesn't
-- grow forever across a long uptime. Call this from a slow-tick thread.
function FenixIncident.cleanupStale()
    local now = GetGameTimer()
    local maxAgeMs = (cfg().incidentMaxAgeMs) or (30 * 60 * 1000)
    local abandonedMs = (cfg().abandonedIncidentMs) or (5 * 60 * 1000)

    for id, incident in pairs(incidents) do
        local age = now - incident.createdAt
        local sinceUpdate = now - incident.lastUpdate

        local isDone = incident.status == 'RESOLVED' or incident.status == 'CANCELLED'
        local isAbandoned = (incident.status == 'CREATED' or incident.status == 'DISPATCHING')
            and FenixIncident.countAssigned(id) == 0
            and sinceUpdate > abandonedMs

        if (isDone and sinceUpdate > 60000) or isAbandoned or age > maxAgeMs then
            dbg(('#%d cleaned up (status=%s age=%dms)'):format(id, incident.status, age))
            incidents[id] = nil
        end
    end
end

CreateThread(function()
    while true do
        Wait(60000)
        local ok, err = pcall(FenixIncident.cleanupStale)
        if not ok then
            print('[fenix-police:incident] cleanup error:', err)
        end
    end
end)

RegisterCommand('fenixincidents', function(source)
    if source ~= 0 then return end -- console-only, matches /fenixbackup etc.

    local count = 0
    for id, incident in pairs(incidents) do
        count = count + 1
        print(('#%d %-12s sev=%d status=%-16s units=%d at %s')
            :format(id, incident.type, incident.severity, incident.status,
                FenixIncident.countAssigned(id), tostring(incident.location)))
    end

    if count == 0 then
        print('[fenix-police] no active incidents')
    end
end, true)
