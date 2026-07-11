--!strict
local TestKit = require(script.Parent.TestKit)

local ok = TestKit.run({
	Signal = require(script.Parent["Signal.spec"]) :: TestKit.Spec,
	Config = require(script.Parent["Config.spec"]) :: TestKit.Spec,
	TableUtil = require(script.Parent["TableUtil.spec"]) :: TestKit.Spec,
	Envelope = require(script.Parent["Envelope.spec"]) :: TestKit.Spec,
	Dispatcher = require(script.Parent["Dispatcher.spec"]) :: TestKit.Spec,
	RemoteRegistry = require(script.Parent["RemoteRegistry.spec"]) :: TestKit.Spec,
	ServerTransport = require(script.Parent["ServerTransport.spec"]) :: TestKit.Spec,
	Channel = require(script.Parent["Channel.spec"]) :: TestKit.Spec,
	Validators = require(script.Parent["Validators.spec"]) :: TestKit.Spec,
	SchemaRegistry = require(script.Parent["SchemaRegistry.spec"]) :: TestKit.Spec,
})

if not ok then
	error("Test run failed")
end
