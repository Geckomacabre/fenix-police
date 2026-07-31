-- ============================================================================
-- Witness -> fenix wanted-level integration
-- When a witness's call timer expires (non-intimidated), bump wanted level
-- by the configured amount. fenix-police then sees the wanted level and
-- handles dispatch normally.
-- ============================================================================

if not BridgeConfig.Witness.enabled then return end

AddEventHandler('umw:witnessCalled', function(witnessCoords, gunshotCoords)
    -- Don't pile on if player is already responding to a callout
    if BridgeConfig.Witness.ignoreDuringCallout and ERSState.HasActiveCallout() then
        if BridgeConfig.Debug.log then
            print('[fenix-bridge] witness ignored - active callout')
        end
        return
    end

    -- Also skip if suppression is currently active for some other reason
    -- (e.g., player is at a um_dynamicworld event scene)
    if Suppression.IsActive() then
        if BridgeConfig.Debug.log then
            print('[fenix-bridge] witness ignored - suppression active')
        end
        return
    end

    local plyId = PlayerId()
    local current = GetPlayerWantedLevel(plyId)
    local cap = math.min(BridgeConfig.Witness.maxWantedFromWitness, 5)
    local target = math.min(cap, current + BridgeConfig.Witness.wantedBump)

    if target > current then
        SetPlayerWantedLevel(plyId, target, false)
        SetPlayerWantedLevelNow(plyId, false)
        if BridgeConfig.Debug.log then
            print(('[fenix-bridge] witness called - wanted %d -> %d'):format(current, target))
        end
    end
end)
