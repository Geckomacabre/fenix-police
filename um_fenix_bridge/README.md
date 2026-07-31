# um_fenix_bridge

Optional companion resource for this fork of `fenix-police`.

**It is not loaded automatically.** FiveM does not descend into a directory that
already belongs to another resource, so this folder sits inert until you copy it
out. That is deliberate — install it only if you want what it does.

## Why it exists

Most robbery scripts alert *player* police and stop there. On a quiet server —
or one with nobody on duty — a bank job draws no response at all.

This watches those alerts and puts a wanted level on whoever caused them.
`fenix-police` already polls the wanted level and dispatches AI units off the
back of it, so the crime gets a response without either script knowing about the
other.

## Install

Copy the folder out of this repo and into your resources directory, alongside
`fenix-police` rather than inside it:

```
resources/
  fenix-police/
  um_fenix_bridge/
```

Then add it to your `server.cfg`, **after** `fenix-police`:

```cfg
ensure fenix-police
ensure um_fenix_bridge
```

Everything else is configured in `config.lua`.

## What's enabled by default

| Module | Default | Needs |
|---|---|---|
| `Crime` — robbery alerts to AI dispatch | **on** | nothing beyond `fenix-police` |
| `ERS` — callout integration + backup units | on | [`night_ers`](https://github.com/Nights-Software) |
| `DynamicEvents` — suppress near world events | off | `um_dynamicworld` (private) |
| `Witness` — witness calls raise wanted level | off | a witness script |

Only the `Crime` module is useful on a stock server, and it is the one that
works with no extra dependencies.

Nothing here calls `exports` on another resource, and there are no hard
dependencies. Every integration is a plain event listener, so a module whose
resource you don't run simply never fires — it does not error, and it does not
need turning off.

## Supported crime sources

`Crime.stars` maps a crime tag to a wanted level. Out of the box it recognises
`loaf_storerobbery`, `loaf_bankrobbery`, `qbx_jewelery` / `jewelery_heist`,
`ps-dispatch` alerts, and the widely-used `police:server:policeAlert` catch-all.

The `um_truckrobbery`, `um_HouseRobberys` and `em_toolkit` tags refer to
resources you probably don't run. Their hooks are harmless when absent — leave
them, or delete the rows.

Stars are applied with fenix's `SetWantedLevel` semantics (takes the higher of
current and new), never additively, so two hooks firing for the same crime can't
stack it to 5. A per-player, per-tag cooldown (`cooldownMs`, 30 s) stops a bank
job that fires an alert per door and per loot bag from re-applying stars each
time.

Where a hook reports *where* a crime happened but not *who* did it, everyone
within `Crime.radius` (60 m) is treated as involved — looser than fenix's own
hardcoded 10 m so that getaway drivers waiting outside are included.

## Licence

GPL-3.0, matching `fenix-police`. See the `LICENSE` file in the parent
directory.
