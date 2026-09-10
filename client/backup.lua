--[[
    client/backup.lua

    Whether to call for backup, as opposed to how many stars you have.

    client.lua's maintainPoliceUnits() has always answered "how many units does
    THIS wanted level call for" from Config.maxUnitsPerLevel — a flat table, no
    memory of the fight itself. Config.Reinforcement layers a clock on top: the
    longer a pursuit runs, the more it escalates. Neither one ever looks at
    what is actually happening to the units already on scene. An officer going
    down and an officer never getting shot at both call in exactly the same
    number of extra cars, because nothing here has ever asked the question.

    This file asks it. Three things raise an incident score — an officer going
    down, an officer taking fire while still alive, a suspect who is visibly
    armed at a serious wanted level — and the score decays over time rather
    than resetting, so a unit that just took a loss stays "hot" for a while
    instead of the moment being forgotten the instant it passes. FenixBackup.
    bonusUnits() turns that score into extra units on top of what Reinforcement
    already adds, and a real incident earns its own forced radio call
    (FenixPursuit.announceBackupRequest) distinct from "suspect still evading".

    client.lua's own per-officer loops already walk every officer every cycle
    for tasking purposes — the report* functions below are called from there,
    not from a second scan of their own.
]]

FenixBackup = {}

local function cfg() return Config.Backup or {} end
local function dbg(msg) if cfg().debug then print('[FENIX-BACKUP] ' .. msg) end end

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

-- Running incident score per kind ('ground' | 'heli'), each entry a list of
-- { amount, at = gameTimer } so decay can be applied per-contribution rather
-- than to one aggregate number, which would decay contributions that haven't
-- even happened yet.
local incidents = { ground = {}, heli = {} }

local lastAnnounceAt = 0

-- pedNetID -> health last cycle, so reportTakingFire's caller (client.lua) can
-- tell "still alive but losing health" from "just spawned" without keeping its
-- own copy of the same bookkeeping.
local lastHealth = {}

-------------------------------------------------------------------------------
-- Scoring
-------------------------------------------------------------------------------

local function addIncident(kind, amount)
    if amount <= 0 then return end
    table.insert(incidents[kind], { amount = amount, at = GetGameTimer() })
end

--- Sum of every contribution to `kind` that hasn't fully decayed yet, pruning
--- the ones that have. Linear decay rather than a hard cutoff: a unit that
--- lost an officer 50 seconds ago is cooling off, not instantly forgotten.
local function currentScore(kind)
    local c = cfg()
    local decay = c.decayMs or 60000
    local now = GetGameTimer()
    local list = incidents[kind]
    local total = 0.0

    for i = #list, 1, -1 do
        local age = now - list[i].at
        if age >= decay then
            table.remove(list, i)
        else
            total = total + (list[i].amount * (1.0 - (age / decay)))
        end
    end

    return total
end

-------------------------------------------------------------------------------
-- Public API — reporting
-------------------------------------------------------------------------------

--- An officer has just died. Called once, the cycle death is first observed —
--- client.lua's per-officer loops already check IsPedDeadOrDying every cycle
--- for tasking, so this is a state comparison there, not a new scan here.
function FenixBackup.reportOfficerDown(pedNetID)
    if cfg().enabled == false then return end
    addIncident('ground', cfg().officerDownScore or 40)
    lastHealth[pedNetID] = nil
    dbg('officer down, ground score now ' .. ('%.0f'):format(currentScore('ground')))
end

--- An officer is still alive but has lost health since the last cycle —
--- taking fire, not yet a casualty. `health` is the officer's current
--- GetEntityHealth reading; the comparison against last cycle happens here so
--- callers don't need their own per-ped history table.
function FenixBackup.reportOfficerHealth(pedNetID, health)
    if cfg().enabled == false then return end
    local prev = lastHealth[pedNetID]
    lastHealth[pedNetID] = health

    if prev and health < prev then
        addIncident('ground', cfg().takingFireScore or 12)
        dbg(('officer %s taking fire (%d -> %d)'):format(pedNetID, prev, health))
    end
end

--- Clears the health baseline for an officer who left the roster (reboarded,
--- despawned, or is a fresh spawn) so their next reading isn't compared
--- against a stale number from a previous life.
function FenixBackup.clearOfficer(pedNetID)
    lastHealth[pedNetID] = nil
end

--- The suspect is visibly armed at a wanted level serious enough that it
--- matters. Cheap and idempotent to call every cycle: the score only grows
--- while the condition holds, same as taking fire.
function FenixBackup.reportSuspectArmed(wantedLevel)
    if cfg().enabled == false then return end
    if (wantedLevel or 0) < 3 then return end

    local playerPed = PlayerPedId()
    if IsPedArmed(playerPed, 7) then -- 7 = any weapon except unarmed/melee-fists
        addIncident('ground', cfg().suspectArmedScore or 8)
    end
end

-------------------------------------------------------------------------------
-- Public API — reading
-------------------------------------------------------------------------------

--- Extra units on top of Config.maxUnitsPerLevel + Config.Reinforcement's own
--- bonus, same shape as client.lua's reinforcementBonus(kind) so the two slot
--- into maintainPoliceUnits() side by side rather than one replacing the other.
--- @param kind string 'ground' | 'heli'
function FenixBackup.bonusUnits(kind)
    if cfg().enabled == false then return 0 end

    local c = cfg()
    local score = currentScore(kind)

    if kind == 'heli' then
        local per = c.scorePerHeliUnit or 40
        local cap = c.maxBonusHeliUnits or 1
        return math.min(cap, math.floor(score / per))
    end

    local per = c.scorePerGroundUnit or 20
    local cap = c.maxBonusGroundUnits or 3
    return math.min(cap, math.floor(score / per))
end

--- Fire the "shots fired, officer down" radio call once a real incident has
--- happened, rate limited so a burst of gunfire doesn't key the radio every
--- cycle — the score itself keeps accumulating underneath regardless.
--- Call this from the same place maintainPoliceUnits() reads bonusUnits(); it
--- decides on its own whether the moment is actually worth announcing.
function FenixBackup.maybeAnnounce()
    if cfg().enabled == false then return end
    if FenixBackup.bonusUnits('ground') <= 0 and FenixBackup.bonusUnits('heli') <= 0 then return end

    local now = GetGameTimer()
    if (now - lastAnnounceAt) < (cfg().announceCooldownMs or 20000) then return end
    lastAnnounceAt = now

    if FenixPursuit and FenixPursuit.announceBackupRequest then
        FenixPursuit.announceBackupRequest()
    end
end

--- Full reset. Called when the wanted level clears, so the next incident
--- starts from a clean slate rather than inheriting a decaying score from a
--- pursuit that's already over.
function FenixBackup.reset()
    incidents = { ground = {}, heli = {} }
    lastHealth = {}
    lastAnnounceAt = 0
end

RegisterCommand('fenixbackup', function()
    print(('[FENIX-BACKUP] ground score %.0f (+%d units), heli score %.0f (+%d units)')
        :format(currentScore('ground'), FenixBackup.bonusUnits('ground'),
                currentScore('heli'), FenixBackup.bonusUnits('heli')))
end, false)
