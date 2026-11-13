-- Procedural goalkeeper animation for the R15 rig (no animation assets needed).
-- Poses are joint rotations in degrees around the rig's own axes (X right, Y up, Z back;
-- +X swings a hanging limb forward, +Z swings it to the rig's right), blended with
-- exponential smoothing. Dives are authored towards world +X and mirrored for -X.
-- Client-only: the server's model never moves, every player animates their own keeper.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ShotConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ShotConfig"))

local Keeper = ShotConfig.Goalkeeper
local S = Keeper.ModelScale / 1.4 -- poses below were tuned at scale 1.4

local JOINT_NAMES = {
	"Waist", "Neck",
	"LeftShoulder", "LeftElbow", "LeftWrist", "RightShoulder", "RightElbow", "RightWrist",
	"LeftHip", "LeftKnee", "LeftAnkle", "RightHip", "RightKnee", "RightAnkle",
}

type Joints = { [string]: Vector3 }
type Plan = {
	reaction: number,
	impactTime: number, -- when the ball reaches the keeper's plane
	target: Vector3, -- body centre at impact, logic coordinates (see ShotConfig.Goalkeeper)
	kind: string?, -- "CATCH" | "PARRY" | nil (beaten or not diving)
	dives: boolean,
}

local function J(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z)
end

-- Ready stance; depth 0 = relaxed, 1 = set (player is charging the shot).
local function readyJoints(depth: number): Joints
	local hip, knee = 36 + 14 * depth, -(60 + 18 * depth)
	local spread = 32 + 8 * depth
	return {
		Waist = J(-16 - 6 * depth, 0, 0),
		Neck = J(12 + 4 * depth, 0, 0),
		LeftShoulder = J(26, 0, -spread), RightShoulder = J(26, 0, spread),
		LeftElbow = J(38, 0, 0), RightElbow = J(38, 0, 0),
		LeftWrist = J(-10, 0, 0), RightWrist = J(-10, 0, 0),
		LeftHip = J(hip, 0, -9), RightHip = J(hip, 0, 9),
		LeftKnee = J(knee, 0, 0), RightKnee = J(knee, 0, 0),
		LeftAnkle = J(24 + 4 * depth, 0, 0), RightAnkle = J(24 + 4 * depth, 0, 0),
	}
end

local function readyDrop(depth: number): number
	return -(0.45 + 0.2 * depth) * S
end

-- Towards world +X, which is the keeper's LEFT (he faces the shooter).
local LOAD: Joints = {
	Waist = J(-20, 0, 6), Neck = J(10, 0, 0),
	LeftShoulder = J(30, 0, -60), RightShoulder = J(30, 0, 40),
	LeftElbow = J(30, 0, 0), RightElbow = J(30, 0, 0),
	LeftWrist = J(-15, 0, 0), RightWrist = J(-15, 0, 0),
	LeftHip = J(28, 0, -24), RightHip = J(52, 0, 6),
	LeftKnee = J(-40, 0, 0), RightKnee = J(-85, 0, 0),
	LeftAnkle = J(18, 0, 0), RightAnkle = J(30, 0, 0),
}
local FLIGHT: Joints = {
	Waist = J(-4, 0, 10), Neck = J(6, 0, 12),
	LeftShoulder = J(12, 0, -158), RightShoulder = J(12, 0, 172),
	LeftElbow = J(6, 0, 0), RightElbow = J(8, 0, 0),
	LeftWrist = J(-25, 0, 0), RightWrist = J(-25, 0, 0),
	LeftHip = J(8, 0, -6), RightHip = J(-6, 0, 28),
	LeftKnee = J(-18, 0, 0), RightKnee = J(-10, 0, 0),
	LeftAnkle = J(25, 0, 0), RightAnkle = J(25, 0, 0),
}
local HUG: Joints = { -- ball pulled into the chest
	Waist = J(-22, 0, 4), Neck = J(-8, 0, 6),
	LeftShoulder = J(66, 0, -18), RightShoulder = J(66, 0, 18),
	LeftElbow = J(100, 0, 0), RightElbow = J(100, 0, 0),
	LeftWrist = J(0, 0, 0), RightWrist = J(0, 0, 0),
	LeftHip = J(48, 0, -8), RightHip = J(55, 0, 8),
	LeftKnee = J(-75, 0, 0), RightKnee = J(-85, 0, 0),
	LeftAnkle = J(20, 0, 0), RightAnkle = J(20, 0, 0),
}
local LYING: Joints = { -- after a parry or a goal: stretched out on the grass
	Waist = J(-2, 0, 4), Neck = J(4, 0, 8),
	LeftShoulder = J(10, 0, -150), RightShoulder = J(14, 0, 162),
	LeftElbow = J(12, 0, 0), RightElbow = J(15, 0, 0),
	LeftWrist = J(-10, 0, 0), RightWrist = J(-10, 0, 0),
	LeftHip = J(14, 0, -4), RightHip = J(22, 0, 14),
	LeftKnee = J(-30, 0, 0), RightKnee = J(-40, 0, 0),
	LeftAnkle = J(15, 0, 0), RightAnkle = J(15, 0, 0),
}
local DEJECTED: Joints = table.clone(LYING)
DEJECTED.Neck = J(-30, 0, 4)
DEJECTED.LeftShoulder = J(40, 0, -60)
DEJECTED.RightShoulder = J(40, 0, 70)

local JUMP: Joints = { -- central high ball: both arms straight up, knees tucked
	Waist = J(4, 0, 0), Neck = J(20, 0, 0),
	LeftShoulder = J(8, 0, -172), RightShoulder = J(8, 0, 172),
	LeftElbow = J(4, 0, 0), RightElbow = J(4, 0, 0),
	LeftWrist = J(-20, 0, 0), RightWrist = J(-20, 0, 0),
	LeftHip = J(40, 0, -6), RightHip = J(40, 0, 6),
	LeftKnee = J(-80, 0, 0), RightKnee = J(-80, 0, 0),
	LeftAnkle = J(30, 0, 0), RightAnkle = J(30, 0, 0),
}
local BLOCK: Joints = { -- central low/mid ball: get down behind it, hands in front
	Waist = J(-30, 0, 0), Neck = J(18, 0, 0),
	LeftShoulder = J(72, 0, -10), RightShoulder = J(72, 0, 10),
	LeftElbow = J(50, 0, 0), RightElbow = J(50, 0, 0),
	LeftWrist = J(-15, 0, 0), RightWrist = J(-15, 0, 0),
	LeftHip = J(78, 0, -14), RightHip = J(78, 0, 14),
	LeftKnee = J(-105, 0, 0), RightKnee = J(-105, 0, 0),
	LeftAnkle = J(30, 0, 0), RightAnkle = J(30, 0, 0),
}

local function mirror(joints: Joints): Joints
	local out = {}
	for name, v in joints do
		local swapped = if string.sub(name, 1, 4) == "Left" then "Right" .. string.sub(name, 5)
			elseif string.sub(name, 1, 5) == "Right" then "Left" .. string.sub(name, 6)
			else name
		out[swapped] = Vector3.new(v.X, -v.Y, -v.Z)
	end
	return out
end

local function blend(a: Joints, b: Joints, t: number): Joints
	local out = {}
	for _, name in JOINT_NAMES do
		local va, vb = a[name] or Vector3.zero, b[name] or Vector3.zero
		out[name] = va:Lerp(vb, t)
	end
	return out
end

local function smoothstep(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

local function easeOut(t: number): number
	t = math.clamp(t, 0, 1)
	return 1 - (1 - t) * (1 - t)
end

local KeeperAnimator = {}
KeeperAnimator.__index = KeeperAnimator

function KeeperAnimator.new(model: Model)
	local self = setmetatable({}, KeeperAnimator)
	self.model = model
	self.home = model:GetPivot()
	self.homeRotation = self.home.Rotation
	self.motors = {}
	for _, name in JOINT_NAMES do
		local motor = model:FindFirstChild(name, true)
		if motor and motor:IsA("Motor6D") then
			self.motors[name] = { motor = motor, base = motor.C0 }
		end
	end
	self.leftHand = model:FindFirstChild("LeftHand", true)
	self.rightHand = model:FindFirstChild("RightHand", true)

	-- Current (smoothed) pose.
	self.joints = readyJoints(0)
	self.pos = Vector3.new(0, readyDrop(0), 0)
	self.roll = 0
	self.yaw = 0
	self.clock = 0
	self.state = "ready"
	self.charging = false
	self.chargeStarted = -math.huge
	self.lyingOffset = 0.95 * Keeper.ModelScale - self.home.Position.Y
	return self
end

function KeeperAnimator:setCharging(on: boolean)
	if on and not self.charging then
		self.chargeStarted = self.clock -- split-step hop as the shooter shapes up
	end
	self.charging = on
end

function KeeperAnimator:startShot(plan: Plan)
	self.state = "shot"
	self.plan = plan
	self.shotTime = 0
	self.charging = false
	local offset = Vector3.new(plan.target.X - Keeper.HomeX, plan.target.Y - Keeper.HomeY, 0)
	offset = Vector3.new(offset.X, math.max(offset.Y, self.lyingOffset * 0.55), 0)
	self.diveOffset = offset
	self.side = if offset.X >= 0 then 1 else -1
	-- Central balls are blocked or jumped for; everything else is a dive.
	if not plan.dives then
		self.style = "watch"
	elseif math.abs(offset.X) < 2.2 then
		self.style = if offset.Y > 1.2 then "jump" else "block"
	else
		self.style = "dive"
	end
	-- Lean from the feet towards the ball (world roll; negative leans to +X).
	local fromFeet = Vector3.new(offset.X, offset.Y + Keeper.HomeY, 0)
	self.diveRoll = math.clamp(math.deg(math.atan2(-fromFeet.X, fromFeet.Y)), -92, 92)
end

function KeeperAnimator:recover()
	self.state = "recover"
	self.recoverStarted = self.clock
	self.plan = nil
end

function KeeperAnimator:handsPosition(): Vector3?
	if self.leftHand and self.rightHand then
		return (self.leftHand.Position + self.rightHand.Position) / 2
	end
	return nil
end

-- Desired pose for this frame: joints, root offset, roll, yaw and smoothing rates.
function KeeperAnimator:_target(): (Joints, Vector3, number, number, number, number)
	local t = self.clock
	if self.state ~= "shot" then
		local depth = if self.charging then 1 else 0
		local joints = readyJoints(depth)
		local sway = if self.charging then 0 else math.sin(t * 2.1) * 0.45 * S
		local bounce = math.abs(math.sin(t * 4.2)) * 0.1 * S
		-- Weight shifts from foot to foot with the sway.
		local shift = math.sin(t * 2.1) * 6 * (1 - depth)
		joints.LeftHip += J(0, 0, -shift)
		joints.RightHip += J(0, 0, -shift)
		local hop = t - self.chargeStarted
		local lift = if hop < 0.32 then math.sin(hop / 0.32 * math.pi) * 0.6 * S else 0
		local pos = Vector3.new(sway, readyDrop(depth) + bounce + lift, 0)
		local rate = if self.state == "recover" and t - self.recoverStarted < 0.6 then 9 else 14
		return joints, pos, 0, 0, rate, rate
	end

	local plan = self.plan :: Plan
	local st = self.shotTime
	local side = self.side
	local offset = self.diveOffset
	local function sided(joints: Joints): Joints
		return if side > 0 then joints else mirror(joints)
	end

	if self.style == "watch" then
		local joints = readyJoints(0.4)
		joints.Neck += J(0, 40 * side, 0)
		joints.Waist += J(0, 15 * side, 0)
		local step = smoothstep((st - plan.reaction) / 0.4)
		return joints, Vector3.new(offset.X * step, readyDrop(0.4), 0), 0, 0, 12, 12
	end

	local reach = math.max(plan.impactTime - plan.reaction, 0.12)
	local alpha = (st - plan.reaction) / reach
	local after = st - plan.impactTime
	local caught = plan.kind == "CATCH"

	if alpha < 0 then
		return readyJoints(1), Vector3.new(0, readyDrop(1), 0), 0, 0, 16, 16
	end

	if self.style == "jump" or self.style == "block" then
		local high = self.style == "jump"
		local pose = if high then JUMP else BLOCK
		local landed = math.clamp(after / 0.35, 0, 1)
		local up = easeOut(alpha) * offset.Y
		local pos = Vector3.new(offset.X * easeOut(alpha), if high then up else readyDrop(1) - 0.35 * S, 0)
		if after > 0 then
			pos = Vector3.new(offset.X, if high then up * (1 - landed * landed) else pos.Y, 0)
			pose = if caught then HUG else blend(pose, readyJoints(1), landed * 0.5)
		end
		return pose, pos, 0, 0, 22, 26
	end

	-- Side dive: load, launch, stretch to the ball, then land on the side.
	local loadEnd = 0.18
	if alpha < loadEnd then
		local k = alpha / loadEnd
		local pos = Vector3.new(offset.X * 0.06 * k, readyDrop(1) - 0.25 * S * k, 0)
		return sided(blend(readyJoints(1), LOAD, k)), pos, self.diveRoll * 0.08 * k, 0, 28, 28
	end
	if after <= 0 then
		local u = (alpha - loadEnd) / (1 - loadEnd)
		local arc = if offset.Y > -1 then math.sin(u * math.pi) * 0.9 * S else 0
		local pos = offset * easeOut(u) + Vector3.new(0, arc, 0)
		return sided(blend(LOAD, FLIGHT, smoothstep(u * 1.6))), pos, self.diveRoll * smoothstep(u), 0, 30, 30
	end

	-- Landing: fall to the ground on the dive side, keep sliding a little.
	local land = math.clamp(after / 0.42, 0, 1)
	local fall = land * land
	local x = offset.X + side * 0.7 * S * easeOut(land)
	local y = offset.Y + (self.lyingOffset - offset.Y) * fall
	local roll = self.diveRoll + (-90 * side - self.diveRoll) * smoothstep(land)
	local pose = if caught then HUG elseif plan.kind == "PARRY" then LYING else (if after > 1.1 then DEJECTED else LYING)
	return sided(pose), Vector3.new(x, y, 0), roll, 0, 18, 12
end

function KeeperAnimator:update(dt: number)
	self.clock += dt
	if self.state == "shot" then
		self.shotTime += dt
	end
	local joints, pos, roll, yaw, rootRate, jointRate = self:_target()

	local jk = 1 - math.exp(-jointRate * dt)
	local rk = 1 - math.exp(-rootRate * dt)
	for _, name in JOINT_NAMES do
		local current = self.joints[name] or Vector3.zero
		self.joints[name] = current:Lerp(joints[name] or Vector3.zero, jk)
	end
	self.pos = self.pos:Lerp(pos, rk)
	self.roll += (roll - self.roll) * rk
	self.yaw += (yaw - self.yaw) * rk

	local root = CFrame.new(self.home.Position + self.pos) * CFrame.Angles(0, 0, math.rad(self.roll)) * self.homeRotation
	self.model:PivotTo(root * CFrame.Angles(0, math.rad(self.yaw), 0))
	for name, entry in self.motors do
		local a = self.joints[name]
		entry.motor.C0 = entry.base * CFrame.Angles(math.rad(a.X), math.rad(a.Y), math.rad(a.Z))
	end
end

return KeeperAnimator
