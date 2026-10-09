fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'el_printer'
author 'Empire Line'
description 'Empire Line printer system for QBCore: fixed and placeable printers, document templates, secure printing and supplies.'
version '1.0.0'

ui_page 'html/index.html'

shared_scripts {
    'config.lua',
    'shared.lua',
    'bridge/init.lua',
}

client_scripts {
    'bridge/client/framework.lua',
    'bridge/client/target.lua',
    'bridge/client/inventory.lua',
    'client/nui.lua',
    'client/placement.lua',
    'client/main.lua',
}

server_scripts {
    'bridge/server/framework.lua',
    'bridge/server/inventory.lua',
    'server/database.lua',
    'server/permissions.lua',
    'server/printers.lua',
    'server/documents.lua',
    'server/printing.lua',
    'server/main.lua',
}

files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
    'html/render.js',
    'html/img/*.png',
    'html/vendor/manrope/*.css',
    'html/vendor/manrope/*.woff2',
    'html/vendor/fontawesome/css/*.css',
    'html/vendor/fontawesome/webfonts/*.woff2',
    'html/vendor/fontawesome/webfonts/*.ttf',
}

dependencies {
    'qb-core',
}
