fx_version "cerulean"
resource_manifest_version "05cfa83c-a124-4cfa-a768-c24a5811d8f9"
game "gta5"
author "Fenix, fork by Upstate Mafia"
description "AI police dispatch and wanted levels, with ambient enforcement"
version "2.7.0"

shared_scripts {
    -- Needed by client/tracker.lua (lib.notify, lib.progressCircle). Nothing
    -- else in this resource used ox_lib before that file existed.
    '@ox_lib/init.lua',

    'config.lua',
    'data/ambient_points.lua',

    -- Generic per-unit state machine (FenixFSM). No natives, no networking --
    -- just state + timing, so both sides can load it. Not yet used by the
    -- existing officer AI (see the file's own header comment for why); new
    -- unit types (EMS, fire) are built on it from the start.
    'shared/unit_fsm.lua',

    -- Per-server overrides, loaded last so they win over everything above.
    -- The directory is gitignored and absent from a clean checkout — a glob that
    -- matches nothing is a no-op, which is the whole reason this is a directory
    -- and not a named file. See config.local.example.lua.
    'config.local/*.lua'
}

dependencies {
    'ox_lib'
}

client_scripts {
    -- Applies ped combat/task natives on the server's behalf -- those natives
    -- don't exist server-side. Self-contained, no ordering requirement.
    'client/combat_bridge.lua',

    -- Shared road/lane/no-go-zone helper. Loaded first: both scripts below call
    -- into the FenixRoads global it defines.
    'client/roads.lua',

    -- Agency livery + installed-model fallback for add-on cruisers. Loaded
    -- before every spawner (tactics/client/ambient) that calls FenixLivery.
    'client/livery.lua',

    -- GPS tracker model. Loaded before pursuit.lua, whose contact thread
    -- calls into the FenixTracker global this defines.
    'client/tracker.lua',

    -- Pursuit contact model (what the police can actually see), AI blips and
    -- radio traffic. Also loaded before client.lua, which drives it.
    'client/pursuit.lua',

    -- Roadblocks and spike strips. Reads both of the modules above.
    'client/tactics.lua',

    -- Event-driven backup escalation, officer morale/retreat, and jurisdiction
    -- handoff. Each is self-contained (own cfg()/dbg(), own driver thread) and
    -- loaded before client.lua, which calls into all three FenixBackup /
    -- FenixMorale / FenixJurisdiction globals from its per-officer loops.
    'client/backup.lua',
    'client/morale.lua',
    'client/jurisdiction.lua',

    'client/client.lua',
    'client/ambient.lua',

    -- Civilian gunfire witnessing -> FenixDispatch incident creation. Reads
    -- Config.Dispatch/Config.Witness only; no dependency on the files above,
    -- placed here purely to keep all the "opt-in incident system" files
    -- together.
    'client/witness.lua',

    -- Crash detection, same "opt-in incident system" grouping.
    'client/collision.lua',

    -- EMS ground response. Reads FenixRoads (loaded above) and FenixFSM
    -- (shared/unit_fsm.lua, shared_scripts).
    'client/ems.lua',

    -- Fire witnessing + ground response, same shape as the EMS pair above.
    'client/firewatch.lua',
    'client/fire.lua',

    -- Police investigation response (no-suspect calls), same shape again.
    'client/investigate.lua',

    -- Moving violations (no helmet, wheelie, phone use). Loaded last: reads
    -- ApplyWantedLevel from client.lua and calls
    -- exports('fenix-police'):IsWitnessed, added in ambient.lua.
    'client/violations.lua'
}

server_scripts {
    -- Entity ownership, the model allowlist and rate limiting. Loaded first:
    -- server.lua's net event handlers call into the FenixGuard global it
    -- defines, and a handler that ran before it existed would be an open door.
    'server/guard.lua',

    -- Incident registry and dispatch reasoning (FenixIncident/FenixDispatch).
    -- Loaded before server.lua, whose fenix:server:trigger handler calls
    -- into FenixDispatch when Config.Dispatch.enabled is true.
    'server/incident.lua',
    'server/dispatch.lua',
    'server/unit_registry.lua',
    'server/ems.lua',
    'server/fire.lua',
    'server/investigate.lua',

    'server/server.lua',

    -- GPS tracker removal. Reads FenixGuard.isAllowedVehicleModel, so it must
    -- load after guard.lua.
    'server/tracker.lua'
}
