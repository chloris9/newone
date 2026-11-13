-- Turns mouse or touch into shot or pass input.
--   SHOT: press on the goal to aim (X -1..1, Y 0..1), hold to charge the power meter, release.
--   PASS: press and drag; the point on the grass under the finger is where the ball goes, its
--         distance from the ball is the power. Release to pass (drags shorter than MinRange cancel).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShotConfig = require(Shared:WaitForChild("ShotConfig"))
local ShotPhysics = require(Shared:WaitForChild("ShotPhysics"))
local PassConfig = require(Shared:WaitForChild("PassConfig"))

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
		-- SHOT: (aimX, aimY, power); PASS: (dirX, dirZ, power)
		onShoot = nil :: ((a: number, b: number, power: number) -> ())?,
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
	if not self.holding or self.mode ~= "SHOT" then
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

-- Projects a screen point onto the grass (Y = 0), limited to the longest pass.
function InputController:_screenToGround(position: Vector3): Vector3?
	local ray = screenRay(position)
	if not ray or ray.Direction.Y > -1e-4 then
		return nil
	end
	local point = ray.Origin + ray.Direction * (-ray.Origin.Y / ray.Direction.Y)
	local origin = self.passOrigin
	local delta = Vector3.new(point.X - origin.X, 0, point.Z - origin.Z)
	local maxRange = PassConfig.Ball.MaxRange
	if delta.Magnitude > maxRange then
		delta = delta.Unit * maxRange
	end
	return origin + delta
end

function InputController:_aimAt(position: Vector3)
	if self.mode == "PASS" then
		local target = self:_screenToGround(position)
		if target then
			self.target = target
			local origin = self.passOrigin
			self.power = Vector3.new(target.X - origin.X, 0, target.Z - origin.Z).Magnitude / PassConfig.Ball.MaxRange
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
	if self.mode == "PASS" then
		local target = self.target
		local origin = self.passOrigin
		local delta = target and Vector3.new(target.X - origin.X, 0, target.Z - origin.Z)
		if not delta or delta.Magnitude < PassConfig.Ball.MinRange then
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
		self.onShoot(dir.X, dir.Z, math.clamp(delta.Magnitude / PassConfig.Ball.MaxRange, 0, 1))
		return
	end
	self.onShoot(self.aimX, self.aimY, self.power)
end

return InputController
