fx_version "cerulean"
resource_manifest_version "05cfa83c-a124-4cfa-a768-c24a5811d8f9"
game "gta5"
author "Fenix, fork by Upstate Mafia"
description "AI police dispatch and wanted levels, with ambient enforcement"
version "2.0.1"

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
    'client/client.lua',
    'client/ambient.lua'
}

server_scripts {
    'server/server.lua'
}
