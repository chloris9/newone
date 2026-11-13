-- Match moments, shared by the server (decides everything) and the client (draws it).
--
-- A moment starts outside the box: you either already have the ball (ON_BALL) or a teammate plays
-- it to you first (RECEIVE). Then play goes into slow motion: pressers close you down and the
-- first one to reach you tackles you at `tackleTime` (seconds of decision time). Before that you
-- shoot (from distance, harder), play a ground pass, or a high ball (cross) to a teammate, who
-- then finishes (a header from a cross). Markers stay goal-side of the teammates.
-- Pure functions: the same layout and input always give the same result.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShotConfig = require(Shared:WaitForChild("ShotConfig"))
local PassConfig = require(Shared:WaitForChild("PassConfig"))
local PassPhysics = require(Shared:WaitForChild("PassPhysics"))

local BALL_RADIUS = ShotConfig.Ball.Radius
local Mate = PassConfig.Teammate
local Defender = PassConfig.Defender

local MomentPhysics = {}

MomentPhysics.Config = {
	-- Where moments happen (penalty box ends at Z = 54).
	CarrierX = { -22, 22 },
	CarrierZ = { 60, 74 },
	-- Slow motion while you decide: world speeds are real speeds times this.
	SlowMo = 0.32,
	PresserSpeed = 10, -- stud/s at real speed (x SlowMo while you decide)
	TackleReach = 2.6,
	MinTackleTime = 2.6,
	MaxTackleTime = 6.5,
	RunnerSpeed = 11, -- teammate making a run during the decision (x SlowMo)
	-- Server accepts input this long after the tackle time (network lag), then tackles you.
	TackleGrace = 0.35,
	MaxLag = 0.35,
	-- Ground passes reuse PassConfig.Ball; high balls:
	CrossMinRange = 12,
	CrossMaxRange = 62,
	CrossApexBase = 4,
	CrossApexPerStud = 0.14,
	CrossHeadHeight = 7.2, -- the ball can be won in the air below this (players jump)
	CrossMateReach = 3,
	CrossMateMaxMove = 7,
	CrossMateBonus = 0.8, -- attackers attacking the ball win close calls
	CrossDefenderReach = 2.2,
	CrossDefenderSpeed = 5, -- defenders read high balls late
	CrossDefenderReaction = 0.45,
	CrossAngleScale = 1.6, -- high balls are less accurate than ground passes
	CrossDistanceScale = 2.2,
	-- Shots from distance scatter more: scale = distance / ShotDistance, at least 1.
	ShotScatterPerStud = 1 / ShotConfig.ShotDistance,
	HeaderHeight = 6.2, -- where a header is struck from (ball centre)
	ReceiveIntro = 1.9, -- seconds of the RECEIVE cutscene (pass, control)
	OnBallIntro = 1.1, -- seconds of the ON_BALL cutscene (a few touches forward)
}
local C = MomentPhysics.Config

export type Runner = { from: Vector3, to: Vector3, speed: number }
export type DefenderSpec = { from: Vector3, to: Vector3, speed: number, role: string }
export type Layout = {
	kind: string, -- RECEIVE | ON_BALL
	carrier: Vector3, -- ball on the ground (Y = 0) at your feet when you decide
	toGoal: Vector3,
	passerFrom: Vector3?, -- RECEIVE: where the ball comes from (teammate 2 plays it)
	teammates: { Runner }, -- 1: #7 in the box, 2: #28 (runs forward after a RECEIVE pass)
	defenders: { DefenderSpec },
	tackleTime: number,
	tackler: number,
}

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function unit(v: Vector3, fallback: Vector3): Vector3
	return if v.Magnitude > 1e-4 then v.Unit else fallback
end

local function along(from: Vector3, to: Vector3, speed: number, t: number, stopShort: number?): Vector3
	local delta = flat(to - from)
	local length = math.max(0, delta.Magnitude - (stopShort or 0))
	if length < 1e-4 then
		return from
	end
	return from + delta.Unit * math.min(length, speed * math.max(t, 0))
end

-- opts.receive: a teammate passes to you first; opts.defenders: 2 or 3; opts.timeFactor: >1 gives
-- you more time (effort, stamina).
function MomentPhysics.layout(rng: Random, opts: { receive: boolean, defenders: number, timeFactor: number }): Layout
	local x = C.CarrierX[1] + rng:NextNumber() * (C.CarrierX[2] - C.CarrierX[1])
	local z = C.CarrierZ[1] + rng:NextNumber() * (C.CarrierZ[2] - C.CarrierZ[1])
	local carrier = Vector3.new(x, 0, z)
	local toGoal = unit(Vector3.new(-x * 0.6, 0, -z), Vector3.new(0, 0, -1))
	local side = if x >= 0 then 1 else -1

	-- #7 in the box on the far side, #28 between you and the box, nearer your side.
	local mate1 = Vector3.new(-side * (4 + rng:NextNumber() * 12), 0, 16 + rng:NextNumber() * 12)
	local mate2Spot = Vector3.new(side * (8 + rng:NextNumber() * 18), 0, 32 + rng:NextNumber() * 12)
	local teammates: { Runner } = { { from = mate1, to = mate1, speed = 0 } }
	local passerFrom = nil
	if opts.receive then
		-- He plays it to you from wide and behind, then makes a run to his spot.
		passerFrom = carrier + Vector3.new(side * (12 + rng:NextNumber() * 6), 0, 6 + rng:NextNumber() * 6)
		teammates[2] = { from = passerFrom, to = mate2Spot, speed = C.RunnerSpeed * C.SlowMo }
	else
		teammates[2] = { from = mate2Spot, to = mate2Spot, speed = 0 }
	end

	local timeFactor = math.clamp(opts.timeFactor, 0.6, 1.5)
	local pressSpeed = C.PresserSpeed * C.SlowMo / timeFactor
	local defenders: { DefenderSpec } = {}
	-- Marker: goal-side of #7, a little towards the middle.
	local markFrom = mate1 + unit(Vector3.new(-mate1.X, 0, -mate1.Z), Vector3.new(0, 0, -1)) * 2.8 + Vector3.new((rng:NextNumber() - 0.5) * 2, 0, 0)
	table.insert(defenders, { from = markFrom, to = markFrom + unit(flat(carrier - markFrom), toGoal) * 1.5, speed = 0.4, role = "MARK" })
	-- Presser: in front of you, between you and goal.
	local frontDistance = 12 + rng:NextNumber() * 4
	local frontFrom = carrier + toGoal * frontDistance + toGoal:Cross(Vector3.yAxis) * ((rng:NextNumber() - 0.5) * 8)
	table.insert(defenders, { from = frontFrom, to = carrier, speed = pressSpeed, role = "PRESS" })
	if opts.defenders >= 3 then
		if rng:NextNumber() < 0.5 then
			-- Chaser from behind on the inside.
			local behind = carrier - toGoal * (9 + rng:NextNumber() * 4) + Vector3.new(-side * (5 + rng:NextNumber() * 4), 0, 0)
			table.insert(defenders, { from = behind, to = carrier, speed = pressSpeed * 0.95, role = "PRESS" })
		else
			-- Second marker, looser, on #28.
			local markFrom2 = mate2Spot + unit(Vector3.new(-mate2Spot.X, 0, -mate2Spot.Z), Vector3.new(0, 0, -1)) * 4 + Vector3.new(-side * 2, 0, 0)
			table.insert(defenders, { from = markFrom2, to = markFrom2 + unit(flat(carrier - markFrom2), toGoal) * 2, speed = 0.5, role = "MARK" })
		end
	end

	-- The first presser to reach you tackles.
	local tackleTime, tackler = math.huge, 2
	for i, d in defenders do
		if d.role == "PRESS" then
			local t = math.max(0, flat(d.to - d.from).Magnitude - C.TackleReach) / d.speed
			if t < tackleTime then
				tackleTime, tackler = t, i
			end
		end
	end
	tackleTime = math.clamp(tackleTime, C.MinTackleTime, C.MaxTackleTime)
	-- Keep the presser's arrival in step with the clamped time.
	local d = defenders[tackler]
	d.speed = math.max(0, flat(d.to - d.from).Magnitude - C.TackleReach) / tackleTime

	return {
		kind = if opts.receive then "RECEIVE" else "ON_BALL",
		carrier = carrier,
		toGoal = toGoal,
		passerFrom = passerFrom,
		teammates = teammates,
		defenders = defenders,
		tackleTime = tackleTime,
		tackler = tackler,
	}
end

function MomentPhysics.intro(layout: Layout): number
	return if layout.kind == "RECEIVE" then C.ReceiveIntro else C.OnBallIntro
end

-- Defender i, t seconds into the decision (slow motion).
function MomentPhysics.defenderAt(layout: Layout, i: number, t: number): Vector3
	local d = layout.defenders[i]
	if d.role == "PRESS" then
		return along(d.from, d.to, d.speed, t, C.TackleReach)
	end
	return along(d.from, d.to, d.speed, t)
end

function MomentPhysics.mateAt(layout: Layout, i: number, t: number): Vector3
	local m = layout.teammates[i]
	return along(m.from, m.to, m.speed, t)
end

-- Ball spot (ball centre) for a shot from the carrier's feet.
function MomentPhysics.shotSpot(layout: Layout): Vector3
	return Vector3.new(layout.carrier.X, BALL_RADIUS, layout.carrier.Z)
end

function MomentPhysics.shotScatterScale(layout: Layout): number
	return math.max(1, flat(layout.carrier).Magnitude * C.ShotScatterPerStud)
end

-- High ball of horizontal length `distance`: flight time and apex.
function MomentPhysics.crossFlight(distance: number): (number, number)
	local flightTime = math.clamp(0.75 + distance / 38, 1, 2.3)
	local apex = C.CrossApexBase + distance * C.CrossApexPerStud
	return flightTime, apex
end

-- Ball centre of a high ball t seconds after it was played (bounces and rolls on after landing).
function MomentPhysics.crossBallAt(start: Vector3, dir: Vector3, distance: number, t: number): Vector3
	local flightTime, apex = MomentPhysics.crossFlight(distance)
	local horizontal = distance / flightTime
	if t <= flightTime then
		local u = t / flightTime
		return Vector3.new(start.X, 0, start.Z) + dir * (horizontal * t) + Vector3.new(0, BALL_RADIUS + 4 * apex * u * (1 - u), 0)
	end
	-- One low bounce, then rolling to a stop.
	local after = t - flightTime
	local v = horizontal * 0.55
	local stopT = v / PassConfig.Ball.Friction
	local s = math.min(after, stopT)
	local roll = v * s - PassConfig.Ball.Friction * s * s / 2
	local bounce = if after < 0.5 then 1.6 * math.sin(after / 0.5 * math.pi) else 0
	return Vector3.new(start.X, 0, start.Z) + dir * (distance + roll) + Vector3.new(0, BALL_RADIUS + bounce, 0)
end

local function sample(endTime: number, f: (number) -> Vector3): { Vector3 }
	local out = {}
	local step = PassConfig.SampleStep
	local count = math.ceil(endTime / step)
	for i = 0, count do
		out[i + 1] = f(math.min(i * step, endTime))
	end
	return out
end

export type PassSim = {
	detail: string, -- GOOD | INTERCEPTED | CLEARED | TOO_HARD | SHORT | WIDE | LONG
	outcome: string, -- GOOD | INTERCEPTED | MISS
	high: boolean,
	eventTime: number,
	endTime: number,
	receiver: number?,
	meet: Vector3?, -- where the receiver takes it (ball centre for a header)
	header: boolean,
	interceptor: number?,
	speed: number,
	ball: { Vector3 }, -- ball centre samples
	defenders: { { Vector3 } },
	mates: { { Vector3 } },
}

-- releaseTime: decision seconds when the ball was played; reaction: defenders' reaction (ground).
function MomentPhysics.simulatePass(layout: Layout, dir: Vector3, distance: number, releaseTime: number, reaction: number, high: boolean): PassSim
	local start = layout.carrier
	local defenders, mates = {}, {}
	for i in layout.defenders do
		defenders[i] = MomentPhysics.defenderAt(layout, i, releaseTime)
	end
	for i in layout.teammates do
		mates[i] = MomentPhysics.mateAt(layout, i, releaseTime)
	end
	local step = PassConfig.SimStep

	local ballAt: (number) -> Vector3
	local tStop, v0
	if high then
		local flightTime = MomentPhysics.crossFlight(distance)
		v0 = distance / flightTime
		tStop = flightTime + 0.55 * v0 / PassConfig.Ball.Friction
		ballAt = function(t)
			return MomentPhysics.crossBallAt(start, dir, distance, t)
		end
	else
		v0 = PassPhysics.launchSpeed(distance)
		tStop = v0 / PassConfig.Ball.Friction
		ballAt = function(t)
			local p = PassPhysics.ballAt(start, dir, v0, t)
			return p + Vector3.new(0, BALL_RADIUS, 0)
		end
	end

	local eventTime, receiver, interceptor, heavyT, heavyIndex, header = nil, nil, nil, nil, nil, false
	local t = 0
	while t <= tStop + 1e-9 do
		local p = ballAt(t)
		local ground = flat(p)
		if high then
			local flightTime = MomentPhysics.crossFlight(distance)
			local u = t / flightTime
			-- Blocked straight off the boot by someone right in front of you.
			if u < 0.25 and p.Y < 3 then
				for i, d in defenders do
					if flat(ground - d).Magnitude <= Defender.Reach then
						eventTime, interceptor = t, i
						break
					end
				end
			elseif u > 0.5 and p.Y <= C.CrossHeadHeight then
				-- Contest in the air (or for the dropping ball): best margin wins.
				local best, bestMargin, bestIsMate = nil, math.huge, false
				for i, m in mates do
					local need = flat(ground - m).Magnitude - C.CrossMateReach
					local can = math.min(C.CrossMateMaxMove, Mate.Speed * math.max(0, t - Mate.Reaction))
					if need <= can then
						local margin = need - can - C.CrossMateBonus
						if margin < bestMargin then
							best, bestMargin, bestIsMate = i, margin, true
						end
					end
				end
				for i, d in defenders do
					local need = flat(ground - d).Magnitude - C.CrossDefenderReach
					local can = C.CrossDefenderSpeed * math.max(0, t - C.CrossDefenderReaction)
					if need <= can and need - can < bestMargin then
						best, bestMargin, bestIsMate = i, need - can, false
					end
				end
				if best then
					eventTime = t
					if bestIsMate then
						receiver = best
						header = p.Y > 2.8
					else
						interceptor = best
					end
				end
			end
		else
			for i, d in defenders do
				local reachable
				if t <= reaction then
					reachable = flat(ground - d).Magnitude <= Defender.Reach
				else
					reachable = flat(ground - d).Magnitude - Defender.Reach <= Defender.Speed * (t - reaction)
				end
				if reachable then
					eventTime, interceptor = t, i
					break
				end
			end
			if not eventTime then
				local _, speed = PassPhysics.ballAt(start, dir, v0, t)
				for i, m in mates do
					local need = flat(ground - m).Magnitude - Mate.Reach
					if need <= 0 or (t > Mate.Reaction and need <= Mate.Speed * (t - Mate.Reaction) and need <= Mate.MaxMove) then
						if speed <= Mate.ControlMaxSpeed then
							eventTime, receiver = t, i
							break
						elseif not heavyT then
							heavyT, heavyIndex = t, i
						end
					end
				end
			end
		end
		if eventTime then
			break
		end
		t += step
	end

	local detail
	if interceptor then
		detail = if high then "CLEARED" else "INTERCEPTED"
	elseif receiver then
		detail = "GOOD"
	elseif heavyT then
		detail, eventTime, receiver = "TOO_HARD", heavyT, heavyIndex
	else
		-- Nobody got there: short of the nearest teammate on the line, wide of him, or over him.
		local best, bestDot = mates[1], -math.huge
		for _, m in mates do
			local d = unit(flat(m - start), dir):Dot(dir)
			if d > bestDot then
				best, bestDot = m, d
			end
		end
		local alongLine = flat(best - start):Dot(dir)
		local reach = if high then distance else distance + PassConfig.Ball.Overrun
		detail = if reach < alongLine - Mate.Reach then "SHORT" elseif high and reach > alongLine + Mate.Reach * 2 then "LONG" else "WIDE"
		eventTime = tStop
	end
	local outcome = if detail == "GOOD" then "GOOD" elseif detail == "INTERCEPTED" or detail == "CLEARED" then "INTERCEPTED" else "MISS"
	local holds = detail == "GOOD" or interceptor ~= nil
	local endTime = if holds then eventTime + 0.7 else math.max(eventTime, tStop) + 0.3

	-- Whoever gets it moves to meet the ball; the others hold their ground.
	local eventBall = ballAt(eventTime)
	local meet = nil
	local function approach(from: Vector3, reach: number, moveFrom: number)
		local toFrom = flat(from - eventBall)
		local point = if toFrom.Magnitude > reach * 0.7 then flat(eventBall) + toFrom.Unit * reach * 0.7 else from
		return function(time: number): Vector3
			if time <= moveFrom then
				return from
			end
			return from:Lerp(point, math.clamp((time - moveFrom) / math.max(eventTime - moveFrom, 1e-3), 0, 1))
		end,
			point
	end
	local mateTracks = {}
	for i, m in mates do
		if i == receiver then
			local f, point = approach(m, if high then C.CrossMateReach else Mate.Reach, math.min(Mate.Reaction, eventTime))
			meet = if header then Vector3.new(point.X, eventBall.Y, point.Z) else point
			mateTracks[i] = sample(endTime, f)
		else
			mateTracks[i] = sample(endTime, function()
				return m
			end)
		end
	end
	local defenderTracks = {}
	for i, d in defenders do
		if i == interceptor then
			local f = approach(d, if high then C.CrossDefenderReach else Defender.Reach, math.min(if high then C.CrossDefenderReaction else reaction, eventTime))
			defenderTracks[i] = sample(endTime, f)
		else
			-- Everyone else drifts towards the ball after reacting, then pulls up.
			local react = if high then C.CrossDefenderReaction else reaction
			defenderTracks[i] = sample(endTime, function(time)
				if time <= react then
					return d
				end
				local towards = flat(ballAt(math.min(time, eventTime)) - d)
				return d + unit(towards, Vector3.zero) * math.min(towards.Magnitude * 0.5, Defender.Speed * 0.6 * (time - react))
			end)
		end
	end
	local holder = nil
	if receiver and detail == "GOOD" then
		holder = flat(mateTracks[receiver][#mateTracks[receiver]])
	elseif interceptor then
		holder = flat(defenderTracks[interceptor][#defenderTracks[interceptor]])
	end
	local ball = sample(endTime, function(time)
		if time <= eventTime or not holder then
			return ballAt(time)
		end
		if header then
			return eventBall -- the header is the next shot: the ball stays at his head
		end
		local k = math.clamp((time - eventTime) / 0.25, 0, 1)
		local at = ballAt(eventTime)
		local feet = holder + Vector3.new(0, BALL_RADIUS, 0)
		return at:Lerp(feet + flat(at - feet).Unit * 0, k * 0.6)
	end)

	return {
		detail = detail,
		outcome = outcome,
		high = high,
		eventTime = eventTime,
		endTime = endTime,
		receiver = if detail == "GOOD" or detail == "TOO_HARD" then receiver else nil,
		meet = meet,
		header = header and detail == "GOOD",
		interceptor = interceptor,
		speed = v0,
		ball = ball,
		defenders = defenderTracks,
		mates = mateTracks,
	}
end

return MomentPhysics
