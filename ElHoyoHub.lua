-- El Hoyo Hub
-- Todo el hub va dentro de una función protegida: si algo falla al cargar, en vez de no abrirse sin más,
-- sale una ventana con el error (y se copia al portapapeles) para poder arreglarlo.
local function ElHoyoHubMain()
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UIS = game:GetService("UserInputService")
local VIM = game:GetService("VirtualInputManager")
local VirtualUser = game:GetService("VirtualUser")
local player = Players.LocalPlayer
local mouse = player:GetMouse()

-- Si ya hay un hub abierto (se volvió a ejecutar el script), se cierra antes: dos hubs harían todo doble
local genv = getgenv and getgenv() or {}
if genv.ElHoyoHubClose then pcall(genv.ElHoyoHubClose) end

local Services = game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Packages"):WaitForChild("_Index")
	:WaitForChild("sleitnick_knit@1.7.0"):WaitForChild("knit"):WaitForChild("Services")

local missingRemotes = {} -- se avisan en la consola cuando ya existe
local function getRemote(service, kind, name)
	-- Con límite de tiempo: si el juego renombra algo, esa función deja de ir pero el hub sí carga
	local svc = Services:WaitForChild(service, 5)
	local folder = svc and svc:WaitForChild(kind, 5)
	local remote = folder and folder:WaitForChild(name, 5)
	if not remote then table.insert(missingRemotes, service .. "." .. kind .. "." .. name) end
	return remote
end

-- Llama a una señal sin romper nada si no existe: devuelve ok, resultados...
local function call(remote, method, ...)
	if not remote then return false, "señal no encontrada" end
	return pcall(remote[method], remote, ...)
end

local alive = true
local cleanup = {} -- conexiones que se desconectan al cerrar

------------------------------------------------------------------ Configuración guardada
-- Se guarda en un archivo del executor (writefile/readfile). Si el executor no lo permite, dura solo la sesión.
local HttpService = game:GetService("HttpService")
local CONFIG_FILE = "ElHoyoHub.json"
local config = {
	profiles = {}, -- perfiles guardados con nombre: funciones encendidas + ajustes
	lang = genv.ElHoyoHubLang or "es",
	palette = "Abismo",
	key = "RightShift",
	notify = true,
	scale = 1,
	hubUrl = "https://raw.githubusercontent.com/saulandujar/elhoyohub/refs/heads/main/ElHoyoHub.lua", -- para Autoexec
}
pcall(function()
	if isfile and readfile and isfile(CONFIG_FILE) then
		for k, v in HttpService:JSONDecode(readfile(CONFIG_FILE)) do config[k] = v end
	end
end)
local saveQueued = false
local function saveConfig()
	if not writefile or saveQueued then return end
	saveQueued = true
	task.delay(1, function() -- agrupa varios cambios seguidos en una sola escritura
		saveQueued = false
		pcall(writefile, CONFIG_FILE, HttpService:JSONEncode(config))
	end)
end

------------------------------------------------------------------ Interfaz: El Hoyo UI
-- La ventana la dibuja ElHoyoUI.lua (librería propia, basada en Neverlose Reloaded y adaptada a El Hoyo Hub).
-- Se usa el archivo de la carpeta del executor si existe; si no, se descarga del mismo sitio que el hub.
-- Aquí abajo hay una capa fina con las funciones de siempre (section, toggle, button, note...) para que las
-- secciones de funciones no tengan que saber nada de la librería.
local UI_URL = "https://raw.githubusercontent.com/saulandujar/elhoyohub/refs/heads/main/ElHoyoUI.lua"
local uiSource
pcall(function()
	if isfile and readfile and isfile("ElHoyoUI.lua") then uiSource = readfile("ElHoyoUI.lua") end
end)
if not uiSource then
	local nextToHub = config.hubUrl and config.hubUrl:gsub("ElHoyoHub%.lua$", "ElHoyoUI.lua")
	local url = (nextToHub and nextToHub ~= config.hubUrl) and nextToHub or UI_URL
	local ok, src = pcall(game.HttpGet, game, url)
	if ok then uiSource = src end
end
assert(type(uiSource) == "string" and #uiSource > 1000,
	"No pude cargar ElHoyoUI.lua: súbelo a GitHub junto a ElHoyoHub.lua (o ponlo en la carpeta del executor)")
local UI = loadstring(uiSource)()

-- Colores fijos para lo que no dibuja la librería (consola, ESP, zona segura): los de la paleta Abismo roja
local C = {
	bg = Color3.fromRGB(13, 12, 19), surface = Color3.fromRGB(19, 18, 26), line = Color3.fromRGB(38, 34, 48),
	accent = Color3.fromRGB(225, 29, 72), on = Color3.fromRGB(34, 197, 94), warn = Color3.fromRGB(245, 158, 11),
	err = Color3.fromRGB(239, 68, 68), text = Color3.fromRGB(236, 236, 244), dim = Color3.fromRGB(128, 128, 150),
}
local FONT_SEMI = Enum.Font.GothamMedium

------------------------------------------------------------------ Idioma
-- La librería traduce sola los nombres: el texto base va en inglés y el español es su idioma 1.
-- L("es", "en") para nombres fijos (se registran en la librería); T("es", "en") para mensajes del momento.
local LANG = "es"
local function L(es, en)
	return { es = es, en = en }
end
local function T(es, en)
	return LANG == "en" and en or es
end
local function uiText(v)
	if type(v) ~= "table" then return v end
	if v.es ~= v.en then UI.Translations[v.en] = { v.es } end
	return v.en
end

------------------------------------------------------------------ Consola
-- Ventana propia (la librería no tiene una lista que crezca): registro de todo lo que hace el hub.
local gui = Instance.new("ScreenGui")
gui.Name = "ElHoyoHub"
gui.ResetOnSpawn = false
gui.DisplayOrder = 60
gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")

local function isOver(f)
	if not f.Visible then return false end
	local p, s = f.AbsolutePosition, f.AbsoluteSize
	return mouse.X >= p.X and mouse.X <= p.X + s.X and mouse.Y >= p.Y and mouse.Y <= p.Y + s.Y
end

local consoleWin = Instance.new("Frame")
consoleWin.Size = UDim2.fromOffset(400, 250)
consoleWin.Position = UDim2.new(1, -416, 1, -330)
consoleWin.BackgroundColor3 = C.bg
consoleWin.Visible = false
consoleWin.Parent = gui
Instance.new("UICorner", consoleWin).CornerRadius = UDim.new(0, 10)
local consoleStroke = Instance.new("UIStroke")
consoleStroke.Color = C.line
consoleStroke.Parent = consoleWin

local consoleHeader = Instance.new("TextButton")
consoleHeader.Text = ""
consoleHeader.AutoButtonColor = false
consoleHeader.BackgroundTransparency = 1
consoleHeader.Size = UDim2.new(1, 0, 0, 36)
consoleHeader.Parent = consoleWin
local consoleTitle = Instance.new("TextLabel")
consoleTitle.BackgroundTransparency = 1
consoleTitle.Position = UDim2.fromOffset(14, 0)
consoleTitle.Size = UDim2.new(1, -90, 1, 0)
consoleTitle.Font = Enum.Font.GothamBold
consoleTitle.TextSize = 13
consoleTitle.TextColor3 = C.text
consoleTitle.TextXAlignment = Enum.TextXAlignment.Left
consoleTitle.Parent = consoleHeader
local accentBar = Instance.new("Frame")
accentBar.BackgroundColor3 = C.accent
accentBar.BorderSizePixel = 0
accentBar.Position = UDim2.fromOffset(0, 35)
accentBar.Size = UDim2.new(1, 0, 0, 1)
accentBar.Parent = consoleWin

local function headerIcon(text, x, onClick)
	local b = Instance.new("TextButton")
	b.Text = text
	b.Font = Enum.Font.GothamBold
	b.TextSize = 14
	b.TextColor3 = C.dim
	b.BackgroundTransparency = 1
	b.Size = UDim2.fromOffset(28, 28)
	b.Position = UDim2.new(1, x, 0, 4)
	b.Parent = consoleWin
	b.MouseEnter:Connect(function() b.TextColor3 = C.accent end)
	b.MouseLeave:Connect(function() b.TextColor3 = C.dim end)
	b.MouseButton1Click:Connect(onClick)
end

local consoleList = Instance.new("ScrollingFrame")
consoleList.Position = UDim2.fromOffset(0, 37)
consoleList.Size = UDim2.new(1, 0, 1, -37)
consoleList.BackgroundTransparency = 1
consoleList.BorderSizePixel = 0
consoleList.CanvasSize = UDim2.new()
consoleList.AutomaticCanvasSize = Enum.AutomaticSize.Y
consoleList.ScrollBarThickness = 3
consoleList.ScrollBarImageColor3 = C.accent
consoleList.Parent = consoleWin
local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 3)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = consoleList
local listPad = Instance.new("UIPadding")
listPad.PaddingLeft, listPad.PaddingRight = UDim.new(0, 12), UDim.new(0, 12)
listPad.PaddingTop, listPad.PaddingBottom = UDim.new(0, 8), UDim.new(0, 8)
listPad.Parent = consoleList

-- Arrastrar la consola por su cabecera
do
	local dragging, startPos, startMouse
	consoleHeader.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging, startPos, startMouse = true, consoleWin.Position, i.Position
		end
	end)
	table.insert(cleanup, UIS.InputChanged:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = i.Position - startMouse
			consoleWin.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end))
	table.insert(cleanup, UIS.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
	end))
end

local MAX_LINES = 150
local lines, lineCount = {}, 0
local LEVEL_COLOR = { info = C.text, ok = C.on, warn = C.warn, error = C.err }
local consoleShown = false
local function setConsole(show)
	consoleShown = show
	consoleWin.Visible = show
end
headerIcon("×", -34, function() setConsole(false) end)
headerIcon("⌫", -64, function()
	for _, l in lines do l:Destroy() end
	table.clear(lines)
end)

-- Escribe en la consola. Avisa con una notificación los errores siempre, y lo demás si las notificaciones
-- están activadas y es un aviso o algo importante (notify = true). No avisar cosas repetitivas.
local function log(msg, level, notify)
	print("[El Hoyo Hub] " .. msg)
	if not alive then return end
	level = level or "info"
	lineCount += 1
	local line = Instance.new("TextLabel")
	line.Text = os.date("%H:%M:%S") .. "  " .. msg
	line.TextColor3 = LEVEL_COLOR[level] or C.text
	line.Font = Enum.Font.Code
	line.TextSize = 13
	line.TextWrapped = true
	line.TextXAlignment = Enum.TextXAlignment.Left
	line.BackgroundTransparency = 1
	line.Size = UDim2.new(1, 0, 0, 0)
	line.AutomaticSize = Enum.AutomaticSize.Y
	line.LayoutOrder = lineCount
	line.Parent = consoleList
	table.insert(lines, line)
	if #lines > MAX_LINES then table.remove(lines, 1):Destroy() end
	task.defer(function()
		consoleList.CanvasPosition = Vector2.new(0, consoleList.AbsoluteCanvasSize.Y)
	end)
	if UI.Notify and (level == "error" or (config.notify and (notify or level == "warn"))) then
		local title = level == "error" and "Error" or level == "warn" and T("Aviso", "Warning") or "El Hoyo Hub"
		pcall(UI.Notify, UI, title, msg)
	end
end

------------------------------------------------------------------ Ventana y pestañas
local win = UI:CreateWindow({ Folder = "ElHoyoHub", ToggleKey = false })
local main = win.frame
local function syncLang()
	LANG = UI.Language == 1 and "es" or "en"
	consoleTitle.Text = T("Consola", "Console")
end
win.onLanguage = syncLang
syncLang()

local pages = {}
local function addTab(label, icon)
	local page = { tab = win:Tab({ Name = uiText(label), Icon = icon }), boxes = {}, byName = {}, current = nil }
	table.insert(pages, page)
	return page
end

-- Cada sección es una caja; se reparten en dos columnas por orden (o en la columna que se diga). Repetir un
-- nombre vuelve a esa caja.
local function section(page, label, column)
	local key = type(label) == "table" and label.en or label
	local box = page.byName[key]
	if not box then
		box = page.tab:Box({ Name = uiText(label), Column = column or ((#page.boxes % 2) + 1), Scrollable = true })
		table.insert(page.boxes, box)
		page.byName[key] = box
	end
	page.current = box
	return box
end

local function boxFor(target)
	if target.grid then target = target.page end
	return target.current or section(target, "General")
end

-- Listas de botones (teleports, GUIs): van en la caja de la sección actual
local function grid(page)
	return { grid = true, page = page }
end

local function note(page, text)
	return boxFor(page):Label(uiText(text))
end

-- Todos los interruptores por nombre (en español): para "Apagar todo"
local toggles = {}

-- Interruptor. onChange(estado) al pulsarlo o al cargar un perfil; .set(v) lo cambia sin llamar a onChange.
-- noSave = es un ajuste, no una función (no entra en perfiles ni en "Apagar todo").
local function toggle(page, text, onChange, desc, noSave)
	local obj = { value = false, onChange = onChange, noSave = noSave }
	local o = {
		Name = uiText(text),
		Tip = desc and uiText(desc) or nil,
		Callback = function(v)
			obj.value = v
			task.spawn(onChange, v)
		end,
	}
	if noSave then o.Flag = false end
	local control = boxFor(page):Toggle(o)
	function obj.set(v)
		obj.value = v == true
		control:Set(obj.value, true)
	end
	toggles[type(text) == "table" and text.es or text] = obj
	return obj
end

local function button(parent, text, onClick, desc)
	return boxFor(parent):Button({ Name = uiText(text), Callback = onClick, Tip = desc and uiText(desc) or nil })
end

-- Lista desplegable de una opción. onPick(índice). Se guarda en config, no en los perfiles.
local function combo(page, text, options, default, onPick, desc)
	local names = {}
	for i, opt in options do names[i] = uiText(opt) end
	return boxFor(page):Combo({
		Name = uiText(text), Options = names, Default = default, Flag = false,
		Tip = desc and uiText(desc) or nil, Callback = function(_, i) onPick(i) end,
	})
end

-- Lista desplegable de varias opciones. onChange(tabla índice -> true/false).
local function multi(page, text, options, defaults, onChange, desc)
	local names = {}
	for i, opt in options do names[i] = uiText(opt) end
	return boxFor(page):Multi({
		Name = uiText(text), Options = names, Default = defaults, Flag = false,
		Tip = desc and uiText(desc) or nil, Callback = onChange,
	})
end

local function input(page, text, placeholder, default, onDone, desc)
	return boxFor(page):Input({ Name = uiText(text), Placeholder = uiText(placeholder), Default = default, Callback = onDone, Tip = desc and uiText(desc) or nil })
end

win:Group(uiText(L("FARMEO", "FARMING")))
local pageAuto = addTab(L("Automatización", "Automation"), "BOLT")
local pageTrain = addTab("Train", "FIRE")
local pageQuest = addTab(L("Misiones", "Quests"), "AWARD")
local pageFruits = addTab(L("Frutas", "Fruits"), "GEM")
win:Group(uiText(L("MUNDO", "WORLD")))
local pageTp = addTab("Teleports", "GLOBE")
local pageGuis = addTab("GUIs", "TH_LARGE")
win:Group("HUB")
local pageMisc = addTab("Misc", "SLIDERS_H")
local pageSettings = addTab(L("Ajustes", "Settings"), "COG")

-- Antes de terminar la ventana: si las cajas de una columna no caben en la página, se reparten el alto
-- según lo que ocupa cada una (todas tienen scroll, así que no se pierde nada).
local PAGE_H = 509 -- alto útil de una página de la librería
local function fitBoxes()
	for _, page in pages do
		local columns = { {}, {} }
		for _, box in page.boxes do table.insert(columns[box.column], box) end
		for _, list in columns do
			local available = PAGE_H - 8 * math.max(0, #list - 1)
			local natural, total = {}, 0
			for i, box in list do
				natural[i] = box.flow.y - box.spacing + box.padY + 18
				total += natural[i]
			end
			if total > available then
				for i, box in list do box.height = math.floor(math.max(80, available * natural[i] / total)) end
			end
		end
	end
end

------------------------------------------------------------------ Utilidades del juego
local function getHRP()
	return player.Character and player.Character:FindFirstChild("HumanoidRootPart")
end

-- shortcut: teletransporte directo; si el juego te expulsa por distancia, cambiar a ir por tramos
local function teleport(pos)
	local hrp = getHRP()
	if hrp then hrp.CFrame = CFrame.new(pos) end
end

-- Solo una función puede moverte a la vez (Sam, Chest, Train). Sin esto, Auto Sam te sacaba del dojo
-- en mitad de una partida y Auto Chest te movía cada medio segundo.
local busy -- nombre de la función que te está moviendo, o nil
local function claimMove(name)
	if busy and busy ~= name then return false end
	busy = name
	return true
end
local function releaseMove(name)
	if busy == name then busy = nil end
end

-- Zona segura: plataforma muy alta creada solo en tu cliente (los demás te ven flotando, no la ven).
-- Si está activa, las funciones que te mueven vuelven a ella en vez de a donde estabas.
local autoStone, autoKen = false, false -- Auto Train (se declaran aquí porque la zona segura los consulta)
local SAFE_HEIGHT = 5000 -- muy por encima de cualquier isla (la más alta ronda los 540) y fuera de la vista
local safePart
local function goSafe()
	local hrp = getHRP()
	if safePart and hrp then
		hrp.CFrame = safePart.CFrame + Vector3.new(0, 4, 0)
		hrp.AssemblyLinearVelocity = Vector3.zero
	end
end
local function returnTo(cf)
	if safePart then return goSafe() end
	local hrp = getHRP()
	if cf and hrp then hrp.CFrame = cf end
end

local function merchant(name)
	local map = workspace:FindFirstChild("Map")
	local merchants = map and map:FindFirstChild("Merchants")
	return merchants and merchants:FindFirstChild(name)
end

local function overOurGui()
	return isOver(main) or isOver(consoleWin)
end

-- ¿Hay un botón o casilla de texto del juego debajo del ratón?
local function overMenu()
	for _, obj in player.PlayerGui:GetGuiObjectsAtPosition(mouse.X, mouse.Y) do
		if (obj:IsA("GuiButton") or obj:IsA("TextBox")) and obj.Visible then return true end
	end
	return false
end

-- Clic real donde está el ratón (el juego hace su propio proceso: animación, señales...)
local function clickMouse()
	if overOurGui() or overMenu() or UIS:GetFocusedTextBox() then return end
	local pos = UIS:GetMouseLocation()
	VIM:SendMouseButtonEvent(pos.X, pos.Y, 0, true, game, 0)
	VIM:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 0)
end

------------------------------------------------------------------ Auto Haki
-- Cuanto más se activa, más se entrena: mientras esté ON se reactiva en cuanto se apaga.
-- Cada haki: señal para alternarlo, atributo que es true mientras está activo, atributo de energía
-- (baja sola) y atributo de máximo (si no existe o es 0, no tienes esa skill).
local HAKIS = {
	{ name = "Buso", remote = "ToggleArmament", energy = "HakiBuso", max = "HakiBusoMax",
		activeAttr = "Haki", -- confirmado: Haki = true solo con la armadura activa
		desc = L("Mantiene el haki de armadura activo y lo reactiva en cuanto se apaga. Así entrena y dura más.",
			"Keeps Armament haki on and turns it back on as soon as it drops. This trains it and makes it last longer.") },
	{ name = "Ken", remote = "ToggleObservation", energy = "HakiKen", max = "HakiKenMax",
		activeAttr = "UsingObs", -- confirmado: UsingObs = true con el Ken activo
		desc = L("Mantiene el haki de observación activo y lo reactiva en cuanto se apaga. Así entrena y dura más.",
			"Keeps Observation haki on and turns it back on as soon as it drops. This trains it and makes it last longer.") },
}

-- La señal alterna (enciende si está apagado, apaga si está encendido). Si dos funciones la envían casi
-- a la vez (Auto Buso y Auto Train), se anulan. Por eso todas pasan por aquí y se ignora una segunda
-- señal del mismo haki en menos de 2 s.
local hakiRemotes, lastHakiFire = {}, {}
for _, haki in HAKIS do hakiRemotes[haki.name] = getRemote("HakiService", "RE", haki.remote) end

local function toggleHaki(name)
	if os.clock() - (lastHakiFire[name] or -math.huge) < 2 then return false end
	lastHakiFire[name] = os.clock()
	local ok, err = call(hakiRemotes[name], "FireServer")
	if not ok then log(name .. ": error " .. tostring(err), "error") end
	return ok
end

local function hakiActive(haki)
	local char = player.Character
	return char ~= nil and char:GetAttribute(haki.activeAttr) == true
end

section(pageAuto, "Haki")
for _, haki in HAKIS do
	local enabled, noEnergyLogged = false, false

	local function hasSkill()
		local char = player.Character
		return char ~= nil and (char:GetAttribute(haki.max) or 0) > 0
	end

	local t
	t = toggle(pageAuto, "Auto " .. haki.name, function(on)
		if on and not hasSkill() then
			log(T("No tienes ", "You don't have ") .. haki.name .. " (" .. haki.max .. " = 0)", "warn")
			t.set(false)
			return
		end
		enabled = on
		log("Auto " .. haki.name .. " " .. (on and "ON" or "OFF"))
		if not on and hakiActive(haki) then toggleHaki(haki.name) end -- al apagar, lo quita
	end, haki.desc)

	task.spawn(function()
		while alive do
			task.wait(0.5)
			local char = player.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if enabled and hum and hum.Health > 0 and not hakiActive(haki) then
				if (char:GetAttribute(haki.energy) or 1) <= 0 then
					if not noEnergyLogged then log(haki.name .. T(": sin energía, espero a que se recargue", ": out of energy, waiting for it to recharge"), "warn") end
					noEnergyLogged = true
				else
					noEnergyLogged = false
					if toggleHaki(haki.name) then
						log(haki.name .. T(" reactivado", " reactivated"), "ok")
						task.wait(2)
					end
				end
			end
		end
	end)
end

------------------------------------------------------------------ Auto Click
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
local CLICK_DELAY = 0.1
local autoClick = false
section(pageAuto, L("Combate", "Combat"))
toggle(pageAuto, "Auto Click", function(on)
	autoClick = on
	log("Auto Click " .. (on and "ON" or "OFF"))
end, L("Hace clic donde está el ratón para atacar con lo que tengas equipado. Se pausa sobre menús y sobre el hub.",
	"Clicks where your mouse is to attack with whatever you have equipped. Pauses over menus and over the hub."))

task.spawn(function()
	while alive do
		task.wait(CLICK_DELAY)
		if autoClick then clickMouse() end
	end
end)

end

------------------------------------------------------------------ Auto Sam
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
local SAM_EVERY = 60 -- reintento si CompassTokenAt no dice nada
local claimRemote = getRemote("CompassQuestService", "RF", "Claim")
local treasureArrive = getRemote("TreasureService", "RE", "Arrive")
local autoSam = false

local function findCompass()
	for _, holder in { player.Character, player:FindFirstChild("Backpack") } do
		local tool = holder and holder:FindFirstChild("Compass")
		if tool and tool:GetAttribute("TreasureTarget") then return tool end
	end
end

local function useCompass(compass)
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if hum and compass.Parent ~= player.Character then
		hum:EquipTool(compass)
		task.wait(0.3)
	end
	compass:Activate()
	clickMouse()
end

local function tryClaim()
	local npc = merchant("QuestMerchant2") -- "Quest Man"
	if npc then
		teleport(npc:GetPivot().Position + Vector3.new(0, 3, 4))
		log(T("Sam: llevado a Quest Man", "Sam: taken to Quest Man"))
		task.wait(0.5)
	end
	local ok, result = call(claimRemote, "InvokeServer", 1)
	log(T("Sam: reclamar -> ", "Sam: claim -> ") .. tostring(result), ok and "info" or "error")
	task.wait(0.5)
end

-- Antes del primer viaje se apunta dónde estabas y qué arma tenías en la mano; al terminar te devuelve
-- ahí (o a la zona segura) y te vuelve a poner esa arma (si estaba Auto Click, sigue atacando con ella).
local samReturn, samPrevTool
local function samRemember()
	local hrp, char = getHRP(), player.Character
	if samReturn or not hrp then return end
	samReturn = hrp.CFrame
	local tool = char and char:FindFirstChildOfClass("Tool")
	samPrevTool = tool and tool.Name ~= "Compass" and tool or nil
end

local function samGoBack()
	if samReturn then
		returnTo(samReturn) -- a la zona segura si está activa
		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if hum then
			if samPrevTool and samPrevTool.Parent == player:FindFirstChild("Backpack") then
				hum:EquipTool(samPrevTool)
			elseif not samPrevTool then
				hum:UnequipTools() -- no llevabas nada: guardar el compass
			end
		end
		log(T("Sam: de vuelta a donde estabas", "Sam: back where you were"))
	end
	samReturn, samPrevTool = nil, nil
	releaseMove("Sam")
end

-- Va al tesoro, usa el compass y espera a que se gaste (o cambie de destino) como mucho 4 s.
-- Si tras 3 visitas el mismo destino sigue ahí, se deja ese destino para no ir y volver sin fin.
local triesOnTarget, lastTarget = 0, nil
local function goTreasure()
	local compass = findCompass()
	local target = compass and compass:GetAttribute("TreasureTarget")
	if not target then return end
	if target ~= lastTarget then triesOnTarget, lastTarget = 0, target end
	if triesOnTarget >= 3 then return end
	triesOnTarget += 1
	teleport(target + Vector3.new(0, 3, 0))
	log(T("Sam: llevado al tesoro", "Sam: taken to the treasure"))
	task.wait(0.5)
	call(treasureArrive, "FireServer") -- lo que manda el juego al llegar al tesoro (grabado)
	useCompass(compass)
	local t0 = os.clock()
	while os.clock() - t0 < 4 do
		local c = findCompass()
		if not c or c:GetAttribute("TreasureTarget") ~= target then break end
		task.wait(0.2)
	end
	local c = findCompass()
	if not c then
		log(T("Sam: compass reclamado", "Sam: compass claimed"), "ok", true)
	elseif c:GetAttribute("TreasureTarget") ~= target then
		log(T("Sam: el compass marca un destino nuevo", "Sam: the compass points to a new place"))
	elseif triesOnTarget >= 3 then
		log(T("Sam: no consigo reclamar este tesoro, lo dejo", "Sam: can't claim this treasure, giving up on it"), "warn")
	end
	samGoBack() -- siempre de vuelta tras usarlo; si hay destino nuevo, el siguiente ciclo vuelve a ir
end

section(pageAuto, L("Compass y cofres", "Compass & chests"))
toggle(pageAuto, "Auto Sam (compass)", function(on)
	autoSam = on
	if not on then samGoBack() end
	log("Auto Sam " .. (on and "ON" or "OFF"))
end, L("Cuando el compass está listo, va a Quest Man, lo reclama, te lleva al tesoro, lo usa y te devuelve a donde estabas con el arma que tenías.",
	"When the compass is ready, goes to Quest Man, claims it, takes you to the treasure, uses it and brings you back with the weapon you had."))

local lastTry = -math.huge
task.spawn(function()
	while alive do
		task.wait(1)
		if autoSam then
			local compass = findCompass()
			local pending = compass and (compass:GetAttribute("TreasureTarget") ~= lastTarget or triesOnTarget < 3)
			-- CompassTokenAt = hora del servidor a la que estará el siguiente compass
			local now = workspace:GetServerTimeNow()
			local token = player:GetAttribute("CompassTokenAt")
			local waiting = type(token) == "number" and token > now
			local mustClaim = not compass and not waiting and now - lastTry >= SAM_EVERY
			if (pending or mustClaim) and claimMove("Sam") then
				samRemember()
				if mustClaim then
					lastTry = now
					tryClaim()
				end
				if findCompass() then
					goTreasure()
				else
					samGoBack() -- no se pudo reclamar: volver igualmente
				end
			end
		end
	end
end)
end

------------------------------------------------------------------ Auto Chest
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
-- Velocidad elegible. "wait": tras teletransportarte, para que el servidor vea que estás al lado; "stay":
-- cuánto se queda insistiendo (toca y clica cada 0,25 s) hasta que el cofre desaparezca. A muy rápido casi
-- no se cogen; los que sigan ahí al acabar la ronda se reintentan en la siguiente.
local CHEST_SPEEDS = {
	{ name = L("Rápido", "Fast"), wait = 0.1, stay = 0.3 },
	{ name = "Normal", wait = 0.25, stay = 1.2 },
	{ name = L("Seguro", "Safe"), wait = 0.4, stay = 2.5 },
}
config.chestSpeed = math.clamp(tonumber(config.chestSpeed) or 2, 1, #CHEST_SPEEDS)
local autoChest = false
local tried = setmetatable({}, { __mode = "k" }) -- cofres ya intentados en esta ronda

local function chests()
	local inst = workspace:FindFirstChild("Instances")
	local folder = inst and inst:FindFirstChild("Chests")
	return folder and folder:GetChildren() or {}
end

local function nextChest()
	local hrp = getHRP()
	if not hrp then return end
	local best, bestDist, left = nil, math.huge, 0
	for _, c in chests() do
		if c:IsA("Model") and not tried[c] then
			left += 1
			local d = (c:GetPivot().Position - hrp.Position).Magnitude
			if d < bestDist then best, bestDist = c, d end
		end
	end
	return best, left
end

-- Un cofre se abre con su ClickDetector (EscaneoCofre: MaxActivationDistance = 10). No tiene toques ni
-- señales propias (EspiaRemotes no vio nada al abrirlo a mano), así que hay que estar a menos de 10 studs.
local function clickChest(chest)
	local cd = chest:FindFirstChildWhichIsA("ClickDetector", true)
	if not cd then return end
	if fireclickdetector then
		if not pcall(fireclickdetector, cd, 0) then pcall(fireclickdetector, cd) end -- según el executor
		return
	end
	-- Sin fireclickdetector: clic real sobre el cofre si se ve en pantalla
	local p, onScreen = workspace.CurrentCamera:WorldToViewportPoint(chest:GetPivot().Position)
	if onScreen then
		VIM:SendMouseButtonEvent(p.X, p.Y, 0, true, game, 0)
		VIM:SendMouseButtonEvent(p.X, p.Y, 0, false, game, 0)
	end
end

local function openChest(chest)
	tried[chest] = true
	local speed = CHEST_SPEEDS[config.chestSpeed]
	teleport(chest:GetPivot().Position + Vector3.new(0, 3, 0)) -- dentro de los 10 studs del clic
	task.wait(speed.wait) -- que el servidor vea que estás al lado antes de clicar
	local t0 = os.clock()
	repeat
		clickChest(chest)
		task.wait(0.25)
	until not chest.Parent or os.clock() - t0 >= speed.stay
end

toggle(pageAuto, "Auto Chest", function(on)
	autoChest = on
	if not on then releaseMove("Chest") end
	log("Auto Chest " .. (on and "ON" or "OFF"))
end, L("Recorre los cofres del mapa del más cercano al más lejano y los abre lo más rápido posible.",
	"Goes through the chests on the map from nearest to farthest and opens them as fast as possible."))

-- Velocidad de Auto Chest
do
	local speedNames = {}
	for i, sp in CHEST_SPEEDS do speedNames[i] = sp.name end
	combo(pageAuto, L("Velocidad de cofres", "Chest speed"), speedNames, config.chestSpeed, function(i)
		config.chestSpeed = i
		saveConfig()
	end, L("Velocidad de Auto Chest. Si se salta muchos cofres, usa una más lenta.", "Auto Chest speed. If it skips many chests, use a slower one."))
end

local chestStart -- dónde estabas antes de empezar la ronda de cofres
local attempted = {} -- cofres visitados en esta ronda (para contar cuántos se abrieron)
task.spawn(function()
	while alive do
		if not autoChest then
			task.wait(0.5)
		else
			local chest = nextChest()
			if chest and claimMove("Chest") then
				local hrp = getHRP()
				if not chestStart and hrp then chestStart = hrp.CFrame end
				table.insert(attempted, chest)
				openChest(chest)
				releaseMove("Chest") -- se suelta en cada cofre para que Sam pueda colarse entre medias
			elseif chest then
				task.wait(0.2) -- otra función te está moviendo
			else
				-- Fin de ronda: contar, volver y empezar otra
				local opened = 0
				for _, c in attempted do
					if not c.Parent then opened += 1 end
				end
				if #attempted > 0 then
					returnTo(chestStart)
					log(T("Chest: ronda terminada, abiertos ", "Chest: round finished, opened ") .. opened .. "/" .. #attempted,
						opened > 0 and "ok" or "info", opened > 0)
				end
				releaseMove("Chest")
				table.clear(tried)
				-- Sin cofres: esperar a que aparezcan. Si ninguno se abrió, no machacar al servidor.
				task.wait(#attempted == 0 and 5 or opened == 0 and 3 or 0.3)
				chestStart = nil
				table.clear(attempted)
			end
		end
	end
end)
end

------------------------------------------------------------------ Auto Gifts
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
-- DailyRewardService.RF.ClaimAll: reclama todos los regalos disponibles de golpe
local GIFT_EVERY = 60
local autoGifts = false
local claimAllGifts = getRemote("DailyRewardService", "RF", "ClaimAll")

local function claimGifts()
	local ok, result = call(claimAllGifts, "InvokeServer")
	if not ok then
		log("Gifts: error " .. tostring(result), "error")
	elseif result then
		log(T("Gifts: reclamado -> ", "Gifts: claimed -> ") .. tostring(result), "ok", true)
	end
end

section(pageAuto, L("Farmeo", "Farming"))
toggle(pageAuto, "Auto Gifts", function(on)
	autoGifts = on
	log("Auto Gifts " .. (on and "ON" or "OFF"))
	if on then claimGifts() end
end, L("Reclama los regalos diarios y por hora al encenderlo y después cada minuto.",
	"Claims the daily and hourly rewards when turned on and then every minute."))

task.spawn(function()
	while alive do
		task.wait(GIFT_EVERY)
		if autoGifts then claimGifts() end
	end
end)

end

------------------------------------------------------------------ Auto Pesca
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
-- Grabado con EspiaRemotes (una pesca a mano):
--   Cast(Vector3 del agua) -> Reel(false) -> el servidor manda MinigameStarted("Easy", "Scatter")
--   -> el cliente manda Hit(1..10) (en cualquier orden; Miss() si falla uno)
--   -> el servidor manda MinigameEnded(nota, "Nombre del pez"). La nota es cuántos acertaste (10 = Perfect).
-- shortcut: no se sabe cuándo pica; se manda Reel(false) cada 2 s hasta que empieza el minijuego (25 s máx.).
-- Solo se ha visto el minijuego "Scatter" con 10 objetivos; otros tipos se apuntan en la consola.
local FISH_RING_CLOSE = 1.1 -- se pulsa cuando el anillo mide como mucho 1,1 veces el objetivo
local FISH_REACTION = 0.3 -- tras picar, antes de recoger
local fishCast = getRemote("FishingService", "RE", "Cast")
local fishReel = getRemote("FishingService", "RE", "Reel")
local fishHit = getRemote("FishingService", "RE", "Hit")
local fishStarted = getRemote("FishingService", "RE", "MinigameStarted")
local fishEnded = getRemote("FishingService", "RE", "MinigameEnded")

local autoFish = false
local minigame -- {difficulty, kind} mientras dura el minijuego
local seenKinds = {}
local fishToggle

if fishStarted then
	table.insert(cleanup, fishStarted.OnClientEvent:Connect(function(difficulty, kind)
		minigame = { difficulty = difficulty, kind = kind }
		if autoFish and not seenKinds[kind] then
			seenKinds[kind] = true
			log(T("Pesca: minijuego ", "Fishing: minigame ") .. tostring(difficulty) .. " / " .. tostring(kind))
		end
	end))
end
if fishEnded then
	table.insert(cleanup, fishEnded.OnClientEvent:Connect(function(score, fish)
		minigame = nil
		if autoFish then
			log(T("Pesca: ", "Fishing: ") .. tostring(fish) .. " (" .. tostring(score) .. "/10)", "ok")
		end
	end))
end

-- Equipa la caña (cualquier objeto con "rod" en el nombre)
local function equipRod()
	local char, backpack = player.Character, player:FindFirstChild("Backpack")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then return false end
	local held = char:FindFirstChildOfClass("Tool")
	if held and held.Name:lower():find("rod") then return true end
	for _, tool in backpack and backpack:GetChildren() or {} do
		if tool:IsA("Tool") and tool.Name:lower():find("rod") then
			hum:EquipTool(tool)
			task.wait(0.3)
			return true
		end
	end
	return false
end

-- Punto de lanzamiento: donde apunta el ratón, como hace el juego al lanzar con clic (en tu grabación el
-- punto estaba a Y 137, por debajo del suelo de las islas, así que el agua no es agua de Terrain y no se
-- puede detectar por material). Hay que dejar el ratón apuntando al agua.
-- El ratón atraviesa el mar (mouse.Hit daba ~10000 studs apuntando al agua), así que se calcula dónde corta
-- el rayo del ratón con la superficie del mar. Altura: la de una pieza llamada agua/mar/océano si existe; si
-- no, la del lanzamiento grabado (Y 137,7).
local FISH_MAX_RANGE = 1000
local SEA_LEVEL = 137.7
do
	local biggest
	for _, d in workspace:GetDescendants() do
		if d:IsA("BasePart") then
			local n = d.Name:lower()
			if (n:find("water") or n:find("ocean") or n == "sea") and (not biggest or d.Size.Magnitude > biggest.Size.Magnitude) then
				biggest = d
			end
		end
	end
	if biggest and biggest.Size.X > 500 then SEA_LEVEL = biggest.Position.Y + biggest.Size.Y / 2 end
end

local function castPoint()
	local hrp = getHRP()
	if not hrp then return nil, "sin personaje" end
	local ray = mouse.UnitRay
	if ray.Direction.Y >= -0.01 then return nil, T("el ratón apunta por encima del horizonte", "the mouse points above the horizon") end
	local t = (SEA_LEVEL - ray.Origin.Y) / ray.Direction.Y
	if t < 0 then return nil, T("estás por debajo del nivel del mar", "you are below sea level") end
	local p = ray.Origin + ray.Direction * t
	local d = (p - hrp.Position).Magnitude
	if d > FISH_MAX_RANGE then return nil, string.format(T("el punto del mar está a %d studs", "the sea point is %d studs away"), d) end
	return p
end

section(pageAuto, L("Farmeo", "Farming"))
-- Sitio de pesca guardado (config.fishSpot = { stand = {x,y,z,rotación}, cast = {x,y,z} }). Si existe, Auto Pesca
-- te lleva ahí y lanza a ese punto, sin depender del ratón: así puede pescar solo (p. ej. para Auto Quest).
local function savedSpot()
	local spot = config.fishSpot
	if type(spot) ~= "table" or type(spot.stand) ~= "table" or type(spot.cast) ~= "table" then return nil end
	local st, ca = spot.stand, spot.cast
	return CFrame.new(st[1], st[2], st[3]) * CFrame.Angles(0, st[4] or 0, 0), Vector3.new(ca[1], ca[2], ca[3])
end

fishToggle = toggle(pageAuto, L("Auto Pesca (beta)", "Auto Fishing (beta)"), function(on)
	autoFish = on
	if not on then releaseMove("Fish") end
	log(on and (T("Auto Pesca ON: deja el ratón apuntando al agua", "Auto Fishing ON: keep the mouse pointing at the water") .. string.format(T(" (mar a Y %.1f)", " (sea at Y %.1f)"), SEA_LEVEL)) or T("Auto Pesca OFF", "Auto Fishing OFF"))
end, L("Lanza donde apunta tu ratón, espera a que pique y acierta los 10 objetivos del minijuego. Deja el ratón apuntando al agua y ten una caña en el inventario.",
	"Casts where your mouse points, waits for a bite and hits all 10 minigame targets. Keep the mouse pointing at the water and have a rod in your inventory."))

button(pageAuto, L("Guardar sitio de pesca aquí", "Save fishing spot here"), function()
	local hrp = getHRP()
	local p, why = castPoint()
	if not (hrp and p) then
		return log(T("Pesca: para guardar el sitio, apunta con el ratón al agua (", "Fishing: to save the spot, point the mouse at the water (") .. tostring(why) .. ")", "warn")
	end
	local _, yaw = hrp.CFrame:ToOrientation()
	config.fishSpot = { stand = { hrp.Position.X, hrp.Position.Y, hrp.Position.Z, yaw }, cast = { p.X, p.Y, p.Z } }
	saveConfig()
	log(T("Pesca: sitio guardado. Auto Pesca y Auto Quest pescarán aquí", "Fishing: spot saved. Auto Fishing and Auto Quest will fish here"), "ok", true)
end, L("Ponte en la orilla, apunta con el ratón al agua y púlsalo: Auto Pesca irá siempre aquí y lanzará a ese punto, sin necesitar el ratón.",
	"Stand on the shore, point the mouse at the water and press it: Auto Fishing will always come here and cast at that point, without needing the mouse."))
button(pageAuto, L("Borrar sitio de pesca", "Clear fishing spot"), function()
	config.fishSpot = nil
	saveConfig()
	releaseMove("Fish")
	log(T("Pesca: sitio borrado; vuelve a lanzar donde apunte el ratón", "Fishing: spot cleared; it casts where the mouse points again"), "ok", true)
end, L("Olvida el sitio guardado: Auto Pesca vuelve a lanzar donde apunte el ratón.", "Forgets the saved spot: Auto Fishing casts where the mouse points again."))

local warned = false
local function fishOnce()
	if not equipRod() then
		log(T("Pesca: no tienes ninguna caña", "Fishing: you don't have a rod"), "warn")
		autoFish = false
		fishToggle.set(false)
		return
	end
	local standAt, spotCast = savedSpot()
	local point, why
	if standAt then
		-- Con sitio guardado: ir allí (si otra función no te está moviendo) y lanzar al punto guardado
		if not claimMove("Fish") then
			task.wait(1)
			return
		end
		local hrp = getHRP()
		if hrp and (hrp.Position - standAt.Position).Magnitude > 8 then
			hrp.CFrame = standAt
			task.wait(0.5)
		end
		releaseMove("Fish") -- se suelta ya: si Sam u otra función te mueve, luego te devuelve aquí
		point = spotCast
	else
		point, why = castPoint()
	end
	if not point then
		-- Aviso destacado solo la primera vez; el motivo concreto siempre en la consola
		log(T("Pesca: no lanzo: ", "Fishing: not casting: ") .. why, warned and "info" or "warn")
		warned = true
		task.wait(3)
		return
	end
	warned = false
			minigame = nil
			local ok, err = call(fishCast, "FireServer", point)
			log(ok and (T("Pesca: lanzando a ", "Fishing: casting at ") .. tostring(point)) or ("Pesca: error " .. tostring(err)), ok and "info" or "error")
			task.wait(1.5)
	-- Esperar a que pique: el personaje recibe el atributo FishingBite = true (EscaneoPesca: a los ~27 s de
	-- caer el flotador). Recoger antes recoge el sedal vacío.
	local t0 = os.clock()
	local char = player.Character
	while autoFish and char and char:GetAttribute("FishingBite") ~= true and os.clock() - t0 < 90 do task.wait(0.1) end
	if not autoFish then return end
	if not (char and char:GetAttribute("FishingBite") == true) then
		return log(T("Pesca: no picó en 90 s, vuelvo a lanzar", "Fishing: no bite in 90 s, casting again"), "warn")
	end
	task.wait(FISH_REACTION) -- como una persona: un momento después de que pique
	call(fishReel, "FireServer", false)
	local t1 = os.clock()
	while not minigame and os.clock() - t1 < 5 do task.wait(0.1) end
	if not minigame then
		return log(T("Pesca: recogí pero no empezó el minijuego", "Fishing: reeled in but the minigame didn't start"), "warn")
	end

	-- Minijuego Scatter: el objetivo (Fishing.Frame.Target) cambia de sitio y aparece un anillo ("Ring") que se
	-- cierra sobre él; hay que pulsar el objetivo cuando el anillo llega. Mandar Hit(n) a mano a destiempo no
	-- contaba, así que ahora se pulsa el propio botón del juego cuando el anillo ya ha cerrado: el juego mide el
	-- momento y manda Hit él solo. Si no se puede pulsar el botón, se manda Hit(n) como antes.
	local rings, hits = 0, 0
	local logged = false
	local function pressTarget(target, n)
		if target:IsA("GuiButton") and getconnections then
			for _, signal in { target.MouseButton1Down, target.MouseButton1Click, target.Activated } do
				local conns = getconnections(signal)
				if #conns > 0 then
					for _, c in conns do pcall(function() c:Fire() end) end
					return true
				end
			end
		end
		call(fishHit, "FireServer", n)
		return false
	end
	local conn = player.PlayerGui.DescendantAdded:Connect(function(ring)
		if ring.Name ~= "Ring" or not minigame then return end
		rings += 1
		local n = rings
		local target = ring.Parent
		task.spawn(function()
			local t0 = os.clock()
			local startSize = ring.AbsoluteSize.X
			-- esperar a que el anillo se cierre hasta el tamaño del objetivo (o como mucho 1,5 s)
			while ring.Parent and minigame and os.clock() - t0 < 1.5 do
				if target:IsA("GuiObject") and ring.AbsoluteSize.X <= target.AbsoluteSize.X * FISH_RING_CLOSE then break end
				task.wait()
			end
			if not logged then
				logged = true
				log(string.format(T("Pesca: anillo de %d px a %d px en %.2f s (objetivo %s de %d px)", "Fishing: ring %d px to %d px in %.2f s (target %s, %d px)"),
					startSize, ring.AbsoluteSize.X, os.clock() - t0, target.ClassName, target:IsA("GuiObject") and target.AbsoluteSize.X or 0))
			end
			if minigame then
				pressTarget(target, n)
				hits += 1
			end
		end)
	end)
	local t2 = os.clock()
	while minigame and os.clock() - t2 < 20 do task.wait(0.1) end
	conn:Disconnect()
	log(string.format(T("Pesca: anillos vistos %d, aciertos enviados %d", "Fishing: rings seen %d, hits sent %d"), rings, hits))
	if rings == 0 then
		log(T("Pesca: no vi ningún anillo; pásame la consola", "Fishing: I didn't see any ring; send me the console"), "warn")
	end
	minigame = nil
end

task.spawn(function()
	while alive do
		task.wait(0.5)
		if autoFish then
			local ok, err = pcall(fishOnce)
			if not ok then
				log(T("Pesca: error ", "Fishing: error ") .. tostring(err), "error")
				task.wait(3)
			end
		end
	end
end)

end

-- Quien da misiones en cada isla (cartel "Quests"); lo usan Auto Quest y Teleports
-- Pulsa un botón de la interfaz del juego como si le hicieras clic, para que el juego haga lo suyo
local function pressGuiButton(btn)
	if getconnections then
		for _, signal in { btn.MouseButton1Click, btn.Activated } do
			local conns = getconnections(signal)
			if #conns > 0 then
				for _, c in conns do pcall(function() c:Fire() end) end
				return
			end
		end
	end
	if firesignal then
		pcall(firesignal, btn.MouseButton1Click)
		return
	end
	-- Último recurso: clic real en el centro del botón (tiene que verse en pantalla)
	local p, s = btn.AbsolutePosition, btn.AbsoluteSize
	local inset = game:GetService("GuiService"):GetGuiInset()
	local x, y = p.X + s.X / 2, p.Y + s.Y / 2 + inset.Y
	VIM:SendMouseButtonEvent(x, y, 0, true, game, 0)
	VIM:SendMouseButtonEvent(x, y, 0, false, game, 0)
end

------------------------------------------------------------------ Entregas
-- Un objeto de misión que hay que llevar es una Tool con el atributo DeliveryTarget (Vector3 del destino); visto
-- con el paquete de Merlin. Lo usan Auto Merlin y Auto Quest (las misiones de Merlin salen en los dos).
local deliverRemote = getRemote("MerlinService", "RF", "Deliver")
local function heldPackage()
	for _, holder in { player:FindFirstChild("Backpack"), player.Character } do
		for _, t in holder and holder:GetChildren() or {} do
			if t:IsA("Tool") and typeof(t:GetAttribute("DeliveryTarget")) == "Vector3" then return t end
		end
	end
end
local function deliverPackage(package)
	teleport(package:GetAttribute("DeliveryTarget") + Vector3.new(0, 3, 4))
	task.wait(0.6)
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if hum and package.Parent ~= player.Character then
		hum:EquipTool(package) -- en la mano, por si el juego lo pide
		task.wait(0.3)
	end
	local ok, delivered = call(deliverRemote, "InvokeServer")
	log(T("Entrega de ", "Delivery of ") .. package.Name .. " -> " .. tostring(delivered), (ok and delivered) and "ok" or "warn", ok and delivered)
	return ok and delivered
end

local QUEST_GIVERS = {
	{ name = "Dockmaster Rolf", model = "QuestWindmill" },
	{ name = "Guard Captain Bram", model = "QuestTown" },
	{ name = "Old Pirate Gil", model = "QuestPirate" },
	{ name = "Farmer Otto", model = "QuestFarm" },
	{ name = "Beachcomber Lou", model = "QuestCrabIsle" },
	{ name = "Old Miner Gus", model = "QuestMountain" },
	{ name = "Sheriff Dale", model = "QuestCaver" },
	{ name = "Calm Bob", model = "QuestTreea" },
	{ name = "Mama Fredda", model = "QuestSandCastle" },
	{ name = "Hal the Deserter", model = "QuestMarine" },
	{ name = "Elder Moray", model = "QuestDeepwake" },
	{ name = "Climber Edda", model = "QuestCliffs" },
	{ name = "Hermit Oswin", model = "QuestPursuer" },
	{ name = "Merlin", model = "QuestFishMerchant" }, -- al final: config.questGiver guarda el número
}
------------------------------------------------------------------ Auto Quest
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
-- Lee la misión activa del rastreador del juego (PlayerGui.QuestTracker.Frame.Rows: Header y Objective1..)
-- y actúa según lo que diga. Por ahora entiende "Defeat <enemigo> (Lv N+): a/b": va a por ese enemigo en
-- Workspace.Alive.NPCs (se llaman "Lv12 Boar") y le ataca con clic real hasta completar el objetivo.
-- shortcut: aceptar y entregar misiones (QuestLogService) aún no está grabado; hay que hacerlo a mano.
local QUEST_DIST = 4 -- studs detrás del enemigo
local autoQuest = false

local function questObjectives()
	local qt = player.PlayerGui:FindFirstChild("QuestTracker")
	local frame = qt and qt:FindFirstChild("Frame")
	local rows = frame and frame:FindFirstChild("Rows")
	if not rows then return nil, {} end
	local header = rows:FindFirstChild("Header")
	local objs = {}
	for _, r in rows:GetChildren() do
		if r:IsA("TextLabel") and r.Name:match("^Objective") and r.Visible and r.Text ~= "" then
			table.insert(objs, { order = tonumber(r.Name:match("%d+")) or 0, text = r.Text })
		end
	end
	table.sort(objs, function(a, b) return a.order < b.order end)
	return header and header.Text or "", objs
end

-- "- Defeat Boar (Lv 10+): 0/5" -> "Boar", 10, 0, 5
local function parseDefeat(text)
	local name, lv, have, need = text:match("Defeat%s+(.-)%s*%(Lv%s*(%d+)%+?%)%s*:%s*(%d+)%s*/%s*(%d+)")
	if not name then name, have, need = text:match("Defeat%s+(.-)%s*:%s*(%d+)%s*/%s*(%d+)") end
	if not name then return nil end
	return name, tonumber(lv) or 0, tonumber(have), tonumber(need)
end
do -- comprobación con el texto real visto en el juego
	local n, lv, have, need = parseDefeat("- Defeat Boar (Lv 10+): 0/5")
	assert(n == "Boar" and lv == 10 and have == 0 and need == 5)
end

local function findEnemy(name, minLv)
	local aliveFolder = workspace:FindFirstChild("Alive")
	local npcs = aliveFolder and aliveFolder:FindFirstChild("NPCs")
	local hrp = getHRP()
	if not (npcs and hrp) then return end
	local want = name:lower()
	local best, bestDist
	for _, m in npcs:GetChildren() do
		local hum = m:FindFirstChildOfClass("Humanoid")
		local root = m:FindFirstChild("HumanoidRootPart")
		local clean = m.Name:gsub("^Lv%s*%d+%s*", ""):lower()
		local lv = tonumber(m.Name:match("^Lv%s*(%d+)")) or 0
		-- "Bandits" en la misión y "Bandit" en el enemigo también vale
		local same = clean == want or clean == want:gsub("s$", "") or clean .. "s" == want
		if hum and root and hum.Health > 0 and same and lv >= minLv then
			local d = (root.Position - hrp.Position).Magnitude
			if not bestDist or d < bestDist then best, bestDist = m, d end
		end
	end
	return best
end

-- Arma: la que tengas en la mano si es un arma; si no, la primera del inventario (Melee/Sword/Sniper)
local function equipWeapon()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then return end
	local held = char:FindFirstChildOfClass("Tool")
	if held and held:GetAttribute("WeaponSlot") and held:GetAttribute("WeaponSlot") ~= "Utility" then return end
	local backpack = player:FindFirstChild("Backpack")
	for _, tool in backpack and backpack:GetChildren() or {} do
		local slot = tool:IsA("Tool") and tool:GetAttribute("WeaponSlot")
		if slot and slot ~= "Utility" then
			hum:EquipTool(tool)
			task.wait(0.2)
			return
		end
	end
end

-- Se pone detrás del enemigo mirándole, apunta la cámara hacia él y hace clic real sobre él
-- (el ataque usa el punto del ratón; enviar Attack a mano no funciona)
local function attack(enemy)
	local root, hrp = enemy:FindFirstChild("HumanoidRootPart"), getHRP()
	if not (root and hrp) then return end
	local away = hrp.Position - root.Position
	away = away.Magnitude > 0.1 and Vector3.new(away.X, 0, away.Z).Unit or Vector3.new(0, 0, 1)
	hrp.CFrame = CFrame.lookAt(root.Position + away * QUEST_DIST, root.Position)
	local cam = workspace.CurrentCamera
	cam.CFrame = CFrame.lookAt(hrp.Position + away * 10 + Vector3.new(0, 4, 0), root.Position)
	local p, onScreen = cam:WorldToViewportPoint(root.Position)
	if onScreen then
		VIM:SendMouseMoveEvent(p.X, p.Y, game)
		VIM:SendMouseButtonEvent(p.X, p.Y, 0, true, game, 0)
		VIM:SendMouseButtonEvent(p.X, p.Y, 0, false, game, 0)
	end
end

-- Ventana del NPC de misiones (EscaneoGUI con Farmer Otto): PlayerGui.QuestGiver.Frame.Window.Body
--   List: botones "Quest<N>" (texto en su hijo "Text", p. ej. "! Out of the Pen"; "!" = disponible)
--   Next: botón con "Accept" (o lo que toque para entregar)
-- Se usa la propia ventana del juego: hablar con el NPC (ClickDetector de su parte Clickable), pulsar la misión y
-- pulsar el botón. Así no hace falta saber el id interno de cada misión (entregar grabado: Claim("FarmBoars")).
local function pressButton(btn)
	if getconnections then
		for _, signal in { btn.MouseButton1Click, btn.Activated, btn.MouseButton1Down } do
			local conns = getconnections(signal)
			if #conns > 0 then
				for _, c in conns do pcall(function() c:Fire() end) end
				return true
			end
		end
	end
	if firesignal then return pcall(firesignal, btn.MouseButton1Click) end
	return false
end

local function buttonText(btn)
	local t = btn:FindFirstChild("Text")
	if t and t:IsA("TextLabel") then return t.Text end
	return btn:IsA("TextButton") and btn.Text or ""
end

local function giverWindow()
	local qg = player.PlayerGui:FindFirstChild("QuestGiver")
	local frame = qg and qg:FindFirstChild("Frame")
	if not (frame and frame.Visible and (not qg:IsA("ScreenGui") or qg.Enabled)) then return nil end
	local window = frame:FindFirstChild("Window")
	return window and window:FindFirstChild("Body")
end

-- Va al NPC, le habla y espera a que se abra su ventana (3 s). Devuelve el cuerpo de la ventana.
local function openGiver(entry)
	local npc = merchant(entry.model)
	if not npc then
		log(T("Quest: no encuentro a ", "Quest: can't find ") .. entry.name, "warn")
		return nil
	end
	teleport(npc:GetPivot().Position + Vector3.new(0, 3, 4))
	task.wait(0.4)
	for _, d in npc:GetDescendants() do
		if d:IsA("ClickDetector") and fireclickdetector then fireclickdetector(d) end
	end
	local t0 = os.clock()
	while os.clock() - t0 < 3 do
		local body = giverWindow()
		if body then return body end
		task.wait(0.1)
	end
	log(T("Quest: no se abre la ventana de ", "Quest: the window of ") .. entry.name .. T("", " doesn't open"), "warn")
	return nil
end

local function questButtons(body)
	local list = body:FindFirstChild("List")
	local out = {}
	for _, b in list and list:GetChildren() or {} do
		if b:IsA("GuiButton") and b.Name:match("^Quest") and b.Visible then table.insert(out, b) end
	end
	table.sort(out, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
	return out
end

local function acceptQuest(entry)
	local body = openGiver(entry)
	if not body then return false end
	for _, b in questButtons(body) do
		if buttonText(b):match("^%s*!") then -- "!" = misión disponible
			pressButton(b)
			task.wait(0.5)
			local nextBtn = body:FindFirstChild("Next")
			if nextBtn and buttonText(nextBtn):lower():find("accept") then
				pressButton(nextBtn)
				task.wait(1)
				log(T("Quest: aceptada ", "Quest: accepted ") .. buttonText(b):gsub("^%s*!%s*", ""), "ok", true)
				return true
			end
		end
	end
	log(T("Quest: ", "Quest: ") .. entry.name .. T(" no tiene misiones disponibles ahora", " has no quests available right now"), "warn")
	return false
end

-- Entregar: abrir la ventana y pulsar lo que no sea "Accept" (y si hace falta, antes la misión)
local function claimQuest(entry)
	local body = openGiver(entry)
	if not body then return false end
	local function tryNext()
		local nextBtn = body:FindFirstChild("Next")
		local text = nextBtn and buttonText(nextBtn):lower() or ""
		if nextBtn and nextBtn.Visible and text ~= "" and not text:find("accept") then
			pressButton(nextBtn)
			task.wait(1)
			return true
		end
		return false
	end
	if tryNext() then return true end
	for _, b in questButtons(body) do
		if not buttonText(b):match("^%s*!") then
			pressButton(b)
			task.wait(0.5)
			if tryNext() then return true end
		end
	end
	log(T("Quest: no veo cómo entregar la misión en la ventana de ", "Quest: can't see how to turn the quest in at ") .. entry.name, "warn")
	return false
end

-- Objetivos "...: a/b" del rastreador
local function progressOf(text)
	local have, need = text:match("(%d+)%s*/%s*(%d+)%s*$")
	return tonumber(have), tonumber(need)
end

section(pageQuest, "Auto Quest")
toggle(pageQuest, "Auto Quest (beta)", function(on)
	autoQuest = on
	if not on then releaseMove("Quest") end
	log("Auto Quest " .. (on and "ON" or "OFF"))
end, L("Va al NPC elegido, acepta una misión, la hace (matar enemigos; pescar con Auto Pesca, quedándote en el agua) y vuelve a entregarla.",
	"Goes to the chosen NPC, accepts a quest, does it (defeating enemies; fishing with Auto Fishing, staying at the water) and comes back to turn it in."))
do
	local names = {}
	for i, g in QUEST_GIVERS do names[i] = g.name end
	config.questGiver = math.clamp(tonumber(config.questGiver) or 4, 1, #QUEST_GIVERS) -- 4 = Farmer Otto
	combo(pageQuest, L("NPC de misiones", "Quest giver"), names, config.questGiver, function(i)
		config.questGiver = i
		saveConfig()
	end, L("A quién pide y entrega las misiones Auto Quest.", "Who Auto Quest takes and turns in quests from."))
end

local lastStatus, questStart
local lastAcceptTry, lastClaimTry = -math.huge, -math.huge
local questFishing = false -- Auto Quest encendió Auto Pesca y la apagará al acabar ese objetivo

local function stopQuestFishing()
	if not questFishing then return end
	questFishing = false
	local fish = toggles["Auto Pesca (beta)"]
	if fish and fish.value then
		fish.set(false)
		task.spawn(fish.onChange, false)
	end
end
-- Un paso de Auto Quest. Va en pcall: si algo falla sale en la consola en vez de parar el bucle en silencio
local function questTick()
	local giver = QUEST_GIVERS[config.questGiver]
	local header, objs = questObjectives()

	-- Llevas algo que entregar (paquete de Merlin u otro con DeliveryTarget): primero eso
	local package = heldPackage()
	if package then
		if claimMove("Quest") then
			local hrp = getHRP()
			if not questStart and hrp then questStart = hrp.CFrame end
			deliverPackage(package)
			returnTo(questStart)
			questStart = nil
			releaseMove("Quest")
		end
		task.wait(1)
		return
	end

	-- Sin misión: ir a pedir una (como mucho cada 15 s)
	if #objs == 0 then
		if os.clock() - lastAcceptTry > 15 and claimMove("Quest") then
			lastAcceptTry = os.clock()
			local hrp = getHRP()
			if not questStart and hrp then questStart = hrp.CFrame end
			acceptQuest(giver)
			returnTo(questStart)
			questStart = nil
			releaseMove("Quest")
		end
		task.wait(1)
		return
	end

	-- ¿Qué objetivo falta? Derrotar enemigos o pescar. Si todos están a/b completos, entregar.
	local target, fishing, allDone = nil, false, true
	for _, o in objs do
		local have, need = progressOf(o.text)
		if have and need and have < need then
			allDone = false
			local name, lv = parseDefeat(o.text)
			if name and not target then target = { name = name, lv = lv, have = have, need = need } end
			if o.text:lower():find("catch") or o.text:lower():find("fish") then fishing = true end
		end
	end

	local status
	if allDone then
		status = T("Quest: completa, voy a entregarla a ", "Quest: done, turning it in to ") .. giver.name
	elseif target then
		status = string.format("Quest: %s %d/%d", target.name, target.have, target.need)
	elseif fishing then
		status = T("Quest: hay que pescar; uso Auto Pesca (quédate en el agua con el ratón sobre ella)",
			"Quest: fishing needed; using Auto Fishing (stay at the water with the mouse on it)")
	else
		local texts = {}
		for _, o in objs do table.insert(texts, o.text) end
		status = T("Quest: ", "Quest: ") .. tostring(header) .. " — " .. table.concat(texts, " · ") .. T(" (aún no sé hacer este tipo)", " (I can't do this type yet)")
	end
	if status ~= lastStatus then
		log(status, (target or fishing or allDone) and "info" or "warn")
		lastStatus = status
	end

	if allDone then
		stopQuestFishing()
		if os.clock() - lastClaimTry > 10 and claimMove("Quest") then
			lastClaimTry = os.clock()
			local hrp = getHRP()
			if not questStart and hrp then questStart = hrp.CFrame end
			if claimQuest(giver) then log(T("Quest: entregada", "Quest: turned in"), "ok", true) end
			returnTo(questStart)
			questStart = nil
			releaseMove("Quest")
		end
		task.wait(1)
		return
	end

	if fishing and not target then
		local fish = toggles["Auto Pesca (beta)"]
		if fish and not fish.value then
			fish.set(true)
			task.spawn(fish.onChange, true)
			questFishing = true
			if not config.fishSpot then
				log(T("Quest: no hay sitio de pesca guardado; pescará donde apunte el ratón", "Quest: no saved fishing spot; it will fish where the mouse points"), "warn")
			end
		end
		task.wait(2)
		return
	end
	stopQuestFishing()

	if not target then
		if questStart then
			returnTo(questStart)
			questStart = nil
		end
		releaseMove("Quest")
		task.wait(2)
		return
	end
	local enemy = findEnemy(target.name, target.lv)
	if not enemy then
		task.wait(1) -- todos muertos o lejos de cargar: esperar a que reaparezcan
		return
	end
	if not claimMove("Quest") then return end
	local hrp = getHRP()
	if not questStart and hrp then questStart = hrp.CFrame end
	equipWeapon()
	attack(enemy)
end

task.spawn(function()
	while alive do
		task.wait(0.25)
		if autoQuest then
			local ok, err = pcall(questTick)
			if not ok then
				log("Quest: error " .. tostring(err), "error")
				task.wait(3)
			end
		end
	end
end)
end

------------------------------------------------------------------ Auto Merlin
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
-- Paquetes de Merlin (grabado): MerlinService.RF.TakePackage() -> true junto a Merlin, y luego
-- MerlinService.RF.Deliver() -> true en el destino (en la grabación, en Pirate's Land, ~ -1253, 214, -1231).
-- Merlin es QuestFishMerchant (junto a Farmer Otto). shortcut: no sabemos cómo marca el juego el destino; se busca
-- como un atributo Vector3 nuevo en el jugador o el personaje tras coger el paquete; si no aparece, se prueba
-- en el sitio de la grabación. Lo que encuentre sale en la consola para fijarlo.
local takeRemote = getRemote("MerlinService", "RF", "TakePackage")
local autoMerlin = false
local merlinStart

local function findMerlin()
	local map = workspace:FindFirstChild("Map")
	local merchants = map and map:FindFirstChild("Merchants")
	if not merchants then return end
	return merchants:FindFirstChild("QuestFishMerchant") -- Merlin: junto a Farmer Otto (QuestFarm)
end

-- Todos los datos (atributos) del jugador, del personaje y de lo que llevas encima (por si el paquete es un
-- objeto con el destino dentro).
local function allAttrs()
	local out = {}
	local function grab(prefix, obj)
		for k, v in obj:GetAttributes() do out[prefix .. "@" .. k] = v end
	end
	grab("Jugador", player)
	local char = player.Character
	if char then grab("Personaje", char) end
	for _, holder in { player:FindFirstChild("Backpack"), char } do
		for _, t in holder and holder:GetChildren() or {} do
			if t:IsA("Tool") then grab("Objeto " .. t.Name, t) end
		end
	end
	return out
end

-- Un nombre de NPC o de isla -> su posición
local function placeNamed(text)
	if type(text) ~= "string" then return nil end
	local npc = merchant(text)
	if npc then return npc:GetPivot().Position end
	local map = workspace:FindFirstChild("Map")
	local islands = map and map:FindFirstChild("Islands")
	local island = islands and islands:FindFirstChild(text)
	if island then
		local target = island:FindFirstChild("QuestBoard") or island:FindFirstChildWhichIsA("BasePart", true)
		if target then return target:GetPivot().Position end
	end
end

local function merlinRound()
	local merlin, hrp = findMerlin(), getHRP()
	if not (merlin and hrp) then
		log(T("Merlin: no encuentro a Merlin (QuestFishMerchant)", "Merlin: can't find Merlin (QuestFishMerchant)"), "warn")
		return false
	end
	if not merlinStart then merlinStart = hrp.CFrame end
	-- ¿Ya lo llevabas (de antes del hub o de una vuelta que falló)? Merlin no da otro: se entrega ese.
	local package = heldPackage()
	local dest, how
	if package then
		dest, how = package:GetAttribute("DeliveryTarget"), T("paquete que ya tenías", "package you already had")
	else
		teleport(merlin:GetPivot().Position + Vector3.new(0, 3, 4))
		task.wait(0.6)

		-- Mientras se coge el paquete, apuntar qué aparece en el mapa y en la pantalla
		local before = allAttrs()
		local appeared = {}
		local watch = {
			workspace.DescendantAdded:Connect(function(d)
				local alive = workspace:FindFirstChild("Alive")
				if not (alive and d:IsDescendantOf(alive)) and #appeared < 40 then table.insert(appeared, d) end
			end),
		}
		local ok, took = call(takeRemote, "InvokeServer")
		if not (ok and took) then
			for _, c in watch do c:Disconnect() end
			log(T("Merlin: no me da paquete (", "Merlin: no package (") .. tostring(took) .. ")")
			return false
		end
		task.wait(1.5)
		for _, c in watch do c:Disconnect() end

		-- 0) Lo confirmado (EscaneoPersonaje con el paquete encima): el paquete es una Tool "Package" con el atributo
		--    DeliveryTarget = Vector3 del destino (en esa prueba, el comprador de frutas al lado de Sam). Puede tardar
		--    un poco en llegar al inventario.
		local t0 = os.clock()
		repeat
			package = heldPackage()
			if not package then task.wait(0.2) end
		until package or os.clock() - t0 > 3
		if package then dest, how = package:GetAttribute("DeliveryTarget"), "Package@DeliveryTarget" end

		-- 1) Si no: un dato nuevo o cambiado (una posición, o el nombre de un NPC o de una isla)
		for k, v in allAttrs() do
			if before[k] ~= v then
				log("Merlin: " .. T("dato nuevo ", "new data ") .. k .. " = " .. tostring(v))
				if not dest and typeof(v) == "Vector3" then dest, how = v, k end
				if not dest and placeNamed(v) then dest, how = placeNamed(v), k .. " (" .. v .. ")" end
			end
		end
		-- 2) Algo que haya aparecido en el mapa con pinta de marca de entrega
		for _, d in appeared do
			local n = d.Name:lower()
			local looksLikeMarker = n:find("package") or n:find("deliver") or n:find("merlin") or n:find("marker")
				or n:find("waypoint") or n:find("beacon") or n:find("target") or n:find("drop")
			if looksLikeMarker then
				log("Merlin: " .. T("apareció ", "appeared ") .. d:GetFullName() .. " [" .. d.ClassName .. "]")
				if not dest and (d:IsA("BasePart") or d:IsA("Model")) then dest, how = d:GetPivot().Position, d:GetFullName() end
			end
		end
	end
	if not dest then
		log(T("Merlin: tengo el paquete pero no sé dónde entregarlo. Pásame lo de arriba de la consola y EscaneoPersonaje con el paquete encima",
			"Merlin: I have the package but don't know where to deliver it. Send me the console lines above and EscaneoPersonaje with the package on you"), "warn")
		return false
	end
	log(T("Merlin: destino ", "Merlin: destination ") .. how .. " -> " .. tostring(dest))
	if package then return deliverPackage(package) end
	teleport(dest + Vector3.new(0, 3, 4))
	task.wait(0.6)
	-- con el paquete en la mano, por si el juego lo pide
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if package and hum and package.Parent ~= player.Character then
		hum:EquipTool(package)
		task.wait(0.3)
	end
	local ok2, delivered = call(deliverRemote, "InvokeServer")
	log(T("Merlin: entrega -> ", "Merlin: delivery -> ") .. tostring(delivered), (ok2 and delivered) and "ok" or "warn", ok2 and delivered)
	return ok2 and delivered
end

section(pageQuest, "Merlin")
toggle(pageQuest, "Auto Merlin (beta)", function(on)
	autoMerlin = on
	if not on then
		if merlinStart then returnTo(merlinStart) end
		merlinStart = nil
		releaseMove("Merlin")
	end
	log("Auto Merlin " .. (on and "ON" or "OFF"))
end, L("Coge un paquete de Merlin, lo entrega y repite. Cada entrega cuenta para las misiones de Expertise.",
	"Takes a package from Merlin, delivers it and repeats. Each delivery counts for Expertise missions."))

task.spawn(function()
	while alive do
		task.wait(1)
		local cooldown = player:GetAttribute("MerlinCooldownEnd") -- hora del servidor en la que Merlin vuelve a dar paquete
		local waiting = type(cooldown) == "number" and cooldown > workspace:GetServerTimeNow() and not heldPackage()
		if autoMerlin and not waiting and claimMove("Merlin") then
			local ok, delivered = pcall(merlinRound)
			if not ok then log("Merlin: error " .. tostring(delivered), "error") end
			-- tras cada vuelta, de regreso a donde estabas (o a la zona segura) hasta el siguiente paquete
			if merlinStart then returnTo(merlinStart) end
			merlinStart = nil
			releaseMove("Merlin")
			if not (ok and delivered) then task.wait(5) end
		end
	end
end)
end

------------------------------------------------------------------ Zona segura
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
local safeBack -- dónde estabas al encenderla
section(pageAuto, L("Zona segura", "Safe zone"))
toggle(pageAuto, L("Zona segura", "Safe zone"), function(on)
	local hrp = getHRP()
	if on then
		if not hrp then return end
		safeBack = hrp.CFrame
		safePart = Instance.new("Part") -- solo en tu cliente: el servidor y los demás no la ven
		safePart.Name = "ElHoyoHubSafeZone"
		safePart.Anchored = true
		safePart.Size = Vector3.new(40, 2, 40)
		safePart.Transparency = 0.6
		safePart.Color = C.accent
		safePart.Material = Enum.Material.ForceField
		safePart.CFrame = CFrame.new(hrp.Position.X, SAFE_HEIGHT, hrp.Position.Z)
		safePart.Parent = workspace
		goSafe()
		log(T("Zona segura: en el aire, a ", "Safe zone: up in the air, at ") .. SAFE_HEIGHT .. " studs", "ok", true)
	else
		if safePart then safePart:Destroy() end
		safePart = nil
		if hrp and safeBack then hrp.CFrame = safeBack end
		safeBack = nil
		log(T("Zona segura apagada", "Safe zone off"))
	end
end, L("Crea una plataforma muy alta que solo ves tú y te deja ahí para farmear. Sam, Chest y Frutas vuelven a ella al terminar. Al apagarla vuelves a donde estabas.",
	"Creates a very high platform only you can see and keeps you there to farm. Sam, Chest and Fruits come back to it when done. Turning it off brings you back."))
table.insert(cleanup, { Disconnect = function() if safePart then safePart:Destroy() end end }) -- se quita al cerrar el hub

-- Si caes o te mueven y nadie más te está moviendo, vuelves a la plataforma
task.spawn(function()
	while alive do
		task.wait(2)
		local hrp = getHRP()
		if safePart and hrp and not busy and not autoStone and not autoKen
			and (hrp.Position - safePart.Position).Magnitude > 40 then
			goSafe()
		end
	end
end)

note(pageAuto, L("Auto Sam, Auto Chest, Auto Train y Frutas te mueven por el mapa: si hay varios encendidos, se turnan.",
	"Auto Sam, Auto Chest, Auto Train and Fruits move you around the map: if several are on, they take turns."))

end

------------------------------------------------------------------ Train
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
section(pageTrain, "Haki")
button(pageTrain, L("Ir con Silvers Rayleigh", "Go to Silvers Rayleigh"), function()
	local npc = merchant("QuestHakiMerchant")
	if not npc then return log(T("No encuentro a Silvers Rayleigh", "Can't find Silvers Rayleigh"), "warn") end
	teleport(npc:GetPivot().Position + Vector3.new(0, 3, 4))
	log(T("Llevado con Silvers Rayleigh", "Taken to Silvers Rayleigh"))
end, L("Te lleva junto a Silvers Rayleigh, en lo alto de Mountain Island.", "Takes you to Silvers Rayleigh, at the top of Mountain Island."))
-- Stone Breaker (HakiDojoService). Sacado de una partida grabada:
--   Game("Rock", {T0, Period, Center, Zone, Left, EndsAt}) -> roca nueva
--   Strike(tiempo del servidor) -> Game("Strike", {Result = Perfect/Good/Miss, Center nuevo, Left, EndsAt})
-- La aguja va y viene entre 0 y 1: u = (t - T0) / Period, posición = u mod 2 (si pasa de 1, 2 - eso).
-- Se golpea justo cuando la aguja pasa por Center (el centro de la zona vale doble).
local dojoStart = getRemote("HakiDojoService", "RF", "Start")
local dojoStrike = getRemote("HakiDojoService", "RE", "Strike")
local dojoGame = getRemote("HakiDojoService", "RE", "Game")

local function needle(r, t)
	local u = ((t - r.T0) / r.Period) % 2
	return u <= 1 and u or 2 - u
end
-- Comprobación con la partida grabada: golpe en 470.983784 dio Perfect con Center 0.608
assert(math.abs(needle({ T0 = 468.859585, Period = 1.51 }, 470.983784) - 0.5932) < 0.001)

-- Próximo instante (después de "now") en que la aguja pasa por el centro de la zona
local function nextHit(r, now)
	local k = math.floor((now - r.T0) / r.Period / 2)
	local best
	for j = k, k + 1 do
		for _, offset in { r.Center, 2 - r.Center } do
			local t = r.T0 + r.Period * (2 * j + offset)
			if t > now + 0.03 and (not best or t < best) then best = t end
		end
	end
	return best
end

local stoneToggle
local rock -- roca actual: {T0, Period, Center, EndsAt, Left}
local waitingResult, sentAt, lastEvent, lastStart = false, 0, 0, -math.huge
local playing = false -- entre "Begin" y "Over" de cualquier modo del dojo
local KEN_DELAY = 0.15 -- respuesta casi humana; el aviso más corto grabado fue 0,49 s
local dojoAnswer = getRemote("HakiDojoService", "RE", "Answer")
local seenEvents = {}

local function onDojoEvent(kind, data)
	lastEvent = os.clock()
	if autoStone and not seenEvents[kind] then
		seenEvents[kind] = true
		log(T("Dojo: evento ", "Dojo: event ") .. tostring(kind)) -- para descubrir eventos que aún no conocemos (fin de partida...)
	end
	if type(data) ~= "table" then return end
	if kind == "Begin" then
		playing = true
	elseif kind == "Over" then
		playing = false
		if autoStone or autoKen then
			log(T("Dojo: fin (", "Dojo: over (") .. tostring(data.Why) .. "), +" .. tostring(data.Earned) .. " exp", "ok", true)
		end
	elseif kind == "Wave" and autoKen then
		-- Blindfold: Wave {I, Side, Warn} -> responder Answer(I, Side) antes de que pase Warn
		task.delay(KEN_DELAY, function() call(dojoAnswer, "FireServer", data.I, data.Side) end)
	end
	if kind == "Rock" then
		rock = { T0 = data.T0, Period = data.Period, Center = data.Center, EndsAt = data.EndsAt, Left = data.Left }
		waitingResult = false
		if autoStone then log(T("Train Buso: roca ", "Train Buso: rock ") .. tostring(data.I) .. T(" (dureza ", " (hardness ") .. tostring(data.Hardness) .. ")") end
	elseif kind == "Strike" then
		if rock and data.Left == 0 then
			rock = nil -- roca rota: esperar a la siguiente; golpear con estos datos daría Miss
		elseif rock then
			rock.Center, rock.Left, rock.EndsAt = data.Center, data.Left, data.EndsAt
		end
		waitingResult = false
	elseif kind ~= "Begin" then
		rock = nil -- cualquier otro evento (fin de partida...) cierra la roca
	end
end
if dojoGame then table.insert(cleanup, dojoGame.OnClientEvent:Connect(onDojoEvent)) end

-- Va con Rayleigh y empieza una partida del modo dado. Devuelve false si hay que apagar el auto
-- (3 fallos seguidos: límite diario u otro motivo, no insistir).
local dojoFails = {}
local function startDojo(mode, label)
	lastStart = os.clock() -- compartido: si Stone y Ken están ON, ninguno empieza mientras el otro arranca
	local hrp, npc = getHRP(), merchant("QuestHakiMerchant")
	if hrp and npc and (hrp.Position - npc:GetPivot().Position).Magnitude > 30 then
		teleport(npc:GetPivot().Position + Vector3.new(0, 3, 4))
		task.wait(0.5)
	end
	if mode == "Stone" and not hakiActive(HAKIS[1]) then -- la roca solo se rompe con Buso activo
		toggleHaki("Buso")
		task.wait(0.5)
	end
	local ok, started, reason = call(dojoStart, "InvokeServer", mode)
	if ok and started then
		dojoFails[mode] = 0
		log(label .. T(": partida empezada", ": game started"), "ok")
		return true
	end
	dojoFails[mode] = (dojoFails[mode] or 0) + 1
	log(label .. T(": no empieza (", ": won't start (") .. tostring(reason or started) .. ")", "warn")
	if dojoFails[mode] >= 3 then
		log(label .. T(": apagado tras 3 intentos fallidos", ": turned off after 3 failed attempts"), "warn")
		return false
	end
	return true
end

stoneToggle = toggle(pageTrain, "Auto Train Buso (Stone)", function(on)
	autoStone = on
	dojoFails.Stone = 0
	if not on then releaseMove("Train") end
	log("Auto Train Buso " .. (on and "ON" or "OFF"))
end, L("Juega Stone Breaker: activa el Buso y golpea justo en el centro de la zona.",
	"Plays Stone Breaker: turns on Buso and strikes right in the middle of the zone."))

task.spawn(function()
	while alive do
		task.wait(0.05)
		if autoStone then
			local now = workspace:GetServerTimeNow()
			local inGame = rock ~= nil or os.clock() - lastEvent < 4 or os.clock() - lastStart < 6
			if not inGame then releaseMove("Train") end -- entre partidas, Sam/Chest pueden usar el movimiento
			if rock and now > rock.EndsAt + 2 then
				rock = nil -- se acabó el tiempo sin aviso
			elseif rock and not waitingResult then
				local r = rock
				local t = nextHit(r, now)
				if t and t < r.EndsAt then
					task.wait(math.max(0, t - workspace:GetServerTimeNow()))
					if autoStone and rock == r then -- si llegó otra roca mientras esperaba, no golpear
						call(dojoStrike, "FireServer", t)
						waitingResult, sentAt = true, os.clock()
					end
				end
			elseif waitingResult and os.clock() - sentAt > 1 then
				waitingResult = false -- no llegó respuesta: volver a intentarlo
			elseif not inGame and claimMove("Train") and not startDojo("Stone", "Train Buso") then
				autoStone = false
				stoneToggle.set(false)
			end
		end
	end
end)

local kenToggle
kenToggle = toggle(pageTrain, "Auto Train Ken (Blindfold)", function(on)
	autoKen = on
	dojoFails.Blindfold = 0
	if not on then releaseMove("Train") end
	log("Auto Train Ken " .. (on and "ON" or "OFF"))
end, L("Juega Blindfold: responde al lado de cada ataque antes de que llegue.",
	"Plays Blindfold: answers each attack's side before it lands."))

-- Las respuestas van en onDojoEvent ("Wave"); este bucle solo empieza partidas nuevas
task.spawn(function()
	while alive do
		task.wait(0.5)
		if autoKen then
			local inGame = playing or os.clock() - lastEvent < 4 or os.clock() - lastStart < 6
			if not inGame then releaseMove("Train") end
			if not inGame and claimMove("Train") and not startDojo("Blindfold", "Train Ken") then
				autoKen = false
				kenToggle.set(false)
			end
		end
	end
end)

note(pageTrain, L("Te llevan a Rayleigh y juegan en bucle hasta el límite diario (2250 exp cada uno). Si los dos están encendidos, se turnan.",
	"They take you to Rayleigh and play in a loop until the daily limit (2250 exp each). If both are on, they take turns."))

end

local groundFruits = function() return {} end -- la rellena Frutas; la usa el ESP
------------------------------------------------------------------ Frutas
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
-- Rarezas y nombres de la wiki del juego (datos.json, listas "... Devil Fruits")
local FRUIT_RARITIES = {
	{ name = L("Común", "Common"), fruits = { "Chop", "Hot", "Slip", "Spin", "Spring", "Swim" } },
	{ name = L("Poco común", "Uncommon"), fruits = { "Barrier", "Bomb", "Diamond", "Float", "Gum", "Hobby", "Love", "Luck", "Smelt", "String" } },
	{ name = L("Rara", "Rare"), fruits = { "Candy", "Chilly", "Flare", "Gas", "Gravity", "Hollow", "Light", "Magma", "Ope", "Plasma",
		"Pumpkin", "Rumble", "Sand", "Shadow", "Smoke", "Snow", "Venom" } },
	{ name = L("Ultra rara", "Ultra Rare"), fruits = { "Dark", "Dough", "Phoenix", "Quake", "Vampire" } },
}
local fruitRank = {} -- "Chop" -> 1 ... "Vampire" -> 4
for rank, r in FRUIT_RARITIES do
	for _, f in r.fruits do fruitRank[f] = rank end
end

config.fruitSel = config.fruitSel or {} -- frutas elegidas (vacío = cualquiera)
config.fruitMin = math.clamp(tonumber(config.fruitMin) or 1, 1, #FRUIT_RARITIES)

-- Confirmado (EscaneoPendientes): una fruta tirada es una Tool en Workspace.Instances.Drops, llamada
-- "Spring Fruit", con el atributo FruitItem = "Spring". Se mira primero el atributo y, si no, el nombre.
local function fruitOf(obj)
	local attr = typeof(obj) == "Instance" and obj:GetAttribute("FruitItem")
	if type(attr) == "string" and fruitRank[attr] then return attr end
	local n = obj.Name:lower()
	for name in fruitRank do
		if n:find("%f[%a]" .. name:lower() .. "%f[%A]") then return name end
	end
end
assert(fruitOf({ Name = "Chop Fruit" }) == "Chop" and fruitOf({ Name = "Hotdog" }) == nil)

local function wanted(name)
	if fruitRank[name] < config.fruitMin then return false end
	return next(config.fruitSel) == nil or config.fruitSel[name] == true
end

-- Objetos sueltos en el mapa: se apuntan al aparecer en vez de recorrer todo el workspace cada vez
local loose = setmetatable({}, { __mode = "k" })
local unknownSeen = {}
local function track(d)
	if d:IsA("Tool") then loose[d] = true end
end
for _, d in workspace:GetDescendants() do track(d) end
table.insert(cleanup, workspace.DescendantAdded:Connect(track))

local function onGround(tool)
	local alive = workspace:FindFirstChild("Alive") -- las que lleva alguien están en su personaje
	return tool.Parent ~= nil and tool:IsDescendantOf(workspace) and not (alive and tool:IsDescendantOf(alive))
		and not (player.Character and tool:IsDescendantOf(player.Character))
end

-- Frutas tiradas ahora mismo (para el ESP): { tool, name, part, rank }
groundFruits = function()
	local out = {}
	for tool in loose do
		if onGround(tool) then
			local name = fruitOf(tool)
			local part = tool:FindFirstChild("Handle") or tool:FindFirstChildWhichIsA("BasePart", true)
			if name and part then table.insert(out, { tool = tool, name = name, part = part, rank = fruitRank[name] }) end
		end
	end
	return out
end

local autoFruit = false
local fruitTried = setmetatable({}, { __mode = "k" }) -- fruta -> momento del último intento fallido

local function nextFruit()
	local hrp = getHRP()
	if not hrp then return end
	local best, bestDist
	for tool in loose do
		if onGround(tool) then
			local name = fruitOf(tool)
			if not name and not unknownSeen[tool.Name] then
				unknownSeen[tool.Name] = true
				log(T("Frutas: objeto suelto sin identificar: ", "Fruits: unidentified loose item: ") .. tool.Name)
			end
			local handle = tool:FindFirstChild("Handle") or tool:FindFirstChildWhichIsA("BasePart", true)
			if name and handle and wanted(name) and os.clock() - (fruitTried[tool] or -math.huge) > 30 then
				local d = (handle.Position - hrp.Position).Magnitude
				if not bestDist or d < bestDist then best, bestDist = tool, d end
			end
		end
	end
	return best
end

local function collectFruit(tool)
	local hrp = getHRP()
	local handle = tool:FindFirstChild("Handle") or tool:FindFirstChildWhichIsA("BasePart", true)
	if not (hrp and handle) then return end
	local name = fruitOf(tool)
	local back = hrp.CFrame
	teleport(handle.Position + Vector3.new(0, 2, 0))
	task.wait(0.2)
	-- Coger: tocar el Handle (recogida normal de Roblox) y, por si la fruta usa otro sistema, clicar o pulsar
	-- lo que tenga. Se insiste hasta 1,5 s.
	local t0 = os.clock()
	repeat
		hrp = getHRP()
		if hrp and firetouchinterest then
			firetouchinterest(hrp, handle, 0)
			firetouchinterest(hrp, handle, 1)
		end
		for _, d in tool:GetDescendants() do
			if d:IsA("ClickDetector") and fireclickdetector then
				fireclickdetector(d)
			elseif d:IsA("ProximityPrompt") and fireproximityprompt then
				fireproximityprompt(d)
			end
		end
		task.wait(0.25)
	until not onGround(tool) or os.clock() - t0 >= 1.5
	returnTo(back)
	if onGround(tool) then
		fruitTried[tool] = os.clock()
		log(T("Frutas: no pude coger ", "Fruits: couldn't pick up ") .. name, "warn")
	else
		log(T("Frutas: recogida ", "Fruits: picked up ") .. name, "ok", true)
	end
end

section(pageFruits, L("Recoger", "Collect"))
toggle(pageFruits, "Collect Devil Fruits", function(on)
	autoFruit = on
	if not on then releaseMove("Fruit") end
	log("Collect Devil Fruits " .. (on and "ON" or "OFF"))
end, L("Va a por las frutas que caen en el mapa, las recoge y te devuelve a donde estabas (o a la zona segura).",
	"Goes for fruits that drop on the map, picks them up and brings you back (or to the safe zone)."))

task.spawn(function()
	while alive do
		task.wait(1)
		if autoFruit then
			local tool = nextFruit()
			if tool and claimMove("Fruit") then
				collectFruit(tool)
				releaseMove("Fruit")
			end
		end
	end
end)

-- Filtro: rareza mínima y frutas concretas (varias; si no hay ninguna marcada, vale cualquiera)
section(pageFruits, L("Filtro", "Filter"))
do
	local rarityNames = {}
	for rank, r in FRUIT_RARITIES do rarityNames[rank] = r.name end
	combo(pageFruits, L("Rareza mínima", "Minimum rarity"), rarityNames, config.fruitMin, function(rank)
		config.fruitMin = rank
		saveConfig()
	end, L("Solo recoge frutas de esta rareza o mejores.", "Only picks up fruits of this rarity or better."))
end
local fruitLists = {}
for _, r in FRUIT_RARITIES do
	local defaults = {}
	for i, f in r.fruits do defaults[i] = config.fruitSel[f] == true end
	table.insert(fruitLists, multi(pageFruits, r.name, r.fruits, defaults, function(chosen)
		for i, f in r.fruits do config.fruitSel[f] = chosen[i] or nil end
		saveConfig()
	end, L("Elige qué frutas de esta rareza recoger.", "Choose which fruits of this rarity to pick up.")))
end
note(pageFruits, L("Si no marcas ninguna fruta, recoge cualquiera desde la rareza mínima. Si marcas algunas, solo esas (y que cumplan la rareza mínima).",
	"If you don't select any fruit, it picks up any from the minimum rarity. If you select some, only those (as long as they meet the minimum rarity)."))
button(pageFruits, L("Quitar selección", "Clear selection"), function()
	table.clear(config.fruitSel)
	saveConfig()
	for _, list in fruitLists do list:Set({}) end
end, L("Desmarca todas las frutas.", "Unselects every fruit."))


-- Cajas y venta de frutas (grabado):
--   abrir: con la caja en la mano ("Common Box"), FruitBoxService.RE.Open()
--   vender: junto al comprador (al lado de Sam), con la fruta en la mano, FruitTradeService.RF.GetQuote() ->
--           { Fruit = "Spin", Rarity = "Common", Beri = 25000, Id = 1, Aura, Rainbow } y luego
--           FruitTradeService.RF.Sell("Beri", Id) -> true
-- Qué rarezas se venden y qué cajas se abren lo eliges tú (por defecto Common y Uncommon). Se comprueba con lo
-- que dice el comprador, no solo con el nombre. Nunca se vende una fruta con aura o arcoíris.
-- Rangos: 1 Common, 2 Uncommon, 3 Rare, 4 Ultra Rare (las listas son de 4 verdaderos/falsos, en ese orden)
local function rarityList(saved)
	if type(saved) ~= "table" then return { true, true, false, false } end
	return { saved[1] == true, saved[2] == true, saved[3] == true, saved[4] == true }
end
config.sellRarities = rarityList(config.sellRarities)
config.boxRarities = rarityList(config.boxRarities)
local RARITY_RANK = { Common = 1, Uncommon = 2, Rare = 3, ["Ultra Rare"] = 4 }
local boxOpen = getRemote("FruitBoxService", "RE", "Open")
local getQuote = getRemote("FruitTradeService", "RF", "GetQuote")
local sellRemote = getRemote("FruitTradeService", "RF", "Sell")
local autoBoxes, autoSell = false, false

-- "Ultra Rare Box" -> 4, "Uncommon Box" -> 2 ... (el orden importa: "Uncommon" contiene "common")
local function boxRank(name)
	local n = name:lower()
	if not n:find("box") then return nil end
	if n:find("ultra") then return 4 end
	if n:find("uncommon") then return 2 end
	if n:find("common") then return 1 end
	if n:find("rare") then return 3 end
end
assert(boxRank("Common Box") == 1 and boxRank("Uncommon Box") == 2 and boxRank("Rare Box") == 3 and boxRank("Black Leg") == nil)

local function myTools()
	local list = {}
	for _, holder in { player:FindFirstChild("Backpack"), player.Character } do
		for _, t in holder and holder:GetChildren() or {} do
			if t:IsA("Tool") then table.insert(list, t) end
		end
	end
	return list
end

local function hold(tool)
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if not hum then return false end
	if tool.Parent ~= player.Character then
		hum:EquipTool(tool)
		task.wait(0.35)
	end
	return tool.Parent == player.Character
end

-- El comprador de frutas es SellerMerchant, a 27 studs de Sam (EscaneoPendientes). Antes se cogía el NPC más
-- cercano a Sam, que era DeepFisherman, y por eso te llevaba junto a Sam.
local function fruitBuyer()
	return merchant("SellerMerchant") or merchant("QuestMerchant2")
end

local function openBoxes()
	local opened = 0
	for _, tool in myTools() do
		local rank = boxRank(tool.Name)
		if rank and config.boxRarities[rank] and hold(tool) then
			call(boxOpen, "FireServer")
			opened += 1
			log(T("Cajas: abierta ", "Boxes: opened ") .. tool.Name, "ok", true)
			task.wait(1.5) -- que llegue la fruta
		end
	end
	return opened
end

local function fruitsToSell()
	local list = {}
	for _, tool in myTools() do
		local name = fruitOf(tool)
		if name and not boxRank(tool.Name) and config.sellRarities[fruitRank[name]] then table.insert(list, tool) end
	end
	return list
end

local function sellFruits()
	local list = fruitsToSell()
	if #list == 0 then return end
	local hrp, buyer = getHRP(), fruitBuyer()
	if not (hrp and buyer) then return end
	if not claimMove("Sell") then return end
	local back = hrp.CFrame
	local char = player.Character
	local prevTool = char and char:FindFirstChildOfClass("Tool")
	teleport(buyer:GetPivot().Position + Vector3.new(0, 3, 4))
	task.wait(0.6)
	for _, tool in list do
		if hold(tool) then
			local ok, quote = call(getQuote, "InvokeServer")
			local rank = ok and type(quote) == "table" and RARITY_RANK[quote.Rarity]
			if not rank then
				log(T("Venta: el comprador no me da precio para ", "Sell: the buyer gives no price for ") .. tool.Name, "warn")
			elseif not config.sellRarities[rank] or quote.Aura or quote.Rainbow then
				log(T("Venta: no vendo ", "Sell: not selling ") .. tostring(quote.Fruit) .. " (" .. tostring(quote.Rarity) .. ")", "warn")
			else
				local sold_ok, sold = call(sellRemote, "InvokeServer", "Beri", quote.Id)
				if sold_ok and sold then
					log(string.format(T("Venta: %s (%s) por %s Beri", "Sell: %s (%s) for %s Beri"), tostring(quote.Fruit),
						tostring(quote.Rarity), tostring(quote.Beri)), "ok", true)
				else
					log(T("Venta: no se pudo vender ", "Sell: couldn't sell ") .. tostring(quote.Fruit), "warn")
				end
			end
			task.wait(0.4)
		end
	end
	returnTo(back)
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if hum and prevTool and prevTool.Parent == player:FindFirstChild("Backpack") then hum:EquipTool(prevTool) end
	releaseMove("Sell")
	log(T("Venta: comprador = ", "Sell: buyer = ") .. buyer.Name)
end

section(pageFruits, L("Cajas y venta", "Boxes and selling"))
local rarityNames = {}
for rank, r in FRUIT_RARITIES do rarityNames[rank] = r.name end
toggle(pageFruits, L("Auto abrir cajas", "Auto open boxes"), function(on)
	autoBoxes = on
	log(T("Auto abrir cajas ", "Auto open boxes ") .. (on and "ON" or "OFF"))
end, L("Abre solas las cajas que tengas (por ejemplo las que da Sam) de las rarezas elegidas abajo.",
	"Opens the boxes you have (e.g. the ones Sam gives) of the rarities chosen below."))
multi(pageFruits, L("Cajas que abrir", "Boxes to open"), rarityNames, config.boxRarities, function(chosen)
	config.boxRarities = rarityList(chosen)
	saveConfig()
end, L("Qué rarezas de caja se abren solas.", "Which box rarities are opened automatically."))
toggle(pageFruits, L("Auto vender frutas", "Auto sell fruits"), function(on)
	autoSell = on
	if not on then releaseMove("Sell") end
	log(T("Auto vender frutas ", "Auto sell fruits ") .. (on and "ON" or "OFF"))
end, L("Lleva tus frutas de las rarezas elegidas abajo al comprador que hay al lado de Sam, las vende por Beri y te devuelve. Nunca vende frutas con aura o arcoíris.",
	"Takes your fruits of the rarities chosen below to the buyer next to Sam, sells them for Beri and brings you back. Never sells fruits with aura or rainbow."))
multi(pageFruits, L("Frutas que vender", "Fruits to sell"), rarityNames, config.sellRarities, function(chosen)
	config.sellRarities = rarityList(chosen)
	saveConfig()
end, L("Qué rarezas de fruta se venden. Se comprueba con lo que dice el comprador.", "Which fruit rarities are sold. Checked against what the buyer says."))

task.spawn(function()
	while alive do
		task.wait(3)
		local ok, err = pcall(function()
			if autoBoxes then openBoxes() end
			if autoSell then sellFruits() end
		end)
		if not ok then log(T("Cajas/venta: error ", "Boxes/sell: error ") .. tostring(err), "error") end
	end
end)
end

local NPCS -- también lo usa la pestaña GUIs
------------------------------------------------------------------ Teleports
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
-- NPCs con interfaz o servicio útil (también los usa la pestaña GUIs). Nombres de su cartel o de la wiki;
-- modelos de Map.Merchants (EscaneoPendientes). Todos se hablan con un ClickDetector (32 studs) en "Clickable".
NPCS = {
	{ name = "Sam (Quest Man)", model = "QuestMerchant2" },
	{ name = "Fruit Seller", model = "SellerMerchant" },
	{ name = "Drink Merchant", model = "DrinkMerchant" },
	{ name = "Deep Fisherman", model = "DeepFisherman" },
	{ name = "Merlin", model = "QuestFishMerchant" },
	{ name = "Trait Sage", model = "TraitSage" },
	{ name = "Silvers Rayleigh", model = "QuestHakiMerchant" },
	{ name = "Red-Haired Shanks", model = "HakiRankMerchant" },
	{ name = "The Expert", model = "ExpertiseMerchant" },
	{ name = "Fish Merchant", model = "FishMerchant" },
	{ name = "Strange Compass Shop", model = "FriendMerchant" },
	{ name = "Affinity Diviner", model = "AffinityMerchant" },
	{ name = "Advanced Bartender", model = "BetterDrinkMerchant" },
	{ name = "Craftsman", model = "Craftsman" },
	{ name = "Sword Dealer", model = "SwordMerchant" },
	{ name = "Sniper Dealer", model = "SniperMerchant" },
	{ name = "Emote Merchant", model = "EmoteMerchant" },
}

local function npcButtons(page, list)
	local g = grid(page)
	for _, entry in list do
		button(g, entry.name, function()
			local npc = merchant(entry.model)
			if not npc then return log(T("No encuentro a ", "Can't find ") .. entry.name, "warn") end
			teleport(npc:GetPivot().Position + Vector3.new(0, 3, 4))
			log(T("Llevado a ", "Taken to ") .. entry.name)
		end, L("Te lleva junto a " .. entry.name, "Takes you to " .. entry.name))
	end
end
pageTp.tab:Columns({ 1.45, 1 }) -- columna 1 más ancha: solo lleva el mapa
local mapBox = section(pageTp, L("Mapa", "Map"), 1)
section(pageTp, "NPCs", 2)
npcButtons(pageTp, NPCS)
section(pageQuest, L("Ir a un NPC de misiones", "Go to a quest giver"))
npcButtons(pageQuest, QUEST_GIVERS)

-- Nombres de las islas según la wiki del juego (datos.json) y los NPCs que hay en cada una.
-- Las que no aparecen aquí usan su nombre interno limpio.
local ISLAND_NAMES = {
	IslandWindmill = "Windmill Island",
	IslandTown = "Town Island",
	IslandPirate = "Pirate's Land",
	Island15 = "Crab Isle", -- tiene QuestCrabIsle al lado
	Z_Island222 = "Farm Island", -- tiene QuestFarm y jabalíes
	IslandDeepwake = "Deepwaken Trench",
	IslandTREEA = "Tree Island",
	Island4 = "Marine Base", -- tiene QuestMarine al lado
	IslandHalloween = "Halloween Island",
	IslandCaver = "Caver Island",
	IslandCliffs = "Cliff Tops",
	IslandMountain = "Mountain Island",
	IslandSandCastle = "Sand Dunes", -- los Fred y su NPC están ahí
	Island14 = "Pursuer Island", -- tiene QuestPursuer al lado
}

section(pageTp, L("Islas", "Islands"), 2)
local islandGrid = grid(pageTp)
local map = workspace:FindFirstChild("Map")
local islandsFolder = map and map:FindFirstChild("Islands")
local islands = islandsFolder and islandsFolder:GetChildren() or {}
local function islandName(island)
	local clean = island.Name:gsub("^Z_", ""):gsub("^Island", ""):gsub("(%l)(%u)", "%1 %2")
	if tonumber(clean) or clean == "" then clean = "Island " .. clean end -- p. ej. Island13 -> "Island 13"
	return ISLAND_NAMES[island.Name] or clean
end
table.sort(islands, function(a, b) return islandName(a) < islandName(b) end)
-- El tablón está en tierra firme. Sin tablón: la isla si es un modelo, o cualquier pieza suya
-- (una carpeta no tiene posición y GetPivot daría error)
local function islandTarget(island)
	return island:FindFirstChild("QuestBoard")
		or (island:IsA("PVInstance") and island)
		or island:FindFirstChildWhichIsA("BasePart", true)
end
local function goIsland(island)
	local name = islandName(island)
	local target = islandTarget(island)
	if not target then return log(T("No sé dónde está ", "Don't know where this is: ") .. name, "warn") end
	teleport(target:GetPivot().Position + Vector3.new(0, 5, 0))
	log(T("Llevado a ", "Taken to ") .. name)
end
for _, island in islands do
	local name = islandName(island)
	button(islandGrid, name, function() goIsland(island) end, L("Te lleva a " .. name, "Takes you to " .. name))
end

-- Mapa visto desde arriba: cada isla es un círculo en su X/Z (tamaño según la isla); clic = teletransporte.
-- Rueda = zoom hacia el ratón, arrastrar = mover. Los nombres solo salen si caben sin pisarse (primero las
-- islas grandes), así al acercar van apareciendo más. El punto rojo eres tú.
do
	local MAP_H, PAD, MAX_ZOOM = 440, 34, 6
	local W = mapBox.flow.rw
	local frame = Instance.new("Frame")
	frame.Position = UDim2.fromOffset(mapBox.flow.x, mapBox.flow.y)
	frame.Size = UDim2.fromOffset(W, MAP_H)
	frame.BackgroundColor3 = C.bg
	frame.BorderSizePixel = 0
	frame.ClipsDescendants = true
	frame.Active = true
	frame.Parent = mapBox.flow.parent
	Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 4)
	Instance.new("UIStroke", frame).Color = C.line
	mapBox:advance(MAP_H)

	local hint = Instance.new("TextLabel")
	hint.Position = UDim2.fromOffset(8, MAP_H - 18)
	hint.Size = UDim2.fromOffset(W - 16, 12)
	hint.BackgroundTransparency = 1
	hint.Font = FONT_SEMI
	hint.TextSize = 10
	hint.TextColor3 = C.dim
	hint.TextXAlignment = Enum.TextXAlignment.Left
	hint.Text = T("Rueda: zoom · arrastrar: mover · clic en una isla: ir", "Wheel: zoom · drag: move · click an island: go")
	hint.ZIndex = 6
	hint.Parent = frame

	local points = {}
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for _, island in islands do
		local target = islandTarget(island)
		if target then
			local p = target:GetPivot().Position
			local ok, size = pcall(function() return island:IsA("Model") and island:GetExtentsSize() or target.Size end)
			size = ok and size or Vector3.zero
			table.insert(points, { island = island, pos = p, size = math.max(size.X, size.Z) })
			minX, maxX = math.min(minX, p.X), math.max(maxX, p.X)
			minZ, maxZ = math.min(minZ, p.Z), math.max(maxZ, p.Z)
		end
	end
	table.sort(points, function(a, b) return a.size > b.size end) -- prioridad de nombre: las grandes primero
	local scale = math.min((W - 2 * PAD) / math.max(maxX - minX, 1), (MAP_H - 2 * PAD) / math.max(maxZ - minZ, 1))
	local offX = (W - (maxX - minX) * scale) / 2
	local offY = (MAP_H - (maxZ - minZ) * scale) / 2
	local zoom, panX, panY = 1, 0, 0
	local function toMap(p)
		-- girado 180°: así el norte del juego queda arriba (confirmado por el usuario)
		local bx, by = (maxX - p.X) * scale + offX, (maxZ - p.Z) * scale + offY
		return (bx - W / 2) * zoom + W / 2 + panX, (by - MAP_H / 2) * zoom + MAP_H / 2 + panY
	end

	local hovered
	local function layout()
		-- que el mapa no se salga del marco
		panX = math.clamp(panX, -(zoom - 1) * W / 2, (zoom - 1) * W / 2)
		panY = math.clamp(panY, -(zoom - 1) * MAP_H / 2, (zoom - 1) * MAP_H / 2)
		local shown = {}
		for _, pt in points do
			local x, y = toMap(pt.pos)
			local d = math.clamp(pt.size * scale * zoom, 12, 90)
			pt.dot.Position, pt.dot.Size = UDim2.fromOffset(x, y), UDim2.fromOffset(d, d)
			local ly = y + d / 2 + 2
			pt.label.Position = UDim2.fromOffset(x, ly)
			local w = pt.label.TextBounds.X + 8
			local fits = true
			for _, o in shown do
				if math.abs(o.x - x) < (o.w + w) / 2 and math.abs(o.y - ly) < 13 then fits = false break end
			end
			if fits then table.insert(shown, { x = x, y = ly, w = w }) end
			pt.label.Visible = fits or pt == hovered
		end
	end

	for _, pt in points do
		local dot = Instance.new("TextButton")
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.BackgroundColor3 = C.surface
		dot.Text = ""
		dot.AutoButtonColor = false
		dot.Parent = frame
		Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
		local ring = Instance.new("UIStroke", dot)
		ring.Color = C.line
		ring.Thickness = 1.5
		local label = Instance.new("TextLabel")
		label.AnchorPoint = Vector2.new(0.5, 0)
		label.Size = UDim2.fromOffset(120, 12)
		label.BackgroundTransparency = 1
		label.Font = FONT_SEMI
		label.TextSize = 10
		label.TextColor3 = C.dim
		label.Text = islandName(pt.island)
		label.ZIndex = 2
		label.Parent = frame
		pt.dot, pt.label = dot, label
		dot.MouseEnter:Connect(function()
			hovered = pt
			ring.Color, label.TextColor3, label.ZIndex = C.accent, C.text, 4
			layout()
		end)
		dot.MouseLeave:Connect(function()
			if hovered == pt then hovered = nil end
			ring.Color, label.TextColor3, label.ZIndex = C.line, C.dim, 2
			layout()
		end)
	end

	-- Ratón: la librería reparte los clics y la rueda con su propio sistema; si el mapa no está registrado en él,
	-- pulsar encima arrastra la ventana y la rueda hace scroll de la caja. Se registra como un control más en una
	-- sub-zona de la caja (se mira antes que la caja).
	local scope = mapBox.scope
	local mapScope = setmetatable({ parent = scope, own = 1, alpha = scope.alpha, painters = {}, items = {}, wheels = {},
		kids = {}, inert = false }, getmetatable(scope))
	table.insert(scope.kids, mapScope)
	local function localPoint(p) -- de píxeles de pantalla a píxeles del mapa (la ventana puede estar escalada)
		local k = frame.AbsoluteSize.X / W
		return (p.X - frame.AbsolutePosition.X) / k, (p.Y - frame.AbsolutePosition.Y) / k
	end
	local dragFrom, moved
	table.insert(mapScope.items, {
		gui = frame,
		down = function(p)
			local x, y = localPoint(p)
			dragFrom, moved = { x = x, y = y, px = panX, py = panY }, false
		end,
		drag = function(p)
			if not dragFrom then return end
			local x, y = localPoint(p)
			if math.abs(x - dragFrom.x) + math.abs(y - dragFrom.y) > 4 then moved = true end
			panX, panY = dragFrom.px + x - dragFrom.x, dragFrom.py + y - dragFrom.y
			layout()
		end,
		up = function(p)
			dragFrom = nil
			if moved then return end
			-- clic sin arrastrar: la isla bajo el ratón
			for _, pt in points do
				local a, s = pt.dot.AbsolutePosition, pt.dot.AbsoluteSize
				if p.X >= a.X and p.Y >= a.Y and p.X < a.X + s.X and p.Y < a.Y + s.Y then return goIsland(pt.island) end
			end
		end,
	})
	-- Zoom con la rueda, manteniendo fijo el punto bajo el ratón
	table.insert(mapScope.wheels, {
		gui = frame,
		fn = function(z)
			-- GetMouseLocation cuenta desde arriba de la pantalla; las GUI sin IgnoreGuiInset, desde debajo de la barra
			local sg = frame:FindFirstAncestorWhichIsA("ScreenGui")
			local m = UIS:GetMouseLocation()
			if not (sg and sg.IgnoreGuiInset) then m -= game:GetService("GuiService"):GetGuiInset() end
			local mx, my = localPoint(m)
			local newZoom = math.clamp(zoom * (z > 0 and 1.25 or 0.8), 1, MAX_ZOOM)
			panX = mx - W / 2 - (mx - W / 2 - panX) * newZoom / zoom
			panY = my - MAP_H / 2 - (my - MAP_H / 2 - panY) * newZoom / zoom
			zoom = newZoom
			layout()
		end,
	})
	task.defer(layout) -- TextBounds ya calculado

	local me = Instance.new("Frame")
	me.AnchorPoint = Vector2.new(0.5, 0.5)
	me.Size = UDim2.fromOffset(8, 8)
	me.BackgroundColor3 = C.accent
	me.BorderSizePixel = 0
	me.ZIndex = 5
	me.Parent = frame
	Instance.new("UICorner", me).CornerRadius = UDim.new(1, 0)
	Instance.new("UIStroke", me).Color = C.text
	task.spawn(function()
		while alive and frame.Parent do
			local hrp = getHRP()
			me.Visible = hrp ~= nil and #points > 0
			if hrp then
				local x, y = toMap(hrp.Position)
				me.Position = UDim2.fromOffset(math.clamp(x, 4, W - 4), math.clamp(y, 4, MAP_H - 4))
			end
			task.wait(0.3)
		end
	end)
	if #points == 0 then note(pageTp, L("No hay islas para dibujar el mapa.", "No islands to draw the map.")) end
end
if #islands == 0 then note(pageTp, L("No encuentro Workspace.Map.Islands.", "Can't find Workspace.Map.Islands.")) end

end

------------------------------------------------------------------ GUIs
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
-- Botones del menú del juego (Crews, Challenges, Quests, Shop, Stats...), leídos en vivo de su interfaz
section(pageGuis, L("Menú del juego", "Game menu"))
local menuGrid = grid(pageGuis)
local menuNew = player.PlayerGui:FindFirstChild("MenuNew")
local column = menuNew and menuNew:FindFirstChild("Column")
local menuButtons = column and column:FindFirstChild("Buttons")
local menuList = {}
for _, b in menuButtons and menuButtons:GetChildren() or {} do
	if b:IsA("GuiButton") then table.insert(menuList, b) end
end
table.sort(menuList, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
for _, b in menuList do
	local textLabel = b:FindFirstChild("Text")
	local name = textLabel and textLabel:IsA("TextLabel") and textLabel.Text ~= "" and textLabel.Text or b.Name
	button(menuGrid, name, function()
		pressGuiButton(b)
		log(T("Abriendo ", "Opening ") .. name)
	end, L("Abre el menú " .. name .. " del juego.", "Opens the game's " .. name .. " menu."))
end
if #menuList == 0 then
	note(pageGuis, L("No encuentro el menú del juego (PlayerGui.MenuNew).", "Can't find the game menu (PlayerGui.MenuNew)."))
end

-- Menús de NPCs: te lleva un momento al NPC, le habla y te devuelve a donde estabas
-- shortcut: no sabemos cómo se habla con los NPCs; se prueban ClickDetector y ProximityPrompt.
-- Si el juego cierra el menú al alejarte, habría que quedarse junto al NPC.
local function talkTo(entry)
	local npc, hrp = merchant(entry.model), getHRP()
	if not npc then return log(T("No encuentro a ", "Can't find ") .. entry.name, "warn") end
	if not hrp then return end
	if not claimMove("GUIs") then return log(T("Otra función te está moviendo, prueba en un momento", "Another feature is moving you, try again in a moment"), "warn") end
	local back = hrp.CFrame
	teleport(npc:GetPivot().Position + Vector3.new(0, 3, 4))
	task.wait(0.4)
	local talked = false
	for _, d in npc:GetDescendants() do
		if d:IsA("ClickDetector") and fireclickdetector then
			fireclickdetector(d)
			talked = true
		elseif d:IsA("ProximityPrompt") and fireproximityprompt then
			fireproximityprompt(d)
			talked = true
		end
	end
	task.wait(0.6)
	hrp = getHRP()
	if hrp then hrp.CFrame = back end
	releaseMove("GUIs")
	if talked then
		log(T("Abriendo el menú de ", "Opening the menu of ") .. entry.name)
	else
		log(T("No sé cómo hablar con ", "Don't know how to talk to ") .. entry.name, "warn")
	end
end

section(pageGuis, L("Tiendas y NPCs (beta)", "Shops and NPCs (beta)"))
local npcGuiGrid = grid(pageGuis)
for _, entry in NPCS do
	button(npcGuiGrid, entry.name, function() talkTo(entry) end,
		L("Va un momento a " .. entry.name .. ", abre su menú y te devuelve a donde estabas.",
			"Briefly goes to " .. entry.name .. ", opens their menu and brings you back."))
end

end

------------------------------------------------------------------ Auto Stats
-- Frutas normales (no Devil Fruits) → zumos que suben stats. Datos de EscaneoBatidos:
--  * Barriles y cajas: Workspace.Map.Barrels.Barrels.Barrel / .Crates.Crate, ClickDetector en la pieza (8 studs).
--    Dan una fruta como Tool ("Banana", "Prickly Pear").
--  * Exprimidor: Workspace.Map.Other.Tent2.Model.JuicingBowl (Bowl, Mixer1, Mixer2; ClickDetector 10 studs).
--    Sale la Tool "<fruta> Juice" ("Banana Juice", "Sour Juice").
--  * Beber: con el zumo en la mano, PlayerGui.Drink tiene DrinkOne y DrinkAll ("Drink all (n)").
-- Sin confirmar: cómo se usa el exprimidor (se equipa la fruta y se clican sus tres piezas) y si se nota un
-- barril vacío.
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
local BARREL_COOLDOWN = 300 -- shortcut: no sé cuándo se rellena un barril; se salta 5 min. Mirar si cambia algo al vaciarse
local BARRELS_PER_ROUND = 15
local autoStats = false
local visited = {} -- pieza del barril -> os.clock() de la última visita
local juiceFailed = false
config.juiceFruits = config.juiceFruits or {}
local fruitNames = { Banana = true, ["Prickly Pear"] = true } -- y las que salgan de los barriles
for name in config.juiceFruits do fruitNames[name] = true end

local function tools()
	local out = {}
	for _, holder in { player:FindFirstChild("Backpack"), player.Character } do
		for _, t in holder and holder:GetChildren() or {} do
			if t:IsA("Tool") then table.insert(out, t) end
		end
	end
	return out
end
local function isDrink(t) return t.Name:find("Juice") ~= nil or t.Name:find("Smoothie") ~= nil end
local function humanoid() return player.Character and player.Character:FindFirstChildOfClass("Humanoid") end

local function collect()
	local hrp = getHRP()
	local map = workspace:FindFirstChild("Map")
	local root = map and map:FindFirstChild("Barrels")
	if not (hrp and root) then return end
	local list = {}
	for _, cd in root:GetDescendants() do
		if cd:IsA("ClickDetector") and cd.Parent:IsA("BasePart")
			and os.clock() - (visited[cd.Parent] or -math.huge) > BARREL_COOLDOWN then
			table.insert(list, cd)
		end
	end
	table.sort(list, function(a, b)
		return (a.Parent.Position - hrp.Position).Magnitude < (b.Parent.Position - hrp.Position).Magnitude
	end)
	local got = 0
	for i = 1, math.min(BARRELS_PER_ROUND, #list) do
		if not autoStats then break end
		local cd = list[i]
		visited[cd.Parent] = os.clock()
		local before = {}
		for _, t in tools() do before[t] = true end
		teleport(cd.Parent.Position + Vector3.new(0, 4, 0))
		task.wait(0.3)
		if fireclickdetector then fireclickdetector(cd, 0) end
		task.wait(0.6)
		for _, t in tools() do
			if not before[t] and not isDrink(t) then
				got += 1
				if not fruitNames[t.Name] then
					fruitNames[t.Name] = true
					config.juiceFruits[t.Name] = true
					saveConfig()
					log(T("Auto Stats: fruta nueva ", "Auto Stats: new fruit ") .. t.Name)
				end
			end
		end
	end
	log(T("Auto Stats: barriles ", "Auto Stats: barrels ") .. math.min(BARRELS_PER_ROUND, #list) .. T(", frutas nuevas ", ", new fruits ") .. got)
end

local function makeJuice()
	if juiceFailed then return end
	local list = {}
	for _, t in tools() do
		if fruitNames[t.Name] then table.insert(list, t) end
	end
	if #list == 0 then return end
	local map = workspace:FindFirstChild("Map")
	local other = map and map:FindFirstChild("Other")
	local bowl = other and other:FindFirstChild("JuicingBowl", true)
	local hum = humanoid()
	if not (bowl and hum) then
		return log(T("Auto Stats: no encuentro el exprimidor (Map.Other...JuicingBowl)", "Auto Stats: can't find the juicer (Map.Other...JuicingBowl)"), "warn")
	end
	teleport(bowl:GetPivot().Position + Vector3.new(0, 3, 4))
	task.wait(0.5)
	for _, fruit in list do
		if not autoStats then break end
		if fruit.Parent then
			hum:EquipTool(fruit)
			task.wait(0.3)
			for _, d in bowl:GetDescendants() do
				if d:IsA("ClickDetector") and fireclickdetector and fruit.Parent then
					fireclickdetector(d, 0)
					task.wait(0.4)
				end
			end
			local t0 = os.clock()
			while fruit.Parent and os.clock() - t0 < 3 do task.wait(0.2) end
			if fruit.Parent then
				-- no se gastó: no insistir en cada vuelta
				juiceFailed = true
				hum:UnequipTools()
				return log(T("Auto Stats: la fruta no se gasta en el exprimidor. Dime cómo lo haces a mano (qué clicas y con qué en la mano)",
					"Auto Stats: the fruit isn't used by the juicer. Tell me how you do it by hand (what you click and holding what)"), "warn")
			end
			log(T("Auto Stats: exprimida ", "Auto Stats: juiced ") .. fruit.Name)
		end
	end
	hum:UnequipTools()
end

local function drinkAll()
	local hum = humanoid()
	if not hum then return end
	local done = {}
	for _, d in tools() do
		if isDrink(d) and not done[d.Name] and d.Parent then
			done[d.Name] = true
			hum:EquipTool(d)
			-- con el zumo en la mano aparece PlayerGui.Drink con "Drink all"
			local btn
			local t0 = os.clock()
			repeat
				local gui = player.PlayerGui:FindFirstChild("Drink")
				local frame = gui and gui:FindFirstChild("Drink")
				local actions = frame and frame.Visible and frame:FindFirstChild("Actions")
				btn = actions and actions:FindFirstChild("DrinkAll")
				if not btn then task.wait(0.1) end
			until btn or os.clock() - t0 > 2
			if btn then
				task.wait(0.2)
				pressGuiButton(btn)
				task.wait(0.8)
				log(T("Auto Stats: bebidos todos los ", "Auto Stats: drank every ") .. d.Name, "ok", true)
			else
				log(T("Auto Stats: no sale el botón Drink all con ", "Auto Stats: no Drink all button with ") .. d.Name, "warn")
			end
		end
	end
	hum:UnequipTools()
end

section(pageAuto, L("Farmeo", "Farming"))
toggle(pageAuto, "Auto Stats (beta)", function(on)
	autoStats = on
	juiceFailed = false
	if not on then releaseMove("Stats") end
	log("Auto Stats " .. (on and "ON" or "OFF"))
end, L("Clica barriles y cajas para sacar frutas normales, las exprime en el puesto de zumos y se bebe todos los zumos de golpe (Drink all).",
	"Clicks barrels and crates for normal fruits, juices them at the juice stand and drinks every juice at once (Drink all)."))

task.spawn(function()
	while alive do
		task.wait(2)
		if autoStats and claimMove("Stats") then
			local hrp = getHRP()
			local start = hrp and hrp.CFrame
			local ok, err = pcall(function()
				collect()
				makeJuice()
				drinkAll()
			end)
			if not ok then log("Auto Stats: error " .. tostring(err), "error") end
			if start then returnTo(start) end
			releaseMove("Stats")
			task.wait(20)
		end
	end
end)
end

------------------------------------------------------------------ Misc
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
local antiAfk = false
section(pageMisc, L("Utilidades", "Utilities"))
toggle(pageMisc, "Anti-AFK", function(on)
	antiAfk = on
	log("Anti-AFK " .. (on and "ON" or "OFF"))
end, L("Evita que Roblox te expulse por estar inactivo.", "Stops Roblox from kicking you for being idle."))
table.insert(cleanup, player.Idled:Connect(function()
	if antiAfk then
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end
end))

local fpsToggle
fpsToggle = toggle(pageMisc, L("Desbloquear FPS", "Unlock FPS"), function(on)
	if not setfpscap then
		fpsToggle.set(false)
		return log(T("Tu executor no permite cambiar los FPS (setfpscap)", "Your executor can't change FPS (setfpscap)"), "warn")
	end
	setfpscap(on and 999 or 60)
	log(on and T("FPS desbloqueados", "FPS unlocked") or T("FPS a 60", "FPS capped at 60"))
end, L("Quita el límite de 60 FPS. Al apagarlo vuelve a 60.", "Removes the 60 FPS limit. Turning it off goes back to 60."))

-- Auto Respawn: al morir pide reaparecer con CharacterService.RF.RequestSpawn(), igual que el botón del juego
-- (grabado: sin argumentos, devuelve true si te deja). Justo al morir el servidor aún no deja y devuelve
-- false, así que se reintenta cada segundo hasta que acepta o ya tienes personaje nuevo (máx. 30 s).
local respawnRemote = getRemote("CharacterService", "RF", "RequestSpawn")
local autoRespawn = false
local function watchDeath(char)
	local hum = char:WaitForChild("Humanoid", 10)
	if not hum then return end
	hum.Died:Connect(function()
		local t0 = os.clock()
		while alive and autoRespawn and player.Character == char and os.clock() - t0 < 30 do
			task.wait(1)
			local ok, accepted = call(respawnRemote, "InvokeServer")
			if ok and accepted then
				log(T("Auto Respawn: reapareciendo", "Auto Respawn: respawning"), "ok")
				return
			end
		end
		if alive and autoRespawn and player.Character == char then
			log(T("Auto Respawn: el servidor no me ha dejado reaparecer en 30 s", "Auto Respawn: the server didn't let me respawn in 30 s"), "warn")
		end
	end)
end
if player.Character then task.spawn(watchDeath, player.Character) end
table.insert(cleanup, player.CharacterAdded:Connect(watchDeath))
toggle(pageMisc, "Auto Respawn", function(on)
	autoRespawn = on
	log("Auto Respawn " .. (on and "ON" or "OFF"))
end, L("Al morir, reapareces enseguida. Con la zona segura activa, vuelves a ella.",
	"When you die, you respawn right away. With the safe zone on, you go back to it."))

button(pageMisc, L("Copiar mi posición", "Copy my position"), function()
	local hrp = getHRP()
	if not hrp then return end
	local text = tostring(hrp.Position)
	if setclipboard then setclipboard(text) end
	log(T("Posición: ", "Position: ") .. text .. (setclipboard and T(" (copiada)", " (copied)") or ""))
end, L("Copia tus coordenadas al portapapeles y las muestra en la consola.", "Copies your coordinates to the clipboard and shows them in the console."))
button(pageMisc, L("Mostrar / ocultar consola", "Show / hide console"), function() setConsole(not consoleShown) end,
	L("Abre o cierra la ventana de consola con el registro de todo lo que hace el hub.", "Opens or closes the console window with a log of everything the hub does."))

section(pageMisc, L("Servidor", "Server"))
local TeleportService = game:GetService("TeleportService")
button(pageMisc, "Rejoin", function()
	log(T("Volviendo a entrar al servidor...", "Rejoining the server..."), "ok", true)
	local ok = pcall(TeleportService.TeleportToPlaceInstance, TeleportService, game.PlaceId, game.JobId, player)
	if not ok or #Players:GetPlayers() <= 1 then TeleportService:Teleport(game.PlaceId, player) end -- solo en el servidor: uno nuevo
end, L("Sale y vuelve a entrar en este mismo servidor.", "Leaves and joins this same server again."))
-- Cambia a otro servidor del juego con hueco (también lo usa la protección contra admins)
local function serverHop()
	-- Lista pública de servidores de Roblox; se elige uno al azar que no sea este y que tenga hueco
	local ok, data = pcall(function()
		return HttpService:JSONDecode(game:HttpGet(
			"https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Asc&limit=100"))
	end)
	if not ok or type(data) ~= "table" or not data.data then
		return log(T("No pude leer la lista de servidores", "Couldn't read the server list"), "error")
	end
	local options = {}
	for _, s in data.data do
		if s.id ~= game.JobId and (s.playing or 0) < (s.maxPlayers or 0) then table.insert(options, s.id) end
	end
	if #options == 0 then return log(T("No hay otros servidores con hueco", "No other servers with free slots"), "warn") end
	log(T("Cambiando de servidor...", "Switching server..."), "ok", true)
	TeleportService:TeleportToPlaceInstance(game.PlaceId, options[math.random(#options)], player)
end
button(pageMisc, "Server Hop", serverHop, L("Te lleva a otro servidor del juego con hueco, elegido al azar.", "Takes you to another server of the game with free slots, picked at random."))

-- Admins: el dueño del juego, o alguien del grupo del juego con un rango alto o un rol de staff.
-- shortcut: solo ve staff que esté en el grupo del juego (o sea el dueño); un admin sin rango en el grupo
-- no se detecta. Si se conoce la lista de staff, añadir sus UserId a EXTRA_ADMINS.
local ADMIN_MIN_RANK = 200 -- rangos de grupo de 200 en adelante suelen ser staff
local ADMIN_ROLE_WORDS = { "admin", "mod", "dev", "owner", "staff", "manager", "creator", "tester", "helper" }
local EXTRA_ADMINS = {} -- [UserId] = true
local adminWatch, adminKick, adminHop = false, false, false
local adminCache = {}

local function isAdmin(p)
	if adminCache[p.UserId] ~= nil then return adminCache[p.UserId] end
	local result = false
	if EXTRA_ADMINS[p.UserId] or (game.CreatorType == Enum.CreatorType.User and p.UserId == game.CreatorId) then
		result = true
	elseif game.CreatorType == Enum.CreatorType.Group then
		local okRank, rank = pcall(p.GetRankInGroup, p, game.CreatorId)
		local okRole, role = pcall(p.GetRoleInGroup, p, game.CreatorId)
		if okRank and rank >= ADMIN_MIN_RANK then result = true end
		if okRole and type(role) == "string" then
			for _, word in ADMIN_ROLE_WORDS do
				if role:lower():find(word, 1, true) then result = true end
			end
		end
	end
	adminCache[p.UserId] = result
	return result
end

local function checkAdmin(p)
	if p == player or not (adminWatch or adminKick or adminHop) or not isAdmin(p) then return end
	log(T("Admin en el servidor: ", "Admin in the server: ") .. p.Name, "warn")
	if adminKick then
		player:Kick(T("El Hoyo Hub: admin detectado (", "El Hoyo Hub: admin detected (") .. p.Name .. ")")
	elseif adminHop then
		serverHop()
	end
end

local function checkAllPlayers()
	for _, p in Players:GetPlayers() do task.spawn(checkAdmin, p) end
end
table.insert(cleanup, Players.PlayerAdded:Connect(checkAdmin))

section(pageMisc, L("Seguridad", "Safety"))
toggle(pageMisc, L("Detectar admins", "Detect admins"), function(on)
	adminWatch = on
	if on then checkAllPlayers() end
end, L("Avisa cuando hay o entra un admin: el dueño del juego o alguien con rango de staff en su grupo.",
	"Warns you when an admin is in or joins: the game owner or someone with a staff rank in its group."))
toggle(pageMisc, L("Auto Kick si hay admin", "Auto Kick if admin"), function(on)
	adminKick = on
	if on then checkAllPlayers() end
end, L("Te saca del juego en cuanto detecta un admin en el servidor.", "Kicks you from the game as soon as an admin is detected in the server."))
toggle(pageMisc, L("Auto Hop si hay admin", "Auto Hop if admin"), function(on)
	adminHop = on
	if on then checkAllPlayers() end
end, L("Te cambia a otro servidor en cuanto detecta un admin. Si Auto Kick también está encendido, gana Auto Kick.",
	"Moves you to another server as soon as an admin is detected. If Auto Kick is also on, Auto Kick wins."))

------------------------------------------------------------------ ESP
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
-- Marcas que solo ves tú: nombre y distancia encima de jugadores, cofres y frutas tiradas.
-- Jugadores además con contorno (Highlight: Roblox solo dibuja ~31 a la vez, por eso cofres y frutas no).
local ESP_MAX_DIST = 3000
local espOn = { players = false, chests = false, fruits = false }
local espFolder = Instance.new("Folder")
espFolder.Name = "ElHoyoHubESP"
espFolder.Parent = gui.Parent -- las BillboardGui no se dibujan dentro de una ScreenGui
table.insert(cleanup, { Disconnect = function() espFolder:Destroy() end })

local RARITY_COLOR = { "dim", "on", "accent", "err" } -- Común, Poco común, Rara, Ultra rara
local marks = {} -- objetivo -> { bb, label, hl, seen }

local function mark(target, part, text, color, outline)
	local m = marks[target]
	if not m then
		local bb = Instance.new("BillboardGui")
		bb.AlwaysOnTop = true
		bb.LightInfluence = 0
		bb.Size = UDim2.fromOffset(220, 32)
		bb.StudsOffset = Vector3.new(0, 3, 0)
		bb.MaxDistance = ESP_MAX_DIST
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Font = FONT_SEMI
		label.TextSize = 13
		label.TextStrokeTransparency = 0.35
		label.Parent = bb
		bb.Parent = espFolder
		m = { bb = bb, label = label }
		if outline then
			local hl = Instance.new("Highlight")
			hl.FillTransparency = 0.85
			hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			hl.Adornee = target
			hl.Parent = espFolder
			m.hl = hl
		end
		marks[target] = m
	end
	m.bb.Adornee = part
	m.label.Text = text
	m.label.TextColor3 = color
	if m.hl then
		m.hl.OutlineColor = color
		m.hl.FillColor = color
	end
	m.seen = true
end

local function firstPart(model)
	return model:FindFirstChild("Pos1") or model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
end

task.spawn(function()
	while alive do
		task.wait(0.3)
		for _, m in marks do m.seen = false end
		local hrp = getHRP()
		if hrp then
			if espOn.players then
				for _, p in Players:GetPlayers() do
					local char = p.Character
					local root = char and char:FindFirstChild("HumanoidRootPart")
					if p ~= player and root then
						local lv = char:GetAttribute("Level")
						mark(char, root, string.format("%s%s  [%d]", p.Name, lv and (" · Lv " .. lv) or "",
							(root.Position - hrp.Position).Magnitude), C.accent, true)
					end
				end
			end
			if espOn.chests then
				local inst = workspace:FindFirstChild("Instances")
				local folder = inst and inst:FindFirstChild("Chests")
				for _, c in folder and folder:GetChildren() or {} do
					local part = c:IsA("Model") and firstPart(c)
					if part then
						mark(c, part, string.format("%s  [%d]", T("Cofre", "Chest"), (part.Position - hrp.Position).Magnitude), C.warn)
					end
				end
			end
			if espOn.fruits then
				for _, f in groundFruits() do
					mark(f.tool, f.part, string.format("%s Fruit  [%d]", f.name, (f.part.Position - hrp.Position).Magnitude),
						C[RARITY_COLOR[f.rank]] or C.text)
				end
			end
		end
		for target, m in marks do
			if not m.seen then
				m.bb:Destroy()
				if m.hl then m.hl:Destroy() end
				marks[target] = nil
			end
		end
	end
end)

section(pageMisc, "ESP")
toggle(pageMisc, L("ESP jugadores", "Player ESP"), function(on) espOn.players = on end,
	L("Muestra el nombre, nivel y distancia de los demás jugadores, con contorno, a través de las paredes.",
		"Shows other players' name, level and distance, with an outline, through walls."))
toggle(pageMisc, L("ESP cofres", "Chest ESP"), function(on) espOn.chests = on end,
	L("Muestra dónde están los cofres del mapa y a qué distancia.", "Shows where the map's chests are and how far."))
toggle(pageMisc, L("ESP frutas", "Fruit ESP"), function(on) espOn.fruits = on end,
	L("Muestra las Devil Fruits tiradas en el suelo, con el color de su rareza.", "Shows Devil Fruits lying on the ground, colored by rarity."))
end

end

local waitingKey = false -- también lo usa la tecla para ocultar
------------------------------------------------------------------ Ajustes
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
section(pageSettings, L("Interfaz", "Interface"))
note(pageSettings, L("Idioma, tamaño del menú y estilo (tema y color de acento): pulsa tu perfil, abajo a la izquierda. Perfiles con nombre (guardar, cargar, borrar, papelera): arriba, junto al icono de guardar.",
	"Language, menu size and style (theme and accent colour): click your profile, bottom left. Named presets (save, load, delete, bin): at the top, next to the save icon."))

section(pageSettings, L("Idioma", "Language"))
button(pageSettings, "Español", function()
	UI:SetLanguage(1) -- la librería traduce todo y avisa al hub (syncLang)
	log("Idioma: español", "ok", true)
end, L("Pone el hub en español.", "Switches the hub to Spanish."))
button(pageSettings, "English", function()
	UI:SetLanguage(0)
	log("Language: English", "ok", true)
end, L("Pone el hub en inglés.", "Switches the hub to English."))

section(pageSettings, L("Interfaz", "Interface"))
local notifyToggle = toggle(pageSettings, L("Notificaciones", "Notifications"), function(on)
	config.notify = on
	saveConfig()
end, L("Muestra avisos arriba a la derecha. Los errores se avisan siempre.", "Shows notices at the top right. Errors are always shown."), true)
notifyToggle.set(config.notify)

button(pageSettings, L("Cambiar tecla para ocultar", "Change hide key"), function()
	if waitingKey then return end
	waitingKey = true
	log(T("Pulsa la tecla que quieras para mostrar u ocultar el hub", "Press the key you want to show or hide the hub"), "warn")
	local pressed
	repeat
		pressed = UIS.InputBegan:Wait()
	until pressed.UserInputType == Enum.UserInputType.Keyboard and not UIS:GetFocusedTextBox()
	config.key = pressed.KeyCode.Name
	saveConfig()
	task.defer(function() waitingKey = false end) -- que esa misma pulsación no oculte el hub
	log(T("Tecla para ocultar: ", "Hide key: ") .. config.key, "ok", true)
end, L("Elige la tecla que muestra u oculta el hub (ahora RightShift si no la has cambiado).", "Choose the key that shows or hides the hub (RightShift unless you changed it)."))

------------------------------------------------------------------ Autoexec
-- Autoexec = que el hub se abra solo:
--  * al entrar al juego: se escribe un cargador en la carpeta "autoexec" del executor, que la ejecuta sola
--    al entrar (solo hace algo en este juego);
--  * al cambiar de servidor sin salir de Roblox (hop, rejoin...): queue_on_teleport, por si el executor no
--    vuelve a pasar por autoexec.
-- El cargador descarga el hub de tu URL raw (la de tu loadstring): el script no puede leerse a sí mismo.
local AUTOEXEC_FILE = "autoexec/ElHoyoHub.lua"
local queueTeleport = queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport)

local function loaderSource()
	return string.format(
		"-- El Hoyo Hub (autoexec)\nif game.PlaceId ~= %d then return end\nif not game:IsLoaded() then game.Loaded:Wait() end\nloadstring(game:HttpGet(%q))()\n",
		game.PlaceId, config.hubUrl)
end

local function hasUrl()
	return config.hubUrl ~= nil and config.hubUrl:match("^https?://") ~= nil
end

-- Deja todo preparado según el ajuste actual; devuelve si se pudo escribir el archivo de autoexec
local function applyAutoexec()
	local wrote = false
	if config.autoExec and hasUrl() then
		if writefile then
			wrote = pcall(function()
				if makefolder and isfolder and not isfolder("autoexec") then makefolder("autoexec") end
				writefile(AUTOEXEC_FILE, loaderSource())
			end)
		end
		if queueTeleport then pcall(queueTeleport, loaderSource()) end
	elseif delfile and isfile then
		pcall(function()
			if isfile(AUTOEXEC_FILE) then delfile(AUTOEXEC_FILE) end
		end)
	end
	return wrote
end

section(pageSettings, "Autoexec")
input(pageSettings, "URL", L("URL raw del script", "Script raw URL"), config.hubUrl or "", function(text)
	config.hubUrl = text:match("^%s*(.-)%s*$")
	saveConfig()
	applyAutoexec()
end, L("La URL raw de tu loadstring. ElHoyoUI.lua se descarga del mismo sitio.", "The raw URL of your loadstring. ElHoyoUI.lua is downloaded from the same place."))
local autoExecToggle
autoExecToggle = toggle(pageSettings, "Autoexec", function(on)
	if on and not hasUrl() then
		autoExecToggle.set(false)
		return log(T("Pon antes la URL raw del script (empieza por https://)", "Set the script raw URL first (starts with https://)"), "warn")
	end
	config.autoExec = on
	saveConfig()
	local wrote = applyAutoexec()
	if not on then
		log(T("Autoexec apagado", "Autoexec off"), "ok", true)
	elseif wrote then
		log(T("Autoexec activado: el hub se abrirá solo al entrar al juego y al cambiar de servidor",
			"Autoexec on: the hub will open by itself when you join the game and when you change server"), "ok", true)
	else
		log(T("Tu executor no deja escribir en autoexec: solo se abrirá al cambiar de servidor",
			"Your executor can't write to autoexec: it will only open when you change server"), "warn")
	end
end, L("El hub se abre solo al entrar al juego y al cambiar de servidor, y carga el último perfil que usaste.",
	"The hub opens by itself when you join the game and when you change server, and loads the last preset you used."), true)
autoExecToggle.set(config.autoExec == true)
applyAutoexec() -- cada vez que se abre, deja preparado el siguiente servidor

section(pageSettings, "Hub")
button(pageSettings, L("Apagar todo", "Turn everything off"), function()
	local n = 0
	for _, t in toggles do
		if t.value and not t.noSave then
			t.set(false)
			task.spawn(t.onChange, false)
			n += 1
		end
	end
	log(T("Apagadas ", "Turned off ") .. n .. T(" funciones", " features"), "ok", true)
end, L("Apaga todas las funciones encendidas sin cerrar el hub.", "Turns off every active feature without closing the hub."))
button(pageSettings, L("Cerrar El Hoyo Hub", "Close El Hoyo Hub"), function() genv.ElHoyoHubClose() end,
	L("Apaga todas las funciones y cierra el hub.", "Turns off every feature and closes the hub."))
end

------------------------------------------------------------------ Ocultar, cursor, cerrar
local function closeHub()
	alive = false -- todos los bucles miran esto y se paran
	for _, c in cleanup do c:Disconnect() end
	pcall(UI.Unload, UI)
	gui:Destroy()
end

-- Mostrar / ocultar con la tecla elegida (la librería no la gestiona: ToggleKey = false)
table.insert(cleanup, UIS.InputBegan:Connect(function(input)
	if waitingKey or UIS:GetFocusedTextBox() then return end
	if input.KeyCode.Name == config.key then main.Visible = not main.Visible end
end))

-- Cursor: el juego a veces lo esconde. Encima del hub o la consola se fuerza a que se vea.
table.insert(cleanup, game:GetService("RunService").RenderStepped:Connect(function()
	if overOurGui() then UIS.MouseIconEnabled = true end
end))

------------------------------------------------------------------ Inicio
genv.ElHoyoHubClose = closeHub
fitBoxes()
win:Finish() -- coloca todo y carga el último perfil usado (eso enciende sus funciones)
log(T("El Hoyo Hub cargado", "El Hoyo Hub loaded"), "ok", true)
for _, missing in missingRemotes do
	log(T("No encuentro la señal ", "Can't find the signal ") .. missing .. T(" (¿actualización del juego?)", " (game update?)"), "error")
end
end

local ok, err = xpcall(ElHoyoHubMain, debug.traceback)
if not ok then
	warn("[El Hoyo Hub] " .. tostring(err))
	if setclipboard then pcall(setclipboard, tostring(err)) end
	local sg = Instance.new("ScreenGui")
	sg.Name = "ElHoyoHubError"
	sg.ResetOnSpawn = false
	local box = Instance.new("TextBox")
	box.Size = UDim2.fromOffset(520, 220)
	box.Position = UDim2.new(0.5, -260, 0.5, -110)
	box.BackgroundColor3 = Color3.fromHex("15151E")
	box.TextColor3 = Color3.fromHex("EF4444")
	box.Font = Enum.Font.Code
	box.TextSize = 13
	box.TextWrapped = true
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.TextYAlignment = Enum.TextYAlignment.Top
	box.ClearTextOnFocus = false
	box.TextEditable = false
	box.Text = "El Hoyo Hub no ha podido abrirse (error copiado al portapapeles):\n\n" .. tostring(err)
	box.Parent = sg
	Instance.new("UICorner", box)
	sg.Parent = (gethui and gethui()) or game:GetService("CoreGui")
	task.delay(30, function() sg:Destroy() end)
end
