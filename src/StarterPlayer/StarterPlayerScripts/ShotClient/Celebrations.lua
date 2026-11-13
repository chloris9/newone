-- Goal celebrations for the FigureBuilder rigs: a library of short keyframed animations, one picked
-- at random per goal (Celebrations.pick / Celebrations.play).
--
-- Same joint conventions as FigureAnimator (degrees, applied as motor.C0 = rest * CFrame.Angles):
--   shoulder  +X swings the arm forward/up, +Z swings the RIGHT arm out (the left uses -Z);
--             the Euler order is Rx*Ry*Rz, so Z spreads first and X then swings the spread arm
--   elbow     +X folds the forearm forward; with the arm out, Z folds it up (right +Z, left -Z)
--   hip       +X swings the leg forward, knee -X bends, ankle +X lifts the toes
--   waist     +X leans the torso back, -X forward;  neck +X tips the head back
-- Root channels move the whole model relative to `base` (the rig faces -Z = base.LookVector):
--   fwd studs forward, side studs to the rig's right, up studs, yaw degrees (+ turns left),
--   pitch degrees about the rig's X axis (+ = backflip), roll about Z (+ = lean left, - = cartwheel
--   to the right). Distances are rig studs and are multiplied by opts.scale.

local Celebrations = {}

export type Handle = {
	update: (self: Handle, dt: number) -> boolean,
	stop: (self: Handle) -> (),
}

type Pose = { [string]: any } -- channel -> number (root) | Vector3 (joint degrees)

type Def = {
	duration: number,
	frames: { Pose }, -- each has t (seconds); channels left out fall back to IDLE
	extra: ((t: number, pose: Pose) -> ())?, -- procedural overlay on the sampled pose
}

type Compiled = {
	times: { number },
	tracks: { [string]: { values: { any }, slopes: { any } } },
}

local JOINT_NAMES = {
	"Waist", "Neck",
	"LeftShoulder", "LeftElbow", "LeftWrist", "RightShoulder", "RightElbow", "RightWrist",
	"LeftHip", "LeftKnee", "LeftAnkle", "RightHip", "RightKnee", "RightAnkle",
}
local ROOT_CHANNELS = { "side", "up", "fwd", "yaw", "pitch", "roll" }
local BLEND_IN = 0.14 -- seconds to ease from whatever pose the rig was in

local function J(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z)
end

local function smooth(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- 0 before a, rises to 1 over `fade`, falls back to 0 after b.
local function window(t: number, a: number, b: number, fade: number): number
	return smooth((t - a) / fade) * (1 - smooth((t - b) / fade))
end

local function add(pose: Pose, key: string, delta: any)
	pose[key] = pose[key] + delta
end

-- Standing at ease (matches FigureAnimator's idle).
local IDLE: Pose = {
	Waist = J(0, 0, 0), Neck = J(0, 0, 0),
	LeftShoulder = J(0, 0, -8), RightShoulder = J(0, 0, 8),
	LeftElbow = J(18, 0, 0), RightElbow = J(18, 0, 0),
	LeftWrist = J(0, 0, 0), RightWrist = J(0, 0, 0),
	LeftHip = J(4, 0, -3), RightHip = J(4, 0, 3),
	LeftKnee = J(-8, 0, 0), RightKnee = J(-8, 0, 0),
	LeftAnkle = J(4, 0, 0), RightAnkle = J(4, 0, 0),
	side = 0, up = 0, fwd = 0, yaw = 0, pitch = 0, roll = 0,
}

-- Keyframe at time t from one or more pose fragments (later fragments win).
local function F(t: number, ...: Pose): Pose
	local frame: Pose = { t = t }
	for _, part in { ... } do
		for key, value in part do
			frame[key] = value
		end
	end
	return frame
end

-- Right-side values; the left side mirrors Y and Z (X stays).
local function mirror(v: Vector3): Vector3
	return J(v.X, -v.Y, -v.Z)
end

local function arms(shoulder: Vector3, elbow: Vector3): Pose
	return {
		RightShoulder = shoulder, RightElbow = elbow,
		LeftShoulder = mirror(shoulder), LeftElbow = mirror(elbow),
	}
end

local function legs(hip: Vector3, knee: Vector3, ankle: Vector3): Pose
	return {
		RightHip = hip, RightKnee = knee, RightAnkle = ankle,
		LeftHip = mirror(hip), LeftKnee = mirror(knee), LeftAnkle = mirror(ankle),
	}
end

-- Running overlay, same swing as FigureAnimator's run cycle (w = strength, rate = rad/s).
local function runCycle(pose: Pose, t: number, w: number, rate: number, withArms: boolean)
	local s, c = math.sin(t * rate), math.cos(t * rate)
	if withArms then
		add(pose, "LeftShoulder", J(-34 * w * s, 0, 0))
		add(pose, "RightShoulder", J(34 * w * s, 0, 0))
	end
	add(pose, "LeftHip", J(40 * w * s, 0, 0))
	add(pose, "RightHip", J(-40 * w * s, 0, 0))
	add(pose, "LeftKnee", J(-55 * w * math.max(0, -c), 0, 0))
	add(pose, "RightKnee", J(-55 * w * math.max(0, c), 0, 0))
	add(pose, "up", math.abs(s) * 0.2 * w)
end

local DEFS: { [string]: Def } = {}

----------------------------------------------------------------------------------------------------
-- 1. Knee slide: sprint, drop onto both knees with arms spread, lean back, pump the fists.

do
	local run = F(0, arms(J(0, 0, 8), J(70, 0, 0)), { Waist = J(-12, 0, 0), Neck = J(6, 0, 0) })
	local slide = F(0,
		arms(J(25, 0, 105), J(12, 0, 0)),
		legs(J(-6, 0, 6), J(-92, 0, 0), J(-20, 0, 0)),
		{ Waist = J(22, 0, 0), Neck = J(26, 0, 0), up = -0.55 }
	)
	DEFS.KneeSlide = {
		duration = 2.4,
		frames = {
			F(0.00),
			F(0.35, run, { fwd = 1.6 }),
			F(0.80, run, { fwd = 5.0 }),
			F(1.00, slide, { fwd = 6.8, up = -0.3 }),
			F(1.25, slide, { fwd = 8.4 }),
			F(1.80, slide, { fwd = 9.6 }),
			F(2.40, slide, { fwd = 9.8 }),
		},
		extra = function(t, pose)
			runCycle(pose, t, window(t, 0, 0.8, 0.2), 17, true)
			local pump = math.sin((t - 1.6) * 9) * smooth((t - 1.6) / 0.3)
			add(pose, "LeftShoulder", J(0, 0, 12 * pump))
			add(pose, "RightShoulder", J(0, 0, -12 * pump))
		end,
	}
end

----------------------------------------------------------------------------------------------------
-- 2. Airplane: arms spread, running while banking left and right.

do
	local plane = F(0, arms(J(-5, 0, 88), J(5, 0, 0)), { Waist = J(-14, 0, 0), up = 0.15 })
	DEFS.Airplane = {
		duration = 2.4,
		frames = {
			F(0.00),
			F(0.30, plane, { fwd = 1.2 }),
			F(0.75, plane, { fwd = 3.5, roll = -24, yaw = -14, side = 0.8 }),
			F(1.40, plane, { fwd = 7.2, roll = 24, yaw = 14, side = -0.8 }),
			F(2.00, plane, { fwd = 10.4, roll = -20, yaw = -12, side = 0.6 }),
			F(2.40, plane, { fwd = 12.2, up = 0 }),
		},
		extra = function(t, pose)
			runCycle(pose, t, 0.6 * smooth(t / 0.3), 15, false)
			add(pose, "Neck", J(0, 0, -pose.roll * 0.5)) -- keep the head level
		end,
	}
end

----------------------------------------------------------------------------------------------------
-- 3. Siu: crouch, jump, half turn in the air, land with arms thrust down and out.

do
	local crouch = F(0,
		arms(J(-45, 0, 10), J(10, 0, 0)),
		legs(J(55, 0, 3), J(-95, 0, 0), J(40, 0, 0)),
		{ Waist = J(-18, 0, 0), up = -0.6 }
	)
	local air = F(0, arms(J(0, 0, 160), J(8, 0, 0)), legs(J(6, 0, 3), J(-14, 0, 0), J(-30, 0, 0)))
	local land = F(0,
		arms(J(0, 0, 45), J(6, 0, 0)),
		legs(J(30, 0, 6), J(-50, 0, 0), J(20, 0, 0)),
		{ Waist = J(-6, 0, 0), up = -0.45, yaw = 180 }
	)
	local pose = F(0,
		arms(J(-8, 0, 52), J(4, 0, 0)),
		legs(J(4, 0, 8), J(-8, 0, 0), J(4, 0, 0)),
		{ Waist = J(8, 0, 0), Neck = J(14, 0, 0), yaw = 180 }
	)
	DEFS.Siu = {
		duration = 2.2,
		frames = {
			F(0.00),
			F(0.35, crouch),
			F(0.55, air, { up = 0.9 }),
			F(0.80, air, { up = 2.0, yaw = 95 }),
			F(1.05, air, arms(J(0, 0, 100), J(8, 0, 0)), { up = 0.9, yaw = 180 }),
			F(1.25, land),
			F(1.55, pose),
			F(2.20, pose),
		},
		extra = function(t, pose)
			local flex = window(t, 1.6, 10, 0.2) * math.sin(t * 7)
			add(pose, "LeftShoulder", J(0, 0, 3 * flex))
			add(pose, "RightShoulder", J(0, 0, -3 * flex))
		end,
	}
end

----------------------------------------------------------------------------------------------------
-- 4. Backflip: arm swing, jump, full tucked rotation backwards, land with arms in a V.

do
	local crouch = F(0,
		arms(J(-60, 0, 12), J(10, 0, 0)),
		legs(J(50, 0, 3), J(-90, 0, 0), J(35, 0, 0)),
		{ Waist = J(-20, 0, 0), up = -0.5 }
	)
	local launch = F(0, arms(J(170, 0, 10), J(8, 0, 0)), legs(J(5, 0, 3), J(-10, 0, 0), J(-30, 0, 0)))
	local tuck = F(0,
		arms(J(70, 0, 10), J(55, 0, 0)),
		legs(J(95, 0, 4), J(-120, 0, 0), J(0, 0, 0)),
		{ Waist = J(-20, 0, 0) }
	)
	local stand = F(0, arms(J(0, 0, 150), J(8, 0, 0)), { Waist = J(4, 0, 0), Neck = J(12, 0, 0), pitch = 360 })
	DEFS.Backflip = {
		duration = 2.3,
		frames = {
			F(0.00),
			F(0.30, crouch),
			F(0.52, launch, { up = 1.0, pitch = 20 }),
			F(0.75, tuck, { up = 2.4, pitch = 130, fwd = -0.5 }),
			F(1.00, tuck, { up = 2.3, pitch = 265, fwd = -1.0 }),
			F(1.20, launch, arms(J(40, 0, 20), J(20, 0, 0)), { up = 0.8, pitch = 345, fwd = -1.3 }),
			F(1.32, crouch, { pitch = 360, up = -0.45, fwd = -1.4, Waist = J(-10, 0, 0) }),
			F(1.70, stand, { fwd = -1.4 }),
			F(2.30, stand, { fwd = -1.4 }),
		},
	}
end

----------------------------------------------------------------------------------------------------
-- 5. Shush the crowd: stroll forward with a finger to the lips, then cup an ear.

do
	local shush = F(0,
		{
			RightShoulder = J(60, 0, 6), RightElbow = J(125, 0, 0),
			LeftShoulder = J(0, 0, -22), LeftElbow = J(60, 0, 0),
			Waist = J(-6, 0, 0), Neck = J(-8, 0, 0),
		}
	)
	local ear = F(0, {
		LeftShoulder = J(5, 0, -90), LeftElbow = J(0, 0, -120),
		RightShoulder = J(0, 0, 10), RightElbow = J(30, 0, 0),
		Waist = J(0, 0, 8), Neck = J(0, 0, 12),
	})
	DEFS.Shush = {
		duration = 2.4,
		frames = {
			F(0.00),
			F(0.30, shush, { fwd = 0.4 }),
			F(1.10, shush, { fwd = 2.0 }),
			F(1.30, shush, { fwd = 2.2 }),
			F(1.65, ear, { fwd = 2.3 }),
			F(2.40, ear, { fwd = 2.3 }),
		},
		extra = function(t, pose)
			runCycle(pose, t, 0.25 * window(t, 0, 1.1, 0.2), 9, false)
			add(pose, "Neck", J(0, 10 * math.sin(t * 8) * window(t, 0.4, 1.25, 0.15), 0))
			add(pose, "LeftElbow", J(0, 0, -8 * math.sin(t * 10) * window(t, 1.7, 10, 0.2)))
		end,
	}
end

----------------------------------------------------------------------------------------------------
-- 6. Robot dance: stiff snap poses, alternating arms, head turns.

do
	local base = F(0, legs(J(12, 0, 8), J(-26, 0, 0), J(14, 0, 0)), { up = -0.15 })
	local poses = {
		F(0, base, { RightShoulder = J(0, 0, 90), RightElbow = J(0, 0, 90), LeftShoulder = J(0, 0, -90), LeftElbow = J(0, 0, 0),
			Neck = J(0, -35, 0), side = 0.5 }),
		F(0, base, arms(J(0, 0, 90), J(0, 0, 90)), { Neck = J(0, 0, 0) }),
		F(0, base, { LeftShoulder = J(0, 0, -90), LeftElbow = J(0, 0, -90), RightShoulder = J(0, 0, 90), RightElbow = J(0, 0, 0),
			Neck = J(0, 35, 0), side = -0.5 }),
		F(0, base, arms(J(90, 0, 8), J(0, 0, 0)), { Waist = J(-10, 0, 0) }),
		F(0, base, { RightShoulder = J(90, 0, 8), RightElbow = J(0, 0, 0), LeftShoulder = J(0, 0, -90), LeftElbow = J(0, 0, -90),
			Neck = J(0, 25, 0), Waist = J(0, 14, 0) }),
	}
	local frames = { F(0.00) }
	local t = 0.25
	for _, p in poses do
		p.t = t
		table.insert(frames, p)
		local hold = table.clone(p)
		hold.t = t + 0.3
		table.insert(frames, hold)
		t += 0.38
	end
	table.insert(frames, F(2.40))
	DEFS.Robot = { duration = 2.4, frames = frames }
end

----------------------------------------------------------------------------------------------------
-- 7. Sky: arms curved overhead like a heart, then one arm points up with the head tipped back.

do
	local heart = F(0, arms(J(0, 0, 150), J(0, 0, 90)), { Waist = J(2, 0, 0), Neck = J(8, 0, 0) })
	local point = F(0, {
		RightShoulder = J(0, 0, 172), RightElbow = J(0, 0, 0),
		LeftShoulder = J(30, 0, -10), LeftElbow = J(110, 0, 0),
		Waist = J(10, 0, 0), Neck = J(30, 0, 0),
	})
	DEFS.SkyPoint = {
		duration = 2.4,
		frames = {
			F(0.00),
			F(0.45, heart, { fwd = 0.3 }),
			F(1.25, heart, { fwd = 0.6 }),
			F(1.65, point, { fwd = 0.8 }),
			F(2.40, point, { fwd = 0.8 }),
		},
		extra = function(t, pose)
			add(pose, "roll", 5 * math.sin(t * 4.5) * window(t, 0.4, 1.3, 0.2))
			add(pose, "up", 0.12 * math.abs(math.sin(t * 6)) * window(t, 1.7, 10, 0.2))
			add(pose, "RightShoulder", J(0, 0, 4 * math.sin(t * 8) * window(t, 1.7, 10, 0.2)))
		end,
	}
end

----------------------------------------------------------------------------------------------------
-- 8. Cartwheel to the rig's right, then a V-arms landing.

do
	local up = arms(J(0, 0, 170), J(5, 0, 0))
	local v = F(0, arms(J(10, 0, 150), J(8, 0, 0)), { Waist = J(-4, 0, 0), Neck = J(10, 0, 0) })
	DEFS.Cartwheel = {
		duration = 2.4,
		frames = {
			F(0.00),
			F(0.30, up, { Waist = J(-5, 0, 0) }),
			F(0.80, up, { roll = -180, side = 2.9 }),
			F(1.30, up, { roll = -360, side = 5.8 }),
			F(1.45, up, { roll = -360, side = 5.8 }),
			F(1.55, v, { roll = -360, side = 5.8, up = -0.3 }),
			F(1.90, v, { roll = -360, side = 5.8 }),
			F(2.40, v, { roll = -360, side = 5.8 }),
		},
		extra = function(t, pose)
			-- Legs split and the body lifts while it is inverted.
			local s = math.sin(math.rad(math.abs(pose.roll)) / 2)
			add(pose, "LeftHip", J(0, 0, -35 * s))
			add(pose, "RightHip", J(0, 0, 35 * s))
			add(pose, "up", 0.6 * s * s)
		end,
	}
end

----------------------------------------------------------------------------------------------------
-- 9. Double fist pump with knee raises: two skip-hops, then a V-armed leap.

do
	local fists = F(0, arms(J(15, 0, 22), J(145, 0, 0)), { Waist = J(-6, 0, 0), Neck = J(18, 0, 0) })
	local leapArms = arms(J(0, 0, 165), J(8, 0, 0))
	DEFS.KneePump = {
		duration = 2.4,
		frames = {
			F(0.00),
			F(0.25, fists, { up = -0.25, fwd = 0.2 }),
			F(0.55, fists, { up = 0.55, fwd = 0.6,
				LeftHip = J(95, 0, -3), LeftKnee = J(-95, 0, 0), LeftAnkle = J(30, 0, 0) }),
			F(0.85, fists, { fwd = 1.0 }),
			F(1.15, fists, { up = 0.55, fwd = 1.9,
				RightHip = J(95, 0, 3), RightKnee = J(-95, 0, 0), RightAnkle = J(30, 0, 0) }),
			F(1.45, fists, { fwd = 2.5 }),
			F(1.75, F(0, fists, leapArms, legs(J(40, 0, 4), J(-60, 0, 0), J(10, 0, 0))), { up = 0.8, fwd = 2.7 }),
			F(2.05, F(0, fists, leapArms), { up = -0.2, fwd = 2.8 }),
			F(2.40, F(0, fists, leapArms), { fwd = 2.8 }),
		},
		extra = function(t, pose)
			local pump = math.sin(t * 14) * window(t, 0.2, 1.5, 0.15)
			add(pose, "LeftShoulder", J(12 * pump, 0, 0))
			add(pose, "RightShoulder", J(12 * pump, 0, 0))
			add(pose, "LeftElbow", J(-12 * pump, 0, 0))
			add(pose, "RightElbow", J(-12 * pump, 0, 0))
		end,
	}
end

----------------------------------------------------------------------------------------------------
-- Keyframe sampling: monotone cubic Hermite per channel (no overshoot, zero speed at holds/peaks).

local function slopeScalar(a: number, b: number, c: number, ta: number, tb: number, tc: number): number
	local d1 = (b - a) / (tb - ta)
	local d2 = (c - b) / (tc - tb)
	if d1 * d2 <= 0 then
		return 0
	end
	return 2 * d1 * d2 / (d1 + d2)
end

local function slopeAny(a: any, b: any, c: any, ta: number, tb: number, tc: number): any
	if typeof(b) == "Vector3" then
		return J(
			slopeScalar(a.X, b.X, c.X, ta, tb, tc),
			slopeScalar(a.Y, b.Y, c.Y, ta, tb, tc),
			slopeScalar(a.Z, b.Z, c.Z, ta, tb, tc)
		)
	end
	return slopeScalar(a, b, c, ta, tb, tc)
end

local function hermite(p0: number, p1: number, m0: number, m1: number, h: number, u: number): number
	local u2 = u * u
	local u3 = u2 * u
	return (2 * u3 - 3 * u2 + 1) * p0 + (u3 - 2 * u2 + u) * h * m0 + (-2 * u3 + 3 * u2) * p1 + (u3 - u2) * h * m1
end

local function hermiteAny(p0: any, p1: any, m0: any, m1: any, h: number, u: number): any
	if typeof(p0) == "Vector3" then
		return J(
			hermite(p0.X, p1.X, m0.X, m1.X, h, u),
			hermite(p0.Y, p1.Y, m0.Y, m1.Y, h, u),
			hermite(p0.Z, p1.Z, m0.Z, m1.Z, h, u)
		)
	end
	return hermite(p0, p1, m0, m1, h, u)
end

local CHANNELS: { string } = {}
for _, name in ROOT_CHANNELS do
	table.insert(CHANNELS, name)
end
for _, name in JOINT_NAMES do
	table.insert(CHANNELS, name)
end

local compiledCache: { [string]: Compiled } = {}

local function compile(name: string): Compiled
	local cached = compiledCache[name]
	if cached then
		return cached
	end
	local frames = DEFS[name].frames
	local count = #frames
	local times: { number } = {}
	for i, frame in frames do
		times[i] = frame.t
	end
	local tracks = {}
	for _, channel in CHANNELS do
		local values: { any } = {}
		for i, frame in frames do
			local v = frame[channel]
			values[i] = if v ~= nil then v else IDLE[channel]
		end
		local zero: any = if typeof(IDLE[channel]) == "Vector3" then Vector3.zero else 0
		local slopes: { any } = {}
		for i = 1, count do
			if i == 1 or i == count then
				slopes[i] = zero
			else
				slopes[i] = slopeAny(values[i - 1], values[i], values[i + 1], times[i - 1], times[i], times[i + 1])
			end
		end
		tracks[channel] = { values = values, slopes = slopes }
	end
	local compiled: Compiled = { times = times, tracks = tracks }
	compiledCache[name] = compiled
	return compiled
end

local function sample(compiled: Compiled, t: number): Pose
	local times = compiled.times
	local count = #times
	local i = 1
	while i < count - 1 and t >= times[i + 1] do
		i += 1
	end
	local h = times[i + 1] - times[i]
	local u = math.clamp((t - times[i]) / h, 0, 1)
	local pose: Pose = {}
	for channel, track in compiled.tracks do
		pose[channel] = hermiteAny(track.values[i], track.values[i + 1], track.slopes[i], track.slopes[i + 1], h, u)
	end
	return pose
end

----------------------------------------------------------------------------------------------------
-- Playback

local Playback = {}
Playback.__index = Playback

Celebrations.NAMES = { "KneeSlide", "Airplane", "Siu", "Backflip", "Shush", "Robot", "SkyPoint", "Cartwheel", "KneePump" }

local lastPicked: string? = nil

-- Random celebration, never the same as the previous pick.
function Celebrations.pick(): string
	local names = Celebrations.NAMES
	local name = names[math.random(1, #names)]
	if name == lastPicked then
		local index = table.find(names, name) or 1
		name = names[(index + math.random(0, #names - 2)) % #names + 1]
	end
	lastPicked = name
	return name
end

function Celebrations.play(model: Model, base: CFrame, rootHeight: number, opts: {
	name: string?,
	scale: number?,
	onDone: (() -> ())?,
}?): Handle
	local options = opts or {}
	local name = options.name
	if not name or not DEFS[name] then
		name = Celebrations.pick()
	end
	local self = setmetatable({}, Playback)
	self.name = name
	self.def = DEFS[name :: string]
	self.compiled = compile(name :: string)
	self.model = model
	self.base = base
	self.rootHeight = rootHeight
	self.scale = options.scale or 1
	self.onDone = options.onDone
	self.time = 0
	self.finished = false
	self.motors = {}
	for _, jointName in JOINT_NAMES do
		local motor = model:FindFirstChild(jointName, true)
		if motor and motor:IsA("Motor6D") then
			-- C0 is a pure translation at rest, so this survives a pose left by FigureAnimator.
			local rest = CFrame.new(motor.C0.Position)
			local rx, ry, rz = (rest:Inverse() * motor.C0):ToEulerAnglesXYZ()
			self.motors[jointName] = {
				motor = motor,
				rest = rest,
				start = J(math.deg(rx), math.deg(ry), math.deg(rz)),
			}
		end
	end
	self:_apply(0)
	return self :: any
end

function Playback:_rootCFrame(side: number, up: number, fwd: number, yaw: number, pitch: number, roll: number): CFrame
	local s = self.scale
	return self.base
		* CFrame.new(side * s, self.rootHeight + up * s, -fwd * s)
		* CFrame.Angles(0, math.rad(yaw), 0)
		* CFrame.Angles(math.rad(pitch), 0, math.rad(roll))
end

function Playback:_apply(t: number)
	local pose = sample(self.compiled, t)
	local extra = self.def.extra
	if extra then
		extra(t, pose)
	end
	local blend = if t < BLEND_IN then smooth(t / BLEND_IN) else 1
	for jointName, entry in self.motors do
		local angles: Vector3 = pose[jointName]
		if blend < 1 then
			angles = entry.start:Lerp(angles, blend)
		end
		entry.motor.C0 = entry.rest * CFrame.Angles(math.rad(angles.X), math.rad(angles.Y), math.rad(angles.Z))
	end
	self.model:PivotTo(self:_rootCFrame(pose.side, pose.up, pose.fwd, pose.yaw, pose.pitch, pose.roll))
end

-- Advances the animation; false once it has finished (the final pose stays applied).
function Playback:update(dt: number): boolean
	if self.finished then
		return false
	end
	local duration = self.def.duration
	self.time = math.min(self.time + dt, duration)
	self:_apply(self.time)
	if self.time >= duration then
		self.finished = true
		local onDone = self.onDone
		if onDone then
			onDone()
		end
		return false
	end
	return true
end

-- Ends it early: joints back to rest, model standing where the celebration would have ended up.
function Playback:stop()
	self.finished = true
	for _, entry in self.motors do
		entry.motor.C0 = entry.rest
	end
	local tracks = self.compiled.tracks
	local function final(channel: string): number
		local values = tracks[channel].values
		return values[#values]
	end
	self.model:PivotTo(self:_rootCFrame(final("side"), 0, final("fwd"), final("yaw"), 0, 0))
end

return Celebrations
