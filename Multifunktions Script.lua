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

local AIM_MODE = "Both"
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

local function isEnemy(player)
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
local circleCorner = Instance.new("UICorner")
circleCorner.CornerRadius = UDim.new(0.5, 0)
circleCorner.Parent = circleFrame
local circleStroke = Instance.new("UIStroke")
circleStroke.Thickness = 2
circleStroke.Color = Color3.fromRGB(255, 255, 255)
circleStroke.Transparency = 0.25
circleStroke.Parent = circleFrame
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
local refreshers = {}
local function createPage(name)
local page = Instance.new("ScrollingFrame")
page.Name = name
page.BackgroundTransparency = 1
page.BorderSizePixel = 0
page.Size = UDim2.fromScale(1, 1)
page.ScrollBarThickness = 5
page.CanvasSize = UDim2.new()
page.AutomaticCanvasSize = Enum.AutomaticSize.Y
page.Visible = false
page.Parent = content
local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 8)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = page
pages[name] = page
return page
end
local function showPage(name)
for pageName, page in pairs(pages) do page.Visible = (pageName == name) end
for tabName, button in pairs(tabButtons) do button.BackgroundColor3 = (tabName == name) and COLOR_ACCENT or COLOR_BUTTON end
end
local function createTab(name, order)
local button = newButton(sidebar, name, UDim2.fromOffset(10, 12 + (order - 1) * 48), UDim2.fromOffset(120, 40), COLOR_BUTTON, 15)
tabButtons[name] = button
button.Activated:Connect(function() showPage(name) end)
return button
end
-- TABS
local mainPage = createPage("Main")
local visualsPage = createPage("Visuals")
local playerPage = createPage("Player")
local playersPage = createPage("Players")
local settingsPage = createPage("Settings")
createTab("Main", 1)
createTab("Visuals", 2)
createTab("Player", 3)
createTab("Players", 4)
createTab("Settings", 5)
local rowCounter = 0
local function createRow(page, text)
rowCounter += 1
local row = Instance.new("Frame")
row.LayoutOrder = rowCounter
row.Size = UDim2.new(1, -10, 0, 48)
row.BackgroundColor3 = COLOR_ITEM
row.Parent = page
addCorner(row, 8)
local rowLabel = newLabel(row, type(text) == "function" and text() or text, UDim2.new(1, -190, 1, 0), UDim2.fromOffset(14, 0), 15, false)
if type(text) == "function" then
table.insert(refreshers, function() rowLabel.Text = text() end)
end
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
-- TAB 1: „MAIN“ SEITE
addToggleRow(mainPage, function() return "Aimbot Lock  (" .. TOGGLE_KEY.Name .. ")" end, function() return isEnabled end, function(value) setEnabled(value) end)
addToggleRow(mainPage, function() return "Fly System  (" .. FLY_KEY.Name .. ")" end, function() return flying end, function(value) if value then startFly() else stopFly() end end)
addStepperRow(mainPage, "Fly speed", function() return tostring(FLY_SPEED) end, function(dir) FLY_SPEED = math.clamp(FLY_SPEED + dir * 10, 10, 300) end)
addCycleRow(mainPage, "Camera mode", function() return CAMERA_MODE end, function() CAMERA_MODE = (CAMERA_MODE == "Behind") and "Keep" or "Behind" end)
addCycleRow(mainPage, "Aim at", function() return AIM_MODE end, function()
if AIM_MODE == "Both" then AIM_MODE = "Head" elseif AIM_MODE == "Head" then AIM_MODE = "Torso" else AIM_MODE = "Both" end
end)
addStepperRow(mainPage, "Circle size", function() return tostring(CIRCLE_RADIUS) end, function(dir) CIRCLE_RADIUS = math.clamp(CIRCLE_RADIUS + dir * 10, 40, 600) refreshGui() end)
-- TAB 2: „VISUALS“ SEITE
addToggleRow(visualsPage, "Aim circle", function() return showCircle end, function(value) showCircle = value refreshGui() end)
addToggleRow(visualsPage, "Boxes", function() return showBoxes end, function(value) showBoxes = value end)
addToggleRow(visualsPage, "Names", function() return showNames end, function(value) showNames = value end)
addToggleRow(visualsPage, "FPS / Ping", function() return showStats end, function(value) showStats = value refreshGui() end)
addToggleRow(visualsPage, "Fullbright", function() return fullbrightWanted end, function(value) fullbrightWanted = value end)
-- TAB 3: „PLAYER“ SEITE
addToggleRow(playerPage, "Pixel Hitbox", function() return pixelHitboxOn end, function(value) setPixelHitboxLocal(value) end)
addToggleRow(playerPage, "Anti-AFK", function() return antiAfk end, function(value) antiAfk = value end)
addActionRow(playerPage, "Kill  (your character)", "Kill me", function()
local character = localPlayer.Character
local humanoid = character and character:FindFirstChildOfClass("Humanoid")
if not humanoid then return end
if pixelHitboxOn then setPixelHitboxLocal(false) end
stopFly()
humanoid.Health = 0
setStatus("You killed yourself.")
end)
local checkpoint = nil
addActionRow(playerPage, "Checkpoint  (save spot)", "Save", function()
local character = localPlayer.Character
local root = character and character:FindFirstChild("HumanoidRootPart")
if not root then
setStatus("No character found.")
return
end
checkpoint = root.CFrame
setStatus("Checkpoint saved.")
end)
addActionRow(playerPage, "Checkpoint  (go back)", "Go back", function()
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
}
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
setStatus("Hotkeys reset to default.")
refreshGui()
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
showPage("Main")
refreshGui()
updatePanel()
print("Head Lock loaded (" .. SCRIPT_PAUSE_KEY.Name .. " = Pause / X = Shutdown). MENU = " .. MENU_KEY.Name)