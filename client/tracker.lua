--[[
    client/tracker.lua

    Every dispatch vehicle carries a GPS tracker by default — stealing one
    doesn't make you invisible, because whoever's monitoring the fleet
    already knows exactly where it is. client/pursuit.lua's contact thread
    checks FenixTracker.hasTracker() on whatever the player is driving and,
    if it's true, treats contact as unbroken regardless of actual line of
    sight — the same override gunfire already gets there.

    The only way out is removing it: an ox_target interaction, gated on
    holding the right tool and, by default, on nobody currently being able to
    see the player do it. Loaded before pursuit.lua (see fxmanifest.lua) so
    FenixTracker already exists by the time the contact thread's first tick
    runs.
]]

FenixTracker = {}

local function cfg() return Config.Tracker or {} end

-------------------------------------------------------------------------------
-- The model set
-------------------------------------------------------------------------------
-- Built the same way server/guard.lua builds its own allowlist — straight
-- from Config.vehiclesByRegion, so a model added there is automatically
-- tracked here too and nobody has to remember to list it twice. The server
-- validates independently off its own copy (FenixGuard.isAllowedVehicleModel)
-- rather than trusting this one; this is only what lets the client answer
-- "is this tracked" instantly, for the target option and the contact thread.

local trackedModels = {}

local function buildTrackedModels()
    trackedModels = {}
    for _, region in pairs(Config.vehiclesByRegion or {}) do
        for _, entry in ipairs(region) do
            if type(entry.model) == 'string' then
                trackedModels[GetHashKey(entry.model)] = true
            end
        end
    end
end

CreateThread(buildTrackedModels)

-------------------------------------------------------------------------------
-- Per-vehicle state
-------------------------------------------------------------------------------
-- A statebag, not a local table: it has to survive the vehicle changing
-- hands and be readable by whichever client's contact thread happens to be
-- checking whoever is currently driving it. Absence means "still has one" —
-- only an explicit server-set true means it's been pulled — so nothing has
-- to be pre-seeded for every vehicle that spawns.

--- Does this vehicle currently have a working tracker?
--- @param vehicle number vehicle entity handle
function FenixTracker.hasTracker(vehicle)
    if not cfg().enabled then return false end
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return false end
    if not trackedModels[GetEntityModel(vehicle)] then return false end

    return Entity(vehicle).state.trackerRemoved ~= true
end

--- Is the player themselves DRIVING a tracked vehicle right now? Passengers
--- don't make the car broadcast its position any less, but the question this
--- answers is "is the vehicle you're using to get away tracked" — so this
--- only looks at the driver's seat.
--- @param playerPed number
function FenixTracker.playerInTrackedVehicle(playerPed)
    local veh = GetVehiclePedIsIn(playerPed, false)
    if veh == 0 or GetPedInVehicleSeat(veh, -1) ~= playerPed then return false end
    return FenixTracker.hasTracker(veh)
end

-------------------------------------------------------------------------------
-- Removing one
-------------------------------------------------------------------------------

--- @return boolean ok
--- @return string? reason shown to the player when ok is false
local function canRemove(vehicle)
    local c = cfg()
    if not FenixTracker.hasTracker(vehicle) then return false, 'No tracker to remove.' end

    if c.removeTool and c.removeTool ~= '' then
        local ok, count = pcall(function() return exports.ox_inventory:Search('count', c.removeTool) end)
        if not ok or not count or count < 1 then
            return false, 'You need the right tool for this.'
        end
    end

    if c.blockWhileSeen ~= false and FenixPursuit and FenixPursuit.hasContact() then
        return false, "Can't do this with someone watching."
    end

    return true
end

local function removeTracker(vehicle)
    local ok, reason = canRemove(vehicle)
    if not ok then
        lib.notify({ type = 'error', description = reason })
        return
    end

    local netId = NetworkGetNetworkIdFromEntity(vehicle)

    local done = lib.progressCircle({
        duration = cfg().removeMs or 12000,
        label = 'Removing tracker...',
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, car = true, combat = true },
        anim = { dict = 'mini@repair', clip = 'fixing_a_ped' },
    })
    if not done then return end

    -- Re-checked after the animation: plenty of time for contact to be
    -- regained, the tool to leave the player's hands, or the vehicle itself
    -- to be gone by the time it finishes.
    ok, reason = canRemove(vehicle)
    if not ok then
        lib.notify({ type = 'error', description = reason })
        return
    end

    TriggerServerEvent('fenix-police:removeTracker', netId)
end

exports('RemoveTracker', removeTracker)
exports('HasTracker', FenixTracker.hasTracker)

-------------------------------------------------------------------------------
-- ox_target
-------------------------------------------------------------------------------

CreateThread(function()
    while GetResourceState('ox_target') ~= 'started' do Wait(500) end

    exports.ox_target:addGlobalVehicle({
        {
            name = 'fenix-police:removeTracker',
            icon = 'fas fa-satellite-dish',
            label = 'Remove GPS Tracker',
            distance = 2.0,
            canInteract = function(entity) return FenixTracker.hasTracker(entity) end,
            onSelect = function(data) removeTracker(data.entity) end,
        },
    })
end)
