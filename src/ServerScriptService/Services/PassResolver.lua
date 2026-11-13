-- Server-only: turns validated pass input into a simulated pass. Never runs on the client.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PassConfig = require(Shared:WaitForChild("PassConfig"))
local PassPhysics = require(Shared:WaitForChild("PassPhysics"))

export type PassInput = { dirX: number, dirZ: number, power: number }
-- guided: tutorial pass to teammate `target` that always arrives (no error, no interception).
-- releaseTime: seconds since the episode started when the pass was played (sets the patrol).
export type PassOptions = { guided: { target: number }?, releaseTime: number }
export type PassResult = {
	input: PassInput,
	outcome: string, -- GOOD | INTERCEPTED | MISS (task progress / history)
	detail: string, -- GOOD | INTERCEPTED | TOO_HARD | SHORT | WIDE (what the player sees)
	speedKmh: number,
	sim: PassPhysics.PassSim,
}

local PassResolver = {}

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function gaussian(rng: Random): number
	local u1 = math.max(rng:NextNumber(), 1e-9)
	local u2 = rng:NextNumber()
	return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
end

function PassResolver.resolve(input: PassInput, layout: PassPhysics.Layout, passing: number, rng: Random, options: PassOptions): PassResult
	local accuracy = PassConfig.Accuracy
	local start = layout.origin
	local dir = Vector3.new(input.dirX, 0, input.dirZ).Unit
	local distance = PassPhysics.distanceForPower(input.power)

	local guided = options.guided
	-- Random parts are always drawn, in the same order, so (seed, input) reproduces a result.
	local skill = math.clamp(passing, 0, 100) / 100
	local cap = accuracy.MaxSigmas
	local angle = math.rad(math.clamp(gaussian(rng), -cap, cap) * lerp(accuracy.AngleAtZeroSkill, accuracy.AngleAtMaxSkill, skill))
	local stretch = 1 + math.clamp(gaussian(rng), -cap, cap) * lerp(accuracy.DistanceAtZeroSkill, accuracy.DistanceAtMaxSkill, skill)
	local reaction = PassConfig.Defender.Reaction + (rng:NextNumber() * 2 - 1) * PassConfig.Defender.ReactionJitter

	if guided then
		local target = layout.teammates[guided.target]
		local toTarget = Vector3.new(target.X - start.X, 0, target.Z - start.Z)
		dir, distance = toTarget.Unit, toTarget.Magnitude
		input = { dirX = dir.X, dirZ = dir.Z, power = PassPhysics.powerForDistance(distance) }
	else
		local c, s = math.cos(angle), math.sin(angle)
		dir = Vector3.new(dir.X * c - dir.Z * s, 0, dir.X * s + dir.Z * c)
		distance *= stretch
	end

	local sim = PassPhysics.simulate(layout, start, dir, distance, options.releaseTime, reaction, guided ~= nil)
	return {
		input = input,
		outcome = sim.outcome,
		detail = sim.detail,
		speedKmh = math.floor(sim.speed + 0.5),
		sim = sim,
	}
end

return PassResolver
