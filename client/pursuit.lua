--[[
    client/pursuit.lua

    What the police actually KNOW, as opposed to where you actually are.

    The pursuit loop in client/client.lua re-tasked every driver to the player's
    live coordinates once a second. Officers were therefore omniscient: you could
    be in a garage, behind a hill, or three streets away in an alley and every
    unit still drove straight at you. `Config.evasionTimes` decided when the
    STARS came off, but nothing decided what the units knew, so hiding was a
    countdown you sat through rather than a thing you did.

    This file holds the missing model:

      contact    at least one officer can currently see the player
      searching  contact was lost; units work the last known position and the
                 search radius widens the longer it stays lost
      reacquired contact regained, everyone converges again

    Everything else here hangs off that one state machine, because everything
    else the player reads a pursuit through is really a question about contact:

      blips      an officer's AI blip cone IS "what this officer can see"
      sirens     units go quiet when they lose you and wind up when they find you
      speech     officers call out spotting and losing the target
      dispatch   the radio traffic describing your vehicle, street and direction

    client/client.lua feeds observers in from its chase loops (once a second) and
    reads the target position back out. The line-of-sight work runs on its own
    faster thread here, because one second is far too coarse for "can they see me
    right now".
]]

FenixPursuit = {}

local function cfg() return Config.Pursuit or {} end
local function dbg(msg) if cfg().debug then print('[FENIX-PURSUIT] ' .. msg) end end

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

-- ped handle -> { kind = 'ground'|'heli'|'air', seenAt = gameTimer, blip = bool }
-- Refreshed by client.lua every chase cycle; entries that stop being refreshed
-- are pruned, which is how a deleted or despawned officer leaves the set without
-- client.lua having to tell us.
local observers = {}

local contact = {
    active       = false,      -- somebody can see the player right now
    lastKnown    = nil,        -- vector3, where they were last seen
    lastHeading  = 0.0,        -- which way they were going, for the radio call
    lastSeenAt   = 0,          -- game timer
    lostAt       = 0,          -- game timer when contact broke, 0 while held
    gaveUp       = false,      -- search called off after Config.Pursuit.giveUpAfterMs, see isSearching()
    everSeen     = false,      -- suppresses "lost the suspect" before first sight
    firstContactAt = 0,        -- game timer of the FIRST sighting this pursuit, see FenixPursuit.pursuitElapsedMs()
    vehicleDesc  = nil,        -- cached description of the car they were last in

    -- What dispatch broadcast when the crime was called in — see callItIn().
    -- Read by tells() below to answer "does the player still match their own
    -- description". nil (outfitSig especially) doubles as "no pursuit called
    -- in since the last reset", which is what gates tells() entirely.
    outfitSig    = nil,        -- string, drawable+texture ids across every clothing component
    vehicleModel = nil,        -- model hash the player was in when called in, or nil for on foot

    -- Where the player was when the wanted level went up: the location the
    -- call came from, and all units have to go on until somebody sees them.
    -- See FenixPursuit.targetCoords().
    dispatchPos  = nil,
}

-- Rate limiting for the radio, so a player weaving through traffic doesn't
-- generate a call every time a wall passes between them and a cruiser.
local lastDispatchAt = 0
local lastSpeechAt = 0

-- Game timer of the player's last shot, kept by the shot thread below.
-- IsPedShooting is only true on the frame a round leaves the barrel, so the
-- contact tick sampling it every 250ms missed most single shots.
local lastShotAt = 0

-- The darkness multiplier the contact tick last used (see nightSight), kept
-- only so the debug print fires when it changes rather than every tick.
local lastNightSight = 1.0

-- Game timers of the last takedown and custody calls. Not cleared by
-- FenixPursuit.reset(): an arrest can end the wanted level -- and with it
-- the pursuit -- either side of its own custody call, and a reset between two
-- reports of one arrest must not let the second one through.
local lastTakedownAt = 0
local lastCustodyAt = 0

-------------------------------------------------------------------------------
-- Small helpers
-------------------------------------------------------------------------------

local COMPASS = { 'north', 'north-east', 'east', 'south-east',
                  'south', 'south-west', 'west', 'north-west' }

--- Heading to an eight-point compass word. GTA heading 0 is north and increases
--- anticlockwise, so the octant has to be measured off (360 - heading).
local function compassFor(heading)
    local h = (360.0 - ((heading or 0.0) % 360.0)) % 360.0
    return COMPASS[(math.floor((h + 22.5) / 45.0) % 8) + 1]
end

--- Street name at a point, or nil where the game has none (which is itself
--- meaningful — see client/roads.lua on unnamed surfaces).
local function streetAt(coords)
    local hash = GetStreetNameAtCoord(coords.x, coords.y, coords.z)
    if not hash or hash == 0 then return nil end
    local name = GetStreetNameFromHashKey(hash)
    if not name or name == '' or name == 'NULL' then return nil end
    return name
end

-- Vehicle paint index -> what a person would say on the radio. Only the indices
-- worth naming; anything else is described without a colour rather than with a
-- wrong one.
local COLOURS = {
    [0] = 'black', [1] = 'black', [2] = 'black', [3] = 'grey', [4] = 'grey',
    [5] = 'grey', [6] = 'silver', [7] = 'silver', [8] = 'grey', [9] = 'blue',
    [11] = 'red', [12] = 'red', [27] = 'red', [28] = 'red',
    [111] = 'white', [112] = 'white', [113] = 'white', [121] = 'white',
    [88] = 'yellow', [89] = 'yellow', [126] = 'yellow',
    [49] = 'green', [50] = 'green', [51] = 'green', [52] = 'green',
    [53] = 'green', [54] = 'green', [55] = 'green', [56] = 'green',
    [38] = 'orange', [124] = 'orange',
    [61] = 'blue', [62] = 'blue', [63] = 'blue', [64] = 'blue',
    [73] = 'blue', [74] = 'blue', [75] = 'blue', [76] = 'blue',
    [93] = 'brown', [94] = 'brown', [95] = 'brown', [96] = 'brown',
}

--- "a black Sultan", or nil when the player is on foot. Built once per pursuit
--- and cached: the model and paint don't change mid-chase, and both natives are
--- more expensive than the string they produce.
local function describeVehicle(vehicle)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return nil end

    local model = GetEntityModel(vehicle)
    local name = GetLabelText(GetDisplayNameFromVehicleModel(model))
    if not name or name == '' or name == 'NULL' then
        name = GetDisplayNameFromVehicleModel(model)
    end
    if not name or name == '' then return nil end

    local primary = GetVehicleColours(vehicle)
    local colour = COLOURS[primary]

    if colour then
        return ('a %s %s'):format(colour, name)
    end
    return ('a %s'):format(name)
end

--- Drawable+texture id across every clothing component, concatenated into one
--- comparable string. Not a real appearance hash (props/hair colour/etc.
--- aren't included) — just enough to answer "did they change clothes since
--- the crime", which is a coarser question than "what do they look like now".
local function outfitSignature(ped)
    local parts = {}
    for i = 0, 11 do
        parts[#parts + 1] = GetPedDrawableVariation(ped, i)
        parts[#parts + 1] = GetPedTextureVariation(ped, i)
    end
    return table.concat(parts, ':')
end

-------------------------------------------------------------------------------
-- Radio
-------------------------------------------------------------------------------

--- One line of radio traffic. Deliberately not a notification per event: a
--- pursuit should produce four or five calls, not a running commentary, so
--- everything here is rate limited and only the state CHANGES call in.
local function dispatch(message, force)
    local c = cfg()
    if c.dispatchMessages == false then return end

    local now = GetGameTimer()
    if not force and (now - lastDispatchAt) < (c.dispatchCooldown or 8000) then return end
    lastDispatchAt = now

    local text = ('%s %s'):format(c.dispatchPrefix or 'DISPATCH:', message)

    if c.dispatchHandler and type(c.dispatchHandler) == 'function' then
        c.dispatchHandler(text)
    else
        FenixFramework.Notify(text, 'police', c.dispatchDuration or 6000)
    end

    dbg('radio: ' .. text)
end

--- Cop voice line on the nearest officer who can be heard.
---
--- Ambient speech is used rather than scanner audio because it degrades
--- silently: a context this build of the game doesn't have simply doesn't play,
--- where a bad scanner report name is an error. Nothing here is load-bearing.
local function speak(context)
    local c = cfg()
    if c.officerSpeech == false then return end

    local now = GetGameTimer()
    if (now - lastSpeechAt) < (c.speechCooldown or 6000) then return end

    local me = GetEntityCoords(PlayerPedId())
    local best, bestDist

    for ped in pairs(observers) do
        if DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true) then
            local d = #(GetEntityCoords(ped) - me)
            if d < (c.speechRange or 60.0) and (not bestDist or d < bestDist) then
                best, bestDist = ped, d
            end
        end
    end

    if not best then return end
    lastSpeechAt = now
    PlayPedAmbientSpeechNative(best, context, 'SPEECH_PARAMS_FORCE_NORMAL')
end

-------------------------------------------------------------------------------
-- Perception
-------------------------------------------------------------------------------

--- Is another vehicle between this officer and the player?
---
--- A separate probe rather than adding vehicles (2) to the LOS flags below:
--- with vehicles in the mask the ray stops on the officer's own car and on the
--- car the player is sitting in, and nothing would ever be seen again. Here the
--- officer's car is excluded outright, and a hit on the player's own car (or
--- anything right where the player is) counts as reaching them. A car right
--- beside the officer doesn't count either: that's an officer on foot using
--- a car as cover, who looks over or round it, and treating it as a wall
--- blinded every officer in a shootout at once.
local function trafficInTheWay(ped, playerPed, pedCoords, playerCoords)
    local ownVeh = GetVehiclePedIsIn(ped, false)
    local probe = StartExpensiveSynchronousShapeTestLosProbe(
        pedCoords.x, pedCoords.y, pedCoords.z + 0.5,
        playerCoords.x, playerCoords.y, playerCoords.z + 0.3,
        2, ownVeh, 4)
    local status, hit, hitCoords, _, entityHit = GetShapeTestResult(probe)
    if status ~= 2 or not (hit == true or hit == 1) then return false end

    if entityHit ~= 0 and entityHit == GetVehiclePedIsIn(playerPed, false) then return false end
    if hitCoords then
        local at = vector3(hitCoords.x, hitCoords.y, hitCoords.z)
        if #(at - playerCoords) < 3.0 or #(at - pedCoords) < 3.0 then return false end
    end
    return true
end

--- Is it dark by the in-game clock? Handles a window that wraps midnight
--- (21 to 6) as well as one that doesn't.
local function isNight(night)
    local hour = GetClockHours()
    local from, to = tonumber(night.startHour) or 21, tonumber(night.endHour) or 6
    if from > to then return hour >= from or hour < to end
    return hour >= from and hour < to
end

--- How far, as a fraction of the normal sight range, an observer with no
--- light of their own can see the player right now. Taken once per contact
--- tick, not per observer: it only depends on the clock and the player.
---
--- 1.0 by day. At night a car running dark, or a suspect on foot, is far
--- harder to pick out than the same car with its headlights on -- which is
--- the point: the stealth is something the player does (lights off), not
--- something the clock hands them, and driving round lit up at 2am gets them
--- seen exactly as at noon.
local function nightSight(c, playerPed)
    local night = c.night
    if night == false then return 1.0 end
    if type(night) ~= 'table' then night = {} end
    if night.enabled == false or not isNight(night) then return 1.0 end

    local vehicle = GetVehiclePedIsIn(playerPed, false)
    if vehicle ~= 0 then
        local _, lightsOn, highbeamsOn = GetVehicleLightsState(vehicle)
        if lightsOn == true or lightsOn == 1 or highbeamsOn == true or highbeamsOn == 1 then
            return tonumber(night.lightsOnMultiplier) or 1.0
        end
    end
    return tonumber(night.sightMultiplier) or 0.6
end

--- This observer's sight range this tick. A police helicopter with its
--- nightsun on brings its own light, so darkness doesn't shorten what its
--- spotter can see; anyone else is cut by `dark` (see nightSight).
local function sightRange(c, ped, kind, dark)
    local range = (kind == 'ground') and (c.sightRange or 90.0) or (c.airSightRange or 250.0)
    if dark == 1.0 then return range end

    if kind == 'heli' then
        local heli = GetVehiclePedIsIn(ped, false)
        if heli ~= 0 and IsVehicleSearchlightOn(heli) then
            return range * math.max(dark, 1.0)
        end
    end
    return range * dark
end

--- Can this officer see the player right now?
---
--- Gates cheapest first. Distance rules out most of the set without a trace;
--- the field-of-view test stops an officer facing the other way from "seeing"
--- through the back of their head; only survivors pay for the rays (world and
--- props first, then traffic).
---
--- Air units skip the FOV test on purpose — a helicopter carries a spotter whose
--- whole job is looking down, and giving them a forward cone makes them useless
--- at the one thing they exist for.
--- @param range number this observer's sight range this tick, see sightRange
local function canSee(ped, kind, playerPed, playerCoords, range)
    local c = cfg()

    local pedCoords = GetEntityCoords(ped)
    local dist = #(pedCoords - playerCoords)

    if dist > range then return false end

    if kind == 'ground' then
        local fov = c.sightFov or 160.0
        if fov < 360.0 then
            local heading = GetEntityHeading(ped)
            local fx, fy = -math.sin(math.rad(heading)), math.cos(math.rad(heading))
            local dx, dy = playerCoords.x - pedCoords.x, playerCoords.y - pedCoords.y
            local len = math.sqrt((dx * dx) + (dy * dy))
            if len > 0.01 then
                local dot = ((dx / len) * fx) + ((dy / len) * fy)
                -- Anything closer than a car length is "seen" regardless of
                -- facing: an officer does not lose the car touching their bumper
                -- because the driver glanced sideways.
                if dist > 8.0 and dot < math.cos(math.rad(fov * 0.5)) then return false end
            end
        end
    end

    -- 17 = map (1) + objects (16): buildings, terrain and props.
    if not HasEntityClearLosToEntity(ped, playerPed, 17) then return false end

    -- Traffic only hides you from street level; from the air it doesn't.
    if kind ~= 'ground' or c.vehiclesBlockSight == false then return true end
    return not trafficInTheWay(ped, playerPed, pedCoords, playerCoords)
end

--- Noise reveals. Firing a weapon inside earshot of a unit hands your position
--- back no matter how good the cover is, which is both realistic and the reason
--- shooting your way out of a hiding place should not work.
local function makingNoise(playerCoords)
    local c = cfg()
    if c.gunfireReveals == false then return false end

    -- At least two contact ticks wide, so a shot can't fall between them.
    local window = math.max(500, (c.contactInterval or 250) * 2)
    if lastShotAt == 0 or (GetGameTimer() - lastShotAt) > window then return false end

    local range = c.gunfireRange or 120.0
    for ped in pairs(observers) do
        if DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true)
            and #(GetEntityCoords(ped) - playerCoords) < range then
            return true
        end
    end
    return false
end

-------------------------------------------------------------------------------
-- Blips
-------------------------------------------------------------------------------
--
-- AI blips rather than blips of our own, because the cone an AI blip draws is
-- literally the thing this file computes: which way an officer is looking. When
-- they lose you and start sweeping, the cones sweep with them, and the player
-- reads the search without being told about it.

--- Should this officer carry a blip right now?
---
--- One per vehicle by default. A four-unit response is eight officers, and eight
--- overlapping blips on the same eight cars is not more information than four —
--- it is a smear on the minimap that hides the cones underneath it. Officers on
--- foot always blip: at that point they are the unit.
local function wantsBlip(ped, c)
    if c.blips == false then return false end
    if c.blipDriversOnly == false then return true end

    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 then return true end
    return GetPedInVehicleSeat(veh, -1) == ped
end

--- Add or remove an officer's blip to match what they currently are. Evaluated
--- on the contact tick rather than once at registration, because who is driving
--- changes: a passenger who bails out becomes a unit and needs a blip, and a
--- driver who is dragged out stops being one.
---
--- The cone's reach follows `range`, this tick's sight range, rather than
--- being set once: it moves with nightfall, the player's headlights and a
--- heli's nightsun, and a cone still showing the daytime range at night would
--- stop being the contact model it is there to show.
local function updateBlip(ped, entry, c, range)
    local want = wantsBlip(ped, c)
    if want == entry.blip then
        if want and entry.blipRange ~= range then
            SetPedAiBlipNoticeRange(ped, range)
            entry.blipRange = range
        end
        return
    end

    if want then
        if c.blipColour then
            SetPedHasAiBlipWithColor(ped, true, c.blipColour)
        else
            SetPedHasAiBlip(ped, true)
        end
        SetPedAiBlipHasCone(ped, c.blipCones ~= false)
        SetPedAiBlipNoticeRange(ped, range)
        entry.blipRange = range
    else
        SetPedHasAiBlip(ped, false)
        entry.blipRange = nil
    end

    entry.blip = want
end

local function clearBlip(ped)
    if DoesEntityExist(ped) then
        SetPedHasAiBlip(ped, false)
    end
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

--- Register (or refresh) an officer as somebody who can see for the pursuit.
--- Called from client.lua's chase loops every cycle. An entry not refreshed
--- inside `observerTimeout` loses its blip but keeps looking; a deleted or
--- dead officer drops out of the set on its own.
--- @param kind string 'ground' | 'heli' | 'air'
function FenixPursuit.noteObserver(ped, kind)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return end

    local entry = observers[ped]
    if entry then
        entry.seenAt = GetGameTimer()
        entry.kind = kind or entry.kind
    else
        -- The blip is applied on the next contact tick rather than here: whether
        -- this officer should carry one depends on where they are sitting, and
        -- at registration they are often not seated yet.
        observers[ped] = { kind = kind or 'ground', seenAt = GetGameTimer(), blip = false }
    end
end

--- True while at least one unit can see the player.
---
--- Reports true when the module is switched off, and every caller depends on
--- that: with perception disabled the intended behaviour is the old omniscient
--- pursuit, not one where nobody can ever see you. A plain `contact.active`
--- would leave units permanently searching and passengers permanently holding
--- fire, which is the opposite of "disabled".
function FenixPursuit.hasContact()
    if cfg().enabled == false then return true end
    return contact.active
end

--- True while units are working a last known position instead of the player.
--- False again once the search is called off (see giveUpAfterMs above) even
--- though lastKnown is still set -- that gap is what lets vice_hud tell "still
--- actively hunting" apart from "gave up, but you're still wanted".
function FenixPursuit.isSearching()
    if cfg().enabled == false then return false end
    return (not contact.active) and contact.everSeen and contact.lastKnown ~= nil and not contact.gaveUp
end

--- True once a search has been called off without the wanted level clearing.
--- This is the state vice_hud's wanted stars read as 'red' (see wantedState()
--- in vice_hud/client.lua): HasContact() and IsSearching() both false, but
--- the pursuit was contacted at some point since the level was raised.
function FenixPursuit.hasGivenUp()
    return contact.gaveUp
end

--- Where units should currently be driving.
---
--- The whole point of the file in one function: the player's real position while
--- anybody can see them, and the last place they were seen once nobody can. When
--- contact has never been made — units are still en route to the original call —
--- the dispatch position is the best information anyone has, so that is what
--- they get.
function FenixPursuit.targetCoords(playerCoords)
    if cfg().enabled == false then return playerCoords, true end
    if contact.active then return playerCoords, true end
    if contact.lastKnown then return contact.lastKnown, false end
    -- Normally snapshotted by the contact thread the tick the wanted level
    -- goes up; taken here instead if a unit asks first.
    if not contact.dispatchPos then contact.dispatchPos = playerCoords end
    return contact.dispatchPos, false
end

--- How far out units should be sweeping. Grows while contact stays lost, so a
--- search starts tight on the last sighting and loosens into the surrounding
--- blocks rather than being a fixed circle.
function FenixPursuit.searchRadius()
    if not FenixPursuit.isSearching() then return 0.0 end

    local c = cfg()
    local elapsed = (GetGameTimer() - contact.lostAt) / 1000.0
    local radius = (c.searchRadiusStart or 40.0) + (elapsed * (c.searchRadiusGrowth or 4.0))
    return math.min(radius, c.searchRadiusMax or 180.0)
end

--- Seconds since the player was last seen, or 0 while in contact.
function FenixPursuit.secondsSinceSeen()
    if contact.active or contact.lastSeenAt == 0 then return 0.0 end
    return (GetGameTimer() - contact.lastSeenAt) / 1000.0
end

--- Milliseconds since a cop FIRST laid eyes on the player this pursuit, or 0
--- before that has ever happened. Keeps counting through a lost-contact
--- search rather than resetting -- dispatch doesn't forget the incident is
--- live just because nobody currently has eyes on you, and this is what
--- client.lua's reinforcement escalation (Config.Reinforcement) reads to
--- decide how many extra units the longer a suspect stays out are worth
--- sending. Reset to 0 by FenixPursuit.reset() when the wanted level clears.
function FenixPursuit.pursuitElapsedMs()
    if not contact.everSeen or contact.firstContactAt == 0 then return 0 end
    return GetGameTimer() - contact.firstContactAt
end

--- Should this unit's siren be running? Units go quiet on a search: a siren is
--- how you tell a street you are coming, and a unit that has lost the suspect
--- wants to hear, not announce. Lights stay on throughout. Also quiet once
--- the search is called off entirely -- standing down is not a reason to
--- start announcing again, it's the opposite.
function FenixPursuit.sirenWanted()
    -- With perception off nothing ever sets contact.active, so it has to be
    -- answered here or every siren stays muted for good -- same reasoning as
    -- hasContact() above.
    if cfg().enabled == false or cfg().quietSearch == false then return true end
    return contact.active
end

--- What dispatch's description of the player still matches, right now.
--- `true` on a key means that tell is still live — the player still looks
--- like the person dispatch described, so it's still working against them.
--- Getting a tell to read `false` is what "changing your outfit" / "changing
--- vehicles" actually buys the player; see client/tracker.lua for the same
--- idea applied to the vehicle itself rather than its description.
---
--- Every key reads false before any pursuit has been called in (outfitSig is
--- nil) — nothing to compare against yet — and `voice` never clears once one
--- has: there's no voice-changing mechanic in this codebase, so once
--- dispatch has heard the player that tell is permanent for the pursuit.
--- @return { outfit: boolean, vehicle: boolean, voice: boolean }
function FenixPursuit.tells()
    if cfg().enabled == false or not contact.outfitSig then
        return { outfit = false, vehicle = false, voice = false }
    end

    local playerPed = PlayerPedId()
    local outfitTell = contact.outfitSig == outfitSignature(playerPed)

    local vehicleTell = false
    if contact.vehicleModel then
        local veh = GetVehiclePedIsIn(playerPed, false)
        vehicleTell = veh ~= 0 and GetEntityModel(veh) == contact.vehicleModel
    end

    return { outfit = outfitTell, vehicle = vehicleTell, voice = true }
end

--- Full reset. Called when the wanted level clears, so the next pursuit starts
--- from no knowledge rather than inheriting the last one's last known position.
function FenixPursuit.reset()
    for ped in pairs(observers) do clearBlip(ped) end
    observers = {}

    contact.active       = false
    contact.lastKnown    = nil
    contact.lastHeading  = 0.0
    contact.lastSeenAt   = 0
    contact.lostAt       = 0
    contact.gaveUp       = false
    contact.everSeen     = false
    contact.firstContactAt = 0
    contact.vehicleDesc  = nil
    contact.outfitSig    = nil
    contact.vehicleModel = nil
    contact.dispatchPos  = nil

    lastDispatchAt = 0
    lastSpeechAt = 0
    lastShotAt = 0
end

--- Opening radio call, made once per pursuit, but on the first REAL
--- contact (see the contact thread's `firstEver` branch below), not on the
--- wanted level going up. Getting a wanted level only means SOMEONE
--- witnessed something; it says nothing about whether a cop has actually
--- seen the player yet, and dispatch describing an outfit/vehicle nobody in
--- uniform has laid eyes on is what let cops "know what you look like" from
--- the moment you became wanted.
function FenixPursuit.callItIn(wantedLevel)
    if cfg().enabled == false then return end

    local playerPed = PlayerPedId()
    local coords = GetEntityCoords(playerPed)
    local vehicle = GetVehiclePedIsIn(playerPed, false)

    contact.vehicleDesc = describeVehicle(vehicle)

    -- What tells() compares the player's CURRENT state against — this is the
    -- description dispatch actually has, snapshotted the moment it goes out,
    -- not re-derived later from whatever the player looks like by then.
    contact.outfitSig = outfitSignature(playerPed)
    contact.vehicleModel = (vehicle ~= 0) and GetEntityModel(vehicle) or nil

    local where = streetAt(coords)
    local parts = {}

    table.insert(parts, (wantedLevel >= 4)
        and 'All units, armed suspect'
        or  'Units respond, suspect')

    if contact.vehicleDesc then
        table.insert(parts, 'in ' .. contact.vehicleDesc)
    else
        table.insert(parts, 'on foot')
    end

    if where then table.insert(parts, 'on ' .. where) end

    dispatch(table.concat(parts, ' ') .. '.', true)
end

--- Radio call for a reinforcement escalation -- see Config.Reinforcement and
--- client.lua's reinforcementBonus(): the longer a spotted suspect stays out,
--- the more units get added on top of the wanted level's normal cap. Forced
--- (bypasses the normal dispatch cooldown) because this only fires a handful
--- of times per pursuit at most, capped by Config.Reinforcement.maxBonusUnits
--- -- it should always be heard, not swallowed by whatever else is on the
--- radio that second.
function FenixPursuit.announceReinforcement(totalBonusUnits)
    if cfg().enabled == false then return end
    dispatch(('Suspect still evading, additional units responding (%d).')
        :format(totalBonusUnits), true)
end

--- Radio call the moment a K9 unit is released against a foot chase (see
--- Config.K9 / client.lua's deployK9). Forced for the same reason
--- announceReinforcement is -- a rare, specific escalation that should always
--- be heard over whatever else is on the radio that second.
function FenixPursuit.announceK9()
    if cfg().enabled == false then return end
    dispatch('K9 unit deployed, suspect on foot.', true)
end

--- Radio call for a genuine incident-driven escalation — see
--- client/backup.lua's FenixBackup, which decides WHEN this is warranted
--- (officer down, officer taking fire) as opposed to announceReinforcement's
--- plain "still evading, been a while" clock. Forced for the same reason the
--- other escalations here are: rare, and should always cut through whatever
--- else is on the radio that second.
--- @param kind string|nil 'officerDown' | 'takingFire'
function FenixPursuit.announceBackupRequest(kind)
    if cfg().enabled == false then return end
    if kind == 'takingFire' then
        dispatch('Officer under attack, requesting backup.', true)
    else
        dispatch('Shots fired, officer down! All units respond.', true)
    end
end

--- Radio call for a unit disengaging — see client/morale.lua's FenixMorale,
--- which decides when a unit has taken enough losses or is badly enough
--- outnumbered to fall back and regroup instead of fighting to the last
--- officer. One call per retreat, not per officer.
function FenixPursuit.announceRetreat()
    if cfg().enabled == false then return end
    dispatch('Unit disengaging, requesting relief.', true)
end

--- Radio call for a jurisdiction handoff — see client/jurisdiction.lua's
--- FenixJurisdiction, which detects the player crossing from one agency's
--- ground into another's mid-pursuit. Takes agency names
--- (FenixJurisdiction.agencyOf), never region keys.
function FenixPursuit.announceHandoff(fromAgency, toAgency)
    if cfg().enabled == false then return end
    local msg = ('Suspect entering %s jurisdiction'):format(tostring(toAgency or 'a neighbouring'))
    if fromAgency then
        msg = msg .. (' — %s units, expect a handoff.'):format(tostring(fromAgency))
    else
        msg = msg .. ' — responding units, expect a handoff.'
    end
    dispatch(msg, true)
end

-- How the end of a pursuit sounds on the radio. Called by the arrest system,
-- both safe to call at any time, from anywhere, as often as it likes:
--
--   FenixPursuit.announceTakedown(kind)  suspect brought down, officers moving
--                                        in; kind 'taser' | 'tackle' | 'k9'
--   FenixPursuit.announceCustody()       suspect cuffed, pursuit over
--
-- Both are forced past the normal dispatch cooldown and rate limited on their
-- own instead: the moment a suspect goes down is usually the moment
-- "re-acquired" has just gone out, and the cooldown would swallow the one call
-- that matters.

-- Within this long of a custody call, another is the same arrest reported
-- twice, not a second arrest.
local CUSTODY_REPEAT_MS = 15000

local TAKEDOWN_CALLS = {
    taser  = 'Taser deployed, suspect is down.',
    tackle = 'Suspect tackled, officers moving in.',
    k9     = 'K9 has the suspect, officers moving in.',
}

--- Radio call for a less-lethal takedown. At most one per dispatchCooldown,
--- so a suspect who keeps getting back up isn't announced every time the
--- taser is reloaded.
--- @param kind string|nil 'taser' | 'tackle' | 'k9'; anything else gets a generic call
function FenixPursuit.announceTakedown(kind)
    local c = cfg()
    if c.enabled == false then return end

    local now = GetGameTimer()
    if lastTakedownAt ~= 0 and (now - lastTakedownAt) < (c.dispatchCooldown or 8000) then return end
    lastTakedownAt = now

    dispatch(TAKEDOWN_CALLS[kind] or 'Suspect is down, officers moving in.', true)
end

--- Radio call once the suspect is in cuffs: the pursuit's last word. Once per
--- arrest, however many places report it.
function FenixPursuit.announceCustody()
    if cfg().enabled == false then return end

    local now = GetGameTimer()
    if lastCustodyAt ~= 0 and (now - lastCustodyAt) < CUSTODY_REPEAT_MS then return end
    lastCustodyAt = now

    dispatch('Suspect in custody, code 4. All units clear.', true)
end

-------------------------------------------------------------------------------
-- The contact thread
-------------------------------------------------------------------------------
--
-- Runs faster than the one-second pursuit loop because "can they see me" changes
-- at the speed of driving past a wall, not at the speed of task assignment. It
-- costs one distance check per observer per tick and a ray only for the ones
-- that pass, with the whole thing skipped entirely when nothing is chasing you.

CreateThread(function()
    while true do
        local c = cfg()
        local interval = c.contactInterval or 250

        local wanted = GetPlayerWantedLevel(PlayerId())
        if c.enabled ~= false then
            if wanted > 0 then
                if not contact.dispatchPos then
                    -- The wanted level just went up: this is where the call
                    -- came from, and where units head until somebody actually
                    -- sees the player.
                    contact.dispatchPos = GetEntityCoords(PlayerPedId())
                end
            elseif not contact.everSeen then
                -- Came and went before anyone saw them; the next wanted level
                -- is a new call from wherever it happens.
                contact.dispatchPos = nil
            end
        end

        -- With nobody registered as eyes there is still work to do while a
        -- pursuit that has had contact is live: contact has to be able to
        -- LAPSE once every unit is dead or gone. Skipping the state machine
        -- entirely froze it -- hasContact() stayed true forever, the search
        -- never started or gave up, and road tactics kept deploying against a
        -- suspect nobody could see.
        local noEyes = next(observers) == nil
        if c.enabled == false or (noEyes and not (contact.everSeen and wanted > 0)) then
            -- Nothing is chasing you: idle at a slower tick rather than paying
            -- for a perception pass over an empty set several times a second.
            interval = 500
        else
            if noEyes then interval = 500 end

            local playerPed = PlayerPedId()
            local playerCoords = GetEntityCoords(playerPed)
            local now = GetGameTimer()
            local timeout = c.observerTimeout or 4000

            local dark = nightSight(c, playerPed)
            if dark ~= lastNightSight then
                dbg(('sight range x%.2f (%s)'):format(dark, dark < 1.0 and 'dark' or 'lit'))
                lastNightSight = dark
            end

            local seen = false

            for ped, entry in pairs(observers) do
                local stale = (now - entry.seenAt) > timeout
                if not DoesEntityExist(ped) or (stale and IsPedDeadOrDying(ped, true)) then
                    clearBlip(ped)
                    observers[ped] = nil
                elseif IsPedDeadOrDying(ped, true) then
                    -- A dead officer is neither a pair of eyes nor a unit on the
                    -- map, but client.lua keeps refreshing them until the
                    -- dead-ped cleanup timer runs (45s by default), so the entry
                    -- will not time out on its own. Drop the blip now and leave
                    -- the entry to be pruned when the refreshes stop.
                    if entry.blip then
                        clearBlip(ped)
                        entry.blip = false
                    end
                else
                    local range = sightRange(c, ped, entry.kind, dark)
                    if stale then
                        -- No longer refreshed: client.lua has handed this
                        -- officer's unit to something other than the chase --
                        -- a foot chase, an arrest, a traffic stop, a retreat.
                        -- Off the map, but still a pair of eyes until dead or
                        -- gone. Dropping them made contact lapse ("lost
                        -- visual") with an officer standing beside the player
                        -- once every unit on scene was busy like that.
                        if entry.blip then
                            clearBlip(ped)
                            entry.blip = false
                        end
                    else
                        updateBlip(ped, entry, c, range)
                    end
                    -- No break once somebody sees: the loop still has to prune
                    -- and blip the rest, it just stops paying for their rays.
                    if not seen and canSee(ped, entry.kind, playerPed, playerCoords, range) then
                        seen = true
                    end
                end
            end

            if not seen and makingNoise(playerCoords) then
                seen = true
            end

            -- A tracked dispatch vehicle overrides line of sight entirely —
            -- see client/tracker.lua. Checked last since it's the priciest of
            -- the three (a model lookup plus a statebag read) and the other
            -- two already short-circuit most ticks.
            if not seen and FenixTracker and FenixTracker.playerInTrackedVehicle(playerPed) then
                seen = true
            end

            if seen then
                contact.lastKnown  = playerCoords
                contact.lastSeenAt = now
                contact.lastHeading = GetEntityHeading(playerPed)

                if not contact.active then
                    local firstEver = not contact.everSeen
                    contact.active = true
                    contact.everSeen = true
                    if firstEver then contact.firstContactAt = now end
                    contact.lostAt = 0
                    contact.gaveUp = false

                    if firstEver then
                        -- The opening radio call used to fire the instant the
                        -- wanted level went up, from ANY witness, not
                        -- necessarily a cop, which meant dispatch had the
                        -- player's outfit and vehicle before an officer had
                        -- ever actually seen them. It belongs here instead:
                        -- the first time a cop genuinely lays eyes on the
                        -- player, which is also the moment FenixPursuit.tells()
                        -- starts being able to return anything true (see its
                        -- own comment, every key reads false while
                        -- contact.outfitSig is nil).
                        FenixPursuit.callItIn(GetPlayerWantedLevel(PlayerId()))
                    else
                        -- Re-acquired, a later sighting after contact was lost.
                        -- Worth its own call; the first sighting just got one
                        -- above, from callItIn itself.
                        local where = streetAt(playerCoords)
                        local msg = ('Suspect re-acquired heading %s'):format(compassFor(contact.lastHeading))
                        if where then msg = msg .. ' on ' .. where end
                        dispatch(msg .. '.')
                        speak('SPOT_PLAYER')
                        dbg('contact regained')
                    end
                end
            elseif contact.active then
                -- Grace period. Line of sight breaks constantly in city driving
                -- — every corner, every truck, every overpass — so contact is
                -- only genuinely lost after it has stayed broken. Without this
                -- the pursuit would drop you at the first parked bus.
                if (now - contact.lastSeenAt) > (c.loseContactMs or 4000) then
                    contact.active = false
                    contact.lostAt = now

                    local where = contact.lastKnown and streetAt(contact.lastKnown)
                    local msg = ('Lost visual, last seen heading %s'):format(compassFor(contact.lastHeading))
                    if where then msg = msg .. ' on ' .. where end
                    dispatch(msg .. '. Units sweep the area.')
                    speak('LOST_TARGET')
                    dbg('contact lost')
                end
            elseif contact.lastKnown and not contact.gaveUp
                and (now - contact.lostAt) > (c.giveUpAfterMs or 45000) then
                -- Search called off: isSearching() drops to false (see its
                -- definition below) without touching lastKnown, everSeen, or
                -- the wanted level itself -- a full FenixPursuit.reset() only
                -- happens once the level decays to 0. Deliberately NOT
                -- clearing lastKnown: targetCoords() falls back to the
                -- original dispatch position once lastKnown is nil, which
                -- would send every unit back to where the call first came
                -- from right when they're supposed to be standing down. They
                -- keep sitting on the stale last-known point (already the
                -- existing idle behaviour once a search goes cold) instead.
                contact.gaveUp = true
                dispatch('No visual, no leads. Units resuming patrol.')
                dbg('search called off')
            end
        end

        Wait(interval)
    end
end)

-- Shots, sampled every frame -- see lastShotAt. Only while somebody is
-- registered to hear them, which is the only time makingNoise() asks.
CreateThread(function()
    while true do
        local c = cfg()
        if c.enabled ~= false and c.gunfireReveals ~= false and next(observers) ~= nil then
            if IsPedShooting(PlayerPedId()) then lastShotAt = GetGameTimer() end
            Wait(0)
        else
            Wait(500)
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for ped in pairs(observers) do clearBlip(ped) end
end)

-------------------------------------------------------------------------------
-- Exports (for vice_hud's search-radius circle overlay)
-------------------------------------------------------------------------------
-- Nothing here changes state -- these just expose the contact model read-only
-- so another resource can draw what it means without duplicating it.

exports('IsSearching', FenixPursuit.isSearching)
exports('HasContact', FenixPursuit.hasContact)
exports('HasGivenUp', FenixPursuit.hasGivenUp)
exports('SearchRadius', FenixPursuit.searchRadius)
exports('PursuitElapsedMs', FenixPursuit.pursuitElapsedMs)

-- { outfit, vehicle, voice } -- which parts of dispatch's description of the
-- player are still accurate right now. See FenixPursuit.tells() above; this
-- is what vice_hud's wanted-tells row polls instead of the placeholder
-- "all three, always" it shipped with.
exports('GetTells', FenixPursuit.tells)

-- Where the circle should be centred right now: the player's live position
-- while seen, the last known position while searching, nil otherwise.
exports('SearchCentre', function()
    if not FenixPursuit.isSearching() then return nil end
    local coords = FenixPursuit.targetCoords(GetEntityCoords(PlayerPedId()))
    return { x = coords.x, y = coords.y, z = coords.z }
end)

-- Static config a caller needs once, not every poll: the fixed radius a
-- search starts at (the "crime origin" ring) and the cap it grows to.
exports('SearchRadiusBounds', function()
    local c = cfg()
    return { start = c.searchRadiusStart or 40.0, max = c.searchRadiusMax or 180.0 }
end)
