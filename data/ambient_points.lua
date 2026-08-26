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
    { x = -1606.5, y = -1014.0, z = 12.0, h = 51.3 },  -- Del Perro Fwy / pier [backroad]
    { x = -483.25, y = -1871.25, z = 16.53, h = 283.8 },  -- La Puerta Fwy [freeway]
    { x = 198.75, y = -2188.0, z = 6.16, h = 90.0 },  -- Elysian Fields Fwy [backroad]
    { x = 1044.5, y = -1503.0, z = 27.16, h = 4.0 },  -- East Los Santos [freeway]
    { x = 1410.25, y = -1723.0, z = 64.94, h = 195.5 },  -- Palomino Fwy [street]
    { x = 292.25, y = 162.5, z = 103.19, h = 250.3 },  -- Vinewood Blvd [street]
    { x = -783.25, y = -97.75, z = 36.78, h = 27.6 },  -- Rockford Hills [street]
    { x = 133.5, y = -901.25, z = 29.28, h = 340.8 },  -- Downtown [street]
    { x = 490.5, y = 2626.25, z = 41.94, h = 101.3 },  -- Route 68, Harmony [street]
    { x = 1736.25, y = 3159.25, z = 42.12, h = 112.1 },  -- Senora Fwy, Sandy [backroad]
    { x = 1338.0, y = 4333.0, z = 36.88, h = 273.8 },  -- Alamo Sea east [gravel]
    { x = 2190.25, y = 4793.75, z = 42.47, h = 168.0 },  -- Grapeseed [street]
    { x = -1291.0, y = 2497.25, z = 20.47, h = 318.8 },  -- Route 68 west [street]
    { x = -1823.25, y = 2034.75, z = 130.88, h = 274.9 },  -- Great Ocean Hwy [street]
    { x = -135.5, y = 6242.0, z = 30.16, h = 143.1 },  -- Route 1, Paleto [freeway]
    { x = 87.5, y = 6594.5, z = 30.56, h = 225.0 },  -- Paleto north [street]
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
