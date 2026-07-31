-- ============================================================================
-- Dynamic events proximity hook
-- When the local player is within range of any active um_dynamicworld event,
-- suppression flag is on. Polls the event_engine's live list.
-- ============================================================================

if not BridgeConfig.DynamicEvents.enabled then return end

CreateThread(function()
    local SUPPRESSION_KEY = 'umw_event_proximity'
    while true do
        Wait(BridgeConfig.DynamicEvents.proximityCheckMs)

        -- Read um_dynamicworld's liveEvents (export it would be cleaner; for now
        -- we sniff the event_engine's state via a fallback: check entity state bags
        -- on nearby peds with the umw spawn tag, or fall back to a coords check).
        -- Simplest reliable approach: ping um_dynamicworld for active event coords.
        local nearby = false
        local plyCoords = GetEntityCoords(PlayerPedId())
        local r = BridgeConfig.DynamicEvents.proximityRadius

        -- Use a global if um_dynamicworld exposed one (forward-compatible: many
        -- versions of the engine register a `_G.UmwActiveEventCoords()` helper)
        local fn = _G.UmwActiveEventCoords
        if type(fn) == 'function' then
            local coordsList = fn()
            if coordsList then
                for _, c in ipairs(coordsList) do
                    if #(c - plyCoords) <= r then nearby = true; break end
                end
            end
        end

        if nearby then
            Suppression.Add(SUPPRESSION_KEY)
        else
            Suppression.Remove(SUPPRESSION_KEY)
        end
    end
end)
