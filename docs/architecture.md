# Architecture Overview

## Layering

```
init.luau (public surface, context-aware)
│
├── Server/            Transport: bind + Fire family (Step 2, done)
├── Client/            Transport: non-blocking On, discovering Fire (Step 2, done)
└── Shared/
    ├── Types/         all public types, single source of truth
    ├── Config/        centralized runtime config + Changed signal
    ├── Signals/       Signal implementation (thread-reusing)
    ├── Utilities/     Log, TableUtil
    ├── Core/          Envelope, RemoteRegistry, Dispatcher (Step 2, done)
    ├── Channels/      channel objects (Step 3)
    ├── Validation/    schema validators (Step 4)
    ├── Security/      rate limiter, abuse detection (Step 5)
    ├── Middleware/    chain runner + built-ins (Step 6)
    ├── Serialization/ datatype codecs (Step 8)
    ├── Compression/   optional payload compression (Step 8)
    └── Debug/         inspector, stats, monitor (Step 10)
```

Dependency rule: arrows point downward only. `Shared/*` modules never require
`Server/` or `Client/`. `Types` has zero requires. `Config` requires only
`Types`, `TableUtil`, `Signal`. This keeps the graph acyclic and every module
unit-testable in isolation.

## Step 1 design decisions

**Types is a single module.** Public types live in `Shared/Types` and are
re-exported from `init.luau`. Consumers write `Networking.Packet`, never reach
into internals. Internal-only types stay in their owning module.

**Config is data, not behaviour.** Subsystems read `Config.Get()` at the point
of use (or subscribe to `Config.Changed`) instead of caching flags at require
time. That makes every option live-tunable — including from an admin command
in a running server.

**Config rejects unknown keys.** A typo like `ValiationEnabled = false`
errors immediately instead of silently doing nothing. Snapshots from
`Config.Get()` are deep-frozen so no consumer can mutate shared state.

**Signal reuses one runner thread.** Firing a non-yielding handler costs zero
thread allocations (the pattern popularised by GoodSignal). This matters
because Step 2 dispatches every incoming packet through signals — at thousands
of packets/sec, per-fire thread allocation is measurable GC pressure. Handler
errors are isolated per-handler via `task.spawn` semantics.

**Log is level-gated through Config.** The library never prints in production
by default (`LogLevel = "Warn"`), and can be fully silenced (`"None"`) or
opened up (`"Debug"`) without touching library code.

**Tests are harness-agnostic.** Spec modules are plain tables of
`name -> function(expect)`. The tiny built-in `TestKit` runs them today;
Jest-Lua can replace the runner later without rewriting specs.

## Remote layout (Step 2 preview)

All remotes live under one folder (`Config.RemoteFolderName`, default
`_Networking`) in ReplicatedStorage, created lazily by the server, discovered
by the client via `WaitForChild`. One RemoteEvent + one UnreliableRemoteEvent +
one RemoteFunction **per channel**, multiplexing events by name inside the
packet envelope — not one Instance per event. Fewer instances, cheaper
discovery, and event names become data (validatable, rate-limitable per name).

## Step 2 design decisions

**Event name rides as the first vararg.** The wire format is
`(eventName, ...args)` — no per-packet wrapper table, so the hot path adds
zero allocations on top of Roblox's own serialization. The envelope module
owns the naming rules; both transports drop (and log) any incoming packet
whose first argument fails them, so garbage from exploiters never reaches
a dispatcher signal.

**`__` prefix is reserved.** User code cannot register or fire events starting
with `__`. The Invoke step will carry request/response correlation on
`__invoke`/`__reply` without ever colliding with game events.

**Dispatcher is pure bookkeeping.** It knows nothing about remotes, players,
or contexts — just `(channel, event) → Signal`. That's what makes routing
fully unit-testable without an engine client.

**Client listeners never yield; client fires may.** `On` must be callable at
require time in LocalScripts without stalling module loading, so receive-path
binding happens in a background task once the server's remotes replicate.
`Fire` has to actually deliver, so it waits — bounded by
`Config.DefaultTimeout` — and drops with a loud error log if the server never
created the channel, instead of hanging forever.

**Idempotent instance adoption.** `RemoteRegistry` adopts existing instances
of the right class instead of erroring or duplicating, so hot-reload
(Rojo re-sync) and multiple require paths converge on the same remotes.
