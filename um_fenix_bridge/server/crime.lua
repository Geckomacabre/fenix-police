-- ============================================================================
-- server/crime.lua
-- Crime -> AI police dispatch.
--
-- The robbery scripts on this server all stop at "notify the player cops". When
-- nobody is on duty that means a bank job produces no response whatsoever. This
-- listens for those alerts and puts a wanted level on the people responsible;
-- fenix-police already polls the wanted level and spawns units off the back of
-- it, so that is the entire integration.
--
-- Where a hook hands us the offender we use it. Where it only gives a location
-- (the escrowed halves of the loaf scripts, ps-dispatch payloads) we fall back
-- to everyone standing near the scene, which is what fenix's own robbery hook
-- does too.
-- ============================================================================

local CRIME = BridgeConfig.Crime or {}

if CRIME.enabled == false then return end

local RADIUS      = CRIME.radius or 60.0
local COOLDOWN_MS = CRIME.cooldownMs or 30000

-- [src] = { [tag] = ms of last dispatch }
local lastDispatch = {}

local function log(fmt, ...)
    if not (BridgeConfig.Debug and BridgeConfig.Debug.log) then return end
    print(('[um_fenix_bridge] ' .. fmt):format(...))
end

-- ============================================================================
-- Targeting
-- ============================================================================

local function toVec3(coords)
    if not coords then return nil end
    if type(coords) == 'vector3' then return coords end
    if type(coords) == 'vector4' then return vector3(coords.x, coords.y, coords.z) end
    if type(coords) == 'table' then
        local x, y, z = coords.x or coords[1], coords.y or coords[2], coords.z or coords[3]
        if x and y and z then return vector3(x + 0.0, y + 0.0, z + 0.0) end
    end
    return nil
end

local function playersNear(coords)
    local out = {}
    if not coords then return out end

    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        local ped = GetPlayerPed(src)

        if ped and ped ~= 0 then
            if #(GetEntityCoords(ped) - coords) <= RADIUS then
                out[#out + 1] = src
            end
        end
    end

    return out
end

-- ============================================================================
-- Dispatch
-- ============================================================================

--- Puts a wanted level on everyone this crime is pinned on.
---@param tag string        crime tag, keyed into BridgeConfig.Crime.stars
---@param coords? vector3|table  where it happened; used when src is unknown
---@param src? number       the offender, when the hook tells us who it was
---@param starsOverride? number  used where the count is per-item, not per-tag
local function report(tag, coords, src, starsOverride)
    local stars = starsOverride or (CRIME.stars and CRIME.stars[tag])

    if not stars or stars <= 0 then
        log('crime "%s" ignored (no stars configured)', tostring(tag))
        return
    end

    local targets

    if src and GetPlayerName(src) then
        targets = { src }
    else
        targets = playersNear(toVec3(coords))
    end

    if #targets == 0 then
        log('crime "%s" had nobody to pin it on', tostring(tag))
        return
    end

    local now = GetGameTimer()

    for i = 1, #targets do
        local ply = targets[i]
        local seen = lastDispatch[ply]

        if not seen then
            seen = {}
            lastDispatch[ply] = seen
        end

        -- Bank jobs alert once per door, per hack and per loot bag. Without this
        -- each of those would re-apply the stars and reset fenix's evasion timer,
        -- making the wanted level effectively permanent.
        if seen[tag] and (now - seen[tag]) < COOLDOWN_MS then
            log('crime "%s" on ply %s still on cooldown', tostring(tag), ply)
        else
            seen[tag] = now
            -- SetWantedLevel, not ApplyWantedLevel: it takes the higher of the
            -- current and requested level instead of adding to it.
            TriggerClientEvent('fenix-police:client:SetWantedLevel', ply, stars)
            log('crime "%s" -> %s stars on ply %s', tostring(tag), stars, ply)
        end
    end
end

--- Public entry point for anything that wants to summon AI police.
exports('reportCrime', function(tag, coords, src) report(tag, coords, src) end)

--- Server-side event form, for resources that would rather not use exports.
AddEventHandler('um_fenix_bridge:crime', function(tag, coords, src)
    report(tag, coords, src)
end)

--- Client-side form. Deliberately only ever applies to the caller: a player can
--- use this to make themselves wanted and nothing else.
RegisterNetEvent('um_fenix_bridge:client:crime', function(tag)
    local src = source
    if type(tag) ~= 'string' then return end
    report(tag, nil, src)
end)

AddEventHandler('playerDropped', function()
    lastDispatch[source] = nil
end)

-- ============================================================================
-- Hooks
--
-- Resources that already fire something usable are picked up here. The three
-- that don't (loaf_bankrobbery, um_truckrobbery, um_HouseRobberys) call into
-- this file from their own editable config/alert functions instead.
-- ============================================================================

-- loaf_storerobbery: fires with the robber's server id, so no guessing needed.
AddEventHandler('loaf_storerobbery:robberyStarted', function(src, storeId)
    log('loaf_storerobbery started by ply %s at store %s', tostring(src), tostring(storeId))
    report('store_robbery', nil, src)
end)

-- police:server:policeAlert has no handler on this server -- qb-policejob isn't
-- installed and dispatch runs through ps-dispatch -- so everything firing it
-- currently alerts nobody at all. qbx_jewelery passes the offender as the third
-- argument; qbx_vehiclekeys and jewelery_heist fire it from the client, where
-- `source` is the offender anyway.
RegisterNetEvent('police:server:policeAlert', function(text, _, alertSrc)
    if not CRIME.catchAllPoliceAlert then return end

    local src = (type(alertSrc) == 'number' and GetPlayerName(alertSrc)) and alertSrc or source
    if not src or src == 0 or not GetPlayerName(src) then return end

    -- The jewellery scripts are the loud ones worth their own tier; everything
    -- else that uses this event gets the generic alert level.
    local tag = 'police_alert'
    if type(text) == 'string' and text:lower():find('jewel') then
        tag = 'jewelry_heist'
    end

    report(tag, nil, src)
end)

-- ps-dispatch catch-all. Off by default: the per-resource hooks already cover
-- the robberies, and this would also fire for EMS and low-grade alerts.
AddEventHandler('ps-dispatch:server:notify', function(data)
    if not CRIME.catchAllDispatch then return end
    if type(data) ~= 'table' then return end

    report('dispatch', data.coords)
end)

-- em_toolkit: every mission, heist finale and game-mode run funnels through
-- this one event, so listing a mission id in BridgeConfig.Crime.emMissions is
-- enough to make it a police matter.
AddEventHandler('em_toolkit:missionStarted', function(id)
    local src = source
    if not src or src == 0 then return end

    -- Opt-in per mission: `true` uses the em_mission tier, a number overrides
    -- it. Unlisted missions bring no police, which is what you want for the
    -- deliveries and errands sharing this event with the robberies.
    local entry = (CRIME.emMissions or {})[id]
    if not entry then return end

    report('em_mission', nil, src, type(entry) == 'number' and entry or nil)
end)
