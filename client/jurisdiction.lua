--[[
    client/jurisdiction.lua

    Which agency's problem you currently are.

    Config.vehiclesByRegion + Config.ZoneEnum already ARE a jurisdiction model
    — client.lua's getPlayerZoneCode()/getZoneKey() resolve the player's GTA
    zone (GetNameOfZone) to a region key, and that key picks which agency's
    vehicles and peds spawn. Los Santos gets LSPD, Paleto/Sandy Shores/the
    countryside get the Sheriff. That part has worked all along.

    What never existed is anyone reacting to a CROSSING. Drive from Los Santos
    into the county mid-pursuit today and nothing happens: the LSPD units
    already on scene keep fighting under LSPD livery forever, nothing goes out
    over the radio, and the only thing that changes is which agency a BRAND
    NEW spawn happens to draw from. This file adds the reaction, on top of the
    lookup that already existed rather than replacing it.

    FenixJurisdiction.currentRegion() is a superset of getZoneKey(
    getPlayerZoneCode()): it checks Config.Jurisdiction.zones first — the same
    box/cylinder/poly shape client/roads.lua's exclusion zones use, for a
    server that wants a boundary finer than GTA's own (huge, few) named zones
    — and falls back to the GTA zone lookup when nothing custom matches. A
    server that configures no custom zones sees byte-for-byte the same region
    result as before this file existed.
]]

FenixJurisdiction = {}

local function cfg() return Config.Jurisdiction or {} end
local function dbg(msg) if cfg().debug then print('[FENIX-JURISDICTION] ' .. msg) end end

-------------------------------------------------------------------------------
-- Zone matching — same shape and logic as client/roads.lua's exclusion zones,
-- duplicated rather than shared. The two mean different things (roads.lua's
-- zones gate where a car may appear; these gate who owns the ground) and
-- client/tactics.lua already sets the precedent of copying roads.lua's small
-- geometry helpers locally instead of reaching across files for them.
-------------------------------------------------------------------------------

local function pointInPoly(poly, x, y)
    local inside = false
    local j = #poly
    for i = 1, #poly do
        local a, b = poly[i], poly[j]
        if ((a.y > y) ~= (b.y > y))
            and (x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x) then
            inside = not inside
        end
        j = i
    end
    return inside
end

local function inZone(zone, x, y, z)
    if zone.enabled == false then return false end

    if z then
        if z < (zone.zMin or -2000.0) or z > (zone.zMax or 2000.0) then return false end
    end

    if zone.min and zone.max then
        return x >= zone.min.x and x <= zone.max.x
           and y >= zone.min.y and y <= zone.max.y
    end

    if zone.center and zone.radius then
        local dx, dy = x - zone.center.x, y - zone.center.y
        return (dx * dx + dy * dy) <= (zone.radius * zone.radius)
    end

    if zone.poly then
        return pointInPoly(zone.poly, x, y)
    end

    return false
end

--- The custom-zone answer only, or nil when nothing configured matches.
local function customRegionAt(coords)
    local zones = cfg().zones
    if type(zones) ~= 'table' then return nil end

    for _, zone in ipairs(zones) do
        if inZone(zone, coords.x, coords.y, coords.z) then
            return zone.region, zone.name
        end
    end
    return nil
end

--- The existing GTA-named-zone fallback. Reimplemented here rather than
--- called back into client.lua (which defines getPlayerZoneCode/getZoneKey/
--- spawnPoliceUnitNet's own lookup as locals, not globals) — this walks the
--- exact same chain spawnPoliceUnitNet does: GetNameOfZone returns a zone
--- CODE ('ZP_ORT'), Config.zones[code] holds that zone's descriptive
--- {name, location}, and Config.ZoneEnum[location] is the actual region key.
--- Falls all the way back to 'losSantos' on a miss, matching
--- spawnPoliceUnitNet's own default for an unmapped zone.
local function nativeRegionAt(coords)
    local zoneCode = GetNameOfZone(coords.x, coords.y, coords.z)
    local zone = Config.zones[zoneCode]
    if not zone then return 'losSantos' end
    return Config.ZoneEnum[zone.location] or 'losSantos'
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

--- The jurisdiction/region key that owns this point, for indexing straight
--- into Config.vehiclesByRegion.
function FenixJurisdiction.regionAt(coords)
    if cfg().enabled == false then return nativeRegionAt(coords) end

    local region, zoneName = customRegionAt(coords)
    if region then
        dbg(('%.0f, %.0f resolved via custom zone "%s" -> %s'):format(coords.x, coords.y, zoneName, region))
        return region
    end

    return nativeRegionAt(coords)
end

-- Cached per-cycle so repeated calls in the same tick (spawn selection,
-- crossing detection) don't each re-run the zone loop / native zone lookup.
local cachedRegion, cachedAt = nil, 0

--- The player's current region, recomputed at most once per game tick.
function FenixJurisdiction.currentRegion()
    local now = GetGameTimer()
    if cachedRegion and now == cachedAt then return cachedRegion end

    cachedRegion = FenixJurisdiction.regionAt(GetEntityCoords(PlayerPedId()))
    cachedAt = now
    return cachedRegion
end

-------------------------------------------------------------------------------
-- Crossing detection
-------------------------------------------------------------------------------
--
-- Deliberately not a CreateThread here — client.lua's own maintainPoliceUnits
-- tick already runs once a second and already needs to know the current
-- region for spawn selection, so it calls FenixJurisdiction.checkCrossing()
-- itself once per pass rather than this file running a second competing
-- timer against the same state.

local lastRegion = nil

--- Call once per maintainPoliceUnits pass. Returns fromRegion, toRegion when a
--- crossing just happened during an active pursuit, or nil otherwise —
--- client.lua uses a non-nil return to hand its currently-spawned units to
--- FenixMorale's retreat/regroup machinery and to key the radio handoff call.
function FenixJurisdiction.checkCrossing(pursuitActive)
    if cfg().enabled == false then return nil end

    local region = FenixJurisdiction.currentRegion()

    if lastRegion == nil then
        lastRegion = region
        return nil
    end

    if region == lastRegion then return nil end

    local from = lastRegion
    lastRegion = region

    if not pursuitActive then
        -- Wandering between regions with nobody chasing you is just driving
        -- around; nothing hands off because nothing is currently responding.
        return nil
    end

    dbg(('crossing: %s -> %s'):format(tostring(from), tostring(region)))

    if cfg().handoffRadio ~= false and FenixPursuit and FenixPursuit.announceHandoff then
        FenixPursuit.announceHandoff(from, region)
    end

    return from, region
end

RegisterCommand('fenixjurisdiction', function()
    local region = FenixJurisdiction.currentRegion()
    print(('[FENIX-JURISDICTION] current region: %s'):format(tostring(region)))
end, false)
