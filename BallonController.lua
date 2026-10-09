-- Discord: louki280 / Roblox: Louki280 (aze28282828)

-- Services
local GS = game:GetService("GuiService")
local PLRS = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RNS = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local TS = game:GetService("TweenService")

-- Packages
local Knit = require(RS.Packages.Knit)
local Janitor = require(RS.Packages.Janitor)
local Promise = require(RS.Packages.Promise)

local BalloonController = Knit.CreateController({
	Name = "BalloonController",
})

local PLR = PLRS.LocalPlayer
local PlaySound = require(RS.Utils.PlaySound)

local function isFiniteNumber(v)
	return type(v) == "number" and v == v and math.abs(v) ~= math.huge
end

function BalloonController:RefreshUI()
	local pg = PLR:FindFirstChildOfClass("PlayerGui")
	local hud = pg and pg:FindFirstChild("HUD")

	if hud == self.hud and (not hud or self.uiReady) then
		return
	end

	self.hud = hud
	self.uiReady = false
	self.handIcon = nil
	self.powerFrame = nil

	if not hud then
		return
	end

	local utils = hud:FindFirstChild("Utils")
	if not utils then
		return
	end

	self.uiReady = true

	local icon = utils:FindFirstChild("HandIcon") or utils:FindFirstChild("SlapIcon")
	if icon then
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Visible = false
	end

	self.handIcon = icon
	self.powerFrame = utils:FindFirstChild("Power")
	self:ShowPower()
end

function BalloonController:LaunchUpward()
	PlaySound:PlaySoundWithRandomSpeed("Slap", 0.8, 1.2)

	Promise.try(function()
		return self.BalloonService:LaunchUpward()
	end):catch(function(err)
		warn("BalloonController:", err)
	end)
end

function BalloonController:ShowPower(power)
	if not self.powerFrame then
		return
	end

	if power then
		PlaySound:PlaySoundWithRandomSpeed("Tick", 0.8, 1.2)
	end

	for i = 1, 5 do
		local seg = self.powerFrame:FindFirstChild(tostring(i))
		if seg then
			local scale = seg:FindFirstChildOfClass("UIScale")

			if not scale then
				scale = Instance.new("UIScale")
				scale.Scale = 0
				scale.Parent = seg
			end

			local value = power and i <= power and 1 or 0
			seg.Visible = value > 0

			local tween = TS:Create(
				scale,
				TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{Scale = value}
			)

			self.Janitor:Add(tween, "Cancel", "PowerTween" .. i) -- Replacing a charge animation cancels the previous tween for that segment.
			tween:Play()
		end
	end
end

function BalloonController:IsHoveringBalloon()
	local cam = workspace.CurrentCamera
	local related = workspace:FindFirstChild("ScriptRelated")
	local balloons = related and related:FindFirstChild("Balloons")

	if not cam or not balloons then
		return false
	end

	local char = PLR.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")

	if not root then
		return false
	end

	local mouse = UIS:GetMouseLocation()
	local ray = cam:ScreenPointToRay(mouse.X, mouse.Y) -- Uses the same screen coordinates returned by GetMouseLocation.

	self.rayParams.FilterDescendantsInstances = {char}

	local result = workspace:Raycast(ray.Origin, ray.Direction * 1000, self.rayParams)
	if not result then
		return false
	end

	local balloon = result.Instance
	if not balloon:IsA("BasePart") or balloon.Parent ~= balloons then
		return false
	end

	local range = balloon:GetAttribute("Range") or 16
	if type(range) ~= "number" or not isFiniteNumber(range) or range <= 0 then
		range = 16
	end

	return (root.Position - balloon.Position).Magnitude <= range
end

function BalloonController:CancelCharge()
	self.charging = false
	self.power = 1
	self:ShowPower()
end

function BalloonController:Update()
	self:RefreshUI()
	UIS.MouseIconEnabled = false

	if self.handIcon then
		local hovering = self:IsHoveringBalloon()
		self.handIcon.Visible = hovering

		if hovering then
			local pos = UIS:GetMouseLocation()

			if self.hud and not self.hud.IgnoreGuiInset then
				pos -= GS:GetGuiInset() -- Converts screen coordinates to the HUD's coordinates when the inset is ignored.
			end

			self.handIcon.Position = UDim2.fromOffset(pos.X, pos.Y)
		end
	end

	if self.charging then
		local power = math.clamp(1 + math.floor((os.clock() - self.chargeStart) / 0.3), 1, 5) -- Charge increases one level every 0.3 seconds.

		if power ~= self.power then
			self.power = power
			self:ShowPower(power)
		end
	end
end

function BalloonController:Release()
	if not self.charging then
		return
	end

	local power = self.power
	local hovering = self:IsHoveringBalloon() -- The cursor may have moved off the balloon while the player was charging.

	self:CancelCharge()

	if not hovering then
		return
	end

	local cam = workspace.CurrentCamera
	if not cam then
		return
	end

	PlaySound:PlaySoundWithRandomSpeed("Slap", 0.8, 1.2)

	Promise.try(function()
		return self.BalloonService:Launch(cam.CFrame.LookVector, power)
	end):catch(function(err)
		warn("BalloonController:", err)
	end)
end

function BalloonController:KnitStart()
	self.BalloonService = Knit.GetService("BalloonService")

	self.Janitor:Add(UIS.InputBegan:Connect(function(input, gp)
		if gp then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self.charging = true
			self.chargeStart = os.clock()
			self.power = 1
			self:ShowPower(1)

		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			self:CancelCharge()
			self:LaunchUpward()
		end
	end))

	self.Janitor:Add(UIS.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self:Release()
		end
	end))

	self.Janitor:Add(UIS.WindowFocusReleased:Connect(function()
		self:CancelCharge() -- The release event may never fire if the player clicks outside the game window.
	end))

	self.Janitor:Add(RNS.RenderStepped:Connect(function()
		self:Update()
	end))
end

function BalloonController:KnitInit()
	self.charging = false
	self.power = 1
	self.chargeStart = 0

	self.rayParams = RaycastParams.new()
	self.rayParams.FilterType = Enum.RaycastFilterType.Exclude

	self.Janitor = Janitor.new()

	UIS.MouseIconEnabled = false
end

return BalloonController
