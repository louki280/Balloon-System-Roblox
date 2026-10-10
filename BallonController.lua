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

-- Same validation logic as the server side.
-- Keeping this here avoids passing obviously broken values around.
local function isFiniteNumber(v)
	return type(v) == "number" and v == v and math.abs(v) ~= math.huge
end

function BalloonController:RefreshUI()
	-- HUD can load late or get recreated, so always re-check the live GUI tree.
	local pg = PLR:FindFirstChildOfClass("PlayerGui")
	local hud = pg and pg:FindFirstChild("HUD")

	-- If nothing changed and the UI is already ready, there's nothing to rebuild.
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

	-- Support both names because UI names tend to drift over time.
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
	-- Promise keeps the error from breaking the whole input flow.
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

	-- A sound on charge change makes the UI feel less dead.
	if power then
		PlaySound:PlaySoundWithRandomSpeed("Tick", 0.8, 1.2)
	end

	for i = 1, 5 do
		local seg = self.powerFrame:FindFirstChild(tostring(i))
		if seg then
			local scale = seg:FindFirstChildOfClass("UIScale")

			-- The UIScale is created lazily so the UI still works even if
			-- the segment was added without one.
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

			-- Replacing an old tween prevents multiple charge animations from
			-- fighting each other on the same segment.
			self.Janitor:Add(tween, "Cancel", "PowerTween" .. i)
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

	-- MouseLocation is already in screen coordinates, so ScreenPointToRay
	-- is the cleanest way to turn that into a world ray.
	local mouse = UIS:GetMouseLocation()
	local ray = cam:ScreenPointToRay(mouse.X, mouse.Y)

	-- Ignore the local character so the ray doesn't get blocked by your own body.
	self.rayParams.FilterDescendantsInstances = {char}

	local result = workspace:Raycast(ray.Origin, ray.Direction * 1000, self.rayParams)
	if not result then
		return false
	end

	local balloon = result.Instance
	if not balloon:IsA("BasePart") or balloon.Parent ~= balloons then
		return false
	end

	-- Range comes from the balloon itself, so different balloons can be
	-- interacted with from different distances.
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

			-- IgnoreGuiInset changes the screen offset, so the icon has to
			-- follow the same coordinate space as the HUD.
			if self.hud and not self.hud.IgnoreGuiInset then
				pos -= GS:GetGuiInset()
			end

			self.handIcon.Position = UDim2.fromOffset(pos.X, pos.Y)
		end
	end

	if self.charging then
		-- Power climbs in steps instead of a smooth ramp, because discrete
		-- levels are easier to read and easier to balance.
		local power = math.clamp(1 + math.floor((os.clock() - self.chargeStart) / 0.3), 1, 5)

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

	-- The cursor might leave the balloon before release, so check again here
	-- instead of trusting the earlier hover state.
	local hovering = self:IsHoveringBalloon()

	self:CancelCharge()

	if not hovering then
		return
	end

	local cam = workspace.CurrentCamera
	if not cam then
		return
	end

	Promise.try(function()
		-- The server decides whether this throw is allowed.
		return self.BalloonService:Launch(cam.CFrame.LookVector, power)
	end):catch(function(err)
		warn("BalloonController:", err)
	end)
end

function BalloonController:KnitStart()
	self.BalloonService = Knit.GetService("BalloonService")

	self.Janitor:Add(UIS.InputBegan:Connect(function(input, gp)
		-- Ignore input that Roblox already used for something else.
		if gp then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			-- Left click starts a charge instead of firing instantly.
			self.charging = true
			self.chargeStart = os.clock()
			self.power = 1
			self:ShowPower(1)

		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			-- Right click is the quick upward throw, so cancel any charge first.
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
		-- If the player alt-tabs or clicks outside the window, the release event
		-- may never arrive. Clearing the charge here avoids stuck input state.
		self:CancelCharge()
	end))

	self.Janitor:Add(RNS.RenderStepped:Connect(function()
		self:Update()
	end))
end

function BalloonController:KnitInit()
	self.charging = false
	self.power = 1
	self.chargeStart = 0

	-- Raycast params are reused instead of rebuilt every frame.
	self.rayParams = RaycastParams.new()
	self.rayParams.FilterType = Enum.RaycastFilterType.Exclude

	self.Janitor = Janitor.new()

	-- Hide the default cursor so the custom hand icon feels intentional.
	UIS.MouseIconEnabled = false
end

return BalloonController
