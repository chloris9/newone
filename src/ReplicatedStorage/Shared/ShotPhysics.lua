-- Shot geometry and ball physics, shared by server and client.
-- The server runs `simulate` to decide the outcome and sends the sampled path to the client,
-- which replays it; the client also uses the free-flight solver for the aiming preview.

local ShotConfig = require(script.Parent.ShotConfig)

local Goal = ShotConfig.Goal
local Arena = ShotConfig.Arena
local P = ShotConfig.Physics
local BALL_RADIUS = ShotConfig.Ball.Radius
local GRAVITY = Vector3.new(0, -P.Gravity, 0)

local HALF_WIDTH = Goal.Width / 2
local POST_X = HALF_WIDTH + Goal.PostRadius
local BAR_Y = Goal.Height + Goal.PostRadius
local FRAME_CONTACT = BALL_RADIUS + Goal.PostRadius

local ShotPhysics = {}

-- Where the ball crosses the goal plane relative to the frame.
ShotPhysics.Zone = {
	OnTarget = "ON_TARGET", -- fully inside the goal mouth
	Frame = "FRAME", -- solid contact with a post or the crossbar
	Wide = "WIDE", -- wide or over
}

export type Event = { kind: string, t: number, pos: Vector3, part: string? }
export type KeeperResponse = { kind: string, velocity: Vector3? } -- kind: "CATCH" | "PARRY"
export type SimResult = {
	path: { Vector3 }, -- ball centre every P.SampleStep seconds, from t = 0
	events: { Event },
	goalTime: number?,
	frameTime: number?,
	framePart: string?, -- "Post" | "Crossbar"
	crossTime: number?, -- first time the ball centre reaches the goal plane (z = 0)
	crossPoint: Vector3?,
	keeperTime: number?, -- when the ball reached the keeper's plane
	keeperPoint: Vector3?,
	keeperKind: string?, -- response returned by the keeper callback, if any
	held: boolean, -- caught: the path ends in the keeper's hands
	duration: number,
}

function ShotPhysics.ballSpot(): Vector3
	return Vector3.new(0, BALL_RADIUS, ShotConfig.ShotDistance)
end

-- Aim X in -1..1 and Y in 0..1 cover exactly the area where the whole ball fits inside the
-- goal mouth, so aiming at the edge means grazing the frame.
function ShotPhysics.aimToGoalPoint(aimX: number, aimY: number): Vector3
	local halfWidth = HALF_WIDTH - BALL_RADIUS
	local x = math.clamp(aimX, -1, 1) * halfWidth
	local y = BALL_RADIUS + math.clamp(aimY, 0, 1) * (Goal.Height - 2 * BALL_RADIUS)
	return Vector3.new(x, y, 0)
end

function ShotPhysics.goalPointToAim(point: Vector3): (number, number)
	local halfWidth = HALF_WIDTH - BALL_RADIUS
	local aimX = math.clamp(point.X / halfWidth, -1, 1)
	local aimY = math.clamp((point.Y - BALL_RADIUS) / (Goal.Height - 2 * BALL_RADIUS), 0, 1)
	return aimX, aimY
end

function ShotPhysics.ballSpeed(power: number): number
	return P.MinBallSpeed + (P.MaxBallSpeed - P.MinBallSpeed) * math.clamp(power, 0, 1)
end

function ShotPhysics.gravity(): Vector3
	return GRAVITY
end

-- Spin chosen for a shot: side spin curls shots aimed at a post back towards the middle,
-- top spin makes hard shots dip. Jitter (from the server's seeded RNG) varies each shot.
function ShotPhysics.spinFor(aimX: number, power: number, jitterX: number?, jitterY: number?): Vector3
	local top = -P.DipSpin * math.max(0, (power - 0.5) / 0.5)
	local side = P.CurlSpin * math.clamp(aimX, -1, 1)
	return Vector3.new(top + (jitterX or 0), side + (jitterY or 0), 0)
end

local function acceleration(v: Vector3, spin: Vector3): Vector3
	return GRAVITY - v * (P.Drag * v.Magnitude) + spin:Cross(v) * P.Magnus
end

-- One midpoint (RK2) step of free flight.
local function step(p: Vector3, v: Vector3, spin: Vector3, dt: number): (Vector3, Vector3)
	local mid = v + acceleration(v, spin) * (dt / 2)
	return p + mid * dt, v + acceleration(mid, spin) * dt
end

-- Free flight (no collisions) until the ball centre reaches the goal plane.
local function crossFree(start: Vector3, v0: Vector3, spin: Vector3, dt: number): (Vector3?, number)
	local p, v, w, t = start, v0, spin, 0
	local decay = 1 - P.SpinDecay * dt
	while t < P.MaxSimTime do
		local nextP, nextV = step(p, v, w, dt)
		t += dt
		if nextP.Z <= 0 then
			local f = p.Z / (p.Z - nextP.Z)
			return p:Lerp(nextP, f), t - dt * (1 - f)
		end
		p, v, w = nextP, nextV, w * decay
	end
	return nil, t
end

-- Launch velocity whose free flight (with drag and spin) crosses the goal plane at `target`.
function ShotPhysics.solveLaunch(start: Vector3, target: Vector3, power: number, spin: Vector3, dt: number?): Vector3
	local stepSize = dt or P.SimStep
	local flightTime = (target - start).Magnitude / ShotPhysics.ballSpeed(power)
	-- Drag-free ballistic guess, then correct the miss a few times.
	local v = (target - start) / flightTime - GRAVITY * (flightTime / 2)
	for _ = 1, 8 do
		local cross, t = crossFree(start, v, spin, stepSize)
		if not cross then
			break
		end
		local miss = target - cross
		if math.abs(miss.X) + math.abs(miss.Y) < 0.01 then
			break
		end
		v += Vector3.new(miss.X, miss.Y, 0) / t
	end
	return v
end

-- Free-flight points from the ball spot (or `from`) to the goal plane, for the aiming preview.
function ShotPhysics.previewPath(target: Vector3, power: number, spin: Vector3, count: number, from: Vector3?): { Vector3 }
	local dt = 1 / 120
	local start = from or ShotPhysics.ballSpot()
	local v0 = ShotPhysics.solveLaunch(start, target, power, spin, dt)
	local _, total = crossFree(start, v0, spin, dt)
	local points = table.create(count)
	local p, v, w, t = start, v0, spin, 0
	local nextSample = total / (count + 1)
	while #points < count and t < total do
		p, v = step(p, v, w, dt)
		w *= 1 - P.SpinDecay * dt
		t += dt
		if t >= nextSample then
			table.insert(points, p)
			nextSample += total / (count + 1)
		end
	end
	return points
end

local function closestOnSegment(p: Vector3, a: Vector3, b: Vector3): Vector3
	local ab = b - a
	local t = math.clamp((p - a):Dot(ab) / ab:Dot(ab), 0, 1)
	return a + ab * t
end

local FRAME_SEGMENTS = {
	{ "Post", Vector3.new(-POST_X, 0, 0), Vector3.new(-POST_X, BAR_Y, 0) },
	{ "Post", Vector3.new(POST_X, 0, 0), Vector3.new(POST_X, BAR_Y, 0) },
	{ "Crossbar", Vector3.new(-POST_X, BAR_Y, 0), Vector3.new(POST_X, BAR_Y, 0) },
}

-- Full flight with collisions: keeper (via callback), posts, crossbar, net, boards and ground.
-- `keeperPlaneZ`/`keeper` are optional; the callback is called once, when the ball first reaches
-- that plane, and may return CATCH (path ends there) or PARRY with a new velocity.
function ShotPhysics.simulate(
	start: Vector3,
	v0: Vector3,
	spin: Vector3,
	keeperPlaneZ: number?,
	keeper: ((t: number, pos: Vector3, vel: Vector3) -> KeeperResponse?)?
): SimResult
	local dt = P.SimStep
	local stepsPerSample = math.max(1, math.round(P.SampleStep / dt))
	local decay = 1 - P.SpinDecay * dt
	local result: SimResult = { path = { start }, events = {}, held = false, duration = 0 }
	local events = result.events

	local p, v, w, t = start, v0, spin, 0
	local stepCount, restTime = 0, 0
	local keeperChecked = keeperPlaneZ == nil
	local touchedNet, touchedBoard = false, false

	local function event(kind: string, at: Vector3, part: string?)
		table.insert(events, { kind = kind, t = t, pos = at, part = part })
	end

	while t < P.MaxSimTime do
		local prev = p
		p, v = step(p, v, w, dt)
		w *= decay
		t += dt
		stepCount += 1

		-- Keeper plane
		if not keeperChecked and prev.Z > keeperPlaneZ and p.Z <= keeperPlaneZ then
			keeperChecked = true
			local f = (prev.Z - keeperPlaneZ) / (prev.Z - p.Z)
			local at = prev:Lerp(p, f)
			result.keeperTime, result.keeperPoint = t - dt * (1 - f), at
			local response = keeper and keeper(result.keeperTime, at, v)
			if response then
				result.keeperKind = response.kind
				event("keeper", at, response.kind)
				if response.kind == "CATCH" then
					p = at
					result.held = true
					table.insert(result.path, p)
					break
				elseif response.velocity then
					p, v, w = at, response.velocity, w * 0.3
				end
			end
		end

		-- Goal frame: sphere against the post / crossbar cylinders.
		for _, segment in FRAME_SEGMENTS do
			local closest = closestOnSegment(p, segment[2], segment[3])
			local offset = p - closest
			local distance = offset.Magnitude
			if distance < FRAME_CONTACT and distance > 1e-4 then
				local normal = offset / distance
				local approach = v:Dot(normal)
				p = closest + normal * FRAME_CONTACT
				if approach < 0 then
					local tangent = v - normal * approach
					v = tangent * 0.9 - normal * (approach * P.FrameRestitution)
					w = w * 0.5
					if not result.frameTime then
						result.frameTime, result.framePart = t, segment[1]
					end
					event("frame", p, segment[1])
				end
			end
		end

		-- Goal line
		if not result.crossTime and prev.Z > 0 and p.Z <= 0 then
			local f = prev.Z / (prev.Z - p.Z)
			result.crossTime, result.crossPoint = t - dt * (1 - f), prev:Lerp(p, f)
		end
		if not result.goalTime and prev.Z >= -BALL_RADIUS and p.Z < -BALL_RADIUS
			and math.abs(p.X) < HALF_WIDTH and p.Y < Goal.Height then
			result.goalTime = t
			event("goal", p)
		end

		-- Net: back, sides and roof, from inside the goal; side netting and roof from outside.
		local inDepth = p.Z < 0 and p.Z > -Goal.NetDepth
		local function netHit(at: Vector3)
			if not touchedNet then
				touchedNet = true
				event("net", at)
			end
		end
		if math.abs(p.X) < HALF_WIDTH and p.Y < Goal.Height and p.Z < -Goal.NetDepth + BALL_RADIUS and prev.Z >= -Goal.NetDepth + BALL_RADIUS then
			p = Vector3.new(p.X, p.Y, -Goal.NetDepth + BALL_RADIUS)
			v = Vector3.new(v.X * 0.4, v.Y * 0.4, -v.Z * P.NetDamping)
			netHit(p)
		end
		if inDepth and p.Y < Goal.Height then
			local inner = HALF_WIDTH - BALL_RADIUS
			local outer = HALF_WIDTH + BALL_RADIUS
			if math.abs(prev.X) <= inner and math.abs(p.X) > inner then
				p = Vector3.new(math.sign(p.X) * inner, p.Y, p.Z)
				v = Vector3.new(-v.X * P.NetDamping, v.Y, v.Z * 0.6)
				netHit(p)
			elseif math.abs(prev.X) >= outer and math.abs(p.X) < outer then
				p = Vector3.new(math.sign(p.X) * outer, p.Y, p.Z)
				v = Vector3.new(-v.X * P.NetDamping, v.Y, v.Z * 0.5)
				netHit(p)
			end
		end
		if inDepth and math.abs(p.X) < HALF_WIDTH then
			local under, over = Goal.Height - BALL_RADIUS, Goal.Height + BALL_RADIUS
			if prev.Y <= under and p.Y > under then
				p = Vector3.new(p.X, under, p.Z)
				v = Vector3.new(v.X * 0.6, -v.Y * P.NetDamping, v.Z * 0.6)
				netHit(p)
			elseif prev.Y >= over and p.Y < over then
				p = Vector3.new(p.X, over, p.Z)
				v = Vector3.new(v.X * 0.5, -v.Y * 0.15, v.Z * 0.5)
				netHit(p)
			end
		end

		-- Advertising boards behind the goal
		if p.Z < Arena.BoardZ + BALL_RADIUS and prev.Z >= Arena.BoardZ + BALL_RADIUS and p.Y < Arena.BoardHeight + BALL_RADIUS then
			p = Vector3.new(p.X, p.Y, Arena.BoardZ + BALL_RADIUS)
			v = Vector3.new(v.X * 0.8, v.Y, -v.Z * P.BoardRestitution)
			if not touchedBoard then
				touchedBoard = true
				event("board", p)
			end
		end

		-- Ground: bounce, then roll with friction.
		if p.Y < BALL_RADIUS then
			p = Vector3.new(p.X, BALL_RADIUS, p.Z)
			if v.Y < -3 then
				local keep = 1 - P.GroundFriction
				v = Vector3.new(v.X * keep, -v.Y * P.GroundRestitution, v.Z * keep)
				event("bounce", p)
			else
				local flat = Vector3.new(v.X, 0, v.Z)
				local speed = flat.Magnitude
				local slowed = math.max(0, speed - P.RollingFriction * dt)
				v = if speed > 1e-3 then flat * (slowed / speed) else Vector3.zero
				w = Vector3.new(v.Z, 0, -v.X) / BALL_RADIUS -- rolling, no more curl
			end
		end

		if stepCount % stepsPerSample == 0 then
			table.insert(result.path, p)
		end

		-- Stop when the ball is resting or has flown into the stands.
		if v.Magnitude < 0.5 and p.Y <= BALL_RADIUS + 0.01 then
			restTime += dt
			if restTime > 0.25 then
				break
			end
		else
			restTime = 0
		end
		if p.Z < Arena.BoardZ - 12 or p.Y < -5 then
			break
		end
	end

	result.duration = t
	return result
end

local function distanceToSegment(px: number, py: number, ax: number, ay: number, bx: number, by: number): number
	local abx, aby = bx - ax, by - ay
	local t = math.clamp(((px - ax) * abx + (py - ay) * aby) / (abx * abx + aby * aby), 0, 1)
	local dx, dy = px - (ax + abx * t), py - (ay + aby * t)
	return math.sqrt(dx * dx + dy * dy)
end

-- Classifies the ball centre where it crosses the goal plane (Z = 0), ignoring collisions.
function ShotPhysics.classify(point: Vector3): string
	local x, y = point.X, point.Y
	local frameDistance = math.min(
		distanceToSegment(x, y, -POST_X, 0, -POST_X, BAR_Y),
		distanceToSegment(x, y, POST_X, 0, POST_X, BAR_Y),
		distanceToSegment(x, y, -POST_X, BAR_Y, POST_X, BAR_Y)
	)
	if frameDistance < Goal.PostRadius + BALL_RADIUS * (1 - Goal.FrameHitDepth) then
		return ShotPhysics.Zone.Frame
	end
	if math.abs(x) < POST_X and y < BAR_Y then
		return ShotPhysics.Zone.OnTarget
	end
	return ShotPhysics.Zone.Wide
end

return ShotPhysics
