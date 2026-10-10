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

-- The server keeps control of launch logic on purpose.
-- If this lived on the client, it would be way too easy to fake throws
-- or abuse the balloon physics.
local BalloonService = Knit.CreateService({
	Name = "BalloonService",
	Client = {},
})

-- Lua treats NaN as a number, which is annoying because it can slip through
-- normal checks and then ruin physics calculations later.
-- This catches NaN and Infinity in one place so the rest of the code stays cleaner.
local function isFiniteNumber(v)
	return type(v) == "number" and v == v and math.abs(v) ~= math.huge
end

-- Remote values can be garbage, either from bugs or from someone trying to
-- send nonsense through the network. Validating each axis avoids weird
-- impulse math later.
local function isValidVector(v)
	return typeof(v) == "Vector3"
		and isFiniteNumber(v.X)
		and isFiniteNumber(v.Y)
		and isFiniteNumber(v.Z)
		and isFiniteNumber(v.Magnitude)
end

-- Characters get rebuilt all the time in Roblox, so I prefer to fetch the
-- live parts every time instead of keeping stale references around.
-- That avoids the classic "it worked before respawn" problem.
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

	-- No point continuing if the character is missing important parts
	-- or if the humanoid is already dead.
	if not root or not hum or hum.Health <= 0 then
		return
	end

	return char, root, hum
end

-- Each balloon can have its own usable range.
-- The fallback exists because I do not trust every balloon in the map
-- to be configured correctly forever.
local function getBalloonRange(balloon)
	local range = balloon:GetAttribute("Range")

	-- A broken or missing Range attribute should not break the whole service.
	if not isFiniteNumber(range) or range <= 0 then
		range = 16
		balloon:SetAttribute("Range", range)
	end

	return math.clamp(range, 4, 40)
end

-- Find the closest balloon inside the managed folder.
-- Picking the nearest one matters because if multiple balloons are in range,
-- the player expects the one they are actually closest to.
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

-- RateLimit is here so a player can't spam requests and hammer the server.
-- The extra player check avoids feeding the limiter a player that already left.
function BalloonService:CanRequest(player)
	if not player or player.Parent ~= PLRS then
		return false
	end

	return self.RequestLimit(player)
end

-- Both throw methods share this same validation and cooldown.
-- Keeping that logic in one place prevents one throw type from drifting away
-- from the other over time.
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

	-- A bad config value should fail safely instead of silently breaking
	-- the cooldown system.
	if not isFiniteNumber(cooldown) or cooldown < 0 then
		return
	end

	if last and now - last < cooldown then
		return
	end

	-- One shared cooldown for both upward and directional launches.
	self.LastLaunch[player] = now
	return balloon, root
end

-- Reuse existing forces if possible.
-- Recreating them every time would just add extra garbage and make setup
-- harder to reason about.
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

	-- World-relative force keeps the lift pointing upward even while the balloon
	-- rotates, which makes the movement feel much less chaotic.
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

	-- The goal is not perfect stiffness.
	-- A little freedom makes it look more like a floating object and less
	-- like something welded in place.
	upright.Attachment0 = att
	upright.Mode = Enum.OrientationAlignmentMode.OneAttachment
	upright.CFrame = CFrame.new()
	upright.RigidityEnabled = false
	upright.MaxTorque = 100000
	upright.MaxAngularVelocity = 6
	upright.Responsiveness = 6

	return lift, upright
end

-- Touch events can fire a lot while two parts remain in contact.
-- Without a tiny gate here, the balloon would keep getting shoved over and over.
function BalloonService:PushBalloon(balloon, hit, state)
	if not hit or not hit:IsA("BasePart") or hit.Anchored then
		return
	end

	local now = os.clock()
	if now - state.LastPush < 0.15 then
		return
	end

	state.LastPush = now

	-- Use the horizontal offset so the push feels like it comes from the
	-- collision itself, not from some random direction.
	local offset = balloon.Position - hit.Position
	local flat = Vector3.new(offset.X, 0, offset.Z)

	-- If the two parts are basically on top of each other, there is no useful
	-- direction to push toward, so the fallback avoids a zero-length vector.
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

	-- Add a bit of upward movement so the balloon doesn't only scrape sideways.
	local dir = (flat.Unit + Vector3.new(0, 0.35, 0)).Unit
	local speed = math.clamp(hit.AssemblyLinearVelocity.Magnitude * 0.5 + 8, 8, 22)

	-- Mass scaling keeps the push feeling consistent even if the balloon's
	-- physical properties change later.
	balloon:ApplyImpulse(dir * balloon.AssemblyMass * speed)
	balloon.AssemblyAngularVelocity += Vector3.new(dir.Z, 0, -dir.X) * 3
end

-- I prefer updating forces instead of manually overwriting velocity.
-- That keeps the motion inside Roblox's physics system instead of fighting it.
function BalloonService:UpdateBalloon(balloon, state, now)
	if not balloon.Parent or not balloon:IsDescendantOf(self.BalloonsFolder) then
		self:RemoveBalloon(balloon)
		return
	end

	local mass = balloon.AssemblyMass
	local vel = balloon.AssemblyLinearVelocity

	-- Slightly under gravity so the balloon drifts down instead of either
	-- dropping like a brick or floating forever.
	local liftForce = mass * workspace.Gravity * (1 - 0.06 + 0.03 * math.sin(now * 1.8))

	-- Stronger vertical drag helps the balloon settle after a push without
	-- killing the sideways movement too aggressively.
	local drag = Vector3.new(
		-vel.X * 1.5,
		-vel.Y * 2.5,
		-vel.Z * 1.5
	) * mass

	-- Each balloon gets its own noise seed so they don't all drift in sync.
	-- Synchronized movement tends to look fake very fast.
	local sway = Vector3.new(
		math.noise(now * 0.35, state.SeedX, 0),
		0,
		math.noise(now * 0.35, state.SeedZ, 0)
	) * 5 * mass

	-- Optional shared wind from the workspace.
	-- If the attribute isn't a Vector3, just ignore it instead of risking weird bugs.
	local wind = workspace:GetAttribute("BalloonWind")
	if typeof(wind) == "Vector3" then
		sway += wind * mass
	end

	-- Everything combines into one force so the balloon feels like one object,
	-- not three separate systems fighting each other.
	state.Lift.Force = Vector3.new(0, liftForce, 0) + drag + sway
end

-- Remove tracking first so nothing else tries to use a balloon that is already
-- being cleaned up.
function BalloonService:RemoveBalloon(balloon)
	self.Balloons[balloon] = nil

	local janitor = self.BalloonJanitors[balloon]
	self.BalloonJanitors[balloon] = nil

	if janitor then
		-- Each balloon owns its own listeners, so cleanup stays local.
		janitor:Cleanup()
	end
end

-- Setup only once per balloon.
-- The state table exists so balloon-specific data stays attached to the balloon
-- instead of getting mixed up with every other one.
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

	-- These physical settings are tuned for something lightweight that still
	-- collides in a believable way.
	balloon.Anchored = false
	balloon.CanCollide = true
	balloon.CustomPhysicalProperties = PhysicalProperties.new(0.2, 0.6, 0.6, 1, 1)

	-- Make sure the range exists and is sane before the first interaction.
	getBalloonRange(balloon)

	-- Reuse the attachment if possible, but replace it if someone put the
	-- wrong class under that name.
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

	-- Server ownership keeps the simulation consistent for everyone.
	-- Otherwise one client could end up simulating a different result.
	pcall(function()
		balloon:SetNetworkOwner(nil)
	end)

	-- Let the balloon react to contact without leaving loose connections behind
	-- when it gets removed later.
	janitor:Add(balloon.Touched:Connect(function(hit)
		self:PushBalloon(balloon, hit, state)
	end))

	-- Keep the Range attribute valid even if another script changes it later.
	-- That way the lookup stays safe no matter who touches the value.
	janitor:Add(balloon:GetAttributeChangedSignal("Range"):Connect(function()
		getBalloonRange(balloon)
	end))
end

-- Vertical launch is the simple case.
-- The server still owns the decision so the client can't fake a stronger throw.
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

	-- Clear old motion first so the new throw does not get mixed with whatever
	-- random speed the balloon had from collision handling.
	balloon.AssemblyLinearVelocity = Vector3.zero
	balloon:ApplyImpulse(Vector3.yAxis * balloon.AssemblyMass * power)

	-- A bit of spin makes the launch look less stiff.
	balloon.AssemblyAngularVelocity += Vector3.new(
		math.random(-10, 10),
		math.random(-10, 10),
		math.random(-10, 10)
	)

	if player then
		-- The sound follows the player, because the throw should feel attached
		-- to the action, not to some random object in the folder.
		PlaySound:PlaySoundWithRandomSpeedInPart("Slap", 0.8, 1.2, player.Character.HumanoidRootPart)
	end

	return true
end

-- Knit just routes the client call to the server-side implementation.
-- The real rules stay in LaunchUpward, which keeps the logic in one place.
function BalloonService.Client:LaunchUpward(player)
	return self.Server:LaunchUpward(player)
end

-- Directional launch uses the aim vector from the client, but the server still
-- decides whether the request is valid and what speed level is allowed.
function BalloonService:Launch(player, lookVector, power)
	if not self:CanRequest(player) then
		return false
	end

	if not isValidVector(lookVector) or not isFiniteNumber(power) then
		return false
	end

	-- Power is used as a level, not as a raw speed.
	-- Rounding first avoids weird edge cases like 2.8 indexing the table badly.
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

	-- A zero-length vector cannot be normalized, so use the character's facing
	-- direction instead of failing the request entirely.
	if lookVector.Magnitude < 0.001 then
		lookVector = root.CFrame.LookVector
	end

	local dir = lookVector.Unit

	-- Reset old movement so the configured power is the only thing shaping
	-- the launch.
	balloon.AssemblyLinearVelocity = Vector3.zero
	balloon:ApplyImpulse(dir * balloon.AssemblyMass * speed)
	balloon.AssemblyAngularVelocity += Vector3.new(dir.Z, 0, -dir.X) * 3

	if player then
		PlaySound:PlaySoundWithRandomSpeedInPart("Slap", 0.8, 1.2, player.Character.HumanoidRootPart)
	end
	return true
end

-- Same idea as above: keep the client-facing method thin and let the server
-- implementation do the real work.
function BalloonService.Client:Launch(player, lookVector, power)
	return self.Server:Launch(player, lookVector, power)
end

-- KnitInit is just setup.
-- This is the right place for tables and long-lived service state, not the
-- actual folder wiring.
function BalloonService:KnitInit()
	self.Balloons = {}
	self.BalloonJanitors = {}
	self.LastLaunch = {}
	self.RequestLimit = Ratelimit(8, 1)
	self.Janitor = Janitor.new()

	-- Cleaning cooldown state on leave keeps the table from slowly filling up
	-- with old player references.
	self.Janitor:Add(PLRS.PlayerRemoving:Connect(function(player)
		self.LastLaunch[player] = nil
	end))
end

-- KnitStart is where the service hooks into the actual folder in the world.
-- Existing balloons have to be set up too, otherwise the ones already in the map
-- would be skipped until something reloaded them.
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

	-- One shared Heartbeat is enough.
	-- A separate loop per balloon would be pointless overhead for no real gain.
	self.Janitor:Add(RNS.Heartbeat:Connect(function()
		local now = os.clock()

		for balloon, state in pairs(self.Balloons) do
			self:UpdateBalloon(balloon, state, now)
		end
	end))
end

return BalloonService
