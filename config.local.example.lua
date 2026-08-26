--[[
    config.local.example.lua

    A template, not a loaded file. Nothing here runs — `fxmanifest.lua` loads
    `config.local/*.lua`, and this file sits outside that directory on purpose so
    it can be committed as documentation without ever being executed.

    ── What this is for ────────────────────────────────────────────────────────

    `config.lua` ships as the portable default: base-game vehicle models, stock
    job names, nothing that assumes anything about your server. That is what
    makes it safe to pull an update over — and also what makes it the wrong place
    to put your own add-on liveries or coordinates, because the next update
    overwrites them.

    Anything in `config.local/` is loaded AFTER `config.lua` and after
    `data/ambient_points.lua`, so it wins over both, and the directory is
    gitignored so an update never touches it.

    ── Using it ────────────────────────────────────────────────────────────────

      1. mkdir config.local
      2. Copy the parts of this file you actually want into
         config.local/whatever.lua  (split across as many files as you like —
         they all load, in filename order)
      3. Restart the resource

    Assign to the leaf you're changing, not to the whole table:

        Config.Ambient.vehicles = { ... }        -- replaces just the vehicle lists
        Config.Ambient = { ... }                 -- WRONG: drops every other
                                                 -- ambient setting with it

    ── Examples ────────────────────────────────────────────────────────────────
]]

-- Ambient police vehicles, per region, from your own add-on packs.
--
-- Weighted form: model -> relative weight. Models that aren't installed on a
-- given client are skipped when the pick is rolled, and a region that resolves
-- to nothing at all falls through to Config.Ambient.vehicleFallback — so you can
-- reference packs without checking that every client has them.
--
-- Weights are how you make an agency regional: give the local agency the bulk of
-- the weight, and let a statewide one appear everywhere at a lower rate.
--[[
Config.Ambient.vehicles = {
    losSantos = {
        ['yourcity_suv']     = 6,   -- city PD owns the city
        ['yourcity_sedan']   = 5,
        ['yourcity_k9']      = 1,   -- rare variants get a weight of 1
        ['yourhwp_charger']  = 2,   -- highway patrol works the freeways
        ['yoursheriff_suv']  = 1,   -- a county car in the city: unusual, not odd
    },
    sandyShores = {
        ['yoursheriff_suv']   = 6,  -- the county's own units carry the region
        ['yoursheriff_sedan'] = 4,
        ['yourhwp_charger']   = 2,
    },
    paletoBay   = { ['yoursheriff_suv'] = 6, ['yourhwp_charger'] = 2 },
    countryside = { ['yoursheriff_suv'] = 5, ['pranger'] = 3 },
}
]]

-- Officer ped models, same region keys. Plain arrays, picked uniformly.
--[[
Config.Ambient.peds = {
    losSantos   = { 'your_cop_ped_01', 'your_cop_ped_02' },
    sandyShores = { 'your_sheriff_ped_01' },
}
]]

-- Traffic citations. Fines are charged server-side; these are the amounts by
-- wanted level at the time of the stop.
--[[
Config.TicketSystem.fine.amounts = { 500, 1500 }
Config.TicketSystem.maxWantedLevel = 2   -- also cover reckless driving
]]

-- Which jobs count as police, if yours aren't named the defaults.
--[[
Config.PoliceJobsToCheck = {
    { jobName = 'yourpd', onDutyOnly = true },
}
]]

-- Extra ambient scene locations placed by hand, without editing the shipped
-- data file. Same shape as data/ambient_points.lua.
--[[
FenixAmbientPoints.radar = FenixAmbientPoints.radar or {}
table.insert(FenixAmbientPoints.radar, { x = 0.0, y = 0.0, z = 0.0, h = 0.0 })
]]

-- No-go areas. The shipped boxes over LSIA and Fort Zancudo are hand-measured,
-- so this is the one setting you should expect to adjust: draw them in-world
-- with /fenixroads, stand somewhere and run /fenixroads here, then trim.
--
-- Assigning the whole list replaces it, which is what you want if the shipped
-- boxes are wrong for your map. To keep them and add one, table.insert instead.
--[[
Config.Roads.exclusionZones = {
    {
        name = 'LSIA airside',
        min  = vector3(-1800.0, -3400.0, 0.0),
        max  = vector3(-950.0,  -2830.0, 0.0),
        zMin = -20.0,
        zMax = 45.0,
    },
    {
        name = 'my custom no-go area',
        -- Boxes are `min`/`max`; cylinders are `center`/`radius`; polygons are
        -- `poly` = a list of vector3 (only x and y are read, so you can paste
        -- coordinates straight out of a capture).
        center = vector3(0.0, 0.0, 0.0),
        radius = 150.0,
        zMin   = -20.0,
        zMax   = 60.0,
        -- Reject spawns here but leave AI pathing alone:
        -- disableAiRoads = false,
    },
}
]]

-- Which lane a responding unit appears in, and how far a parked scene sits past
-- the edge of the carriageway.
--[[
Config.Roads.lanePreference = 'random'   -- 'outer' (default) | 'inner' | 'random'
Config.Roads.shoulderOffset = 1.5
]]

-- How much the police can see, and how forgiving losing them is. The two numbers
-- worth touching first: sightRange (how far a ground officer sees) and
-- loseContactMs (how long line of sight has to stay broken before they give up
-- on your live position). Raising loseContactMs makes them dogged; lowering it
-- makes corners matter more.
--[[
Config.Pursuit.sightRange     = 90.0
Config.Pursuit.loseContactMs  = 4000
Config.Pursuit.blipColour     = 3        -- blue rather than the default hostile red
Config.Pursuit.blipDriversOnly = true
]]

-- Send radio traffic somewhere other than QBCore notifications. Receives the
-- finished string.
--[[
Config.Pursuit.dispatchHandler = function(text)
    exports['my_scanner']:Say(text)
end
]]

-- Roadblocks and spike strips. Turn either off by pushing its wanted level above
-- 5 rather than disabling the whole system.
--[[
Config.Tactics.roadblockFromLevel = 3
Config.Tactics.spikeFromLevel     = 6    -- effectively off
Config.Tactics.roadblockVehicles  = { 'your_addon_cruiser' }
]]

-- How police drive. Ranges are { min, max } per wanted level and rolled once per
-- officer.
--[[
Config.Driving.aggression = {
    [1] = { 0.15, 0.35 },   -- calmer low-level pursuits
    [2] = { 0.25, 0.50 },
    [3] = { 0.45, 0.70 },
    [4] = { 0.70, 0.95 },
    [5] = { 0.85, 1.00 },
}
]]

-- Server-side entity security. The one setting worth revisiting: turn
-- strictOwnership on once `fenixguard` in the server console shows entities
-- being owned during a pursuit. Before that it risks police cars that never
-- despawn.
--[[
Config.Security.strictOwnership = true
Config.Security.logRefusals     = true
]]

-- Allowlist models that live outside Config.vehiclesByRegion and the heli/plane
-- tables. Only needed if something else spawns police entities through this
-- resource's server events.
--[[
Config.Security.extraVehicles = { 'your_addon_cruiser' }
Config.Security.extraPeds     = { 'your_addon_cop_ped' }
]]

-- Ambient encounter rate and the convoy scene. Turned down in 2.4.0 after
-- reports of a cop on 7/10 corners; these are the knobs to move if it's still
-- too much, too little, or you want convoys more or less often.
--[[
Config.Ambient.spawnInterval    = 20      -- even sparser
Config.Ambient.maxScenes        = 2
Config.Ambient.convoyThirdCarChance = 0.0 -- convoys are always 2 cars
Config.Ambient.convoyCooldownSeconds = 480
]]

-- If a divided highway is still occasionally getting a unit on the wrong
-- carriageway, tighten these; if legitimate spawns near ordinary roads are
-- being rejected and falling back to the conservative one-lane-each-way
-- placement more than expected, loosen them.
--[[
Config.Roads.crossCheckDistance = 15.0
Config.Roads.crossCheckAngle    = 30.0
]]
