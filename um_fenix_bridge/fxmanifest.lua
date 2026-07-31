fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'um_fenix_bridge'
description 'Glue between fenix-police, ERS, and um_dynamicworld'
author 'Upstate Mafia'
version '0.1.0'

shared_scripts {
    'config.lua',
}

client_scripts {
    'client/suppression.lua',
    'client/ers_hooks.lua',
    'client/events_hooks.lua',
    'client/witness_hook.lua',
}

server_scripts {
    'server/crime.lua',   -- robbery alerts -> wanted level -> fenix AI units
}
