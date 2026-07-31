-- ============================================================================
-- ERS event hooks
-- Track active ERS callout state, suppress fenix while one is accepted,
-- spawn additional NPC backup for specified callouts (Officer Down, Active Shooter).
-- ============================================================================

ERSState = {
    currentCallout = nil,  -- calloutData while active
    backupEntities = {},   -- entities spawned for backup
}

-- ---- Helper: extract callout ID/name from event data (defensive) ----
local function getCalloutId(data)
    if type(data) ~= 'table' then return nil end
    return data.Id or data.id or data.calloutId or data.name or data.Name
end

local function getCalloutCoords(data)
    if type(data) ~= 'table' then return nil end
    if data.Coordinates then return data.Coordinates end
    if data.coords then return data.coords end
    if type(data.x) == 'number' then return vector3(data.x, data.y, data.z) end
    return nil
end

-- ---- Backup spawn ----
local function spawnBackup(calloutId, coords)
    local backupCfg = BridgeConfig.ERS.backupCallouts[calloutId]
    if not backupCfg then return end
    if not coords then return end

    local vehHash = GetHashKey(backupCfg.vehicleModel or 'police')
    local pedHash = GetHashKey('s_m_y_cop_01')

    RequestModel(vehHash); RequestModel(pedHash)
    local t = GetGameTimer() + 4000
    while (not HasModelLoaded(vehHash) or not HasModelLoaded(pedHash)) and GetGameTimer() < t do Wait(20) end
    if not HasModelLoaded(vehHash) or not HasModelLoaded(pedHash) then
        if BridgeConfig.Debug.log then print('[fenix-bridge] backup model failed to load') end
        return
    end

    local r = BridgeConfig.ERS.backupSpawnRadius
    for i = 1, (backupCfg.units or 2) do
        local angle = math.rad(math.random(360))
        local x = coords.x + math.cos(angle) * r
        local y = coords.y + math.sin(angle) * r
        local _, z = GetGroundZFor_3dCoord(x, y, coords.z + 50.0, false)
        z = z and (z + 1.0) or coords.z

        local veh = CreateVehicle(vehHash, x, y, z, math.random(360), true, false)
        if veh and DoesEntityExist(veh) then
            SetVehicleSiren(veh, true)
            SetVehicleEngineOn(veh, true, true, false)

            -- Create cop ON FOOT first so weapons are given before seating.
            -- GiveWeaponToPed is unreliable when the ped is already seated.
            local cop = CreatePed(4, pedHash, x, y, z, math.random(360), true, false)
            local pedWait = 0
            while (not DoesEntityExist(cop) or cop == 0) and pedWait < 30 do
                Wait(10); pedWait = pedWait + 1
            end
            if cop and DoesEntityExist(cop) then
                SetEntityAsMissionEntity(cop, true, true)
                SetPedAsCop(cop, true)
                SetPedAccuracy(cop, 35)
                SetPedCombatAttributes(cop, 46, true)
                -- Arm while on foot (reliable)
                GiveWeaponToPed(cop, GetHashKey('weapon_pistol'), 100, false, true)
                SetCurrentPedWeapon(cop, GetHashKey('weapon_pistol'), true)
                -- Now seat into driver seat
                SetPedIntoVehicle(cop, veh, -1)
                Wait(100)
                -- Drive to callout
                TaskVehicleDriveToCoordLongrange(cop, veh, coords.x, coords.y, coords.z, 25.0, 786603, 5.0)
                ERSState.backupEntities[#ERSState.backupEntities+1] = cop
            end
            ERSState.backupEntities[#ERSState.backupEntities+1] = veh
        end
    end

    SetModelAsNoLongerNeeded(vehHash)
    SetModelAsNoLongerNeeded(pedHash)
end

local function cleanupBackup()
    for _, ent in ipairs(ERSState.backupEntities) do
        if DoesEntityExist(ent) then
            SetEntityAsMissionEntity(ent, true, true)
            DeleteEntity(ent)
        end
    end
    ERSState.backupEntities = {}
end

-- ---- Event handler registration ----
local function ev(name) return BridgeConfig.ERS.eventPrefix .. name end

if BridgeConfig.ERS.enabled then
    AddEventHandler(ev('OnAcceptedCalloutOffer'), function(calloutData)
        if not calloutData then return end
        ERSState.currentCallout = calloutData
        if BridgeConfig.ERS.suppressOnAccept then
            Suppression.Add('ers_callout')
        end
        if BridgeConfig.Debug.log then
            print(('[fenix-bridge] ERS accepted: %s'):format(tostring(getCalloutId(calloutData))))
        end
    end)

    AddEventHandler(ev('OnArrivedAtCallout'), function(calloutData)
        if not calloutData then return end
        ERSState.currentCallout = calloutData
        local id = getCalloutId(calloutData)
        local coords = getCalloutCoords(calloutData)
        if id and coords then spawnBackup(id, coords) end
    end)

    AddEventHandler(ev('OnEndedACallout'), function()
        ERSState.currentCallout = nil
        Suppression.Remove('ers_callout')
        cleanupBackup()
    end)

    AddEventHandler(ev('OnCalloutCompletedSuccesfully'), function()
        ERSState.currentCallout = nil
        Suppression.Remove('ers_callout')
        cleanupBackup()
    end)
end

-- Cleanup on resource stop
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    cleanupBackup()
end)

--- Public API for other modules
function ERSState.HasActiveCallout()
    return ERSState.currentCallout ~= nil
end
