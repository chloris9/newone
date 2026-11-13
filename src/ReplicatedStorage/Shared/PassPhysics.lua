-- Ground pass simulation, shared by the server (decides the outcome) and the client (layouts,
-- the defender's patrol and the aiming line). Pure functions: same inputs, same result.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PassConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PassConfig"))

local BallCfg = PassConfig.Ball
local Mate = PassConfig.Teammate
local Defender = PassConfig.Defender

export type Patrol = { from: Vector3, to: Vector3, speed: number, phase: number }
export type Layout = { index: number, origin: Vector3, teammates: { Vector3 }, defender: Patrol }
export type PassSim = {
	detail: string, -- GOOD | INTERCEPTED | TOO_HARD | SHORT | WIDE
	outcome: string, -- GOOD | INTERCEPTED | MISS
	eventTime: number, -- when the result is decided (received, intercepted, missed, ball stops)
	endTime: number,
	receiver: number?, -- teammate index for GOOD / TOO_HARD
	speed: number, -- launch speed, stud/s
	ball: { Vector3 }, -- samples every PassConfig.SampleStep
	defender: { Vector3 },
	receiverTrack: { Vector3 }?,
}

local PassPhysics = {}

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function offset(origin: Vector3, xz: { number }): Vector3
	return origin + Vector3.new(xz[1], 0, xz[2])
end

-- Absolute positions for a prepared situation. phase (0..2) sets where the patrol starts.
function PassPhysics.layout(index: number, phase: number): Layout
	local spec = PassConfig.Layouts[index]
	local origin = PassConfig.Origin
	local teammates = {}
	for i, xz in spec.teammates do
		teammates[i] = offset(origin, xz)
	end
	return {
		index = index,
		origin = origin,
		teammates = teammates,
		defender = {
			from = offset(origin, spec.defender.from),
			to = offset(origin, spec.defender.to),
			speed = spec.defender.speed,
			phase = phase,
		},
	}
end

-- Defender on his back-and-forth route, t seconds after the episode started.
function PassPhysics.patrolAt(patrol: Patrol, t: number): Vector3
	local span = (patrol.to - patrol.from).Magnitude
	if span < 1e-3 then
		return patrol.from
	end
	local k = (patrol.phase + t * patrol.speed / span) % 2
	if k > 1 then
		k = 2 - k
	end
	return patrol.from:Lerp(patrol.to, k)
end

-- Drag length -> pass distance (and back), both clamped to the playable range.
function PassPhysics.distanceForPower(power: number): number
	return math.clamp(power * BallCfg.MaxRange, BallCfg.MinRange, BallCfg.MaxRange)
end

function PassPhysics.powerForDistance(distance: number): number
	return math.clamp(distance / BallCfg.MaxRange, 0, 1)
end

function PassPhysics.launchSpeed(distance: number): number
	return math.sqrt(2 * BallCfg.Friction * (distance + BallCfg.Overrun))
end

-- Where the ball is t seconds after a pass of launch speed v0, and its speed.
function PassPhysics.ballAt(start: Vector3, dir: Vector3, v0: number, t: number): (Vector3, number)
	local a = BallCfg.Friction
	t = math.clamp(t, 0, v0 / a)
	return start + dir * (v0 * t - a * t * t / 2), v0 - a * t
end

-- Samples f(t) every SampleStep from 0 to endTime.
local function sample(endTime: number, f: (number) -> Vector3): { Vector3 }
	local out = {}
	local step = PassConfig.SampleStep
	local count = math.ceil(endTime / step)
	for i = 0, count do
		out[i + 1] = f(math.min(i * step, endTime))
	end
	return out
end

-- start: ball spot; dir: unit direction on the ground; distance: intended length;
-- releaseTime: seconds since the episode started (where the patrol is); reaction: defender's
-- reaction time; guided: the defender can't intercept and any reachable ball is controlled.
function PassPhysics.simulate(layout: Layout, start: Vector3, dir: Vector3, distance: number, releaseTime: number, reaction: number, guided: boolean?): PassSim
	local v0 = PassPhysics.launchSpeed(distance)
	local tStop = v0 / BallCfg.Friction
	local patrol = layout.defender
	local function defenderAt(t: number): Vector3
		return PassPhysics.patrolAt(patrol, releaseTime + t)
	end
	local defenderSet = defenderAt(reaction)

	local interceptT, receiveT, receiver, heavyT, heavyIndex
	local step = PassConfig.SimStep
	local t = 0
	while t <= tStop + 1e-9 do
		local p, speed = PassPhysics.ballAt(start, dir, v0, t)
		if not guided then
			local reachable
			if t <= reaction then
				reachable = flat(p - defenderAt(t)).Magnitude <= Defender.Reach
			else
				reachable = flat(p - defenderSet).Magnitude - Defender.Reach <= Defender.Speed * (t - reaction)
			end
			if reachable then
				interceptT = t
				break
			end
		end
		for i, mate in layout.teammates do
			local need = flat(p - mate).Magnitude - Mate.Reach
			if need <= 0 or (t > Mate.Reaction and need <= Mate.Speed * (t - Mate.Reaction) and need <= Mate.MaxMove) then
				if guided or speed <= Mate.ControlMaxSpeed then
					receiveT, receiver = t, i
					break
				elseif not heavyT then
					heavyT, heavyIndex = t, i
				end
			end
		end
		if receiveT then
			break
		end
		t += step
	end

	local detail, eventTime
	if interceptT then
		detail, eventTime = "INTERCEPTED", interceptT
	elseif receiveT then
		detail, eventTime = "GOOD", receiveT
	elseif heavyT then
		detail, eventTime, receiver = "TOO_HARD", heavyT, heavyIndex
	else
		-- Nobody got there: short of the teammate it was meant for, or wide / past him.
		local best, bestDot = layout.teammates[1], -math.huge
		for _, mate in layout.teammates do
			local d = flat(mate - start).Unit:Dot(dir)
			if d > bestDot then
				best, bestDot = mate, d
			end
		end
		local along = flat(best - start):Dot(dir)
		detail = if distance + BallCfg.Overrun < along - Mate.Reach then "SHORT" else "WIDE"
		eventTime = tStop
	end
	local outcome = if detail == "GOOD" then "GOOD" elseif detail == "INTERCEPTED" then "INTERCEPTED" else "MISS"
	local endTime = if detail == "GOOD" or detail == "INTERCEPTED" then eventTime + 0.7 else math.max(eventTime, tStop) + 0.3

	-- Receiver: steps from his spot to meet the ball, then stays with it.
	local receiverTrack, meetPoint
	if receiver then
		local mate = layout.teammates[receiver]
		local at = PassPhysics.ballAt(start, dir, v0, eventTime)
		local toMate = flat(mate - at)
		meetPoint = if toMate.Magnitude > Mate.Reach * 0.7 then at + toMate.Unit * Mate.Reach * 0.7 else mate
		local moveFrom = math.min(Mate.Reaction, eventTime)
		receiverTrack = sample(endTime, function(time)
			if time <= moveFrom then
				return mate
			end
			return mate:Lerp(meetPoint, math.clamp((time - moveFrom) / math.max(eventTime - moveFrom, 1e-3), 0, 1))
		end)
	end

	-- Defender: patrols until he reacts, then runs to the interception point (or chases the ball).
	local interceptPoint
	if interceptT then
		local at = PassPhysics.ballAt(start, dir, v0, interceptT)
		local from = if interceptT <= reaction then defenderAt(interceptT) else defenderSet
		local toDef = flat(from - at)
		interceptPoint = if toDef.Magnitude > Defender.Reach * 0.6 then at + toDef.Unit * Defender.Reach * 0.6 else from
	end
	local chase = defenderSet
	local lastChaseT = reaction
	local defenderTrack = sample(endTime, function(time)
		if time <= reaction and not (interceptT and time >= interceptT) then
			return defenderAt(time)
		end
		if interceptT then
			if interceptT <= reaction then
				return defenderAt(interceptT)
			end
			return defenderSet:Lerp(interceptPoint, math.clamp((time - reaction) / (interceptT - reaction), 0, 1))
		end
		-- Chase the ball until the result is decided, then pull up.
		local until_ = math.min(time, eventTime)
		if until_ > lastChaseT then
			local ballPos = PassPhysics.ballAt(start, dir, v0, until_)
			local towards = flat(ballPos - chase)
			local stepLen = math.min(towards.Magnitude, Defender.Speed * 0.85 * (until_ - lastChaseT))
			if towards.Magnitude > 1e-3 then
				chase += towards.Unit * stepLen
			end
			lastChaseT = until_
		end
		return chase
	end)

	-- Ball: rolls along its line, then stays at the feet of whoever got it.
	local ball = sample(endTime, function(time)
		if time <= eventTime or not (detail == "GOOD" or detail == "INTERCEPTED") then
			return (PassPhysics.ballAt(start, dir, v0, time))
		end
		local holder = if detail == "GOOD" then meetPoint else interceptPoint
		local at = PassPhysics.ballAt(start, dir, v0, eventTime)
		return at:Lerp(holder :: Vector3, math.clamp((time - eventTime) / 0.15, 0, 1) * 0.6)
	end)

	return {
		detail = detail,
		outcome = outcome,
		eventTime = eventTime,
		endTime = endTime,
		receiver = receiver,
		speed = v0,
		ball = ball,
		defender = defenderTrack,
		receiverTrack = receiverTrack,
	}
end

return PassPhysics
