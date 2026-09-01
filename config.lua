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

-- The engine's own wanted-level CEILING (SET_MAX_WANTED_LEVEL), not this
-- resource's own settings. If this ever reads back as 0 (see /fenix:diag),
-- GetPlayerWantedLevel can never rise above 0 no matter what sets it --
-- native crimes, ApplyWantedLevel, even a manual SetPlayerWantedLevel are all
-- silently clamped. Re-applied every cycle in the main thread rather than
-- only reactively, for exactly that reason.
Config.MaxWantedLevel = 5

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

    -- How many ambient scenes may exist at once. Each scene is 1-3 vehicles and
    -- 1-4 peds, so keep this low.
    --
    -- Lowered from 4. Four scenes inside a 220m maxSpawnDistance is close to
    -- one every couple of blocks in a dense area — enough that turning a
    -- corner into a fresh one felt less like a city with police in it and more
    -- like the slots were always full.
    maxScenes = 3,

    -- Seconds between scene spawn attempts.
    --
    -- Raised from 8. At 8s with maxScenes=4 the scene population barely has
    -- time to fall before the next attempt tops it back up, and reports were
    -- "a cop every corner, most corners" — closer to filling every open slot
    -- than to ambient presence. This alone is the biggest lever on how often
    -- you encounter something; maxScenes and maxNearbyCops below cap how much
    -- is on screen at once, but this caps how fast a gap gets refilled.
    spawnInterval = 15,

    -- A scene must spawn between these distances from the player, and is deleted
    -- past cleanupDistance. Fixed-point scenes are also deleted when their point
    -- goes out of range, and re-spawn when you come back.
    minSpawnDistance = 70.0,
    maxSpawnDistance = 220.0,
    cleanupDistance  = 320.0,

    -- Roaming scenes are torn down after this many seconds regardless of distance
    -- so patrols and pursuits keep cycling instead of following you forever.
    --
    -- Lowered from 180. This is also how often a `patrol` gives its scene slot
    -- back — at maxScenes=3, a patrol camping a slot for three minutes is three
    -- minutes `stop` and `pursuit` cannot even attempt to spawn.
    roamingLifetime = 130,

    -- ── Pursuits ────────────────────────────────────────────────────────────
    -- A pursuit is an event, not background traffic. The scene weight alone
    -- can't express "rare but memorable", so this is a hard floor between them
    -- regardless of how the weighted roll lands.
    --
    -- Lowered from 300 for the same reason as stopCooldownSeconds: the
    -- 8s/4-scene cadence this was tuned against no longer exists, and 5 minutes
    -- on top of a slot that's already hard to win made a pursuit a rare sight
    -- rather than an occasional one.
    pursuitCooldownSeconds = 220,

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

    -- ── Convoys ─────────────────────────────────────────────────────────────
    -- Two or three cruisers travelling the same road together, lights and
    -- sirens off — the "cops driving in a group, no lights" sight, done on
    -- purpose instead of by three independent scenes drifting together. Reads
    -- as backup en route to a call that never renders.
    --
    -- Minimum seconds between convoys. A group is a more noticeable sight than
    -- a single patrol car, so it gets its own floor the same way stop and
    -- pursuit do — otherwise the weight alone can make them common instead of
    -- occasional.
    convoyCooldownSeconds = 240,

    -- Chance the group is three cars instead of two.
    convoyThirdCarChance = 0.35,

    -- Nose-to-tail spacing between cars in the group, in metres.
    convoySpacing = 9.0,

    -- Seconds before the group is torn down regardless of distance. Falls back
    -- to roamingLifetime when unset.
    convoyLifetime = 150,

    -- Minimum seconds between traffic stops, for the same reason pursuits have
    -- one: the weights cannot express "occasional".
    --
    -- `stop` is only 3 of 15, which sounds rare until you notice a radar trap
    -- that clocks someone ALSO ends as a cruiser stopped behind a civilian car.
    -- The two read as the same scene to a player, so the effective rate is
    -- closer to 6 of 15, and with a spawn attempt every 8 seconds that becomes
    -- a stop around every corner. This puts a floor between them instead.
    --
    -- Raise it if stops still feel constant; 0 restores the old behaviour.
    --
    -- Lowered from 150. That value assumed the original 8s/4-scene cadence;
    -- spawnInterval alone is now 15s with a 3-scene cap, which already throttles
    -- how often anything spawns. Leaving the old cooldown on top of the new
    -- density settings was two brakes doing one job, and `stop` in particular
    -- needs its retries: the player can drive past a stop parked on the verge
    -- without ever registering it happened, and there was nothing to make a
    -- missed one try again soon.
    stopCooldownSeconds = 100,

    -- ── Placement quality ───────────────────────────────────────────────────
    -- Candidate road nodes sampled per spawn attempt. The best-scoring one wins
    -- rather than the first that happens to be in range, which is what keeps
    -- scenes off junctions, out of traffic and away from dead-end dirt tracks.
    -- Each sample is one cheap native call; 10 is plenty.
    -- Raised from 10 when road placement landed: candidates now have to clear
    -- lane geometry, the no-go zones and a reachability test, so more of them
    -- are rejected. Each sample is a handful of natives run once per spawn tick,
    -- not per frame.
    nodeSamples = 20,

    -- Minimum distance between two ambient scenes. Stops them clumping into a
    -- police convention on one street.
    --
    -- Raised from 90 for the same reason as spawnInterval and maxScenes: three
    -- separate scenes 90m apart on the same road reads as one big encounter,
    -- not three small ones. If you want a deliberate multi-car look, that's
    -- now the `convoy` scene below rather than an accidental overlap of
    -- `patrol` and `stop`.
    minSceneSpacing = 120.0,

    -- Hard ceiling on ambient OFFICERS within nearbyRadius of the player, on top
    -- of maxScenes. A couple of 4-officer foot posts reach "too many cops" long
    -- before the scene cap does. Counted from the scenes this script already
    -- owns during the cull pass — no world scans, no extra bookkeeping.
    --
    -- Lowered from 6 alongside maxScenes and spawnInterval, then raised back
    -- partway to 5: at 4, a single 3-car `convoy` came within one officer of
    -- the whole area budget on its own, which was blocking `pursuit` (1-2
    -- officers) and `stop` (1 officer) from spawning even when a scene slot
    -- was free. 5 leaves room for one of those alongside a convoy without
    -- undoing the reason this was lowered in the first place.
    maxNearbyCops = 5,
    nearbyRadius  = 260.0,

    -- Superseded by Config.Roads.shoulderOffset, below. That one is measured
    -- from the edge of the carriageway rather than from the centre line, which
    -- is the only way to get a verge that works on both a two-lane street and a
    -- six-lane boulevard. Left here so an existing config.local/ override is
    -- obvious rather than silently ignored — it is not read any more.
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

        -- [Upstate Mafia] Signal-and-follow grace period before a radar catch
        -- turns into a real pursuit. The wanted level still applies immediately
        -- (that's what makes the existing surrender/ticket flow -- beginPullOver
        -- in client.lua -- available), but the catching officer starts calm:
        -- lights and siren, low aggressiveness, a following distance rather than
        -- a bumper-lock. Only once the driver keeps speeding past this window
        -- does the officer switch to the same aggressive TaskVehicleChase a real
        -- pursuit uses. Slowing below pulloverStoppedMph at any point holds the
        -- calm behaviour indefinitely -- no reason to escalate on someone who is
        -- visibly complying.
        pulloverGraceMs        = 12000,
        pulloverStoppedMph     = 8.0,
        pulloverAggressiveness = 0.15,
        pulloverDistance       = 20.0, -- metres, following distance during the calm phase

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
    --
    -- Rebalanced toward `stop` and `pursuit` after the density pass above made
    -- them close to invisible. The weight was never really the problem —
    -- `patrol` and `convoy` are long-lived (roamingLifetime / convoyLifetime,
    -- 130-150s) and have no cooldown of their own, so once maxScenes=3 fills
    -- with a mix of those plus `radar`/`post`, no new spawn ATTEMPT happens at
    -- all until one expires. `stop` and `pursuit` only ever get a shot at that
    -- rare open slot, on top of needing to be off their own cooldown (below) —
    -- a much narrower window that kept losing to whatever filler was already
    -- parked. This raises their odds of winning the roll when a slot IS free,
    -- which is a variety fix, not a frequency one: overall encounter rate is
    -- still governed entirely by spawnInterval/maxScenes/minSceneSpacing/
    -- maxNearbyCops above, none of which this touches.
    weights = {
        radar    = 2,  -- cruiser parked facing traffic, officer inside
        stop     = 4,  -- NPC pulled over, officer at the driver's window
        patrol   = 2,  -- cruiser driving a normal route, no siren
        convoy   = 1,  -- 2-3 cruisers travelling together, no lights — see below
        post     = 2,  -- officers on foot at a station/landmark doing scenarios
        pursuit  = 2,  -- NPC vehicle fleeing, cruisers chasing with sirens
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
    --
    -- Two accepted shapes per region:
    --   array  { 'police', 'police2' }        picked uniformly
    --   map    { police = 4, police2 = 1 }    model -> relative weight
    --
    -- Base-game models only, deliberately: this ships as stock so it works on any
    -- server. The map form exists for add-on liveries — weights are how you get
    -- one agency dominant in a region while another still turns up occasionally,
    -- without hard-coded region rules. For example, if you ran a highway-patrol
    -- pack and a sheriff pack:
    --
    --   sandyShores = {
    --       ['yoursheriff_suv'] = 6,   -- the county's own units carry the region
    --       ['yoursheriff_sedan'] = 4,
    --       ['yourhwp_charger'] = 2,   -- highway patrol passes through
    --       ['yourhwp_suv'] = 2,
    --   },
    --
    -- A model that isn't installed is skipped when the pick is rolled rather than
    -- failing the spawn, so a mixed list degrades to whatever you actually have.
    -- If a region resolves to nothing installed at all, vehicleFallback below is
    -- used — which is what makes it safe to point this at packs without checking
    -- that every client has them.
    vehicles = {
        losSantos   = { 'police', 'police2', 'police3' },
        paletoBay   = { 'sheriff', 'sheriff2' },
        sandyShores = { 'sheriff', 'sheriff2' },
        countryside = { 'sheriff', 'sheriff2', 'pranger' },
    },

    -- Used only when nothing in `vehicles` for the region resolves to a model
    -- this client can spawn. Keep these to base-game models — the whole point is
    -- that they are always there.
    vehicleFallback = {
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


-- AFTERMATH: FIELD REVIVE / SCENE HOLD --
-- What responding officers do once the player actually goes down, instead of
-- the wanted level clearing and every unit despawning within a couple of
-- ticks. See client.lua's beginAftermath()/attemptFieldRevive() for the
-- actual sequence -- this is deliberately not a replacement for real EMS
-- (ps-dispatch's own automatic PlayerDowned alert already handles that): a
-- failed field revive just holds the scene, it never calls anyone itself.
Config.Aftermath = {
    -- [Upstate Mafia] Disabled: still fighting the pursuit AI after several
    -- rounds of fixes (watchdog, server-side re-tasking, other units staying
    -- hostile) rather than actually behaving. Turned off so death goes back
    -- to the previous instant-despawn behaviour. The rest of the feature is
    -- left in place, not deleted, in case it's worth debugging further later.
    enabled = false,

    -- How far to look for ground officers to respond, in metres. Air/heli
    -- units never respond -- nobody lands a helicopter to perform CPR.
    responseRange = 60.0,

    -- The nearest responding officer's chance of a successful field revive.
    -- Kept low and deliberate: this is a coin-flip exception, not a way to
    -- skip EMS outright. 0 disables field revives entirely -- officers still
    -- hold the scene, they just never attempt one.
    reviveChance = 0.35,

    -- How close the officer has to be to the player before starting the
    -- kneel-and-work animation, and how long that animation runs before the
    -- reviveChance roll resolves, in ms.
    reviveRange    = 8.0,
    reviveDuration = 8000,

    -- How long a failed attempt holds the scene (nearby units parked, lights
    -- on, waiting) before giving up and letting the normal despawn path run,
    -- in ms. Not a guarantee EMS shows up in this window, just a cap so
    -- units don't hold forever if nobody answers the dispatch alert.
    holdAfterFailedMs = 240000,
}


-- TRAFFIC TICKET SYSTEM --
-- The roadside alternative to being taken in, on the same key (default H).
-- Where you are decides which one you get:
--
--   on foot, wanted          hands up, cuffs, BUSTED screen, station
--   driving, low wanted      hazards on, officer at your window, citation, drive away
--
-- This exists because an arrest teleports you to a station, which ends whatever
-- you were in the middle of — and the offence that most often triggers one is
-- speeding past a radar trap on a run you were halfway through. A citation costs
-- money instead of progress, which is the trade a traffic offence should be.
Config.TicketSystem = {
    enabled = true,

    -- Highest wanted level still settleable at the roadside. 1 keeps it to what
    -- a radar trap issues (Config.Ambient.radar.playerWantedLevel) — a genuine
    -- traffic offence. Raise to 2 if you want it to cover the reckless driving
    -- that GTA escalates into on its own; above that, an officer writing a
    -- citation instead of making an arrest stops being believable.
    maxWantedLevel = 1,

    -- A citation is for driving. Passengers aren't the ones being cited, and on
    -- foot is the surrender path, so both fall through to the arrest system.
    driverOnly = true,

    -- Shots fired is not a traffic stop. Once you have fired on police the
    -- option is gone for the rest of the pursuit.
    denyAfterShooting = true,

    -- Speed (mph) at or below which your vehicle counts as stopped. Nobody gets
    -- out of a car until you're under this — the arrest system already learned
    -- what pulling a ped out of a moving vehicle does to them.
    stoppedSpeedMph = 3.0,

    -- Having stopped, pull away faster than this and the stop is off: you're
    -- fleeing, and the pursuit picks straight back up where it left off.
    fleeSpeedMph = 12.0,

    -- Abandon a stop that never happens — you signalled on a road no unit can
    -- reach, or the response despawned around you. Seconds.
    timeoutSeconds = 90,

    -- How close the responding UNIT must be before it stops and sends an officer
    -- out on foot, and how close that officer must get to your window before
    -- they start writing.
    approachDistance = 40.0,
    windowDistance   = 3.5,

    -- How long the officer spends at the window before handing it over.
    writeSeconds = 8,

    -- Grace period between the citation and the wanted level clearing. The
    -- cleanup sweep deletes every spawned unit the moment you stop being wanted,
    -- so without this the car parked behind you blinks out of existence while
    -- you're looking at it. This is how long they get to drive off first.
    dispersalSeconds = 6,

    -- The fine. Computed and charged SERVER-side from these values: the client
    -- says it was stopped and at what wanted level, never what it is willing to
    -- pay. Set enabled = false for a warning-only stop that costs nothing.
    fine = {
        enabled = true,

        -- Indexed by wanted level at the time of the stop. Levels past the end
        -- of this list use the last entry, so it only needs to be as long as
        -- maxWantedLevel.
        amounts = { 750, 2000, 4000, 6000, 9000 },

        -- Charged here first, then cash if fallbackToCash is on.
        account = 'bank',
        fallbackToCash = true,

        -- Can't cover it? The stop still ends and you still drive away — an
        -- officer doesn't arrest you over an unpaid citation, and turning "you're
        -- broke" into a teleport to jail is exactly the outcome this avoids.
        -- Set false to charge whatever you can and treat the rest as written off.
        allowUnpaid = true,

        -- Reason string on the transaction, for anything reading money logs.
        reason = 'traffic-citation',
    },

    -- Player-facing text. %s in `issued` / `unpaid` is the amount.
    messages = {
        prompt   = 'Pull over and stop. Wait for the officer.',
        hint     = 'Stopping for police — press the surrender key again to cancel',
        writing  = 'The officer is writing your citation...',
        issued   = 'Citation issued: $%s. You are free to go.',
        unpaid   = 'Citation issued: $%s — unpaid, on record.',
        warning  = 'Verbal warning issued. You are free to go.',
        serious  = 'Too serious for a citation — they want you out of the car.',
        fled     = 'You pulled away from the stop.',
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




-- SERVER-SIDE ENTITY SECURITY --
--
-- Read by server/guard.lua. Every mutating net event in server/server.lua used
-- to take a network ID straight off the wire and act on whatever it resolved to:
-- delete any entity, unlock any vehicle, arm any ped. Network IDs are small
-- integers, so none of that needed guessing, only counting.
--
-- Three layers, and only the third is configurable:
--   1. A player's ped, or a vehicle a player is sitting in, is always refused.
--   2. The entity's model must be one this resource is configured to spawn.
--      This is the layer that closes the serious hole, and it needs nothing
--      from the client to be true.
--   3. Entities are recorded against the player they were spawned for.

Config.Security = {
    -- Log every refusal to the server console. Worth leaving on: the first thing
    -- you want when somebody starts probing net IDs is to know it is happening.
    logRefusals = true,

    -- Extra detail: allowlist size at boot, unit registrations as they land.
    debug = false,

    -- Require an ownership record before acting on an entity.
    --
    -- Left OFF by default. With layers 1 and 2 in place, the worst an unowned
    -- entity permits is one player interfering with another player's police
    -- units -- griefing, not theft -- and turning this on before you have
    -- confirmed registration works on your server converts every gap into a
    -- police car that never gets cleaned up. Turn it on once `fenixguard` in the
    -- server console shows entities being owned during a pursuit.
    strictOwnership = false,

    -- Seconds a spawn ticket stays valid. A ticket is issued when the server
    -- authorises a ground spawn and consumed when the client reports back what
    -- it built; this only has to cover model loading on a slow client.
    ticketLifetime = 30,

    -- Ceiling on how many entities one player can have recorded at once. The
    -- backstop against a client that passes every other check and simply asks
    -- for units forever. Config.maxUnitsPerLevel tops out at 10 vehicles with
    -- crews, so this has a lot of headroom before it can bite legitimately.
    maxOwnedEntities = 60,

    -- Requests per player per minute, per event group. These events are not
    -- called at remotely similar rates: `spawn` is a deliberate request made a
    -- handful of times a minute, `unlock` and `rearm` fire from the chase loop
    -- once per officer per cycle, and `delete` arrives in bursts of thirty when
    -- a pursuit ends and the cleanup sweep runs five passes over ten units and
    -- their crews.
    --
    -- Too tight is worse than absent: a refused delete is a police car left in
    -- the world forever. These exist to stop a loop, not to meter normal play,
    -- so they sit far above anything legitimate. Set one to 0 to disable it.
    rateLimits = {
        spawn    = 60,
        register = 60,
        delete   = 600,
        unlock   = 600,
        rearm    = 600,
        alert    = 30,
    },

    -- Fallback for any event group not named above.
    maxRequestsPerMinute = 300,

    -- `fenix:server:trigger` applies a wanted level to everyone standing near a
    -- reported crime, and took the crime's coordinates from the client. Any
    -- client could therefore pick a victim anywhere on the map and star them --
    -- a wanted-level cannon aimed by whoever sent the event.
    --
    -- A player reporting a crime is reporting one they are AT, so coordinates
    -- further than this from the caller are refused. Raise it if a resource of
    -- yours legitimately reports crimes from a distance; 0 disables the check.
    -- Calls from another resource server-side skip it either way, since there is
    -- no caller to measure against.
    maxAlertDistance = 100.0,

    -- Models to allowlist that the config tables above don't mention. You only
    -- need these if something outside Config.vehiclesByRegion / Config.polHelis
    -- / Config.milHelis / Config.milPlanes spawns police entities through this
    -- resource's server events.
    extraVehicles = {},
    extraPeds     = {},
}


-- PURSUIT PERCEPTION --
--
-- Read by client/pursuit.lua. See that file's header for the reasoning; the
-- short version is that the chase loop used to re-task every unit to the
-- player's live coordinates once a second, so officers were omniscient and
-- hiding was a countdown rather than a thing you did.

Config.Pursuit = {
    enabled = true,

    -- Prints contact transitions and every radio call.
    debug = false,

    -- How often the "can anybody see the player" pass runs, in ms. The main
    -- pursuit loop is 1000ms, which is far too coarse for this: whether a wall
    -- is between you and a cruiser changes at the speed of driving, not at the
    -- speed of task assignment.
    contactInterval = 250,

    -- How far a ground officer can see, and how wide their cone of attention is
    -- in degrees. 360 disables the cone entirely. Anything within 8m is seen
    -- regardless of facing -- an officer does not lose the car touching their
    -- bumper because the driver glanced sideways.
    sightRange = 90.0,
    sightFov   = 160.0,

    -- Air crews. No cone: a helicopter carries a spotter whose entire job is
    -- looking down, and giving them a forward arc makes them useless at the one
    -- thing they exist for. This is what stops you breaking contact by turning a
    -- corner while a heli is overhead, and it is most of what justifies one.
    airSightRange = 250.0,

    -- How long line of sight has to stay broken before contact is genuinely
    -- lost, in ms. Sight breaks constantly in city driving -- every corner,
    -- every truck, every overpass -- so without a grace period the pursuit would
    -- drop you at the first parked bus.
    loseContactMs = 4000,

    -- Firing a weapon inside this range of any unit hands your position back
    -- regardless of cover. Realistic, and the reason shooting your way out of a
    -- hiding place should not work.
    gunfireReveals = true,
    gunfireRange   = 120.0,

    -- The search, once contact is lost. Units drive to the last known position,
    -- then sweep outward from it; the radius grows the longer you stay hidden,
    -- so a search starts tight on the sighting and loosens into the surrounding
    -- blocks rather than being a fixed circle.
    --
    -- These feed vice_hud's inner/outer search-radius circles directly (see
    -- its Config.PoliceSearch) -- there's no separate "visual size" knob on
    -- that end, this IS the size. Scaled up ~3.5x from the original
    -- 40/4/180 after the circles read as too small on the actual minimap/
    -- pause map: units now search a wider area for the same reason.
    searchRadiusStart  = 140.0,
    searchRadiusGrowth = 14.0,    -- metres per second lost
    searchRadiusMax    = 630.0,

    -- How long units keep actively searching a last-known position before
    -- calling it off, in ms. Once this elapses without contact, the search
    -- stands down (FenixPursuit.isSearching() drops to false) but the wanted
    -- level itself is untouched -- that's the gap between "actively hunting
    -- you" and "shaken them, but still in the search zone" vice_hud's
    -- wanted stars read as the 'red' state, matching GTA's own reference:
    -- red stars only appear in that window, before the level actually decays.
    giveUpAfterMs = 45000,

    -- Mute sirens (not lights) while searching. A unit that has lost the suspect
    -- wants to hear the street, not announce itself to it.
    quietSearch = true,

    -- An officer who stops being refreshed by the chase loop for this long is
    -- dropped from the perception set. This is how a deleted officer removes
    -- itself without client.lua having to say so.
    observerTimeout = 4000,

    -- AI blips on responding officers, with the view cone that shows what each
    -- one can see. The cone is not decoration: it is the same number sightRange
    -- and sightFov feed, so a player watching the cones is reading the actual
    -- contact model.
    --
    -- Off by default: vice_hud draws its own inner/outer search-radius circles
    -- (fed by FenixPursuit.isSearching/.searchRadius/.targetCoords via this
    -- resource's exports) instead of per-officer blips, so the player reads
    -- "the area cops are working" rather than individual unit positions.
    blips      = false,
    blipCones  = true,

    -- Blip colour index. Left nil, officers get the game's default AI blip,
    -- which is the hostile red GTA uses for everything it tracks this way. Set a
    -- colour index (3 is blue) if you would rather they read as police than as
    -- enemies.
    blipColour = nil,

    -- One blip per vehicle rather than one per officer. A four-unit response is
    -- eight officers, and eight overlapping blips on the same four cars is not
    -- more information -- it is a smear that hides the cones underneath it.
    -- Officers on foot always blip: at that point they are the unit.
    blipDriversOnly = true,

    -- Radio traffic. Roughly four or five calls per pursuit -- opening call,
    -- lost visual, re-acquired -- not a running commentary.
    dispatchMessages = true,
    dispatchPrefix   = 'DISPATCH:',
    dispatchCooldown = 8000,   -- ms between calls, ignored by the opening call
    dispatchDuration = 6000,   -- how long the notification sits on screen

    -- Route radio traffic somewhere else (a scanner UI, a phone app, ox_lib).
    -- Receives the finished string. Leave nil for QBCore notifications.
    -- dispatchHandler = function(text) exports['my_scanner']:Say(text) end,
    dispatchHandler = nil,

    -- Officers call out spotting and losing the target. Ambient speech is used
    -- rather than scanner audio deliberately: a speech context this build of the
    -- game doesn't have simply doesn't play, where a bad scanner report name is
    -- an error. Nothing here is load-bearing.
    officerSpeech  = true,
    speechRange    = 60.0,
    speechCooldown = 6000,
}

-- GPS TRACKER --
--
-- Every dispatch vehicle (everything in Config.vehiclesByRegion — the exact
-- set server/guard.lua already allowlists) is fitted with a tracker by
-- default. While a wanted player is DRIVING one, client/pursuit.lua's contact
-- thread treats them as seen regardless of actual line of sight, the same way
-- gunfire already overrides it (see makingNoise in pursuit.lua) — stealing a
-- cruiser doesn't make you invisible, because whoever's watching the fleet
-- already knows exactly where it is.
--
-- The only way out is removing it: client/tracker.lua's ox_target
-- interaction, gated on holding removeTool and (by default) on nobody
-- currently being able to see you do it.
Config.Tracker = {
    enabled = true,

    -- ox_inventory item required to attempt a removal. '' or nil skips the
    -- check entirely.
    removeTool = 'screwdriverset',

    -- How long the ox_lib progress bar takes, in ms.
    removeMs = 12000,

    -- Refuse the attempt while FenixPursuit.hasContact() is true — an officer
    -- can currently see the player. Set false to allow it in plain sight.
    blockWhileSeen = true,
}


-- POLICE DRIVING --
--
-- Every driver used to be handed SetDriverAbility(1.0) and
-- SetDriverAggressiveness(1.0), re-applied every cycle, so every unit in every
-- pursuit drove identically: all ramming, all cornering the same, none of them
-- ever making a mistake. These are rolled once per officer and kept for that
-- officer's lifetime, the same way Config.Combat.engageChance is.

Config.Driving = {
    -- Ranges are { min, max } and indexed by wanted level, exactly like the
    -- Config.Combat tables. A single { min, max } pair applies at every level.
    --
    -- ability      0-1. Cornering, braking, reading the road. Low values make
    --              mistakes; that is the point.
    -- aggression   0-1. Willingness to ram, cut across and force the issue.
    ability = {
        [1] = { 0.55, 0.80 },
        [2] = { 0.60, 0.85 },
        [3] = { 0.70, 0.90 },
        [4] = { 0.80, 1.00 },
        [5] = { 0.85, 1.00 },
    },

    aggression = {
        [1] = { 0.25, 0.50 },   -- a pursuit, not a demolition derby
        [2] = { 0.35, 0.60 },
        [3] = { 0.50, 0.75 },
        [4] = { 0.70, 0.95 },
        [5] = { 0.85, 1.00 },
    },

    -- Commanded pursuit speed in m/s. 42 is roughly 94 mph.
    speed = 42.0,

    -- Cap the commanded speed to what the car can actually do. A riot van and an
    -- interceptor were both told 42 m/s; the van never reached it and drove like
    -- it was late for something.
    matchVehicleSpeed = true,
    speedFraction     = 0.92,

    -- Per-officer multiplier on the result, so a convoy doesn't move as one
    -- object.
    speedVariance = { 0.90, 1.05 },

    -- Speed while sweeping a search area. Slow: they are looking, not chasing.
    searchSpeed = 16.0,

    -- [Upstate Mafia] Half of the units still in the direct-response phase
    -- (see applyGroundPursuitTask in server/server.lua) drive to a point this
    -- far ahead of the player's current velocity instead of their live
    -- position, so a response reads as officers cutting you off rather than
    -- every unit converging from the same direction. Ignored below
    -- interceptMinSpeed (m/s) -- leading a target that isn't meaningfully
    -- moving just means driving to nowhere.
    interceptLeadDistance = 70.0,
    interceptMinSpeed     = 4.0,

    -- An officer on foot beside their car is tasked to walk back and get in.
    -- After this many cycles, or beyond this distance, they are warped instead.
    -- Something genuinely does get officers stuck -- ragdolled under the car,
    -- wedged in scenery, holding a task that will not clear -- and a pursuit unit
    -- standing in the road forever is worse than one visible teleport.
    reboardPatience        = 12,
    reboardGiveUpDistance  = 45.0,
}



-- ROADBLOCKS & SPIKE STRIPS --
--
-- Read by client/tactics.lua. Dispatch service 8 (DT_PoliceRoadBlock) is
-- force-disabled elsewhere in this resource and nothing replaced it, so the
-- entire response at every wanted level was "more cars behind you" — a pursuit
-- with no way to get in front of the suspect has only one shape.
--
-- Both features lean on Config.Roads: a block that spans a carriageway has to
-- know where the carriageway ends, and a strip laid across the wrong side of a
-- dual carriageway is scenery.

Config.Tactics = {
    enabled = true,
    debug   = false,

    -- Deployed against a suspect the police can currently SEE. Getting a unit in
    -- front of you means knowing where you are going, and during a search nobody
    -- does — which is also what stops a search becoming a wall of roadblocks in
    -- every direction at once.
    --
    -- Below this speed both are pointless: a suspect doing 15mph through a side
    -- street drives around a block and steps over a strip. In m/s.
    minSpeed = 12.0,

    -- Ceiling across both kinds, and the minimum gap between any two. Two blocks
    -- a hundred metres apart on the same road is one block with extra steps.
    maxConcurrent = 2,
    minSpacing    = 250.0,

    -- Give up looking for a spot after this many samples along the player's
    -- route. Sampled far-to-near so a block lands at the far end of its band
    -- where possible, which is the difference between an obstacle and an ambush.
    placementAttempts = 12,

    -- ── Roadblocks ──────────────────────────────────────────────────────────
    roadblockFromLevel  = 3,
    roadblockChance     = 0.5,     -- rolled once per cooldown window
    roadblockCooldown   = 45,      -- seconds
    roadblockMinDistance = 170.0,
    roadblockMaxDistance = 300.0,

    -- One car per blocked lane, parked broadside. Officers stand behind the
    -- line, facing back down the road, and hold position — the block is the
    -- obstacle, it is not an ambush.
    roadblockVehicles = { 'police', 'police2', 'police3', 'sheriff' },
    roadblockOfficers = 2,

    -- ── Spike strips ────────────────────────────────────────────────────────
    -- Laid closer than a roadblock on purpose. A strip you cannot see until you
    -- are on it is a coin flip; one you spot at two hundred metres is a
    -- decision.
    spikeFromLevel   = 3,
    spikeChance      = 0.5,
    spikeCooldown    = 35,         -- seconds
    spikeMinDistance = 120.0,
    spikeMaxDistance = 220.0,
    spikeModel       = 'p_ld_stinger_s',
    spikeNotify      = true,
    spikeMessage     = 'Spike strip!',

    -- ── Shared ──────────────────────────────────────────────────────────────
    peds   = { 's_m_y_cop_01', 's_f_y_cop_01', 's_m_y_sheriff_01' },
    weapon = 'weapon_pistol',

    -- Placements are removed after this many seconds, or once the player is this
    -- far away (with a floor on age, since a block placed 300m ahead is already
    -- "far away" the moment it exists).
    lifetime        = 90,
    despawnDistance = 350.0,
}


-- ROAD PLACEMENT & NO-GO AREAS --
--
-- Read by client/roads.lua, which is what both the pursuit spawner and the
-- ambient system use to pick a spot. See the header comment in that file for why
-- it exists; the short version is that a vehicle node is the centre line of a
-- road, not a lane, and the heading a node reports is only one of the road's two
-- legal directions of travel. Placing a car on the raw node data is what put
-- cruisers in the middle of the street facing oncoming traffic.

Config.Roads = {
    -- Prints every rejected spawn candidate with the reason. Noisy.
    debug = false,

    -- Width of one traffic lane, in metres. GTA's road network is built to
    -- roughly 3.5m and the engine's own reported road widths agree, so there is
    -- rarely a reason to change this. Too small and cars straddle the paint; too
    -- large and they spawn on the pavement.
    laneWidth = 3.5,

    -- Which lane a responding unit appears in.
    --   'outer'   kerbside lane. The plausible one, and the default.
    --   'inner'   lane nearest the centre line.
    --   'random'  any lane travelling the right way.
    lanePreference = 'outer',

    -- How far past the outermost lane a *parked* scene sits (radar traps,
    -- traffic stops), in metres from the edge of the carriageway. Because it is
    -- measured from the edge and not the centre line, the same number works on a
    -- two-lane street and a six-lane boulevard. A car is about 2m wide, so 1.5
    -- puts it mostly on the verge with a wheel still on the tarmac -- which is
    -- how a real speed trap parks. Raise it and cars end up in the scenery.
    shoulderOffset = 1.5,

    -- Ring samples per spawn attempt. Each one is a GET_CLOSEST_ROAD plus a
    -- handful of cheap checks, run once when a unit is dispatched — not per
    -- frame — so this can afford to be generous.
    spawnAttempts = 24,

    -- Reject spawn points on surfaces the game gives no street name to. This is
    -- the main defence against units appearing on runways, taxiways, aprons,
    -- car park aisles and dirt scrapes: GTA V names every drivable public road,
    -- rural trails included, and names none of those. Turn it off only if you
    -- run a map addon whose roads have no street data.
    requireNamedStreet = true,

    -- Minimum vehicle node density. 0-1 is a dead end or a track, and a pursuit
    -- that starts on one stalls immediately.
    minNodeDensity = 2,

    -- Radius, in metres, of the emptiness check around a candidate point. This
    -- is what stops a cruiser materialising inside a moving car. A police
    -- cruiser is about 5m long, so anything under 4 leaves them overlapping.
    clearance = 4.0,

    -- Minimum gap between a new spawn point and one already promised to a spawn
    -- that is still in flight.
    --
    -- The dispatcher fires several spawn requests in a single tick, and each is a
    -- round trip to the server before any vehicle exists -- so the occupancy
    -- check above cannot see the car that is about to be there. Two cruisers then
    -- land on the same point and flip each other. Scoring makes this more likely
    -- than the first-fit code it replaced, because two calls a few milliseconds
    -- apart agree on which lane centre is best.
    spawnSeparation = 18.0,

    -- [Upstate Mafia] How far a sample point is allowed to snap to the nearest
    -- real road before findSpawnPoint() throws it out as "ignoring the
    -- distance band" -- see its use in client/roads.lua. The requested ring is
    -- opts.minDistance/maxDistance (Config.minPoliceSpawnDistance = 80m by
    -- default), but the nearest actual road to a sample point is rarely
    -- exactly on that ring, so some slack is unavoidable. It was a flat
    -- 0.6x/1.6x band, which let a unit land as close as 48m despite the
    -- config saying 80 -- close enough to read as spawning right on top of
    -- the player. Tightened toward the requested distance; still not 1.0
    -- because a hard cutoff on a sparse road network means more attempts
    -- fall through to getSafeSpawnPoint's wider fallback passes instead,
    -- which allow more distance, not less.
    spawnDistanceMinRatio = 0.85,
    spawnDistanceMaxRatio = 1.3,

    -- How long a promised spot stays claimed. Only has to outlive the server
    -- round trip; after that the vehicle exists and `clearance` takes over.
    reservationSeconds = 25,

    -- How much of the player's view counts as "in front", as the cosine of the
    -- half-angle. Candidates inside it are refused outright.
    --   0.0  refuse anything in the forward half-plane (the default)
    --   0.7  refuse only the front 90-degree cone
    --   1.0  refuse nothing, units may spawn dead ahead
    --
    -- Sampling already biases towards the rear, but a sample is only a starting
    -- point: the road it snaps to can be anywhere. This is the check that
    -- actually keeps units out of the windscreen. Raise it if you want units
    -- cutting you off from in front at higher wanted levels.
    maxForwardDot = 0.0,

    -- Reject a spawn point whose driving distance to the player is more than
    -- this many times the straight-line distance. Catches the placements that
    -- look perfect on a map and are useless in play: the freeway deck directly
    -- above the player, the far bank of the Alamo Sea, the other side of a
    -- canyon — 90m apart, three kilometres by road, and the unit spends its
    -- entire lifetime driving. Set to 0 to disable the check.
    maxTravelRatio = 4.0,

    -- If GET_CLOSEST_ROAD reports nothing at a sample point, fall back to the
    -- old vehicle-node native and assume an undivided two-lane road. Less
    -- accurate, but "this one unit was placed with less information" beats "no
    -- unit ever spawns" if a map addon has road data the native doesn't read.
    nodeFallback = true,

    -- GET_CLOSEST_ROAD's lane-count output is community convention, not a
    -- Rockstar-confirmed contract — FiveM's own native reference lists those
    -- parameters as untyped and unverified. On a DIVIDED highway that can go
    -- wrong visibly: each carriageway is close enough to the other across a
    -- narrow median that "closest road" can hand back the FAR one, dropping a
    -- unit in the opposite carriageway facing oncoming traffic.
    --
    -- Every GET_CLOSEST_ROAD result is checked against
    -- GET_CLOSEST_VEHICLE_NODE_WITH_HEADING — a plain, confirmed position and
    -- heading, the same native this file already falls back to when
    -- GET_CLOSEST_ROAD finds nothing. A result further than crossCheckDistance
    -- from that anchor, or angled more than crossCheckAngle away from it
    -- (allowing for the anchor facing either direction of travel), is treated
    -- as describing a different road and discarded in favour of the anchor —
    -- one lane each way, same as the no-data fallback above.
    --
    -- crossCheckDistance in metres, 0 disables the check. crossCheckAngle in
    -- degrees.
    crossCheckDistance = 20.0,
    crossCheckAngle    = 40.0,

    -- Switch the AI road network off inside the exclusion zones below, using
    -- SET_ROADS_IN_AREA. Rejecting spawns keeps units from *appearing* airside;
    -- this is what stops a pursuit that started on a normal street from routing
    -- across the runway, because the pathfinder stops seeing those nodes at all.
    -- It applies to ambient traffic too, which is correct — airside has no
    -- civilian traffic. Restored when the resource stops.
    disableAiRoads = true,

    -- How close the player has to be to a zone before the above is applied.
    -- Node state is reset by the engine when a region streams back in, so it is
    -- re-applied on a timer rather than once at startup.
    suppressionRadius = 2000.0,

    -- Areas police neither spawn in nor path through.
    --
    -- Each entry is a box (`min`/`max`), a cylinder (`center`/`radius`) or a
    -- prism (`poly` = list of vector3, only x/y read). `zMin`/`zMax` bound it
    -- vertically, which matters: without a ceiling, a box over an airfield also
    -- swallows any road bridging over it.
    --
    --   enabled         false to keep the entry as documentation without effect
    --   disableAiRoads  false to reject spawns here but leave pathing alone
    --   disablePedPaths true to also clear pedestrian paths
    --
    -- THESE BOXES ARE HAND-MEASURED. Before trusting one, fly out and run
    -- `/fenixroads` to draw them in-world, and `/fenixroads here` to see what
    -- the system makes of the ground you are standing on. Adjust in
    -- config.local/ rather than here so an update doesn't overwrite your work.
    exclusionZones = {
        {
            name = 'LSIA airside',
            -- Runways, taxiways, aprons and hangars. The north edge stops short
            -- of the terminal frontage road so arrivals/departures traffic —
            -- and police responding to it — is unaffected.
            min  = vector3(-1800.0, -3400.0, 0.0),
            max  = vector3(-950.0,  -2830.0, 0.0),
            zMin = -20.0,
            zMax = 45.0,
        },
        {
            name = 'Fort Zancudo airfield',
            -- Military. Even without the immersion argument, LSPD units driving
            -- onto an active air base is not a thing that should happen.
            min  = vector3(-2700.0, 2850.0, 0.0),
            max  = vector3(-1600.0, 3650.0, 0.0),
            zMin = -20.0,
            zMax = 120.0,
        },
        {
            name = 'Sandy Shores airstrip',
            -- Off by default: the strip sits close enough to Route 68 and the
            -- Alamo Sea road that a box big enough to cover it risks eating real
            -- roads. Draw it with /fenixroads, trim it to fit, then enable.
            enabled = false,
            min  = vector3(1300.0, 3200.0, 0.0),
            max  = vector3(1800.0, 3350.0, 0.0),
            zMin = 20.0,
            zMax = 80.0,
        },
    },
}


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
