CROSS-GROUP API CONTRACT (fix phase)

The MODULES group (client/morale.lua, backup.lua, jurisdiction.lua, pursuit.lua, ...) and the CLIENT group (client/client.lua) work in parallel. They must agree on these exact interfaces. MODULES implements them; CLIENT calls them. Neither group edits the other's files.

All functions must be safe to call with unknown/stale ids (no-op) and must never throw.

--- client/morale.lua (FenixMorale) ---
FenixMorale.reportDeath(vehNetID, pedNetID)
    NEW. Explicit, deduplicated death report for a ground-unit officer (replaces headcount-derived "dead"). Idempotent per pedNetID.
FenixMorale.officerRemoved(vehNetID, pedNetID)
    NEW. A non-death removal (foot-chase give-up, far cleanup). Decrements the unit's baseline crew so it is NOT counted as a casualty.
FenixMorale.clearUnit(vehNetID)
    EXISTS. Must be called for every unit removed from spawnedVehicles. Clears retreating/originalCrew/troubleSince/released/cooldown state for that id.
FenixMorale.isRetreating(vehNetID) -> bool
    EXISTS (keep). True while the unit is in its retreat/regroup sequence (morale or jurisdiction).
FenixMorale.release(vehNetID, reason)
    NEW. Marks a unit as RELEASED: it is done with this pursuit and should be removed so a fresh unit backfills ("relief"). morale.lua calls it itself when a unit is still broken at the end of regroup; jurisdiction.lua calls it for every outgoing unit on a confirmed crossing (instead of beginRetreat). Before/while released, morale.lua tasks the driver to drive away (TaskVehicleDriveWander) if the car is drivable.
FenixMorale.isReleased(vehNetID) -> bool
    NEW. CLIENT group checks this in the ground-unit loop; a released unit is EXCLUDED from currentUnits immediately, and deleted (normal server delete events for its peds + vehicle, spawnedVehicles[id]=nil, FenixMorale.clearUnit(id)) once it is not on screen (IsEntityOnScreen false) and/or > 120 m from the player, or after 30 s regardless.

--- client/jurisdiction.lua (FenixJurisdiction) ---
Regions in Config.vehiclesByRegion are losSantos (LSPD) and paletoBay / sandyShores / countryside (all the County Sheriff). A crossing between two regions of the SAME agency is not a handoff at all.

FenixJurisdiction.agencyOf(region) -> string
    NEW. Human-readable agency for a region key, from NEW config Config.Jurisdiction.agencies (default { losSantos = 'LSPD', paletoBay = 'Sheriff', sandyShores = 'Sheriff', countryside = 'Sheriff' }); unknown region → the region key itself. Used for handoff decisions AND radio text (never print internal keys like 'sandyShores').
FenixJurisdiction.checkCrossing(pursuitActive) -> fromRegion, toRegion | nil
    SAME signature. Changes: returns non-nil only for a CONFIRMED crossing (new region held continuously for Config.Jurisdiction.dwellMs, default 8000) between DIFFERENT agencies, during an active pursuit; tracks lastRegion even when not pursuing (so pursuit start never fakes a crossing); announces the handoff once per confirmed crossing with agency names (FenixPursuit.announceHandoff gets agency names).
FenixJurisdiction.reset()
    NEW. Clears lastRegion/pending dwell state. CLIENT group calls it in the "pursuit over" branch next to FenixPursuit.reset().
jurisdiction.lua NO LONGER triggers retreats itself and client.lua no longer calls beginRetreat on a crossing.

GRADUAL HANDOFF (implemented in client.lua by the CLIENT group):
- Record vehicleData.agency = FenixJurisdiction.agencyOf(FenixJurisdiction.currentRegion()) whenever a ground unit is added to spawnedVehicles (spawn response, ambient promotion, investigation promotion).
- A unit is "outgoing" when vehicleData.agency ~= agencyOf(currentRegion()) (only when Config.Jurisdiction.enabled ~= false). Outgoing units keep chasing (real pursuits don't drop the suspect at the county line) but are EXCLUDED from currentUnits, so the new agency's units start spawning right away (respect unitInterval; skip the Config.Response initial delay since the pursuit is already under way).
- Each maintain cycle: while (incoming + outgoing) > maxUnits for this wanted level, release one outgoing unit via FenixMorale.release(vehNetID, 'jurisdiction'), preferring units without line of sight / farthest from the player. Net effect: the response swaps agencies one car at a time.

--- client/backup.lua (FenixBackup) ---
FenixBackup.reportOfficerDown(...)  — same signature as today, becomes idempotent per officer internally.
FenixBackup.reportSuspectArmed(...) — same signature, internally rate-limited (≤ once/second) and guns-only (IsPedArmed flag 6). CLIENT group additionally moves the call to once per main-loop cycle.

--- client/pursuit.lua (FenixPursuit) ---
No signature changes. Internal: shot tracking via a dedicated fast thread; state machine keeps running with an empty observer set.

--- CLIENT group (client/client.lua) obligations ---
- Call FenixMorale.reportDeath next to every ground-unit FenixBackup.reportOfficerDown call (once per officer — keep vehicleData.reportedDown).
- Call FenixMorale.officerRemoved at non-death officer removals (foot-chase give-up, far-officer cleanup).
- Call FenixMorale.clearUnit at EVERY site that sets spawnedVehicles[vehNetID] = nil.
- Handle FenixMorale.isReleased as described above; exclude retreating AND released AND abandoned/wrecked units from currentUnits.
- Call FenixJurisdiction.reset() where FenixPursuit.reset() is called for pursuit end.
- Guard all calls with the module existing (`FenixMorale and FenixMorale.isReleased`) so load order or a disabled module never throws.

--- SERVER group obligations visible to clients ---
- spawnPoliceHeliNet / spawnPoliceAirNet: server derives the spawn table itself (client-sent table ignored), validates wantedLevel/spawnPoint, and ALWAYS replies (spawnPoliceHeliNetResponse / spawnPoliceAirNetResponse with nil,nil on failure). CLIENT group: response handlers must treat nil vehNetID as failure and decrement the pending counter.
- spawnPoliceUnitNet: ALWAYS replies (existing failure reply shape — check what the client expects).
- updateWantedStatus: server tolerates change-only + heartbeat reporting from clients.
- cleanupAllPolice: only broadcast on someone-wanted → nobody-wanted transition.
- fieldRevive / issueTicket: new server-side preconditions. CLIENT group sends issueTicket only after the citation completes.
- New FenixGuard helpers (server only): FenixGuard.ownerOf(netID), FenixGuard.ownedCount(src).
