-- Turns mouse or touch into shot or pass input.
--   SHOT: press on the goal to aim (X -1..1, Y 0..1), hold to charge the power meter, release.
--   PASS: press and drag; the point on the grass under the finger is where the ball goes, its
--         distance from the ball is the power. Release to pass (drags shorter than MinRange cancel).
--   MOMENT (match): both. A press on or around the goal is a SHOT; anywhere else a PASS drag, or a
--         CROSS (high ball) while highBall is on. onShoot gets the action as its 4th argument.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShotConfig = require(Shared:WaitForChild("ShotConfig"))
local ShotPhysics = require(Shared:WaitForChild("ShotPhysics"))
local PassConfig = require(Shared:WaitForChild("PassConfig"))
local MomentPhysics = require(Shared:WaitForChild("MomentPhysics"))

-- MOMENT: presses this close to the goal frame (studs on the goal plane) count as a shot.
local SHOT_ZONE_MARGIN_X = 7
local SHOT_ZONE_MARGIN_Y = 5

local InputController = {}
InputController.__index = InputController

type Guide = {
	-- SHOT: presses only count near (aimX, aimY) and the aim stays there.
	aimX: number?,
	aimY: number?,
	accepts: (aimX: number, aimY: number) -> boolean,
	-- PASS: whether a release at this ground point counts.
	acceptsTarget: ((target: Vector3) -> boolean)?,
	onRejected: (() -> ())?,
}

function InputController.new()
	local self = setmetatable({
		enabled = false,
		holding = false,
		mode = "SHOT",
		aimX = 0,
		aimY = 0.5,
		power = 0,
		target = nil :: Vector3?, -- PASS: drop point on the ground
		passOrigin = PassConfig.Origin,
		highBall = false, -- MOMENT: drags are crosses
		action = "SHOT", -- MOMENT: what the current press is (SHOT | PASS | CROSS)
		-- SHOT: (aimX, aimY, power); PASS: (dirX, dirZ, power); MOMENT adds the action
		onShoot = nil :: ((a: number, b: number, power: number, action: string?) -> ())?,
		guide = nil :: Guide?,
		_activeInput = nil :: InputObject?,
		_holdStartedAt = 0,
	}, InputController)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		self:_onBegan(input, gameProcessed)
	end)
	UserInputService.InputChanged:Connect(function(input)
		self:_onChanged(input)
	end)
	UserInputService.InputEnded:Connect(function(input)
		self:_onEnded(input)
	end)
	return self
end

function InputController:setMode(mode: string, passOrigin: Vector3?)
	self.mode = mode
	self.passOrigin = passOrigin or PassConfig.Origin
	self.target = nil
	self.power = 0
	self.action = if mode == "PASS" then "PASS" else "SHOT"
end

function InputController:setHighBall(on: boolean)
	self.highBall = on
end

-- Charging a shot (SHOT mode, or a press on the goal in a moment).
function InputController:isShooting(): boolean
	return self.mode == "SHOT" or (self.mode == "MOMENT" and self.action == "SHOT")
end

function InputController:isPassing(): boolean
	return self.mode == "PASS" or (self.mode == "MOMENT" and self.action ~= "SHOT")
end

function InputController:_range(): (number, number)
	if self.mode == "MOMENT" and self.action == "CROSS" then
		local c = MomentPhysics.Config
		return c.CrossMinRange, c.CrossMaxRange
	end
	return PassConfig.Ball.MinRange, PassConfig.Ball.MaxRange
end

function InputController:setEnabled(enabled: boolean)
	self.enabled = enabled
	if not enabled then
		self.holding = false
		self._activeInput = nil
		self.power = 0
		self.target = nil
	end
end

-- Call every frame: advances the shot power meter while held.
function InputController:update()
	if not self.holding or not self:isShooting() then
		return
	end
	local phase = ((os.clock() - self._holdStartedAt) / ShotConfig.Input.PowerCycleSeconds) % 1
	self.power = 1 - math.abs(1 - 2 * phase) -- 0 -> 1 -> 0
end

function InputController:setGuide(guide: Guide?)
	self.guide = guide
	if guide and guide.aimX and guide.aimY then
		self.aimX, self.aimY = guide.aimX, guide.aimY
	end
end

local function screenRay(position: Vector3): Ray?
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	return camera:ScreenPointToRay(position.X, position.Y)
end

-- Projects a screen point onto the goal plane (Z = 0).
local function screenToAim(position: Vector3): (number?, number?)
	local ray = screenRay(position)
	if not ray or ray.Direction.Z > -1e-4 then
		return nil, nil
	end
	local point = ray.Origin + ray.Direction * (-ray.Origin.Z / ray.Direction.Z)
	return ShotPhysics.goalPointToAim(point)
end

-- MOMENT: whether a press here means a shot (on or around the goal frame).
local function inShotZone(position: Vector3): boolean
	local ray = screenRay(position)
	if not ray or ray.Direction.Z > -1e-4 then
		return false
	end
	local point = ray.Origin + ray.Direction * (-ray.Origin.Z / ray.Direction.Z)
	local goal = ShotConfig.Goal
	return math.abs(point.X) <= goal.Width / 2 + SHOT_ZONE_MARGIN_X and point.Y >= -1 and point.Y <= goal.Height + SHOT_ZONE_MARGIN_Y
end

-- Projects a screen point onto the grass (Y = 0), limited to the longest pass.
function InputController:_screenToGround(position: Vector3): Vector3?
	local ray = screenRay(position)
	if not ray or ray.Direction.Y > -1e-4 then
		return nil
	end
	local point = ray.Origin + ray.Direction * (-ray.Origin.Y / ray.Direction.Y)
	local origin = self.passOrigin
	local delta = Vector3.new(point.X - origin.X, 0, point.Z - origin.Z)
	local _, maxRange = self:_range()
	if delta.Magnitude > maxRange then
		delta = delta.Unit * maxRange
	end
	return origin + delta
end

function InputController:_aimAt(position: Vector3)
	if self:isPassing() then
		local target = self:_screenToGround(position)
		if target then
			self.target = target
			local origin = self.passOrigin
			local _, maxRange = self:_range()
			self.power = Vector3.new(target.X - origin.X, 0, target.Z - origin.Z).Magnitude / maxRange
		end
		return
	end
	if self.guide then
		return
	end
	local aimX, aimY = screenToAim(position)
	if aimX then
		self.aimX, self.aimY = aimX, aimY
	end
end

function InputController:_onBegan(input: InputObject, gameProcessed: boolean)
	if gameProcessed or not self.enabled or self.holding then
		return
	end
	local inputType = input.UserInputType
	if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
		local guide = self.guide
		if guide and self.mode == "SHOT" then
			local aimX, aimY = screenToAim(input.Position)
			if not (aimX and guide.accepts(aimX, aimY)) then
				if guide.onRejected then
					guide.onRejected()
				end
				return
			end
		end
		self.holding = true
		self._activeInput = input
		self._holdStartedAt = os.clock()
		self.power = 0
		if self.mode == "MOMENT" then
			self.action = if inShotZone(input.Position) then "SHOT" elseif self.highBall then "CROSS" else "PASS"
			self.target = nil
		end
		self:_aimAt(input.Position)
	end
end

function InputController:_onChanged(input: InputObject)
	if not self.enabled then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseMovement then
		if self.mode == "SHOT" or self.holding then
			self:_aimAt(input.Position) -- PC: the shot marker follows the mouse even before clicking
		end
	elseif input.UserInputType == Enum.UserInputType.Touch and input == self._activeInput then
		self:_aimAt(input.Position)
	end
end

function InputController:_onEnded(input: InputObject)
	if not self.holding then
		return
	end
	local active = self._activeInput
	local isMouseRelease = input.UserInputType == Enum.UserInputType.MouseButton1
		and active ~= nil
		and active.UserInputType == Enum.UserInputType.MouseButton1
	if not (isMouseRelease or input == active) then
		return
	end

	self.holding = false
	self._activeInput = nil
	if not (self.enabled and self.onShoot) then
		return
	end
	if self:isPassing() then
		local target = self.target
		local origin = self.passOrigin
		local minRange, maxRange = self:_range()
		local delta = target and Vector3.new(target.X - origin.X, 0, target.Z - origin.Z)
		if not delta or delta.Magnitude < minRange then
			self.target, self.power = nil, 0 -- a tap or a tiny drag: no pass
			return
		end
		local guide = self.guide
		if guide and guide.acceptsTarget and not guide.acceptsTarget(target :: Vector3) then
			if guide.onRejected then
				guide.onRejected()
			end
			self.target, self.power = nil, 0
			return
		end
		local dir = delta.Unit
		self.onShoot(dir.X, dir.Z, math.clamp(delta.Magnitude / maxRange, 0, 1), if self.mode == "MOMENT" then self.action else nil)
		return
	end
	self.onShoot(self.aimX, self.aimY, self.power, if self.mode == "MOMENT" then "SHOT" else nil)
end

return InputController
