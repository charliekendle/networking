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
    ├── Channels/      Channel objects (Step 3, done)
    ├── Validation/    Validators + SchemaRegistry (Step 4, done)
    ├── Security/      RateLimiter + SecurityMonitor (Step 5, done)
    ├── Middleware/    MiddlewareRegistry (Step 6, done)
    ├── Serialization/ Serializer (Step 8, done)
    ├── Compression/   LZW with raw fallback (Step 8, done)
    └── Debug/         Stats: counters, packet log, RTT (Step 10, done)
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

## Step 3 design decisions

**Channels are memoized, not constructed.** `Network.Channel("Combat")` from
any script returns the same object. Games never need their own channel
registry module, and two systems referencing the same name can't accidentally
create parallel state.

**Server access is eager, client access is lazy.** Merely referencing a
channel server-side creates its remotes, so any client that can require the
code can discover them — no "fired before the server made the channel" races
in normal usage. On the client, nothing yields until the first listener or
fire.

**Channel objects are thin.** All state (dispatch tables, remote caches,
bound flags) lives in the transports keyed by channel name; the Channel
object is just a name plus method sugar. Middleware/validation/rate-limit
scoping in later steps attaches to the name, which means it works identically
through `Network.Fire` and `channel:Fire`.

## Step 4 design decisions

**Validators are plain functions.** `(value) -> (boolean, string?)` — no
classes, no metatables. Composition is function composition, custom
validators are just functions, and the hot path is a plain call.

**Schemas are positional and closed.** A schema lists one validator per
argument; *more* arguments than validators always rejects. An exploiter
cannot append payload past a validated signature. Fewer arguments validate
the missing slots as nil, so `optional(...)` at the tail is the one way to
express optional args — explicit, visible in the schema.

**Checking allocates nothing.** Varargs are walked with `select`, never
packed. A validated event costs the validator calls and nothing else.

**Non-finite numbers are rejected by default.** NaN and ±inf pass typeof
checks but break math silently downstream (`NaN > x` is always false, so
naive clamps don't save you). `number`, ranges, and every component-bearing
datatype validator reject them; `numberRaw` is the opt-out.

**Registry is context-local.** The server's schemas validate client→server
traffic — the security-critical direction. Client registration exists as a
development aid and costs nothing when unused.

## Step 5 design decisions

**Rate limit runs first.** The pipeline is rate limit → envelope → schema →
dispatch. The limiter is the cheapest check (one table lookup, a little
arithmetic), so a flood is rejected before the server spends anything
parsing it.

**Token buckets are lazy.** Refill is computed from elapsed time on access —
no per-frame upkeep loop, no cost for idle players, and capacity/rate read
live from Config so an admin command can tighten limits mid-incident.

**Strikes are consecutive, not cumulative.** A legitimate player who trips
the limiter once during a lag spike resets to zero on their next clean
packet. Only sustained abuse reaches the threshold, and the hook re-fires
every N violations rather than once ever — so a game reacting with
escalating punishment sees repeat offenses.

**The package never punishes.** Kicking a paying player is a product
decision. The library detects, drops, logs, and reports; the game decides in
`OnSuspiciousActivity`.

**The audit log is a ring buffer.** Fixed 256 entries, O(1) append, copied
out on read. An exploiter cannot grow server memory by generating
violations, and the log-throttle (1/sec/player) means they can't flood the
console either.

## Step 6 design decisions

**Middleware runs last before dispatch.** Rate limiting and validation are
mechanical, cheap, and universally wanted — they run first and don't need
the flexibility (or cost) of user chains. Middleware is where *game logic*
gates live (permissions, auth, feature flags, transforms), so it sees only
packets that already passed the mechanical checks.

**Fail closed.** A middleware that errors, or returns anything other than
"Continue"/"Drop", drops the packet with an Error log. The alternative —
failing open — turns any bug in a permission check into a security hole.

**Zero cost when unused.** The Packet struct is only allocated when
`hasAny(channel)` is true. Games that never call Use pay one boolean check
per packet.

**Replacement, not mutation contract.** Middleware may mutate the packet it
received and/or return a replacement with "Continue"; whatever comes back
flows downstream and into dispatch (unpacked by ArgCount, so transforms may
produce trailing nils safely).

## Step 7 design decisions

**RemoteEvents + correlation IDs, not RemoteFunctions.** The engine's
RemoteFunction has two classic failure modes: `InvokeClient` can hang the
server forever if the client never returns, and timeouts require abandoning
yielded threads. Carrying requests as `(__invoke, id, name, ...)` and replies
as `(__reply, id, ok, ...)` over the existing Reliable remote gives clean
timeout (drop the pending entry), clean cancellation (same), and reply
authentication (a reply must come from the player the request was addressed
to — anything else is a Protocol violation).

**Only timeouts retry.** An error reply proves the server received and
processed the request; re-sending would repeat side effects. A timeout proves
nothing was (visibly) processed, so the client may retry with a fresh id.
Server→client invokes never retry for the same reason in reverse.

**Handler errors are sanitized.** The client sees "Invoke handler error";
the real message and stack go to the server log. Exploiters don't get to
farm internal error strings for reconnaissance.

## Step 8 design decisions

**One buffer beats many arguments.** Roblox's generic serialization writes
type tags and full doubles everywhere. The Serializer packs integers into
1/2/4 bytes, colors into 3, rotations into axis-angle f32s, lengths into
varints, and interns strings (a dictionary key repeated across 100 entries
is written once) — and a buffer is itself the cheapest argument type to
send. LZW compression is a separate, opt-in pass on top
(`Network.Compress`): the packing is usually the big win, LZW pays off on
repetitive KB+ payloads, and the raw-fallback header guarantees compression
never grows a payload past input + 1 byte.

**Fail loudly at both ends.** Serialize errors on Instances (identity cannot
survive a byte stream), functions, and cycles. Deserialize bounds-checks
every read and rejects unknown tags — a malicious buffer errors cleanly
instead of corrupting state.

## Step 10 design decisions

**Counters always, log opt-in.** Integer bumps are effectively free, so
Sent/Received/Dropped totals are always live. The packet log allocates per
packet, so it records only under DebugMode, into a fixed 128-slot ring.

**RTT from invokes.** Round-trip time is measured where a round trip
actually exists — invoke request → reply — over a 64-sample rolling window,
rather than pretending fire-and-forget packets have measurable latency.

## 1.1 design decisions — defined events

**One declaration, three jobs.** `Expect` validators are runtime gates only:
they don't shape the wire and don't reach the type system. A `Define`d
event's codec is the wire format (a `u8` is one byte), the static type
(`EventDef<T>` handles infer), and the validation (decode bounds-checks
every read). This is the ByteNet/Zap insight, layered onto this package's
existing security pipeline rather than replacing it — defined events still
pass rate limiting, strikes, middleware, and the audit log.

**Decode is the validator.** A value that violates the schema cannot come
out of `Schema.decode`: integer reads are width-bounded plus explicitly
range-checked (so `int(0,100)` rejects a raw byte of 200), floats are
finiteness-checked, strings/arrays length-capped against the schema's own
limits, structs closed, trailing bytes rejected. The runtime validator walk
is skipped for defined events because there is nothing left for it to do.

**Struct fields pack in sorted key order.** Deterministic across peers with
zero key names on the wire — both sides derive the order from the same
shared definition module. This is also why definitions must live in shared
code: the codec registration on each side is what makes the bytes mean the
same thing.

**Send-site check.** `Fire` on a typed handle validates before encoding, so
a server bug that produces `Power = 999` errors loudly at the call site
instead of being silently dropped by the peer.
