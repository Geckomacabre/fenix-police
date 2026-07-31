--[[
    data/ambient_points.lua

    Seed locations for Config.Ambient scenes.

    IMPORTANT — these are APPROXIMATE. Every point is snapped at spawn time:
      * `radar` points snap to the nearest vehicle node (the actual road surface),
        and are discarded if the nearest road is further than `snapRadius` away.
      * `post` points snap to ground Z via GetSafeCoordForPed.
    That means a seed only has to land in the right neighbourhood — the game
    finds the real surface. If a point never produces a scene, its nearest road
    is out of range and the seed is wrong; replace it with an exact one placed
    through the em_toolkit connector (World & Environment -> Police Scenarios).

    `stop`, `patrol` and `pursuit` scenes don't use this file at all — they pick
    road nodes near the player at runtime.
]]

FenixAmbientPoints = {}

-- How far from a seed the snapped road node may be before the seed is rejected.
FenixAmbientPoints.snapRadius = 120.0

-- ---------------------------------------------------------------------------
-- RADAR TRAPS — cruiser parked facing traffic with an officer inside.
-- Placed along highways and arterial roads. `h` is the heading the cruiser
-- faces; when a point snaps to a road node the node's own heading is used
-- instead, rotated 90 degrees so the car sits across the traffic flow.
-- ---------------------------------------------------------------------------
FenixAmbientPoints.radar = {
    -- Los Santos
    { x = -1600.0, y = -1000.0, z = 13.0,  h = 130.0 },  -- Del Perro Fwy / pier
    { x = -500.0,  y = -1800.0, z = 20.0,  h = 300.0 },  -- La Puerta Fwy
    { x = 200.0,   y = -2200.0, z = 6.0,   h = 265.0 },  -- Elysian Fields Fwy
    { x = 1000.0,  y = -1500.0, z = 30.0,  h = 90.0  },  -- East Los Santos
    { x = 1500.0,  y = -1700.0, z = 80.0,  h = 20.0  },  -- Palomino Fwy
    { x = 300.0,   y = 200.0,   z = 100.0, h = 160.0 },  -- Vinewood Blvd
    { x = -800.0,  y = -100.0,  z = 40.0,  h = 210.0 },  -- Rockford Hills
    { x = 100.0,   y = -900.0,  z = 30.0,  h = 340.0 },  -- Downtown

    -- Countryside / Route 68 / Senora Fwy
    { x = 500.0,   y = 2600.0,  z = 42.0,  h = 190.0 },  -- Route 68, Harmony
    { x = 1700.0,  y = 3200.0,  z = 40.0,  h = 30.0  },  -- Senora Fwy, Sandy
    { x = 1300.0,  y = 4300.0,  z = 30.0,  h = 190.0 },  -- Alamo Sea east
    { x = 2200.0,  y = 4800.0,  z = 40.0,  h = 250.0 },  -- Grapeseed
    { x = -1300.0, y = 2500.0,  z = 20.0,  h = 100.0 },  -- Route 68 west
    { x = -1900.0, y = 2100.0,  z = 130.0, h = 300.0 },  -- Great Ocean Hwy

    -- Paleto / north
    { x = -200.0,  y = 6300.0,  z = 31.0,  h = 220.0 },  -- Route 1, Paleto
    { x = 100.0,   y = 6600.0,  z = 31.0,  h = 45.0  },  -- Paleto north
}

-- ---------------------------------------------------------------------------
-- FOOT POSTS — officers standing around doing scenarios. These are exact
-- station coordinates (shared with Config.ArrestSystem.stations) plus a few
-- landmarks, so they only need a ground-Z snap.
-- `count` is how many officers stand at the post.
-- ---------------------------------------------------------------------------
FenixAmbientPoints.post = {
    -- Police stations
    { x = 428.6,   y = -981.2,  z = 30.7, h = 90.0,  count = 3 },  -- Mission Row LSPD
    { x = 436.5,   y = -1013.8, z = 28.7, h = 180.0, count = 2 },  -- Mission Row lot
    { x = -1108.4, y = -845.4,  z = 19.0, h = 35.0,  count = 2 },  -- Vespucci PD
    { x = 1853.1,  y = 3689.6,  z = 34.3, h = 120.0, count = 2 },  -- Sandy Shores Sheriff
    { x = -449.2,  y = 6012.6,  z = 31.7, h = 45.0,  count = 2 },  -- Paleto Bay Sheriff
    { x = 360.6,   y = -1584.8, z = 29.3, h = 320.0, count = 2 },  -- Davis Sheriff
    { x = -561.8,  y = -131.0,  z = 38.0, h = 200.0, count = 2 },  -- Rockford Hills PD
    { x = 638.5,   y = 1.9,     z = 82.8, h = 270.0, count = 1 },  -- Vinewood Hills PD

    -- Landmarks that read as a police presence
    { x = -1035.0, y = -2733.0, z = 13.8, h = 330.0, count = 2 },  -- LSIA terminal
    { x = 236.0,   y = -410.0,  z = 48.1, h = 250.0, count = 1 },  -- Pillbox / hospital
    { x = -247.0,  y = -970.0,  z = 31.2, h = 160.0, count = 1 },  -- Legion Square
    { x = 1972.0,  y = 3815.0,  z = 33.4, h = 300.0, count = 1 },  -- Sandy Shores medical
}
