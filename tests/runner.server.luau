--!strict
local TestKit = require(script.Parent.TestKit)

local ok = TestKit.run({
	Signal = require(script.Parent["Signal.spec"]) :: TestKit.Spec,
	Config = require(script.Parent["Config.spec"]) :: TestKit.Spec,
	TableUtil = require(script.Parent["TableUtil.spec"]) :: TestKit.Spec,
})

if not ok then
	error("Test run failed")
end
