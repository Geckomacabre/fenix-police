fx_version "cerulean"
resource_manifest_version "05cfa83c-a124-4cfa-a768-c24a5811d8f9"
game "gta5"
author "Fenix, fork by Upstate Mafia"
description "AI police dispatch and wanted levels, with ambient enforcement"
version "2.6.0"

shared_scripts {
    -- Needed by client/tracker.lua (lib.notify, lib.progressCircle). Nothing
    -- else in this resource used ox_lib before that file existed.
    '@ox_lib/init.lua',

    'config.lua',
    'data/ambient_points.lua',

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

    -- GPS tracker model. Loaded before pursuit.lua, whose contact thread
    -- calls into the FenixTracker global this defines.
    'client/tracker.lua',

    -- Pursuit contact model (what the police can actually see), AI blips and
    -- radio traffic. Also loaded before client.lua, which drives it.
    'client/pursuit.lua',

    -- Roadblocks and spike strips. Reads both of the modules above.
    'client/tactics.lua',

    'client/client.lua',
    'client/ambient.lua'
}

server_scripts {
    -- Entity ownership, the model allowlist and rate limiting. Loaded first:
    -- server.lua's net event handlers call into the FenixGuard global it
    -- defines, and a handler that ran before it existed would be an open door.
    'server/guard.lua',

    'server/server.lua',

    -- GPS tracker removal. Reads FenixGuard.isAllowedVehicleModel, so it must
    -- load after guard.lua.
    'server/tracker.lua'
}
