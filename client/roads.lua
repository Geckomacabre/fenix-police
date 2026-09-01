--[[
    client/roads.lua

    Where a police unit is allowed to appear, and which way it faces when it
    does.

    Three problems this exists to solve, all of them the same root cause — the
    old spawn code took whatever `GetClosestVehicleNodeWithHeading` handed back
    and used it verbatim:

      1. Wrong lane.      A vehicle node is the centre line of the road, not a
                          lane. Spawning on it drops a cruiser straddling the
                          middle of the street.
      2. Facing backwards. The heading a node reports is the direction of ONE of
                          the road's two travel directions, chosen by the engine.
                          Half the time that is the oncoming side, so the cruiser
                          appears nose-to-nose with traffic.
      3. Airside.         LSIA and Fort Zancudo have vehicle nodes across the
                          runways, taxiways and aprons. Nothing stopped a unit
                          spawning on the tarmac, or a pursuit routing down the
                          active runway.

    The fix for 1 and 2 is GET_CLOSEST_ROAD, which — unlike the node natives —
    reports the road's two endpoints AND the lane count in each direction. From
    that you can compute an actual lane centre and an actual legal heading
    instead of guessing. The fix for 3 is a config-driven exclusion list that
    both rejects spawns and switches the AI road nodes off via SET_ROADS_IN_AREA,
    which is what keeps pursuits off the runway.

    Everything is exposed on the `FenixRoads` global because client/client.lua
    and client/ambient.lua are separate file scopes in the same Lua state.
]]

FenixRoads = {}

local function cfg() return Config.Roads or {} end
local function dbg(msg) if cfg().debug then print('[FENIX-ROADS] ' .. msg) end end

-- GTA heading h has forward = (-sin h, cos h); the right-hand side of that is
-- (cos h, sin h). Both are used constantly below, so they get names.
local function forwardOf(heading)
    local r = math.rad(heading)
    return -math.sin(r), math.cos(r)
end

local function rightOf(heading)
    local r = math.rad(heading)
    return math.cos(r), math.sin(r)
end

-------------------------------------------------------------------------------
-- Exclusion zones
-------------------------------------------------------------------------------

--- Standard even-odd ray cast. `poly` is a list of vector2/vector3; only x and y
--- are read, so a polygon captured from in-world coordinates works as-is.
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

--- A zone is a box (`min`/`max`), a cylinder (`center`/`radius`) or a prism
--- (`poly`), each with an optional `zMin`/`zMax` band. The band matters: without
--- it a box over LSIA would also swallow the freeway flying past it.
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

--- The flat bounding box of a zone, for the natives that only take one.
local function zoneBounds(zone)
    if zone.min and zone.max then
        return zone.min.x, zone.min.y, zone.max.x, zone.max.y
    end
    if zone.center and zone.radius then
        return zone.center.x - zone.radius, zone.center.y - zone.radius,
               zone.center.x + zone.radius, zone.center.y + zone.radius
    end
    if zone.poly and #zone.poly > 0 then
        local minX, minY = math.huge, math.huge
        local maxX, maxY = -math.huge, -math.huge
        for _, p in ipairs(zone.poly) do
            if p.x < minX then minX = p.x end
            if p.y < minY then minY = p.y end
            if p.x > maxX then maxX = p.x end
            if p.y > maxY then maxY = p.y end
        end
        return minX, minY, maxX, maxY
    end
end

--- True when this point is somewhere police have no business being. Returns the
--- zone name as a second value so debug output can say which one.
--- @param coords vector3
function FenixRoads.isExcluded(coords)
    local zones = cfg().exclusionZones
    if type(zones) ~= 'table' then return false end

    for _, zone in ipairs(zones) do
        if inZone(zone, coords.x, coords.y, coords.z) then
            return true, zone.name or 'unnamed zone'
        end
    end
    return false
end

--- Same test, ignoring the height band and with a slack radius. Gates the
--- SET_ROADS_IN_AREA thread so it does nothing while you are across the map.
local function anyZoneNear(coords, radius)
    local zones = cfg().exclusionZones
    if type(zones) ~= 'table' then return false end

    for _, zone in ipairs(zones) do
        if zone.enabled ~= false then
            local minX, minY, maxX, maxY = zoneBounds(zone)
            if minX then
                -- Distance from point to box, zero when inside it.
                local dx = math.max(minX - coords.x, 0.0, coords.x - maxX)
                local dy = math.max(minY - coords.y, 0.0, coords.y - maxY)
                if (dx * dx + dy * dy) <= radius * radius then return true end
            end
        end
    end
    return false
end

-------------------------------------------------------------------------------
-- Switching the airside road network off
-------------------------------------------------------------------------------
--
-- SET_ROADS_IN_AREA is the only thing that actually stops a pursuit routing down
-- the runway. Rejecting spawns keeps units from *appearing* airside, but a unit
-- that spawned on a normal street will still happily path across the airfield
-- while the nodes are live. Switching them off makes the whole airside invisible
-- to vehicle pathfinding, for police and ambient traffic alike — which is the
-- behaviour you want, because airside has no civilian traffic either.
--
-- The call has to be repeated: the engine restores node state when a region
-- streams back in, so one call at resource start survives only until the player
-- leaves and comes back.

local roadsSuppressed = false

local function applyRoadSuppression(enabled)
    local zones = cfg().exclusionZones
    if type(zones) ~= 'table' then return end

    for _, zone in ipairs(zones) do
        if zone.enabled ~= false and zone.disableAiRoads ~= false then
            local minX, minY, maxX, maxY = zoneBounds(zone)
            if minX then
                local zMin = zone.zMin or -200.0
                local zMax = zone.zMax or 500.0
                -- Args 7/8: the node state to apply, and an "unknown" that every
                -- known caller passes as true.
                SetRoadsInArea(minX, minY, zMin, maxX, maxY, zMax, enabled, true)
                if zone.disablePedPaths then
                    SetPedPathsInArea(minX, minY, zMin, maxX, maxY, zMax, enabled, true)
                end
            end
        end
    end
    roadsSuppressed = not enabled
end

CreateThread(function()
    while true do
        if cfg().disableAiRoads == false then
            -- Switched off at runtime after having been applied: hand the nodes
            -- back rather than leaving the map permanently altered.
            if roadsSuppressed then applyRoadSuppression(true) end
            Wait(5000)
        elseif anyZoneNear(GetEntityCoords(PlayerPedId()), cfg().suppressionRadius or 2000.0) then
            applyRoadSuppression(false)
            Wait(5000)
        else
            Wait(15000)
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if roadsSuppressed then applyRoadSuppression(true) end
end)

-------------------------------------------------------------------------------
-- Lane geometry
-------------------------------------------------------------------------------

--- One lane each way at `pos`/`heading`, the conservative fallback shape used
--- both when GET_CLOSEST_ROAD has nothing and when its answer fails the
--- cross-check below. It still offsets the car into a lane instead of onto
--- the centre line, and still allows both directions, which is what an
--- ordinary two-way street permits anyway.
local function conservativeRoad(pos, heading)
    return {
        center      = pos,
        heading     = heading or 0.0,
        fwdLanes    = 1,
        bwdLanes    = 1,
        width       = (cfg().laneWidth or 3.5) * 2.0,
        approximate = true,
    }
end

--- Everything known about the road nearest `x,y,z`, or nil when there isn't one.
---
--- GET_CLOSEST_ROAD gives the segment endpoints and, crucially, how many lanes
--- run in each direction along it. That is the one piece of information the node
--- natives don't expose, and the whole reason units used to face the wrong way:
--- with only a centre point and one arbitrary heading there is no way to tell a
--- one-way street from the oncoming side of a two-way one.
---
--- That lane-count output is undocumented, though — FiveM's own native
--- reference lists GET_CLOSEST_ROAD's later parameters as untyped, unconfirmed
--- `Any*`, not "lanes forward" / "lanes back". Treating them that way is
--- community convention, not a confirmed contract, and on a DIVIDED highway
--- it can go wrong in a very visible way: each carriageway is effectively its
--- own road, close enough to the other across a narrow median that "closest
--- road" can hand back the FAR carriageway's segment instead of the near one.
--- Placing a car on that segment's own lane maths then drops it in the
--- opposite carriageway facing oncoming traffic, having done everything this
--- file exists to prevent — just working from the wrong road.
---
--- So the result is cross-checked against GET_CLOSEST_VEHICLE_NODE_WITH_HEADING
--- — a plain, confirmed position + heading, and the same native this file
--- already trusts as its own no-data fallback below. If GET_CLOSEST_ROAD's
--- segment sits further from that anchor than a lane change should ever be, or
--- points a different way entirely, it is not describing the road under the
--- query point and gets discarded in favour of the reliable anchor instead.
---
--- Returns a table:
---   center   vector3  point on the road's centre line closest to the query
---   heading  number   heading of the src -> target direction ("direction A")
---   fwdLanes number   lanes travelling along direction A
---   bwdLanes number   lanes travelling against it
---   width    number   the road width the engine reports, for reference
local function roadAt(x, y, z)
    local found, srcNode, targetNode, fwdLanes, bwdLanes, width =
        GetClosestRoad(x, y, z, 1.0, 1, true)

    local nodeFound, nodePos, nodeHeading = GetClosestVehicleNodeWithHeading(x, y, z, 1, 3.0, 0)

    if not found or not srcNode or not targetNode then
        -- Degrade rather than disappear. If GET_CLOSEST_ROAD has nothing here
        -- there is usually nothing here at all, but "no unit ever spawns" is a
        -- far worse failure than "this one unit is placed with less information".
        if cfg().nodeFallback == false then return nil end
        if not nodeFound or not nodePos then return nil end
        return conservativeRoad(vector3(nodePos.x, nodePos.y, nodePos.z), nodeHeading)
    end

    local sx, sy, sz = srcNode.x, srcNode.y, srcNode.z
    local dx = targetNode.x - sx
    local dy = targetNode.y - sy
    local dz = targetNode.z - sz

    local lenSq = (dx * dx) + (dy * dy)
    if lenSq < 0.01 then return nil end

    -- Project the query point onto the segment, so the spawn lands beside where
    -- we asked rather than at whichever endpoint the engine happened to return.
    local t = (((x - sx) * dx) + ((y - sy) * dy)) / lenSq
    if t < 0.0 then t = 0.0 elseif t > 1.0 then t = 1.0 end

    local center = vector3(sx + (dx * t), sy + (dy * t), sz + (dz * t))
    local heading = GetHeadingFromVector_2d(dx, dy)

    -- The cross-check. Only possible when the reliable anchor also found
    -- something; if it didn't, GET_CLOSEST_ROAD is all there is, and it
    -- already found this segment near a real query point.
    if nodeFound and nodePos then
        local c = cfg()
        local maxDrift = c.crossCheckDistance or 20.0

        if maxDrift > 0.0 then
            local drift = #(center - vector3(nodePos.x, nodePos.y, nodePos.z))
            if drift > maxDrift then
                dbg(('GET_CLOSEST_ROAD segment %.0fm from the reliable anchor at %.1f,%.1f — '
                    .. 'likely the far carriageway of a divided road, using the anchor instead')
                    :format(drift, x, y))
                return conservativeRoad(vector3(nodePos.x, nodePos.y, nodePos.z), nodeHeading)
            end

            -- Same road, or the wrong one running past it at an angle? A real
            -- carriageway pair runs parallel — nearly the same heading, or
            -- nearly opposite. A cross street or ramp does not.
            local maxAngle = c.crossCheckAngle or 40.0
            if nodeHeading then
                local diff = math.abs(((heading - nodeHeading + 180.0) % 360.0) - 180.0)
                local alignment = math.min(diff, math.abs(180.0 - diff))
                if alignment > maxAngle then
                    dbg(('GET_CLOSEST_ROAD segment misaligned %.0f degrees from the reliable anchor '
                        .. 'at %.1f,%.1f — using the anchor instead'):format(alignment, x, y))
                    return conservativeRoad(vector3(nodePos.x, nodePos.y, nodePos.z), nodeHeading)
                end
            end
        end
    end

    return {
        center   = center,
        heading  = heading,
        fwdLanes = math.max(0, math.floor(fwdLanes or 0)),
        bwdLanes = math.max(0, math.floor(bwdLanes or 0)),
        width    = width or 0.0,
    }
end

--- Centre of one lane, as a signed offset from the road's centre line measured
--- along right-of-A.
---
--- Lanes are numbered 1..total from the left-hand edge looking along direction
--- A. The centre line sits in the middle of the full set, which holds both for
--- an undivided street (1 + 1 lanes, centre line is the paint) and for one
--- carriageway of a divided highway (3 + 0 lanes, centre line is the middle of
--- those three) — which is why one formula covers both.
local function laneOffsetFromCentre(laneIndex, totalLanes, laneWidth)
    return (-(totalLanes * laneWidth) * 0.5) + ((laneIndex - 0.5) * laneWidth)
end

--- Put a vehicle in a real lane of `road`, travelling in a direction that road
--- actually permits, preferring the direction that heads towards `towards`.
---
--- Returns coords, heading — or nil if the road reports no drivable lane.
--- @param opts table { shoulder? = park on the verge instead of in a lane,
---                     lanePreference? = 'outer' | 'inner' | 'random' }
local function placeOnRoad(road, towards, opts)
    opts = opts or {}
    local c = cfg()
    local laneWidth = c.laneWidth or 3.5

    local total = road.fwdLanes + road.bwdLanes
    if total <= 0 then return nil end

    local headingA = road.heading

    -- Which direction of travel heads towards the target. Only directions that
    -- have lanes are candidates, so a one-way street can never be entered the
    -- wrong way round no matter where the player is.
    local preferA = true
    if towards then
        local fx, fy = forwardOf(headingA)
        local tx = towards.x - road.center.x
        local ty = towards.y - road.center.y
        local len = math.sqrt((tx * tx) + (ty * ty))
        if len > 0.01 then
            preferA = (((tx / len) * fx) + ((ty / len) * fy)) >= 0.0
        end
    end

    local useA
    if preferA and road.fwdLanes > 0 then
        useA = true
    elseif (not preferA) and road.bwdLanes > 0 then
        useA = false
    else
        useA = road.fwdLanes > 0
    end

    local heading = useA and headingA or ((headingA + 180.0) % 360.0)

    local offset
    if opts.shoulder then
        -- Clear of every lane, on the verge to the right of travel. Right of
        -- direction B is the negative side of right-of-A.
        offset = ((total * laneWidth) * 0.5) + (c.shoulderOffset or 1.5)
        if not useA then offset = -offset end
    else
        -- Direction A occupies the rightmost `fwdLanes` slots and direction B
        -- the leftmost `bwdLanes`, both counted along right-of-A. Lane 1 of a
        -- direction is its kerbside lane, which is where a responding unit most
        -- plausibly appears.
        local lanesHere = useA and road.fwdLanes or road.bwdLanes
        local pick = opts.lanePreference or c.lanePreference or 'outer'

        local n
        if pick == 'inner' then
            n = lanesHere
        elseif pick == 'random' then
            n = math.random(lanesHere)
        else
            n = 1
        end

        local laneIndex
        if useA then
            laneIndex = total - (n - 1)   -- count in from the right edge
        else
            laneIndex = n                 -- count in from the left edge
        end

        offset = laneOffsetFromCentre(laneIndex, total, laneWidth)
    end

    local rx, ry = rightOf(headingA)
    local x = road.center.x + (rx * offset)
    local y = road.center.y + (ry * offset)
    local z = road.center.z

    -- Settle onto the actual surface. The centre-line z is the node's z, which
    -- on a camber, a slope or a bridge deck can be well off the tarmac. Reject
    -- an implausible result rather than dropping the car through the world.
    local okGround, groundZ = GetGroundZFor_3dCoord(x, y, z + 3.0, false)
    if okGround and groundZ and math.abs(groundZ - z) < 6.0 then z = groundZ end

    return vector3(x, y, z), heading
end

-------------------------------------------------------------------------------
-- Candidate validation
-------------------------------------------------------------------------------

--- Is this a real street, as opposed to a runway, an apron, a car park aisle or
--- a dirt scrape? GTA V names essentially every drivable public road, rural
--- trails included ("Cassidy Trail", "Joshua Rd"), and names none of the airside
--- surfaces. That makes the street name the cheapest reliable discriminator
--- available, and unlike a coordinate box it needs no maintenance.
local function isNamedStreet(coords)
    local streetHash = GetStreetNameAtCoord(coords.x, coords.y, coords.z)
    return streetHash ~= nil and streetHash ~= 0
end

--- Node density at a point, or nil when the engine has nothing there. Density
--- 0-1 is a dead end or a track; pursuits stall out on those.
local function nodeDensity(coords)
    local ok, density = GetVehicleNodeProperties(coords.x, coords.y, coords.z)
    if not ok then return nil end
    return density
end

--- Everything that disqualifies a spawn point, in one place so client.lua and
--- ambient.lua cannot drift apart on it. Returns false plus a reason string.
--- @param opts table { minDensity?, avoidVisible?, clearance?, allowUnnamed? }
function FenixRoads.isSpawnable(coords, opts)
    opts = opts or {}
    local c = cfg()

    local excluded, zoneName = FenixRoads.isExcluded(coords)
    if excluded then return false, 'inside ' .. zoneName end

    if c.requireNamedStreet ~= false and not opts.allowUnnamed and not isNamedStreet(coords) then
        return false, 'unnamed surface (runway, apron or car park)'
    end

    local minDensity = opts.minDensity or c.minNodeDensity or 2
    local density = nodeDensity(coords)
    if density and density < minDensity then
        return false, ('node density %d below %d'):format(density, minDensity)
    end

    local clearance = opts.clearance or c.clearance or 3.0
    if clearance > 0.0 and IsPositionOccupied(coords.x, coords.y, coords.z, clearance,
            false, true, true, false, false, 0, false) then
        return false, 'occupied'
    end

    if opts.avoidVisible and IsSphereVisible(coords.x, coords.y, coords.z, 4.0) then
        return false, 'on screen'
    end

    return true
end

-------------------------------------------------------------------------------
-- The spawn point finder
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- Reservations
-------------------------------------------------------------------------------
--
-- Two cruisers landing on the same square metre and flipping each other.
--
-- maintainPoliceUnits fires up to MAX_CONCURRENT_SPAWNS requests in a single
-- tick, and each one is a separate round trip to the server before any vehicle
-- actually exists. IsPositionOccupied cannot help: when the second request picks
-- its spot, the first car has not been created yet. There is nothing in the
-- world to collide with, right up until there is.
--
-- Scoring made this worse rather than better. First-fit picked the first random
-- node that passed, so two calls scattered; scoring converges, and two calls a
-- few milliseconds apart with the same player position and the same road network
-- reliably agree on which lane centre is best. Deterministic lane choice
-- ('outer') then puts them on the exact same point.
--
-- So a chosen point is reserved for a few seconds, and later candidates have to
-- keep clear of it. The reservation outlives the round trip; after that the
-- vehicle exists and the ordinary occupancy check takes over.

local reservations = {}

local function pruneReservations(now, ttl)
    for i = #reservations, 1, -1 do
        if (now - reservations[i].at) > ttl then table.remove(reservations, i) end
    end
end

--- Is `pos` too close to a spot already promised to an in-flight spawn?
local function isReserved(pos, separation)
    local now = GetGameTimer()
    pruneReservations(now, (cfg().reservationSeconds or 25) * 1000)

    for _, r in ipairs(reservations) do
        if #(r.pos - pos) < separation then return true end
    end
    return false
end

--- Promise this spot to the spawn that just won it.
function FenixRoads.reserve(pos)
    if not pos then return end
    table.insert(reservations, { pos = pos, at = GetGameTimer() })
end

--- Drop every reservation. Called when a pursuit ends, so the next one is not
--- working around spots that were promised to units which no longer exist.
function FenixRoads.clearReservations()
    reservations = {}
end


--- Is this spot inside the arc the player is looking at?
---
--- Applied to the FINAL lane position rather than the sample point, because
--- resolving a sample to a road can move it a long way -- which is how a rear
--- sample ends up as a spawn dead ahead.
---
--- `maxForwardDot` is the cosine of the half-angle that counts as "in front":
---   0.0  anything in the forward half-plane is refused (the default)
---   0.7  only the front 90-degree cone is refused
---   1.0  nothing is refused
local function inFrontOfPlayer(pos, origin, opts)
    if not opts.behindVector then return false end

    local limit = opts.maxForwardDot or cfg().maxForwardDot or 0.0
    if limit >= 1.0 then return false end

    local fx, fy = opts.behindVector.x, opts.behindVector.y
    local flen = math.sqrt((fx * fx) + (fy * fy))
    if flen < 0.01 then return false end

    local dx, dy = pos.x - origin.x, pos.y - origin.y
    local dlen = math.sqrt((dx * dx) + (dy * dy))
    if dlen < 0.01 then return false end

    return ((((dx / dlen) * (fx / flen)) + ((dy / dlen) * (fy / flen)))) > limit
end

--- Can a car actually drive from here to there, without a detour so long the
--- unit would never arrive?
---
--- This is what catches the placements that look perfect on a map and are
--- useless in play: the freeway deck directly above the player, the far bank of
--- the Alamo Sea, the other side of a canyon. Straight-line distance says 90m,
--- the road network says three kilometres, and the unit spends its whole
--- lifetime driving. CALCULATE_TRAVEL_DISTANCE_BETWEEN_POINTS returns a very
--- large number when there is no route at all, so one ratio test covers both.
local function reachable(pos, target, straightLine)
    local ratio = cfg().maxTravelRatio
    if not ratio or ratio <= 0 then return true end
    if straightLine < 1.0 then return true end

    local travel = CalculateTravelDistanceBetweenPoints(
        pos.x, pos.y, pos.z, target.x, target.y, target.z)

    -- A zero or negative result means the native had nothing to say; treating
    -- that as unreachable would block every spawn on maps it does not cover.
    if not travel or travel <= 0.0 then return true end

    return travel <= (straightLine * ratio)
end


--- Find somewhere a police vehicle can legitimately appear.
---
--- Samples points on a ring around `origin`, resolves each to a real road,
--- places the vehicle in a correct lane facing a legal direction, validates it,
--- and scores whatever survives. Scoring rather than first-fit is what stops
--- every unit appearing at the same distance on the same side.
---
--- Returns coords, heading — or nil when nothing nearby qualifies.
---
--- @param origin vector3 usually the player
--- @param opts table
---   minDistance, maxDistance  ring to sample
---   behindVector    vector3   player forward; biases sampling into the rear arc
---   towards         vector3   direction of travel should head here (default origin)
---   attempts        number    ring samples
---   shoulder        boolean   park on the verge instead of in a lane
---   avoidVisible    boolean   never place inside the player's view
---   lanePreference  string    'outer' | 'inner' | 'random'
---   reject          function  extra caller-supplied veto, receives coords, heading
---   score           function  extra caller-supplied bonus, receives coords, heading
function FenixRoads.findSpawnPoint(origin, opts)
    opts = opts or {}
    local c = cfg()

    local minDist = opts.minDistance or 80.0
    local maxDist = opts.maxDistance or 140.0
    if maxDist < minDist then maxDist = minDist end

    local towards = opts.towards or origin
    local attempts = opts.attempts or c.spawnAttempts or 24
    local bestPos, bestHeading, bestScore
    local lastReason = 'no road nearby'

    for _ = 1, attempts do
        -- Rear arc, so units do not pop into existence straight ahead.
        --
        -- This used to convert the player's forward vector to a GTA heading with
        -- GetHeadingFromVector_2d, add the arc offset, and feed the result to
        -- sin/cos. Those two conventions run opposite ways -- GTA headings
        -- increase anticlockwise from north, sin/cos as used here sweeps
        -- clockwise from north -- so the result was the player's direction
        -- MIRRORED across the north-south axis. Facing north it happened to
        -- work; facing east, "behind" resolved to due east, and every unit
        -- appeared in the windscreen.
        --
        -- Rotating the forward vector directly sidesteps the conversion, and
        -- with it the chance of getting the convention wrong again.
        local dirX, dirY
        if opts.behindVector then
            local ang = math.rad(math.random(110, 250))
            local ca, sa = math.cos(ang), math.sin(ang)
            local fx, fy = opts.behindVector.x, opts.behindVector.y
            local len = math.sqrt((fx * fx) + (fy * fy))
            if len > 0.01 then fx, fy = fx / len, fy / len else fx, fy = 0.0, 1.0 end
            dirX = (fx * ca) - (fy * sa)
            dirY = (fx * sa) + (fy * ca)
        else
            local ang = math.rad(math.random(0, 359))
            dirX, dirY = math.sin(ang), math.cos(ang)
        end

        local dist = minDist + (math.random() * (maxDist - minDist))
        local road = roadAt(
            origin.x + (dirX * dist),
            origin.y + (dirY * dist),
            origin.z)

        if road then
            local pos, heading = placeOnRoad(road, towards, opts)
            if not pos then
                lastReason = 'road reports no drivable lane'
            else
                local d = #(pos - origin)
                if d < (minDist * (c.spawnDistanceMinRatio or 0.6))
                    or d > (maxDist * (c.spawnDistanceMaxRatio or 1.6)) then
                    -- The nearest road to the sample point was somewhere else
                    -- entirely; taking it would ignore the distance band.
                    lastReason = 'snapped outside the distance band'
                else
                    local ok, reason = FenixRoads.isSpawnable(pos, opts)
                    if not ok then
                        lastReason = reason
                    elseif isReserved(pos, opts.separation or c.spawnSeparation or 18.0) then
                        -- Another spawn from this same tick already claimed
                        -- here. Without this two cruisers land on one point and
                        -- flip each other the instant the second one appears.
                        lastReason = 'too close to a spawn already in flight'
                    elseif inFrontOfPlayer(pos, origin, opts) then
                        -- Sampling biases towards the rear arc, but the sample is
                        -- only a starting point -- the road it resolves to can be
                        -- anywhere, including straight ahead. The old first-fit
                        -- code had exactly this test and it was the only thing
                        -- actually keeping units out of the windscreen; the
                        -- rewrite replaced it with a scoring bonus on the ROAD's
                        -- direction, which is a different question entirely.
                        lastReason = 'in front of the player'
                    elseif opts.reject and opts.reject(pos, heading) then
                        lastReason = 'caller rejected'
                    elseif not reachable(pos, towards, d) then
                        lastReason = 'no road route to the target'
                    else
                        -- Mid-band is the sweet spot: close enough to matter,
                        -- far enough that the player drives up on it.
                        local mid = (minDist + maxDist) * 0.5
                        local span = math.max(1.0, (maxDist - minDist) * 0.5)
                        local score = 100.0 - ((math.abs(d - mid) / span) * 40.0)

                        -- Prefer wider, busier roads: a pursuit that starts on a
                        -- four-lane boulevard behaves far better than one that
                        -- starts in a cul-de-sac.
                        score = score + (math.min(road.fwdLanes + road.bwdLanes, 6) * 4.0)
                        local density = nodeDensity(pos)
                        if density then score = score + (density * 2.0) end

                        -- Facing the target is a bonus, never a requirement.
                        -- Making it a requirement is exactly how you end up
                        -- spawning against the flow on a one-way street.
                        local fx, fy = forwardOf(heading)
                        local tx, ty = towards.x - pos.x, towards.y - pos.y
                        local len = math.sqrt((tx * tx) + (ty * ty))
                        if len > 0.01 then
                            score = score + ((((tx / len) * fx) + ((ty / len) * fy)) * 15.0)
                        end

                        if opts.score then score = score + (opts.score(pos, heading) or 0.0) end

                        if not bestScore or score > bestScore then
                            bestPos, bestHeading, bestScore = pos, heading, score
                        end
                    end
                end
            end
        end
    end

    if not bestPos then
        dbg(('no spawn point in %.0f-%.0fm after %d samples (last rejection: %s)')
            :format(minDist, maxDist, attempts, lastReason))
        return nil
    end

    -- Claim it, so the next request in this same tick has to keep clear.
    if opts.reserve ~= false then FenixRoads.reserve(bestPos) end

    return bestPos, bestHeading
end

--- Snap an authored point onto a real lane, aiming it down whichever direction
--- its own heading already described. Used by the ambient system for its shipped
--- radar-trap seeds, which are documented as approximate.
---
--- Returns coords, heading, snapped — the inputs unchanged with snapped = false
--- when there is no road in range. Callers need that third value: a scene that
--- was NOT snapped still has to apply its own offset, and one that was must not.
function FenixRoads.snapToLane(coords, heading, opts)
    opts = opts or {}

    local road = roadAt(coords.x, coords.y, coords.z)
    if not road then return coords, heading, false end
    if #(road.center - coords) > (opts.maxSnap or 120.0) then return coords, heading, false end

    local towards
    if heading then
        local fx, fy = forwardOf(heading)
        towards = vector3(coords.x + (fx * 50.0), coords.y + (fy * 50.0), coords.z)
    end

    local pos, newHeading = placeOnRoad(road, towards, opts)
    if not pos then return coords, heading, false end
    return pos, newHeading, true
end

--- The road's legal travel directions at a point, for callers that only need to
--- correct a heading they already hold.
function FenixRoads.roadInfoAt(coords)
    return roadAt(coords.x, coords.y, coords.z)
end

-------------------------------------------------------------------------------
-- Debug
-------------------------------------------------------------------------------
--
-- The exclusion zones shipped in config.lua are hand-measured boxes, and the
-- only honest way to check a hand-measured box is to stand in it and look. This
-- draws every zone as a wireframe column, and reports what the road system makes
-- of the ground under your feet.

local drawing = false

RegisterCommand('fenixroads', function(_, args)
    local arg = (args[1] or ''):lower()

    if arg == 'here' then
        local me = GetEntityCoords(PlayerPedId())
        local excluded, zoneName = FenixRoads.isExcluded(me)
        local ok, reason = FenixRoads.isSpawnable(me, {})
        local road = roadAt(me.x, me.y, me.z)
        local streetHash = GetStreetNameAtCoord(me.x, me.y, me.z)

        print(('[FENIX-ROADS] %.2f, %.2f, %.2f'):format(me.x, me.y, me.z))
        print(('  zone       %s'):format(GetNameOfZone(me.x, me.y, me.z)))
        print(('  street     %s'):format(
            (streetHash and streetHash ~= 0) and GetStreetNameFromHashKey(streetHash) or 'UNNAMED'))
        print(('  excluded   %s'):format(excluded and zoneName or 'no'))
        print(('  spawnable  %s'):format(ok and 'yes' or ('no - ' .. tostring(reason))))
        if road then
            print(('  road       heading %.1f, %d lane(s) forward / %d back, width %.1f%s')
                :format(road.heading, road.fwdLanes, road.bwdLanes, road.width,
                    road.approximate and '  [fallback: GET_CLOSEST_ROAD unavailable or failed the divided-road cross-check]' or ''))
        else
            print('  road       none')
        end
        return
    end

    drawing = not drawing
    print(('[FENIX-ROADS] zone overlay %s - "/fenixroads here" for a point report')
        :format(drawing and 'ON' or 'OFF'))

    if not drawing then return end

    CreateThread(function()
        while drawing do
            Wait(0)
            local me = GetEntityCoords(PlayerPedId())
            for _, zone in ipairs(cfg().exclusionZones or {}) do
                local minX, minY, maxX, maxY = zoneBounds(zone)
                if minX then
                    local cx, cy = (minX + maxX) * 0.5, (minY + maxY) * 0.5
                    local dx, dy = cx - me.x, cy - me.y
                    if ((dx * dx) + (dy * dy)) < (3000.0 * 3000.0) then
                        local zMin = zone.zMin or -50.0
                        local zMax = zone.zMax or 100.0
                        local r, g, b = 200, 40, 40
                        if zone.enabled == false then r, g, b = 90, 90, 90 end

                        local corners = {
                            { minX, minY }, { maxX, minY }, { maxX, maxY }, { minX, maxY },
                        }
                        for i = 1, 4 do
                            local a = corners[i]
                            local n = corners[(i % 4) + 1]
                            DrawLine(a[1], a[2], zMin, a[1], a[2], zMax, r, g, b, 180)
                            DrawLine(a[1], a[2], zMin, n[1], n[2], zMin, r, g, b, 180)
                            DrawLine(a[1], a[2], zMax, n[1], n[2], zMax, r, g, b, 180)
                        end
                    end
                end
            end
        end
    end)
end, false)
