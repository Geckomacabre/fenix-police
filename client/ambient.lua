--[[
    client/ambient.lua

    Ambient police presence — the map dressing that Config.Ambient describes.

    Deliberately independent of client/client.lua: it shares no state with the
    pursuit system, only reads GetPlayerWantedLevel to know when to get out of
    the way. Everything it creates is client-local (non-networked), protected
    from the population manager with SetEntityAsMissionEntity, and deleted by
    handle. No net IDs, no server round-trips, no ownership races.

    Scene kinds:
      radar    fixed point  cruiser parked facing traffic, officer inside
      post     fixed point  officers on foot playing scenarios at a station
      stop     procedural   NPC pulled over, officer writing at the window
      patrol   procedural   cruiser driving a normal route, no siren
      pursuit  procedural   NPC fleeing, cruisers chasing with sirens
]]

local scenes = {}       -- sceneId -> scene record
local nextSceneId = 1
local claimedPoints = {} -- "kind:index" -> sceneId, stops two scenes on one point
local ambientGroup = nil
local runtimeEnabled = true
local lastSpawnAttempt = 0
local toolkitPoints = nil -- extra points from the em_toolkit connector, if present

local function cfg() return Config.Ambient or {} end
local function ambientOn() return cfg().enabled == true and runtimeEnabled end
local function dbg(msg) if cfg().debug then print('[FENIX-AMBIENT] ' .. msg) end end

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function loadModel(hash)
    if not IsModelValid(hash) then return false end
    RequestModel(hash)
    local waited = 0
    while not HasModelLoaded(hash) and waited < 150 do
        Wait(10)
        waited = waited + 1
    end
    return HasModelLoaded(hash)
end

local function pick(list)
    if not list or #list == 0 then return nil end
    return list[math.random(#list)]
end

--- Is this model something the client can actually spawn? Add-on vehicle packs
--- are the reason this exists: the region lists name models from packs a given
--- server may not run, and a missing pack has to be an entry that's skipped, not
--- a spawn that fails.
local function modelInstalled(modelName)
    return type(modelName) == 'string' and IsModelValid(GetHashKey(modelName))
end

--- Pick from a model table, skipping anything `valid` rejects.
---
--- Two accepted shapes, because the region vehicle lists gained weights and the
--- old format still has to work. `list[1] ~= nil` tells them apart:
---   array  { 'police', 'police2' }     picked uniformly
---   map    { police = 4, sheriff = 1 } picked by relative weight
---
--- Filtering happens inside the roll rather than after it, so an uninstalled
--- model never consumes a pick — a region weighted mostly toward a pack you
--- don't have still returns the models you do.
local function pickWeighted(list, valid)
    if not list then return nil end

    if list[1] ~= nil then
        local pool = {}
        for _, model in ipairs(list) do
            if not valid or valid(model) then pool[#pool + 1] = model end
        end
        return pick(pool)
    end

    local total = 0
    for model, weight in pairs(list) do
        if type(weight) == 'number' and weight > 0 and (not valid or valid(model)) then
            total = total + weight
        end
    end
    if total <= 0 then return nil end

    local roll, acc = math.random() * total, 0
    for model, weight in pairs(list) do
        if type(weight) == 'number' and weight > 0 and (not valid or valid(model)) then
            acc = acc + weight
            if roll <= acc then return model end
        end
    end
end

--- Region key for the player's current zone, matching Config.ZoneEnum.
--- Reimplemented here rather than reaching into client.lua, whose zone helpers
--- are file-locals.
local function regionKey()
    local coords = GetEntityCoords(PlayerPedId())
    local zoneCode = GetNameOfZone(coords.x, coords.y, coords.z)
    local zone = Config.zones[zoneCode]
    if zone and Config.ZoneEnum[zone.location] then
        return Config.ZoneEnum[zone.location]
    end
    return 'losSantos'
end

local function regionList(tbl)
    local key = regionKey()
    return (tbl and (tbl[key] or tbl.losSantos)) or nil
end

--- Cruiser model for an ambient scene in the player's current region.
---
--- Every scene that spawns a police vehicle goes through here, so agency mix is
--- decided in one place: Config.Ambient.vehicles carries the weights, and this
--- drops through to Config.Ambient.vehicleFallback (stock police / sheriff) when
--- none of the weighted models are installed.
local function regionVehicle()
    local model = pickWeighted(regionList(cfg().vehicles), modelInstalled)
    if model then return model end
    return pick(regionList(cfg().vehicleFallback)) or 'police'
end

--- Weighted pick over Config.Ambient.weights, skipping kinds weighted 0.
local function pickSceneKind()
    local weights = cfg().weights or {}
    local total = 0
    for _, w in pairs(weights) do
        if type(w) == 'number' and w > 0 then total = total + w end
    end
    if total <= 0 then return nil end

    local roll = math.random() * total
    local acc = 0
    for kind, w in pairs(weights) do
        if type(w) == 'number' and w > 0 then
            acc = acc + w
            if roll <= acc then return kind end
        end
    end
end

--- Distance from `pos` to the nearest live scene, or math.huge when there are
--- none. Walks only the scenes this script owns (never more than maxScenes), so
--- it costs nothing next to a world scan.
local function distToNearestScene(pos)
    local best = math.huge
    for _, scene in pairs(scenes) do
        local reference = scene.anchor
        local lead = scene.vehicles[1]
        if lead and DoesEntityExist(lead) then reference = GetEntityCoords(lead) end
        local d = #(reference - pos)
        if d < best then best = d end
    end
    return best
end

--- Best placement between minSpawnDistance and maxSpawnDistance.
---
--- The road maths -- resolving a sample point to a real road, working out where
--- its lanes actually are, and picking a direction that road legally permits --
--- all lives in client/roads.lua, shared with the pursuit spawner so the two
--- systems cannot drift apart on what counts as a valid spot. What stays here is
--- the part that is specific to ambient scenes: keeping them spread out, and
--- never letting one appear on screen.
---
--- Returns coords, heading -- or nil if nothing usable is nearby (deep water,
--- wilderness, airside, or everything in range already occupied).
--- @param opts table { shoulder? = park on the verge, avoidVisible? = never spawn on screen }
local function bestRoadNode(playerCoords, opts)
    opts = opts or {}
    local c = cfg()

    return FenixRoads.findSpawnPoint(playerCoords, {
        minDistance  = c.minSpawnDistance,
        maxDistance  = c.maxSpawnDistance,
        attempts     = c.nodeSamples or 10,
        shoulder     = opts.shoulder,
        avoidVisible = opts.avoidVisible and c.avoidVisibleSpawns ~= false,
        towards      = playerCoords,

        -- Anti-clump: keep ambient scenes spread across the map, not stacked
        -- three-deep on one street.
        reject = function(pos)
            return distToNearestScene(pos) < (c.minSceneSpacing or 90.0)
        end,

        -- Junction nodes are legal but a parked scene on one blocks the box for
        -- real traffic, so they lose to anything else in range.
        score = function(pos)
            local ok, _, flags = GetVehicleNodeProperties(pos.x, pos.y, pos.z)
            if ok and flags and (flags & 8) ~= 0 then return -25.0 end
            return 0.0
        end,
    })
end

--- Fixed points of `kind` (shipped list + toolkit list) that are in range and
--- not already claimed by a live scene.
local function candidatePoints(kind, playerCoords)
    local c = cfg()
    local out = {}

    -- `exact` marks a point somebody stood (or parked) on and captured through
    -- em_toolkit. The shipped list is documented as approximate and is snapped to
    -- roads and ground at spawn time; doing that to a hand-placed point drags it
    -- off the spot that was picked deliberately, so exact points are used
    -- verbatim instead.
    local function consider(list, tag)
        if type(list) ~= 'table' then return end
        for i, p in ipairs(list) do
            local key = ('%s:%s:%d'):format(tag, kind, i)
            if not claimedPoints[key] then
                local pos = vector3(p.x, p.y, p.z)
                local d = #(pos - playerCoords)
                -- Spacing applies to authored points too, so two points placed
                -- close together don't both fire and read as a police convention.
                -- Visibility deliberately does NOT: you should be able to stand
                -- and watch a point you just placed come to life.
                if d >= c.minSpawnDistance and d <= c.maxSpawnDistance
                    and distToNearestScene(pos) >= (c.minSceneSpacing or 90.0) then
                    out[#out + 1] = { point = p, key = key, exact = (tag == 'kit') }
                end
            end
        end
    end

    consider(FenixAmbientPoints and FenixAmbientPoints[kind], 'base')
    consider(toolkitPoints and toolkitPoints[kind], 'kit')
    return out
end

--- Ambient officers are police dressing, not combatants. Neutral relationship
--- group so they never open fire on their own; if the player shoots one, normal
--- ped reactions and the wanted system take it from there.
local function ensureAmbientGroup()
    if ambientGroup then return ambientGroup end
    local name = cfg().relationshipGroup or 'FENIX_AMBIENT'
    AddRelationshipGroup(name)
    ambientGroup = GetHashKey(name)
    SetRelationshipBetweenGroups(1, ambientGroup, GetHashKey('PLAYER'))
    SetRelationshipBetweenGroups(1, GetHashKey('PLAYER'), ambientGroup)
    return ambientGroup
end

local function createPed(modelName, x, y, z, heading, isCop)
    if type(modelName) ~= 'string' then return nil end
    local hash = GetHashKey(modelName)
    if not loadModel(hash) then return nil end

    local ped = CreatePed(4, hash, x, y, z, heading or 0.0, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not DoesEntityExist(ped) then return nil end

    -- Non-networked peds are fair game for the population manager without this.
    SetEntityAsMissionEntity(ped, true, true)
    SetPedDropsWeaponsWhenDead(ped, false)

    if isCop then
        local c = cfg()
        SetPedRelationshipGroupHash(ped, ensureAmbientGroup())
        if c.weapon then
            GiveWeaponToPed(ped, GetHashKey(c.weapon), 250, false, false)
        end
        local acc = c.accuracy or { 8, 18 }
        SetPedAccuracy(ped, math.random(acc[1], acc[2]))
        SetPedArmour(ped, 25)
    end
    return ped
end

local function createVehicle(modelName, x, y, z, heading)
    if type(modelName) ~= 'string' then return nil end
    local hash = GetHashKey(modelName)
    if not loadModel(hash) then return nil end

    local veh = CreateVehicle(hash, x, y, z, heading or 0.0, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not DoesEntityExist(veh) then return nil end

    SetEntityAsMissionEntity(veh, true, true)
    SetVehicleOnGroundProperly(veh)
    SetVehicleHasBeenOwnedByPlayer(veh, false)
    return veh
end

local function destroyScene(scene)
    if scene.releaseOnTeardown then
        -- The scene already drove off under its own power. Hand the cars and
        -- their drivers to the population manager instead of deleting them, so
        -- nothing vanishes mid-drive in front of the player.
        for _, ped in ipairs(scene.peds) do
            if DoesEntityExist(ped) then
                SetEntityAsMissionEntity(ped, false, false)
                SetPedAsNoLongerNeeded(ped)
            end
        end
        for _, veh in ipairs(scene.vehicles) do
            if DoesEntityExist(veh) then
                SetEntityAsMissionEntity(veh, false, false)
                SetVehicleAsNoLongerNeeded(veh)
            end
        end
    else
        for _, ped in ipairs(scene.peds) do
            if DoesEntityExist(ped) then DeleteEntity(ped) end
        end
        for _, veh in ipairs(scene.vehicles) do
            if DoesEntityExist(veh) then DeleteEntity(veh) end
        end
    end

    -- Borrowed world traffic caught by a radar trap. We never created these, so
    -- they get released back to the population manager rather than deleted —
    -- deleting them would blink real traffic out in front of the player.
    local b = scene.borrowed
    if b then
        if b.driver and DoesEntityExist(b.driver) then
            ClearPedTasks(b.driver)
            SetEntityAsMissionEntity(b.driver, false, false)
            SetPedAsNoLongerNeeded(b.driver)
        end
        if b.veh and DoesEntityExist(b.veh) then
            SetEntityAsMissionEntity(b.veh, false, false)
            SetVehicleAsNoLongerNeeded(b.veh)
        end
        scene.borrowed = nil
    end

    if scene.pointKey then claimedPoints[scene.pointKey] = nil end
    scenes[scene.id] = nil
    dbg(('destroyed %s scene #%d'):format(scene.kind, scene.id))
end

local function destroyAllScenes()
    for _, scene in pairs(scenes) do destroyScene(scene) end
    scenes = {}
    claimedPoints = {}
end

local function newScene(kind, anchor, pointKey)
    local scene = {
        id = nextSceneId,
        kind = kind,
        anchor = anchor,
        pointKey = pointKey,
        peds = {},
        vehicles = {},
        cops = 0, -- officers only; civilians don't count toward the area budget
    }
    nextSceneId = nextSceneId + 1
    if pointKey then claimedPoints[pointKey] = scene.id end
    return scene
end

--- Record a ped on a scene. `isCop` feeds the nearby-officer budget, which is
--- why civilians (pulled-over drivers, fleeing suspects) go through here too.
local function trackPed(scene, ped, isCop)
    scene.peds[#scene.peds + 1] = ped
    if isCop then scene.cops = scene.cops + 1 end
    return ped
end

--- Commit a scene, or roll it back if a spawn step failed partway through.
local function commitScene(scene, ok)
    if ok and #scene.vehicles + #scene.peds > 0 then
        scenes[scene.id] = scene
        dbg(('spawned %s scene #%d (%d veh, %d ped)'):format(scene.kind, scene.id, #scene.vehicles, #scene.peds))
        return true
    end
    destroyScene(scene)
    return false
end

-------------------------------------------------------------------------------
-- Scene builders
-------------------------------------------------------------------------------

--- Cruiser parked on the shoulder facing oncoming traffic, officer inside.
local function spawnRadar(playerCoords)
    local candidates = candidatePoints('radar', playerCoords)
    local anchor, roadHeading, pointKey
    local exact = false
    local pointVehicle, pointSpeed
    -- Which way the cruiser ends up pointing, and — once a snap has run — where
    -- it sits. nil until something sets it, so the `exact` and unsnapped paths
    -- below can tell that no road placement happened.
    local facing

    if #candidates > 0 then
        local chosen = candidates[math.random(#candidates)]
        local p = chosen.point
        pointKey = chosen.key
        exact = chosen.exact
        anchor = vector3(p.x, p.y, p.z)
        roadHeading = p.h or 0.0
        -- Per-trap overrides authored in em_toolkit; nil falls through to the
        -- regional vehicle list and the config-wide trigger speed.
        pointVehicle, pointSpeed = p.vehicle, p.speed

        if cfg().snapToRoad and not exact then
            -- Snap onto the verge the car will actually face down. `p.h` is the
            -- road's direction; a trap watches the traffic coming the other way,
            -- so the placement is resolved against h+180 and the shoulder picked
            -- for THAT direction. Doing it the other way round — snap to h, then
            -- flip the car — is what parks a cruiser facing oncoming traffic
            -- from the far verge, which is the wrong side of the road.
            --
            -- On a one-way street the opposite direction has no lanes, so the
            -- snap falls back to the legal direction and the trap simply faces
            -- with the flow. That is correct: there is no oncoming traffic.
            local snapRadius = (FenixAmbientPoints and FenixAmbientPoints.snapRadius) or 120.0
            local pos, snapHeading, snapped = FenixRoads.snapToLane(
                anchor, (roadHeading + 180.0) % 360.0, {
                    shoulder = true,
                    maxSnap  = snapRadius,
                })
            if snapped then
                anchor, facing = pos, snapHeading
            end
        end
    elseif cfg().radarFallbackToRoadNodes then
        -- No seed point in range: fall back to a scored road placement so radar
        -- traps still appear in areas the shipped list doesn't cover. Off by
        -- default — with authored points this is the main source of "cops
        -- everywhere".
        --
        -- bestRoadNode aims the direction of travel at the player, so the verge
        -- it returns is the one a car facing that direction parks on, and the
        -- heading already looks up the road at anyone driving towards the trap.
        -- No flip: flipping here would put the trap on the far verge.
        local pos, travelHeading = bestRoadNode(playerCoords, { shoulder = true, avoidVisible = true })
        if not pos then return false end
        anchor, facing = pos, travelHeading or 0.0
    else
        return false
    end

    local scene = newScene('radar', anchor, pointKey)

    local x, y, heading

    if exact then
        -- Placed by parking the cruiser on the spot and capturing it, so the
        -- capture already IS where the car goes and which way it faces. Any
        -- offset or flip here would move it off the chosen spot.
        x, y, heading = anchor.x, anchor.y, roadHeading
    elseif facing then
        -- A road placement ran: the anchor is already a verge position and
        -- `facing` is already the direction the car looks. Offsetting again here
        -- is what used to push traps two shoulder-widths into the scenery.
        x, y, heading = anchor.x, anchor.y, facing
    else
        -- Approximate authored point with snapToRoad off. No road data to work
        -- from, so fall back to the old hand-rolled offset: GTA heading h has
        -- forward = (-sin h, cos h), so the road's right-hand side is
        -- (cos h, sin h). Slide onto that verge and face back down the road at
        -- oncoming traffic — the classic speed-trap read.
        local roads = Config.Roads or {}
        local off = (roads.laneWidth or 3.5) + (roads.shoulderOffset or 1.5)
        local rad = math.rad(roadHeading)
        x = anchor.x + math.cos(rad) * off
        y = anchor.y + math.sin(rad) * off
        heading = (roadHeading + 180.0) % 360.0
    end

    local veh = createVehicle(pointVehicle or regionVehicle(), x, y, anchor.z + 0.5, heading)
    if not veh and pointVehicle then
        -- Authored model missing from the server (never streamed, addon removed).
        -- Fall back rather than losing the trap entirely.
        dbg(('radar point vehicle "%s" failed to load, using regional default'):format(pointVehicle))
        veh = createVehicle(regionVehicle(), x, y, anchor.z + 0.5, heading)
    end
    if not veh then return commitScene(scene, false) end
    scene.vehicles[1] = veh
    SetVehicleEngineOn(veh, true, true, false)
    SetVehicleLights(veh, 0)

    -- Arms the radar for this scene; nil threshold means the config default.
    scene.radarSpeed = pointSpeed

    local cop = createPed(pick(regionList(cfg().peds)), x, y, anchor.z + 0.5, heading, true)
    if not cop then return commitScene(scene, false) end
    trackPed(scene, cop, true)
    SetPedIntoVehicle(cop, veh, -1)

    return commitScene(scene, true)
end

--- Officers on foot playing scenarios at a station or landmark.
local function spawnPost(playerCoords)
    local candidates = candidatePoints('post', playerCoords)
    if #candidates == 0 then return false end

    local chosen = candidates[math.random(#candidates)]
    local p = chosen.point
    local anchor = vector3(p.x, p.y, p.z)

    -- Exact points were captured by standing on the ground in question, so the
    -- safe-coord search (which can drag an officer up to 25m onto a pavement)
    -- only applies to the approximate shipped seeds.
    if not chosen.exact then
        local found, safe = GetSafeCoordForPed(p.x, p.y, p.z, true, 16)
        if found and safe and #(vector3(safe.x, safe.y, safe.z) - anchor) < 25.0 then
            anchor = vector3(safe.x, safe.y, safe.z)
        end
    end

    local scene = newScene('post', anchor, chosen.key)
    local count = math.max(1, math.min(p.count or 2, 4))
    local scenarios = cfg().footScenarios or {}

    for i = 1, count do
        -- Spread the post out so officers aren't stacked on one another.
        local spread = math.rad(math.random() * 360.0)
        local radius = (i == 1) and 0.0 or (1.5 + math.random() * 2.5)
        local px = anchor.x + math.cos(spread) * radius
        local py = anchor.y + math.sin(spread) * radius

        local cop = createPed(pick(regionList(cfg().peds)), px, py, anchor.z, p.h or 0.0, true)
        if cop then
            trackPed(scene, cop, true)
            local scenario = pick(scenarios)
            if scenario then
                TaskStartScenarioInPlace(cop, scenario, 0, true)
            else
                TaskStandStill(cop, -1)
            end
        end
    end

    return commitScene(scene, #scene.peds > 0)
end

--- NPC pulled over: civilian car on the shoulder, cruiser behind with its
--- lights on (muted), officer at the driver's window writing a ticket.
--- Last traffic stop, so they stay occasional rather than lining the route.
local lastStopAt = -math.huge

local function spawnStop(playerCoords)
    -- Same reasoning as the pursuit cooldown above. A traffic stop is a thing
    -- you come across, and the weights alone cannot say that: `stop` is only 3
    -- of 15, but radar traps also end up as a cruiser stopped behind a civilian
    -- car, so the two together read as one scene type at roughly double the
    -- weight. Without a floor between them you turn a corner and there is
    -- another one.
    local c = cfg()
    local now = GetGameTimer()
    if now - lastStopAt < (c.stopCooldownSeconds or 150) * 1000 then return false end

    -- Static scene: put it on the verge, not in a lane.
    local pos, heading = bestRoadNode(playerCoords, { shoulder = true, avoidVisible = true })
    if not pos then return false end

    local scene = newScene('stop', pos, nil)

    local civVeh = createVehicle(pick(cfg().civVehicles), pos.x, pos.y, pos.z + 0.5, heading)
    if not civVeh then return commitScene(scene, false) end
    scene.vehicles[1] = civVeh
    SetVehicleEngineOn(civVeh, false, true, false)
    SetVehicleLights(civVeh, 1)

    -- Cruiser 8m behind the civilian car, lights on but silent.
    local behind = GetOffsetFromEntityInWorldCoords(civVeh, 0.0, -8.0, 0.0)
    local copVeh = createVehicle(regionVehicle(), behind.x, behind.y, behind.z + 0.5, heading)
    if not copVeh then return commitScene(scene, false) end
    scene.vehicles[2] = copVeh
    SetVehicleEngineOn(copVeh, true, true, false)
    SetVehicleSiren(copVeh, true)
    SetVehicleHasMutedSirens(copVeh, true) -- flashing lights, no wail
    SetSirenKeepOn(copVeh, true)

    -- Driver stays in the civilian car.
    local driver = createPed(pick(cfg().civPeds), pos.x, pos.y, pos.z + 0.5, heading, false)
    if driver then
        trackPed(scene, driver, false)
        SetPedIntoVehicle(driver, civVeh, -1)
    end

    -- Officer at the driver's window. The offset puts them on the car's left;
    -- heading-90 turns them back toward it (forward(h-90) == the car's right).
    local atWindow = GetOffsetFromEntityInWorldCoords(civVeh, -1.9, -0.6, 0.0)
    local cop = createPed(pick(regionList(cfg().peds)), atWindow.x, atWindow.y, atWindow.z, heading - 90.0, true)
    if cop then
        trackPed(scene, cop, true)
        TaskStartScenarioInPlace(cop, 'WORLD_HUMAN_CLIPBOARD', 0, true)
    end

    -- Spawned mid-stop, so the clock starts here: after stopDurationSeconds the
    -- officer wraps up and both cars pull away.
    scene.stop = {
        phase = 'dwelling', since = GetGameTimer(),
        cop = cop, copVeh = copVeh,
        civVeh = civVeh, civDriver = driver,
        borrowed = false,
    }

    -- Only once the scene is real. Starting the cooldown on a failed attempt
    -- would silently suppress stops for the next couple of minutes over a
    -- placement that never happened.
    lastStopAt = GetGameTimer()

    return commitScene(scene, true)
end

--- Cruiser driving a normal route with no siren.
local function spawnPatrol(playerCoords)
    -- Moving scene: spawns on the carriageway and drives off, so no shoulder.
    local pos, heading = bestRoadNode(playerCoords, { avoidVisible = true })
    if not pos then return false end

    local scene = newScene('patrol', pos, nil)
    scene.expiresAt = GetGameTimer() + (cfg().roamingLifetime or 180) * 1000

    local veh = createVehicle(regionVehicle(), pos.x, pos.y, pos.z + 0.5, heading)
    if not veh then return commitScene(scene, false) end
    scene.vehicles[1] = veh
    SetVehicleEngineOn(veh, true, true, false)

    local cop = createPed(pick(regionList(cfg().peds)), pos.x, pos.y, pos.z + 0.5, heading, true)
    if not cop then return commitScene(scene, false) end
    trackPed(scene, cop, true)
    SetPedIntoVehicle(cop, veh, -1)

    SetDriverAbility(cop, 0.9)
    SetDriverAggressiveness(cop, 0.2)
    -- Driving style 786603: obeys lights, avoids traffic, no shortcuts.
    TaskVehicleDriveWander(cop, veh, 16.0, 786603)

    return commitScene(scene, true)
end

--- Last convoy start, so it stays an occasional sight rather than the normal
--- traffic pattern.
local lastConvoyAt = -math.huge

--- Two or three cruisers travelling together, lights and sirens off — backup
--- en route to a call that never renders, rather than a pursuit or a stop.
---
--- This is a deliberate version of something that already happened by
--- accident: independent `patrol` scenes, spawned close enough together and
--- started on the same road, drift into a loose convoy on their own, because
--- TaskVehicleDriveWander just keeps a car on whatever road it is already on.
--- It looked good and cost three times what it should have — three scene
--- slots and three officers out of the nearby-cops budget for one visual.
--- This is the same look, on purpose, for the price of one scene.
local function spawnConvoy(playerCoords)
    local c = cfg()
    local now = GetGameTimer()
    if now - lastConvoyAt < (c.convoyCooldownSeconds or 240) * 1000 then return false end

    -- Moving scene: spawns on the carriageway and drives off, same as patrol.
    local pos, heading = bestRoadNode(playerCoords, { avoidVisible = true })
    if not pos then return false end

    local count = 2
    if math.random() < (c.convoyThirdCarChance or 0.35) then count = 3 end

    local scene = newScene('convoy', pos, nil)
    scene.expiresAt = now + (c.convoyLifetime or c.roamingLifetime or 180) * 1000

    -- Heading h has forward = (-sin h, cos h) — see the header comment in
    -- client/roads.lua. Trailing cars are placed back along that line, nose to
    -- tail, so the group reads as one unit travelling together rather than a
    -- coincidence of timing.
    local rad = math.rad(heading)
    local bx, by = -math.sin(rad), math.cos(rad)
    local spacing = c.convoySpacing or 9.0

    -- One model for the whole convoy. Matching cars is what sells "these are
    -- travelling together" — a mixed cruiser and sheriff truck reads as two
    -- coincidental patrols instead.
    local model = regionVehicle()
    local peds = regionList(c.peds)

    for i = 0, count - 1 do
        local x = pos.x - (bx * spacing * i)
        local y = pos.y - (by * spacing * i)
        local z = pos.z

        -- The lead position already cleared bestRoadNode's own checks.
        -- Trailing spots are new ground — parked traffic, a postbox, whatever's
        -- actually there — and get the same emptiness test so a cruiser doesn't
        -- spawn through something.
        if i == 0 or FenixRoads.isSpawnable(vector3(x, y, z), { clearance = 2.5 }) then
            local veh = createVehicle(model, x, y, z + 0.5, heading)
            if veh then
                scene.vehicles[#scene.vehicles + 1] = veh
                SetVehicleEngineOn(veh, true, true, false)

                local cop = createPed(pick(peds), x, y, z + 0.5, heading, true)
                if cop then
                    trackPed(scene, cop, true)
                    SetPedIntoVehicle(cop, veh, -1)
                    SetDriverAbility(cop, 0.9)
                    SetDriverAggressiveness(cop, 0.15)
                    -- Same style and speed as spawnPatrol — the one that let
                    -- independent patrols drift together in the first place.
                    -- Deliberate here, so the group holds together instead of
                    -- scattering at the first junction the way three unrelated
                    -- patrols would.
                    TaskVehicleDriveWander(cop, veh, 14.0, 786603)
                end
            end
        end
    end

    if #scene.vehicles == 0 then return commitScene(scene, false) end

    -- Only once the scene is real — the same reasoning spawnStop uses for its
    -- own cooldown timer.
    lastConvoyAt = now

    return commitScene(scene, true)
end

--- Last pursuit start, so a chase stays an event rather than background noise.
local lastPursuitAt = -math.huge

--- Weighted pick of how a pursuit ends. Every chase resolves — the old version
--- just drove in circles until roamingLifetime culled it, which is why they read
--- as filler.
local function pickPursuitOutcome()
    local w = cfg().pursuitOutcomes or { bail = 4, surrender = 4, crash = 2 }
    local total = 0
    for _, n in pairs(w) do if type(n) == 'number' and n > 0 then total = total + n end end
    if total <= 0 then return 'surrender' end

    local roll, acc = math.random() * total, 0
    for kind, n in pairs(w) do
        if type(n) == 'number' and n > 0 then
            acc = acc + n
            if roll <= acc then return kind end
        end
    end
    return 'surrender'
end

--- NPC vehicle running from one or two cruisers with sirens up.
local function spawnPursuit(playerCoords)
    local c = cfg()

    -- A pursuit every couple of minutes stops feeling like an event. Gate it
    -- behind a cooldown separate from the scene weights, because the weights
    -- alone can't express "rare but memorable".
    local now = GetGameTimer()
    if now - lastPursuitAt < (c.pursuitCooldownSeconds or 300) * 1000 then return false end

    -- Moving scene: spawns on the carriageway and drives off, so no shoulder.
    local pos, heading = bestRoadNode(playerCoords, { avoidVisible = true })
    if not pos then return false end

    local scene = newScene('pursuit', pos, nil)
    -- Longer than roamingLifetime: a pursuit needs room to run, resolve, and be
    -- watched. advancePursuit shortens this once it ends.
    scene.expiresAt = GetGameTimer() + ((c.pursuitLifetime or 300) * 1000)

    local suspectVeh = createVehicle(pick(cfg().civVehicles), pos.x, pos.y, pos.z + 0.5, heading)
    if not suspectVeh then return commitScene(scene, false) end
    scene.vehicles[1] = suspectVeh
    SetVehicleEngineOn(suspectVeh, true, true, false)

    local suspect = createPed(pick(cfg().civPeds), pos.x, pos.y, pos.z + 0.5, heading, false)
    if not suspect then return commitScene(scene, false) end
    trackPed(scene, suspect, false)
    SetPedIntoVehicle(suspect, suspectVeh, -1)
    SetDriverAbility(suspect, 1.0)
    SetDriverAggressiveness(suspect, 1.0)
    -- Style 786469: rushed, ignores lights — reads as fleeing.
    TaskVehicleDriveWander(suspect, suspectVeh, 45.0, 786469)

    local chaserCount = math.random(1, 2)
    for i = 1, chaserCount do
        local behind = GetOffsetFromEntityInWorldCoords(suspectVeh, (i == 2) and 3.0 or 0.0, -12.0 * i, 0.0)
        local copVeh = createVehicle(regionVehicle(), behind.x, behind.y, behind.z + 0.5, heading)
        if copVeh then
            scene.vehicles[#scene.vehicles + 1] = copVeh
            SetVehicleEngineOn(copVeh, true, true, false)
            SetVehicleSiren(copVeh, true)
            SetSirenKeepOn(copVeh, true)

            local cop = createPed(pick(regionList(cfg().peds)), behind.x, behind.y, behind.z + 0.5, heading, true)
            if cop then
                trackPed(scene, cop, true)
                SetPedIntoVehicle(cop, copVeh, -1)
                SetDriverAbility(cop, 1.0)
                SetDriverAggressiveness(cop, 1.0)
                SetPedCombatAttributes(cop, 3, false) -- stay in the car
                TaskVehicleChase(cop, suspect)
                SetTaskVehicleChaseBehaviorFlag(cop, 8, true)
            end
        end
    end

    local window = cfg().pursuitChaseSeconds or { 35, 75 }
    scene.pursuit = {
        phase = 'fleeing',
        since = GetGameTimer(),
        -- Randomised so two pursuits don't resolve on the same beat.
        endsAfter = math.random(window[1] or 35, window[2] or 75) * 1000,
        outcome = pickPursuitOutcome(),
        suspect = suspect,
        veh = suspectVeh,
    }

    lastPursuitAt = GetGameTimer()
    return commitScene(scene, true)
end

--- Take a pursuit from "racing around" to an actual ending.
---
--- Three outcomes, all converging on the same arrest tableau:
---   surrender  suspect pulls over and gives up at the roadside
---   bail       suspect stops, bolts on foot, and is run down
---   crash      engine gives out, then surrender
---
--- Officers only leave their cars once the chase is over, so nothing interferes
--- with the driving tasks while it's still running.
local function advancePursuit(scene)
    local p = scene.pursuit
    if not p then return end

    if not DoesEntityExist(p.suspect) then
        scene.pursuit = nil
        return
    end

    local now = GetGameTimer()
    local elapsed = now - p.since

    local function officersOut()
        for i = 2, #scene.vehicles do
            local copVeh = scene.vehicles[i]
            if copVeh and DoesEntityExist(copVeh) then
                SetVehicleSiren(copVeh, true)
                SetVehicleHasMutedSirens(copVeh, true) -- lights only once it's over
            end
        end
        for _, cop in ipairs(scene.peds) do
            if cop ~= p.suspect and DoesEntityExist(cop) and IsPedInAnyVehicle(cop, false) then
                TaskLeaveVehicle(cop, GetVehiclePedIsIn(cop, false), 0)
            end
        end
    end

    if p.phase == 'fleeing' then
        if elapsed < p.endsAfter then return end
        p.phase, p.since = p.outcome, now

        if p.outcome == 'crash' then
            -- Blown engine rather than a scripted collision: the car coasts to a
            -- halt wherever it happens to be, which looks like a real breakdown.
            if DoesEntityExist(p.veh) then
                SetVehicleEngineHealth(p.veh, 0.0)
                SetVehicleUndriveable(p.veh, true)
            end
        else
            if DoesEntityExist(p.veh) then BringVehicleToHalt(p.veh, 8.0, 3, false) end
        end
        dbg(('pursuit resolving: %s'):format(p.outcome))

    elseif p.phase == 'crash' then
        if elapsed < 3500 then return end
        p.phase, p.since = 'surrender', now

    elseif p.phase == 'surrender' then
        if elapsed < 2500 then return end
        p.phase, p.since = 'giving_up', now

        ClearPedTasks(p.suspect)
        TaskLeaveVehicle(p.suspect, p.veh, 0)
        officersOut()

    elseif p.phase == 'bail' then
        if elapsed < 2000 then return end
        p.phase, p.since = 'on_foot', now

        ClearPedTasks(p.suspect)
        TaskLeaveVehicle(p.suspect, p.veh, 0)
        SetPedMoveRateOverride(p.suspect, 1.15)
        officersOut()

    elseif p.phase == 'on_foot' then
        -- Foot chase: suspect runs, officers converge. Ends when they're caught
        -- or when they've had a decent run.
        local caught = false
        local suspectPos = GetEntityCoords(p.suspect)

        for _, cop in ipairs(scene.peds) do
            if cop ~= p.suspect and DoesEntityExist(cop) and not IsPedInAnyVehicle(cop, false) then
                TaskGoToEntity(cop, p.suspect, -1, 1.0, 3.0, 1073741824, 0)
                if #(GetEntityCoords(cop) - suspectPos) < 2.5 then caught = true end
            end
        end

        if not IsPedInAnyVehicle(p.suspect, false) and elapsed > 1500 then
            local flee = scene.peds[2]
            if flee and DoesEntityExist(flee) then
                TaskSmartFleePed(p.suspect, flee, 100.0, -1, false, false)
            end
        end

        if caught or elapsed > (cfg().pursuitFootChaseSeconds or 25) * 1000 then
            p.phase, p.since = 'giving_up', now
            ClearPedTasks(p.suspect)
        end

    elseif p.phase == 'giving_up' then
        if elapsed < 2500 then return end
        p.phase, p.since = 'arrested', now

        -- Hands up, then down on the floor. Same anim set the player arrest uses,
        -- so an ambient bust and a real one read identically.
        RequestAnimDict('random@arrests@busted')
        if HasAnimDictLoaded('random@arrests@busted') then
            TaskPlayAnim(p.suspect, 'random@arrests@busted', 'idle_a', 8.0, -8.0, -1, 1, 0, false, false, false)
        else
            TaskHandsUp(p.suspect, 60000, 0, -1, false)
        end

        for _, cop in ipairs(scene.peds) do
            if cop ~= p.suspect and DoesEntityExist(cop) and not IsPedInAnyVehicle(cop, false) then
                TaskTurnPedToFaceEntity(cop, p.suspect, 2000)
                TaskAimGunAtEntity(cop, p.suspect, 8000, false)
            end
        end

    elseif p.phase == 'arrested' then
        if elapsed < (cfg().pursuitHoldSeconds or 20) * 1000 then return end
        -- Let the tableau sit, then release everyone back to the world.
        scene.releaseOnTeardown = true
        scene.expiresAt = now
        scene.pursuit = nil
    end
end

--- Ambient carjacking: a suspect drags a driver out of their car and takes off.
---
--- Concept reference: FivePD-2.0's `FivePD.Gamemode.IA.AmbientEvents` module,
--- which describes itself as handling "various ambient events around players
--- (e.x.: carjackings or speeders)" but ships as a stub. The speeder half is the
--- radar enforcement above; this is the other half.
---
--- Written from that one-line description only. No code was taken from that
--- project: it is AGPL-3.0, and copying from it would relicense this entire
--- bundle under AGPL, whose network clause would oblige offering full source to
--- every player who connects.
local function spawnCarjack(playerCoords)
    local pos, heading = bestRoadNode(playerCoords, { shoulder = true, avoidVisible = true })
    if not pos then return false end

    local c = cfg()
    local scene = newScene('carjack', pos, nil)
    scene.expiresAt = GetGameTimer() + (c.roamingLifetime or 180) * 1000

    local veh = createVehicle(pick(c.civVehicles), pos.x, pos.y, pos.z + 0.5, heading)
    if not veh then return commitScene(scene, false) end
    scene.vehicles[1] = veh
    SetVehicleEngineOn(veh, true, true, false)

    local victim = createPed(pick(c.civPeds), pos.x, pos.y, pos.z + 0.5, heading, false)
    if not victim then return commitScene(scene, false) end
    trackPed(scene, victim, false)
    SetPedIntoVehicle(victim, veh, -1)

    -- Suspect starts on the driver's side, a few metres back.
    local approach = GetOffsetFromEntityInWorldCoords(veh, -3.5, -1.5, 0.0)
    local suspect = createPed(pick(c.carjackSuspects or c.civPeds), approach.x, approach.y, approach.z, heading, false)
    if not suspect then return commitScene(scene, false) end
    trackPed(scene, suspect, false)

    SetPedCanBeDraggedOut(victim, true)
    -- Flag 16 makes TaskEnterVehicle jack whoever is already in the seat rather
    -- than politely wait for it to be free.
    TaskEnterVehicle(suspect, veh, 20000, -1, 2.0, 16, 0)

    scene.carjack = {
        phase = 'approaching', since = GetGameTimer(),
        veh = veh, victim = victim, suspect = suspect,
    }

    return commitScene(scene, true)
end

--- Drive the carjacking from "walking up" to "gone". Kept as a state machine on
--- the director's 1s tick rather than a per-scene thread, same as the traffic
--- stop wind-down.
local function advanceCarjack(scene)
    local cj = scene.carjack
    if not cj then return end

    if not DoesEntityExist(cj.suspect) or not DoesEntityExist(cj.veh) then
        scene.carjack = nil
        return
    end

    local now = GetGameTimer()

    if cj.phase == 'approaching' then
        if GetPedInVehicleSeat(cj.veh, -1) == cj.suspect then
            cj.phase, cj.since = 'fleeing', now

            if DoesEntityExist(cj.victim) then
                ClearPedTasks(cj.victim)
                TaskSmartFleePed(cj.victim, cj.suspect, 120.0, -1, false, false)
            end

            SetDriverAbility(cj.suspect, 1.0)
            SetDriverAggressiveness(cj.suspect, 1.0)
            -- Deliberately fast: quick enough that a radar trap down the road may
            -- well clock them, which turns a carjacking into a pursuit with no
            -- extra wiring at all.
            TaskVehicleDriveWander(cj.suspect, cj.veh, 30.0, 786469)

        elseif now - cj.since > 25000 then
            -- Approach never completed (blocked, victim fled early). Stop
            -- driving the scene and let the normal expiry collect it.
            scene.carjack = nil
        end
    end
end

local BUILDERS = {
    radar   = spawnRadar,
    post    = spawnPost,
    stop    = spawnStop,
    patrol  = spawnPatrol,
    convoy  = spawnConvoy,
    pursuit = spawnPursuit,
    carjack = spawnCarjack,
}

-------------------------------------------------------------------------------
-- Radar enforcement
--
-- A parked trap actually reads speed: anything crossing its cone above the
-- threshold gets picked up.
--
-- Players are handed straight to this resource's own pursuit stack via
-- ApplyWantedLevel rather than growing a second one here. That overlap is
-- precisely why sk_streetkings' trap module ships disabled — two systems
-- spawning their own pursuit AI is how you end up with cops dispatch has never
-- heard of.
--
-- NPCs never touch the wanted system. The trap car chases them itself and the
-- whole thing settles into a roadside stop that reuses the `stop` scene's look.
-------------------------------------------------------------------------------

local MPS_TO_MPH = 2.236936
local radarCooldown = {}  -- entity -> timer value it may be clocked again at
local npcScanTick = 0
local lastPlayerPos = nil -- previous sample, so fast cars can't tunnel the cone

local function radarCfg() return cfg().radar or {} end

local function thresholdFor(scene)
    return scene.radarSpeed or radarCfg().triggerSpeedMph or 60
end

--- Is `pos` within `range` of the observer and inside its cone? An aimed radar
--- trap watches the direction it was parked to watch, so cars behind it drive
--- past untouched. Pass coneDegrees = 360 for an officer who is simply looking
--- around — cos(180°) is -1, so the cone test always passes and this reduces to
--- a plain radius check.
local function inRadarCone(observer, pos, range, coneDegrees)
    local origin = GetEntityCoords(observer)
    local delta = pos - origin
    local dist = #delta
    if dist > range then return false end
    if dist < 1.0 then return true end

    local forward = GetEntityForwardVector(observer)
    local dot = (delta.x * forward.x + delta.y * forward.y) / dist
    return dot >= math.cos(math.rad((coneDegrees or 70.0) * 0.5))
end

--- Posted limit for a position, via the `speedlimits` resource. Returns the mph
--- a driver is judged against (posted + tolerance) plus the raw sign value, or
--- the unposted fallback where that street has no sign defined.
---@return number threshold, number|nil posted
local function postedThreshold(pos)
    local c = cfg().radar or {}

    if c.usePostedLimits ~= false and GetResourceState('speedlimits') == 'started' then
        local ok, posted = pcall(function()
            return exports['speedlimits']:getSpeedLimitAtCoords(pos.x, pos.y, pos.z)
        end)
        if ok and type(posted) == 'number' and posted > 0 then
            return posted + (c.toleranceMph or 15), posted
        end
    end

    return c.unpostedLimitMph or c.triggerSpeedMph or 80, nil
end

--- Did the path from `from` to `to` pass through the cone at any point?
---
--- Testing only the current position tunnels badly: at 150 mph a car covers ~27m
--- per 400ms tick, which is wider than the wedge a trap actually watches, so it
--- would sail through undetected between two samples. Walking the segment in ~8m
--- steps makes detection independent of how fast the car is going.
local function crossedRadarCone(observer, from, to, range, coneDegrees)
    if not from then return inRadarCone(observer, to, range, coneDegrees) end

    local travelled = #(to - from)
    -- A jump this large is a teleport or a respawn, not driving.
    if travelled > 300.0 then return inRadarCone(observer, to, range, coneDegrees) end

    local steps = math.min(16, math.max(1, math.ceil(travelled / 8.0)))
    local delta = to - from
    for i = 0, steps do
        if inRadarCone(observer, from + delta * (i / steps), range, coneDegrees) then
            return true
        end
    end
    return false
end

--- Whichever entity does the actual watching for a scene: the cruiser for a
--- radar trap or a patrol, the officer themselves for a foot post.
local function observerOf(scene)
    local veh = scene.vehicles[1]
    if veh and DoesEntityExist(veh) then return veh end
    local ped = scene.peds[1]
    if ped and DoesEntityExist(ped) then return ped end
    return nil
end

--- Did this scene's officers see it happen? An aimed trap watches its cone; a
--- patrol car or a foot officer just looks around, so they get a plain radius.
local function witnessed(scene, from, to)
    local c = cfg().radar or {}
    local observer = observerOf(scene)
    if not observer then return false end

    if scene.kind == 'radar' then
        return crossedRadarCone(observer, from, to, c.detectRange or 60.0, c.coneDegrees or 70.0)
    end
    return crossedRadarCone(observer, from, to, c.copDetectRange or 45.0, 360.0)
end

--- Is the local player on duty as police? Checked before enforcing so ambient
--- officers never pull over a player who is themselves policing — that job
--- belongs to night_ers, which owns player-side police RP on this server.
---
--- Two sources, either sufficient: this resource's own job check, and ERS's
--- shift state. Both behind pcall, because either can be absent.
local function playerIsOnDutyPolice()
    if (cfg().radar or {}).exemptPolice == false then return false end

    local ok, res = pcall(function() return exports['fenix-police']:IsPlayerPoliceOfficer() end)
    if ok and res == true then return true end

    ok, res = pcall(function() return exports['night_ers']:getIsPlayerOnShift() end)
    if ok and res == true then return true end

    return false
end

local function onCooldown(ent)
    local until_ = radarCooldown[ent]
    return until_ ~= nil and GetGameTimer() < until_
end

local function startCooldown(ent)
    radarCooldown[ent] = GetGameTimer() + ((radarCfg().cooldownSeconds or 45) * 1000)
end

--- Drop expired entries every pass so the cooldown table can't grow across a
--- session. It only ever holds vehicles clocked in the last cooldown window.
local function pruneCooldowns()
    local now = GetGameTimer()
    for ent, until_ in pairs(radarCooldown) do
        if now >= until_ then radarCooldown[ent] = nil end
    end
end

--- Player caught: hand off to the real pursuit system, and have the trap car
--- join in rather than just calling it in and sitting there.
local function catchPlayer(scene, veh, speedMph, threshold, posted)
    local c = radarCfg()
    startCooldown(veh)
    scene.enforcing = true -- exempts it from the despawnWhenWanted sweep

    -- %.0f, never %d: these are measurements, and string.format('%d', 152.34)
    -- raises "number has no integer representation" in Lua 5.3+. Throwing here
    -- would abort the catch *after* the cooldown and enforcing flag were already
    -- set, permanently disarming the scene without ever applying the wanted level.
    dbg(('%s officer clocked the player at %.0f mph (%s)'):format(
        scene.kind, speedMph,
        posted and ('%.0f posted, %.0f allowed'):format(posted, threshold)
            or ('%.0f unposted'):format(threshold)))

    -- Global from client.lua, same resource and same Lua state. Guarded because
    -- a failed client.lua would otherwise take the whole trap down with it.
    if type(ApplyWantedLevel) == 'function' then
        ApplyWantedLevel(c.playerWantedLevel or 1)
    end

    -- A foot officer has no car to give chase in: they call it in, and the
    -- pursuit system sends units. Only scenes whose officer is actually sat in
    -- the cruiser join the chase themselves.
    local copVeh, cop = scene.vehicles[1], scene.peds[1]
    if copVeh and cop and DoesEntityExist(copVeh) and DoesEntityExist(cop)
        and GetVehiclePedIsIn(cop, false) == copVeh then
        SetVehicleSiren(copVeh, true)
        SetSirenKeepOn(copVeh, true)
        SetDriverAbility(cop, 1.0)
        SetDriverAggressiveness(cop, 0.8)
        TaskVehicleChase(cop, PlayerPedId())
        SetTaskVehicleChaseBehaviorFlag(cop, 8, true)
        SetTaskVehicleChaseIdealPursuitDistance(cop, 25.0)
    end

    -- No longer a fixed scene once it's rolling: let it time out like a patrol
    -- instead of hanging on its point forever.
    scene.expiresAt = GetGameTimer() + (cfg().roamingLifetime or 180) * 1000
end

--- NPC caught: chase it down, no wanted system involved.
local function catchNpc(scene, veh, driver, speedMph)
    local copVeh, cop = scene.vehicles[1], scene.peds[1]
    if not (copVeh and cop and DoesEntityExist(copVeh) and DoesEntityExist(cop)) then return end

    startCooldown(veh)
    dbg(('radar clocked an NPC at %.0f mph'):format(speedMph))

    -- Borrowed, not created. These are world traffic: hold them for the chase,
    -- then hand them back to the population manager instead of deleting them.
    SetEntityAsMissionEntity(veh, true, true)
    SetEntityAsMissionEntity(driver, true, true)
    scene.borrowed = { veh = veh, driver = driver }
    scene.chase = { phase = 'chasing', since = GetGameTimer() }

    SetVehicleSiren(copVeh, true)
    SetSirenKeepOn(copVeh, true)
    SetDriverAbility(cop, 1.0)
    SetDriverAggressiveness(cop, 0.8)
    TaskVehicleChase(cop, driver)
    SetTaskVehicleChaseIdealPursuitDistance(cop, 12.0)

    -- Suspect makes a run for it, briefly. Style 786469: rushed, ignores lights.
    SetDriverAbility(driver, 0.8)
    TaskVehicleDriveWander(driver, veh, 32.0, 786469)

    scene.expiresAt = GetGameTimer() + (cfg().roamingLifetime or 180) * 1000
end

--- Walk a caught NPC from "running" to "pulled over with an officer at the
--- window", reusing the look spawnStop already establishes.
local function advanceNpcStop(scene)
    local ch = scene.chase
    local b = scene.borrowed
    if not ch or not b then return end

    if not DoesEntityExist(b.veh) or not DoesEntityExist(b.driver) then
        scene.chase = nil
        return
    end

    local c = radarCfg()
    local now = GetGameTimer()
    local cop, copVeh = scene.peds[1], scene.vehicles[1]

    if ch.phase == 'chasing' and now - ch.since > (c.npcYieldSeconds or 15) * 1000 then
        ch.phase, ch.since = 'yielding', now
        ClearPedTasks(b.driver)
        BringVehicleToHalt(b.veh, 12.0, 3, false)

    elseif ch.phase == 'yielding' and now - ch.since > 4000 then
        ch.phase, ch.since = 'approaching', now
        if cop and DoesEntityExist(cop) and copVeh and DoesEntityExist(copVeh) then
            SetVehicleHasMutedSirens(copVeh, true) -- lights, no wail, as `stop` does
            TaskLeaveVehicle(cop, copVeh, 0)
        end

    elseif ch.phase == 'approaching' and now - ch.since > 5000 then
        ch.phase, ch.since = 'stopped', now
        if cop and DoesEntityExist(cop) then
            -- Same offset spawnStop uses: driver's window, turned toward the car.
            local atWindow = GetOffsetFromEntityInWorldCoords(b.veh, -1.9, -0.6, 0.0)
            TaskGoStraightToCoord(cop, atWindow.x, atWindow.y, atWindow.z, 1.0, 8000,
                GetEntityHeading(b.veh) - 90.0, 0.5)
        end
        scene.expiresAt = now + 90000

    elseif ch.phase == 'stopped' and now - ch.since > 8000 then
        if cop and DoesEntityExist(cop) then
            TaskStartScenarioInPlace(cop, 'WORLD_HUMAN_CLIPBOARD', 0, true)
        end

        -- Hand over to the shared wind-down so a radar stop ends the same way a
        -- procedural one does, instead of standing there until it's culled.
        scene.stop = {
            phase = 'dwelling', since = now,
            cop = cop, copVeh = copVeh,
            civVeh = b.veh, civDriver = b.driver,
            borrowed = true,
        }
        scene.chase = nil
        scene.expiresAt = nil -- advanceStop sets a fresh one when they drive off
    end
end

--- Wind a traffic stop up and send everyone on their way. Shared by procedural
--- `stop` scenes and by radar traps that have pulled an NPC over — without it a
--- stop is a permanent tableau, an officer holding a clipboard until the player
--- walks far enough away for the cull to take it.
local function advanceStop(scene)
    local s = scene.stop
    if not s then return end

    local c = cfg()
    local now = GetGameTimer()
    local copAlive = s.cop and DoesEntityExist(s.cop)
    local copVehAlive = s.copVeh and DoesEntityExist(s.copVeh)

    if s.phase == 'dwelling' then
        if now - s.since < (c.stopDurationSeconds or 60) * 1000 then return end
        s.phase, s.since = 'wrapping', now

        -- Ticket written: officer heads back to the car.
        if copAlive and copVehAlive then
            ClearPedTasks(s.cop)
            TaskEnterVehicle(s.cop, s.copVeh, 15000, -1, 1.5, 1, 0)
        end

    elseif s.phase == 'wrapping' then
        local seated = copAlive and copVehAlive and GetVehiclePedIsIn(s.cop, false) == s.copVeh
        -- Don't wait forever on a walk-back that got stuck on geometry.
        if not seated and now - s.since < 16000 then return end
        s.phase, s.since = 'leaving', now

        if copVehAlive then
            SetVehicleSiren(s.copVeh, false)
            SetSirenKeepOn(s.copVeh, false)
        end
        if seated then
            SetDriverAbility(s.cop, 0.9)
            SetDriverAggressiveness(s.cop, 0.2)
            -- 786603: obeys lights, avoids traffic — same as an ambient patrol.
            TaskVehicleDriveWander(s.cop, s.copVeh, 16.0, 786603)
        end

        -- The stopped driver pulls back into traffic.
        if s.civDriver and DoesEntityExist(s.civDriver) and s.civVeh and DoesEntityExist(s.civVeh) then
            ClearPedTasks(s.civDriver)
            SetVehicleLights(s.civVeh, 0)
            TaskVehicleDriveWander(s.civDriver, s.civVeh, 16.0, 786603)
        end

        -- Borrowed traffic rejoins the world immediately; it was never ours.
        if s.borrowed then
            if s.civDriver and DoesEntityExist(s.civDriver) then
                SetEntityAsMissionEntity(s.civDriver, false, false)
                SetPedAsNoLongerNeeded(s.civDriver)
            end
            if s.civVeh and DoesEntityExist(s.civVeh) then
                SetEntityAsMissionEntity(s.civVeh, false, false)
                SetVehicleAsNoLongerNeeded(s.civVeh)
            end
            scene.borrowed = nil
        end

        -- Everyone is under way, so teardown must hand them over rather than
        -- delete them — otherwise the cars blink out mid-drive in front of you.
        scene.releaseOnTeardown = true
        scene.expiresAt = now + (c.stopDepartureSeconds or 25) * 1000
    end
end

--- A player who has pulled over for a scripted traffic stop is not being chased.
--- The trap car that clocked them is still carrying the TaskVehicleChase that
--- catchPlayer gave it, and left alone it circles and PITs a car that has
--- already stopped — in exactly the scenario the ticket system exists for.
---
--- `stoodDown` latches, so this re-tasks the car once rather than every second
--- for as long as the officer is writing.
local function standDownForTrafficStop()
    local ok, stopping = pcall(function()
        return exports['fenix-police']:IsPlayerAtTrafficStop()
    end)
    if not (ok and stopping == true) then return end

    for _, scene in pairs(scenes) do
        if scene.enforcing and not scene.stoodDown then
            scene.stoodDown = true
            local veh = scene.vehicles[1]
            if veh and DoesEntityExist(veh) then
                local driver = GetPedInVehicleSeat(veh, -1)
                if driver and driver ~= 0 and DoesEntityExist(driver) then
                    ClearPedTasks(driver)
                    BringVehicleToHalt(veh, 10.0, 3, false)
                end
                -- Lights, no wail: it's parked at a stop now, not running one.
                SetVehicleHasMutedSirens(veh, true)
            end
            dbg('enforcing scene stood down for a roadside stop')
        end
    end
end

--- One pass over every armed trap. Kept cheap on purpose: the player check needs
--- no pool walk at all, and the NPC pool is fetched once per scan (not per
--- scene) on a slower cadence than the player check.
local function radarTick()
    local c = radarCfg()
    pruneCooldowns()

    -- Every officer enforces, not just aimed traps: a patrol car or a foot post
    -- reacts to a car doing triple the limit past it, which is the whole point.
    local allCops = c.enforceFromAllCops ~= false

    local armed = {}
    for _, scene in pairs(scenes) do
        if scene.chase then
            advanceNpcStop(scene)
        elseif scene.cops > 0 and not scene.enforcing and not scene.stop
            and (allCops or scene.kind == 'radar') and observerOf(scene) then
            -- A scene conducting a stop is busy; its officer is out of the car
            -- and shouldn't be clocking the next thing that goes past.
            armed[#armed + 1] = scene
        end
    end
    if #armed == 0 then
        -- Drop the trail: the next armed scene should compare against a fresh
        -- sample, not against wherever the player was minutes ago.
        lastPlayerPos = nil
        return
    end

    if c.catchPlayers ~= false and not playerIsOnDutyPolice() then
        local playerPed = PlayerPedId()
        local playerVeh = GetVehiclePedIsIn(playerPed, false)
        -- Driver's seat only: a passenger isn't the one speeding.
        if playerVeh ~= 0 and GetPedInVehicleSeat(playerVeh, -1) == playerPed then
            local speed = GetEntitySpeed(playerVeh) * MPS_TO_MPH
            local pos = GetEntityCoords(playerVeh)
            local prev = lastPlayerPos
            lastPlayerPos = pos

            if not onCooldown(playerVeh) then
                -- One lookup per tick, not per scene: the posted limit depends on
                -- where the driver is, not on who is watching.
                local limit, posted = postedThreshold(pos)

                for _, scene in ipairs(armed) do
                    -- An authored trap speed overrides the posted sign entirely —
                    -- that's the point of setting one on a specific trap.
                    local threshold = scene.radarSpeed or limit
                    if speed >= threshold and witnessed(scene, prev, pos) then
                        catchPlayer(scene, playerVeh, speed, threshold, scene.radarSpeed and nil or posted)
                        break
                    end
                end
            end
        else
            lastPlayerPos = nil
        end
    end

    if c.catchNpcs == false then return end

    npcScanTick = npcScanTick + 1
    if npcScanTick < (c.npcScanEveryTicks or 2) then return end
    npcScanTick = 0

    -- NPC pursuits stay with aimed traps by default. Every patrol car chasing
    -- every speeding NPC turns the map into a permanent car chase, and unlike
    -- the player there is nobody to appreciate it.
    local npcCatchers = {}
    for _, scene in ipairs(armed) do
        if c.catchNpcsFromAllCops == true or scene.kind == 'radar' then
            npcCatchers[#npcCatchers + 1] = scene
        end
    end
    if #npcCatchers == 0 then return end

    -- NPCs are judged against the trap's own limit rather than the posted sign:
    -- resolving a street name per vehicle per tick is not worth it for traffic.
    local lowest = math.huge
    for _, scene in ipairs(npcCatchers) do
        local t = thresholdFor(scene)
        if t < lowest then lowest = t end
    end

    for _, veh in ipairs(GetGamePool('CVehicle')) do
        if not onCooldown(veh) then
            local speed = GetEntitySpeed(veh) * MPS_TO_MPH
            if speed >= lowest then
                local driver = GetPedInVehicleSeat(veh, -1)
                if driver ~= 0 and DoesEntityExist(driver) and not IsPedAPlayer(driver) then
                    local pos = GetEntityCoords(veh)
                    for _, scene in ipairs(npcCatchers) do
                        if not scene.chase and speed >= thresholdFor(scene)
                            and witnessed(scene, nil, pos) then
                            catchNpc(scene, veh, driver, speed)
                            break
                        end
                    end
                end
            end
        end
    end
end

CreateThread(function()
    while true do
        local c = radarCfg()
        Wait(c.tickMs or 400)
        if c.enabled ~= false and ambientOn() then
            local ok, err = pcall(radarTick)
            if not ok then print('[FENIX-AMBIENT] radar error: ' .. tostring(err)) end
        end
    end
end)

-------------------------------------------------------------------------------
-- em_toolkit connector (optional)
-------------------------------------------------------------------------------

--- Pull extra points placed with the em_toolkit connector. fenix-police runs
--- fine without em_toolkit; this is purely additive.
local function refreshToolkitPoints()
    if not cfg().useToolkitPoints then
        toolkitPoints = nil
        return
    end
    local ok, result = pcall(function()
        return exports['em_toolkit']:getPolicePoints()
    end)
    if ok and type(result) == 'table' then
        toolkitPoints = result
        local n = 0
        for _, list in pairs(result) do n = n + #list end
        dbg(('loaded %d point(s) from em_toolkit'):format(n))
    else
        toolkitPoints = nil
    end
end

RegisterNetEvent('em_toolkit:policePointsChanged', function()
    refreshToolkitPoints()
    -- Drop fixed-point scenes so the new list takes effect immediately.
    for _, scene in pairs(scenes) do
        if scene.pointKey then destroyScene(scene) end
    end
end)

-------------------------------------------------------------------------------
-- Director
-------------------------------------------------------------------------------

local function sceneCount()
    local n = 0
    for _ in pairs(scenes) do n = n + 1 end
    return n
end

--- Cull dead/distant/expired scenes and, in the same walk, total up how many
--- ambient officers are still standing near the player. Returning the count from
--- here is deliberate: the director needs it every tick, and this loop is already
--- computing each scene's reference position, so the budget costs no extra work
--- and no extra state — just an integer.
---@return integer nearbyCops
local function cullScenes(playerCoords)
    local c = cfg()
    local now = GetGameTimer()
    local nearbyCops = 0
    local nearbyRadius = c.nearbyRadius or 260.0

    for _, scene in pairs(scenes) do
        local alive = false
        for _, ent in ipairs(scene.peds) do
            if DoesEntityExist(ent) then alive = true end
        end
        for _, ent in ipairs(scene.vehicles) do
            if DoesEntityExist(ent) then alive = true end
        end

        -- Track roaming scenes by their lead entity, not their spawn point —
        -- a patrol car drives away from where it started.
        local reference = scene.anchor
        local lead = scene.vehicles[1]
        if lead and DoesEntityExist(lead) then reference = GetEntityCoords(lead) end

        local tooFar = #(reference - playerCoords) > c.cleanupDistance
        local expired = scene.expiresAt and now > scene.expiresAt

        if not alive or tooFar or expired then
            destroyScene(scene)
        elseif #(reference - playerCoords) <= nearbyRadius then
            nearbyCops = nearbyCops + scene.cops
        end
    end

    return nearbyCops
end

CreateThread(function()
    -- Let config.lua, the points file and the rest of the resource settle.
    Wait(4000)
    refreshToolkitPoints()

    while true do
        Wait(1000)

        local ok, err = pcall(function()
            if not ambientOn() then
                if sceneCount() > 0 then destroyAllScenes() end
                return
            end

            local playerPed = PlayerPedId()
            if not playerPed or playerPed == 0 then return end
            local playerCoords = GetEntityCoords(playerPed)

            -- Cull first, so an enforcing trap that has been rolling past its
            -- lifetime still gets cleaned up while the player is wanted.
            local nearbyCops = cullScenes(playerCoords)

            -- Scene sequences that play out over tens of seconds. One second is
            -- ample granularity, and keeping them here means no per-scene threads.
            for _, scene in pairs(scenes) do
                if scene.stop then advanceStop(scene) end
                if scene.carjack then advanceCarjack(scene) end
                if scene.pursuit then advancePursuit(scene) end
            end

            -- An enforcing trap survives the sweep below, so it is the one scene
            -- that can still be mid-chase when the player pulls over for a
            -- citation. Stand it down before that sweep returns.
            standDownForTrafficStop()

            -- Stay entirely out of the pursuit system's way — except for a trap
            -- that started this pursuit itself. Wiping the car mid-catch leaves a
            -- chase with no visible origin, which reads as a bug to the player.
            if cfg().despawnWhenWanted and GetPlayerWantedLevel(PlayerId()) > 0 then
                for _, scene in pairs(scenes) do
                    if not scene.enforcing then destroyScene(scene) end
                end
                return
            end

            local now = GetGameTimer()
            if sceneCount() >= (cfg().maxScenes or 4) then return end
            -- Area budget on top of the scene cap: a couple of multi-officer
            -- posts can hit "too many cops" long before maxScenes does.
            if nearbyCops >= (cfg().maxNearbyCops or 6) then return end
            if now - lastSpawnAttempt < (cfg().spawnInterval or 8) * 1000 then return end
            lastSpawnAttempt = now

            -- A builder legitimately fails when its prerequisites aren't there
            -- (no seed point in range, no road node, deep wilderness). Try a few
            -- kinds rather than burning the whole interval on one miss.
            for _ = 1, 3 do
                local kind = pickSceneKind()
                local builder = kind and BUILDERS[kind]
                if builder and builder(playerCoords) then break end
            end
        end)

        if not ok then
            print('[FENIX-AMBIENT] director error: ' .. tostring(err))
        end
    end
end)

-------------------------------------------------------------------------------
-- Commands & teardown
-------------------------------------------------------------------------------

RegisterCommand('ambientpolice', function(_, args)
    local arg = (args[1] or ''):lower()
    if arg == 'on' then
        runtimeEnabled = true
    elseif arg == 'off' then
        runtimeEnabled = false
    else
        runtimeEnabled = not runtimeEnabled
    end

    if not runtimeEnabled then destroyAllScenes() end

    local cops = 0
    for _, scene in pairs(scenes) do cops = cops + scene.cops end

    print(('[FENIX-AMBIENT] %s — %d/%d scene(s), %d/%d officer(s) nearby, %d toolkit point set(s)')
        :format(runtimeEnabled and 'ON' or 'OFF', sceneCount(), cfg().maxScenes or 4,
            cops, cfg().maxNearbyCops or 6, toolkitPoints and 1 or 0))

    -- Which scenes are actually live, so "I drove past a cop and nothing
    -- happened" can be answered: only `radar` scenes read speed at all.
    local me = GetEntityCoords(PlayerPedId())
    for _, scene in pairs(scenes) do
        local lead = scene.vehicles[1] or scene.peds[1]
        local where = (lead and DoesEntityExist(lead)) and GetEntityCoords(lead) or scene.anchor
        local state
        if scene.chase then
            state = 'chasing an NPC'
        elseif scene.stop then
            state = 'conducting a stop'
        elseif scene.enforcing then
            state = 'already triggered a pursuit'
        elseif scene.cops == 0 or not observerOf(scene) then
            state = 'no officer to enforce'
        elseif scene.radarSpeed then
            state = ('armed at %.0f mph (authored)'):format(scene.radarSpeed)
        elseif scene.kind == 'radar' then
            state = ('armed, %.0fm cone'):format((cfg().radar or {}).detectRange or 60.0)
        else
            state = ('armed, %.0fm radius'):format((cfg().radar or {}).copDetectRange or 45.0)
        end
        print(('  %-8s %5.0fm  %s'):format(scene.kind, #(where - me), state))
    end

    -- What the player is actually being judged against right now.
    local threshold, posted = postedThreshold(GetEntityCoords(PlayerPedId()))
    print(('  limit here: %s'):format(
        posted and ('%.0f posted, %.0f allowed'):format(posted, threshold)
        or ('unposted, %.0f allowed'):format(threshold)))
end, false)

-- Live trace of the enforcement decision, once a second. Answers "why did that
-- officer not react" with the actual numbers rather than a guess: whether the
-- tick is running at all, what the player is being judged against, and for the
-- nearest officer, the distance and the cone/radius result.
local tracing = false

RegisterCommand('radartrace', function()
    tracing = not tracing
    print(('[FENIX-AMBIENT] radar trace %s'):format(tracing and 'ON' or 'OFF'))

    if not tracing then return end

    CreateThread(function()
        while tracing do
            Wait(1000)

            local c = radarCfg()
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)

            if veh == 0 then
                print('[TRACE] not in a vehicle — enforcement only looks at drivers')
            else
                local speed = GetEntitySpeed(veh) * MPS_TO_MPH
                local pos = GetEntityCoords(veh)
                local threshold, posted = postedThreshold(pos)

                print(('[TRACE] tick=%s ambientOn=%s | %.0f mph vs %.0f allowed (%s) | cooldown=%s')
                    :format(tostring(c.enabled ~= false), tostring(ambientOn()),
                        speed, threshold, posted and (posted .. ' posted') or 'unposted',
                        tostring(onCooldown(veh))))

                local n = 0
                for _, scene in pairs(scenes) do
                    local observer = observerOf(scene)
                    if observer then
                        n = n + 1
                        local d = #(GetEntityCoords(observer) - pos)
                        local reach = (scene.kind == 'radar')
                            and (c.detectRange or 60.0) or (c.copDetectRange or 45.0)
                        print(('[TRACE]   %-8s %5.0fm (reach %.0fm) cops=%d armed=%s seen=%s')
                            :format(scene.kind, d, reach, scene.cops,
                                tostring(not scene.enforcing and not scene.stop and not scene.chase and scene.cops > 0),
                                tostring(witnessed(scene, nil, pos))))
                    end
                end
                if n == 0 then print('[TRACE]   no ambient scenes exist at all') end
            end
        end
    end)
end, false)

RegisterCommand('ambientpolicereload', function()
    refreshToolkitPoints()
    destroyAllScenes()
    print('[FENIX-AMBIENT] points reloaded, scenes cleared')
end, false)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    destroyAllScenes()
end)
