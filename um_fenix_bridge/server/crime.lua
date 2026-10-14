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

--- Did this handler run with no network sender? A resource firing an event
--- server-side with TriggerEvent arrives with `source` set to "" -- not 0 --
--- so a `source == 0` test never recognises it and every such call reads as
--- coming from a player who doesn't exist.
local function isServer(s)
    return s == nil or s == '' or s == 0
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

    -- alertSrc is only trustworthy when this fired via a local TriggerEvent
    -- (no network caller, see isServer) -- that's qbx_jewelery's own server
    -- code reporting on someone else's behalf. A real network call already IS
    -- the offender -- qbx_vehiclekeys fires this about itself -- and a
    -- client-supplied alertSrc must never override it, or a modified client
    -- could frame an arbitrary victim with wanted stars and summoned police.
    local src = source
    if isServer(src) then
        src = tonumber(alertSrc)
    end
    if not src or not GetPlayerName(src) then return end

    -- The jewellery scripts are the loud ones worth their own tier; everything
    -- else that uses this event gets the generic alert level.
    local tag = 'police_alert'
    if type(text) == 'string' and text:lower():find('jewel') then
        tag = 'jewelry_heist'
    end

    report(tag, nil, src)
end)

-- ps-dispatch catch-all. Off by default: the per-resource hooks already cover
-- the robberies, and this would also fire for low-grade alerts.
--
-- ps-dispatch raises its alerts from the client doing the thing the alert is
-- about (TriggerServerEvent), so this has to be a net event here too -- a bare
-- AddEventHandler never sees a client-sent event. A networked alert stars its
-- sender only, never whoever data.coords points at: those coordinates come
-- from the same client. Only a server-side TriggerEvent, which has no
-- sender, falls back to everyone near data.coords.
RegisterNetEvent('ps-dispatch:server:notify', function(data)
    if not CRIME.catchAllDispatch then return end
    if type(data) ~= 'table' then return end

    -- An alert only for medics or firefighters is about a casualty, raised
    -- from the casualty's own client -- fenix-police's aftermath sends
    -- InjuriedPerson for a player its officers just put down. Starring the
    -- sender of one of those restarts the pursuit on whoever is lying there.
    if type(data.jobs) == 'table' and #data.jobs > 0 then
        local medicalOnly = true
        for _, job in ipairs(data.jobs) do
            if job ~= 'ems' and job ~= 'ambulance' and job ~= 'fire' then
                medicalOnly = false
                break
            end
        end
        if medicalOnly then return end
    end

    local src = source
    if isServer(src) then
        report('dispatch', data.coords)
    else
        report('dispatch', nil, src)
    end
end)

-- em_toolkit: every mission, heist finale and game-mode run funnels through
-- this one event, so listing a mission id in BridgeConfig.Crime.emMissions is
-- enough to make it a police matter.
--
-- Registered as a net event so both ways em_toolkit might send it work. From
-- a client, `source` is the player starting the mission (and all a client
-- can do with it is star itself). From the server (TriggerEvent) there is no
-- sender, so the player has to come from the event itself: a server id, or a
-- list of them, as the argument after the mission id. em_toolkit's payload
-- beyond the id isn't documented anywhere this bridge can see; with neither,
-- the mission has nobody to pin it on and is skipped (logged with Debug.log
-- on).
RegisterNetEvent('em_toolkit:missionStarted', function(id, players)
    -- Opt-in per mission: `true` uses the em_mission tier, a number overrides
    -- it. Unlisted missions bring no police, which is what you want for the
    -- deliveries and errands sharing this event with the robberies.
    local entry = (CRIME.emMissions or {})[id]
    if not entry then return end
    local stars = type(entry) == 'number' and entry or nil

    local src = source
    if not isServer(src) then
        report('em_mission', nil, src, stars)
        return
    end

    if type(players) ~= 'table' then players = { players } end
    local reported = false
    for _, ply in ipairs(players) do
        local plySrc = tonumber(ply)
        if plySrc and GetPlayerName(plySrc) then
            report('em_mission', nil, plySrc, stars)
            reported = true
        end
    end
    if not reported then
        log('em_toolkit mission "%s" started server-side with no player to pin it on', tostring(id))
    end
end)
