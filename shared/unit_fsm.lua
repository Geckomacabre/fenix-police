-- Generic finite-state-machine helper for first-responder units.
--
-- fenix-police already has three informal state patterns (a phase string on
-- an ambient scene table, presence-in-a-table as a boolean flag, and a flat
-- per-ped status string in client.lua's officerTasks). This formalizes that
-- pattern into one reusable object rather than inventing a fourth. It is
-- intentionally dumb: no natives, no networking, just state + timing + a
-- transition log, so both client and server can load it (shared_scripts).
--
-- Existing systems (client.lua's officerTasks, ambient.lua's scene.phase)
-- are NOT migrated onto this -- they work, and this expansion follows the
-- project's own rule against replacing working systems for architectural
-- purity alone. New unit types (EMS, fire) are built on this from the start.

FenixFSM = {}
FenixFSM.__index = FenixFSM

-- states: array of valid state name strings.
-- initial: starting state, must be a member of states.
function FenixFSM.new(states, initial)
    local allowed = {}
    for _, s in ipairs(states) do
        allowed[s] = true
    end
    assert(allowed[initial], ('FenixFSM.new: initial state "%s" is not in the states list'):format(tostring(initial)))

    return setmetatable({
        allowed = allowed,
        state = initial,
        previousState = nil,
        enteredAt = GetGameTimer(),
        data = {},
    }, FenixFSM)
end

-- Moves to newState unless it's the same state (no-op transitions don't
-- reset enteredAt, which callers rely on for "how long have we been here").
-- extra is an optional table merged into self.data on transition.
function FenixFSM:transition(newState, extra)
    if not self.allowed[newState] then
        error(('FenixFSM: "%s" is not a valid state for this machine'):format(tostring(newState)), 2)
    end

    if newState == self.state then
        return false
    end

    self.previousState = self.state
    self.state = newState
    self.enteredAt = GetGameTimer()

    if extra then
        for k, v in pairs(extra) do
            self.data[k] = v
        end
    end

    return true
end

function FenixFSM:is(state)
    return self.state == state
end

function FenixFSM:timeInState()
    return GetGameTimer() - self.enteredAt
end

function FenixFSM:msSince(field)
    local t = self.data[field]
    if not t then return nil end
    return GetGameTimer() - t
end
