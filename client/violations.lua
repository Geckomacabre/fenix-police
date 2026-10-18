-------------------------------------------------------------------------------
-- Moving violations: no helmet, wheelie/stoppie, phone use.
--
-- See Config.Violations in config.lua for what this covers and why red
-- lights / stop signs / sidewalk driving / wrong-way driving are deliberately
-- not attempted.
--
-- Each check requires an ambient officer to actually be able to see the
-- player (this resource's IsWitnessed export, added in client/ambient.lua) --
-- same "the police only know what they can see" rule the pursuit system
-- already applies, just extended to these. A hit calls the global
-- SetWantedLevel() from client/client.lua, so dispatch/pursuit/the
-- roadside-citation flow all pick it up with no extra wiring.
-------------------------------------------------------------------------------

local MPS_TO_MPH = 2.236936
local cooldowns = {} -- violation kind -> GetGameTimer() it may fire again at

-- Called through this resource's own exports by its real name: with a
-- hard-coded 'fenix-police', every pcall below fails quietly (no violations
-- at all) on a server that renamed the folder.
local RESOURCE = GetCurrentResourceName()

-- Phone use is a road offence: not on a pedal cycle, a boat, an aircraft or
-- a train (vehicle classes 13, 14, 15, 16, 21).
local PHONE_EXEMPT_CLASSES = { [13] = true, [14] = true, [15] = true, [16] = true, [21] = true }

local function cfg() return Config.Violations or {} end

local function onCooldown(kind)
    local until_ = cooldowns[kind]
    return until_ ~= nil and GetGameTimer() < until_
end

local function startCooldown(kind, seconds)
    cooldowns[kind] = GetGameTimer() + ((seconds or 60) * 1000)
end

-- Same exemption rule ambient.lua's radar uses: don't cite a player who is
-- themselves on duty as police. Two sources, either sufficient.
local function playerIsOnDutyPolice()
    local ok, res = pcall(function() return exports[RESOURCE]:IsPlayerPoliceOfficer() end)
    if ok and res == true then return true end

    ok, res = pcall(function() return exports['night_ers']:getIsPlayerOnShift() end)
    if ok and res == true then return true end

    return false
end

local function isWitnessed(coords)
    local ok, res = pcall(function()
        return exports[RESOURCE]:IsWitnessed(coords.x, coords.y, coords.z, cfg().witnessRange or 35.0)
    end)
    return ok and res == true
end

--- Cite the player for `kind`: apply the wanted level and let the existing
--- pursuit/citation flow take it from there, same as a radar catch.
local function cite(kind, wantedLevel, message)
    startCooldown(kind, (cfg()[kind] or {}).cooldownSeconds or 60)

    -- SetWantedLevel never lowers and never adds. ApplyWantedLevel adds to
    -- whatever is already there, so one violation landing on top of another
    -- would push the player past the roadside-citation threshold
    -- (TicketSystem.maxWantedLevel) and into a full pursuit.
    if type(SetWantedLevel) == 'function' then
        SetWantedLevel(wantedLevel or 1)
    elseif type(ApplyWantedLevel) == 'function' then
        ApplyWantedLevel(wantedLevel or 1)
    end

    local ok = pcall(function()
        lib.notify({ type = 'error', title = 'Traffic Violation', description = message })
    end)
    if not ok then
        -- lib.notify is only guaranteed once ox_lib's init has run; a plain
        -- chat message is a harmless fallback, never a reason to skip the cite.
        TriggerEvent('chat:addMessage', { args = { 'Police', message } })
    end
end

-------------------------------------------------------------------------------
-- No helmet on a motorcycle
-------------------------------------------------------------------------------

local helmetMissingSince = nil
local helmetCheckedAt = 0

local function checkNoHelmet(ped, veh)
    local c = cfg().noHelmet
    if not c or not c.enabled then return false end
    if GetVehicleClass(veh) ~= 8 then return false end -- 8 = Motorcycles
    if GetPedInVehicleSeat(veh, -1) ~= ped then return false end
    if GetEntitySpeed(veh) * MPS_TO_MPH < (c.minSpeedMph or 5) then return false end

    -- IS_PED_WEARING_HELMET only knows the game's own bike helmet; one put on
    -- through a clothing menu sits in head-prop slot 0 and reads as bare-headed.
    -- Any head prop counts -- a missed citation beats a false one.
    if IsPedWearingHelmet(ped) or GetPedPropIndex(ped, 0) ~= -1 then
        helmetMissingSince = nil
        return false
    end

    -- Bare-headed for dwellMs running, as far as the officer can tell: the
    -- game's own helmet goes on with an animation a moment after setting off.
    -- A gap of more than a couple of ticks (out of sight, slowed down) starts
    -- the clock again.
    local now = GetGameTimer()
    if not helmetMissingSince or now - helmetCheckedAt > (cfg().tickMs or 750) * 2 then
        helmetMissingSince = now
    end
    helmetCheckedAt = now
    if now - helmetMissingSince < (c.dwellMs or 4000) then return false end
    helmetMissingSince = nil

    cite('noHelmet', c.wantedLevel, 'Operating a motorcycle without a helmet.')
    return true
end

-------------------------------------------------------------------------------
-- Wheelie / stoppie
-------------------------------------------------------------------------------

local function checkWheelie(ped, veh)
    local c = cfg().wheelie
    if not c or not c.enabled then return false end
    if GetVehicleClass(veh) ~= 8 then return false end
    if GetPedInVehicleSeat(veh, -1) ~= ped then return false end
    -- 129 = "doing wheelie" per FiveM's native docs. Covers stoppies too --
    -- GTA V doesn't expose a separate state for one vs. the other.
    if GetVehicleWheelieState(veh) ~= 129 then return false end

    cite('wheelie', c.wantedLevel, 'Reckless operation of a motorcycle (wheelie).')
    return true
end

-------------------------------------------------------------------------------
-- Phone use while driving
-------------------------------------------------------------------------------

local function checkPhoneUse(ped, veh)
    local c = cfg().phone
    if not c or not c.enabled then return false end
    if PHONE_EXEMPT_CLASSES[GetVehicleClass(veh)] then return false end
    if GetPedInVehicleSeat(veh, -1) ~= ped then return false end
    if GetEntitySpeed(veh) * MPS_TO_MPH < (c.minSpeedMph or 5) then return false end

    -- Reads the state bag lb-phone itself sets (see
    -- [phone]/lb-phone/client/custom/functions/entities.lua). No lb-phone
    -- export needed, and this is a silent no-op if lb-phone isn't running --
    -- the key is simply never set, so LocalPlayer.state.phoneOpen is nil.
    local ok, open = pcall(function() return LocalPlayer.state.phoneOpen end)
    if not (ok and open) then return false end

    cite('phone', c.wantedLevel, 'Using a mobile phone while driving.')
    return true
end

-------------------------------------------------------------------------------
-- Driver loop
-------------------------------------------------------------------------------

CreateThread(function()
    while true do
        Wait(cfg().tickMs or 750)

        local ped = PlayerPedId()
        if not IsPedInAnyVehicle(ped, false) then goto continue end

        local veh = GetVehiclePedIsIn(ped, false)
        if veh == 0 or not DoesEntityExist(veh) then goto continue end

        -- Already wanted: the police are on the player already, and a
        -- citation on top could only add stars.
        if GetPlayerWantedLevel(PlayerId()) > 0 then goto continue end

        do
            local coords = GetEntityCoords(veh)
            if not isWitnessed(coords) then goto continue end
            if playerIsOnDutyPolice() then goto continue end

            -- One citation per pass: two in the same tick would both land
            -- before either wanted level is applied.
            local cited = not onCooldown('noHelmet') and checkNoHelmet(ped, veh)
            if not cited and not onCooldown('wheelie') then cited = checkWheelie(ped, veh) end
            if not cited and not onCooldown('phone') then checkPhoneUse(ped, veh) end
        end

        ::continue::
    end
end)
