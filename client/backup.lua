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

-- Running incident score, a list of { amount, at = gameTimer } so decay can be
-- applied per-contribution rather than to one aggregate number, which would
-- decay contributions that haven't even happened yet. One score for the whole
-- incident: how bad things are on the ground is also what decides whether a
-- helicopter is worth sending, so ground and heli bonuses read the same score
-- against their own thresholds.
local incidents = {}

local lastAnnounceAt = 0

-- When an officer last went down / last took damage. The radio call is about
-- those two things specifically -- an armed suspect raises the score but is
-- not "officer down" -- and only a NEW one since the last call is worth
-- keying the radio again for.
local lastOfficerDownAt = 0
local lastTakingFireAt = 0

-- pedNetID -> health last cycle, so reportTakingFire's caller (client.lua) can
-- tell "still alive but losing health" from "just spawned" without keeping its
-- own copy of the same bookkeeping.
local lastHealth = {}

-- pedNetID -> true once that officer's death has been scored. client.lua sees
-- a body every cycle until the dead-ped cleanup removes it (45s on the ground,
-- 120s in the air); scoring each sighting turned one death into +40 a second.
local downReported = {}

-- Last time reportSuspectArmed actually scored. It's called per unit per
-- cycle, so without this six units on scene scored the same drawn weapon six
-- times a second.
local lastArmedAt = 0

-------------------------------------------------------------------------------
-- Scoring
-------------------------------------------------------------------------------

local function addIncident(amount)
    if amount <= 0 then return end
    table.insert(incidents, { amount = amount, at = GetGameTimer() })
end

--- Sum of every contribution that hasn't fully decayed yet, pruning the ones
--- that have. Linear decay rather than a hard cutoff: a unit that lost an
--- officer 50 seconds ago is cooling off, not instantly forgotten.
local function currentScore()
    local c = cfg()
    local decay = c.decayMs or 60000
    local now = GetGameTimer()
    local list = incidents
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

--- An officer has just died. Safe to call every cycle the body is seen —
--- only the first report for an officer scores.
function FenixBackup.reportOfficerDown(pedNetID)
    if cfg().enabled == false then return end
    if pedNetID == nil or downReported[pedNetID] then return end
    downReported[pedNetID] = true

    addIncident(cfg().officerDownScore or 40)
    lastOfficerDownAt = GetGameTimer()
    lastHealth[pedNetID] = nil
    dbg('officer down, score now ' .. ('%.0f'):format(currentScore()))
end

--- An officer is still alive but has lost health since the last cycle —
--- taking fire, not yet a casualty. `health` is the officer's current
--- GetEntityHealth reading; the comparison against last cycle happens here so
--- callers don't need their own per-ped history table.
function FenixBackup.reportOfficerHealth(pedNetID, health)
    if cfg().enabled == false then return end
    if pedNetID == nil or type(health) ~= 'number' then return end
    local prev = lastHealth[pedNetID]
    lastHealth[pedNetID] = health

    if prev and health < prev then
        addIncident(cfg().takingFireScore or 12)
        lastTakingFireAt = GetGameTimer()
        dbg(('officer %s taking fire (%d -> %d)'):format(pedNetID, prev, health))
    end
end

--- Clears the health baseline for an officer who left the roster (reboarded,
--- despawned, or is a fresh spawn) so their next reading isn't compared
--- against a stale number from a previous life -- and so a later officer who
--- is handed the same net id can be reported down in their own right.
function FenixBackup.clearOfficer(pedNetID)
    if pedNetID == nil then return end
    lastHealth[pedNetID] = nil
    downReported[pedNetID] = nil
end

--- The suspect is visibly armed at a wanted level serious enough that it
--- matters. Cheap to call every cycle from anywhere: it scores at most once a
--- second however many units call it, and only while the condition holds.
function FenixBackup.reportSuspectArmed(wantedLevel)
    if cfg().enabled == false then return end
    if (wantedLevel or 0) < 3 then return end

    local now = GetGameTimer()
    if (now - lastArmedAt) < 1000 then return end

    -- 6 = explosives + firearms. Not melee: a drawn knife is not what calls in
    -- extra units.
    if IsPedArmed(PlayerPedId(), 6) then
        lastArmedAt = now
        addIncident(cfg().suspectArmedScore or 8)
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
    local score = currentScore()

    if kind == 'heli' then
        local per = c.scorePerHeliUnit or 40
        local cap = c.maxBonusHeliUnits or 1
        return math.min(cap, math.floor(score / per))
    end

    local per = c.scorePerGroundUnit or 20
    local cap = c.maxBonusGroundUnits or 3
    return math.min(cap, math.floor(score / per))
end

--- Fire the backup radio call once a real incident has happened, rate limited
--- so a burst of gunfire doesn't key the radio every cycle — the score itself
--- keeps accumulating underneath regardless.
--- Call this from the same place maintainPoliceUnits() reads bonusUnits(); it
--- decides on its own whether the moment is actually worth announcing.
---
--- Only an officer going down or taking damage is announced, and only one that
--- happened since the last call: an armed suspect can push the score over a
--- threshold on its own, and announcing "officer down" for that -- again every
--- cooldown, for as long as the score stayed up -- had dispatch reporting
--- casualties nobody had taken.
function FenixBackup.maybeAnnounce()
    if cfg().enabled == false then return end
    if FenixBackup.bonusUnits('ground') <= 0 and FenixBackup.bonusUnits('heli') <= 0 then return end

    local lastIncidentAt = math.max(lastOfficerDownAt, lastTakingFireAt)
    if lastIncidentAt == 0 or lastIncidentAt <= lastAnnounceAt then return end

    local now = GetGameTimer()
    if (now - lastIncidentAt) >= (cfg().decayMs or 60000) then return end
    if lastAnnounceAt ~= 0 and (now - lastAnnounceAt) < (cfg().announceCooldownMs or 20000) then return end
    lastAnnounceAt = now

    if FenixPursuit and FenixPursuit.announceBackupRequest then
        FenixPursuit.announceBackupRequest((lastOfficerDownAt >= lastTakingFireAt) and 'officerDown' or 'takingFire')
    end
end

--- Full reset. Called when the wanted level clears, so the next incident
--- starts from a clean slate rather than inheriting a decaying score from a
--- pursuit that's already over.
function FenixBackup.reset()
    incidents = {}
    lastHealth = {}
    downReported = {}
    lastAnnounceAt = 0
    lastOfficerDownAt = 0
    lastTakingFireAt = 0
    lastArmedAt = 0
end

RegisterCommand('fenixbackup', function()
    print(('[FENIX-BACKUP] score %.0f (+%d ground, +%d heli units)')
        :format(currentScore(), FenixBackup.bonusUnits('ground'), FenixBackup.bonusUnits('heli')))
end, false)
