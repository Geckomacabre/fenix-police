AUDIT REPORT — server side: server/*.lua + um_fenix_bridge/server/crime.lua
(line numbers against commit 235a2cd; re-locate by content before editing)
All RegisterNetEvent handlers cross-checked against client triggers: argument order matches everywhere.
NOTE: when the server fires an event to itself (TriggerEvent), `source` is "" (empty string), NOT 0 — several guards assume 0.

1. [critical][CONFIRMED] server.lua:696-925 (heli) and 931-1084 (plane) — any client chooses what the server spawns, where, how many.
   Client sends spawnTable (client.lua:620/734); getRandomAirUnit (server.lua:367-411) uses it as-is: model, pilots, peds, numPilots, numPeds, spawnChance, loadout. spawnPoint and wantedLevel unchecked.
   - Server hang: spawnChance=1e9 or numPeds=1e9 → `for _=1,unit.spawnChance do table.insert(...)` (378/393/400) exhausts memory/CPU.
   - Arbitrary spawns: any model, any coords, armed peds, 60/min; not counted against maxOwnedEntities.
   - Client crashes: CreateVehicleServerSetter(hash,'heli',...) with a non-heli model is a known crash for every client in range.
   Fix: ignore client table; derive on server:
     local function airTable(src, kind) -- 'heli'|'plane'
       local ped = GetPlayerPed(src); local veh = ped ~= 0 and GetVehiclePedIsIn(ped,false) or 0
       local vt = veh ~= 0 and GetVehicleType(veh) or nil
       if kind == 'heli' then if vt == 'plane' then return nil end; return vt=='heli' and Config.milHelis or Config.polHelis end
       return (vt=='plane' or vt=='heli') and Config.milPlanes or nil
     end
     -- top of each handler (after FenixGuard.allow):
     wantedLevel = math.floor(tonumber(wantedLevel) or 0); if wantedLevel<1 or wantedLevel>5 or type(spawnPoint)~='vector3' then return fail() end
     local ped = GetPlayerPed(src); if ped==0 or #(GetEntityCoords(ped).xy - spawnPoint.xy) > (Config.maxHeliSpawnDistance or 500.0)+50.0 then return fail() end
     if FenixGuard.ownedCount(src) >= ((Config.Security or {}).maxOwnedEntities or 60) then return fail() end
     local spawnTable = airTable(src,'heli'); if not spawnTable then return fail() end
   (FenixGuard.ownedCount is new: expose guard.lua's ownedCountFor. Planes use Config.maxAirSpawnDistance.)
   IMPORTANT: verify against client.lua how spawnTable is chosen client-side (spawnHeliUnitNet / spawnAirUnitNet ~608/721) and replicate exactly that selection server-side so behaviour is unchanged for honest clients.

2. [high][CONFIRMED] server.lua:1370-1379 fenix-police:server:fieldRevive — free self-revive any time (calls exports.qbx_medical:Revive(src) unchecked).
   Fix: if not aftermathHolding[src] then refuse; per-player cooldown (lastRevive, 300s); require one of the player's own owned officer peds within 10m; clear lastRevive on playerDropped; aftermathHolding[src]=nil after use. (FenixGuard.ownerOf(netID) new helper.)

3. [high][CONFIRMED] guard.lua:343-389 + config.lua:1370 strictOwnership=false — player police/EMS job vehicles can be unlocked/deleted.
   Allowlist is stock police/police2..4/sheriff/fbi/riot plus ambulance/firetruk (EMS/fire allowlisted even when those features are off, guard.lua:146-153). Player job cars use the same models and are never in `owned`. Any client walks net IDs through fenix-police:unlockOfficerVehicle (600/min, also sets doorslockstate=1) to steal parked cop cars, or deleteSpawnedEntity/deleteSpawnedVehicle to delete every unoccupied one.
   Fix: default strictOwnership = true (FIRST verify every legitimate client delete/unlock path targets entities that get registered as owned — heli/plane server-created, ground via ticket, ambient promotions, tactics/K9 are local non-networked; if any legit path would be refused, fix registration rather than leaving strict off); remove deleteSpawnedEntity handler (server.lua:288-301) if no client calls it (grep!); only allowlist EMS/Fire/Investigate models when Config.X.enabled; release ownership on AddEventHandler('entityRemoved', function(e) FenixGuard.release(NetworkGetNetworkIdFromEntity(e)) end) so reused net IDs don't inherit stale owner.

4. [high][CONFIRMED] guard.lua:415-463 registerSpawnedUnit — a free ticket lets a client claim any unowned allowlisted entity.
   fenix-police:server:promoteAmbientUnit (server.lua:683-690) hands out tickets with no precondition. Cap checked once before loop, so one ticket claims unbounded pedNetIDs.
   Fix in register(): if NetworkGetFirstEntityOwner(entity) ~= src then refuse 'not created by this player'; if ownedCountFor(src) >= cap then refuse; before loop: if type(pedNetIDs)~='table' or #pedNetIDs > 16 then return end.
   (Check NetworkGetFirstEntityOwner exists in server natives list; for ambient-promoted entities created client-side by the same player it should match.)

5. [high][CONFIRMED] server.lua:1279-1335 fenix:server:trigger — grief vector, and the documented server-side use never works.
   Net event, nothing in client/ triggers it. A griefer within 100m can put location.wanted stars on anyone within 10m of a Config.locations point, 30/min. Away from those points wantedlevel becomes 0 and is still sent (1309/1332; with dispatch on, directWanted=0 is truthy at dispatch.lua:139) → client SetWantedLevel clears and re-applies victim's level, re-centring the search.
   README integration TriggerEvent('fenix:server:trigger', source, alertData) arrives with source "" → `""~=0` takes player branch, GetPlayerPed("") = 0, returns. Documented integration is dead.
   Fix: remove RegisterNetEvent (keep AddEventHandler only), remove client-distance block (1290-1306), add `local wantedlevel = GetWantedLevelFromCoords(coords); if not wantedlevel or wantedlevel <= 0 then return end`. Make the source==server detection robust ("" / nil / 0).

6. [high][CONFIRMED] server.lua:758-765, 841-848, 984-991 — CreatePed retry loop spawns a NEW ped every pass (async server CreatePed) → up to 10 peds per seat materialising 150-200m up (falling cops never claimed/swept). If window runs out, `return` leaks the crewless heli/plane.
   Fix: create once then wait (spawnPedWait helper, 3s timeout, Wait(50)); every failure path → abort() deleting vehicle + all peds created so far, then fail().

7. [high][CONFIRMED] server.lua:716-719, 728-731, 766-769, 849-852, 951-954, 963-966, 992-995 — failed air spawns never reply → helicopters stop for the rest of the pursuit.
   No spawnPoliceHeliNetResponse / spawnPoliceAirNetResponse → client pendingHeliSpawns/pendingAirSpawns never decrement; client stops asking at 5 (client.lua:1641/1677). Trace: maxHeliUnitsPerLevel[2]=1 but lowest polHelis entry needs wanted 3 → at 2 stars every request returns no candidate, no reply; after 5s counter at 5; at 3-5 stars no heli ever spawns until wanted clears. Same for hunter at 2-3 stars.
   Fix: fail() sends response with nil,nil; every early return → return abort(). VERIFY client handlers treat nil vehNetID as a failure and decrement pending counters (fix client side too if not).

8. [medium][CONFIRMED] server.lua:1137-1200 issueTicket — no rate limit, no proof of real stop, honor granted even unpaid (allowUnpaid default true → broke player spamming gets unlimited qbx_honor complied_with_police hooks).
   Fix: FenixGuard.allow(src,'ticket',3); require player wanted (playerWantedStatus[src]) and/or one of player's own officer peds within (c.windowDistance or 3.5)+6 m; only ApplyHook when paid. (Client side: send issueTicket AFTER citation writing loop — owned by client.lua group.)

9. [medium][CONFIRMED] server.lua:223-235 and 276-285 — "cleanup all police" broadcast every ~2s whenever nobody is wanted; can wipe a newly wanted player's first units.
   Every client posts updateWantedStatus every second (client.lua:5482-5489); each runs cleanupIfNoPlayersWanted → broadcast cleanupAllPolice to all every ~2s → each client runs handleEndWantedDelete (closes spawn gate, resets counters/backup/morale). At wanted onset server's view up to 1s stale → cleanup reaches newly wanted client, wipes just-promoted ambient unit / discards spawn response.
   Fix: broadcast only on transition someone-wanted → nobody-wanted (wasWanted flag). (Client side: send only on change + 10-15s heartbeat — client.lua group.)

10. [medium][CONFIRMED] guard.lua:394-403 — entities forgotten, not deleted, when their player disconnects; no sweep exists. Server-created helis/planes migrate and fly on untracked; resource-stop sweep (server.lua:1347) misses them. Heli/plane spawns finishing after requester left claim for dead src.
   Fix: playerDropped: for each rec.src==src delete entity if exists and not belongsToAPlayer(e). Heli/air handlers before claiming: if not GetPlayerName(src) then return abort() end.

11. [medium][CONFIRMED] um_fenix_bridge/server/crime.lua:160-174 and 198-209 — server-side crime reports never reach anyone (source "" not 0): qbx_jewelery alertSrc ignored; GetPlayerName("") drops report; em_toolkit:missionStarted can never resolve a target.
   Fix: local function isServer(s) return s==nil or s=='' or s==0 end; use it in both places; for em_toolkit take player from event args (check payload shape in code/comments; if unknowable, document).

12. [medium][CONFIRMED] dispatch.lua:231-254 — any client can rewrite any incident's units (assign/release accept any incidentId/unitId/role; releasing a unit on empty incident resolves it; fake 'investigating' role cuts EMS staging).
   Fix: numeric ids; role in {ems, fire, investigating}; record inc.assignedBy[unitId]=src; release only if inc.assignedBy[unitId]==src.

13. [medium][LIKELY] server.lua:722/957/758ff + dispatch.lua:53-65 — routing buckets ignored (server-created air units in bucket 0 even if requester instanced; nearestPlayer can pick host in another bucket).
   Fix: SetEntityRoutingBucket(e, GetPlayerRoutingBucket(src)) for every created entity; filter host candidates to reporter's bucket.

14. [medium][CONFIRMED] dispatch.lua:149/165 — each incident gets one host, no fallback; if host declines (maxUnits / no spawn point) call never answered. incident.lua:140-142 isAbandoned can never be true (createIncident always ends ACTIVE, dispatch.lua:179) → abandonedIncidentMs dead; unanswered incidents sit ACTIVE 30 min.
   Fix: cleanupStale treats ACTIVE with countAssigned==0 older than abandonedIncidentMs as abandoned; optionally re-offer to next-nearest player after N s with no assign.

15. [low][CONFIRMED] dispatch.lua:93-105 — duplicate detection uses createdAt → sustained gunfire/fire creates new incident (new EMS + investigation) every 30s. Fix: compare now - incident.lastUpdate; set existing.lastUpdate on merge.

16. [low][CONFIRMED] unit_registry.lua:24-49 — registry accepts anything (any client overwrites entries for net IDs it doesn't own). Fix before dispatch uses it: accept entry only if FenixGuard.ownerOf(vehNetID)==src; whitelist kind ground/heli/air; prefer server-side GetEntityCoords when entity visible.

17. [low][CONFIRMED] server.lua:96 SetSirenKeepOn is client-only, but nothing reaches it: applyGroundPursuitTask (79-186) only runs over activeGroundUnits, never filled. If ever filled, first call throws inside the un-pcalled 1s loop (188-195) killing it. GetVehicleModelNumberOfSeats guard (113) always yields 4.
   Fix: delete dead subsystem: line ~23 decl, 49-51, 79-195, activeGroundUnits loops at 241-245, 317-328, 342. (Grep to make sure nothing else references them.)

18. [low][CONFIRMED] server.lua:758/762/841/845/984/988 — undefined global spawnHeading → replace with 0.0 (or a computed heading toward the player).

19. [low][CONFIRMED] server.lua:619-669 spawnPoliceUnitNet — two never-reply paths: regionCode unchecked (region missing from vehiclesByRegion e.g. custom Config.Jurisdiction zone → ipairs(nil) at 423 errors, never replies → pendingGroundSpawns stuck); `while` at 632 runs at most once and if hasDriverWaitCount is 0 never runs/replies.
   Fix: if type(regionCode)~='string' or not Config.vehiclesByRegion[regionCode] then regionCode='losSantos' end; remove the while loop; ensure every path replies.

20. [low][CONFIRMED] server.lua:73-77 dispatchCombatProfile broadcasts to everyone (owner -1) when entity missing — exactly the all-client task broadcast the comment says froze the game. Fix: if not DoesEntityExist(entity) then return end; owner = NetworkGetEntityOwner(entity); if not owner or owner <= 0 then return end.

21. [low][CONFIRMED] server.lua:39-47 and 276-285 — aftermathState and updateWantedStatus unthrottled; a client sending aftermathState(true) permanently suppresses global cleanup for everyone. Add FenixGuard.allow(src,'status',120); expire aftermathHolding after holdAfterFailedMs (Config.Aftermath).

Config keys: Config.polPlanes (guard.lua:111) and Config.Driving.interceptMinSpeed/interceptLeadDistance referenced; interceptMinSpeed/LeadDistance DO exist in config.lua Config.Driving (verified by main session) but only dead server code reads them. polPlanes has a default.

UNIT REGISTRY → DISPATCH (smallest safe change):
 1. Harden input (unit_registry.lua): FenixGuard.ownerOf(id); accept entry only if ownerOf(vehNetID)==src; whitelist kind; prefer server GetEntityCoords.
 2. dispatch.lua pickHost(coords, r): if registry enabled, FenixUnitRegistry.nearest(coords, r, 'ground') → if its owner's ped within r of coords, return u.src; else nearestPlayer(coords, r). Replace the two nearestPlayer calls (149, 165). Tie-break only, no new trust path.

Improvements: move heli/plane creation client-side with ticket handshake (bigger change — NOT now); client sends updateWantedStatus only on change + heartbeat; rate-limit refuse() logging per player; FenixGuard.ownedBy/ownedCount helpers; drop dead activeGroundUnits code.
