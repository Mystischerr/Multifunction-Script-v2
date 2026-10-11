-- HeadLockAll: Ein einzelnes LocalScript (mit Hotkey-Einstellungen, FPS/Ping-Anzeige)
-- WICHTIG: Platziere dieses Skript in: StarterPlayer > StarterPlayerScripts

if game:GetService("RunService"):IsServer() then 
	return 
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local localPlayer = Players.LocalPlayer

-- Alle globalen Verbindungen werden hier gesammelt, damit "X" sie komplett trennen kann
local connections = {}
local function connect(signal, callback)
	local connection = signal:Connect(callback)
	table.insert(connections, connection)
	return connection
end

-- Altes GUI und RenderSteps bereinigen
do
	local existingGui = localPlayer:WaitForChild("PlayerGui")
	for _, name in ipairs({ "HeadLockOverlay", "HeadLockGui" }) do
		local old = existingGui:FindFirstChild(name)
		while old do
			old:Destroy()
			old = existingGui:FindFirstChild(name)
		end
	end
	pcall(function() RunService:UnbindFromRenderStep("HeadLockEnemyCamera") end)
	pcall(function() RunService:UnbindFromRenderStep("HeadLockEsp") end)
	pcall(function() RunService:UnbindFromRenderStep("HeadLockCursor") end)
	pcall(function() RunService:UnbindFromRenderStep("HeadLockFly") end)
	pcall(function() RunService:UnbindFromRenderStep("HeadLockExtras") end)
end

-- Einstellungen
local TOGGLE_KEY = Enum.KeyCode.T
local MENU_KEY = Enum.KeyCode.RightShift 
local SCRIPT_PAUSE_KEY = Enum.KeyCode.P -- Taste P pausiert die Funktionen
local AIM_BUTTON = Enum.UserInputType.MouseButton2 
local START_ENABLED = true  
local CIRCLE_RADIUS = 150    
local KEEP_ANGLE = 70       
local MAX_DISTANCE = 300     
local ESP_MAX_DISTANCE = 1000 
local SMOOTH_SPEED = 25      
local SWITCH_INTERVAL = 0.4  
local LOCK_BLEND_TIME = 0.12 

local AIM_MODE = "Head" -- Standard: Kopf wird angezielt (im Menü bei "Aim at" änderbar)
local DRIFT_FIX_DISTANCE = 0.75 -- ab dieser Abweichung (Studs) vom Ziel wird schneller nachkorrigiert
local DRIFT_FIX_BOOST = 4       -- Verstärkung der Nachführung bei Abweichung
local CAMERA_MODE = "Keep" 
local BEHIND_DISTANCE = 12  
local BEHIND_HEIGHT = 5     

local KEEP_COS = math.cos(math.rad(KEEP_ANGLE))

-- Zustandsschalter für die Taste P (Pausiert = false)
local scriptFunctionsWorking = true

-- Zustand der Hotkey-Umbelegung (Settings-Tab)
local listeningFor = nil
local bindIgnoreUntil = 0
local function inputBlocked()
	return listeningFor ~= nil or os.clock() < bindIgnoreUntil
end

-- Zustand
local isEnabled = START_ENABLED
local showCircle = true
local showBoxes = true
local showNames = true
local isAiming = false            
local lockedTarget = nil          
local cameraOffset = Vector3.zero 
local lastDirection = Vector3.new(0, 0, -1)
local lockedFov = nil                  
local aimPoint = Vector3.zero          
local lockStartCFrame = CFrame.new()   
local lockTime = 0                     
local smoothedLength = nil             
local viewDirection = Vector3.new(0, 0, -1) 

-- Hitbox-Zustand
local pixelHitboxOn = false
local originalSizes = {}

local function isAlive(character)
	if not character then return false end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0 and character:FindFirstChild("HumanoidRootPart") ~= nil
end

local function getHead(character)
	local head = character and character:FindFirstChild("Head")
	return (head and head:IsA("BasePart")) and head or nil
end

local function getTorso(character)
	local torso = character and (
		character:FindFirstChild("UpperTorso")
		or character:FindFirstChild("Torso")
		or character:FindFirstChild("HumanoidRootPart")
	)
	return (torso and torso:IsA("BasePart")) and torso or nil
end

local function getAimPosition(character)
	local head = getHead(character)
	local torso = getTorso(character)
	local part
	if AIM_MODE == "Head" then
		part = head or torso
	elseif AIM_MODE == "Torso" then
		part = torso or head
	else
		local useTorso = math.floor(os.clock() / SWITCH_INTERVAL) % 2 == 1
		part = (useTorso and torso) or head or torso
	end
	return part and part.Position or Vector3.zero
end

-- Team-Check: schliesst Spieler des eigenen Teams aus Aimbot, ESP, Tracer und Hitbox aus
local teamCheck = true
local function isEnemy(player)
	if not teamCheck then return true end
	local myTeam = localPlayer.Team
	if myTeam == nil then return true end
	return player.Team ~= myTeam
end

local function isValidTarget(player)
	return player ~= localPlayer and isEnemy(player) and isAlive(player.Character) and getHead(player.Character) ~= nil
end

local function distanceTo(player, fromPosition)
	return (player.Character.HumanoidRootPart.Position - fromPosition).Magnitude
end

local function isInCone(origin, position, cosLimit)
	local flat = Vector3.new(position.X - origin.X, 0, position.Z - origin.Z)
	if flat.Magnitude < 0.5 then return true end
	return viewDirection:Dot(flat.Unit) >= cosLimit
end

local function isInCircle(camera, position)
	local point = camera:WorldToViewportPoint(position)
	if point.Z <= 0 then return false end
	local viewport = camera.ViewportSize
	local center = Vector2.new(viewport.X / 2, viewport.Y / 2)
	return (Vector2.new(point.X, point.Y) - center).Magnitude <= CIRCLE_RADIUS
end

local function findClosestEnemy(camera, origin)
	local best = nil
	local bestDistance = MAX_DISTANCE
	for _, player in ipairs(Players:GetPlayers()) do
		if isValidTarget(player) then
			local character = player.Character
			local head = getHead(character)
			local torso = getTorso(character)
			if isInCircle(camera, head.Position) or (torso and isInCircle(camera, torso.Position)) then
				local distance = distanceTo(player, origin)
				if distance < bestDistance then
					best = player
					bestDistance = distance
				end
			end
		end
	end
	return best
end

local function clipToWalls(origin, desired, ignoreList)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignoreList
	params.RespectCanCollide = true

	local result = workspace:Raycast(origin, desired - origin, params)
	return result and (result.Position + result.Normal * 0.3) or desired
end

local function releaseLock()
	lockedTarget = nil
	local fovToRestore = lockedFov
	lockedFov = nil
	local camera = workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Custom
		if fovToRestore then camera.FieldOfView = fovToRestore end
	end
end

local function stopAiming()
	isAiming = false
	releaseLock()
end

local refreshGui = function() end

local function setEnabled(value)
	isEnabled = value
	if not isEnabled then stopAiming() end
	refreshGui()
end

connect(UserInputService.InputBegan, function(input, gameProcessed)
	if not scriptFunctionsWorking then return end -- Blockiert T-Aimbot wenn über P pausiert
	if inputBlocked() then return end
	if input.KeyCode == TOGGLE_KEY then
		if UserInputService:GetFocusedTextBox() then return end
		setEnabled(not isEnabled)
	elseif input.UserInputType == AIM_BUTTON and isEnabled then
		if UserInputService:GetFocusedTextBox() then return end
		isAiming = true
	end
end)

connect(UserInputService.InputEnded, function(input)
	if input.UserInputType == AIM_BUTTON and isAiming then stopAiming() end
end)

connect(UserInputService.WindowFocusReleased, function()
	if isAiming then stopAiming() end
end)

RunService:BindToRenderStep("HeadLockEnemyCamera", Enum.RenderPriority.Camera.Value + 1, function(dt)
	if not scriptFunctionsWorking then return end -- Blockiert Kameraschwenks wenn über P pausiert
	if not isAiming then
		if isEnabled and UserInputService:IsMouseButtonPressed(AIM_BUTTON) and not UserInputService:GetFocusedTextBox() then
			isAiming = true
		else
			return
		end
	end

	local camera = workspace.CurrentCamera
	if not camera or not isEnabled or not UserInputService:IsMouseButtonPressed(AIM_BUTTON) then
		stopAiming()
		return
	end

	local myCharacter = localPlayer.Character
	if not isAlive(myCharacter) then
		stopAiming()
		return
	end
	
	local myPosition = myCharacter.HumanoidRootPart.Position
	local origin = (getHead(myCharacter) or myCharacter.HumanoidRootPart).Position
	local target

	if lockedTarget then
		if not isValidTarget(lockedTarget) or distanceTo(lockedTarget, origin) > MAX_DISTANCE or not isInCone(origin, getHead(lockedTarget.Character).Position, KEEP_COS) then
			stopAiming()
			return
		end
		target = lockedTarget
	else
		local look = camera.CFrame.LookVector
		local flatLook = Vector3.new(look.X, 0, look.Z)
		if flatLook.Magnitude > 0.1 then viewDirection = flatLook.Unit end

		target = findClosestEnemy(camera, origin)
		if not target then return end

		cameraOffset = camera.CFrame.Position - myPosition
		lockStartCFrame = camera.CFrame
		lockTime = 0
		smoothedLength = nil
		lastDirection = viewDirection
		aimPoint = getAimPosition(target.Character)
		lockedFov = camera.FieldOfView
		camera.CameraType = Enum.CameraType.Scriptable
		lockedTarget = target
	end

	local targetCharacter = target.Character
	local goalPoint = getAimPosition(targetCharacter)
	local alpha = SMOOTH_SPEED > 0 and (1 - math.exp(-SMOOTH_SPEED * dt)) or 1
	-- Selbstkorrektur: schweift der Zielpunkt vom Kopf ab, wird stärker nachgeführt
	local drift = (goalPoint - aimPoint).Magnitude
	if drift > DRIFT_FIX_DISTANCE then
		local boost = math.clamp(drift / DRIFT_FIX_DISTANCE, 1, DRIFT_FIX_BOOST)
		alpha = 1 - math.exp(-SMOOTH_SPEED * boost * dt)
	end
	aimPoint = aimPoint:Lerp(goalPoint, alpha)

	local cameraPosition
	if CAMERA_MODE == "Behind" then
		local flat = Vector3.new(aimPoint.X - myPosition.X, 0, aimPoint.Z - myPosition.Z)
		if flat.Magnitude > 2 then lastDirection = flat.Unit end

		local anchor = myPosition + Vector3.new(0, 2, 0)
		local offset = -lastDirection * BEHIND_DISTANCE + Vector3.new(0, BEHIND_HEIGHT - 2, 0)
		local fullLength = offset.Magnitude
		local direction = offset / fullLength

		local clipped = clipToWalls(anchor, anchor + offset, { myCharacter, targetCharacter })
		local allowedLength = (clipped - anchor).Magnitude
		if smoothedLength == nil or allowedLength < smoothedLength then
			smoothedLength = allowedLength
		else
			smoothedLength = smoothedLength + (allowedLength - smoothedLength) * alpha
		end
		cameraPosition = anchor + direction * smoothedLength
	else
		cameraPosition = myPosition + cameraOffset
	end

	local toAim = aimPoint - cameraPosition
	if toAim.Magnitude < 0.5 then return end

	local upVector = math.abs(toAim.Unit.Y) > 0.98 and Vector3.zAxis or Vector3.yAxis
	local targetCFrame = CFrame.lookAt(cameraPosition, aimPoint, upVector)

	camera.FieldOfView = lockedFov or camera.FieldOfView 
	lockTime += dt
	if lockTime < LOCK_BLEND_TIME then
		local t = lockTime / LOCK_BLEND_TIME
		t = t * t * (3 - 2 * t)
		camera.CFrame = lockStartCFrame:Lerp(targetCFrame, t)
	else
		camera.CFrame = targetCFrame
	end
	camera.Focus = CFrame.new(aimPoint)
end)

-- Overlay (Zielkreis, Boxen und Namen)
local playerGui = localPlayer:WaitForChild("PlayerGui")
local overlay = Instance.new("ScreenGui")
overlay.Name = "HeadLockOverlay"
overlay.ResetOnSpawn = false
overlay.IgnoreGuiInset = true
overlay.DisplayOrder = 50
overlay.Parent = playerGui
local circleFrame = Instance.new("Frame")
circleFrame.Name = "AimCircle"
circleFrame.AnchorPoint = Vector2.new(0.5, 0.5)
circleFrame.Position = UDim2.fromScale(0.5, 0.5)
circleFrame.Size = UDim2.fromOffset(CIRCLE_RADIUS * 2, CIRCLE_RADIUS * 2)
circleFrame.BackgroundTransparency = 1
circleFrame.BorderSizePixel = 0
circleFrame.Parent = overlay
do
local circleCorner = Instance.new("UICorner")
circleCorner.CornerRadius = UDim.new(0.5, 0)
circleCorner.Parent = circleFrame
local circleStroke = Instance.new("UIStroke")
circleStroke.Thickness = 2
circleStroke.Color = Color3.fromRGB(255, 255, 255)
circleStroke.Transparency = 0.25
circleStroke.Parent = circleFrame
end
-- FPS- und Ping-Anzeige (oben rechts)
local showStats = true
local statsLabel = Instance.new("TextLabel")
statsLabel.Name = "StatsLabel"
statsLabel.AnchorPoint = Vector2.new(1, 0)
statsLabel.Position = UDim2.new(1, -12, 0, 8)
statsLabel.Size = UDim2.fromOffset(190, 26)
statsLabel.BackgroundColor3 = Color3.fromRGB(20, 20, 26)
statsLabel.BackgroundTransparency = 0.3
statsLabel.BorderSizePixel = 0
statsLabel.Font = Enum.Font.GothamBold
statsLabel.TextSize = 14
statsLabel.TextColor3 = Color3.fromRGB(240, 240, 245)
statsLabel.Text = "FPS --  |  Ping -- ms"
statsLabel.Parent = overlay
do
local statsCorner = Instance.new("UICorner")
statsCorner.CornerRadius = UDim.new(0, 6)
statsCorner.Parent = statsLabel
local statsFrames, statsTime = 0, 0
connect(RunService.Heartbeat, function(dt)
	statsFrames += 1
	statsTime += dt
	if statsTime >= 0.5 then
		local fps = math.floor(statsFrames / statsTime + 0.5)
		local ok, ping = pcall(function() return localPlayer:GetNetworkPing() * 1000 end)
		statsLabel.Text = string.format("FPS %d  |  Ping %d ms", fps, ok and math.floor(ping + 0.5) or 0)
		statsFrames, statsTime = 0, 0
	end
end)
end
-- Anti-AFK: verhindert den Leerlauf-Kick (Idled-Event, Standardmethode)
local VirtualUser = game:GetService("VirtualUser")
local antiAfk = true
connect(localPlayer.Idled, function()
	if not antiAfk then return end
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end)
-- Fullbright: macht die Map lokal hell, stellt beim Ausschalten alles wieder her
local Lighting = game:GetService("Lighting")
local fullbrightWanted = false
local lightingBackup = nil
local function restoreLighting()
	if not lightingBackup then return end
	for property, value in pairs(lightingBackup) do
		pcall(function() Lighting[property] = value end)
	end
	lightingBackup = nil
end
connect(RunService.Heartbeat, function()
	if fullbrightWanted and scriptFunctionsWorking then
		if not lightingBackup then
			lightingBackup = {
				Brightness = Lighting.Brightness,
				ClockTime = Lighting.ClockTime,
				FogEnd = Lighting.FogEnd,
				GlobalShadows = Lighting.GlobalShadows,
				Ambient = Lighting.Ambient,
				OutdoorAmbient = Lighting.OutdoorAmbient,
			}
		end
		Lighting.Brightness = 2
		Lighting.ClockTime = 14
		Lighting.FogEnd = 1e6
		Lighting.GlobalShadows = false
		Lighting.Ambient = Color3.fromRGB(178, 178, 178)
		Lighting.OutdoorAmbient = Color3.fromRGB(178, 178, 178)
	else
		restoreLighting()
	end
end)
local ESP_COLOR = Color3.fromRGB(255, 60, 60)
local LOCKED_COLOR = Color3.fromRGB(255, 220, 40)
local espObjects = {}
local CORNER_SIGNS = {}
for x = -1, 1, 2 do
for y = -1, 1, 2 do
for z = -1, 1, 2 do
table.insert(CORNER_SIGNS, Vector3.new(x, y, z))
end
end
end
local function createEsp(player)
local box = Instance.new("Frame")
box.Name = "Esp_" .. player.Name
box.BackgroundTransparency = 1
box.BorderSizePixel = 0
box.Visible = false
box.Parent = overlay
local stroke = Instance.new("UIStroke")
stroke.Thickness = 2
stroke.Color = ESP_COLOR
stroke.Parent = box
local label = Instance.new("TextLabel")
label.BackgroundTransparency = 1
label.AnchorPoint = Vector2.new(0.5, 1)
label.Position = UDim2.new(0.5, 0, 0, -2)
label.Size = UDim2.fromOffset(120, 16)
label.Font = Enum.Font.GothamBold
label.TextSize = 14
label.TextColor3 = Color3.fromRGB(255, 255, 255)
label.TextStrokeTransparency = 0.3
label.Text = ""
label.Parent = box
espObjects[player] = { box = box, stroke = stroke, label = label }
return espObjects[player]
end
local function updateEsp()
local camera = workspace.CurrentCamera
if not camera or not scriptFunctionsWorking then
-- Blendet ESP-Boxen sofort aus, wenn über P pausiert wurde
for _, obj in pairs(espObjects) do obj.box.Visible = false end
return
end
local active = showBoxes or showNames
local myCharacter = localPlayer.Character
local myRoot = myCharacter and myCharacter:FindFirstChild("HumanoidRootPart")
for _, player in ipairs(Players:GetPlayers()) do
if player ~= localPlayer then
local object = espObjects[player]
local visible = false
if active and isValidTarget(player) then
local character = player.Character
local root = character.HumanoidRootPart
local distance = myRoot and (root.Position - myRoot.Position).Magnitude or 0
if distance <= ESP_MAX_DISTANCE then
local boxCFrame, boxSize = character:GetBoundingBox()
local minX, minY = math.huge, math.huge
local maxX, maxY = -math.huge, -math.huge
local allInFront = true
for _, sign in ipairs(CORNER_SIGNS) do
local point = camera:WorldToViewportPoint(boxCFrame:PointToWorldSpace(sign * boxSize / 2))
if point.Z <= 0 then
allInFront = false
break
end
minX = math.min(minX, point.X)
minY = math.min(minY, point.Y)
maxX = math.max(maxX, point.X)
maxY = math.max(maxY, point.Y)
end
if allInFront then
visible = true
if not object then object = createEsp(player) end
object.box.Position = UDim2.fromOffset(minX, minY)
object.box.Size = UDim2.fromOffset(maxX - minX, maxY - minY)
object.stroke.Enabled = showBoxes
object.stroke.Color = (lockedTarget == player) and LOCKED_COLOR or ESP_COLOR
object.label.Visible = showNames
object.label.Text = player.DisplayName
end
end
end
if object then object.box.Visible = visible end
end
end
end
connect(Players.PlayerRemoving, function(player)
local object = espObjects[player]
if object then
object.box:Destroy()
espObjects[player] = nil
end
end)
RunService:BindToRenderStep("HeadLockEsp", Enum.RenderPriority.Camera.Value + 2, updateEsp)
-- GUI Steuerungspanel (STABILES RECHTECKIGES TAB-LAYOUT)
local COLOR_BG = Color3.fromRGB(20, 20, 26)
local COLOR_SIDEBAR = Color3.fromRGB(28, 28, 36)
local COLOR_ITEM = Color3.fromRGB(42, 42, 52)
local COLOR_BUTTON = Color3.fromRGB(66, 66, 80)
local COLOR_ACCENT = Color3.fromRGB(70, 120, 200)
local COLOR_TEXT = Color3.fromRGB(240, 240, 245)
local COLOR_SUBTEXT = Color3.fromRGB(150, 150, 165)
local ON_COLOR = Color3.fromRGB(40, 160, 80)
local OFF_COLOR = Color3.fromRGB(170, 50, 50)
local WINDOW_W, WINDOW_H = 620, 460
local TITLE_H = 40
local function addCorner(instance, radius)
local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, radius or 8)
corner.Parent = instance
return corner
end
local function newLabel(parent, text, size, position, textSize, bold)
local label = Instance.new("TextLabel")
label.BackgroundTransparency = 1
label.Position = position
label.Size = size
label.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
label.Text = text
label.TextColor3 = COLOR_TEXT
label.TextSize = textSize or 14
label.TextXAlignment = Enum.TextXAlignment.Left
label.Parent = parent
return label
end
local function newButton(parent, text, position, size, color, textSize)
local button = Instance.new("TextButton")
button.Position = position
button.Size = size
button.AutoButtonColor = true
button.BackgroundColor3 = color or COLOR_BUTTON
button.BorderSizePixel = 0
button.Font = Enum.Font.GothamBold
button.Text = text
button.TextColor3 = Color3.fromRGB(255, 255, 255)
button.TextSize = textSize or 14
button.Parent = parent
addCorner(button, 8)
return button
end
local gui = Instance.new("ScreenGui")
gui.Name = "HeadLockGui"
gui.ResetOnSpawn = false
gui.DisplayOrder = 100
gui.Parent = playerGui
local window = Instance.new("Frame")
window.Name = "Panel"
window.Size = UDim2.fromOffset(WINDOW_W, WINDOW_H)
window.Position = UDim2.new(0.5, -WINDOW_W / 2, 0.5, -WINDOW_H / 2)
window.BackgroundColor3 = COLOR_BG
window.Active = true
window.Parent = gui
addCorner(window, 12)
do
	local windowStroke = Instance.new("UIStroke")
	windowStroke.Color = Color3.fromRGB(60, 60, 78)
	windowStroke.Thickness = 1
	windowStroke.Parent = window
end
local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, TITLE_H)
titleBar.BackgroundColor3 = COLOR_SIDEBAR
titleBar.Active = true
titleBar.Parent = window
addCorner(titleBar, 12)
local titleLabel = newLabel(titleBar, "  Head Lock", UDim2.new(1, -110, 1, 0), UDim2.fromOffset(8, 0), 17, true)
local minimizeButton = newButton(titleBar, "-", UDim2.new(1, -84, 0, 8), UDim2.fromOffset(34, 24), COLOR_BUTTON, 16)
local closeButton = newButton(titleBar, "X", UDim2.new(1, -44, 0, 8), UDim2.fromOffset(34, 24), OFF_COLOR, 14)
local sidebar = Instance.new("Frame")
sidebar.Position = UDim2.fromOffset(0, TITLE_H)
sidebar.Size = UDim2.fromOffset(140, WINDOW_H - TITLE_H)
sidebar.BackgroundColor3 = COLOR_SIDEBAR
sidebar.Parent = window
local content = Instance.new("Frame")
content.Position = UDim2.fromOffset(152, TITLE_H + 12)
content.Size = UDim2.fromOffset(WINDOW_W - 152 - 12, WINDOW_H - TITLE_H - 12 - 52)
content.BackgroundTransparency = 1
content.Parent = window
local statusBar = Instance.new("Frame")
statusBar.Position = UDim2.fromOffset(152, WINDOW_H - 44)
statusBar.Size = UDim2.fromOffset(WINDOW_W - 152 - 12, 34)
statusBar.BackgroundColor3 = COLOR_ITEM
statusBar.Parent = window
addCorner(statusBar, 8)
local statusLabel = newLabel(statusBar, MENU_KEY.Name .. " = free mouse", UDim2.new(1, -20, 1, 0), UDim2.fromOffset(10, 0), 13, false)
statusLabel.TextColor3 = COLOR_SUBTEXT
local function setStatus(text)
statusLabel.Text = tostring(text)
statusLabel.TextColor3 = COLOR_TEXT
end
local pages = {}
local tabButtons = {}
local tabBars = {}
local refreshers = {}
local searchEntries = {}
local currentPage = "Combat"
local PAGE_TOP = 38

-- Suchfeld: findet Funktionen ueber alle Tabs hinweg
local searchBox = Instance.new("TextBox")
searchBox.Name = "Search"
searchBox.Position = UDim2.fromOffset(0, 0)
searchBox.Size = UDim2.new(1, -10, 0, 30)
searchBox.BackgroundColor3 = COLOR_ITEM
searchBox.BorderSizePixel = 0
searchBox.Font = Enum.Font.Gotham
searchBox.PlaceholderText = "Search functions..."
searchBox.PlaceholderColor3 = COLOR_SUBTEXT
searchBox.Text = ""
searchBox.TextColor3 = COLOR_TEXT
searchBox.TextSize = 14
searchBox.TextXAlignment = Enum.TextXAlignment.Left
searchBox.ClearTextOnFocus = false
searchBox.Parent = content
addCorner(searchBox, 8)
do
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 10)
	padding.Parent = searchBox
end
local function createPage(name, hidden)
	local page = Instance.new("ScrollingFrame")
	page.Name = name
	page.BackgroundTransparency = 1
	page.BorderSizePixel = 0
	page.Position = UDim2.fromOffset(0, PAGE_TOP)
	page.Size = UDim2.new(1, 0, 1, -PAGE_TOP)
	page.ScrollBarThickness = 5
	page.CanvasSize = UDim2.new()
	page.AutomaticCanvasSize = Enum.AutomaticSize.Y
	page.Visible = false
	page.Parent = content
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = page
	if not hidden then pages[name] = page end
	return page
end
local searchPage = createPage("Search", true)
local noResultsLabel = newLabel(searchPage, "No matching functions.", UDim2.new(1, -10, 0, 40), UDim2.new(), 15, false)
noResultsLabel.TextColor3 = COLOR_SUBTEXT
noResultsLabel.Visible = false
local function restoreRows()
	for _, entry in ipairs(searchEntries) do entry.row.Parent = entry.page end
end
local function applySearch()
	local query = string.match(string.lower(searchBox.Text), "^%s*(.-)%s*$")
	if query == "" then
		restoreRows()
		searchPage.Visible = false
		for pageName, page in pairs(pages) do page.Visible = (pageName == currentPage) end
		return
	end
	local matches = 0
	for _, entry in ipairs(searchEntries) do
		local haystack = string.lower(entry.getText() .. " " .. entry.page.Name)
		if string.find(haystack, query, 1, true) then
			entry.row.Parent = searchPage
			matches += 1
		else
			entry.row.Parent = entry.page
		end
	end
	for _, page in pairs(pages) do page.Visible = false end
	searchPage.Visible = true
	noResultsLabel.Visible = (matches == 0)
end
searchBox:GetPropertyChangedSignal("Text"):Connect(applySearch)
local function showPage(name)
	currentPage = name
	if searchBox.Text ~= "" then searchBox.Text = "" end
	restoreRows()
	searchPage.Visible = false
	for pageName, page in pairs(pages) do page.Visible = (pageName == name) end
	for tabName, button in pairs(tabButtons) do
		local active = (tabName == name)
		button.BackgroundColor3 = active and COLOR_ACCENT or COLOR_BUTTON
		tabBars[tabName].Visible = active
	end
end
local function createTab(name, order)
	local button = newButton(sidebar, name, UDim2.fromOffset(10, 12 + (order - 1) * 48), UDim2.fromOffset(120, 40), COLOR_BUTTON, 15)
	local bar = Instance.new("Frame")
	bar.Size = UDim2.new(0, 4, 1, -12)
	bar.Position = UDim2.fromOffset(5, 6)
	bar.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	bar.BorderSizePixel = 0
	bar.Visible = false
	bar.Parent = button
	addCorner(bar, 2)
	tabBars[name] = bar
	tabButtons[name] = button
	button.Activated:Connect(function() showPage(name) end)
	return button
end
-- TABS
local combatPage = createPage("Combat")
local visualsPage = createPage("Visuals")
local movePage = createPage("Movement")
local miscPage = createPage("Misc")
local playersPage = createPage("Players")
local settingsPage = createPage("Settings")
createTab("Combat", 1)
createTab("Visuals", 2)
createTab("Movement", 3)
createTab("Misc", 4)
createTab("Players", 5)
createTab("Settings", 6)
local rowCounter = 0
local function createRow(page, text)
	rowCounter += 1
	local row = Instance.new("Frame")
	row.LayoutOrder = rowCounter
	row.Size = UDim2.new(1, -10, 0, 48)
	row.BackgroundColor3 = COLOR_ITEM
	row.Parent = page
	addCorner(row, 8)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(58, 58, 74)
	stroke.Thickness = 1
	stroke.Parent = row
	local isDynamic = type(text) == "function"
	local rowLabel = newLabel(row, isDynamic and text() or text, UDim2.new(1, -190, 1, 0), UDim2.fromOffset(14, 0), 15, false)
	if isDynamic then
		table.insert(refreshers, function() rowLabel.Text = text() end)
	end
	table.insert(searchEntries, { row = row, page = page, getText = function() return rowLabel.Text end })
	return row
end
local function addToggleRow(page, text, getValue, setValue)
local row = createRow(page, text)
local button = newButton(row, "", UDim2.new(1, -124, 0.5, -16), UDim2.fromOffset(112, 32), OFF_COLOR, 14)
local function refresh()
local on = getValue()
button.Text = on and "ON" or "OFF"
button.BackgroundColor3 = on and ON_COLOR or OFF_COLOR
end
button.Activated:Connect(function() setValue(not getValue()) refresh() end)
table.insert(refreshers, refresh)
refresh()
end
local function addCycleRow(page, text, getText, onClick)
local row = createRow(page, text)
local button = newButton(row, "", UDim2.new(1, -164, 0.5, -16), UDim2.fromOffset(152, 32), COLOR_BUTTON, 14)
local function refresh() button.Text = getText() end
button.Activated:Connect(function() onClick() refresh() end)
table.insert(refreshers, refresh)
refresh()
end
local function addStepperRow(page, text, getText, onChange)
local row = createRow(page, text)
local valueLabel = newLabel(row, "", UDim2.fromOffset(80, 48), UDim2.new(1, -182, 0, 0), 15, true)
valueLabel.TextXAlignment = Enum.TextXAlignment.Center
local minus = newButton(row, "-", UDim2.new(1, -96, 0.5, -16), UDim2.fromOffset(40, 32), COLOR_BUTTON, 18)
local plus = newButton(row, "+", UDim2.new(1, -50, 0.5, -16), UDim2.fromOffset(40, 32), COLOR_BUTTON, 18)
local function refresh() valueLabel.Text = getText() end
minus.Activated:Connect(function() onChange(-1) refresh() end)
plus.Activated:Connect(function() onChange(1) refresh() end)
table.insert(refreshers, refresh)
refresh()
end
local function addActionRow(page, text, buttonText, onClick)
local row = createRow(page, text)
local button = newButton(row, buttonText, UDim2.new(1, -164, 0.5, -16), UDim2.fromOffset(152, 32), COLOR_ACCENT, 14)
button.Activated:Connect(onClick)
end
refreshGui = function()
for _, refresh in ipairs(refreshers) do refresh() end
circleFrame.Visible = scriptFunctionsWorking and showCircle or false
statsLabel.Visible = showStats
circleFrame.Size = UDim2.fromOffset(CIRCLE_RADIUS * 2, CIRCLE_RADIUS * 2)
end
-- Fly-System (Fliegen)
local FLY_KEY = Enum.KeyCode.G
local FLY_SPEED = 60
local flying = false
local flyVelocity, flyGyro
local function stopFly()
flying = false
pcall(function() RunService:UnbindFromRenderStep("HeadLockFly") end)
if flyVelocity then flyVelocity:Destroy() flyVelocity = nil end
if flyGyro then flyGyro:Destroy() flyGyro = nil end
local character = localPlayer.Character
local humanoid = character and character:FindFirstChildOfClass("Humanoid")
if humanoid then humanoid.PlatformStand = false end
refreshGui()
end
local function startFly()
if not scriptFunctionsWorking then return end -- Fliegen blockieren wenn über P pausiert
local character = localPlayer.Character
local root = character and character:FindFirstChild("HumanoidRootPart")
local humanoid = character and character:FindFirstChildOfClass("Humanoid")
if not (root and humanoid) then return end
flying = true
humanoid.PlatformStand = true
flyVelocity = Instance.new("BodyVelocity")
flyVelocity.MaxForce = Vector3.one * 1e6
flyVelocity.Velocity = Vector3.zero
flyVelocity.Parent = root
flyGyro = Instance.new("BodyGyro")
flyGyro.MaxTorque = Vector3.one * 1e6
flyGyro.P = 1e4
flyGyro.CFrame = root.CFrame
flyGyro.Parent = root
RunService:BindToRenderStep("HeadLockFly", Enum.RenderPriority.Camera.Value + 4, function()
local camera = workspace.CurrentCamera
if not camera or not root.Parent or humanoid.Health <= 0 or not scriptFunctionsWorking then stopFly() return end
local direction = Vector3.zero
if not UserInputService:GetFocusedTextBox() then
local cf = camera.CFrame
if UserInputService:IsKeyDown(Enum.KeyCode.W) then direction += cf.LookVector end
if UserInputService:IsKeyDown(Enum.KeyCode.S) then direction -= cf.LookVector end
if UserInputService:IsKeyDown(Enum.KeyCode.D) then direction += cf.RightVector end
if UserInputService:IsKeyDown(Enum.KeyCode.A) then direction -= cf.RightVector end
if UserInputService:IsKeyDown(Enum.KeyCode.Space) then direction += Vector3.yAxis end
if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then direction -= Vector3.yAxis end
end
flyVelocity.Velocity = direction.Magnitude > 0 and direction.Unit * FLY_SPEED or Vector3.zero
flyGyro.CFrame = CFrame.new(root.Position, root.Position + camera.CFrame.LookVector)
end)
refreshGui()
end
connect(UserInputService.InputBegan, function(input)
if not scriptFunctionsWorking then return end
if inputBlocked() then return end
if input.KeyCode == FLY_KEY and not UserInputService:GetFocusedTextBox() then
if flying then stopFly() else startFly() end
end
end)
connect(localPlayer.CharacterAdded, function() stopFly() end)
-- Interaktive Pixel-Hitbox
local function setPixelHitboxLocal(enabled)
pixelHitboxOn = enabled
local character = localPlayer.Character
if not character then return end
if enabled and scriptFunctionsWorking then
for _, part in ipairs(character:GetChildren()) do
if part:IsA("BasePart") then
if not originalSizes[part.Name] then originalSizes[part.Name] = part.Size end
pcall(function()
if part.Name == "HumanoidRootPart" then
part.Size = Vector3.new(0.01, 2, 0.01)
else
part.Size = Vector3.new(0.001, 0.001, 0.001)
end
end)
end
end
setStatus("Pixel Hitbox ON.")
else
for _, part in ipairs(character:GetChildren()) do
if part:IsA("BasePart") and originalSizes[part.Name] then
pcall(function() part.Size = originalSizes[part.Name] end)
end
end
table.clear(originalSizes)
setStatus("Hitbox restored.")
end
end
connect(localPlayer.CharacterAdded, function()
if pixelHitboxOn then task.wait(0.4) setPixelHitboxLocal(true) end
end)
-- Teleport-Funktion
local function teleportToPlayer(player)
if not scriptFunctionsWorking then return end -- Teleport blockieren wenn über P pausiert
local myCharacter = localPlayer.Character
local myRoot = myCharacter and myCharacter:FindFirstChild("HumanoidRootPart")
local targetCharacter = player.Character
local targetRoot = targetCharacter and (targetCharacter:FindFirstChild("HumanoidRootPart") or targetCharacter.PrimaryPart)
if not myRoot or not targetRoot then
setStatus("Teleport failed.")
return
end
local destination = targetRoot.CFrame * CFrame.new(0, 0.5, 4)
pcall(function()
myRoot.AssemblyLinearVelocity = Vector3.zero
myCharacter:PivotTo(destination)
end)
setStatus("Teleported to " .. player.DisplayName)
end
-- ============================================================
-- ERWEITERUNGEN: FOV, Hitbox-Regler, Crosshair, Speed, Jump, Tracer,
-- Config Save/Load, Noclip, Keybind-HUD, Auto-Clicker
-- ============================================================
local scriptAlive = true
local uiState = { menuOpen = false }

local NOCLIP_KEY = Enum.KeyCode.N
local CLICKER_KEY = Enum.KeyCode.K
local BURST_KEY = Enum.KeyCode.B

-- Slider-Zeile (ziehbar mit Maus/Touch)
local function addSliderRow(page, text, minValue, maxValue, step, getValue, setValue)
	local row = createRow(page, text)
	local valueLabel = newLabel(row, "", UDim2.fromOffset(44, 48), UDim2.new(1, -52, 0, 0), 14, true)
	valueLabel.TextXAlignment = Enum.TextXAlignment.Center
	local hit = Instance.new("TextButton")
	hit.Text = ""
	hit.AutoButtonColor = false
	hit.BackgroundTransparency = 1
	hit.Size = UDim2.fromOffset(116, 28)
	hit.Position = UDim2.new(1, -176, 0.5, -14)
	hit.Parent = row
	local track = Instance.new("Frame")
	track.Size = UDim2.new(1, 0, 0, 6)
	track.Position = UDim2.new(0, 0, 0.5, -3)
	track.BackgroundColor3 = COLOR_BUTTON
	track.BorderSizePixel = 0
	track.Parent = hit
	addCorner(track, 3)
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = COLOR_ACCENT
	fill.BorderSizePixel = 0
	fill.Parent = track
	addCorner(fill, 3)
	local function refresh()
		local value = getValue()
		local rel = (maxValue > minValue) and math.clamp((value - minValue) / (maxValue - minValue), 0, 1) or 0
		fill.Size = UDim2.fromScale(rel, 1)
		valueLabel.Text = tostring(value)
	end
	local function setFromX(x)
		local width = hit.AbsoluteSize.X
		if width <= 0 then return end
		local rel = math.clamp((x - hit.AbsolutePosition.X) / width, 0, 1)
		local value = minValue + rel * (maxValue - minValue)
		value = math.floor(value / step + 0.5) * step
		value = math.clamp(value, minValue, maxValue)
		value = tonumber(string.format("%.3f", value)) or value
		setValue(value)
		refresh()
	end
	local sliding = false
	hit.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			sliding = true
			setFromX(input.Position.X)
		end
	end)
	connect(UserInputService.InputChanged, function(input)
		if sliding and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			setFromX(input.Position.X)
		end
	end)
	connect(UserInputService.InputEnded, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			sliding = false
		end
	end)
	table.insert(refreshers, refresh)
	refresh()
end

-- 1) FOV-Anpassung
local fovEnabled = false
local customFov = 90
local defaultFov = nil

-- 3) Hitbox-Groessen-Regler (HumanoidRootPart der Ziele)
local hitboxResize = false
local hitboxScale = 6
local restoreAllHitboxes, updateHitboxes
do
local hitboxBackup = {}
local function restoreHitbox(part)
	local data = hitboxBackup[part]
	if not data then return end
	hitboxBackup[part] = nil
	if part.Parent then
		pcall(function()
			part.Size = data.Size
			part.Transparency = data.Transparency
			part.Material = data.Material
			part.CanCollide = data.CanCollide
		end)
	end
end
function restoreAllHitboxes()
	for part in pairs(hitboxBackup) do restoreHitbox(part) end
end
function updateHitboxes()
	local active = {}
	if hitboxResize and scriptFunctionsWorking then
		for _, player in ipairs(Players:GetPlayers()) do
			if isValidTarget(player) then
				local root = player.Character:FindFirstChild("HumanoidRootPart")
				if root and root:IsA("BasePart") then
					active[root] = true
					if not hitboxBackup[root] then
						hitboxBackup[root] = {
							Size = root.Size,
							Transparency = root.Transparency,
							Material = root.Material,
							CanCollide = root.CanCollide,
						}
					end
					pcall(function()
						root.Size = Vector3.new(hitboxScale, hitboxScale, hitboxScale)
						root.Transparency = 0.7
						root.Material = Enum.Material.Neon
						root.CanCollide = false
					end)
				end
			end
		end
	end
	for part in pairs(hitboxBackup) do
		if not active[part] then restoreHitbox(part) end
	end
end
end

-- 5) + 6) WalkSpeed und JumpPower
local speedOn, speedValue = false, 50
local jumpOn, jumpValue = false, 100
local updateHumanoidMods
do
local speedBackup, jumpBackup = nil, nil
function updateHumanoidMods()
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		speedBackup = nil
		jumpBackup = nil
		return
	end
	if speedOn and scriptFunctionsWorking then
		if not speedBackup or speedBackup.humanoid ~= humanoid then
			speedBackup = { humanoid = humanoid, value = humanoid.WalkSpeed }
		end
		humanoid.WalkSpeed = speedValue
	elseif speedBackup then
		if speedBackup.humanoid == humanoid then humanoid.WalkSpeed = speedBackup.value end
		speedBackup = nil
	end
	if jumpOn and scriptFunctionsWorking then
		if not jumpBackup or jumpBackup.humanoid ~= humanoid then
			jumpBackup = {
				humanoid = humanoid,
				power = humanoid.JumpPower,
				height = humanoid.JumpHeight,
				usePower = humanoid.UseJumpPower,
			}
		end
		if humanoid.UseJumpPower then
			humanoid.JumpPower = jumpValue
		else
			humanoid.JumpHeight = (jumpValue * jumpValue) / (2 * workspace.Gravity)
		end
	elseif jumpBackup then
		if jumpBackup.humanoid == humanoid then
			humanoid.UseJumpPower = jumpBackup.usePower
			humanoid.JumpPower = jumpBackup.power
			humanoid.JumpHeight = jumpBackup.height
		end
		jumpBackup = nil
	end
end
end

-- 9) Noclip (Stepped)
local noclipOn = false
local restoreNoclip
do
local noclipBackup = {}
function restoreNoclip()
	for part in pairs(noclipBackup) do
		noclipBackup[part] = nil
		if part.Parent then pcall(function() part.CanCollide = true end) end
	end
end
connect(RunService.Stepped, function()
	if noclipOn and scriptFunctionsWorking then
		local character = localPlayer.Character
		if character then
			for _, part in ipairs(character:GetDescendants()) do
				if part:IsA("BasePart") and part.CanCollide then
					noclipBackup[part] = true
					part.CanCollide = false
				end
			end
		end
	elseif next(noclipBackup) then
		restoreNoclip()
	end
end)end
local function setNoclip(value)
	noclipOn = value
	if not value then restoreNoclip() end
	setStatus("Noclip " .. (value and "ON" or "OFF"))
	refreshGui()
end

-- 11) Auto-Clicker (bis 500 Klicks/Sekunde, mehrere Klicks pro Frame)
local autoClickOn = false
local clicksPerSecond = 500
local clickBurst = 10 -- maximale Klicks pro Frame (hoeher = schneller, aber mehr Last)
local burstCount = 100 -- Anzahl Klicks pro Tastendruck (Burst)
local queueClickBurst
local clickMode = "Mouse1" -- "Mouse1" = echter Mausklick (mouse1click / VirtualInputManager), "Virtual" = VirtualUser, "Tool" = Tool:Activate()
local updateAutoClicker
local function setAutoClick(value)
	autoClickOn = value
	setStatus("Auto-Clicker " .. (value and "ON" or "OFF"))
	refreshGui()
end
do
	local owed = 0
	local captured = false
	local LOW_FPS_DT = 0.1 -- unter ca. 10 FPS wird stark gedrosselt (Schutz vor Absturz)
	local LOW_FPS_MAX_CLICKS = 2
	local sentCount, statTime, frameCount = 0, 0, 0
	local mouse1Warned = false
	local nativeClick = (type(mouse1click) == "function") and mouse1click or nil
	local inputManager = nil
	do
		local ok, service = pcall(function() return game:GetService("VirtualInputManager") end)
		if ok then inputManager = service end
	end
	-- Waehlt einmal pro Frame die passende Klick-Funktion (nicht pro Klick)
	local function getClicker()
		if clickMode == "Mouse1" then
			if nativeClick then return nativeClick end
			if inputManager then
				local position = UserInputService:GetMouseLocation()
				local x, y = position.X, position.Y
				return function()
					inputManager:SendMouseButtonEvent(x, y, 0, true, game, 0)
					inputManager:SendMouseButtonEvent(x, y, 0, false, game, 0)
				end
			end
			if not mouse1Warned then
				mouse1Warned = true
				setStatus("Mouse1 click not available here - using Virtual click.")
			end
		elseif clickMode == "Tool" then
			local character = localPlayer.Character
			local tool = character and character:FindFirstChildOfClass("Tool")
			if tool then
				return function() tool:Activate() end
			end
		end
		local camera = workspace.CurrentCamera
		local position = camera and (camera.ViewportSize / 2) or Vector2.new(0, 0)
		local cf = camera and camera.CFrame or CFrame.new()
		return function()
			VirtualUser:Button1Down(position, cf)
			VirtualUser:Button1Up(position, cf)
		end
	end
	local function runBatch(click, count)
		for _ = 1, count do click() end
	end
	local pending = 0
	function queueClickBurst(amount)
		if not scriptFunctionsWorking then return end
		if uiState.menuOpen then
			setStatus("Close the menu first - burst clicks are skipped while it is open.")
			return
		end
		pending = math.min(pending + amount, 2000)
		setStatus("Burst: " .. tostring(amount) .. " clicks queued")
	end
	function updateAutoClicker(dt)
		if not scriptFunctionsWorking or uiState.menuOpen then
			owed = 0
			pending = 0
			return
		end
		if (not autoClickOn) and pending < 1 then
			owed = 0
			return
		end
		if not captured then
			captured = true
			pcall(function() VirtualUser:CaptureController() end)
		end
		-- Bei sehr niedrigen FPS weniger Klicks, damit sich das Spiel erholen kann
		local limit = (dt > LOW_FPS_DT) and LOW_FPS_MAX_CLICKS or clickBurst
		local count = 0
		if autoClickOn then
			owed = math.min(owed + clicksPerSecond * dt, limit)
			count = math.floor(owed)
			owed -= count
		end
		-- Burst: pro Frame hoechstens "limit" Klicks aus der Warteschlange
		local fromBurst = math.min(pending, limit)
		pending -= fromBurst
		count += fromBurst
		frameCount += 1
		statTime += dt
		if count >= 1 then
			if pcall(runBatch, getClicker(), count) then
				sentCount += count
			else
				autoClickOn = false
				owed = 0
				pending = 0
				setStatus("Auto-Clicker stopped: click method failed.")
				refreshGui()
			end
		end
		-- Live-Anzeige: wie viele Klicks wirklich gesendet wurden
		if statTime >= 1 then
			if autoClickOn then
				setStatus(string.format("Auto-Clicker: %d clicks/s sent  (%d FPS)", math.floor(sentCount / statTime + 0.5), math.floor(frameCount / statTime + 0.5)))
			end
			sentCount, statTime, frameCount = 0, 0, 0
		end
	end
end

-- 4) Custom Crosshair (starr in der Bildschirmmitte)
local CROSSHAIR_COLORS = {
	{ name = "White", color = Color3.fromRGB(255, 255, 255) },
	{ name = "Green", color = Color3.fromRGB(60, 255, 100) },
	{ name = "Red", color = Color3.fromRGB(255, 60, 60) },
	{ name = "Cyan", color = Color3.fromRGB(60, 230, 255) },
	{ name = "Yellow", color = Color3.fromRGB(255, 230, 60) },
	{ name = "Magenta", color = Color3.fromRGB(255, 80, 220) },
}
local crosshairOn = false
local chLength, chGap, chThickness, chColorIndex = 10, 4, 2, 2
local crosshairFrame = Instance.new("Frame")
crosshairFrame.Name = "Crosshair"
crosshairFrame.AnchorPoint = Vector2.new(0.5, 0.5)
crosshairFrame.Position = UDim2.fromScale(0.5, 0.5)
crosshairFrame.Size = UDim2.fromOffset(0, 0)
crosshairFrame.BackgroundTransparency = 1
crosshairFrame.Visible = false
crosshairFrame.Parent = overlay
local applyCrosshair
do
local chLines = {}
for index = 1, 4 do
	local line = Instance.new("Frame")
	line.AnchorPoint = Vector2.new(0.5, 0.5)
	line.BorderSizePixel = 0
	line.Parent = crosshairFrame
	chLines[index] = line
end
function applyCrosshair()
	local color = CROSSHAIR_COLORS[chColorIndex].color
	local half = chGap + chLength / 2
	local layout = {
		{ w = chThickness, h = chLength, x = 0, y = -half },
		{ w = chThickness, h = chLength, x = 0, y = half },
		{ w = chLength, h = chThickness, x = -half, y = 0 },
		{ w = chLength, h = chThickness, x = half, y = 0 },
	}
	for index, line in ipairs(chLines) do
		local item = layout[index]
		line.Size = UDim2.fromOffset(item.w, item.h)
		line.Position = UDim2.fromOffset(item.x, item.y)
		line.BackgroundColor3 = color
	end
end
end
applyCrosshair()

-- 7) Tracer-Linien (vom unteren Bildschirmrand zum Torso)
local tracersOn = false
local tracerThickness = 1.5
local updateTracers
do
local tracerObjects = {}
local function getTracer(player)
	local line = tracerObjects[player]
	if line and line.Parent then return line end
	line = Instance.new("Frame")
	line.Name = "Tracer_" .. player.Name
	line.AnchorPoint = Vector2.new(0.5, 0.5)
	line.BorderSizePixel = 0
	line.BackgroundColor3 = ESP_COLOR
	line.Visible = false
	line.Parent = overlay
	tracerObjects[player] = line
	return line
end
local function hideTracers()
	for _, line in pairs(tracerObjects) do line.Visible = false end
end
connect(Players.PlayerRemoving, function(player)
	local line = tracerObjects[player]
	if line then
		line:Destroy()
		tracerObjects[player] = nil
	end
end)
function updateTracers(camera)
	if not (tracersOn and scriptFunctionsWorking and camera) then
		hideTracers()
		return
	end
	local viewport = camera.ViewportSize
	local origin = Vector2.new(viewport.X / 2, viewport.Y)
	local myCharacter = localPlayer.Character
	local myRoot = myCharacter and myCharacter:FindFirstChild("HumanoidRootPart")
	for _, player in ipairs(Players:GetPlayers()) do
		local shown = false
		if isValidTarget(player) then
			local torso = getTorso(player.Character)
			if torso then
				local distance = myRoot and (torso.Position - myRoot.Position).Magnitude or 0
				local point = camera:WorldToViewportPoint(torso.Position)
				if point.Z > 0 and distance <= ESP_MAX_DISTANCE then
					local target = Vector2.new(point.X, point.Y)
					local delta = target - origin
					local line = getTracer(player)
					line.Size = UDim2.fromOffset(delta.Magnitude, tracerThickness)
					line.Position = UDim2.fromOffset((origin.X + target.X) / 2, (origin.Y + target.Y) / 2)
					line.Rotation = math.deg(math.atan2(delta.Y, delta.X))
					line.BackgroundColor3 = (lockedTarget == player) and LOCKED_COLOR or ESP_COLOR
					line.Visible = true
					shown = true
				end
			end
		end
		if not shown then
			local line = tracerObjects[player]
			if line then line.Visible = false end
		end
	end
end
end

-- 10) Keybind-HUD (Farbwechsel gruen = aktiv, rot = inaktiv)
local hudOn = false
local refreshHud
do
local HUD_ACTIVE = Color3.fromRGB(80, 220, 120)
local HUD_INACTIVE = Color3.fromRGB(215, 80, 80)
local hudFrame = Instance.new("Frame")
hudFrame.Name = "KeybindHud"
hudFrame.AnchorPoint = Vector2.new(0, 0.5)
hudFrame.Position = UDim2.new(0, 12, 0.5, 0)
hudFrame.Size = UDim2.fromOffset(190, 0)
hudFrame.AutomaticSize = Enum.AutomaticSize.Y
hudFrame.BackgroundColor3 = COLOR_BG
hudFrame.BackgroundTransparency = 0.3
hudFrame.BorderSizePixel = 0
hudFrame.Visible = false
hudFrame.Parent = overlay
addCorner(hudFrame, 6)
local hudLayout = Instance.new("UIListLayout")
hudLayout.Padding = UDim.new(0, 2)
hudLayout.SortOrder = Enum.SortOrder.LayoutOrder
hudLayout.Parent = hudFrame
local hudPadding = Instance.new("UIPadding")
hudPadding.PaddingTop = UDim.new(0, 6)
hudPadding.PaddingBottom = UDim.new(0, 6)
hudPadding.PaddingLeft = UDim.new(0, 8)
hudPadding.PaddingRight = UDim.new(0, 8)
hudPadding.Parent = hudFrame
local hudEntries = {
	{ name = "Aimbot", key = function() return TOGGLE_KEY end, active = function() return isEnabled end },
	{ name = "Fly", key = function() return FLY_KEY end, active = function() return flying end },
	{ name = "Noclip", key = function() return NOCLIP_KEY end, active = function() return noclipOn end },
	{ name = "Auto-Click", key = function() return CLICKER_KEY end, active = function() return autoClickOn end },
	{ name = "Free mouse", key = function() return MENU_KEY end, active = function() return uiState.menuOpen end },
	{ name = "Functions", key = function() return SCRIPT_PAUSE_KEY end, active = function() return scriptFunctionsWorking end },
}
for index, entry in ipairs(hudEntries) do
	local label = Instance.new("TextLabel")
	label.LayoutOrder = index
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 0, 18)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 13
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = ""
	label.Parent = hudFrame
	entry.label = label
end
function refreshHud()
	hudFrame.Visible = hudOn
	if not hudOn then return end
	for _, entry in ipairs(hudEntries) do
		local on = entry.active()
		entry.label.Text = (on and "● " or "○ ") .. entry.name .. "  [" .. entry.key().Name .. "]"
		entry.label.TextColor3 = on and HUD_ACTIVE or HUD_INACTIVE
	end
end
end

-- Update-Schleifen
connect(RunService.Heartbeat, function(dt)
	updateAutoClicker(dt)
	updateHitboxes()
	updateHumanoidMods()
	refreshHud()
end)
RunService:BindToRenderStep("HeadLockExtras", Enum.RenderPriority.Camera.Value + 5, function()
	local camera = workspace.CurrentCamera
	if camera then
		if fovEnabled and scriptFunctionsWorking then
			if not defaultFov then defaultFov = camera.FieldOfView end
			if not lockedTarget then camera.FieldOfView = customFov end
		elseif defaultFov then
			if lockedTarget then
				lockedFov = defaultFov
			else
				camera.FieldOfView = defaultFov
			end
			defaultFov = nil
		end
	end
	crosshairFrame.Visible = crosshairOn and scriptFunctionsWorking
	updateTracers(camera)
end)

-- Hotkeys fuer Noclip und Auto-Clicker
connect(UserInputService.InputBegan, function(input)
	if not scriptFunctionsWorking then return end
	if inputBlocked() then return end
	if UserInputService:GetFocusedTextBox() then return end
	if input.KeyCode == NOCLIP_KEY then
		setNoclip(not noclipOn)
	elseif input.KeyCode == CLICKER_KEY then
		setAutoClick(not autoClickOn)
	elseif input.KeyCode == BURST_KEY then
		queueClickBurst(burstCount)
	end
end)

-- Alles zuruecksetzen (beim Beenden ueber X)
local function resetExtras()
	scriptAlive = false
	fovEnabled, hitboxResize, speedOn, jumpOn = false, false, false, false
	noclipOn, autoClickOn, tracersOn, crosshairOn, hudOn = false, false, false, false, false
	restoreAllHitboxes()
	updateHumanoidMods()
	restoreNoclip()
	local camera = workspace.CurrentCamera
	if camera and defaultFov then camera.FieldOfView = defaultFov end
	defaultFov = nil
end

-- 8) Config Save / Load (JSON per writefile / readfile)
local saveConfig, loadConfig
do
local HttpService = game:GetService("HttpService")
local CONFIG_FILE = "HeadLockConfig.json"
local function collectConfig()
	return {
		aimbot = isEnabled,
		teamCheck = teamCheck,
		showCircle = showCircle,
		showBoxes = showBoxes,
		showNames = showNames,
		showStats = showStats,
		fullbright = fullbrightWanted,
		antiAfk = antiAfk,
		pixelHitbox = pixelHitboxOn,
		cameraMode = CAMERA_MODE,
		aimMode = AIM_MODE,
		circleRadius = CIRCLE_RADIUS,
		flySpeed = FLY_SPEED,
		fovEnabled = fovEnabled,
		fov = customFov,
		hitboxResize = hitboxResize,
		hitboxScale = hitboxScale,
		crosshairOn = crosshairOn,
		crosshairLength = chLength,
		crosshairGap = chGap,
		crosshairThickness = chThickness,
		crosshairColor = chColorIndex,
		speedOn = speedOn,
		speedValue = speedValue,
		jumpOn = jumpOn,
		jumpValue = jumpValue,
		tracersOn = tracersOn,
		tracerThickness = tracerThickness,
		noclipOn = noclipOn,
		hudOn = hudOn,
		autoClickOn = autoClickOn,
		clicksPerSecond = clicksPerSecond,
		clickBurst = clickBurst,
		burstCount = burstCount,
		clickMode = clickMode,
		keys = {
			aimbot = TOGGLE_KEY.Name,
			fly = FLY_KEY.Name,
			menu = MENU_KEY.Name,
			pause = SCRIPT_PAUSE_KEY.Name,
			noclip = NOCLIP_KEY.Name,
			clicker = CLICKER_KEY.Name,
			burst = BURST_KEY.Name,
		},
	}
end
local function pickBool(value, current)
	if type(value) == "boolean" then return value end
	return current
end
local function pickNumber(value, current, low, high)
	if type(value) == "number" then return math.clamp(value, low, high) end
	return current
end
local function pickChoice(value, allowed, current)
	for _, option in ipairs(allowed) do
		if value == option then return value end
	end
	return current
end
local function pickKey(name, current)
	if type(name) ~= "string" then return current end
	local ok, key = pcall(function() return Enum.KeyCode[name] end)
	if ok and key then return key end
	return current
end
function saveConfig()
	if type(writefile) ~= "function" then
		setStatus("Save failed: writefile is not available here.")
		return
	end
	local ok, err = pcall(function()
		writefile(CONFIG_FILE, HttpService:JSONEncode(collectConfig()))
	end)
	setStatus(ok and ("Config saved: " .. CONFIG_FILE) or ("Save failed: " .. tostring(err)))
end
function loadConfig()
	if type(readfile) ~= "function" then
		setStatus("Load failed: readfile is not available here.")
		return
	end
	if type(isfile) == "function" and not isfile(CONFIG_FILE) then
		setStatus("No config file found yet.")
		return
	end
	local okRead, raw = pcall(readfile, CONFIG_FILE)
	if not okRead then
		setStatus("Load failed: " .. tostring(raw))
		return
	end
	local okParse, data = pcall(function() return HttpService:JSONDecode(raw) end)
	if not okParse or type(data) ~= "table" then
		setStatus("Load failed: invalid config file.")
		return
	end
	teamCheck = pickBool(data.teamCheck, teamCheck)
	showCircle = pickBool(data.showCircle, showCircle)
	showBoxes = pickBool(data.showBoxes, showBoxes)
	showNames = pickBool(data.showNames, showNames)
	showStats = pickBool(data.showStats, showStats)
	fullbrightWanted = pickBool(data.fullbright, fullbrightWanted)
	antiAfk = pickBool(data.antiAfk, antiAfk)
	CAMERA_MODE = pickChoice(data.cameraMode, { "Keep", "Behind" }, CAMERA_MODE)
	AIM_MODE = pickChoice(data.aimMode, { "Both", "Head", "Torso" }, AIM_MODE)
	CIRCLE_RADIUS = pickNumber(data.circleRadius, CIRCLE_RADIUS, 40, 600)
	FLY_SPEED = pickNumber(data.flySpeed, FLY_SPEED, 10, 300)
	fovEnabled = pickBool(data.fovEnabled, fovEnabled)
	customFov = pickNumber(data.fov, customFov, 30, 120)
	hitboxResize = pickBool(data.hitboxResize, hitboxResize)
	hitboxScale = pickNumber(data.hitboxScale, hitboxScale, 2, 30)
	crosshairOn = pickBool(data.crosshairOn, crosshairOn)
	chLength = pickNumber(data.crosshairLength, chLength, 2, 40)
	chGap = pickNumber(data.crosshairGap, chGap, 0, 30)
	chThickness = pickNumber(data.crosshairThickness, chThickness, 1, 6)
	chColorIndex = math.floor(pickNumber(data.crosshairColor, chColorIndex, 1, #CROSSHAIR_COLORS))
	speedOn = pickBool(data.speedOn, speedOn)
	speedValue = pickNumber(data.speedValue, speedValue, 16, 200)
	jumpOn = pickBool(data.jumpOn, jumpOn)
	jumpValue = pickNumber(data.jumpValue, jumpValue, 50, 300)
	tracersOn = pickBool(data.tracersOn, tracersOn)
	tracerThickness = pickNumber(data.tracerThickness, tracerThickness, 1, 5)
	hudOn = pickBool(data.hudOn, hudOn)
	clicksPerSecond = pickNumber(data.clicksPerSecond, clicksPerSecond, 1, 500)
	clickBurst = pickNumber(data.clickBurst, clickBurst, 1, 50)
	burstCount = math.floor(pickNumber(data.burstCount, burstCount, 1, 500))
	clickMode = pickChoice(data.clickMode, { "Mouse1", "Virtual", "Tool" }, clickMode)
	if type(data.keys) == "table" then
		TOGGLE_KEY = pickKey(data.keys.aimbot, TOGGLE_KEY)
		FLY_KEY = pickKey(data.keys.fly, FLY_KEY)
		MENU_KEY = pickKey(data.keys.menu, MENU_KEY)
		SCRIPT_PAUSE_KEY = pickKey(data.keys.pause, SCRIPT_PAUSE_KEY)
		NOCLIP_KEY = pickKey(data.keys.noclip, NOCLIP_KEY)
		CLICKER_KEY = pickKey(data.keys.clicker, CLICKER_KEY)
		BURST_KEY = pickKey(data.keys.burst, BURST_KEY)
	end
	setEnabled(pickBool(data.aimbot, isEnabled))
	setPixelHitboxLocal(pickBool(data.pixelHitbox, pixelHitboxOn))
	setNoclip(pickBool(data.noclipOn, noclipOn))
	setAutoClick(pickBool(data.autoClickOn, autoClickOn))
	applyCrosshair()
	refreshGui()
	setStatus("Config loaded: " .. CONFIG_FILE)
end
end

-- ===== MENUE-INHALT (Tabs: Combat / Visuals / Movement / Misc) =====
local function addSection(page, title)
	rowCounter += 1
	local header = Instance.new("TextLabel")
	header.LayoutOrder = rowCounter
	header.Size = UDim2.new(1, -10, 0, 24)
	header.BackgroundTransparency = 1
	header.Font = Enum.Font.GothamBold
	header.Text = string.upper(title)
	header.TextSize = 12
	header.TextColor3 = COLOR_ACCENT
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Parent = page
	local underline = Instance.new("Frame")
	underline.Size = UDim2.new(1, 0, 0, 1)
	underline.Position = UDim2.new(0, 0, 1, -2)
	underline.BackgroundColor3 = COLOR_BUTTON
	underline.BorderSizePixel = 0
	underline.Parent = header
end

-- TAB: COMBAT
addSection(combatPage, "Aimbot")
addToggleRow(combatPage, function() return "Aimbot Lock  (" .. TOGGLE_KEY.Name .. ")" end, function() return isEnabled end, function(value) setEnabled(value) end)
addCycleRow(combatPage, "Aim at", function() return AIM_MODE end, function()
	if AIM_MODE == "Both" then AIM_MODE = "Head" elseif AIM_MODE == "Head" then AIM_MODE = "Torso" else AIM_MODE = "Both" end
end)
addCycleRow(combatPage, "Camera mode", function() return CAMERA_MODE end, function() CAMERA_MODE = (CAMERA_MODE == "Behind") and "Keep" or "Behind" end)
addStepperRow(combatPage, "Circle size", function() return tostring(CIRCLE_RADIUS) end, function(dir) CIRCLE_RADIUS = math.clamp(CIRCLE_RADIUS + dir * 10, 40, 600) refreshGui() end)
addToggleRow(combatPage, "Team check  (ignore teammates)", function() return teamCheck end, function(value) teamCheck = value end)
addSection(combatPage, "Hitbox")
addToggleRow(combatPage, "Hitbox resizer  (enemies)", function() return hitboxResize end, function(value) hitboxResize = value end)
addSliderRow(combatPage, "Hitbox size", 2, 30, 1, function() return hitboxScale end, function(value) hitboxScale = value end)
addToggleRow(combatPage, "Pixel Hitbox  (own character)", function() return pixelHitboxOn end, function(value) setPixelHitboxLocal(value) end)
addSection(combatPage, "Auto-Clicker")
addToggleRow(combatPage, function() return "Auto-Clicker  (" .. CLICKER_KEY.Name .. ")" end, function() return autoClickOn end, function(value) setAutoClick(value) end)
addSliderRow(combatPage, "Clicks/s  (high = laggy)", 1, 500, 1, function() return clicksPerSecond end, function(value) clicksPerSecond = value end)
addSliderRow(combatPage, "Max clicks per frame", 1, 50, 1, function() return clickBurst end, function(value) clickBurst = value end)
addSliderRow(combatPage, function() return "Burst size  (press " .. BURST_KEY.Name .. ")" end, 1, 500, 1, function() return burstCount end, function(value) burstCount = value end)
addCycleRow(combatPage, "Click mode", function() return clickMode end, function()
	if clickMode == "Mouse1" then clickMode = "Virtual" elseif clickMode == "Virtual" then clickMode = "Tool" else clickMode = "Mouse1" end
end)

-- TAB: VISUALS
addSection(visualsPage, "ESP")
addToggleRow(visualsPage, "Boxes", function() return showBoxes end, function(value) showBoxes = value end)
addToggleRow(visualsPage, "Names", function() return showNames end, function(value) showNames = value end)
addToggleRow(visualsPage, "Tracers", function() return tracersOn end, function(value) tracersOn = value end)
addSliderRow(visualsPage, "Tracer thickness", 1, 5, 0.5, function() return tracerThickness end, function(value) tracerThickness = value end)
addSection(visualsPage, "Screen")
addToggleRow(visualsPage, "Aim circle", function() return showCircle end, function(value) showCircle = value refreshGui() end)
addToggleRow(visualsPage, "FOV changer", function() return fovEnabled end, function(value) fovEnabled = value end)
addSliderRow(visualsPage, "Field of view", 30, 120, 1, function() return customFov end, function(value) customFov = value end)
addToggleRow(visualsPage, "Fullbright", function() return fullbrightWanted end, function(value) fullbrightWanted = value end)
addSection(visualsPage, "Crosshair")
addToggleRow(visualsPage, "Crosshair", function() return crosshairOn end, function(value) crosshairOn = value end)
addSliderRow(visualsPage, "Crosshair size", 2, 40, 1, function() return chLength end, function(value) chLength = value applyCrosshair() end)
addSliderRow(visualsPage, "Crosshair gap", 0, 30, 1, function() return chGap end, function(value) chGap = value applyCrosshair() end)
addSliderRow(visualsPage, "Crosshair thickness", 1, 6, 1, function() return chThickness end, function(value) chThickness = value applyCrosshair() end)
addCycleRow(visualsPage, "Crosshair color", function() return CROSSHAIR_COLORS[chColorIndex].name end, function()
	chColorIndex = (chColorIndex % #CROSSHAIR_COLORS) + 1
	applyCrosshair()
end)
addSection(visualsPage, "Info")
addToggleRow(visualsPage, "FPS / Ping", function() return showStats end, function(value) showStats = value refreshGui() end)
addToggleRow(visualsPage, "Keybind HUD", function() return hudOn end, function(value) hudOn = value end)

-- TAB: MOVEMENT
addSection(movePage, "Fly")
addToggleRow(movePage, function() return "Fly System  (" .. FLY_KEY.Name .. ")" end, function() return flying end, function(value) if value then startFly() else stopFly() end end)
addStepperRow(movePage, "Fly speed", function() return tostring(FLY_SPEED) end, function(dir) FLY_SPEED = math.clamp(FLY_SPEED + dir * 10, 10, 300) end)
addSection(movePage, "Speed & Jump")
addToggleRow(movePage, "Speed", function() return speedOn end, function(value) speedOn = value end)
addSliderRow(movePage, "Walk speed", 16, 200, 2, function() return speedValue end, function(value) speedValue = value end)
addToggleRow(movePage, "Jump power", function() return jumpOn end, function(value) jumpOn = value end)
addSliderRow(movePage, "Jump value", 50, 300, 10, function() return jumpValue end, function(value) jumpValue = value end)
addSection(movePage, "Collision")
addToggleRow(movePage, function() return "Noclip  (" .. NOCLIP_KEY.Name .. ")" end, function() return noclipOn end, function(value) setNoclip(value) end)
addSection(movePage, "Checkpoint")
local checkpoint = nil
addActionRow(movePage, "Checkpoint  (save spot)", "Save", function()
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		setStatus("No character found.")
		return
	end
	checkpoint = root.CFrame
	setStatus("Checkpoint saved.")
end)
addActionRow(movePage, "Checkpoint  (go back)", "Go back", function()
	if not scriptFunctionsWorking then return end
	if not checkpoint then
		setStatus("No checkpoint saved yet.")
		return
	end
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		setStatus("No character found.")
		return
	end
	pcall(function()
		root.AssemblyLinearVelocity = Vector3.zero
		character:PivotTo(checkpoint)
	end)
	setStatus("Back at checkpoint.")
end)

-- TAB: MISC
addSection(miscPage, "Utility")
addToggleRow(miscPage, "Anti-AFK", function() return antiAfk end, function(value) antiAfk = value end)
addActionRow(miscPage, "Kill  (your character)", "Kill me", function()
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	if pixelHitboxOn then setPixelHitboxLocal(false) end
	stopFly()
	humanoid.Health = 0
	setStatus("You killed yourself.")
end)
-- TAB 4: „PLAYERS“ SEITE
local playersHeader = newLabel(playersPage, "Teleport = go to player   |   Spectate = watch player", UDim2.new(1, -10, 0, 26), UDim2.new(), 13, false)
playersHeader.TextColor3 = COLOR_SUBTEXT
local noPlayersLabel = newLabel(playersPage, "No other players found.", UDim2.new(1, -10, 0, 40), UDim2.new(), 15, false)
noPlayersLabel.TextColor3 = COLOR_SUBTEXT
-- Spectate (anderen Spielern zuschauen)
local spectating = nil
local spectateButtons = {}
local function refreshSpectateButtons()
for player, button in pairs(spectateButtons) do
if button.Parent then
button.Text = (spectating == player) and "Stop" or "Spectate"
else
spectateButtons[player] = nil
end
end
end
local function stopSpectate()
if not spectating then return end
spectating = nil
local camera = workspace.CurrentCamera
local humanoid = localPlayer.Character and localPlayer.Character:FindFirstChildOfClass("Humanoid")
if camera and humanoid then camera.CameraSubject = humanoid end
refreshSpectateButtons()
setStatus("Spectate stopped.")
end
local function spectatePlayer(player)
if not scriptFunctionsWorking then return end
if spectating == player then
stopSpectate()
return
end
local camera = workspace.CurrentCamera
local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
if not (camera and humanoid) then
setStatus("Spectate failed.")
return
end
spectating = player
camera.CameraSubject = humanoid
refreshSpectateButtons()
setStatus("Spectating " .. player.DisplayName)
end
connect(RunService.Heartbeat, function()
if not spectating then return end
local camera = workspace.CurrentCamera
local humanoid = spectating.Character and spectating.Character:FindFirstChildOfClass("Humanoid")
if camera and humanoid and camera.CameraSubject ~= humanoid then camera.CameraSubject = humanoid end
end)
connect(Players.PlayerRemoving, function(player)
if player == spectating then stopSpectate() end
end)
connect(localPlayer.CharacterAdded, function() stopSpectate() end)
local function createPlayerRow(player, order)
local row = Instance.new("Frame")
row.LayoutOrder = order + 1
row.Size = UDim2.new(1, -10, 0, 46)
row.BackgroundColor3 = COLOR_ITEM
row.Parent = playersPage
addCorner(row, 8)
local nameLabel = newLabel(row, player.DisplayName, UDim2.new(1, -230, 1, 0), UDim2.fromOffset(14, 0), 15, true)
local teleportButton = newButton(row, "Teleport", UDim2.new(1, -124, 0.5, -16), UDim2.fromOffset(112, 32), COLOR_ACCENT, 13)
teleportButton.Activated:Connect(function() teleportToPlayer(player) end)
local spectateButton = newButton(row, (spectating == player) and "Stop" or "Spectate", UDim2.new(1, -218, 0.5, -16), UDim2.fromOffset(88, 32), COLOR_BUTTON, 13)
spectateButtons[player] = spectateButton
spectateButton.Activated:Connect(function() spectatePlayer(player) end)
end
local function rebuildPlayerList()
for _, child in ipairs(playersPage:GetChildren()) do if child:IsA("Frame") then child:Destroy() end end
local others = {}
for _, player in ipairs(Players:GetPlayers()) do if player ~= localPlayer then table.insert(others, player) end end
noPlayersLabel.Visible = (#others == 0)
for index, player in ipairs(others) do createPlayerRow(player, index) end
end
connect(Players.PlayerAdded, rebuildPlayerList)
connect(Players.PlayerRemoving, function() task.defer(rebuildPlayerList) end)
rebuildPlayerList()
-- Menüverhalten und Cursor-Steuerung
local customOpen = false
local modalButton = Instance.new("TextButton")
modalButton.Size = UDim2.fromOffset(0, 0)
modalButton.BackgroundTransparency = 1
modalButton.Modal = true
modalButton.Visible = false
modalButton.Parent = window
local cursorForced = false
local function setCursorFree(free)
if free == cursorForced then return end
cursorForced = free
if free then
RunService:BindToRenderStep("HeadLockCursor", Enum.RenderPriority.Camera.Value + 3, function()
UserInputService.MouseBehavior = Enum.MouseBehavior.Default
UserInputService.MouseIconEnabled = true
end)
else
pcall(function() RunService:UnbindFromRenderStep("HeadLockCursor") end)
end
end
local mouseButton = newButton(sidebar, "", UDim2.new(0, 10, 1, -52), UDim2.fromOffset(120, 40), COLOR_BUTTON, 13)
local function updatePanel()
modalButton.Visible = customOpen
uiState.menuOpen = customOpen
setCursorFree(customOpen)
if not scriptFunctionsWorking then
titleLabel.Text = "  Head Lock   [PAUSED - Press " .. SCRIPT_PAUSE_KEY.Name .. "]"
else
titleLabel.Text = customOpen and "  Head Lock   [mouse free]" or "  Head Lock"
end
mouseButton.Text = customOpen and "Mouse: FREE" or "Free mouse"
mouseButton.BackgroundColor3 = customOpen and ON_COLOR or COLOR_BUTTON
end
mouseButton.Activated:Connect(function() customOpen = not customOpen updatePanel() end)
-- NEUE FUNKTION FÜR DIE TASTE P: Pausiert nur die Funktionen, lässt das Menü aber da
local function togglePauseState()
scriptFunctionsWorking = not scriptFunctionsWorking
if not scriptFunctionsWorking then
stopFly()
stopAiming()
if pixelHitboxOn then setPixelHitboxLocal(false) end
stopSpectate()
setStatus("Functions Paused via " .. SCRIPT_PAUSE_KEY.Name .. ".")
else
if pixelHitboxOn then setPixelHitboxLocal(true) end
setStatus("Functions Restored.")
end
updatePanel()
refreshGui()
end
-- ABSCHALTEN BEIM KLICK AUF DAS ROTE X (Shutdown-System)
local function shutdown()
stopSpectate()
fullbrightWanted = false
restoreLighting()
stopFly()
stopAiming()
resetExtras()
pcall(function() RunService:UnbindFromRenderStep("HeadLockExtras") end)
isEnabled = false
if pixelHitboxOn then setPixelHitboxLocal(false) end
setCursorFree(false)
pcall(function() RunService:UnbindFromRenderStep("HeadLockEnemyCamera") end)
pcall(function() RunService:UnbindFromRenderStep("HeadLockEsp") end)
pcall(function() RunService:UnbindFromRenderStep("HeadLockCursor") end)
pcall(function() RunService:UnbindFromRenderStep("HeadLockFly") end)
for _, connection in ipairs(connections) do connection:Disconnect() end
overlay:Destroy()
gui:Destroy()
end
closeButton.Activated:Connect(shutdown)
do
local collapsed = false
minimizeButton.Activated:Connect(function()
collapsed = not collapsed
sidebar.Visible = not collapsed
content.Visible = not collapsed
statusBar.Visible = not collapsed
window.Size = UDim2.fromOffset(WINDOW_W, collapsed and TITLE_H or WINDOW_H)
minimizeButton.Text = collapsed and "+" or "-"
end)
local dragging, dragStart, startPosition = false, Vector3.zero, window.Position
titleBar.InputBegan:Connect(function(input)
if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
dragging = true
dragStart = input.Position
startPosition = window.Position
input.Changed:Connect(function() if input.UserInputState == Enum.UserInputState.End then dragging = false end end)
end
end)
connect(UserInputService.InputChanged, function(input)
if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
local delta = input.Position - dragStart
window.Position = UDim2.new(startPosition.X.Scale, startPosition.X.Offset + delta.X, startPosition.Y.Scale, startPosition.Y.Offset + delta.Y)
end
end)
end
-- Zentraler Tastatur-Empfänger
connect(UserInputService.InputBegan, function(input)
if UserInputService:GetFocusedTextBox() then return end
if inputBlocked() then return end
if input.KeyCode == SCRIPT_PAUSE_KEY then
togglePauseState() -- P pausiert/reaktiviert nur die Hacks
elseif input.KeyCode == MENU_KEY then
customOpen = not customOpen
updatePanel()
end
end)
-- TAB 5: "SETTINGS" SEITE (Hotkeys anpassen)
local settingsHint = newLabel(settingsPage, "Click a key, then press the new key  (Esc = cancel)", UDim2.new(1, -10, 0, 26), UDim2.new(), 13, false)
settingsHint.TextColor3 = COLOR_SUBTEXT
local hotkeys = {
{ name = "Aimbot toggle", get = function() return TOGGLE_KEY end, set = function(k) TOGGLE_KEY = k end },
{ name = "Fly toggle", get = function() return FLY_KEY end, set = function(k) FLY_KEY = k end },
{ name = "Free mouse / menu", get = function() return MENU_KEY end, set = function(k) MENU_KEY = k end },
{ name = "Pause functions", get = function() return SCRIPT_PAUSE_KEY end, set = function(k) SCRIPT_PAUSE_KEY = k end },
{ name = "Noclip toggle", get = function() return NOCLIP_KEY end, set = function(k) NOCLIP_KEY = k end },
{ name = "Auto-Clicker toggle", get = function() return CLICKER_KEY end, set = function(k) CLICKER_KEY = k end },
{ name = "Click burst", get = function() return BURST_KEY end, set = function(k) BURST_KEY = k end },
}
addSection(settingsPage, "Hotkeys")
for _, entry in ipairs(hotkeys) do
local row = createRow(settingsPage, entry.name)
local button = newButton(row, "", UDim2.new(1, -164, 0.5, -16), UDim2.fromOffset(152, 32), COLOR_BUTTON, 14)
local function refresh()
if listeningFor == entry then
button.Text = "Press a key..."
button.BackgroundColor3 = COLOR_ACCENT
else
button.Text = entry.get().Name
button.BackgroundColor3 = COLOR_BUTTON
end
end
button.Activated:Connect(function()
if listeningFor == entry then
listeningFor = nil
bindIgnoreUntil = os.clock() + 0.2
setStatus("Rebind cancelled.")
else
listeningFor = entry
setStatus("Press a key for: " .. entry.name)
end
refreshGui()
end)
table.insert(refreshers, refresh)
refresh()
end
addActionRow(settingsPage, "Reset hotkeys", "Defaults", function()
listeningFor = nil
bindIgnoreUntil = os.clock() + 0.2
TOGGLE_KEY = Enum.KeyCode.T
FLY_KEY = Enum.KeyCode.G
MENU_KEY = Enum.KeyCode.RightShift
SCRIPT_PAUSE_KEY = Enum.KeyCode.P
NOCLIP_KEY = Enum.KeyCode.N
CLICKER_KEY = Enum.KeyCode.K
BURST_KEY = Enum.KeyCode.B
setStatus("Hotkeys reset to default.")
refreshGui()
updatePanel()
end)
addSection(settingsPage, "Config")
addActionRow(settingsPage, "Config  (save to JSON file)", "Save config", saveConfig)
addActionRow(settingsPage, "Config  (load from file)", "Load config", function()
loadConfig()
updatePanel()
end)
connect(UserInputService.InputBegan, function(input)
if not listeningFor then return end
if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
if UserInputService:GetFocusedTextBox() then return end
local entry = listeningFor
if input.KeyCode == Enum.KeyCode.Escape then
listeningFor = nil
bindIgnoreUntil = os.clock() + 0.2
setStatus("Rebind cancelled.")
refreshGui()
return
end
if input.KeyCode == Enum.KeyCode.Unknown then return end
for _, other in ipairs(hotkeys) do
if other ~= entry and other.get() == input.KeyCode then
setStatus(input.KeyCode.Name .. " is already used by: " .. other.name)
return
end
end
entry.set(input.KeyCode)
listeningFor = nil
bindIgnoreUntil = os.clock() + 0.2
setStatus(entry.name .. " = " .. input.KeyCode.Name)
refreshGui()
updatePanel()
end)
showPage("Combat")
refreshGui()
updatePanel()
print("Head Lock loaded (" .. SCRIPT_PAUSE_KEY.Name .. " = Pause / X = Shutdown). MENU = " .. MENU_KEY.Name)