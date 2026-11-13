-- Match moments, shared by the server (decides everything) and the client (draws it).
--
-- A moment starts outside the box: a teammate plays the ball to you (RECEIVE) or you already have
-- it (ON_BALL). Each step of the moment is two choices, as in New Star Soccer:
--   1. the arrow: drag from the ball to where it should go (a teammate, space, or the goal);
--   2. the strike: tap the part of the ball you hit. Below the centre lifts it (a lofted pass,
--      a cross, a chipped shot), above keeps it low and fast, the sides curl it the other way,
--      and the edge of the ball scuffs it.
-- Play is in slow motion while you aim; the presser reaches you at layout.tackleTime.
-- A teammate near goal finishes your pass himself; one further out plays it straight back into
-- your run (a one-two) and you get the next step closer to goal.
-- Pure functions: the same layout and input always give the same result.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShotConfig = require(Shared:WaitForChild("ShotConfig"))

local BALL_RADIUS = ShotConfig.Ball.Radius
local GOAL_HALF_WIDTH = ShotConfig.Goal.Width / 2
local Phys = ShotConfig.Physics
local GRAVITY = Vector3.new(0, -Phys.Gravity, 0)

local MomentPhysics = {}

MomentPhysics.Config = {
	-- Where moments start (the penalty box ends at Z = 54).
	CarrierX = { -22, 22 },
	CarrierZ = { 60, 70 },
	SlowMo = 0.35, -- how fast the world moves while you aim
	DecisionTime = 7, -- seconds to aim before the presser gets there (fresh, effort 2)
	StepDecisionTime = 5.5, -- after a one-two
	StrikeTime = 3, -- seconds to hit the ball on the strike screen
	MaxLag = 0.4,
	Grace = 0.6, -- network slack on the server's deadlines
	MaxSteps = 3,
	TackleReach = 2.6,
	FinishDistance = 36, -- a teammate this close to goal shoots; further out he plays a one-two
	-- Arrow
	MinArrow = 5,
	MaxArrow = 80,
	MaxPassRange = 64,
	ShotZoneZ = 6, -- an arrow ending past this line, near the goal, is a shot
	ShotZoneHalfWidth = GOAL_HALF_WIDTH + 12,
	-- Strike (hit point on the ball, -1..1 each way, +Y is the top of the ball)
	CleanRadius = 0.7, -- clean contact inside this; scuffed towards the edge
	LoftFrom = -0.22, -- hitting lower than this lifts the ball
	MinLoft = 16, -- degrees
	MaxLoft = 48,
	SideSpin = 8, -- rad/s at a full side hit (hit the right side: it curls left)
	TopSpin = 6,
	-- Ball on the grass
	Friction = 18,
	Overrun = 5,
	Restitution = 0.45,
	BounceKeep = 0.8,
	ControlSpeed = 34, -- faster ground balls bounce off the receiver
	-- Players
	MateReach = 2.6,
	MateSpeed = 12,
	MateReaction = 0.1,
	MateMaxMove = 8,
	HeaderHeight = 7,
	MateBonus = 0.5, -- attackers attacking the ball win close calls
	MateAirBonus = 1.4, -- ...and more so in the air: they know where the cross is going
	DefReach = 2.3,
	DefSpeed = 9,
	DefReaction = 0.35,
	MarkerDelay = 0.25, -- markers watch their man first
	DefAirReaction = 0.5,
	DefAirSpeed = 6.5,
	DefHeaderHeight = 6.4,
	OpenLane = 5, -- a teammate is "calling" when no defender is this close to the lane
	-- Shots
	ShotScatterBase = 0.2, -- spread (x the shooter's skill spread) of a clean strike...
	ShotScatterPerStud = 0.006, -- ...growing a little with distance
	ShotSideSpin = 10, -- side spin boost on shots, so the curl is plain to see
	LongShotKeeperDelayPerStud = 0.0035, -- long shots: the keeper is a little late, not hopeless
	FinishScatterDistance = 26,
	HeaderSpotHeight = 6.2,
	BlockRange = 26, -- defenders can block a shot in its first studs
	BlockReach = 1.35, -- body half-width plus the ball: only shots right at him are blocked
	BlockMinGap = 3, -- closer than this he is tackling, not blocking
	BlockHeight = 5.6, -- the ball must be higher than this to clear a defender (he is ~7 studs tall)
	-- Cutscenes (client), seconds
	ReceiveIntro = 1.9,
	OnBallIntro = 1.2,
	OneTwoTime = 1.7,
}
local C = MomentPhysics.Config

export type Spec = { from: Vector3, to: Vector3, speed: number, role: string, number: number? }
export type Layout = {
	kind: string, -- RECEIVE | ON_BALL | ONE_TWO
	step: number,
	carrier: Vector3, -- ball at your feet (Y = 0) when you decide
	toGoal: Vector3,
	passerFrom: Vector3?, -- RECEIVE / ONE_TWO: where the ball comes from
	passer: number?, -- teammate index who plays it to you
	teammates: { Spec }, -- 1: #7 up front, 2: #28 in support
	defenders: { Spec },
	tackleTime: number,
	tackler: number,
}

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function unit(v: Vector3, fallback: Vector3): Vector3
	return if v.Magnitude > 1e-4 then v.Unit else fallback
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function along(from: Vector3, to: Vector3, speed: number, t: number, stopShort: number?): Vector3
	local delta = flat(to - from)
	local length = math.max(0, delta.Magnitude - (stopShort or 0))
	if length < 1e-4 then
		return from
	end
	return from + delta.Unit * math.min(length, speed * math.max(t, 0))
end

local function towardsGoal(p: Vector3): Vector3
	return unit(Vector3.new(-p.X * 0.6, 0, -p.Z), Vector3.new(0, 0, -1))
end

-- Distance from p to the segment a-b on the ground.
local function laneDistance(p: Vector3, a: Vector3, b: Vector3): number
	local ab = flat(b - a)
	local ap = flat(p - a)
	local t = math.clamp(ap:Dot(ab) / math.max(ab:Dot(ab), 1e-6), 0, 1)
	return (ap - ab * t).Magnitude
end

---------------------------------------------------------------- situations

local function marker(of: Vector3, carrier: Vector3, gap: number, rng: Random): Vector3
	-- Goal-side of his man, shading towards the ball.
	local goalSide = unit(Vector3.new(-of.X, 0, -of.Z), Vector3.new(0, 0, -1))
	local toBall = unit(flat(carrier - of), goalSide)
	return of + (goalSide * 0.8 + toBall * 0.35).Unit * gap + Vector3.new((rng:NextNumber() - 0.5) * 1.2, 0, 0)
end

local function finishLayout(layout: Layout, rng: Random, decisionTime: number): Layout
	-- The first presser to reach you tackles; his speed is set so he gets there at decisionTime.
	local tackler, best = 0, math.huge
	for i, d in layout.defenders do
		if d.role == "PRESS" then
			local dist = flat(d.to - d.from).Magnitude
			if dist < best then
				tackler, best = i, dist
			end
		end
	end
	layout.tackleTime = decisionTime
	layout.tackler = tackler
	for i, d in layout.defenders do
		if d.role == "PRESS" then
			local reach = math.max(0, flat(d.to - d.from).Magnitude - C.TackleReach)
			-- The tackler arrives on time, the others a little later.
			d.speed = reach / (if i == tackler then decisionTime else decisionTime * (1.15 + rng:NextNumber() * 0.2))
		end
	end
	return layout
end

-- opts.receive: a teammate passes to you first; opts.defenders: 2 or 3; opts.timeFactor: > 1
-- gives you more time (effort, stamina).
function MomentPhysics.layout(rng: Random, opts: { receive: boolean, defenders: number, timeFactor: number }): Layout
	local x = lerp(C.CarrierX[1], C.CarrierX[2], rng:NextNumber())
	local z = lerp(C.CarrierZ[1], C.CarrierZ[2], rng:NextNumber())
	local carrier = Vector3.new(x, 0, z)
	local toGoal = towardsGoal(carrier)
	local side = if x >= 0 then 1 else -1

	-- #7 up front on the far side, #28 in support towards the edge of the box on your side.
	local striker = Vector3.new(-side * lerp(2, 16, rng:NextNumber()), 0, lerp(18, 30, rng:NextNumber()))
	local support = Vector3.new(math.clamp(x + side * lerp(10, 20, rng:NextNumber()), -40, 40), 0, lerp(38, 48, rng:NextNumber()))
	local teammates = {
		{ from = striker, to = striker, speed = 0, role = "STRIKER", number = 7 },
		{ from = support, to = support, speed = 0, role = "SUPPORT", number = 28 },
	}
	local passerFrom = nil
	if opts.receive then
		-- #28 plays it to you from deep, then runs to his support spot while you aim.
		passerFrom = carrier + Vector3.new(side * lerp(10, 15, rng:NextNumber()), 0, lerp(7, 11, rng:NextNumber()))
		teammates[2].from = passerFrom
		teammates[2].speed = 4
	end

	local defenders: { Spec } = {}
	-- Marker on #7, sometimes caught ball-watching (then #7 is free for a pass).
	local looseMark = rng:NextNumber() < 0.25
	local markAt = marker(striker, carrier, if looseMark then 6.5 else 2.8, rng)
	table.insert(defenders, { from = markAt, to = markAt, speed = 0, role = "MARK", number = 4 })
	-- Presser from in front, coming at you from the side away from #28, so that pass stays on.
	local away = -side
	local pressFrom = carrier + toGoal * lerp(13, 16, rng:NextNumber()) + toGoal:Cross(Vector3.yAxis) * (away * lerp(3, 6, rng:NextNumber()))
	table.insert(defenders, { from = pressFrom, to = carrier, speed = 0, role = "PRESS", number = 5 })
	if opts.defenders >= 3 then
		if rng:NextNumber() < 0.5 then
			-- Second presser chasing from behind on the inside.
			local behind = carrier - toGoal * lerp(10, 13, rng:NextNumber()) + Vector3.new(away * lerp(4, 7, rng:NextNumber()), 0, 0)
			table.insert(defenders, { from = behind, to = carrier, speed = 0, role = "PRESS", number = 3 })
		else
			-- Covering defender in the box, central: makes crosses and the striker's finish harder.
			local cover = Vector3.new(lerp(-5, 5, rng:NextNumber()), 0, lerp(11, 15, rng:NextNumber()))
			table.insert(defenders, { from = cover, to = cover, speed = 0, role = "COVER", number = 3 })
		end
	end

	local timeFactor = math.clamp(opts.timeFactor, 0.7, 1.3)
	return finishLayout({
		kind = if opts.receive then "RECEIVE" else "ON_BALL",
		step = 1,
		carrier = carrier,
		toGoal = toGoal,
		passerFrom = passerFrom,
		passer = if opts.receive then 2 else nil,
		teammates = teammates,
		defenders = defenders,
		tackleTime = 0,
		tackler = 0,
	}, rng, C.DecisionTime * timeFactor)
end

-- After a one-two: you ran on and teammate `passer` (standing at `from`) played it back to you.
-- `defenders` are where the defenders were when he got the ball.
function MomentPhysics.oneTwo(rng: Random, previous: Layout, passer: number, from: Vector3, defenders: { Vector3 }, timeFactor: number): Layout
	local old = previous.carrier
	local z = math.clamp(math.min(old.Z - 18, from.Z - 5), 36, 48)
	local x = math.clamp(lerp(old.X, from.X, 0.35) * 0.55, -18, 18)
	local carrier = Vector3.new(x, 0, z)
	if flat(carrier - from).Magnitude < 9 then
		carrier = from + unit(flat(carrier - from), Vector3.new(0, 0, -1)) * 9
	end
	local toGoal = towardsGoal(carrier)
	local teammates = table.clone(previous.teammates)
	for i, m in teammates do
		local at = if i == passer then from else m.to
		teammates[i] = { from = at, to = at, speed = 0, role = m.role, number = m.number }
	end
	-- #7 drifts to stay onside and away from his marker.
	local striker = teammates[1]
	if passer ~= 1 then
		local drift = Vector3.new(lerp(-3, 3, rng:NextNumber()), 0, lerp(-2, 1, rng:NextNumber()))
		striker.from = striker.from + drift
		striker.to = striker.from
	end

	local out: { Spec } = {}
	local side = if x >= 0 then 1 else -1
	for i, d in previous.defenders do
		local at = defenders[i] or d.from
		if d.role == "MARK" then
			local m = marker(striker.from, carrier, 2.8, rng)
			table.insert(out, { from = at, to = m, speed = 6, role = "MARK", number = d.number })
		elseif d.role == "COVER" then
			table.insert(out, { from = at, to = d.to, speed = 0, role = "COVER", number = d.number })
		else
			-- Pressers recover: the nearest comes at you, the other chases.
			table.insert(out, { from = at, to = carrier, speed = 0, role = "PRESS", number = d.number })
		end
	end
	-- One defender steps out of the line to meet you.
	local stepOut = carrier + toGoal * lerp(9, 11, rng:NextNumber()) + toGoal:Cross(Vector3.yAxis) * (-side * lerp(4, 7, rng:NextNumber()))
	table.insert(out, { from = stepOut, to = carrier, speed = 0, role = "PRESS", number = 6 })
	if #out > 3 then
		-- Keep three: drop the presser furthest from the new spot.
		local worst, worstD = nil, -1
		for i, d in out do
			if d.role == "PRESS" and i ~= #out then
				local dist = flat(d.from - carrier).Magnitude
				if dist > worstD then
					worst, worstD = i, dist
				end
			end
		end
		if worst then
			table.remove(out, worst)
		end
	end

	return finishLayout({
		kind = "ONE_TWO",
		step = previous.step + 1,
		carrier = carrier,
		toGoal = toGoal,
		passerFrom = from,
		passer = passer,
		teammates = teammates,
		defenders = out,
		tackleTime = 0,
		tackler = 0,
	}, rng, C.StepDecisionTime * math.clamp(timeFactor, 0.7, 1.3))
end

function MomentPhysics.intro(layout: Layout): number
	if layout.kind == "RECEIVE" then
		return C.ReceiveIntro
	elseif layout.kind == "ONE_TWO" then
		return C.OneTwoTime
	end
	return C.OnBallIntro
end

-- Defender i, t seconds into the decision.
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

-- Whether teammate i is free for a pass along the ground at decision time t (no defender near the
-- lane from the ball to him). The client shows these with a ball bubble.
function MomentPhysics.isOpen(layout: Layout, i: number, t: number): boolean
	local mate = MomentPhysics.mateAt(layout, i, t)
	for d in layout.defenders do
		local at = MomentPhysics.defenderAt(layout, d, t)
		if laneDistance(at, layout.carrier, mate) < C.OpenLane then
			return false
		end
	end
	return true
end

---------------------------------------------------------------- the arrow and the strike

-- Arrow end on the ground -> SHOT (into the goal) or PASS.
function MomentPhysics.classify(layout: Layout, target: Vector3): string
	local from = layout.carrier
	if target.Z <= C.ShotZoneZ and from.Z > target.Z then
		-- Where the arrow line crosses the goal line.
		local k = from.Z / math.max(from.Z - target.Z, 1e-3)
		local crossX = from.X + (target.X - from.X) * k
		if math.abs(crossX) <= C.ShotZoneHalfWidth then
			return "SHOT"
		end
	end
	return "PASS"
end

export type Strike = { hitX: number, hitY: number, scuff: number, lofted: boolean, loft: number, side: number, top: number }

-- Where you hit the ball (hitX right, hitY up, both -1..1) -> what the ball does.
function MomentPhysics.strike(hitX: number, hitY: number): Strike
	local r = math.sqrt(hitX * hitX + hitY * hitY)
	if r > 1 then
		hitX, hitY, r = hitX / r, hitY / r, 1
	end
	local scuff = math.clamp((r - C.CleanRadius) / (1 - C.CleanRadius), 0, 1)
	local lofted = hitY < C.LoftFrom
	local loftT = math.clamp((C.LoftFrom - hitY) / (1 + C.LoftFrom), 0, 1)
	return {
		hitX = hitX,
		hitY = hitY,
		scuff = scuff,
		lofted = lofted,
		loft = if lofted then lerp(C.MinLoft, C.MaxLoft, loftT) else 0,
		-- Right side of the ball: spin about +Y, which curls it to the left of its path.
		side = C.SideSpin * hitX,
		-- Top: top spin (dips, skids on); bottom: back spin (lift).
		top = if hitY > 0 then -C.TopSpin * hitY else C.TopSpin * 0.6 * -hitY,
	}
end

-- Spin vector for a ball travelling along dir (ShotPhysics convention: acceleration = spin x v).
-- Back spin (positive top) is about the travel direction's right axis and lifts the ball.
local function spinVector(dir: Vector3, s: Strike): Vector3
	local right = dir:Cross(Vector3.yAxis)
	return Vector3.new(0, s.side, 0) + right * s.top
end

-- Shot for ShotResolver: the point on the goal plane it is aimed at, power, spin and scatter.
-- The ball ends where the arrow crosses the goal line (give or take a little, more if you scuff
-- it); where you hit the ball decides how it gets there: low = higher, high = lower, a side = it
-- curls (starting out wide and bending back in, round a defender if need be).
function MomentPhysics.shotInput(layout: Layout, target: Vector3, s: Strike, over: number)
	local from = layout.carrier
	local k = from.Z / math.max(from.Z - target.Z, 1e-3)
	local crossX = from.X + (target.X - from.X) * k
	-- Hit low on the ball: it rises; high: it stays down. The centre is about a third of the way up.
	local height = 0.3 - s.hitY * 0.85
	local dir = unit(flat(target - from), Vector3.new(0, 0, -1))
	local distance = flat(from).Magnitude
	local goalHeight = ShotConfig.Goal.Height
	local y = BALL_RADIUS + math.clamp(height, 0, 1) * (goalHeight - 2 * BALL_RADIUS) + math.max(0, height - 1) * 8
	local aimX = math.clamp(crossX / (GOAL_HALF_WIDTH - BALL_RADIUS), -1, 1)
	local spin = spinVector(dir, s)
	return {
		aimX = aimX,
		aimY = math.clamp(height, 0, 1),
		aimPoint = Vector3.new(crossX, y, 0),
		power = math.clamp(0.74 + 0.22 * math.clamp(over / 14, 0, 1) + (if s.hitY > 0 then 0.06 * s.hitY else 0) - 0.3 * s.scuff, 0.3, 1),
		spin = Vector3.new(0, spin.Y * C.ShotSideSpin, 0) + Vector3.new(spin.X, 0, spin.Z) * 0.6,
		scatterScale = (C.ShotScatterBase + distance * C.ShotScatterPerStud) * (1 + 2.5 * s.scuff),
		keeperDelay = math.max(0, distance - ShotConfig.ShotDistance) * C.LongShotKeeperDelayPerStud,
		steady = true,
	}
end

function MomentPhysics.shotSpot(layout: Layout): Vector3
	return Vector3.new(layout.carrier.X, BALL_RADIUS, layout.carrier.Z)
end

---------------------------------------------------------------- ball flight

local SIM_STEP = 1 / 120
local SAMPLE_STEP = 1 / 60
MomentPhysics.SampleStep = SAMPLE_STEP

local function acceleration(v: Vector3, spin: Vector3, onGround: boolean): Vector3
	if onGround then
		local horizontal = Vector3.new(v.X, 0, v.Z)
		local speed = horizontal.Magnitude
		if speed < 1e-3 then
			return Vector3.zero
		end
		-- Rolling resistance, and the side spin still bends it a little.
		local curl = Vector3.new(0, spin.Y, 0):Cross(horizontal) * (Phys.Magnus * 0.6)
		return -horizontal / speed * C.Friction + curl
	end
	return GRAVITY - v * (Phys.Drag * v.Magnitude) + spin:Cross(v) * Phys.Magnus
end

-- Free ball from start (ball centre) with velocity v0 and spin: samples every SAMPLE_STEP until it
-- stops, leaves the pitch, or maxTime. Also returns where it first lands (nil if it never does).
function MomentPhysics.flight(start: Vector3, v0: Vector3, spin: Vector3, maxTime: number?): ({ Vector3 }, Vector3?, number?)
	local p, v, w, t = start, v0, spin, 0
	local onGround = p.Y <= BALL_RADIUS + 1e-3 and v.Y <= 0.5
	if onGround then
		v = Vector3.new(v.X, 0, v.Z)
	end
	local samples = { p }
	local nextSample = SAMPLE_STEP
	local landing, landingT = nil, nil
	local limit = maxTime or 4
	while t < limit do
		local a = acceleration(v, w, onGround)
		local mid = v + a * (SIM_STEP / 2)
		local nextV = v + acceleration(mid, w, onGround) * SIM_STEP
		if onGround then
			-- Friction stops the ball rather than reversing it.
			local before, after = Vector3.new(v.X, 0, v.Z), Vector3.new(nextV.X, 0, nextV.Z)
			if after:Dot(before) <= 0 then
				nextV = Vector3.zero
			end
			nextV = Vector3.new(nextV.X, 0, nextV.Z)
		end
		p += mid * SIM_STEP
		v = nextV
		w *= 1 - (if onGround then 2 else Phys.SpinDecay) * SIM_STEP
		t += SIM_STEP
		if not onGround and p.Y <= BALL_RADIUS then
			if not landing then
				landing, landingT = Vector3.new(p.X, 0, p.Z), t
			end
			p = Vector3.new(p.X, BALL_RADIUS, p.Z)
			if v.Y < -5 then
				v = Vector3.new(v.X * C.BounceKeep, -v.Y * C.Restitution, v.Z * C.BounceKeep)
				w *= 0.6
			else
				onGround = true
				v = Vector3.new(v.X, 0, v.Z)
			end
		end
		while t >= nextSample do
			table.insert(samples, p)
			nextSample += SAMPLE_STEP
		end
		if onGround and v.Magnitude < 0.3 then
			break
		end
		if p.Z < -2 or math.abs(p.X) > 115 or p.Z > 110 then
			break
		end
	end
	return samples, landing, landingT
end

-- Launch for a pass of the intended length along dir with this strike: rolls (or first lands) at
-- about `distance`. Returns velocity and spin.
function MomentPhysics.launch(start: Vector3, dir: Vector3, distance: number, s: Strike): (Vector3, Vector3)
	local spin = spinVector(dir, s)
	if not s.lofted then
		-- Along the grass: friction decides the speed.
		local speed = math.sqrt(2 * C.Friction * (distance + C.Overrun))
		for _ = 1, 3 do
			local samples = MomentPhysics.flight(start, dir * speed, spin)
			local travelled = flat(samples[#samples] - start).Magnitude
			speed *= math.sqrt((distance + C.Overrun) / math.max(travelled, 1))
		end
		return dir * speed, spin
	end
	local e = math.rad(s.loft)
	local launchDir = (dir * math.cos(e) + Vector3.yAxis * math.sin(e)).Unit
	local speed = math.sqrt(Phys.Gravity * math.max(distance, 4) / math.sin(2 * e))
	for _ = 1, 4 do
		local _, landing = MomentPhysics.flight(start, launchDir * speed, spin, 5)
		local landed = if landing then flat(landing - start).Magnitude else distance
		speed *= math.sqrt(distance / math.max(landed, 1))
	end
	return launchDir * speed, spin
end

local function sample(endTime: number, f: (number) -> Vector3): { Vector3 }
	local out = {}
	local count = math.ceil(endTime / SAMPLE_STEP)
	for i = 0, count do
		out[i + 1] = f(math.min(i * SAMPLE_STEP, endTime))
	end
	return out
end

export type PassSim = {
	detail: string, -- GOOD | INTERCEPTED | CLEARED | TOO_HARD | ASTRAY
	outcome: string, -- GOOD | INTERCEPTED | MISS
	eventTime: number,
	endTime: number,
	receiver: number?,
	meet: Vector3?, -- ball centre where the receiver takes it
	header: boolean,
	interceptor: number?,
	speed: number,
	ball: { Vector3 },
	defenders: { { Vector3 } },
	mates: { { Vector3 } },
	defenderEnd: { Vector3 },
	mateEnd: { Vector3 },
}

-- The pass after the strike. releaseTime: decision seconds when you let the arrow go (where
-- everyone was); reaction: the defenders' (seeded) reaction time.
function MomentPhysics.simulatePass(layout: Layout, v0: Vector3, spin: Vector3, releaseTime: number, reaction: number): PassSim
	local start = layout.carrier + Vector3.new(0, BALL_RADIUS, 0)
	local path = MomentPhysics.flight(start, v0, spin)
	local defenders, mates = {}, {}
	for i in layout.defenders do
		defenders[i] = MomentPhysics.defenderAt(layout, i, releaseTime)
	end
	for i in layout.teammates do
		mates[i] = MomentPhysics.mateAt(layout, i, releaseTime)
	end

	local eventIndex, receiver, interceptor, heavy = nil, nil, nil, false
	for index, p in path do
		local t = (index - 1) * SAMPLE_STEP
		local ground = flat(p)
		local speed = if index > 1 then (p - path[index - 1]).Magnitude / SAMPLE_STEP else v0.Magnitude
		-- A rising ball can only be stopped at body height; heading it needs it coming down.
		local descending = index > 1 and p.Y < path[index - 1].Y - 1e-4
		local high = p.Y > 2.6
		-- Best attacker and best defender who can play the ball now (smaller margin = easier).
		local bestMate, mateMargin = nil, math.huge
		if p.Y <= (if descending then C.HeaderHeight else 2.6) then
			for i, m in mates do
				local need = flat(ground - m).Magnitude - C.MateReach
				local can = math.min(C.MateMaxMove, C.MateSpeed * math.max(0, t - C.MateReaction))
				if need <= can and t > 0.12 then
					local margin = need - can - (if high then C.MateAirBonus else C.MateBonus)
					if margin < mateMargin then
						bestMate, mateMargin = i, margin
					end
				end
			end
		end
		local bestDef, defMargin = nil, math.huge
		if p.Y <= (if descending then C.DefHeaderHeight else 3.2) then
			for i, d in defenders do
				local role = layout.defenders[i].role
				local react = if high then C.DefAirReaction else reaction + (if role == "MARK" then C.MarkerDelay else 0)
				local speedLimit = if high then C.DefAirSpeed else C.DefSpeed
				local need = flat(ground - d).Magnitude - C.DefReach
				local can = if t <= react then 0 else speedLimit * (t - react)
				if need <= can then
					local margin = need - can
					if margin < defMargin then
						bestDef, defMargin = i, margin
					end
				end
			end
		end
		if bestMate and mateMargin <= defMargin then
			eventIndex, receiver = index, bestMate
			heavy = not high and speed > C.ControlSpeed
			break
		elseif bestDef then
			eventIndex, interceptor = index, bestDef
			break
		end
	end

	local detail
	if interceptor then
		detail = if path[eventIndex].Y > 2.6 then "CLEARED" else "INTERCEPTED"
	elseif receiver then
		detail = if heavy then "TOO_HARD" else "GOOD"
	else
		detail = "ASTRAY"
	end
	local eventTime = if eventIndex then (eventIndex - 1) * SAMPLE_STEP else (#path - 1) * SAMPLE_STEP
	local outcome = if detail == "GOOD" then "GOOD" elseif interceptor then "INTERCEPTED" else "MISS"
	local holds = detail == "GOOD" or interceptor ~= nil
	local endTime = if holds then eventTime + 0.6 else (#path - 1) * SAMPLE_STEP + 0.3
	local eventBall = path[math.min(eventIndex or #path, #path)]
	local header = detail == "GOOD" and eventBall.Y > 2.8

	-- Whoever plays it moves to meet the ball; the others drift towards it.
	local function approach(from: Vector3, reach: number, moveFrom: number)
		local toFrom = flat(from - eventBall)
		local point = if toFrom.Magnitude > reach * 0.7 then flat(eventBall) + toFrom.Unit * reach * 0.7 else from
		return function(time: number): Vector3
			if time <= moveFrom then
				return from
			end
			return from:Lerp(point, math.clamp((time - moveFrom) / math.max(eventTime - moveFrom, 1e-3), 0, 1))
		end, point
	end
	local function ballAt(time: number): Vector3
		local i = math.clamp(math.floor(time / SAMPLE_STEP) + 1, 1, #path)
		return path[i]
	end
	local mateTracks, mateEnd = {}, {}
	local meet = nil
	for i, m in mates do
		if i == receiver then
			local f, point = approach(m, C.MateReach, math.min(C.MateReaction, eventTime))
			meet = Vector3.new(point.X, eventBall.Y, point.Z)
			mateTracks[i] = sample(endTime, f)
		else
			mateTracks[i] = sample(endTime, function(time)
				-- Keep an eye on it, a step or two towards play.
				local towards = flat(ballAt(math.min(time, eventTime)) - m)
				return m + unit(towards, Vector3.zero) * math.min(towards.Magnitude * 0.15, 2 * time)
			end)
		end
		mateEnd[i] = mateTracks[i][#mateTracks[i]]
	end
	local defenderTracks, defenderEnd = {}, {}
	for i, d in defenders do
		if i == interceptor then
			local f = approach(d, C.DefReach, math.min(if eventBall.Y > 2.6 then C.DefAirReaction else reaction, eventTime))
			defenderTracks[i] = sample(endTime, f)
		else
			defenderTracks[i] = sample(endTime, function(time)
				if time <= reaction then
					return d
				end
				local towards = flat(ballAt(math.min(time, eventTime)) - d)
				return d + unit(towards, Vector3.zero) * math.min(towards.Magnitude * 0.45, C.DefSpeed * 0.6 * (time - reaction))
			end)
		end
		defenderEnd[i] = defenderTracks[i][#defenderTracks[i]]
	end

	-- Ball: its flight, then it sticks with whoever got it (a header is struck where he met it).
	local holder = if receiver and detail == "GOOD" then flat(mateEnd[receiver]) elseif interceptor then flat(defenderEnd[interceptor]) else nil
	local ball = sample(endTime, function(time)
		if time <= eventTime or not holder then
			return ballAt(time)
		end
		if header then
			return eventBall
		end
		local k = math.clamp((time - eventTime) / 0.25, 0, 1)
		return eventBall:Lerp(holder + Vector3.new(0, BALL_RADIUS, 0), k)
	end)

	return {
		detail = detail,
		outcome = outcome,
		eventTime = eventTime,
		endTime = endTime,
		receiver = if detail == "GOOD" or detail == "TOO_HARD" then receiver else nil,
		meet = meet,
		header = header,
		interceptor = interceptor,
		speed = v0.Magnitude,
		ball = ball,
		defenders = defenderTracks,
		mates = mateTracks,
		defenderEnd = defenderEnd,
		mateEnd = mateEnd,
	}
end

-- Where a teammate's finish starts: a header where he met the cross, otherwise a touch towards goal.
function MomentPhysics.finishSpot(meet: Vector3, header: boolean): Vector3
	if header then
		return Vector3.new(meet.X, C.HeaderSpotHeight, meet.Z)
	end
	local ground = flat(meet)
	local toGoal = unit(Vector3.new(-ground.X, 0, -ground.Z), Vector3.new(0, 0, -1))
	local spot = ground + toGoal * 1.6
	return Vector3.new(spot.X, BALL_RADIUS, spot.Z)
end

function MomentPhysics.shouldFinish(at: Vector3): boolean
	return flat(at).Magnitude <= C.FinishDistance
end

-- The defender a low shot towards `target` would hit, if any (the arrow warns about him).
function MomentPhysics.laneBlocker(layout: Layout, target: Vector3, t: number): number?
	local start = flat(MomentPhysics.shotSpot(layout))
	local delta = flat(target) - start
	if delta.Magnitude < 1e-3 then
		return nil
	end
	local finish = start + delta.Unit * math.min(delta.Magnitude, C.BlockRange)
	for i in layout.defenders do
		local d = MomentPhysics.defenderAt(layout, i, t)
		if flat(d - start).Magnitude > C.BlockMinGap and laneDistance(d, start, finish) <= C.BlockReach + 0.5 then
			return i
		end
	end
	return nil
end

-- A shot straight at a defender standing in the way is blocked (lift it over him or bend it round).
-- Returns the sample index of the block and the defender, or nil.
function MomentPhysics.blockShot(layout: Layout, path: { Vector3 }, releaseTime: number): (number?, number?)
	local start = path[1]
	-- A presser already on top of you is lunging for the tackle, not set to block.
	local set = {}
	for i in layout.defenders do
		set[i] = flat(MomentPhysics.defenderAt(layout, i, releaseTime) - start).Magnitude > C.BlockMinGap
	end
	for index, p in path do
		local t = (index - 1) * SAMPLE_STEP
		if flat(p - start).Magnitude > C.BlockRange then
			break
		end
		if t > 0.03 and p.Y <= C.BlockHeight then
			for i in layout.defenders do
				local d = MomentPhysics.defenderAt(layout, i, releaseTime)
					if set[i] and flat(p - d).Magnitude <= C.BlockReach then
					return index, i
				end
			end
		end
	end
	return nil, nil
end

-- The ball off the defender: a short ricochet. Returns its samples (from the block point).
function MomentPhysics.deflect(at: Vector3, incoming: Vector3, rng: Random): { Vector3 }
	local side = if rng:NextNumber() < 0.5 then -1 else 1
	local back = unit(flat(-incoming), Vector3.new(0, 0, 1))
	local lateral = back:Cross(Vector3.yAxis) * side
	local v = (back * 0.6 + lateral * 0.8).Unit * (incoming.Magnitude * 0.3) + Vector3.new(0, 6 + rng:NextNumber() * 6, 0)
	return (MomentPhysics.flight(at, v, Vector3.zero, 1.6))
end

return MomentPhysics
