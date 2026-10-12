--[[
    server/guard.lua

    Who is allowed to do what to which entity.

    Every mutating net event in server/server.lua took a network ID straight off
    the wire and acted on whatever it resolved to:

        deleteSpawnedEntity           deleted ANY networked entity
        deleteSpawnedPed              deleted any networked ped
        fenix-police:rearmOfficer     armed any ped, including a player's
        fenix-police:unlockOfficerVehicle  unlocked any vehicle

    Network IDs are small integers. You don't guess them, you count. On a QBCore
    server that is theft, griefing and free weapons for anybody who can send an
    event.

    There was a registry these could have been validated against —
    `activeGroundUnits` in server.lua — but it is only ever assigned nil. It is a
    leftover from the server-side ground spawn path that the client-side
    delegation replaced, so the server holds no record of what this resource
    created. That is the hole. This file is the record.

    ── Three layers, outermost first ───────────────────────────────────────────

      1. PLAYER ENTITIES ARE UNTOUCHABLE. A player's ped, or a vehicle a player
         is sitting in, is refused before anything else is considered. Absolute,
         not configurable, and the reason a stolen cruiser can't be deleted out
         from under whoever stole it.

      2. MODEL ALLOWLIST. The entity's model must be one this resource is
         configured to spawn. This is the layer doing the real work: a player's
         Sultan and a player's freemode ped are not in the set, so the serious
         hole is closed by model alone, with no dependence on the client having
         told us anything truthful.

      3. OWNERSHIP. Entities are recorded against the player they were spawned
         for, and an unrecorded one is only accepted from the player whose
         client created it. Without this, the allowlist alone waves through
         every player's own police/EMS job car -- same stock models -- for
         anybody counting net IDs (see Config.Security.strictOwnership).

    Ground units are created client-side, so the server can't record them at
    creation the way it does for helicopters and planes. Instead it issues a
    single-use TICKET when it authorises a spawn, and accepts one registration
    quoting that ticket back. A client can only ever register entities the server
    just told it to make.
]]

FenixGuard = {}

local function cfg() return Config.Security or {} end
local function dbg(msg) if cfg().debug then print('[FENIX-GUARD] ' .. msg) end end

--- Refusals are logged by default rather than silently swallowed: the first
--- thing you want when somebody starts probing is to know it is happening.
---
--- Always returns false, so a caller can `return refuse(...)` and have it read
--- as a rejection rather than as a log line with a return bolted on.
local function refuse(src, what, why)
    if cfg().logRefusals == false then return false end
    print(('^3[FENIX-GUARD] refused %s from %s (%s): %s^7')
        :format(what, GetPlayerName(src) or 'unknown', tostring(src), why))
    return false
end

-- Exposed so server.lua can log a refusal for a check that is specific to one
-- handler and doesn't belong in the shared gate.
FenixGuard.refuse = refuse

-------------------------------------------------------------------------------
-- Layer 2: the model allowlist
-------------------------------------------------------------------------------

-- modelHash -> true. Built once at start from the same config the spawners read,
-- so a server owner who adds an add-on cruiser to Config.vehiclesByRegion gets
-- it allowlisted automatically and never has to know this file exists.
local allowedVehicles = {}
local allowedPeds = {}

local function allowVehicle(model)
    if type(model) == 'string' then allowedVehicles[GetHashKey(model)] = true end
end

--- Is this model one of the dispatch vehicles built above? Exposed read-only
--- for anything that needs the same "is this a police vehicle" answer
--- without re-deriving it from Config.vehiclesByRegion itself — server/tracker.lua,
--- for one: whether a vehicle is trackable is exactly this same question.
--- @param model number a model HASH, not a name
function FenixGuard.isAllowedVehicleModel(model)
    return allowedVehicles[model] == true
end

local function allowPed(model)
    if type(model) == 'string' then allowedPeds[GetHashKey(model)] = true end
end

local function buildAllowlist()
    allowedVehicles, allowedPeds = {}, {}

    for _, region in pairs(Config.vehiclesByRegion or {}) do
        for _, entry in ipairs(region) do
            allowVehicle(entry.model)
            -- Stock stand-in the client spawns instead when the add-on model
            -- isn't installed (client/livery.lua's resolveModel).
            allowVehicle(entry.fallback)
            for _, ped in ipairs(entry.peds or {}) do allowPed(ped) end
        end
    end

    for _, list in ipairs({ Config.polHelis, Config.milHelis,
                            Config.polPlanes, Config.milPlanes }) do
        for _, entry in ipairs(list or {}) do
            allowVehicle(entry.model)
            for _, ped in ipairs(entry.pilots or {}) do allowPed(ped) end
            for _, ped in ipairs(entry.peds or {}) do allowPed(ped) end
        end
    end

    -- Anything the server owner added by hand, for add-on packs referenced from
    -- somewhere this doesn't reach.
    for _, model in ipairs(cfg().extraVehicles or {}) do allowVehicle(model) end
    for _, model in ipairs(cfg().extraPeds or {}) do allowPed(model) end

    -- [Upstate Mafia] Ambient scene models (client/ambient.lua) -- a patrol or
    -- convoy scene promoted into a real pursuit unit (PromoteAmbientUnit,
    -- client.lua) registers through the same fenix-police:registerSpawnedUnit
    -- path as a fresh spawn, which checks this allowlist. Config.Ambient's
    -- pools happen to already be a subset of Config.vehiclesByRegion's today,
    -- but that's not guaranteed to stay true, and an unlisted model here means
    -- a promoted unit's later delete/rearm calls get silently refused forever.
    local ambientCfg = Config.Ambient or {}
    for _, pool in ipairs({ ambientCfg.vehicles, ambientCfg.vehicleFallback }) do
        for _, list in pairs(pool or {}) do
            -- Both shapes client/ambient.lua accepts: an array of names, or a
            -- `model = weight` map (ipairs alone skipped the map form entirely).
            for k, v in pairs(list) do allowVehicle(type(k) == 'string' and k or v) end
        end
    end
    for _, list in pairs(ambientCfg.peds or {}) do
        for _, model in ipairs(list) do allowPed(model) end
    end

    -- EMS (server/ems.lua, client/ems.lua). Same reasoning as ambient scene
    -- models above: whatever Config.EMS spawns must be allowlisted or its
    -- later register/delete calls get silently refused. Only while the
    -- feature is on, though -- 'ambulance' and 'firetruk' are exactly what
    -- player EMS/fire jobs drive, and a disabled feature spawns nothing that
    -- needs them listed.
    local emsCfg = Config.EMS or {}
    if emsCfg.enabled then
        allowVehicle(emsCfg.vehicle)
        for _, model in ipairs(emsCfg.peds or {}) do allowPed(model) end
    end

    -- Fire (server/fire.lua, client/fire.lua). Same reasoning again.
    local fireCfg = Config.Fire or {}
    if fireCfg.enabled then
        allowVehicle(fireCfg.vehicle)
        for _, model in ipairs(fireCfg.peds or {}) do allowPed(model) end
    end

    -- Investigation units (server/investigate.lua, client/investigate.lua).
    -- Same reasoning again -- both the configured model and its stock
    -- fallback (client/livery.lua's resolveModel) need to be allowlisted,
    -- same as every entry in Config.vehiclesByRegion.
    local invCfg = Config.Investigate or {}
    if invCfg.enabled then
        allowVehicle(invCfg.vehicle)
        allowVehicle(invCfg.vehicleFallback)
        for _, model in ipairs(invCfg.peds or {}) do allowPed(model) end
    end

    local v, p = 0, 0
    for _ in pairs(allowedVehicles) do v = v + 1 end
    for _ in pairs(allowedPeds) do p = p + 1 end
    dbg(('allowlist built: %d vehicle model(s), %d ped model(s)'):format(v, p))
end

CreateThread(buildAllowlist)

-------------------------------------------------------------------------------
-- Layer 1: player entities
-------------------------------------------------------------------------------

--- Is this entity a player's ped, or a vehicle with a player in it?
---
--- Checked before everything else and never configurable. It is also what makes
--- the model allowlist safe on a stolen cruiser: the model says "police", so
--- layer 2 would wave it through, and this is what stops the car being deleted
--- from under whoever is driving it.
--- @param ignoreSrc? number a player to leave out (one who is disconnecting)
local function belongsToAPlayer(entity, ignoreSrc)
    for _, playerId in ipairs(GetPlayers()) do
        local ped = tonumber(playerId) ~= tonumber(ignoreSrc) and GetPlayerPed(playerId) or 0
        if ped and ped ~= 0 then
            if ped == entity then return true end
            if GetVehiclePedIsIn(ped, false) == entity then return true end
        end
    end
    return false
end

-------------------------------------------------------------------------------
-- Layer 3: ownership
-------------------------------------------------------------------------------

-- netID -> { src = player this was spawned for, kind = 'vehicle'|'ped', at = os.time() }
local owned = {}

-- ticket -> { src, issuedAt }. Single use, short lived.
local tickets = {}
local nextTicket = 1

--- Record an entity against the player it was spawned for.
function FenixGuard.claim(src, netID, kind)
    if not netID then return end
    owned[netID] = { src = src, kind = kind or 'entity', at = os.time() }
end

function FenixGuard.release(netID)
    if netID then owned[netID] = nil end
end

-- Network IDs are recycled. Without this, an entity that disappears any way
-- other than through this resource's own delete handlers (despawned out of
-- scope, deleted by another script) leaves its record behind, and whatever
-- entity gets that net ID next arrives already "owned" by a player who never
-- spawned it. Fires for every entity on the server, ambient traffic
-- included, so it stays a single lookup; pcall because a native error here
-- would print once per despawn.
AddEventHandler('entityRemoved', function(entity)
    local ok, netID = pcall(NetworkGetNetworkIdFromEntity, entity)
    if ok and netID and netID ~= 0 then owned[netID] = nil end
end)

--- The player an entity is recorded against, or nil.
function FenixGuard.ownerOf(netID)
    local rec = owned[netID]
    return rec and rec.src or nil
end

--- Did this player's client create the entity? The server's own record of
--- who first owned it, so nothing the client says goes into it. Helicopters
--- and planes are created by the server and recorded at creation instead, and
--- a record always wins over this (see heldBy). nil when this server build
--- predates NETWORK_GET_FIRST_ENTITY_OWNER and can't say.
local function createdBy(entity, src)
    if not NetworkGetFirstEntityOwner then return nil end
    local first = NetworkGetFirstEntityOwner(entity)
    return first ~= nil and first > 0 and first == tonumber(src)
end

--- Is `src` entitled to act on this entity: recorded against them, or, with
--- no record at all, created by their own client. The second half covers the
--- window between a client creating a unit and its registration landing --
--- client.lua re-arms each officer the moment it is seated, before the
--- registration for the unit has even been sent.
local function heldBy(src, netID, entity)
    local rec = owned[netID]
    if rec then return rec.src == src end
    return createdBy(entity, src) == true
end

--- Same test for callers outside this file; false for anything that no longer
--- exists.
function FenixGuard.isHeldBy(src, netID)
    if type(netID) ~= 'number' then return false end
    local entity = NetworkGetEntityFromNetworkId(netID)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return false end
    return heldBy(src, netID, entity)
end

--- Snapshot of every currently-owned net ID, for a resource-stop sweep that
--- has to find everything this resource ever spawned without keeping its own
--- second copy of the same registry. Returns {netID, kind} pairs; callers
--- resolve the entity themselves since a netID can go stale between the
--- snapshot and the delete attempt.
function FenixGuard.allOwned()
    local list = {}
    for netID, rec in pairs(owned) do
        list[#list + 1] = { netID = netID, kind = rec.kind }
    end
    return list
end

--- How many entities this player currently has on the books. The cap this feeds
--- is the backstop against a client that passes every other check and simply
--- asks for units forever.
local function ownedCountFor(src)
    local n = 0
    for _, rec in pairs(owned) do
        if rec.src == src then n = n + 1 end
    end
    return n
end

FenixGuard.ownedCount = ownedCountFor

--- The per-player ceiling ownedCountFor is checked against.
function FenixGuard.ownedCap()
    return cfg().maxOwnedEntities or 150
end

--- Issue a single-use spawn ticket. The server calls this when it authorises a
--- ground spawn; the client quotes it back with the entities it made.
function FenixGuard.issueTicket(src)
    local id = nextTicket
    nextTicket = nextTicket + 1
    tickets[id] = { src = src, issuedAt = os.time() }
    return id
end

--- Consume a ticket. Returns false if it never existed, has already been used,
--- belongs to somebody else, or has gone stale.
local function redeemTicket(src, ticket)
    local rec = tickets[ticket]
    if not rec then return false, 'no such ticket' end
    if rec.src ~= src then return false, 'ticket belongs to another player' end

    tickets[ticket] = nil

    if (os.time() - rec.issuedAt) > (cfg().ticketLifetime or 30) then
        return false, 'ticket expired'
    end
    return true
end

-- Stale tickets are spawns that were authorised and never completed — a failed
-- model load, a client that disconnected mid-spawn. Swept so the table can't
-- grow for the life of the server.
CreateThread(function()
    while true do
        Wait(60000)
        local now = os.time()
        local lifetime = cfg().ticketLifetime or 30
        for id, rec in pairs(tickets) do
            if (now - rec.issuedAt) > lifetime then tickets[id] = nil end
        end
    end
end)

-------------------------------------------------------------------------------
-- Rate limiting
-------------------------------------------------------------------------------

-- src -> { [bucket] = { count, windowStart } }
local buckets = {}

-- Per-bucket ceilings, because these events are not called at remotely similar
-- rates. `spawn` is a deliberate request a client makes a handful of times a
-- minute; `unlock` and `rearm` are fired from the chase loop once per officer
-- per cycle, and `delete` arrives in bursts of thirty when a pursuit ends and
-- the cleanup sweep runs five passes over ten units and their crews.
--
-- Getting these too tight is worse than not having them: a refused delete is a
-- police car left in the world forever. They exist to stop a loop, not to meter
-- normal play, so the defaults sit far above anything legitimate.
local DEFAULT_LIMITS = {
    spawn    = 60,
    register = 60,
    delete   = 600,
    unlock   = 600,
    rearm    = 600,
}

--- Sliding-window counter. The spawn events had no limit at all, so a client
--- could sit in a loop asking for units.
--- @param bucket string a name, so each event group is metered separately
function FenixGuard.allow(src, bucket, limitPerMinute)
    local limits = cfg().rateLimits or {}
    local limit = limitPerMinute
        or limits[bucket]
        or DEFAULT_LIMITS[bucket]
        or cfg().maxRequestsPerMinute
        or 300
    if limit <= 0 then return true end

    local now = os.time()
    buckets[src] = buckets[src] or {}
    local b = buckets[src][bucket]

    if not b or (now - b.windowStart) >= 60 then
        buckets[src][bucket] = { count = 1, windowStart = now }
        return true
    end

    b.count = b.count + 1
    if b.count > limit then
        if b.count == limit + 1 then
            refuse(src, bucket, ('rate limit: more than %d in 60s'):format(limit))
        end
        return false
    end
    return true
end

-------------------------------------------------------------------------------
-- The gate
-------------------------------------------------------------------------------

--- May `src` act on the entity behind `netID`?
---
--- Returns the entity handle on success, or nil plus a reason. Callers should
--- treat nil as "do nothing at all" — never as "try something else".
---
--- @param kind string 'vehicle' | 'ped' | 'any'
--- @param what string label for the refusal log
function FenixGuard.resolve(src, netID, kind, what)
    if type(netID) ~= 'number' then
        return nil, refuse(src, what, 'network id was not a number')
    end

    local entity = NetworkGetEntityFromNetworkId(netID)
    if not entity or entity == 0 or not DoesEntityExist(entity) then
        -- Not an attack, just a race: the entity is already gone. Drop the
        -- ownership record and say nothing.
        FenixGuard.release(netID)
        return nil
    end

    -- Layer 1.
    if belongsToAPlayer(entity) then
        return nil, refuse(src, what, 'entity is a player, or a vehicle a player is in')
    end

    -- Layer 2.
    local entityType = GetEntityType(entity)   -- 1 ped, 2 vehicle, 3 object
    local model = GetEntityModel(entity)

    if kind == 'vehicle' and entityType ~= 2 then
        return nil, refuse(src, what, 'entity is not a vehicle')
    end
    if kind == 'ped' and entityType ~= 1 then
        return nil, refuse(src, what, 'entity is not a ped')
    end

    local allowed = (entityType == 2 and allowedVehicles[model])
                 or (entityType == 1 and allowedPeds[model])
    if not allowed then
        return nil, refuse(src, what, ('model %s is not one this resource spawns'):format(model))
    end

    -- Layer 3.
    local rec = owned[netID]
    if rec then
        if rec.src ~= src then
            return nil, refuse(src, what, 'entity belongs to another player')
        end
    elseif cfg().strictOwnership ~= false and not createdBy(entity, src) then
        return nil, refuse(src, what, 'entity has no ownership record')
    end

    return entity
end

--- Is one of `src`'s own officers -- an allowlisted, non-player ped held by
--- them -- within `radius` of `coords`? For actions that only make sense with
--- an officer physically there (a field revive, a citation at the window), so
--- that sending the event from anywhere else does nothing.
function FenixGuard.officerNear(src, coords, radius)
    for _, ped in ipairs(GetAllPeds()) do
        if allowedPeds[GetEntityModel(ped)] and not IsPedAPlayer(ped)
            and #(GetEntityCoords(ped) - coords) <= radius
            and heldBy(src, NetworkGetNetworkIdFromEntity(ped), ped) then
            return true
        end
    end
    return false
end

--- A disconnecting player's units go with them. Helicopters and planes are
--- server-created, so nothing ties them to the requester's connection: left
--- alone they fly on with nobody tracking them, and with their records gone
--- even the resource-stop sweep in server.lua can't find them. Records go
--- too, so a recycled server id can't inherit somebody else's entities.
AddEventHandler('playerDropped', function()
    local src = source
    for netID, rec in pairs(owned) do
        if rec.src == src then
            local entity = NetworkGetEntityFromNetworkId(netID)
            if entity and entity ~= 0 and DoesEntityExist(entity) and not belongsToAPlayer(entity, src) then
                DeleteEntity(entity)
            end
            owned[netID] = nil
        end
    end
    for id, rec in pairs(tickets) do
        if rec.src == src then tickets[id] = nil end
    end
    buckets[src] = nil
end)

-------------------------------------------------------------------------------
-- Ground-unit registration
-------------------------------------------------------------------------------

--- The client reports the entities it created for an authorised spawn.
---
--- Everything is re-checked here rather than trusted: the ticket proves the
--- server asked for a spawn, but it does not prove the client made what it was
--- told to. Each reported net ID has to resolve to an allowlisted police model
--- that nobody already owns and that this player's own client created --
--- promoteAmbientUnit hands a ticket to anyone who asks, so without that last
--- check a ticket would be a licence to claim any unowned cruiser on the map.
RegisterNetEvent('fenix-police:registerSpawnedUnit')
AddEventHandler('fenix-police:registerSpawnedUnit', function(ticket, vehNetID, pedNetIDs)
    local src = source

    if not FenixGuard.allow(src, 'register') then return end

    local ok, why = redeemTicket(src, tonumber(ticket) or -1)
    if not ok then
        refuse(src, 'unit registration', why)
        return
    end

    -- One vehicle's crew. Sixteen is more seats than anything in the game has.
    if pedNetIDs ~= nil and (type(pedNetIDs) ~= 'table' or #pedNetIDs > 16) then
        refuse(src, 'unit registration', 'crew list is not a list of at most 16 ids')
        return
    end

    local cap = FenixGuard.ownedCap()

    local function register(netID, kind)
        if type(netID) ~= 'number' then return end
        local entity = NetworkGetEntityFromNetworkId(netID)
        if not entity or entity == 0 or not DoesEntityExist(entity) then return end

        -- Checked per entity, not once up front: one registration can carry a
        -- vehicle and its whole crew.
        if ownedCountFor(src) >= cap then
            refuse(src, 'unit registration', ('already owns %d entities'):format(cap))
            return
        end

        -- Unknown (an older server build) is let through: refusing every
        -- registration would leave nothing recorded to clean up.
        if createdBy(entity, src) == false then
            refuse(src, 'unit registration', 'entity was not created by this player')
            return
        end

        if belongsToAPlayer(entity) then
            refuse(src, 'unit registration', 'entity is a player, or a vehicle a player is in')
            return
        end

        local entityType = GetEntityType(entity)
        local model = GetEntityModel(entity)
        local allowed = (kind == 'vehicle' and entityType == 2 and allowedVehicles[model])
                     or (kind == 'ped' and entityType == 1 and allowedPeds[model])
        if not allowed then
            refuse(src, 'unit registration', ('model %s is not a police %s'):format(model, kind))
            return
        end

        -- Never let a registration steal an entity somebody else already owns.
        local existing = owned[netID]
        if existing and existing.src ~= src then
            refuse(src, 'unit registration', 'entity already owned by another player')
            return
        end

        FenixGuard.claim(src, netID, kind)
    end

    register(tonumber(vehNetID), 'vehicle')
    for _, pedNetID in ipairs(pedNetIDs or {}) do
        register(tonumber(pedNetID), 'ped')
    end

    dbg(('registered a ground unit for %s'):format(GetPlayerName(src) or src))
end)

-------------------------------------------------------------------------------
-- Diagnostics
-------------------------------------------------------------------------------

RegisterCommand('fenixguard', function(source)
    -- Console only. Player id 0 is the server console in FiveM.
    if source ~= 0 then return end

    local v, p = 0, 0
    for _ in pairs(allowedVehicles) do v = v + 1 end
    for _ in pairs(allowedPeds) do p = p + 1 end

    local perPlayer = {}
    local total = 0
    for _, rec in pairs(owned) do
        perPlayer[rec.src] = (perPlayer[rec.src] or 0) + 1
        total = total + 1
    end

    local pending = 0
    for _ in pairs(tickets) do pending = pending + 1 end

    print(('[FENIX-GUARD] allowlist %d vehicle / %d ped model(s)'):format(v, p))
    print(('[FENIX-GUARD] %d entity/entities owned, %d ticket(s) outstanding'):format(total, pending))
    print(('[FENIX-GUARD] strictOwnership = %s'):format(tostring(cfg().strictOwnership ~= false)))
    for src, n in pairs(perPlayer) do
        print(('  %s (%s): %d'):format(GetPlayerName(src) or 'gone', tostring(src), n))
    end
end, true)
