fx_version "cerulean"
resource_manifest_version "05cfa83c-a124-4cfa-a768-c24a5811d8f9"
game "gta5"
author "Fenix, fork by Upstate Mafia"
description "AI police dispatch and wanted levels, with ambient enforcement"
version "2.4.2"

shared_scripts {
    'config.lua',
    'data/ambient_points.lua',

    -- Per-server overrides, loaded last so they win over everything above.
    -- The directory is gitignored and absent from a clean checkout — a glob that
    -- matches nothing is a no-op, which is the whole reason this is a directory
    -- and not a named file. See config.local.example.lua.
    'config.local/*.lua'
}

client_scripts {
    -- Shared road/lane/no-go-zone helper. Loaded first: both scripts below call
    -- into the FenixRoads global it defines.
    'client/roads.lua',

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

    'server/server.lua'
}
