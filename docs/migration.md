# Migration Guide

## From raw RemoteEvents/RemoteFunctions

| Before | After |
| --- | --- |
| Create RemoteEvent instances, WaitForChild on client | Nothing — `Network.Channel("X")` creates/discovers automatically |
| `remote.OnServerEvent:Connect(fn)` | `channel:On("Event", fn)` |
| `remote:FireClient(player, ...)` | `channel:Fire(player, "Event", ...)` |
| `remote:FireAllClients(...)` | `channel:FireAll("Event", ...)` |
| `remote:FireServer(...)` | `channel:Fire("Event", ...)` |
| `remoteFunction.OnServerInvoke = fn` | `channel:OnInvoke("Event", fn)` |
| `remoteFunction:InvokeServer(...)` (yields, can hang) | `channel:Invoke("Event", ...):Await()` (timeout-bounded) |
| `remoteFunction:InvokeClient(...)` (can hang the server forever) | `channel:InvokeClient(player, "Event", ...)` (always timeout-bounded) |
| Manual typeof checks at the top of every handler | `channel:Expect("Event", ...validators)` once |
| Hand-rolled debounces per remote | Built-in per-player-per-channel rate limiting |

Behavioral differences to know:

1. **One remote trio per channel, not per event.** Your instance count drops; event names travel inside the packet.
2. **Extra arguments are rejected** on validated events. If a handler relied on loose trailing args, add `optional(...)` validators.
3. **Client `Fire` can yield once** per channel (remote discovery, bounded by `DefaultTimeout`). Listeners never yield.
4. **NaN/inf are rejected** by `number`-family validators. Use `numberRaw` if you truly need them.
5. Invoke handler errors reach clients as `"Invoke handler error"` — return explicit error values if the client needs details.

## From Net / Red / BridgeNet-style libraries

Concept mapping is direct: namespaces/bridges → `Network.Channel(name)`; declared remotes → nothing to declare, `On`/`Fire` by event name; `Function`/async remotes → `OnInvoke`/`Invoke` promises; identity/typechecking middleware → `Expect` schemas + `Use` middleware.

Differences worth noting: schemas are positional (one validator per argument, closed by default); rate limiting and abuse strikes are built in and on by default; `__`-prefixed event names are reserved.

## Version policy

SemVer. 1.x guarantees: no breaking changes to any documented API or the wire format tags without a major bump. The serializer format is versioned by its tag set — buffers produced by 1.x deserialize on any later 1.x.
