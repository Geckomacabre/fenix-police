-------------------------------------------------------------------------------
-- Agency liveries for multi-livery add-on cruisers (Upstate Mafia).
--
-- The ONX EVP cars ([cars]/onx-evp-c-pack, onx-evp-c-pack2) are one model per
-- car with every agency's paint job on it as a livery MOD (mod type 48,
-- VMT_LIVERY_MOD), each labelled LIV_LSPD / LIV_BCSO / LIV_SAHP / ... in the
-- pack's carcols.meta. Spawned bare, a car carries no agency at all, so the
-- same model would read as the wrong department half the map away.
--
-- This picks the livery by LABEL, not by index -- GET_MOD_TEXT_LABEL returns
-- the carcols modShopLabel, so the lookup survives a pack update reordering its
-- liveries, and a stock car (no type-48 mods) is a silent no-op. See
-- Config.Liveries for which label goes where.
--
-- Also owns the "is this add-on model actually here" fallback, so a pack that
-- fails to start (entitlement lapsed, resource stopped) degrades to stock
-- cruisers instead of pursuit units silently never spawning.
-------------------------------------------------------------------------------

FenixLivery = {}

local LIVERY_MOD = 48 -- VMT_LIVERY_MOD

local function cfg() return Config.Liveries or {} end
local function dbg(msg) if cfg().debug then print('[FENIX-LIVERY] ' .. msg) end end

--- Region key (Config.ZoneEnum value) that owns `coords`. Defers to
--- client/jurisdiction.lua when it's loaded, so custom jurisdiction zones apply
--- to paint jobs too; otherwise the plain GTA-zone lookup.
function FenixLivery.regionAt(coords)
    if FenixJurisdiction and FenixJurisdiction.regionAt then
        return FenixJurisdiction.regionAt(coords)
    end
    local zone = Config.zones[GetNameOfZone(coords.x, coords.y, coords.z)]
    return (zone and Config.ZoneEnum[zone.location]) or 'losSantos'
end

--- Whether this client can actually spawn `model` right now.
function FenixLivery.isInstalled(model)
    if type(model) ~= 'string' then return false end
    local hash = GetHashKey(model)
    return IsModelInCdimage(hash) and IsModelAVehicle(hash)
end

--- `model` if it's installed; otherwise `fallback` (an entry's own stock
--- stand-in, e.g. police4 for an unmarked unit) if given and installed;
--- otherwise a stock cruiser for the region at `coords` from
--- Config.Ambient.vehicleFallback (base-game models, always present). Every
--- one of these is on server/guard.lua's allowlist.
function FenixLivery.resolveModel(model, coords, fallback)
    if FenixLivery.isInstalled(model) then return model end
    if FenixLivery.isInstalled(fallback) then
        dbg(('%s is not installed, using its fallback %s'):format(tostring(model), fallback))
        return fallback
    end

    local pool = Config.Ambient and Config.Ambient.vehicleFallback
    local list = pool and (pool[FenixLivery.regionAt(coords)] or pool.losSantos)
    local fallback = (list and #list > 0) and list[math.random(#list)] or 'police'
    dbg(('%s is not installed, using %s'):format(tostring(model), fallback))
    return fallback
end

--- Strips a multi-livery car back to an unmarked look: no livery, the
--- configured extras (roof lightbar) off, one of the plain paint colours.
local function styleUnmarked(vehicle)
    local u = cfg().unmarked or {}
    RemoveVehicleMod(vehicle, LIVERY_MOD)
    for _, extra in ipairs(u.extrasOff or { 1 }) do
        if DoesExtraExist(vehicle, extra) then SetVehicleExtra(vehicle, extra, true) end
    end
    local colours = u.colours
    if type(colours) == 'table' and #colours > 0 then
        local c = colours[math.random(#colours)]
        SetVehicleColours(vehicle, c, c)
    end
end

--- The livery label(s) FenixLivery.apply would pick for `vehicle` if it were
--- standing at `coords` right now -- byModel precedence, then byRegion for
--- `coords` (NOT the vehicle's actual current position). Exposed for
--- callers that re-purpose an already-liveried vehicle for use somewhere
--- other than where it happens to be standing (client/investigate.lua's
--- ambient-patrol reuse: the vehicle's livery reflects wherever it was
--- originally spawned, which may not be the incident it's now being sent
--- to). Returns nil when Config.Liveries is disabled or nothing matches.
function FenixLivery.labelsFor(vehicle, coords)
    if cfg().enabled == false then return nil end

    local byModel = cfg().byModel or {}
    for name, labels in pairs(byModel) do
        if GetEntityModel(vehicle) == GetHashKey(name) then return labels end
    end

    local byRegion = cfg().byRegion or {}
    local region = FenixLivery.regionAt(coords)
    return byRegion[region] or byRegion.losSantos
end

--- Paints `vehicle` with an agency livery. `override` (a label or a list of
--- labels, e.g. a Config.vehiclesByRegion entry's `livery`) wins, then
--- Config.Liveries.byModel, then Config.Liveries.byRegion for wherever the car
--- is standing. When several labels are listed, one the car actually has is
--- picked at random. `unmarked` skips all of that and styles the car plain
--- instead. Safe on any vehicle: stock cars have no livery mods and are left
--- untouched.
function FenixLivery.apply(vehicle, override, unmarked)
    if cfg().enabled == false then return end
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return end
    if GetNumModKits(vehicle) <= 0 then
        dbg(('%s has no mod kits yet (spawned this tick?), skipping livery'):format(GetDisplayNameFromVehicleModel(GetEntityModel(vehicle))))
        return
    end

    SetVehicleModKit(vehicle, 0)
    local count = GetNumVehicleMods(vehicle, LIVERY_MOD)
    if not count or count <= 0 then return end

    if unmarked then
        styleUnmarked(vehicle)
        return
    end

    local wanted = override
    if wanted == nil then
        local byModel = cfg().byModel or {}
        for name, labels in pairs(byModel) do
            if GetEntityModel(vehicle) == GetHashKey(name) then wanted = labels break end
        end
    end
    if wanted == nil then
        local byRegion = cfg().byRegion or {}
        local region = FenixLivery.regionAt(GetEntityCoords(vehicle))
        wanted = byRegion[region] or byRegion.losSantos
    end
    if type(wanted) == 'string' then wanted = { wanted } end
    if type(wanted) ~= 'table' then return end

    local available = {}
    for i = 0, count - 1 do
        local label = GetModTextLabel(vehicle, LIVERY_MOD, i)
        if label and available[label] == nil then available[label] = i end
    end

    local options = {}
    for _, label in ipairs(wanted) do
        if available[label] then options[#options + 1] = available[label] end
    end
    if #options == 0 then
        dbg(('no livery from {%s} on this model; leaving it as spawned'):format(table.concat(wanted, ', ')))
        return
    end

    SetVehicleMod(vehicle, LIVERY_MOD, options[math.random(#options)], false)
end
