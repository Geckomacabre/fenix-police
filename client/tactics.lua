--[[
    client/tactics.lua

    The things a police response does to a road, rather than to a car:
    roadblocks and spike strips.

    Dispatch service 8 (DT_PoliceRoadBlock) is force-disabled in client.lua, and
    nothing replaced it — so at every wanted level the entire response was "more
    cars behind you". A pursuit with no way to get in front of the suspect has
    only one shape.

    Both features need the same thing, and it is the thing client/roads.lua
    already works out: not "where is the road" but "how wide is it, how many
    lanes run each way, and which of those lanes is the player in". A roadblock
    that spans the carriageway has to know where the carriageway ends, and a
    spike strip laid across the wrong side of a dual carriageway is scenery.

    Placement rules, both features:
      - ahead of the player along their actual direction of travel
      - far enough that they arrive, not appear
      - never inside the player's view when created
      - never inside a Config.Roads exclusion zone

    Everything is client-local (non-networked), the way client/ambient.lua works:
    created with CreateVehicle/CreateObject, held with SetEntityAsMissionEntity,
    deleted by handle. No net IDs and no server round-trip.
]]

FenixTactics = {}

local function cfg() return Config.Tactics or {} end
local function dbg(msg) if cfg().debug then print('[FENIX-TACTICS] ' .. msg) end end

-- Live placements. Each is { kind, coords, vehicles = {}, peds = {}, objects = {},
-- createdAt = gameTimer, armed = bool }
local placements = {}

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function forwardOf(heading)
    local r = math.rad(heading)
    return -math.sin(r), math.cos(r)
end

local function rightOf(heading)
    local r = math.rad(heading)
    return math.cos(r), math.sin(r)
end

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

--- Lane centre offset from the road's centre line, measured along right-of-A.
--- Straight from client/roads.lua, so a block or strip lands in exactly the
--- lane a unit would be spawned in, whichever lane layout is configured there.
local function laneOffset(road, laneIndex, laneWidth)
    return FenixRoads.laneOffset(road, laneIndex, laneWidth)
end

--- Where the player is going, and how fast. Falls back to the ped's own heading
--- when they're on foot, so a roadblock is still placed somewhere sensible.
local function playerVector()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    local entity = (veh ~= 0) and veh or ped

    return GetEntityCoords(entity), GetEntityHeading(entity), GetEntitySpeed(entity), veh
end

--- Is anything of ours already within `spacing` of this point? Two roadblocks a
--- hundred metres apart on the same road is one roadblock with extra steps.
local function tooCloseToExisting(coords, spacing)
    for _, place in ipairs(placements) do
        if #(place.coords - coords) < spacing then return true end
    end
    return false
end

-------------------------------------------------------------------------------
-- Entity creation
-------------------------------------------------------------------------------

local function createVehicle(place, modelName, x, y, z, heading)
    if not modelName then return nil end
    modelName = FenixLivery.resolveModel(modelName, vector3(x, y, z))
    local hash = GetHashKey(modelName)
    if not loadModel(hash) then return nil end

    local veh = CreateVehicle(hash, x, y, z, heading, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not DoesEntityExist(veh) then return nil end

    SetEntityAsMissionEntity(veh, true, true)
    SetVehicleOnGroundProperly(veh)
    FenixLivery.apply(veh)
    SetVehicleDoorsLocked(veh, 2)
    SetVehicleEngineOn(veh, true, true, false)
    -- Lights and bar on, siren silent. A roadblock is announcing a closed road,
    -- not chasing anybody, and a stationary wailing siren a hundred metres ahead
    -- is the tell that ruins the surprise.
    SetVehicleSiren(veh, true)
    SetVehicleHasMutedSirens(veh, true)
    SetVehicleLights(veh, 2)
    -- Do not let the population manager take these back mid-pursuit.
    SetEntityCanBeDamaged(veh, true)

    table.insert(place.vehicles, veh)
    return veh
end

local function createPed(place, modelName, x, y, z, heading)
    if not modelName then return nil end
    local hash = GetHashKey(modelName)
    if not loadModel(hash) then return nil end

    local ped = CreatePed(4, hash, x, y, z, heading, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not DoesEntityExist(ped) then return nil end

    SetEntityAsMissionEntity(ped, true, true)
    SetPedArmour(ped, 100)
    SetPedCanRagdollFromPlayerImpact(ped, false)
    -- 46 = AlwaysFight off: officers manning a block hold position and only
    -- respond if fired on. The block is the obstacle; it is not an ambush.
    SetPedCombatAttributes(ped, 46, false)
    SetPedCombatAttributes(ped, 3, false)
    SetPedFleeAttributes(ped, 0, false)
    SetPedDropsWeaponsWhenDead(ped, false)

    local weapon = cfg().weapon or 'weapon_pistol'
    GiveWeaponToPed(ped, GetHashKey(weapon), 250, false, true)

    table.insert(place.peds, ped)
    return ped
end

-------------------------------------------------------------------------------
-- Finding a spot ahead
-------------------------------------------------------------------------------

--- Would the player see something appear here?
---
--- In the camera's view AND with nothing solid between the camera and the
--- spot. IS_SPHERE_VISIBLE alone is only a frustum test: to it everything ahead
--- of a chase camera is "visible", hills and buildings in the way included, so
--- nearly every spot ahead of the player was refused and blocks almost never
--- got placed. The ray only runs for spots that pass the frustum test, and only
--- from the tactics thread (never per frame) -- it waits a few frames for the
--- result.
local function inPlayerView(pos)
    if not IsSphereVisible(pos.x, pos.y, pos.z, 6.0) then return false end

    local cam = GetFinalRenderedCamCoord()
    -- World geometry only (1): buildings, terrain, bridges. Props are left out
    -- on purpose -- a lamp post in the way does not hide a roadblock.
    local probe = StartShapeTestLosProbe(cam.x, cam.y, cam.z, pos.x, pos.y, pos.z + 1.5,
        1, PlayerPedId(), 7)
    for _ = 1, 30 do
        local status, hit = GetShapeTestResult(probe)
        if status == 2 then return not (hit == true or hit == 1) end
        if status == 0 then break end
        Wait(0)
    end

    -- No answer: assume it's in view rather than risk appearing in front of them.
    return true
end

--- Is this spot on the road the player is actually driving, rather than a
--- parallel street, a crossing road or an overpass that merely happens to be
--- ahead in a straight line? The driving distance to it can't be much more
--- than the straight-line one. (The road also has to run roughly the player's
--- way; roadAhead checks that first, for free.)
local function onPlayerRoute(from, road)
    local ratio = cfg().routeRatio or 1.5
    if ratio <= 0 then return true end

    local straight = #(road.center - from)
    local travel = CalculateTravelDistanceBetweenPoints(from.x, from.y, from.z,
        road.center.x, road.center.y, road.center.z)
    -- Zero or negative means the native had nothing to say; don't block on it.
    if not travel or travel <= 0.0 then return true end
    return travel <= (straight * ratio)
end

-- Route queries per roadAhead() call. CALCULATE_TRAVEL_DISTANCE_BETWEEN_POINTS
-- is a synchronous path search, so it only runs for spots that passed every
-- other test, and only this many times before the search waits for next time.
local MAX_ROUTE_CHECKS = 3

--- A road far enough ahead of the player, on the route they are actually taking.
---
--- Returns the road info from client/roads.lua plus which of its two directions
--- the player is travelling — which is what decides WHICH lanes get blocked. On
--- a dual carriageway, blocking the wrong three is scenery.
local function roadAhead(minDist, maxDist)
    local coords, heading, _, _ = playerVector()
    local fx, fy = forwardOf(heading)

    -- Sample from far to near: a block placed at the far end of the band gives
    -- the player longer to see it and decide, which is the difference between an
    -- obstacle and an ambush.
    local routeChecks = 0
    for _ = 1, (cfg().placementAttempts or 12) do
        local dist = maxDist - (math.random() * (maxDist - minDist))
        local px = coords.x + (fx * dist)
        local py = coords.y + (fy * dist)

        local road = FenixRoads.roadInfoAt(vector3(px, py, coords.z))
        if road then
            -- Which way along this road is the player going? A road running
            -- across their path (|dot| small) is a cross street, not theirs.
            local rfx, rfy = forwardOf(road.heading)
            local dot = (fx * rfx) + (fy * rfy)
            local alongA = dot >= 0.0
            local lanes = alongA and road.fwdLanes or road.bwdLanes

            -- Cheapest first. The view check waits a frame or two for its ray;
            -- the route check is the expensive one, so it goes last.
            if lanes > 0 and math.abs(dot) >= 0.5
                and FenixRoads.isSpawnable(road.center, { clearance = 0.0 })
                and not inPlayerView(road.center) then
                routeChecks = routeChecks + 1
                if onPlayerRoute(coords, road) then
                    return road, alongA, lanes
                end
                if routeChecks >= MAX_ROUTE_CHECKS then return nil end
            end
        end
    end

    return nil
end

-------------------------------------------------------------------------------
-- Roadblock
-------------------------------------------------------------------------------

--- Cars parked broadside across the lanes the player is driving in, with
--- officers standing behind them.
local function buildRoadblock()
    local c = cfg()
    local road, alongA = roadAhead(c.roadblockMinDistance or 170.0,
                                   c.roadblockMaxDistance or 300.0)
    if not road then return false end
    if tooCloseToExisting(road.center, c.minSpacing or 250.0) then return false end

    local laneWidth = (Config.Roads and Config.Roads.laneWidth) or 3.5
    local total = road.fwdLanes + road.bwdLanes

    -- Face the block across the road: broadside is what makes it a wall rather
    -- than a queue. Which of the two perpendiculars doesn't matter for blocking,
    -- but keeping them consistent makes the block look deliberate.
    local blockHeading = (road.heading + 90.0) % 360.0

    -- Officers stand on the far side, so the cars are between them and the
    -- oncoming suspect.
    local awayX, awayY = forwardOf(alongA and road.heading or ((road.heading + 180.0) % 360.0))

    local place = {
        kind = 'roadblock',
        coords = road.center,
        vehicles = {}, peds = {}, objects = {},
        createdAt = GetGameTimer(),
    }

    -- Direction A occupies the rightmost `fwdLanes` slots, direction B the
    -- leftmost `bwdLanes` — the same numbering client/roads.lua places cars with.
    local firstLane, lastLane
    if alongA then
        firstLane, lastLane = total - road.fwdLanes + 1, total
    else
        firstLane, lastLane = 1, road.bwdLanes
    end

    -- Resolved up front (rather than inside createVehicle) so the spacing below
    -- is measured off the model that will actually spawn.
    local model = FenixLivery.resolveModel(pick(c.roadblockVehicles) or 'police', road.center)
    local hash = GetHashKey(model)
    if not loadModel(hash) then return false end

    -- Broadside, each car spans its full length across the road, but a lane is
    -- only laneWidth wide: one car per lane in a straight line overlaps its
    -- neighbours by a metre or more, and cars spawned into each other get
    -- thrown apart by the physics, scattering the block. Every other car is set
    -- back by a car's width instead, so the line still leaves no gap.
    local carLength, carWidth = 5.0, 2.2
    local mn, mx = GetModelDimensions(hash)
    if mn and mx and (mx.y - mn.y) > 1.0 and (mx.x - mn.x) > 0.5 then
        carLength, carWidth = mx.y - mn.y, mx.x - mn.x
    end
    local stagger = ((carLength + 0.4) > laneWidth) and (carWidth + 0.5) or 0.0

    local built = 0

    for lane = firstLane, lastLane do
        local off = laneOffset(road, lane, laneWidth)
        local back = (((lane - firstLane) % 2) == 1) and stagger or 0.0
        local rx, ry = rightOf(road.heading)
        local x = road.center.x + (rx * off) + (awayX * back)
        local y = road.center.y + (ry * off) + (awayY * back)

        local okGround, groundZ = GetGroundZFor_3dCoord(x, y, road.center.z + 3.0, false)
        local z = (okGround and math.abs(groundZ - road.center.z) < 6.0) and groundZ or road.center.z

        if createVehicle(place, model, x, y, z + 0.5, blockHeading) then
            built = built + 1
        end
    end

    if built == 0 then
        FenixTactics.clearPlacement(place)
        return false
    end

    -- One officer per car, up to the configured cap, standing a couple of metres
    -- behind the line.
    local officers = math.min(built, c.roadblockOfficers or 2)
    for i = 1, officers do
        local veh = place.vehicles[i]
        if veh and DoesEntityExist(veh) then
            local vc = GetEntityCoords(veh)
            local px = vc.x + (awayX * 2.5)
            local py = vc.y + (awayY * 2.5)
            local okGround, groundZ = GetGroundZFor_3dCoord(px, py, vc.z + 2.0, false)

            -- Face back down the road, at whoever is coming.
            local facing = alongA and ((road.heading + 180.0) % 360.0) or road.heading
            local cop = createPed(place, pick(c.peds), px, py,
                (okGround and groundZ or vc.z), facing)

            if cop then
                TaskStandGuard(cop, px, py, (okGround and groundZ or vc.z), facing, 'WORLD_HUMAN_GUARD_STAND')
            end
        end
    end

    table.insert(placements, place)
    dbg(('roadblock: %d car(s) across %d lane(s) at %.0f, %.0f')
        :format(built, lastLane - firstLane + 1, road.center.x, road.center.y))
    return true
end

-------------------------------------------------------------------------------
-- Spike strip
-------------------------------------------------------------------------------

--- Strips laid across the lanes the player is in, with an officer on the verge.
---
--- Deliberately placed closer than a roadblock and marked `armed`: a strip you
--- cannot see until you are on it is a coin flip, and one you spot at two
--- hundred metres is a decision.
local function layStrips()
    local c = cfg()
    local road, alongA = roadAhead(c.spikeMinDistance or 120.0,
                                   c.spikeMaxDistance or 220.0)
    if not road then return false end
    if tooCloseToExisting(road.center, c.minSpacing or 250.0) then return false end

    local laneWidth = (Config.Roads and Config.Roads.laneWidth) or 3.5

    local place = {
        kind = 'spikes',
        coords = road.center,
        vehicles = {}, peds = {}, objects = {},
        createdAt = GetGameTimer(),
        armed = true,
    }

    local modelName = c.spikeModel or 'p_ld_stinger_s'
    local hash = GetHashKey(modelName)
    if not loadModel(hash) then return false end

    -- Which way the strip model runs, read from the model rather than assumed
    -- so a replacement spikeModel lies down correctly too. Its long axis has
    -- to lie ACROSS the lane: laid along it, a strip only catches a car that
    -- drives straight down its length. The same numbers drive the hit test.
    local mn, mx = GetModelDimensions(hash)
    local sizeX, sizeY = 0.0, 0.0
    if mn and mx then sizeX, sizeY = mx.x - mn.x, mx.y - mn.y end
    local longOnY = sizeY > sizeX
    place.strip = {
        longOnY   = longOnY,
        halfLen   = math.max(sizeX, sizeY) * 0.5,
        halfDepth = math.min(sizeX, sizeY) * 0.5,
    }
    if place.strip.halfLen < 0.5 then
        -- No usable dimensions: assume a strip one lane long.
        place.strip.halfLen, place.strip.halfDepth = laneWidth * 0.5, 0.3
    end
    local stripHeading = longOnY and ((road.heading + 90.0) % 360.0) or road.heading

    local total = road.fwdLanes + road.bwdLanes
    local firstLane, lastLane
    if alongA then
        firstLane, lastLane = total - road.fwdLanes + 1, total
    else
        firstLane, lastLane = 1, road.bwdLanes
    end

    local rx, ry = rightOf(road.heading)
    local laid = 0

    for lane = firstLane, lastLane do
        local off = laneOffset(road, lane, laneWidth)
        local x = road.center.x + (rx * off)
        local y = road.center.y + (ry * off)

        local okGround, groundZ = GetGroundZFor_3dCoord(x, y, road.center.z + 3.0, false)
        local z = (okGround and math.abs(groundZ - road.center.z) < 6.0) and groundZ or road.center.z

        local obj = CreateObject(hash, x, y, z, false, false, false)
        if DoesEntityExist(obj) then
            SetEntityHeading(obj, stripHeading)
            PlaceObjectOnGroundProperly(obj)
            SetEntityAsMissionEntity(obj, true, true)
            FreezeEntityPosition(obj, true)
            table.insert(place.objects, obj)
            laid = laid + 1
        end
    end

    SetModelAsNoLongerNeeded(hash)

    if laid == 0 then
        FenixTactics.clearPlacement(place)
        return false
    end

    -- The officer who laid them, on the verge and out of the way.
    local shoulder = FenixRoads.edgeOffset(road, alongA, laneWidth) + 3.0
    if not alongA then shoulder = -shoulder end
    local px = road.center.x + (rx * shoulder)
    local py = road.center.y + (ry * shoulder)
    local okGround, groundZ = GetGroundZFor_3dCoord(px, py, road.center.z + 2.0, false)
    local facing = alongA and ((road.heading + 180.0) % 360.0) or road.heading
    createPed(place, pick(c.peds), px, py, (okGround and groundZ or road.center.z), facing)

    table.insert(placements, place)
    dbg(('spikes: %d strip(s) at %.0f, %.0f'):format(laid, road.center.x, road.center.y))
    return true
end

-- Wheel bone -> tyre index for SET_VEHICLE_TYRE_BURST. Bikes use the lf/lr
-- pair (0 front, 4 rear), six-wheelers add the middle pair.
local WHEELS = {
    { 'wheel_lf', 0 }, { 'wheel_rf', 1 },
    { 'wheel_lm1', 2 }, { 'wheel_rm1', 3 },
    { 'wheel_lr', 4 }, { 'wheel_rr', 5 },
}

-- Bone indices for the vehicle last checked, so they're looked up once per
-- vehicle rather than six times every tick.
local wheelVeh, wheelModel, wheelBones = 0, 0, {}

local function wheelsOf(veh)
    local model = GetEntityModel(veh)
    if veh ~= wheelVeh or model ~= wheelModel then
        wheelVeh, wheelModel, wheelBones = veh, model, {}
        for _, w in ipairs(WHEELS) do
            local bone = GetEntityBoneIndexByName(veh, w[1])
            if bone ~= -1 then wheelBones[#wheelBones + 1] = { bone = bone, tyre = w[2] } end
        end
    end
    return wheelBones
end

-- After the first tyre goes, a strip stays live this long so the rest of the
-- same car's wheels can cross it too, then it's spent.
local SPIKE_SPENT_MS = 2000

--- Burst the tyres of anything that drives over a live strip.
---
--- Scripted rather than left to the model's own collision, because the stinger
--- prop has none that does this — in the base game the effect is driven entirely
--- by mission script.
---
--- Tested per wheel against each strip's own footprint: only a tyre that rolls
--- over a strip bursts. A wheel that moved from one side of the strip to the
--- other since the last tick counts as having crossed it, so a fast car can't
--- skip over a 0.3m strip between two 50ms ticks.
local function checkSpikeHits()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 then return end

    -- Another player driving: their client owns the car, so a burst from here
    -- wouldn't take.
    local driver = GetPedInVehicleSeat(veh, -1)
    if driver ~= 0 and driver ~= ped and IsPedAPlayer(driver) then return end

    local vc = GetEntityCoords(veh)
    local now = GetGameTimer()

    for _, place in ipairs(placements) do
        if place.kind == 'spikes' and place.armed and place.strip then
            if place.spentAt and now >= place.spentAt then
                place.armed = false
            elseif #(vc - place.coords) > 40.0 then
                place.lastAcross = nil
            else
                if place.lastVeh ~= veh then
                    place.lastVeh, place.lastAcross = veh, nil
                end
                place.lastAcross = place.lastAcross or {}

                local s = place.strip
                local burst = 0

                for _, obj in ipairs(place.objects) do
                    if DoesEntityExist(obj) then
                        local prev = place.lastAcross[obj] or {}
                        place.lastAcross[obj] = prev

                        for _, w in ipairs(wheelsOf(veh)) do
                            local wp = GetWorldPositionOfEntityBone(veh, w.bone)
                            local off = GetOffsetFromEntityGivenWorldCoords(obj, wp.x, wp.y, wp.z)
                            local along = s.longOnY and off.y or off.x
                            local across = s.longOnY and off.x or off.y
                            local before = prev[w.tyre]
                            prev[w.tyre] = across

                            local crossed = before ~= nil and (before < 0.0) ~= (across < 0.0)
                                and math.abs(before) < 10.0 and math.abs(across) < 10.0
                            if math.abs(along) <= (s.halfLen + 0.25) and math.abs(off.z) < 1.2
                                and (math.abs(across) <= (s.halfDepth + 0.2) or crossed)
                                and not IsVehicleTyreBurst(veh, w.tyre, false) then
                                SetVehicleTyreBurst(veh, w.tyre, false, 1000.0)
                                burst = burst + 1
                            end
                        end
                    end
                end

                if burst > 0 then
                    dbg(('spikes hit: %d tyre(s)'):format(burst))
                    if not place.spentAt then
                        place.spentAt = now + SPIKE_SPENT_MS
                        if cfg().spikeNotify ~= false then
                            FenixFramework.Notify(cfg().spikeMessage or 'Spike strip!', 'error', 4000)
                        end
                    end
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

--- Delete everything one placement owns. Safe on a placement that was never
--- added to the live list, which is how the build functions abandon a failure.
function FenixTactics.clearPlacement(place)
    for _, veh in ipairs(place.vehicles or {}) do
        if DoesEntityExist(veh) then
            -- Never delete a car the player has climbed into. Stealing a unit
            -- out of a roadblock is a legitimate outcome and deleting it out
            -- from under them is not.
            if not IsPedInVehicle(PlayerPedId(), veh, false) then
                DeleteEntity(veh)
            else
                -- Theirs now: hand it to the game's population manager rather
                -- than leaving it a mission entity that is never cleaned up.
                SetEntityAsNoLongerNeeded(veh)
            end
        end
    end
    for _, ped in ipairs(place.peds or {}) do
        if DoesEntityExist(ped) then DeleteEntity(ped) end
    end
    for _, obj in ipairs(place.objects or {}) do
        if DoesEntityExist(obj) then DeleteEntity(obj) end
    end
end

--- Tear down every placement. Called when the wanted level clears.
function FenixTactics.clearAll()
    for _, place in ipairs(placements) do
        FenixTactics.clearPlacement(place)
    end
    placements = {}
end

--- How many placements are live, for the debug command.
function FenixTactics.count()
    return #placements
end

-- Expire placements the player has driven past or that have simply been up too
-- long. Runs on its own timer rather than in the build thread so a block clears
-- promptly even while nothing new is being placed.
local function expirePlacements()
    local c = cfg()
    local now = GetGameTimer()
    local me = GetEntityCoords(PlayerPedId())
    local lifetime = (c.lifetime or 90) * 1000

    for i = #placements, 1, -1 do
        local place = placements[i]
        local age = now - place.createdAt
        local dist = #(me - place.coords)

        -- Distance is checked with a floor on age: a block placed 300m ahead is
        -- already "far away" the moment it exists.
        if age > lifetime
            or (age > 20000 and dist > (c.despawnDistance or 350.0)) then
            FenixTactics.clearPlacement(place)
            table.remove(placements, i)
        end
    end
end

-------------------------------------------------------------------------------
-- Driver
-------------------------------------------------------------------------------

CreateThread(function()
    local lastRoadblock = 0
    local lastSpikes = 0

    while true do
        Wait(1000)

        local c = cfg()
        if c.enabled == false then
            if #placements > 0 then FenixTactics.clearAll() end
            goto continue
        end

        do
            local wanted = GetPlayerWantedLevel(PlayerId())

            if wanted == 0 then
                if #placements > 0 then FenixTactics.clearAll() end
                goto continue
            end

            expirePlacements()

            -- Nothing is deployed against a suspect nobody can see. Getting a
            -- unit in front of you requires knowing where you are going, and
            -- during a search nobody does — which is also what stops a search
            -- turning into a wall of roadblocks in every direction.
            if not FenixPursuit.hasContact() then goto continue end

            -- A road tactic means nothing to a suspect in the air or on the
            -- water; placing one under a helicopter is just scenery.
            local playerPed = PlayerPedId()
            if IsPedInAnyHeli(playerPed) or IsPedInAnyPlane(playerPed) or IsPedInAnyBoat(playerPed) then
                goto continue
            end

            local _, _, speed = playerVector()
            local now = GetGameTimer()

            -- Both are pointless below a speed: a suspect doing 15mph through a
            -- side street drives around a block and steps over a strip.
            if speed < (c.minSpeed or 12.0) then goto continue end

            -- A pursuit that's been running a while unlocks road tactics even
            -- below roadblockFromLevel/spikeFromLevel -- see the comment on
            -- durationFallbackMs above. Never below durationFallbackMinLevel
            -- regardless of how long it's run.
            local elapsedMs = FenixPursuit.pursuitElapsedMs and FenixPursuit.pursuitElapsedMs() or 0
            local durationUnlocked = (c.durationFallbackMs or 0) > 0
                and wanted >= (c.durationFallbackMinLevel or 2)
                and elapsedMs >= c.durationFallbackMs

            if #placements < (c.maxConcurrent or 2) then
                if (wanted >= (c.roadblockFromLevel or 3) or durationUnlocked)
                    and (now - lastRoadblock) > ((c.roadblockCooldown or 45) * 1000)
                    and math.random() < (c.roadblockChance or 0.5) then
                    if buildRoadblock() then lastRoadblock = now end

                elseif (wanted >= (c.spikeFromLevel or 3) or durationUnlocked)
                    and (now - lastSpikes) > ((c.spikeCooldown or 35) * 1000)
                    and math.random() < (c.spikeChance or 0.5) then
                    if layStrips() then lastSpikes = now end
                end
            end
        end

        ::continue::
    end
end)

-- Spike contact needs a much finer tick than placement: at 90mph a car crosses
-- a strip's whole footprint inside a single 1000ms cycle.
CreateThread(function()
    while true do
        if #placements > 0 then
            checkSpikeHits()
            Wait(50)
        else
            Wait(500)
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    FenixTactics.clearAll()
end)

RegisterCommand('fenixtactics', function()
    print(('[FENIX-TACTICS] %d placement(s) live'):format(#placements))
    local me = GetEntityCoords(PlayerPedId())
    for _, place in ipairs(placements) do
        print(('  %-9s %5.0fm  %d vehicle(s), %d ped(s), %d object(s)%s')
            :format(place.kind, #(me - place.coords), #place.vehicles, #place.peds,
                #place.objects, place.armed and ' [armed]' or ''))
    end
end, false)
