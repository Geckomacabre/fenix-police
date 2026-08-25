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
    everSeen     = false,      -- suppresses "lost the suspect" before first sight
    vehicleDesc  = nil,        -- cached description of the car they were last in
}

-- Rate limiting for the radio, so a player weaving through traffic doesn't
-- generate a call every time a wall passes between them and a cruiser.
local lastDispatchAt = 0
local lastSpeechAt = 0

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
    elseif QBCore and QBCore.Functions and QBCore.Functions.Notify then
        QBCore.Functions.Notify(text, 'police', c.dispatchDuration or 6000)
    else
        print('[DISPATCH] ' .. text)
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

--- Can this officer see the player right now?
---
--- Three gates, cheapest first. Distance rules out most of the set without a
--- trace; the field-of-view test stops an officer facing the other way from
--- "seeing" through the back of their head; only survivors pay for the ray.
---
--- Air units skip the FOV test on purpose — a helicopter carries a spotter whose
--- whole job is looking down, and giving them a forward cone makes them useless
--- at the one thing they exist for.
local function canSee(ped, kind, playerPed, playerCoords)
    local c = cfg()

    local pedCoords = GetEntityCoords(ped)
    local dist = #(pedCoords - playerCoords)

    local range = (kind == 'ground') and (c.sightRange or 90.0) or (c.airSightRange or 250.0)
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

    -- 17 = map + vehicles + objects. The player's own vehicle is ignored by the
    -- native when the target is its driver, which is what we want.
    return HasEntityClearLosToEntity(ped, playerPed, 17)
end

--- Noise reveals. Firing a weapon inside earshot of a unit hands your position
--- back no matter how good the cover is, which is both realistic and the reason
--- shooting your way out of a hiding place should not work.
local function makingNoise(playerPed, playerCoords)
    local c = cfg()
    if c.gunfireReveals == false then return false end
    if not IsPedShooting(playerPed) then return false end

    local range = c.gunfireRange or 120.0
    for ped in pairs(observers) do
        if DoesEntityExist(ped) and #(GetEntityCoords(ped) - playerCoords) < range then
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
local function updateBlip(ped, entry, c)
    local want = wantsBlip(ped, c)
    if want == entry.blip then return end

    if want then
        if c.blipColour then
            SetPedHasAiBlipWithColor(ped, true, c.blipColour)
        else
            SetPedHasAiBlip(ped, true)
        end
        SetPedAiBlipHasCone(ped, c.blipCones ~= false)
        SetPedAiBlipNoticeRange(ped, (entry.kind == 'ground')
            and (c.sightRange or 90.0) or (c.airSightRange or 250.0))
    else
        SetPedHasAiBlip(ped, false)
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
--- Called from client.lua's chase loops every cycle. Entries not refreshed
--- inside `observerTimeout` are dropped, so a deleted officer removes itself.
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
function FenixPursuit.isSearching()
    if cfg().enabled == false then return false end
    return (not contact.active) and contact.everSeen and contact.lastKnown ~= nil
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
    return playerCoords, false
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

--- Should this unit's siren be running? Units go quiet on a search: a siren is
--- how you tell a street you are coming, and a unit that has lost the suspect
--- wants to hear, not announce. Lights stay on throughout.
function FenixPursuit.sirenWanted()
    if cfg().quietSearch == false then return true end
    return not FenixPursuit.isSearching()
end

--- Full reset. Called when the wanted level clears, so the next pursuit starts
--- from no knowledge rather than inheriting the last one's last known position.
function FenixPursuit.reset()
    for ped in pairs(observers) do clearBlip(ped) end
    observers = {}

    contact.active      = false
    contact.lastKnown   = nil
    contact.lastHeading = 0.0
    contact.lastSeenAt  = 0
    contact.lostAt      = 0
    contact.everSeen    = false
    contact.vehicleDesc = nil

    lastDispatchAt = 0
    lastSpeechAt = 0
end

--- Opening radio call, made once when a pursuit starts. Separate from the
--- contact machine because it describes the CRIME, not the sighting.
function FenixPursuit.callItIn(wantedLevel)
    if cfg().enabled == false then return end

    local playerPed = PlayerPedId()
    local coords = GetEntityCoords(playerPed)
    local vehicle = GetVehiclePedIsIn(playerPed, false)

    contact.vehicleDesc = describeVehicle(vehicle)

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

        if c.enabled == false or next(observers) == nil then
            -- Nothing is chasing you: idle at a slower tick rather than paying
            -- for a perception pass over an empty set several times a second.
            interval = 500
        else
            local playerPed = PlayerPedId()
            local playerCoords = GetEntityCoords(playerPed)
            local now = GetGameTimer()
            local timeout = c.observerTimeout or 4000

            local seen = false

            for ped, entry in pairs(observers) do
                if (now - entry.seenAt) > timeout or not DoesEntityExist(ped) then
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
                    updateBlip(ped, entry, c)
                    if canSee(ped, entry.kind, playerPed, playerCoords) then
                        seen = true
                        -- No break: the loop still has to prune the rest, and
                        -- the set is at most a dozen peds.
                    end
                end
            end

            if not seen and makingNoise(playerPed, playerCoords) then
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
                    contact.lostAt = 0

                    if not firstEver then
                        -- Re-acquired. Worth a call; the first sighting of a
                        -- pursuit is not, because callItIn already covered it.
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
            end
        end

        Wait(interval)
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for ped in pairs(observers) do clearBlip(ped) end
end)
