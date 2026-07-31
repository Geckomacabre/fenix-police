Config = {}

-- ============================================================================
-- FEATURE TOGGLES
-- One place to turn major systems on/off without hunting through the file.
-- ============================================================================
Config.Toggles = {
    -- Master switch: enable/disable all AI police dispatching
    enabled                 = true,

    -- Only spawn AI cops when no player police are on duty
    -- (mirrors Config.onlyWhenPlayerPoliceOffline below — change BOTH or just use this)
    onlyWhenPlayerPoliceOffline = true,

    -- Wanted level system: if false, players never become wanted
    wantedLevels            = true,

    -- Arrest / BUSTED screen system (requires Config.ArrestSystem.enabled too)
    arrestSystem            = false,

    -- AI helicopter units
    heliUnits               = true,

    -- AI fixed-wing air units (jets)
    airUnits                = true,

    -- Ground unit spawning while player is in a helicopter
    groundUnitsInHeli       = true,

    -- Ground unit spawning while player is in a plane
    groundUnitsInPlane      = true,

    -- Remove base-game vehicle generators at police stations when player police are online
    removeVehicleGenerators = false,
}
-- ============================================================================


-- **CONFIG SETTINGS** --

-- Can enable this to print debug messages to client consoles and server console.
Config.isDebug = false


-- DISPATCH SERVICES --

-- This toggle will enable functionality that checks if any players logged on have the Police job
-- and disables wanted levels and dispatching if there are. 
-- Setting this to true will only allow AI police when no player police are online.
-- Setting this to false will always have AI police even if player police are online.
Config.onlyWhenPlayerPoliceOffline = true

-- This setting works with the above toggle, how many police online are required before AI police are turned off?
Config.numberOfPoliceRequired = 1
-- Which Jobs count as "Police" jobs?
Config.PoliceJobsToCheck = {
    [1] = {
        jobName = 'police',
        onDutyOnly = true, -- Only counts if on Duty, if this is false any online police count even if off-duty.
    },
    -- [Upstate Mafia] Added BCSO and SASP to match ox.cfg inventory:police list.
    [2] = {
        jobName = 'bcso',
        onDutyOnly = true,
    },
    [3] = {
        jobName = 'sasp',
        onDutyOnly = true,
    },
}

-- Are players with police jobs in the list above protected from becoming wanted?
Config.PoliceWantedProtection = true

-- 1.0.1 Are players treated as police (and protected from being wanted) only when on-duty?
Config.PlayerPoliceOnlyOnDuty = true

-- 1.0.1 This removes vehicles from generating at PDs when police are online. 
Config.RemoveVehicleGenerators = false

-- This sets which dispatch services the game will handle using base game logic.
-- IMPORTANT: Turning on regular police dispatches will cause this mod to spawn more police in addition to base game police.
Config.AIResponse = {
    wantedLevels = true, -- if true, you will recieve wanted levels
    dispatchServices = {  -- AI dispatch services
        [1] = false,      -- Police Vehicles
        [2] = false,      -- Police Helicopters
        [3] = false,      -- Fire Department Vehicles
        [4] = false,      -- Swat Vehicles
        [5] = false,      -- Ambulance Vehicles
        [6] = false,      -- Police Motorcycles
        [7] = false,      -- Police Backup
        [8] = false,      -- Police Roadblocks
        [9] = false,      -- PoliceAutomobileWaitPulledOver
        [10] = false,     -- PoliceAutomobileWaitCruising
        [11] = false,     -- Gang Members
        [12] = false,     -- Swat Helicopters
        [13] = false,     -- Police Boats
        [14] = false,     -- Army Vehicles
        [15] = false      -- Biker Backup
    }
}

-- Define the evasion times for each wanted level (in milliseconds)
Config.evasionTimes = {
    [1] = 60000, -- 1 minute for wanted level 1
    [2] = 90000, -- 1.5 minutes for wanted level 2
    [3] = 120000, -- 2 minutes for wanted level 3
    [4] = 120000, -- 2 minutes for wanted level 4
    [5] = 150000  -- 2.5 minutes for wanted level 5
}


-- OFFICER COMBAT BALANCE --
-- Controls how deadly AI officers are, scaled by wanted level.
-- Without this, every cop spawns with high accuracy, full-auto firing and
-- HATES_PLAYER, so a 1-star chase turns into a firefight instantly.
-- The intent here: wanted 1-3 is a PURSUIT (sirens, boxing, PIT) and cops only
-- shoot if you shoot first; wanted 4-5 is a SHOOTOUT.
Config.Combat = {
    -- Set false to restore the old always-hostile behaviour.
    enabled = true,

    -- Chance (0.0 - 1.0) that any given officer is willing to open fire at this
    -- wanted level. Rolled once per officer when they spawn and kept for their
    -- lifetime, so a unit doesn't flicker between shooting and not shooting.
    -- 0.0 = pure pursuit, nobody shoots unless provoked (see provokedDuration).
    engageChance = {
        [1] = 0.0,
        [2] = 0.0,
        [3] = 0.25,  -- roughly one officer in four starts taking shots
        [4] = 0.8,
        [5] = 1.0,
    },

    -- Wanted level at which officers are hostile on sight regardless of the
    -- engageChance roll above.
    hostileFromLevel = 4,

    -- CALIBRATION SOURCE: the numbers below are anchored to Rockstar's own
    -- difficulty tiers, read out of the decompiled fm_content_vehrob_police
    -- script (helpers func_311/312/313, applied together on every enemy ped):
    --
    --   tier          accuracy   shootRate   combatAbility
    --   2 "easy"         10          60          1
    --   3 "normal"       25          80          2
    --   4 "hard"         40         100          2
    --   (rocket/railgun carriers get accuracy 2)
    --
    -- So wanted 5 here lands on Rockstar's "hard" and wanted 4 on their
    -- "normal"; 1-3 sit at or below "easy". Anything above these is hotter than
    -- the hardest enemies the base game ships.

    -- SetPedAccuracy roll range {min, max} per wanted level. 0-100.
    accuracy = {
        [1] = { 5, 10 },
        [2] = { 6, 12 },
        [3] = { 8, 16 },
        [4] = { 15, 25 },  -- ceiling = Rockstar "normal"
        [5] = { 25, 40 },  -- ceiling = Rockstar "hard"
    },

    -- SetPedShootRate per wanted level. Lower = longer pauses between shots.
    -- The native accepts up to 1000, but Rockstar never goes above 100 — treat
    -- 100 as the real ceiling.
    shootRate = {
        [1] = 30,
        [2] = 40,
        [3] = 50,
        [4] = 80,   -- Rockstar "normal"
        [5] = 100,  -- Rockstar "hard"
    },

    -- SetPedCombatAbility: 0 = poor, 1 = average, 2 = professional.
    -- Affects flanking, cover use and reaction time, not just aim. Rockstar
    -- never drops below 1, so neither do we — 0 makes officers visibly broken
    -- rather than merely less dangerous.
    combatAbility = {
        [1] = 1,
        [2] = 1,
        [3] = 1,
        [4] = 1,
        [5] = 2,
    },

    -- SetPedCombatRange: 0 = near, 1 = medium, 2 = far.
    -- Low values force officers to close distance instead of sniping from a
    -- block away, which reads as far less unfair.
    combatRange = {
        [1] = 0,
        [2] = 0,
        [3] = 0,
        [4] = 1,
        [5] = 2,
    },

    -- Wanted level from which officers may fire out of vehicle windows.
    -- Drive-bys are the single biggest source of "shot through the windshield
    -- while doing 90" complaints, so they're held back to the shootout tiers.
    drivebyFromLevel = 4,

    -- Wanted level from which officers use full-auto instead of burst fire.
    fullAutoFromLevel = 5,
    firingPatternBurst = 'FIRING_PATTERN_BURST_FIRE',
    firingPatternAuto  = 'FIRING_PATTERN_FULL_AUTO',
    -- Helicopter/aircraft crews get their own pattern regardless of level. This
    -- is what the base game uses for peds on mounted vehicle weapons — in
    -- fm_content_vehrob_police it's set in the same block as combat attributes
    -- 52/53/89, which is exactly the setup our air units already run.
    firingPatternHeli  = 'FIRING_PATTERN_BURST_FIRE_HELI',

    -- Relationship group applied once an officer is hostile.
    relationshipHostile = 'HATES_PLAYER',
    -- Relationship group applied while officers are in pursuit-only mode. This
    -- group is created at runtime and set to Respect toward PLAYER so officers
    -- will not start a fight on their own, but still defend themselves.
    relationshipPassive = 'FENIX_PURSUIT',

    -- PROVOCATION: if the player fires a weapon or damages an officer, every
    -- unit escalates to full hostility (hostile relationship, drive-bys, full
    -- auto) for this long, no matter the wanted level. Refreshed on each new
    -- provocation. Set to 0 to disable escalation entirely.
    provokedDuration = 30000, -- ms
}


-- AMBIENT POLICE PRESENCE --
-- Scripted police "scenes" that populate the map when you are NOT wanted:
-- radar traps, traffic stops, cruisers on patrol, cops on foot, NPC pursuits.
--
-- Why this exists: the main loop calls SetCreateRandomCops(false) every cycle so
-- the base game's ambient cops don't fight the dispatch system. That's correct,
-- but it also strips every cop off the map outside a chase. This puts them back
-- under script control, so they're police *dressing* and never interfere with a
-- pursuit.
--
-- Entities are client-local (non-networked), like a map prop. Fixed-point scenes
-- (radar / stop / post) use the same coordinate list on every client so everyone
-- sees the same scene in the same place; roaming scenes (patrol / pursuit) are
-- picked from road nodes near each player and will differ per client.
Config.Ambient = {
    enabled = true,

    -- Ambient scenes are suppressed while you're wanted and torn down as soon as
    -- a wanted level appears, so they never get tangled up in a real pursuit.
    despawnWhenWanted = true,

    -- How many ambient scenes may exist at once. Each scene is 1-2 vehicles and
    -- 1-4 peds, so keep this low.
    maxScenes = 4,

    -- Seconds between scene spawn attempts.
    spawnInterval = 8,

    -- A scene must spawn between these distances from the player, and is deleted
    -- past cleanupDistance. Fixed-point scenes are also deleted when their point
    -- goes out of range, and re-spawn when you come back.
    minSpawnDistance = 70.0,
    maxSpawnDistance = 220.0,
    cleanupDistance  = 320.0,

    -- Roaming scenes are torn down after this many seconds regardless of distance
    -- so patrols and pursuits keep cycling instead of following you forever.
    roamingLifetime = 180,

    -- ── Pursuits ────────────────────────────────────────────────────────────
    -- A pursuit is an event, not background traffic. The scene weight alone
    -- can't express "rare but memorable", so this is a hard floor between them
    -- regardless of how the weighted roll lands.
    pursuitCooldownSeconds = 300,

    -- Pursuits get their own lifetime because they need room to run, resolve and
    -- be watched. Shortened automatically once the arrest tableau has held.
    pursuitLifetime = 300,

    -- How long the car chase runs before it resolves, randomised per pursuit so
    -- two never end on the same beat.
    pursuitChaseSeconds = { 35, 75 },

    -- How it ends. Every pursuit resolves — previously they just drove in circles
    -- until the lifetime culled them, which is what made them feel like filler.
    --   surrender  pulls over and gives up at the roadside
    --   bail       stops, runs on foot, gets run down
    --   crash      engine dies, then surrenders
    pursuitOutcomes = { surrender = 4, bail = 4, crash = 2 },

    -- Caps a foot chase so a suspect who outruns the AI still gets caught.
    pursuitFootChaseSeconds = 25,

    -- How long the cuffed-at-gunpoint tableau holds before everyone is released.
    pursuitHoldSeconds = 20,

    -- How long a traffic stop runs before the officer wraps up and walks back to
    -- the car, and how long the scene is then kept alive so both vehicles can
    -- actually drive away. Applies to procedural stops and to radar traps that
    -- have pulled an NPC over. Without these a stop never ends.
    stopDurationSeconds  = 60,
    stopDepartureSeconds = 25,

    -- ── Placement quality ───────────────────────────────────────────────────
    -- Candidate road nodes sampled per spawn attempt. The best-scoring one wins
    -- rather than the first that happens to be in range, which is what keeps
    -- scenes off junctions, out of traffic and away from dead-end dirt tracks.
    -- Each sample is one cheap native call; 10 is plenty.
    nodeSamples = 10,

    -- Minimum distance between two ambient scenes. Stops them clumping into a
    -- police convention on one street.
    minSceneSpacing = 90.0,

    -- Hard ceiling on ambient OFFICERS within nearbyRadius of the player, on top
    -- of maxScenes. A couple of 4-officer foot posts reach "too many cops" long
    -- before the scene cap does. Counted from the scenes this script already
    -- owns during the cull pass — no world scans, no extra bookkeeping.
    maxNearbyCops = 6,
    nearbyRadius  = 260.0,

    -- Static roadside scenes (radar traps, traffic stops) are pushed this far
    -- onto the verge so they stop blocking a live lane. Moving scenes (patrol,
    -- pursuit) still spawn on the carriageway — they drive off immediately.
    shoulderOffset = 4.5,

    -- Never spawn a procedural scene the player can currently see, so nothing
    -- pops into existence in front of them. Authored points are exempt: you
    -- should be able to stand and watch a point you placed come to life.
    avoidVisibleSpawns = true,

    -- Invent radar traps at random road nodes when no authored point is in
    -- range. Off by default — with points of your own this is the single
    -- biggest source of "there are cops everywhere".
    radarFallbackToRoadNodes = false,

    -- ── Radar enforcement ───────────────────────────────────────────────────
    -- Parked radar traps actually read speed and react. Per-trap overrides for
    -- the vehicle and the enforced mph are authored in em_toolkit
    -- (World & Environment -> Police Scenarios); the values here are the
    -- fallbacks for traps that don't set their own.
    radar = {
        enabled = true,

        -- Every ambient officer enforces, not just aimed radar traps — a patrol
        -- car or a foot post reacts to a car doing triple the limit past it.
        -- Foot officers have no car to give chase in, so they call it in and the
        -- pursuit system sends units.
        enforceFromAllCops = true,

        -- ── Speed limits ────────────────────────────────────────────────────
        -- Posted limits come from the `speedlimits` resource (its
        -- Config.SpeedLimits, keyed by street name) through the exports added to
        -- its client/main.lua. Limits stay defined there — this only reads them.
        usePostedLimits = true,

        -- Grace over the posted sign before anyone reacts.
        toleranceMph = 15,

        -- Most streets have no sign defined, so this is what applies on them.
        -- It is deliberately generous: it exists to catch the genuinely absurd,
        -- not to police ordinary driving on unposted roads.
        unpostedLimitMph = 80,

        -- Fallback when posted limits are off or `speedlimits` isn't running.
        -- A radar trap with its own authored "Enforced speed" overrides
        -- everything above, posted signs included.
        triggerSpeedMph = 60,

        -- ── Detection ───────────────────────────────────────────────────────
        -- An aimed trap only watches the way it was parked to watch: cars must
        -- be within detectRange and inside this cone (full width, degrees), so
        -- traffic behind it drives past untouched.
        detectRange = 60.0,
        coneDegrees = 70.0,

        -- Patrols and foot officers aren't aimed at anything, so they watch a
        -- plain radius in every direction — shorter, since they're not looking
        -- for it the way a trap is.
        copDetectRange = 45.0,

        -- How often the radar samples. The player check is free; the NPC pool
        -- is only walked every npcScanEveryTicks passes, so at these numbers
        -- traffic is scanned a little over once a second.
        --
        -- The player check walks the path travelled since the last sample rather
        -- than just the current position, so this rate does NOT set a speed
        -- ceiling on detection — a car at 150 mph covers ~40m between samples
        -- here and is still picked up. NPCs are tested on position only, so a
        -- genuinely flying NPC can still slip through.
        tickMs = 600,
        npcScanEveryTicks = 2,

        -- A vehicle can't be clocked twice inside this window — stops one car
        -- setting off the same trap repeatedly while it crawls past.
        cooldownSeconds = 45,

        -- Players: hands off to this resource's own pursuit stack. Units spawn,
        -- dispatch reacts, and the ArrestSystem (if enabled) ends it in a bust.
        -- The catching cruiser joins the chase and is exempted from
        -- despawnWhenWanted so it doesn't vanish mid-catch.
        catchPlayers = true,
        playerWantedLevel = 1,

        -- Never enforce against a player who is on duty as police. Checked
        -- against this resource's own job list (Config.PoliceJobsToCheck) and
        -- against night_ers' shift state, either being sufficient.
        --
        -- Player-side police RP belongs to night_ers on this server; an ambient
        -- trap chasing an on-duty officer to a call is exactly the kind of
        -- crossover that makes AI police feel broken rather than alive.
        exemptPolice = true,

        -- NPCs: no wanted system at all. The trap car chases, the NPC yields
        -- after npcYieldSeconds, and it settles into a roadside stop with an
        -- officer at the window. NPCs are judged against the trap's own limit
        -- rather than the posted sign — resolving a street name for every
        -- vehicle in the pool every tick isn't worth it for background traffic.
        catchNpcs = true,
        npcYieldSeconds = 15,

        -- Aimed traps pull NPCs over; patrols don't. Turning this on means every
        -- patrol car chases every speeding NPC, which becomes a permanent
        -- citywide car chase very quickly.
        catchNpcsFromAllCops = false,
    },

    -- Relative weight of each scene type. Set a weight to 0 to disable that type.
    weights = {
        radar    = 3,  -- cruiser parked facing traffic, officer inside
        stop     = 3,  -- NPC pulled over, officer at the driver's window
        patrol   = 4,  -- cruiser driving a normal route, no siren
        post     = 3,  -- officers on foot at a station/landmark doing scenarios
        pursuit  = 1,  -- NPC vehicle fleeing, cruisers chasing with sirens
        carjack  = 1,  -- suspect drags a driver out and takes off
    },

    -- Peds used as carjackers. Defaults to civPeds when unset; give it a
    -- rougher-looking list if you want them to read as criminals on sight.
    -- The getaway is driven fast on purpose, so a suspect who passes a radar
    -- trap gets clocked and chased with no extra wiring.
    carjackSuspects = {
        'a_m_y_skater_01', 'a_m_m_farmer_01', 'a_m_y_hipster_01',
        'a_m_y_stwhi_01', 'a_m_m_soucent_01',
    },

    -- Vehicles used for ambient units, by region key (see Config.ZoneEnum).
    vehicles = {
        losSantos   = { 'police', 'police2', 'police3' },
        paletoBay   = { 'sheriff', 'sheriff2' },
        sandyShores = { 'sheriff', 'sheriff2' },
        countryside = { 'sheriff', 'sheriff2', 'pranger' },
    },

    -- Officer models by region key.
    peds = {
        losSantos   = { 's_m_y_cop_01', 's_f_y_cop_01' },
        paletoBay   = { 's_m_y_sheriff_01', 's_f_y_sheriff_01' },
        sandyShores = { 's_m_y_sheriff_01', 's_f_y_sheriff_01' },
        countryside = { 's_m_y_sheriff_01', 's_f_y_sheriff_01', 's_m_y_ranger_01' },
    },

    -- Civilian models + vehicles used as the "pulled over" / "fleeing" party.
    civPeds = { 'a_m_y_business_01', 'a_m_m_farmer_01', 'a_f_y_hipster_01', 'a_m_y_skater_01', 'a_f_m_business_02' },
    civVehicles = { 'blista', 'premier', 'sultan', 'futo', 'asea', 'rebel', 'sadler', 'washington' },

    -- Scenarios ambient foot officers play. Every name here was verified against
    -- the decompiled base-game scripts (fm_content_vehrob_police uses
    -- WORLD_HUMAN_COP_IDLES / WORLD_HUMAN_GUARD_STAND for exactly this — cops
    -- standing guard around a police vehicle).
    footScenarios = {
        'WORLD_HUMAN_COP_IDLES',
        'WORLD_HUMAN_GUARD_STAND',
        'WORLD_HUMAN_STAND_IMPATIENT',
        'WORLD_HUMAN_STAND_MOBILE',
        'WORLD_HUMAN_INSPECT_STAND',
        'WORLD_HUMAN_LEANING',
        'WORLD_HUMAN_SMOKING',
        'WORLD_HUMAN_DRINKING',
    },

    -- Officers are armed so they aren't defenceless props, but at ambient-tier
    -- accuracy. They're in a neutral relationship group and will not start a
    -- fight — shoot one and the normal wanted system takes over from there.
    -- Below Rockstar's "easy" tier (accuracy 10) — these are set dressing.
    weapon = 'weapon_pistol',
    accuracy = { 5, 12 },

    -- Relationship group for ambient officers. Created at runtime, set to Respect
    -- toward PLAYER. Same reasoning as Config.Combat.relationshipPassive.
    relationshipGroup = 'FENIX_AMBIENT',

    -- Shipped seed points are snapped onto the nearest road node / ground at
    -- spawn time, so data/ambient_points.lua only has to be approximately right —
    -- the game finds the actual road surface.
    --
    -- This never applies to points placed through em_toolkit: those were captured
    -- by standing or parking on the exact spot, and are always used verbatim.
    snapToRoad = true,

    -- Read extra points placed with the em_toolkit connector, if that resource is
    -- running. fenix-police works standalone without it.
    useToolkitPoints = true,

    -- Per-client trace of ambient spawning and radar enforcement. Off for
    -- release; turn on when diagnosing placement or detection, alongside the
    -- /ambientpolice and /radartrace commands.
    debug = false,
}


-- ARREST / BUSTED SYSTEM --
-- When a wanted player presses the surrender key (default H), they put their hands up.
-- Nearby officers will approach with weapons aimed. Once close enough, the player is
-- arrested with a cinematic "BUSTED" screen (same style as the WASTED screen) and is
-- transported (teleported) to the nearest police station.
Config.ArrestSystem = {
    enabled = true,
    -- How close the responding UNIT must be before it stops and sends an officer
    -- out on foot. Units further away than this stay in their vehicles, which is
    -- what keeps the pursuit loop intact instead of emptying every car at once.
    approachDistance = 35.0,
    arrestDistance = 2.0,          -- How close an officer must be to trigger arrest (metres)

    -- How long the BUSTED screen holds, in REAL milliseconds. This is measured
    -- with GetNetworkTime rather than GetGameTimer, because the cinematic runs at
    -- SetTimeScale(0.15) and game time would stretch 6s into roughly 40s.
    bustedDuration = 6000,
    bustedMaxDuration = 30000,     -- Hard ceiling, whatever bustedDuration says
    bustedSkippable = true,        -- SPACE or ENTER skips the rest of the cinematic
    bustedSubtitle = 'Taken into custody',

    -- Where you wake up: 'nearest' picks the closest station to the arrest,
    -- 'random' picks any station in the list below.
    releaseAt = 'nearest',
    stations = {
        vector4(441.1, -982.2, 30.7, 90.0),      -- Mission Row LSPD
        vector4(-1108.4, -845.4, 19.0, 35.0),     -- Vespucci PD
        vector4(1853.1, 3689.6, 34.3, 120.0),     -- Sandy Shores Sheriff
        vector4(-449.2, 6012.6, 31.7, 45.0),      -- Paleto Bay Sheriff
        vector4(360.6, -1584.8, 29.3, 320.0),     -- Davis Sheriff
        vector4(-561.8, -131.0, 38.0, 200.0),     -- Rockford Hills PD
    },
}


---------------------------------


-- SCRIPT CYCLE TIME--

-- IMPORTANT: This is the number of miliseconds between cycles in the script.
-- Default is 1000 ms, this means every second the script will check if the player wanted level is greater than 0.
-- If the player is wanted it will check the currently spawned unit count vs the max for that wanted level and spawn one unit if required.
-- It will not spawn another unit until the script cycles again. This means at 1000 ms this will spawn one cop per second if the player is wanted.
-- All of the handling of currently spawned units occurs for all of them every cycle. With the default setting this means every second it checks all the spawned
-- vehicles and officers to see if they are dead or too far away and starts timers to remove them if they remain that way. 
-- It checks if the player is on foot or in a vehicle and adjusts ALL of the spawned officers accordingly every cycle making them get out and pursue on foot or get back
-- into a nearby vehicle if the player gets in a vehicle and flees etc.
Config.scriptFrequency = 1000 --miliseconds

-- This modulus is used when the cleanup/removal timers are checked in the code to ensure that they are not treated as the 
-- number of cycles to pass before removing an officer, but as the number of seconds. 
-- eg. if the timer is 20 and is supposed to be seconds but your scriptFrequency has been changed to 500 ms as in it runs once every 0.5 seconds
-- the modulus will be (500 / 1000) = 0.5, when called in code I will take (timer/modulus) as the number of cycles to pass before removing the officer.
-- this means 20/0.5 = 40 cycles at 0.5 seconds per cycle this ensures the timer is still treated as 20 seconds. 
-- DO NOT CHANGE THIS, there should be no need to change this calculation. 
Config.scriptFrequencyModulus = (Config.scriptFrequency / 1000)

-- Wait time used for NetToVeh or NetToPed calls until they return a value.
Config.netWaitTime = 100

-- WAIT COUNT LOOPS--

-- Wait Count used by spawning scripts, this is the # of retries before it gives up for various loops.
Config.spawnWaitCount = 10

-----------------------------------------
-- UPDATE: This didn't work as intended, in my testing if the first ped fails to warp into a vehicle they ALL will fail.
-- And spawning new vehicles at the same spawn point, even if different vehicle models each time, will still fail over and over.
-- It seems that the spawn location is the problem more than anything. Randomizing it each time did fix it, but then they were all over the place including invalid spots.
-- Setting warpWaitCount = 1 and hasDriverWaitCount = 1 effectively means it will try to create the ped and try to warp them spawnWaitCount # of times once. If that fails it breaks the loop.
-- Then it deletes the vehicle and goes to re-try, but because hasDriverWaitCount = 1 it just exits returning nil to the client and the client will pick a new random spawn point and ask for another unit
-- next cycle. That seems to work the most reliably. 
-- These wait counts are used for re-tries. The logic is something like this:
-- 1) Spawn vehicle, if failed retry spawning vehicle spawnWaitCount # of times. 
-- 2) If vehicle has spawned then spawn a ped, if failed retry spawning ped spawnWaitCount # of times.
-- 3) If ped has spawned try warping into vehicle, if failed retry warping ped spawnWaitCount # of times.
-- 4) If ped still not warped delete ped entity and spawn a new one starting back at step 3. Do this warpWaitCount # of times.
-- 5) If we still don't have a ped in the driver seat of the vehicle delete the vehicle entity and start back at step 1. Do this hasDriverWaitCount # of times.
-- 6) If we STILL haven't properly spawned a vehicle exit the function and send the client a response, it will be empty, so the client will start over trying to add one more unit again. 

-- DO NOT EDIT Wait Count used by spawning scripts for warping peds into vehicles, this is the # of times it will start over with a fresh ped and attempt to warp the new ped.
Config.warpWaitCount = 3

-- DO NOT EDIT Wait Count used by spawning scripts for generating a vehicle with a driver, this is the number of times it starts over with a fresh vehicle if it still has no driver at end of ped loop.
Config.hasDriverWaitCount = 3
------------------------------------------

-- Wait Count used by handling scripts, ie. to send police to coords, to check if they are dead, too far away, stuck etc. 
-- Anything that requires the entity to exist locally. I want this lower so it doesn't spend so long checking over and over
-- for an entity that might be too far away to exist on the local client.
-- This is the # of retries before it gives up.
Config.controlWaitCount = 6

--------------------------

-- WANTED LEVEL UNIT COUNTS --
Config.maxUnitsPerLevel = {2, 3, 4, 6, 10} -- Maximum ground units for each wanted level
Config.maxHeliUnitsPerLevel = {0, 1, 1, 2, 4} -- Maximum heli units for each wanted level
Config.maxAirUnitsPerLevel = {0, 0, 0, 0, 1} -- Maximum plane units for each wanted level

-- This controls whether ground units will spawn if the player is in a helicopter, already spawned units aren't removed.
Config.spawnGroundUnitsInHeli = true

-- This controls whether ground units will spawn if the player is in a plane, already spawned units aren't removed.
Config.spawnGroundUnitsInPlane = true


-- SPAWN DISTANCES ETC --

Config.maxPoliceSpawnDistance = 140.0 -- This is the max distance around the player the spawn point for a new unit must be.
Config.minPoliceSpawnDistance = 80.0 -- This is the min distance from the player a spawn point for a new unit must be.

Config.maxHeliSpawnDistance = 500.0 -- This is the max distance around the player the spawn point for a new heli must be.
Config.minHeliSpawnDistance = 100.0 -- This is the min distance from the player a spawn point for a new heli must be. 
Config.maxHeliSpawnHeight = 200.0 -- This is the max height the spawn point for a new heli must be.
Config.minHeliSpawnHeight = 150.0 -- This is the min height the spawn point for a new heli must be.

Config.maxAirSpawnDistance = 600.0 -- This is the max distance around the player the spawn point for a new plane must be.
Config.minAirSpawnDistance = 400.0 -- This is the min distance from the player a spawn point for a new plane must be. 
Config.maxAirSpawnHeight = 300.0 -- This is the max height the spawn point for a new plane must be.
Config.minAirSpawnHeight = 150.0 -- This is the min height the spawn point for a new plane must be.

-- This is the distance an officer operating a vehicle has to be from a player that is on foot before they get out to chase the player on foot.
-- This means they will drive to the player and get within this distance before getting out. If it is too small they will not be able to get out
-- and chase players that went down alley ways / into buildings. If it is too large they will get out too soon.
Config.footChaseDistance = 30.0
---------------------


-- OFFICER CLEANUP TIMERS AND DISTANCES --

-- NOTE: Police vehicles will not be cleaned up if a player is currently occupying them at the time the script attempts to remove them.
-- However it will remove the vehicle from the script's tracking at this time so the currently spawned count is decreased and a replacement can spawn. 
-- This means the vehicle will never be deleted after this.
-- This is to allow the player to steal a police vehicle and not have it disappear mid chase. Or to keep it and use it for any length of time
-- after the chase. If too many vehicles are left in the world it could cause performance issues. 

-- This is the number of seconds that must pass after an officer has died before they are deleted. Officers are tied to their vehicles.
-- A vehicle will only be deleted if all officers assigned to that vehicle are removed. 
Config.deadOfficerCleanupTimer = 45

-- This is how far away an officer must be from the player before the timer to remove them due to distance starts counting down. 
-- The timer will be re-set when they get back within this distance. This is to allow for new units to spawn and chase the player if police get
-- stuck or too far away for too long. The combination of cleanup timers, spawn distances, and cleanup distances will create the police chase experience you get.
-- My default values are to give a more realistic sense. 
-- The randomness of spawn points means reinforcements can still spawn ahead of you and cut you off, but they won't ALWAYS do it like base game.
Config.officerTooFarDistance = 500.0

-- This is the number of seconds that must pass while an officer is too far away from the player before they are deleted. Officers are tied to their vehicles.
-- A vehicle will only be deleted if all officers assigned to that vehicle are removed. 
Config.farOfficerCleanupTimer = 45




-- AIR UNIT CLEANUP TIMERS AND DISTANCES --

-- HELICOPTERS --
-- This is the number of seconds that must pass after a helicopter crew has died before they are deleted. 
Config.deadHeliPilotCleanupTimer = 120 

-- This is how far away a heli crew must be from the player before the timer to remove them due to distance starts counting down.
-- The timer will be re-set when they get back within this distance. 
Config.heliTooFarDistance = 600.0

-- This is the number of seconds that must pass while a heli crew is too far away from the player before they are deleted.
Config.farHeliPilotCleanupTimer = 120 


-- PLANES --
-- This is the number of seconds that must pass after a plane crew has died before they are deleted. 
Config.deadAirPilotCleanupTimer = 120 

-- This is how far away a plane crew must be from the player before the timer to remove them due to distance starts counting down.
-- The timer will be re-set when they get back within this distance. 
Config.planeTooFarDistance = 800.0

-- This is the number of seconds that must pass while a plane crew is too far away from the player before they are deleted.
Config.farAirPilotCleanupTimer = 120 

-- This is the number of seconds that must pass after the player is no longer wanted before officers are deleted.
Config.endWantedCleanupTimer = 5

-- This is the number of times a driver will try to unstick a vehicle before being teleported to the nearest road. 
Config.maxCloseUnstuckAttempts = 4 
Config.maxFarUnstuckAttempts = 4
--------------------



-- ZONE LIST -- 

-- This list maps zones by code to a region and also includes their names. This is used to setup 'districts' and determine what units are dispatched when a player is wanted.
-- This is done using the enum table below this. For eg. we check the player zone, it returns AIRP and we lookup the location and get 'Los Santos.' We check the
-- enum table and get losSantos as the region code using getZoneKey.
-- This can then be used to access the vehiclesByRegion table and select a random vehicle from it that should respond in Los Santos. That vehicle data object has all the info required
-- to spawn the unit and officers.
Config.zones = {
    AIRP = { name = 'Los Santos International Airport', location = 'Los Santos' },
    ALAMO = { name = 'Alamo Sea', location = 'Countryside' },
    ALTA = { name = 'Alta', location = 'Los Santos' },
    ARMYB = { name = 'Fort Zancudo', location = 'Countryside' },
    BANHAMC = { name = 'Banham Canyon Dr', location = 'Countryside' },
    BANNING = { name = 'Banning', location = 'Los Santos' },
    BEACH = { name = 'Vespucci Beach', location = 'Los Santos' },
    BHAMCA = { name = 'Banham Canyon', location = 'Countryside' },
    BRADP = { name = 'Braddock Pass', location = 'Countryside' },
    BRADT = { name = 'Braddock Tunnel', location = 'Countryside' },
    BURTON = { name = 'Burton', location = 'Los Santos' },
    CALAFB = { name = 'Calafia Bridge', location = 'Countryside' },
    CANNY = { name = 'Raton Canyon', location = 'Countryside' },
    CCREAK = { name = 'Cassidy Creek', location = 'Countryside' },
    CHAMH = { name = 'Chamberlain Hills', location = 'Los Santos' },
    CHIL = { name = 'Vinewood Hills', location = 'Los Santos' },
    CHU = { name = 'Chumash', location = 'Countryside' },
    CMSW = { name = 'Chiliad Mountain State Wilderness', location = 'Countryside' },
    CYPRE = { name = 'Cypress Flats', location = 'Los Santos' },
    DAVIS = { name = 'Davis', location = 'Los Santos' },
    DELBE = { name = 'Del Perro Beach', location = 'Los Santos' },
    DELPE = { name = 'Del Perro', location = 'Los Santos' },
    DELSOL = { name = 'La Puerta', location = 'Los Santos' },
    DESRT = { name = 'Grand Senora Desert', location = 'Countryside' },
    DOWNT = { name = 'Downtown', location = 'Los Santos' },
    DTVINE = { name = 'Downtown Vinewood', location = 'Los Santos' },
    EAST_V = { name = 'East Vinewood', location = 'Los Santos' },
    EBuro = { name = 'El Burro Heights', location = 'Los Santos' },
    ELGORL = { name = 'El Gordo Lighthouse', location = 'Countryside' },
    ELYSIAN = { name = 'Elysian Island', location = 'Los Santos' },
    GALFISH = { name = 'Galilee', location = 'Countryside' },
    GOLF = { name = 'GWC and Golfing Society', location = 'Los Santos' },
    GRAPES = { name = 'Grapeseed', location = 'Countryside' },
    GREATC = { name = 'Great Chaparral', location = 'Countryside' },
    HARMO = { name = 'Harmony', location = 'Countryside' },
    HAWICK = { name = 'Hawick', location = 'Los Santos' },
    HORS = { name = 'Vinewood Racetrack', location = 'Los Santos' },
    HUMLAB = { name = 'Humane Labs and Research', location = 'Countryside' },
    JAIL = { name = 'Bolingbroke Penitentiary', location = 'Countryside' },
    KOREAT = { name = 'Little Seoul', location = 'Los Santos' },
    LACT = { name = 'Land Act Reservoir', location = 'Countryside' },
    LAGO = { name = 'Lago Zancudo', location = 'Countryside' },
    LDAM = { name = 'Land Act Dam', location = 'Countryside' },
    LEGSQU = { name = 'Legion Square', location = 'Los Santos' },
    LMESA = { name = 'La Mesa', location = 'Los Santos' },
    LOSPUER = { name = 'La Puerta', location = 'Los Santos' },
    MIRR = { name = 'Mirror Park', location = 'Los Santos' },
    MORN = { name = 'Morningwood', location = 'Los Santos' },
    MOVIE = { name = 'Richards Majestic', location = 'Los Santos' },
    MTCHIL = { name = 'Mount Chiliad', location = 'Countryside' },
    MTGORDO = { name = 'Mount Gordo', location = 'Countryside' },
    MTJOSE = { name = 'Mount Josiah', location = 'Countryside' },
    MURRI = { name = 'Murrieta Heights', location = 'Los Santos' },
    NCHU = { name = 'North Chumash', location = 'Countryside' },
    NOOSE = { name = 'N.O.O.S.E', location = 'Countryside' },
    OCEANA = { name = 'Pacific Ocean', location = 'Countryside' },
    PALCOV = { name = 'Paleto Cove', location = 'Countryside' },
    PALETO = { name = 'Paleto Bay', location = 'Paleto Bay' },
    PALFOR = { name = 'Paleto Forest', location = 'Countryside' },
    PALHIGH = { name = 'Palomino Highlands', location = 'Countryside' },
    PALMPOW = { name = 'Palmer-Taylor Power Station', location = 'Countryside' },
    PBLUFF = { name = 'Pacific Bluffs', location = 'Los Santos' },
    PBOX = { name = 'Pillbox Hill', location = 'Los Santos' },
    PROCOB = { name = 'Procopio Beach', location = 'Countryside' },
    RANCHO = { name = 'Rancho', location = 'Los Santos' },
    RGLEN = { name = 'Richman Glen', location = 'Los Santos' },
    RICHM = { name = 'Richman', location = 'Los Santos' },
    ROCKF = { name = 'Rockford Hills', location = 'Los Santos' },
    RTRAK = { name = 'Redwood Lights Track', location = 'Countryside' },
    SANAND = { name = 'San Andreas', location = 'Los Santos' },
    SANCHIA = { name = 'San Chianski Mountain Range', location = 'Countryside' },
    SANDY = { name = 'Sandy Shores', location = 'Sandy Shores' },
    SKID = { name = 'Mission Row', location = 'Los Santos' },
    SLAB = { name = 'Stab City', location = 'Countryside' },
    STAD = { name = 'Maze Bank Arena', location = 'Los Santos' },
    STRAW = { name = 'Strawberry', location = 'Los Santos' },
    TATAMO = { name = 'Tataviam Mountains', location = 'Countryside' },
    TERMINA = { name = 'Terminal', location = 'Los Santos' },
    TEXTI = { name = 'Textile City', location = 'Los Santos' },
    TONGVAH = { name = 'Tongva Hills', location = 'Countryside' },
    TONGVAV = { name = 'Tongva Valley', location = 'Countryside' },
    VCANA = { name = 'Vespucci Canals', location = 'Los Santos' },
    VESP = { name = 'Vespucci', location = 'Los Santos' },
    VINE = { name = 'Vinewood', location = 'Los Santos' },
    WINDF = { name = 'RON Alternates Wind Farm', location = 'Countryside' },
    WVINE = { name = 'West Vinewood', location = 'Los Santos' },
    ZANCUDO = { name = 'Zancudo River', location = 'Countryside' },
    ZP_ORT = { name = 'Port of South Los Santos', location = 'Los Santos' },
    ZQ_UAR = { name = 'Davis Quartz', location = 'Countryside' }
}

-- The ZoneEnum maps location names from the above table to the Config.vehiclesByRegion key from the table below. 
-- This shouldn't be changed unless you know what you're doing. The location names above, enum list, and Config.vehiclesByRegion must be kept in sync.
-- Make sure any changes you make are reflected in all three. 
Config.ZoneEnum = {
    ['Los Santos'] = 'losSantos',
    ['Paleto Bay'] = 'paletoBay',
    ['Sandy Shores'] = 'sandyShores',
    ['Countryside'] = 'countryside'
}


------------------------


-- VEHICLE AND PED LISTS BY JURISDICTION / REGION --

-- Defines the list of vehicles by region with wanted levels, peds, and spawn chance.
-- The model value should be the model code from the game files. This will be spawned by getting the hash from the model code later.
-- Possible officers to spawn for a vehicle are attached to that car model entry. 
-- Peds should include the model codes for peds you want to possibly spawn with the car, they are selected randomly.
-- primaryWeaponGroup corresponds to the weapon table you'd like the primary weapon from. Peds will always have a primary weapon.
-- secondaryWeaponGroup corresponds to the weapon table you'd like the 
Config.vehiclesByRegion = {
    losSantos = {
        { model = 'police', peds = {'s_m_y_cop_01', 's_f_y_cop_01'}, wantedLevel = 1, spawnChance = 5, numPeds = 2, loadout = 'patrol' },
        { model = 'police2', peds = {'s_m_y_cop_01', 's_f_y_cop_01'}, wantedLevel = 1, spawnChance = 5, numPeds = 2, loadout = 'patrol'  },
        { model = 'police3', peds = {'s_m_y_cop_01', 's_f_y_cop_01'}, wantedLevel = 1, spawnChance = 2, numPeds = 2, loadout = 'patrol'  },
        { model = 'police4', peds = {'S_M_M_CIASec_01'}, wantedLevel = 2, spawnChance = 3, numPeds = 2, loadout = 'undercover'  },
        -- [Upstate Mafia] policet (police transporter) removed entirely
        { model = 'police3', peds = {'S_M_M_CIASec_01'}, wantedLevel = 2, spawnChance = 3, numPeds = 2, loadout = 'undercover' },
        { model = 'riot', peds = {'S_M_Y_Swat_01'}, wantedLevel = 5, spawnChance = 3, numPeds = 4, loadout = 'riot' },
        { model = 'fbi', peds = {'S_M_M_FIBSec_01'}, wantedLevel = 5, spawnChance = 5, numPeds = 2, loadout = 'fbi' },
        { model = 'fbi2', peds = {'S_M_M_FIBSec_01'}, wantedLevel = 5, spawnChance = 5, numPeds = 4, loadout = 'fbi' },

    },
    -- [Upstate Mafia] Rebalanced: riot at wantedLevel=5 only, sheriff boosted, FBI reduced
    paletoBay = {
        { model = 'policeb', peds = {'S_M_Y_HwayCop_01'}, wantedLevel = 1, spawnChance = 2, numPeds = 1, loadout = 'bike' },
        { model = 'sheriff', peds = {'s_m_y_sheriff_01', 's_f_y_sheriff_01'}, wantedLevel = 1, spawnChance = 5, numPeds = 2, loadout = 'sheriff' },
        { model = 'sheriff2', peds = {'s_m_y_sheriff_01', 's_f_y_sheriff_01'}, wantedLevel = 1, spawnChance = 5, numPeds = 2, loadout = 'sheriff' },
        { model = 'police3', peds = {'S_M_M_CIASec_01'}, wantedLevel = 2, spawnChance = 3, numPeds = 2, loadout = 'undercover' },
        { model = 'riot', peds = {'S_M_Y_Swat_01'}, wantedLevel = 5, spawnChance = 3, numPeds = 4, loadout = 'riot' },
        { model = 'fbi', peds = {'S_M_M_FIBSec_01'}, wantedLevel = 5, spawnChance = 5, numPeds = 2, loadout = 'fbi' },
        { model = 'fbi2', peds = {'S_M_M_FIBSec_01'}, wantedLevel = 5, spawnChance = 5, numPeds = 4, loadout = 'fbi' },
    },
    -- [Upstate Mafia] Rebalanced: riot at wantedLevel=5 only, sheriff boosted, FBI reduced
    sandyShores = {
        { model = 'policeb', peds = {'S_M_Y_HwayCop_01'}, wantedLevel = 1, spawnChance = 2, numPeds = 1, loadout = 'bike' },
        { model = 'sheriff', peds = {'s_m_y_sheriff_01', 's_f_y_sheriff_01'}, wantedLevel = 1, spawnChance = 5, numPeds = 2, loadout = 'sheriff' },
        { model = 'sheriff2', peds = {'s_m_y_sheriff_01', 's_f_y_sheriff_01'}, wantedLevel = 1, spawnChance = 5, numPeds = 2, loadout = 'sheriff' },
        { model = 'police3', peds = {'S_M_M_CIASec_01'}, wantedLevel = 2, spawnChance = 3, numPeds = 2, loadout = 'undercover' },
        { model = 'riot', peds = {'S_M_Y_Swat_01'}, wantedLevel = 5, spawnChance = 3, numPeds = 4, loadout = 'riot' },
        { model = 'fbi', peds = {'S_M_M_FIBSec_01'}, wantedLevel = 5, spawnChance = 5, numPeds = 2, loadout = 'fbi' },
        { model = 'fbi2', peds = {'S_M_M_FIBSec_01'}, wantedLevel = 5, spawnChance = 5, numPeds = 4, loadout = 'fbi' },
    },
    -- [Upstate Mafia] Rebalanced: riot at wantedLevel=5 only, sheriff/ranger boosted, FBI reduced
    countryside = {
        { model = 'policeb', peds = {'S_M_Y_HwayCop_01'}, wantedLevel = 1, spawnChance = 2, numPeds = 1, loadout = 'bike' },
        { model = 'sheriff', peds = {'s_m_y_sheriff_01', 's_f_y_sheriff_01'}, wantedLevel = 1, spawnChance = 4, numPeds = 2, loadout = 'sheriff' },
        { model = 'sheriff2', peds = {'s_m_y_sheriff_01', 's_f_y_sheriff_01'}, wantedLevel = 1, spawnChance = 4, numPeds = 2, loadout = 'sheriff' },
        { model = 'pranger', peds = { 's_m_y_ranger_01', 's_f_y_ranger_01'}, wantedLevel = 1, spawnChance = 8, numPeds = 2, loadout = 'ranger' },
        { model = 'police4', peds = {'S_M_M_CIASec_01'}, wantedLevel = 2, spawnChance = 3, numPeds = 2, loadout = 'undercover' },
        { model = 'police3', peds = {'S_M_M_CIASec_01'}, wantedLevel = 2, spawnChance = 4, numPeds = 2, loadout = 'undercover' },
        { model = 'riot', peds = {'S_M_Y_Swat_01'}, wantedLevel = 5, spawnChance = 3, numPeds = 4, loadout = 'riot' },
        { model = 'fbi', peds = {'S_M_M_FIBSec_01'}, wantedLevel = 5, spawnChance = 5, numPeds = 2, loadout = 'fbi' },
        { model = 'fbi2', peds = {'S_M_M_FIBSec_01'}, wantedLevel = 5, spawnChance = 5, numPeds = 4, loadout = 'fbi' },
    }
}

Config.polHelis = {
    { model = 'polmav', pilots = {"S_M_M_Pilot_02"}, numPilots = 2, peds = {'s_m_y_cop_01', 's_f_y_cop_01'}, numPeds = 2, wantedLevel = 3, spawnChance = 1, loadout = 'airPatrol' },   
    { model = 'buzzard2', pilots = {"S_M_M_Pilot_02"}, numPilots = 2, peds = {'S_M_M_CIASec_01'}, numPeds = 2, wantedLevel = 3, spawnChance = 1, loadout = 'airPatrol' },   
    { model = 'polmav', pilots = {"S_M_M_Pilot_02"}, numPilots = 2, peds = {'S_M_Y_Swat_01'}, numPeds = 2, wantedLevel = 4, spawnChance = 1, loadout = 'airPatrol' }, 
}

Config.milHelis = {
    { model = 'hunter', pilots = {"S_M_M_Pilot_02"}, numPilots = 2, peds = {}, numPeds = 0, wantedLevel = 4, spawnChance = 1, loadout = 'airPatrol' },   
}

Config.milPlanes = {
    { model = 'lazer', pilots = {"S_M_M_Pilot_02"}, numPilots = 1, peds = {}, numPeds = 0, wantedLevel = 4, spawnChance = 1, loadout = 'airPatrol' }, 
}




-- OFFICER LOADOUTS --

Config.loadouts = {
    patrol = {
        primaryWeapons = {
            { name = 'weapon_pistol', weight = 3 },
            { name = 'weapon_combatpistol', weight = 1 },
        },
        secondaryWeapons = {
            { name = 'weapon_pumpshotgun', weight = 4 },
        },
        secondaryChance = 0.15,
        armorChance = 0.5,
        armorValue = 40,
        armorModel = 'prop_bodyarmour_03',
        helmetChance = 0.0,
        helmetModel = 0,
    },
    sheriff = {
        primaryWeapons = {
            { name = 'weapon_pistol', weight = 3 },
            { name = 'weapon_heavypistol', weight = 1 },
        },
        secondaryWeapons = {
            { name = 'weapon_pumpshotgun', weight = 4 },
            { name = 'weapon_carbinerifle', weight = 1 },
        },
        secondaryChance = 0.15,
        armorChance = 0.5,
        armorValue = 40,
        armorModel = 'prop_bodyarmour_04',
        helmetChance = 0.0,
        helmetModel = 0,
    },
    undercover = {
        primaryWeapons = {
            { name = 'weapon_pistol_mk2', weight = 2 },
            { name = 'weapon_heavypistol', weight = 1 },
            { name = 'weapon_snspistol', weight = 2 },
            { name = 'weapon_pistol50', weight = 1 },
        },
        secondaryWeapons = {
            { name = 'weapon_pumpshotgun', weight = 1 },
            { name = 'weapon_carbinerifle', weight = 2 },
            { name = 'weapon_smg', weight = 2 },
        },
        secondaryChance = 0.25,
        armorChance = 1.0,
        armorValue = 40,
        armorModel = 'prop_bodyarmour_04',
        helmetChance = 0.0,
        helmetModel = 0,
    },
    bike = {
        primaryWeapons = {
            { name = 'weapon_revolver', weight = 1 },
            { name = 'weapon_combatpistol', weight = 1 },
            { name = 'weapon_snspistol', weight = 1 },
            { name = 'weapon_doubleaction', weight = 1 },
        },
        secondaryWeapons = {},
        secondaryChance = 0.0,
        armorChance = 0.0,
        armorValue = 40,
        armorModel = 'prop_bodyarmour_03',
        helmetChance = 1.0,
        helmetModel = 0, -- In theory -1 is disabled, 0 would be the first variation. The bike model should have only one helmet variation and thus 0 should work. 
    },
    ranger = {
        primaryWeapons = {
            { name = 'weapon_heavypistol', weight = 3 },
            { name = 'weapon_pistol_mk2', weight = 1 },
        },
        secondaryWeapons = {
            { name = 'weapon_pumpshotgun', weight = 6 },
            { name = 'weapon_carbinerifle', weight = 2 },
            { name = 'weapon_marksmanrifle', weight = 1 },
        },
        secondaryChance = 0.5,
        armorChance = 0.5,
        armorValue = 40,
        armorModel = 'prop_bodyarmour_04',
        helmetChance = 0.0,
        helmetModel = 0,
    },
    fbi = {
        primaryWeapons = {
            { name = 'weapon_pistol_mk2', weight = 3 },
            { name = 'weapon_heavypistol', weight = 1 },
        },
        secondaryWeapons = {
            { name = 'weapon_combatpdw', weight = 2 },
            { name = 'weapon_carbinerifle_mk2', weight = 1 },
            { name = 'weapon_assaultshotgun', weight = 1 },
            
        },
        secondaryChance = 0.8,
        armorChance = 1.0,
        armorValue = 60,
        armorModel = 'prop_bodyarmour_03',
        helmetChance = 0.0,
        helmetModel = 0,
    },
    riot = {
        primaryWeapons = {
            { name = 'weapon_combatpistol', weight = 2 },
            { name = 'weapon_heavypistol', weight = 1 },
        },
        secondaryWeapons = {
            { name = 'weapon_carbinerifle', weight = 2 },
            { name = 'weapon_smg', weight = 3 },
            { name = 'weapon_combatshotgun', weight = 2 },
            { name = 'weapon_marksmanrifle', weight = 1 },
        },
        secondaryChance = 1.0,
        armorChance = 1.0,
        armorValue = 80,
        armorModel = 'prop_bodyarmour_03',
        helmetChance = 1.0,
        helmetModel = 0, -- In theory -1 is disabled, 0 would be the first variation. The SWAT model should have only one helmet variation and thus 0 should work. 
    },
    airPatrol = {
        primaryWeapons = {
            { name = 'weapon_pistol', weight = 3 },
            { name = 'weapon_combatpistol', weight = 1 },
        },
        secondaryWeapons = {
            { name = 'weapon_smg', weight = 1 },
        },
        secondaryChance = 0.15,
        armorChance = 0.5,
        armorValue = 40,
        armorModel = 'prop_bodyarmour_03',
        helmetChance = 0.0,
        helmetModel = 0,
    },
}


--known locations
--these are locations pulled from other qb files to make a list of kown places and a setting a wanted level

Config.locations = {
    [1] = { vector3(-47.24, -1757.65, 29.53), type = 'Registers', wanted = 1},
    [2] = { vector3(-48.58, -1759.21, 29.59), type = 'Registers', wanted = 1 },
    [3] = { vector3(-1486.26, -378.0, 40.16), type = 'Registers', wanted = 1 },
    [4] = { vector3(-1222.03, -908.32, 12.32), type = 'Registers', wanted = 1 },
    [5] = { vector3(-706.08, -915.42, 19.21), type = 'Registers', wanted = 1 },
    [6] = { vector3(-706.16, -913.5, 19.21), type = 'Registers', wanted = 1 },
    [7] = { vector3(24.47, -1344.99, 29.49), type = 'Registers', wanted = 1 },
    [8] = { vector3(24.45, -1347.37, 29.49), type = 'Registers', wanted = 1 },
    [9] = { vector3(1134.15, -982.53, 46.41), type = 'Registers', wanted = 1 },
    [10] = { vector3(1165.05, -324.49, 69.2), type = 'Registers', wanted = 1 },
    [11] = { vector3(1164.7, -322.58, 69.2), type = 'Registers', wanted = 1 },
    [12] = { vector3(373.14, 328.62, 103.56), type = 'Registers', wanted = 1 },
    [13] = { vector3(372.57, 326.42, 103.56), type = 'Registers', wanted = 1 },
    [14] = { vector3(-1818.9, 792.9, 138.08), type = 'Registers', wanted = 1 },
    [15] = { vector3(-1820.17, 794.28, 138.08), type = 'Registers', wanted = 1 },
    [16] = { vector3(-2966.46, 390.89, 15.04), type = 'Registers', wanted = 1 },
    [17] = { vector3(-3041.14, 583.87, 7.9), type = 'Registers', wanted = 1 },
    [18] = { vector3(-3038.92, 584.5, 7.9), type = 'Registers', wanted = 1 },
    [19] = { vector3(-3244.56, 1000.14, 12.83), type = 'Registers', wanted = 1 },
    [20] = { vector3(-3242.24, 999.98, 12.83), type = 'Registers', wanted = 1 },
    [21] = { vector3(549.42, 2669.06, 42.15), type = 'Registers', wanted = 1 },
    [22] = { vector3(549.05, 2671.39, 42.15), type = 'Registers', wanted = 1 },
    [23] = { vector3(1165.9, 2710.81, 38.15), type = 'Registers', wanted = 1 },
    [24] = { vector3(2676.02, 3280.52, 55.24), type = 'Registers', wanted = 1 },
    [25] = { vector3(2678.07, 3279.39, 55.24), type = 'Registers', wanted = 1 },
    [26] = { vector3(1958.96, 3741.98, 32.34), type = 'Registers', wanted = 1 },
    [27] = { vector3(1960.13, 3740.0, 32.34), type = 'Registers', wanted = 1 },
    [28] = { vector3(1728.86, 6417.26, 35.03), type = 'Registers', wanted = 1 },
    [29] = { vector3(1727.85, 6415.14, 35.03), type = 'Registers', wanted = 1 },
    [30] = { vector3(-161.07, 6321.23, 31.5), type = 'Registers', wanted = 1 },
    [31] = { vector3(160.52, 6641.74, 31.6), type = 'Registers', wanted = 1 },
    [32] = { vector3(162.16, 6643.22, 31.6), type = 'Registers', wanted = 1 },
    [33] = { vector3(-43.43, -1748.3, 29.42), type = 'Safes', wanted = 1 },
    [34] = { vector3(-1478.94, -375.5, 39.16), type = 'Safes', wanted = 1 },
    [35] = { vector3(-1220.85, -916.05, 11.32), type = 'Safes', wanted = 1 },
    [36] = { vector3(-709.74, -904.15, 19.21), type = 'Safes', wanted = 1 },
    [37] = { vector3(28.21, -1339.14, 29.49), type = 'Safes', wanted = 1 },
    [38] = { vector3(1126.77, -980.1, 45.41), type = 'Safes', wanted = 1 },
    [39] = { vector3(1159.46, -314.05, 69.2), type = 'Safes', wanted = 1 },
    [40] = { vector3(378.17, 333.44, 103.56), type = 'Safes', wanted = 1 },
    [41] = { vector3(-1829.27, 798.76, 138.19), type = 'Safes', wanted = 1 },
    [42] = { vector3(-2959.64, 387.08, 14.04), type = 'Safes', wanted = 1 },
    [43] = { vector3(-3047.88, 585.61, 7.9), type = 'Safes', wanted = 1 },
    [44] = { vector3(-3250.02, 1004.43, 12.83), type = 'Safes', wanted = 1 },
    [45] = { vector3(546.41, 2662.8, 42.15), type = 'Safes', wanted = 1 },
    [46] = { vector3(1169.31, 2717.79, 37.15), type = 'Safes', wanted = 1 },
    [47] = { vector3(2672.69, 3286.63, 55.24), type = 'Safes', wanted = 1 },
    [48] = { vector3(1959.26, 3748.92, 32.34), type = 'Safes', wanted = 1 },
    [49] = { vector3(1734.78, 6420.84, 35.03), type = 'Safes', wanted = 1 },
    [50] = { vector3(-168.40, 6318.80, 30.58), type = 'Safes', wanted = 1 },
    [51] = { vector3(168.95, 6644.74, 31.70), type = 'Safes', wanted = 1 },
    [52] = { vector3(-630.5, -237.13, 38.08),type = 'jewelery', wanted = 3},
}


------------------------
