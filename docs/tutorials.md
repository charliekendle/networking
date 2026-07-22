# Tutorials

## 1. Getting started

Install via Wally:

```toml
[dependencies]
Networking = "charliekendle/networking@1.0.0"
```

`wally install`, make sure `Packages` replicates (ReplicatedStorage), and require it from both contexts:

```lua
local Network = require(ReplicatedStorage.Packages.Networking)
```

The smallest possible round trip, no setup, no remote instances to create:

```lua
-- Server Script
Network.On("Hello", function(player, message)
	print(player.Name, "says", message)
	Network.Fire(player, "HelloBack", "hi!")
end)
```

```lua
-- LocalScript
Network.On("HelloBack", print)
Network.Fire("Hello", "hey server")
```

Remotes are created lazily by the server and discovered by the client — you never touch a RemoteEvent instance.

## 2. Structure a real game with channels

Give each system its own channel. Same name anywhere returns the same object, so no registry module of your own:

```lua
-- shared/Channels.luau (optional convenience module)
local Network = require(ReplicatedStorage.Packages.Networking)
return {
	Combat = Network.Channel("Combat"),
	Shop = Network.Channel("Shop"),
	Trading = Network.Channel("Trading"),
}
```

Event names are scoped per channel — "Update" on Combat and "Update" on Shop never collide. Rate limits are also per channel, so shop spam can't starve combat traffic.

## 3. Lock every remote down with schemas

Rule of thumb: **every `On`/`OnInvoke` on the server gets an `Expect` next to it.**

```lua
local V = Network.Validators

Combat:Expect("Attack", V.instanceIsA("Model"), V.numberRange(0, 100))
Combat:On("Attack", function(player, target, damage)
	-- target is guaranteed a Model, damage a finite 0..100.
end)

Trading:Expect("Offer", V.strictInterface({
	ItemId = V.stringMaxLength(50),
	Amount = V.integerRange(1, 999),
}))
```

Things the schema layer stops for free: NaN/inf numbers, extra smuggled arguments, oversized strings, tables with unexpected fields (`strictInterface`), array holes. Failing packets are dropped and logged before your handler ever runs, and each one strikes the sender.

## 4. Request/response with promises

Replace RemoteFunction patterns with `Invoke` — same ergonomics, but with timeouts, retries, and no hang risk:

```lua
-- Server
Shop:Expect("Purchase", V.string)
Shop:OnInvoke("Purchase", function(player, itemId)
	local ok, receipt = ShopService:TryPurchase(player, itemId) -- may yield
	if not ok then
		error("purchase rejected") -- client sees sanitized "Invoke handler error"
	end
	return receipt
end)
```

```lua
-- Client
Shop:Invoke("Purchase", "sword_01")
	:AndThen(function(receipt)
		showReceipt(receipt)
	end)
	:Catch(function(reason)
		if reason == "InvokeTimeout" then showRetryButton() end
	end)

-- or synchronous style inside any coroutine:
local ok, receipt = Shop:Invoke("Purchase", "sword_01"):Await()
```

Server→client works too, always timeout-bounded: `Shop:InvokeClient(player, "ConfirmDialog", text)`.

## 5. Permission gates with middleware

Middleware sees packets after rate limiting and validation, right before your handlers — the right place for game-logic gates:

```lua
Trading:Use(function(packet)
	if packet.Player and not TradePermits:CanTrade(packet.Player) then
		return "Drop"
	end
	return "Continue"
end)
```

A crashed gate **fails closed** (packet dropped), never open. Global middleware (`Network.Use`) runs before every channel chain — good for logging/analytics.

## 6. React to abuse

```lua
Network.OnSuspiciousActivity:Connect(function(report)
	warn(`{report.Player.Name}: {report.Kind} x{report.Strikes} on {report.Channel} — {report.Reason}`)
	AbuseLog:Record(report)
	if report.Kind == "RateLimit" then
		report.Player:Kick("Network abuse detected")
	end
end)
```

Tighten limits live during an incident (e.g. from an admin command):

```lua
Network.Configure({ RateLimit = { MaxPacketsPerSecond = 20, BurstAllowance = 5 } })
```

`Network.GetAuditLog()` returns the last 256 drops for forensics.

## 7. Big payloads: Serialize (+ Compress)

For snapshots, inventories, and map state, pack once and send one buffer:

```lua
-- Server
local blob = Network.Serialize(inventoryTable)           -- compact binary
Shop:Fire(player, "InventorySnapshot", blob)

-- Very repetitive & large? Layer LZW on top:
Shop:Fire(player, "MapState", Network.Compress(Network.Serialize(mapTable)))
```

```lua
-- Client
Shop:On("InventorySnapshot", function(blob)
	local ok, inventory = pcall(Network.Deserialize, blob) -- pcall remote input
	if ok then render(inventory) end
end)
```

## 8. Debugging a misbehaving system

```lua
Network.Configure({ DebugMode = true, LogLevel = "Debug" })

print(Network.GetStats())        -- sent/received/dropped, per channel, invoke RTT
for _, entry in Network.GetPacketLog() do -- last 128 packets while DebugMode on
	print(entry.Direction, entry.Channel, entry.Event, entry.ArgCount, entry.Player)
end
```

High `Dropped` on one channel usually means a schema mismatch (check Warn logs for the positional reason) or a rate limit set too low for that channel's traffic.
