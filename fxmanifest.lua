fx_version "cerulean"
resource_manifest_version "05cfa83c-a124-4cfa-a768-c24a5811d8f9"
game "gta5"
author "Fenix"
description "Police"
version "1.0"

shared_scripts {
    'config.lua',
    'data/ambient_points.lua'
}

client_scripts {
    'client/client.lua',
    'client/ambient.lua'
}

server_scripts {
    'server/server.lua'
}
