-- ============================================================================
-- Suppression core
-- Counter-based: multiple sources can request suppression simultaneously.
-- While count > 0, wanted level is force-cleared each tick, which prevents
-- fenix-police from spawning AI cops (its dispatch keys off wanted level).
-- ============================================================================

Suppression = {}

local count    = 0
local sources  = {}  -- key -> true (for debugging)
local active   = false

--- Bump the counter. Pass a unique key for tracking.
function Suppression.Add(key)
    if sources[key] then return end
    sources[key] = true
    count = count + 1
    if BridgeConfig.Debug.log then
        print(('[fenix-bridge] suppression+ %s (count=%d)'):format(key, count))
    end
end

--- Decrement the counter for a specific key.
function Suppression.Remove(key)
    if not sources[key] then return end
    sources[key] = nil
    count = count - 1
    if count < 0 then count = 0 end
    if BridgeConfig.Debug.log then
        print(('[fenix-bridge] suppression- %s (count=%d)'):format(key, count))
    end
end

--- Are we currently suppressing?
function Suppression.IsActive()
    return count > 0
end

--- Get current source list.
function Suppression.GetSources()
    local s = {}
    for k in pairs(sources) do s[#s+1] = k end
    return s
end

-- Suppression tick: while active, hammer wanted level to 0
CreateThread(function()
    while true do
        if Suppression.IsActive() then
            local plyId = PlayerId()
            if GetPlayerWantedLevel(plyId) > 0 then
                SetPlayerWantedLevel(plyId, 0, false)
                SetPlayerWantedLevelNow(plyId, false)
                if BridgeConfig.Suppression.clearCenter then
                    ClearPlayerWantedLevel(plyId)
                end
            end
            Wait(BridgeConfig.Suppression.tickMs)
        else
            Wait(1000)  -- idle check
        end
    end
end)

-- Optional on-screen debug
CreateThread(function()
    while true do
        if BridgeConfig.Debug.hud then
            local lines = { ('Suppression: %s'):format(Suppression.IsActive() and 'ON' or 'off') }
            for _, src in ipairs(Suppression.GetSources()) do
                lines[#lines+1] = '  - ' .. src
            end
            SetTextScale(0.35, 0.35)
            SetTextFont(4)
            SetTextColour(255, 200, 50, 220)
            BeginTextCommandDisplayText('STRING')
            AddTextComponentSubstringPlayerName(table.concat(lines, '\n'))
            EndTextCommandDisplayText(0.85, 0.40)
            Wait(0)
        else
            Wait(1000)
        end
    end
end)
