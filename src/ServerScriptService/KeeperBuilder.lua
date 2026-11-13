-- Builds the goalkeeper on the server: the blocky footballer (Shared/FigureBuilder) with the
-- character sheet's kit painted on. The client fills the decals in (ImageLoader) and animates the
-- rig locally (KeeperAnimator); the server never moves it.
-- Part colours match the kit, so the keeper still looks right if images are unavailable.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShotConfig = require(Shared:WaitForChild("ShotConfig"))
local FigureBuilder = require(Shared:WaitForChild("FigureBuilder"))

local Keeper = ShotConfig.Goalkeeper

local KIT = {
	skin = Color3.fromRGB(214, 132, 82),
	shirt = Color3.fromRGB(30, 22, 40), -- black/purple camo shirt and shorts
	sleeves = Color3.fromRGB(30, 22, 40),
	shorts = Color3.fromRGB(30, 22, 40),
	socks = Color3.fromRGB(22, 18, 28),
	boots = Color3.fromRGB(232, 228, 242),
	hands = Color3.fromRGB(236, 232, 244), -- gloves
	hair = Color3.fromRGB(52, 32, 26),
}

local KeeperBuilder = {}

function KeeperBuilder.build(scene: Instance): Model?
	if not Keeper.Enabled then
		return nil
	end
	local model, rootHeight = FigureBuilder.build("Goalkeeper", KIT, Keeper.ModelScale, "kit")
	model:SetAttribute("Rig", "R15 blocks")
	-- Face the shooter (+Z) and stand with the feet on the ground.
	model:PivotTo(CFrame.new(Keeper.HomeX, rootHeight, Keeper.HomeZ) * CFrame.Angles(0, math.pi, 0))
	model.Parent = scene
	local _, size = model:GetBoundingBox()
	print(string.format("[KeeperBuilder] Goalkeeper ready (%s, %.1f studs tall)", model:GetAttribute("Rig"), size.Y))
	return model
end

return KeeperBuilder
