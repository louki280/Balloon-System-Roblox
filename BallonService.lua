-- Discord: louki280 / Roblox: Louki280 (aze28282828)

-- Services
local PLRS = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RNS = game:GetService("RunService")

-- Packages
local Knit = require(RS.Packages.Knit)
local Janitor = require(RS.Packages.Janitor)
local Ratelimit = require(RS.Packages.RateLimit)

-- Modules
local GameData = require(RS.Utils.GameData)
local PlaySound = require(RS.Utils.PlaySound)

local BalloonService = Knit.CreateService({
	Name = "BalloonService",
	Client = {},
})

local function isFiniteNumber(v)
	return type(v) == "number" and v == v and math.abs(v) ~= math.huge
end

local function isValidVector(v)
	return typeof(v) == "Vector3"
		and isFiniteNumber(v.X)
		and isFiniteNumber(v.Y)
		and isFiniteNumber(v.Z)
		and isFiniteNumber(v.Magnitude)
end

local function getCharData(player)
	if not player or player.Parent ~= PLRS then
		return
	end

	local char = player.Character
	if not char then
		return
	end

	local root = char:FindFirstChild("HumanoidRootPart")
	local hum = char:FindFirstChildWhichIsA("Humanoid")

	if not root or not hum or hum.Health <= 0 then
		return
	end

	return char, root, hum
end

local function getBalloonRange(balloon)
	local range = balloon:GetAttribute("Range")

	if not isFiniteNumber(range) or range <= 0 then
		range = 16
		balloon:SetAttribute("Range", range)
	end

	return math.clamp(range, 4, 40)
end

function BalloonService:GetBalloon(pos)
	local closest
	local closestDist = math.huge

	for balloon in pairs(self.Balloons) do
		if balloon.Parent and balloon:IsDescendantOf(self.BalloonsFolder) then
			local dist = (pos - balloon.Position).Magnitude
			local range = getBalloonRange(balloon)

			if dist <= range and dist < closestDist then
				closest = balloon
				closestDist = dist
			end
		end
	end

	return closest
end

function BalloonService:CanRequest(player)
	if not player or player.Parent ~= PLRS then
		return false
	end

	return self.RequestLimit(player)
end

function BalloonService:GetLaunchData(player)
	local _, root, hum = getCharData(player)
	if not root or not hum then
		return
	end

	local balloon = self:GetBalloon(root.Position)
	if not balloon then
		return
	end

	local now = os.clock()
	local last = self.LastLaunch[player]
	local cooldown = GameData.BalloonConfig.BalloonCooldown

	if not isFiniteNumber(cooldown) or cooldown < 0 then
		return
	end

	if last and now - last < cooldown then
		return
	end

	self.LastLaunch[player] = now -- Both throw types share the same cooldown.
	return balloon, root
end

function BalloonService:CreateBalloonForces(balloon, att)
	local lift = balloon:FindFirstChild("BalloonLift")
	if not lift or not lift:IsA("VectorForce") then
		if lift then
			lift:Destroy()
		end

		lift = Instance.new("VectorForce")
		lift.Name = "BalloonLift"
		lift.Parent = balloon
	end

	lift.Attachment0 = att
	lift.RelativeTo = Enum.ActuatorRelativeTo.World
	lift.ApplyAtCenterOfMass = true

	local upright = balloon:FindFirstChild("BalloonUpright")
	if not upright or not upright:IsA("AlignOrientation") then
		if upright then
			upright:Destroy()
		end

		upright = Instance.new("AlignOrientation")
		upright.Name = "BalloonUpright"
		upright.Parent = balloon
	end

	upright.Attachment0 = att
	upright.Mode = Enum.OrientationAlignmentMode.OneAttachment
	upright.CFrame = CFrame.new()
	upright.RigidityEnabled = false
	upright.MaxTorque = 100000
	upright.MaxAngularVelocity = 6
	upright.Responsiveness = 6

	return lift, upright
end

function BalloonService:PushBalloon(balloon, hit, state)
	if not hit or not hit:IsA("BasePart") or hit.Anchored then
		return
	end

	local now = os.clock()
	if now - state.LastPush < 0.15 then
		return
	end

	state.LastPush = now

	local offset = balloon.Position - hit.Position
	local flat = Vector3.new(offset.X, 0, offset.Z)

	if flat.Magnitude < 0.01 then
		flat = Vector3.new(
			state.Random:NextNumber(-1, 1),
			0,
			state.Random:NextNumber(-1, 1)
		)

		if flat.Magnitude < 0.01 then
			flat = Vector3.xAxis
		end
	end

	local dir = (flat.Unit + Vector3.new(0, 0.35, 0)).Unit
	local speed = math.clamp(hit.AssemblyLinearVelocity.Magnitude * 0.5 + 8, 8, 22)

	balloon:ApplyImpulse(dir * balloon.AssemblyMass * speed)
	balloon.AssemblyAngularVelocity += Vector3.new(dir.Z, 0, -dir.X) * 3
end

function BalloonService:UpdateBalloon(balloon, state, now)
	if not balloon.Parent or not balloon:IsDescendantOf(self.BalloonsFolder) then
		self:RemoveBalloon(balloon)
		return
	end

	local mass = balloon.AssemblyMass
	local vel = balloon.AssemblyLinearVelocity

	-- Lift stays just below gravity, which makes the balloon fall slowly instead of floating away.
	local liftForce = mass * workspace.Gravity * (1 - 0.06 + 0.03 * math.sin(now * 1.8))

	local drag = Vector3.new(
		-vel.X * 1.5,
		-vel.Y * 2.5,
		-vel.Z * 1.5
	) * mass

	-- Noise gives the balloon a smooth sway without changing direction randomly every frame.
	local sway = Vector3.new(
		math.noise(now * 0.35, state.SeedX, 0),
		0,
		math.noise(now * 0.35, state.SeedZ, 0)
	) * 5 * mass

	local wind = workspace:GetAttribute("BalloonWind")
	if typeof(wind) == "Vector3" then
		sway += wind * mass
	end

	state.Lift.Force = Vector3.new(0, liftForce, 0) + drag + sway
end

function BalloonService:RemoveBalloon(balloon)
	self.Balloons[balloon] = nil

	local janitor = self.BalloonJanitors[balloon]
	self.BalloonJanitors[balloon] = nil

	if janitor then
		janitor:Cleanup() -- Each balloon cleans up its own listeners when removed.
	end
end

function BalloonService:SetupBalloon(balloon)
	if not balloon:IsA("BasePart") or self.Balloons[balloon] then
		return
	end

	local janitor = Janitor.new()
	local rnd = Random.new()

	local state = {
		Janitor = janitor,
		Random = rnd,
		LastPush = 0,
		SeedX = rnd:NextNumber(0, 1000),
		SeedZ = rnd:NextNumber(0, 1000),
	}

	self.Balloons[balloon] = state
	self.BalloonJanitors[balloon] = janitor

	balloon.Anchored = false
	balloon.CanCollide = true
	balloon.CustomPhysicalProperties = PhysicalProperties.new(0.2, 0.6, 0.6, 1, 1)

	getBalloonRange(balloon)

	local att = balloon:FindFirstChild("BalloonAttachment")
	if not att or not att:IsA("Attachment") then
		if att then
			att:Destroy()
		end

		att = Instance.new("Attachment")
		att.Name = "BalloonAttachment"
		att.Parent = balloon
	end

	local lift, upright = self:CreateBalloonForces(balloon, att)
	state.Lift = lift
	state.Upright = upright

	pcall(function()
		balloon:SetNetworkOwner(nil) -- Physics stays on the server so clients don't own the simulation.
	end)

	janitor:Add(balloon.Touched:Connect(function(hit)
		self:PushBalloon(balloon, hit, state)
	end))

	janitor:Add(balloon:GetAttributeChangedSignal("Range"):Connect(function()
		getBalloonRange(balloon)
	end))
end

function BalloonService:LaunchUpward(player)
	if not self:CanRequest(player) then
		return false
	end

	local power = GameData.BalloonConfig.UpwardPower
	if not isFiniteNumber(power) or power <= 0 then
		return false
	end

	local balloon = self:GetLaunchData(player)
	if not balloon then
		return false
	end

	balloon.AssemblyLinearVelocity = Vector3.zero
	balloon:ApplyImpulse(Vector3.yAxis * balloon.AssemblyMass * power)
	balloon.AssemblyAngularVelocity += Vector3.new(
		math.random(-10, 10),
		math.random(-10, 10),
		math.random(-10, 10)
	)

	if player then
		PlaySound:PlaySoundWithRandomSpeedInPart("Slap", 0.8, 1.2, player.Character.HumanoidRootPart)
	end

	return true
end

function BalloonService.Client:LaunchUpward(player)
	return self.Server:LaunchUpward(player)
end

function BalloonService:Launch(player, lookVector, power)
	if not self:CanRequest(player) then
		return false
	end

	if not isValidVector(lookVector) or not isFiniteNumber(power) then
		return false
	end

	power = math.clamp(math.floor(power + 0.5), 1, 5)

	local speeds = GameData.BalloonConfig.PowerSpeeds
	local speed = type(speeds) == "table" and speeds[power]

	if not isFiniteNumber(speed) or speed <= 0 then
		return false
	end

	local balloon, root = self:GetLaunchData(player)
	if not balloon then
		return false
	end

	if lookVector.Magnitude < 0.001 then
		lookVector = root.CFrame.LookVector
	end

	local dir = lookVector.Unit -- The throw uses direction only, not the original vector's length.

	balloon.AssemblyLinearVelocity = Vector3.zero
	balloon:ApplyImpulse(dir * balloon.AssemblyMass * speed)
	balloon.AssemblyAngularVelocity += Vector3.new(dir.Z, 0, -dir.X) * 3
	
	if player then
		PlaySound:PlaySoundWithRandomSpeedInPart("Slap", 0.8, 1.2, player.Character.HumanoidRootPart)
	end
	return true
end

function BalloonService.Client:Launch(player, lookVector, power)
	return self.Server:Launch(player, lookVector, power)
end

function BalloonService:KnitInit()
	self.Balloons = {}
	self.BalloonJanitors = {}
	self.LastLaunch = {}
	self.RequestLimit = Ratelimit(8, 1)
	self.Janitor = Janitor.new()

	self.Janitor:Add(PLRS.PlayerRemoving:Connect(function(player)
		self.LastLaunch[player] = nil
	end))
end

function BalloonService:KnitStart()
	self.BalloonsFolder = workspace:WaitForChild("ScriptRelated"):WaitForChild("Balloons")

	self.Janitor:Add(self.BalloonsFolder.ChildAdded:Connect(function(balloon)
		self:SetupBalloon(balloon)
	end))

	self.Janitor:Add(self.BalloonsFolder.ChildRemoved:Connect(function(balloon)
		self:RemoveBalloon(balloon)
	end))

	for _, balloon in ipairs(self.BalloonsFolder:GetChildren()) do
		self:SetupBalloon(balloon)
	end

	-- One shared Heartbeat loop is cheaper than creating a connection for every balloon.
	self.Janitor:Add(RNS.Heartbeat:Connect(function()
		local now = os.clock()

		for balloon, state in pairs(self.Balloons) do
			self:UpdateBalloon(balloon, state, now)
		end
	end))
end

return BalloonService
