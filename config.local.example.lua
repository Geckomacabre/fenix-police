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
