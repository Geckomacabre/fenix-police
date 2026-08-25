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
--- Same geometry as client/roads.lua uses to place a car in a lane — see the
--- comment on laneOffsetFromCentre there for why the centre line sits in the
--- middle of the full lane set.
local function laneOffset(laneIndex, totalLanes, laneWidth)
    return (-(totalLanes * laneWidth) * 0.5) + ((laneIndex - 0.5) * laneWidth)
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
    local hash = GetHashKey(modelName)
    if not loadModel(hash) then return nil end

    local veh = CreateVehicle(hash, x, y, z, heading, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not DoesEntityExist(veh) then return nil end

    SetEntityAsMissionEntity(veh, true, true)
    SetVehicleOnGroundProperly(veh)
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
    for _ = 1, (cfg().placementAttempts or 12) do
        local dist = maxDist - (math.random() * (maxDist - minDist))
        local px = coords.x + (fx * dist)
        local py = coords.y + (fy * dist)

        local road = FenixRoads.roadInfoAt(vector3(px, py, coords.z))
        if road then
            local ok = FenixRoads.isSpawnable(road.center, { clearance = 0.0 })
            if ok and not IsSphereVisible(road.center.x, road.center.y, road.center.z, 6.0) then
                -- Which way along this road is the player going?
                local rfx, rfy = forwardOf(road.heading)
                local alongA = ((fx * rfx) + (fy * rfy)) >= 0.0

                local lanes = alongA and road.fwdLanes or road.bwdLanes
                if lanes > 0 then
                    return road, alongA, lanes
                end
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
    local road, alongA, lanes = roadAhead(c.roadblockMinDistance or 170.0,
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

    local model = pick(c.roadblockVehicles) or 'police'
    local built = 0

    for lane = firstLane, lastLane do
        local off = laneOffset(lane, total, laneWidth)
        local rx, ry = rightOf(road.heading)
        local x = road.center.x + (rx * off)
        local y = road.center.y + (ry * off)

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
    local road, alongA, lanes = roadAhead(c.spikeMinDistance or 120.0,
                                          c.spikeMaxDistance or 220.0)
    if not road then return false end
    if tooCloseToExisting(road.center, c.minSpacing or 250.0) then return false end

    local laneWidth = (Config.Roads and Config.Roads.laneWidth) or 3.5
    local total = road.fwdLanes + road.bwdLanes

    local place = {
        kind = 'spikes',
        coords = road.center,
        vehicles = {}, peds = {}, objects = {},
        createdAt = GetGameTimer(),
        armed = true,
        radius = ((lanes * laneWidth) * 0.5) + 2.0,
    }

    local modelName = c.spikeModel or 'p_ld_stinger_s'
    local hash = GetHashKey(modelName)
    if not loadModel(hash) then return false end

    local firstLane, lastLane
    if alongA then
        firstLane, lastLane = total - road.fwdLanes + 1, total
    else
        firstLane, lastLane = 1, road.bwdLanes
    end

    local rx, ry = rightOf(road.heading)
    local laid = 0

    for lane = firstLane, lastLane do
        local off = laneOffset(lane, total, laneWidth)
        local x = road.center.x + (rx * off)
        local y = road.center.y + (ry * off)

        local okGround, groundZ = GetGroundZFor_3dCoord(x, y, road.center.z + 3.0, false)
        local z = (okGround and math.abs(groundZ - road.center.z) < 6.0) and groundZ or road.center.z

        -- The strip model is long on its own X, so it lies across the road at
        -- the road's own heading rather than perpendicular to it.
        local obj = CreateObject(hash, x, y, z, false, false, false)
        if DoesEntityExist(obj) then
            SetEntityHeading(obj, road.heading)
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
    local shoulder = ((total * laneWidth) * 0.5) + 3.0
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

--- Burst the tyres of anything that drives over a live strip.
---
--- Scripted rather than left to the model's own collision, because the stinger
--- prop has none that does this — in the base game the effect is driven entirely
--- by mission script.
local function checkSpikeHits()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 then return end
    if GetEntitySpeed(veh) < 2.0 then return end

    local vc = GetEntityCoords(veh)

    for _, place in ipairs(placements) do
        if place.kind == 'spikes' and place.armed and #(vc - place.coords) < (place.radius or 8.0) then
            place.armed = false

            local burst = 0
            -- Wheel indices: 0/1 front, 2/3 mid (six-wheelers), 4/5 rear.
            for wheel = 0, 5 do
                if not IsVehicleTyreBurst(veh, wheel, false) then
                    SetVehicleTyreBurst(veh, wheel, false, 1000.0)
                    burst = burst + 1
                end
            end

            if burst > 0 then
                dbg(('spikes hit: %d tyre(s)'):format(burst))
                if cfg().spikeNotify ~= false and QBCore and QBCore.Functions then
                    QBCore.Functions.Notify(cfg().spikeMessage or 'Spike strip!', 'error', 4000)
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

            local _, _, speed = playerVector()
            local now = GetGameTimer()

            -- Both are pointless below a speed: a suspect doing 15mph through a
            -- side street drives around a block and steps over a strip.
            if speed < (c.minSpeed or 12.0) then goto continue end

            if #placements < (c.maxConcurrent or 2) then
                if wanted >= (c.roadblockFromLevel or 3)
                    and (now - lastRoadblock) > ((c.roadblockCooldown or 45) * 1000)
                    and math.random() < (c.roadblockChance or 0.5) then
                    if buildRoadblock() then lastRoadblock = now end

                elseif wanted >= (c.spikeFromLevel or 3)
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
