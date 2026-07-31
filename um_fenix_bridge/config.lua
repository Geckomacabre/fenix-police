-- ============================================================================
-- um_fenix_bridge config
-- ============================================================================

BridgeConfig = {}

-- ------------------------------------------------------------
-- Suppression: while active, wanted level is force-cleared
-- (which prevents fenix-police from dispatching AI cops)
-- ------------------------------------------------------------
BridgeConfig.Suppression = {
    -- Tick rate while suppressing (ms). 250ms = 4x/sec, fast enough to beat fenix's 1s scan
    tickMs = 250,
    -- Set this true to also force-clear the wanted level center (recommended)
    clearCenter = true,
}

-- ------------------------------------------------------------
-- ERS callout integration
-- ------------------------------------------------------------
BridgeConfig.ERS = {
    enabled = true,
    -- Suppress fenix while you have an accepted ERS callout
    suppressOnAccept = true,
    -- Callout IDs that should also spawn additional NPC backup cops
    -- (the names must match Config.Callouts["X"] keys in night_ers plugins)
    backupCallouts = {
        ['officer_down']     = { units = 3, vehicleModel = 'police2' },
        ['active_shooter']   = { units = 4, vehicleModel = 'police2' },
        ['rifle_shots_fired']= { units = 2, vehicleModel = 'police3' },
    },
    -- Spawn radius around callout location
    backupSpawnRadius = 50.0,
    -- If ERS uses namespaced events, set the prefix here. Empty = bare names.
    -- Try 'nights:' or 'ers:' if bare names don't fire.
    eventPrefix = '',
}

-- ------------------------------------------------------------
-- Dynamic events integration (um_dynamicworld)
-- DISABLED by default - was over-suppressing wanted level when events
-- spawned near the player, so cops never responded to player crimes.
-- Re-enable if you want player crime near event NPCs to be ignored.
-- ------------------------------------------------------------
BridgeConfig.DynamicEvents = {
    enabled = false,
    proximityRadius = 60.0,
    proximityCheckMs = 1000,
}

-- ------------------------------------------------------------
-- Witness -> fenix integration
-- ------------------------------------------------------------
BridgeConfig.Witness = {
    enabled = false,
    -- When a non-intimidated witness calls, bump wanted level by this much
    wantedBump = 1,
    -- Max wanted level a single witness call can produce
    maxWantedFromWitness = 3,
    -- If a callout is already active for this player, witness call is ignored
    -- (don't pile on while they're already responding to something)
    ignoreDuringCallout = true,
}

-- ------------------------------------------------------------
-- Crime -> AI police dispatch
--
-- Robbery scripts alert player cops and stop there, so on a quiet server a bank
-- job draws no response at all. This watches those alerts and puts a wanted
-- level on whoever caused them; fenix-police sees the stars and rolls units.
--
-- Stars are set with fenix's SetWantedLevel (takes the higher of current and
-- new), never ApplyWantedLevel (additive), so two hooks firing for the same
-- crime can't stack it to 5.
-- ------------------------------------------------------------
BridgeConfig.Crime = {
    enabled = true,

    -- Wanted stars per crime tag. 0 or nil = no AI response for that crime.
    stars = {
        store_robbery = 2,   -- loaf_storerobbery
        bank_robbery  = 4,   -- loaf_bankrobbery
        jewelry_heist = 3,   -- qbx_jewelery / jewelery_heist
        truck_robbery = 3,   -- um_truckrobbery
        house_robbery = 2,   -- um_HouseRobberys
        em_mission    = 2,   -- em_toolkit missions listed in emMissions below
        police_alert  = 1,   -- anything else that fires police:server:policeAlert
        dispatch      = 1,   -- anything else that fires a ps-dispatch alert
    },

    -- When a hook tells us where a crime happened but not who did it, everyone
    -- within this many metres of the scene is treated as involved. Matches how
    -- fenix-police's own robbery hook picks targets, just less tight than its
    -- hardcoded 10m so getaway drivers waiting outside are included.
    radius = 60.0,

    -- Same player, same crime tag, inside this window = ignored. Bank jobs fire
    -- an alert per door, per hack and per loot bag; without this every one of
    -- them would re-apply the stars and reset the evasion timer.
    cooldownMs = 30000,

    -- police:server:policeAlert has no handler on this server (no qb-policejob),
    -- so it is a free catch-all: qbx_jewelery, qbx_vehiclekeys and
    -- jewelery_heist all fire it. Set false to only respond to the named tags.
    catchAllPoliceAlert = true,

    -- ps-dispatch alerts are already covered by the per-resource hooks below.
    -- Turning this on responds to every other dispatch call too, which will
    -- include things you may not want AI police for (EMS calls, minor alerts).
    catchAllDispatch = false,

    -- em_toolkit missions that should bring police. Every mission, heist finale
    -- and game-mode run goes through one event, so this is opt-in per id —
    -- otherwise the deliveries and errands sharing that event would summon cops
    -- too. `true` uses the em_mission tier above, a number overrides it.
    --
    -- Missions built with the `set_wanted` objective already summon fenix on
    -- their own and don't need listing here.
    emMissions = {
        -- ['my_robbery_mission'] = true,
        -- ['the_big_score']      = 4,
    },
}

-- ------------------------------------------------------------
-- Debug
-- ------------------------------------------------------------
BridgeConfig.Debug = {
    log = false,
    -- Draw on-screen text showing suppression state
    hud = false,
}
