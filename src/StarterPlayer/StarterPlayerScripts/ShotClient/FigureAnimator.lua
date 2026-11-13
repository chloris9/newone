-- Procedural animation for the outfield players of the pass drill (FigureBuilder rigs).
-- Same joint conventions as KeeperAnimator: degrees around the rig's own axes, +X swings a
-- hanging limb forward, +Z swings it to the rig's right; knees bend with -X.
-- Feed it a ground position and facing every frame (moveTo); it derives the run cycle from
-- the speed and overlays one-shot or looping actions.

local FigureAnimator = {}
FigureAnimator.__index = FigureAnimator

local JOINT_NAMES = {
	"Waist", "Neck",
	"LeftShoulder", "LeftElbow", "LeftWrist", "RightShoulder", "RightElbow", "RightWrist",
	"LeftHip", "LeftKnee", "LeftAnkle", "RightHip", "RightKnee", "RightAnkle",
}

-- One-shot actions and their length in seconds; WAVE, CHEER and SLIDE loop until replaced.
local DURATION = { KICK = 0.5, TRAP = 0.55, LUNGE = 0.8, NOD = 0.8 }

local function J(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z)
end

local function smooth(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

function FigureAnimator.new(model: Model, rootHeight: number, scale: number)
	local self = setmetatable({}, FigureAnimator)
	self.model = model
	self.rootHeight = rootHeight
	self.scale = scale
	self.motors = {}
	for _, name in JOINT_NAMES do
		local motor = model:FindFirstChild(name, true)
		if motor and motor:IsA("Motor6D") then
			self.motors[name] = { motor = motor, base = motor.C0 }
		end
	end
	self.joints = {}
	self.position = Vector3.zero
	self.facing = Vector3.new(0, 0, -1)
	self.speed = 0
	self.phase = math.random() * math.pi * 2
	self.clock = math.random() * 10
	self.action = nil
	self.actionTime = 0
	self.drop = 0
	return self
end

-- Jumps straight there (new episode).
function FigureAnimator:place(position: Vector3, facing: Vector3?)
	self.position = Vector3.new(position.X, 0, position.Z)
	if facing and facing.Magnitude > 1e-3 then
		self.facing = Vector3.new(facing.X, 0, facing.Z).Unit
	end
	self.speed = 0
end

-- Moves there this frame; the run cycle follows the distance covered.
function FigureAnimator:moveTo(position: Vector3, facing: Vector3?, dt: number)
	local flat = Vector3.new(position.X, 0, position.Z)
	local speed = if dt > 0 then (flat - self.position).Magnitude / dt else 0
	self.speed += (speed - self.speed) * math.min(1, dt * 12)
	self.position = flat
	if facing and facing.Magnitude > 1e-3 then
		local f = Vector3.new(facing.X, 0, facing.Z).Unit
		self.facing = self.facing:Lerp(f, math.min(1, dt * 10))
		if self.facing.Magnitude < 1e-3 then
			self.facing = f
		end
		self.facing = self.facing.Unit
	end
end

-- KICK | TRAP | LUNGE | NOD (one-shot), WAVE | CHEER | SLIDE (loop), nil = back to idle/run.
function FigureAnimator:play(action: string?)
	if self.action == action and (action == "WAVE" or action == "CHEER" or action == "SLIDE") then
		return
	end
	self.action = action
	self.actionTime = 0
end

function FigureAnimator:_pose(): (Vector3, number)
	local run = math.clamp(self.speed / 9, 0, 1)
	local s = math.sin(self.phase)
	local c = math.cos(self.phase)
	local breathe = math.sin(self.clock * 2.2)
	local joints = {
		Waist = J(-10 * run, 0, 0),
		Neck = J(4 * run, 0, 0),
		LeftShoulder = J(-34 * run * s, 0, -8 - 2 * breathe),
		RightShoulder = J(34 * run * s, 0, 8 + 2 * breathe),
		LeftElbow = J(18 + 50 * run, 0, 0),
		RightElbow = J(18 + 50 * run, 0, 0),
		LeftWrist = J(0, 0, 0),
		RightWrist = J(0, 0, 0),
		LeftHip = J(4 + 40 * run * s, 0, -3),
		RightHip = J(4 - 40 * run * s, 0, 3),
		LeftKnee = J(-8 - 55 * run * math.max(0, -c), 0, 0),
		RightKnee = J(-8 - 55 * run * math.max(0, c), 0, 0),
		LeftAnkle = J(4, 0, 0),
		RightAnkle = J(4, 0, 0),
	}
	local bob = math.abs(s) * 0.22 * run + 0.03 * breathe * (1 - run)
	local drop = 0

	local action, t = self.action, self.actionTime
	if action == "KICK" then
		-- Inside-foot pass with the right foot: wind up, swing through, follow through.
		local back = smooth(t / 0.16) * (1 - smooth((t - 0.16) / 0.1))
		local through = smooth((t - 0.16) / 0.1) * (1 - smooth((t - 0.32) / 0.18))
		joints.RightHip = J(-38 * back + 48 * through, 0, 8 * through)
		joints.RightKnee = J(-70 * back - 10 * through, 0, 0)
		joints.RightAnkle = J(10, 0, 0)
		joints.LeftKnee = J(-18 * (back + through), 0, 0)
		joints.LeftShoulder = J(10, 0, -40 * (back + through))
		joints.RightShoulder = J(-20 * through, 0, 32 * (back + through))
		joints.Waist = J(-8, 12 * back - 10 * through, 0)
		drop = 0.15 * (back + through)
	elseif action == "TRAP" then
		local k = smooth(t / 0.15) * (1 - smooth((t - 0.38) / 0.17))
		joints.RightHip = J(28 * k, 0, 6 * k)
		joints.RightKnee = J(-34 * k, 0, 0)
		joints.RightAnkle = J(-18 * k, 0, 0)
		joints.LeftKnee = J(-16 * k, 0, 0)
		joints.LeftShoulder = J(8, 0, -30 * k)
		joints.RightShoulder = J(8, 0, 30 * k)
		joints.Neck = J(18 * k, 0, 0) -- eyes on the ball
		drop = 0.12 * k
	elseif action == "LUNGE" then
		-- Slide in with the right leg stretched towards the ball.
		local k = smooth(t / 0.18) * (1 - smooth((t - 0.55) / 0.25))
		joints.RightHip = J(72 * k, 0, 0)
		joints.RightKnee = J(-4 * k, 0, 0)
		joints.LeftHip = J(-12 * k, 0, 0)
		joints.LeftKnee = J(-75 * k, 0, 0)
		joints.Waist = J(16 * k, 0, 0)
		joints.LeftShoulder = J(30 * k, 0, -55 * k)
		joints.RightShoulder = J(-10 * k, 0, 55 * k)
		drop = 0.75 * k
	elseif action == "WAVE" then
		-- Calling for the ball: right arm up, waving.
		joints.RightShoulder = J(150, 0, 18 + 14 * math.sin(self.clock * 9))
		joints.RightElbow = J(20, 0, 0)
	elseif action == "CHEER" then
		-- Goal celebration with both feet on the ground: right fist pumping, left arm out.
		local pump = math.sin(self.clock * 7)
		joints.RightShoulder = J(150 + 10 * pump, 0, 14)
		joints.RightElbow = J(35 + 15 * pump, 0, 0)
		joints.LeftShoulder = J(10, 0, -55)
		joints.LeftElbow = J(30, 0, 0)
		joints.Waist = J(-6, 0, 0)
		joints.Neck = J(-12, 0, 0)
	elseif action == "NOD" then
		-- Contract signed: arms stay relaxed, one short nod towards the camera.
		local nod = math.max(0, math.sin(math.min(t, 0.8) / 0.8 * math.pi))
		joints.Neck = J(16 * nod, 0, 0)
	elseif action == "SLIDE" then
		-- Goal: down onto both knees (thighs upright, shins flat behind), leaning back with the
		-- arms spread wide and the head thrown back; the fists pump once he has stopped.
		local k = smooth(t / 0.22)
		local pump = if t > 0.9 then math.sin((t - 0.9) * 9) * smooth((t - 0.9) / 0.3) else 0
		joints.LeftHip = J(-6 * k, 0, -6 * k)
		joints.RightHip = J(-6 * k, 0, 6 * k)
		joints.LeftKnee = J(-92 * k, 0, 0)
		joints.RightKnee = J(-92 * k, 0, 0)
		joints.LeftAnkle = J(-30 * k, 0, 0)
		joints.RightAnkle = J(-30 * k, 0, 0)
		joints.Waist = J(22 * k, 0, 0) -- +X tips the upper body back
		joints.Neck = J(28 * k, 0, 0)
		joints.LeftShoulder = J(25 * k, 0, (-105 + 12 * pump) * k)
		joints.RightShoulder = J(25 * k, 0, (105 - 12 * pump) * k)
		joints.LeftElbow = J(12 * k, 0, 0)
		joints.RightElbow = J(12 * k, 0, 0)
		drop = 0.9 * k
		bob = 0
	end
	return joints, bob - drop
end

function FigureAnimator:update(dt: number)
	self.clock += dt
	local cadence = 1.6 + self.speed * 0.42 -- strides per second grow with speed
	self.phase += dt * cadence * math.pi
	if self.action then
		self.actionTime += dt
		local duration = DURATION[self.action]
		if duration and self.actionTime >= duration then
			self.action = nil
		end
	end

	local joints, lift = self:_pose()
	local k = 1 - math.exp(-20 * dt)
	for name, entry in self.motors do
		local target = joints[name] or Vector3.zero
		local current = self.joints[name] or target
		current = current:Lerp(target, k)
		self.joints[name] = current
		entry.motor.C0 = entry.base * CFrame.Angles(math.rad(current.X), math.rad(current.Y), math.rad(current.Z))
	end
	self.drop += (lift - self.drop) * k
	local base = self.position + Vector3.new(0, self.rootHeight + self.drop * self.scale, 0)
	self.model:PivotTo(CFrame.lookAt(base, base + self.facing))
end

return FigureAnimator
