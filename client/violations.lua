-------------------------------------------------------------------------------
-- Moving violations: no helmet, wheelie/stoppie, phone use.
--
-- See Config.Violations in config.lua for what this covers and why red
-- lights / stop signs / sidewalk driving / wrong-way driving are deliberately
-- not attempted.
--
-- Each check requires an ambient officer to actually be able to see the
-- player (exports('fenix-police'):IsWitnessed, added in client/ambient.lua) --
-- same "the police only know what they can see" rule the pursuit system
-- already applies, just extended to these. A hit calls the global
-- ApplyWantedLevel() from client/client.lua, the same entry point radar
-- enforcement uses, so dispatch/pursuit/the roadside-citation flow all pick
-- it up with no extra wiring.
-------------------------------------------------------------------------------

local MPS_TO_MPH = 2.236936
local cooldowns = {} -- violation kind -> GetGameTimer() it may fire again at

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
    local ok, res = pcall(function() return exports['fenix-police']:IsPlayerPoliceOfficer() end)
    if ok and res == true then return true end

    ok, res = pcall(function() return exports['night_ers']:getIsPlayerOnShift() end)
    if ok and res == true then return true end

    return false
end

local function isWitnessed(coords)
    local ok, res = pcall(function()
        return exports['fenix-police']:IsWitnessed(coords.x, coords.y, coords.z, cfg().witnessRange or 35.0)
    end)
    return ok and res == true
end

--- Cite the player for `kind`: apply the wanted level and let the existing
--- pursuit/citation flow take it from there, same as a radar catch.
local function cite(kind, wantedLevel, message)
    startCooldown(kind, (cfg()[kind] or {}).cooldownSeconds or 60)

    if type(ApplyWantedLevel) == 'function' then
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

local function checkNoHelmet(ped, veh)
    local c = cfg().noHelmet
    if not c or not c.enabled then return end
    if GetVehicleClass(veh) ~= 8 then return end -- 8 = Motorcycles
    if GetPedInVehicleSeat(veh, -1) ~= ped then return end
    if GetEntitySpeed(veh) * MPS_TO_MPH < (c.minSpeedMph or 5) then return end
    if IsPedWearingHelmet(ped) then return end

    cite('noHelmet', c.wantedLevel, 'Operating a motorcycle without a helmet.')
end

-------------------------------------------------------------------------------
-- Wheelie / stoppie
-------------------------------------------------------------------------------

local function checkWheelie(ped, veh)
    local c = cfg().wheelie
    if not c or not c.enabled then return end
    if GetVehicleClass(veh) ~= 8 then return end
    if GetPedInVehicleSeat(veh, -1) ~= ped then return end
    -- 129 = "doing wheelie" per FiveM's native docs. Covers stoppies too --
    -- GTA V doesn't expose a separate state for one vs. the other.
    if GetVehicleWheelieState(veh) ~= 129 then return end

    cite('wheelie', c.wantedLevel, 'Reckless operation of a motorcycle (wheelie).')
end

-------------------------------------------------------------------------------
-- Phone use while driving
-------------------------------------------------------------------------------

local function checkPhoneUse(ped, veh)
    local c = cfg().phone
    if not c or not c.enabled then return end
    if GetPedInVehicleSeat(veh, -1) ~= ped then return end
    if GetEntitySpeed(veh) * MPS_TO_MPH < (c.minSpeedMph or 5) then return end

    -- Reads the state bag lb-phone itself sets (see
    -- [phone]/lb-phone/client/custom/functions/entities.lua). No lb-phone
    -- export needed, and this is a silent no-op if lb-phone isn't running --
    -- the key is simply never set, so LocalPlayer.state.phoneOpen is nil.
    local ok, open = pcall(function() return LocalPlayer.state.phoneOpen end)
    if not (ok and open) then return end

    cite('phone', c.wantedLevel, 'Using a mobile phone while driving.')
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

        do
            local coords = GetEntityCoords(veh)
            if not isWitnessed(coords) then goto continue end
            if playerIsOnDutyPolice() then goto continue end

            if not onCooldown('noHelmet') then checkNoHelmet(ped, veh) end
            if not onCooldown('wheelie') then checkWheelie(ped, veh) end
            if not onCooldown('phone') then checkPhoneUse(ped, veh) end
        end

        ::continue::
    end
end)
