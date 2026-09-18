-- [Upstate Mafia] Optional framework glue, server side.
--
-- Mirrors client/framework.lua: qb-core/qbx_core is used when running for the
-- online-police count and traffic-fine deduction, both of which need a real
-- job/money system to mean anything. Standalone, there is no such system, so
-- the police count is always 0 (AI response behaves as if no player police
-- exist -- the only sane default with no job system to check) and fines are
-- never actually charged (the ticket is still issued; see the
-- Config.TicketSystem.fine.allowUnpaid path in server/server.lua).
FenixFramework = {}

local core = nil

local function tryGetCore()
    for _, res in ipairs({ 'qbx_core', 'qb-core' }) do
        if GetResourceState(res) == 'started' then
            local ok, obj = pcall(function() return exports[res]:GetCoreObject() end)
            if ok and obj then return obj end
        end
    end
    return nil
end

CreateThread(function()
    core = tryGetCore()
end)

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == 'qb-core' or resourceName == 'qbx_core' then
        core = tryGetCore()
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == 'qb-core' or resourceName == 'qbx_core' then
        core = nil
    end
end)

function FenixFramework.HasFramework()
    return core ~= nil
end

--- Number of connected players holding one of Config.PoliceJobsToCheck,
--- respecting each entry's onDutyOnly flag. 0 with no framework loaded.
function FenixFramework.GetOnlinePoliceCount()
    if not (core and core.Functions and core.Functions.GetQBPlayers) then return 0 end

    local ok, players = pcall(function() return core.Functions.GetQBPlayers() end)
    if not ok or not players then return 0 end

    local polCount = 0
    for _, Player in pairs(players) do
        local job = Player and Player.PlayerData and Player.PlayerData.job
        if job then
            for _, entry in ipairs(Config.PoliceJobsToCheck) do
                if job.name == entry.jobName then
                    if entry.onDutyOnly then
                        if job.onduty then polCount = polCount + 1 end
                    else
                        polCount = polCount + 1
                    end
                end
            end
        end
    end
    return polCount
end

--- Attempts to deduct `amount` from `src`'s `account`. Returns true only if
--- it actually came out of the player's funds -- false with no framework
--- loaded, same as a framework call that itself reported failure.
function FenixFramework.RemoveMoney(src, account, amount, reason)
    if not (core and core.Functions and core.Functions.GetPlayer) then return false end

    local ok, Player = pcall(function() return core.Functions.GetPlayer(src) end)
    if not ok or not Player then return false end

    local ok2, result = pcall(function() return Player.Functions.RemoveMoney(account, amount, reason) end)
    return ok2 and result == true
end

--- How much `src` currently holds in `account`. 0 with no framework loaded.
function FenixFramework.GetHeldMoney(src, account)
    if not (core and core.Functions and core.Functions.GetPlayer) then return 0 end

    local ok, Player = pcall(function() return core.Functions.GetPlayer(src) end)
    if not ok or not Player then return 0 end

    return (Player.PlayerData.money and Player.PlayerData.money[account]) or 0
end
