-- El Hoyo Hub
-- Versión: subir HUB_VERSION en cada cambio que se suba a GitHub (así se ve si el executor cargó el nuevo)
local HUB_VERSION = "1.3.1"
local UI_MIN_VERSION = 2 -- ElHoyoUI.lua con Library.Version menor no vale (cambió algo que el hub necesita)
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

-- Ciclo de vida. cleanup: lo que se deshace al cerrar, en orden (conexiones y objetos con :Disconnect()).
-- El cierre se registra ya aquí, antes de esperar a nada: así un hub a medio cargar (o que falló al cargar)
-- también se puede cerrar, y si se vuelve a ejecutar mientras este carga, este se para en vez de duplicarse.
local alive = true
local cleanup = {}
local function closeHub()
	if not alive then return end
	alive = false -- todos los bucles miran esto y se paran
	for _, c in cleanup do pcall(c.Disconnect, c) end
	table.clear(cleanup)
end
genv.ElHoyoHubClose = closeHub

-- Los errores en hilos propios (bucles, callbacks) antes morían en silencio en la consola de Roblox, que el
-- usuario no ve. Este task envuelve spawn/delay/defer: el error sale en la consola del hub (una vez por mensaje).
local reportError -- se asigna cuando existe log()
local realTask = task
local function guarded(fn)
	if type(fn) ~= "function" then return fn end -- task.spawn(hilo) se deja igual
	return function(...)
		local ok, err = xpcall(fn, debug.traceback, ...)
		if not ok and alive and reportError then reportError(err) end
	end
end
local task = setmetatable({
	spawn = function(fn, ...) return realTask.spawn(guarded(fn), ...) end,
	defer = function(fn, ...) return realTask.defer(guarded(fn), ...) end,
	delay = function(t, fn, ...) return realTask.delay(t, guarded(fn), ...) end,
}, { __index = realTask })

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


------------------------------------------------------------------ Idioma
-- La librería traduce sola los nombres: el texto base va en inglés y el español es su idioma 1.
-- L("es", "en") para nombres fijos (se registran en la librería); T("es", "en") para mensajes del momento.
local LANG = "es" -- lo fija syncLang() según el idioma de la librería
local function L(es, en)
	return { es = es, en = en }
end
local function T(es, en)
	return LANG == "en" and en or es
end

------------------------------------------------------------------ Configuración guardada
-- Se guarda en un archivo del executor (writefile/readfile). Si el executor no lo permite, dura solo la sesión.
local HttpService = game:GetService("HttpService")
local CONFIG_FILE = "ElHoyoHub.json"
local CONFIG_VERSION = 2 -- 2 = v1.3.1 (webhook fuera de los perfiles)
local bootNotes = {} -- avisos de la carga { es, en }: se escriben en la consola cuando existe (y se sabe el idioma)
local config = {
	profiles = {}, -- perfiles guardados con nombre: funciones encendidas + ajustes
	lang = genv.ElHoyoHubLang or "es",
	palette = "Abismo",
	key = "RightShift",
	notify = true,
	scale = 1,
	hubUrl = "https://raw.githubusercontent.com/saulandujar/elhoyohub/refs/heads/main/ElHoyoHub.lua", -- para Autoexec
}
-- Tipo de cada clave conocida: un valor de otro tipo (archivo editado a mano o roto) se ignora y queda el de
-- serie, en vez de romper la sección que lo lee. Las claves sin tipo aquí las valida quien las usa.
do -- bloque propio: CONFIG_TYPES solo se usa al cargar (límite de 200 locales)
local CONFIG_TYPES = {
	profiles = "table", lang = "string", palette = "string", key = "string", notify = "boolean", scale = "number",
	hubUrl = "string", webhook = "string", autoExec = "boolean", fishSpot = "table", juiceFruits = "table",
	fruitSel = "table", sellRarities = "table", boxRarities = "table", bossKeys = "string", configVersion = "number",
}
do
	local text
	pcall(function() if isfile and readfile and isfile(CONFIG_FILE) then text = readfile(CONFIG_FILE) end end)
	if text then
		local ok, data = pcall(HttpService.JSONDecode, HttpService, text)
		if ok and type(data) == "table" then
			for k, v in data do
				local want = CONFIG_TYPES[k]
				if type(k) == "string" and (not want or type(v) == want) then
					config[k] = v
				else
					table.insert(bootNotes, { "Ajuste ignorado (valor no válido): " .. tostring(k), "Setting ignored (invalid value): " .. tostring(k) })
				end
			end
		else
			-- Archivo roto: se guarda una copia antes de que el siguiente guardado lo pise
			if writefile then pcall(writefile, CONFIG_FILE .. ".bak", text) end
			table.insert(bootNotes, { "ElHoyoHub.json estaba dañado: se usan los ajustes de serie (copia en ElHoyoHub.json.bak)",
				"ElHoyoHub.json was damaged: using default settings (copy in ElHoyoHub.json.bak)" })
		end
	end
end
end
local saveQueued = false
local function saveConfig()
	if not writefile or saveQueued then return end
	saveQueued = true
	task.delay(1, function() -- agrupa varios cambios seguidos en una sola escritura
		saveQueued = false
		local ok, text = pcall(HttpService.JSONEncode, HttpService, config)
		if ok then pcall(writefile, CONFIG_FILE, text) end
	end)
end

-- Lo conseguido en esta sesión (sale en Inicio)
local session = { compass = 0, chests = 0, fruits = 0, juices = 0, fish = 0, quests = 0, deliveries = 0 }

-- Avisos a un webhook de Discord (config.webhook). Solo el texto del aviso: nada de tu cuenta.
-- Solo se aceptan URLs de webhook de Discord, sin menciones (@everyone/@here/roles no avisan a nadie) y como
-- mucho WEBHOOK_PER_MIN avisos por minuto (Discord corta a ~30).
local hubLog -- = log(), cuando existe
local wh = { fruits = false, bosses = false, admins = false }
local httpRequest = request or http_request or (syn and syn.request) or (http and http.request)
local function validWebhook(url)
	if type(url) ~= "string" then return false end
	local host = url:match("^https://([%w%.]+)/api/webhooks/%d+/[%w_%-]+$")
	return host == "discord.com" or host == "discordapp.com" or host == "ptb.discord.com" or host == "canary.discord.com"
end
-- done(ok, motivo) opcional: lo usa el botón de prueba para decir qué pasó
local sendWebhook
do -- bloque propio (límite de 200 locales)
local WEBHOOK_PER_MIN = 20
local whSent, whWarned = {}, -math.huge
function sendWebhook(text, done)
	local url = config.webhook
	local function finish(ok, why)
		if done then
			done(ok, why)
		elseif not ok and hubLog and os.clock() - whWarned > 60 then -- un aviso por minuto como mucho
			whWarned = os.clock()
			hubLog("Webhook: " .. why, "warn")
		end
	end
	if not httpRequest then return finish(false, T("tu executor no permite peticiones HTTP", "your executor can't make HTTP requests")) end
	if not validWebhook(url) then return finish(false, T("no hay una URL de webhook de Discord válida", "no valid Discord webhook URL")) end
	local now = os.clock()
	while whSent[1] and now - whSent[1] > 60 do table.remove(whSent, 1) end
	if #whSent >= WEBHOOK_PER_MIN then return finish(false, T("demasiados avisos seguidos, se descartan", "too many alerts in a row, dropped")) end
	table.insert(whSent, now)
	task.spawn(function()
		local ok, res = pcall(httpRequest, {
			Url = url, Method = "POST", Headers = { ["Content-Type"] = "application/json" },
			Body = HttpService:JSONEncode({
				content = "**El Hoyo Hub** · " .. tostring(text):sub(1, 1800),
				allowed_mentions = { parse = {} },
			}),
		})
		local code = ok and type(res) == "table" and tonumber(res.StatusCode)
		if not ok then
			finish(false, T("error de conexión", "connection error"))
		elseif code and (code < 200 or code >= 300) then
			finish(false, T("Discord respondió ", "Discord answered ") .. code
				.. (code == 404 and T(" (webhook borrado o URL mal copiada)", " (webhook deleted or URL miscopied)") or ""))
		else
			finish(true)
		end
	end)
end
end

------------------------------------------------------------------ Interfaz: El Hoyo UI
-- La ventana la dibuja ElHoyoUI.lua (librería propia, basada en Neverlose Reloaded y adaptada a El Hoyo Hub).
-- Se usa el archivo de la carpeta del executor si existe y es de una versión compatible; si no, se descarga del
-- mismo sitio que el hub. Aquí abajo hay una capa fina con las funciones de siempre (section, toggle, button,
-- note...) para que las secciones de funciones no tengan que saber nada de la librería.
local UI_URL = "https://raw.githubusercontent.com/saulandujar/elhoyohub/refs/heads/main/ElHoyoUI.lua"
local UI, uiErrors = nil, {}
do -- bloque propio (límite de 200 locales)
local function loadUI(source, from)
	if type(source) ~= "string" or #source < 1000 then return nil, from .. ": vacío o sin descargar" end
	local chunk, err = loadstring(source)
	if not chunk then return nil, from .. ": " .. tostring(err) end
	local ok, lib = pcall(chunk)
	if not ok or type(lib) ~= "table" then return nil, from .. ": " .. tostring(lib) end
	if (tonumber(lib.Version) or 1) < UI_MIN_VERSION then
		pcall(lib.Unload, lib)
		return nil, from .. ": versión " .. tostring(lib.Version or 1) .. " (hace falta " .. UI_MIN_VERSION .. ")"
	end
	return lib
end
	local localSource
	pcall(function() if isfile and readfile and isfile("ElHoyoUI.lua") then localSource = readfile("ElHoyoUI.lua") end end)
	local err
	if localSource then
		UI, err = loadUI(localSource, "ElHoyoUI.lua local")
		if err then table.insert(uiErrors, err) end
	end
	if not UI then
		local hubUrl = type(config.hubUrl) == "string" and config.hubUrl or ""
		local nextToHub = hubUrl:gsub("ElHoyoHub%.lua$", "ElHoyoUI.lua")
		local url = (nextToHub ~= hubUrl and nextToHub:match("^https://")) and nextToHub or UI_URL
		local ok, src = pcall(game.HttpGet, game, url)
		UI, err = loadUI(ok and src, url)
		if err then table.insert(uiErrors, err) end
	end
	if UI and localSource and #uiErrors > 0 then
		table.insert(bootNotes, { "Tu ElHoyoUI.lua local no vale (" .. uiErrors[1] .. "): uso el de internet. Bórralo o actualízalo.",
			"Your local ElHoyoUI.lua can't be used (" .. uiErrors[1] .. "): using the online one. Delete or update it." })
	end
end
assert(UI, "No pude cargar un ElHoyoUI.lua compatible (" .. table.concat(uiErrors, "; ")
	.. "). Sube ElHoyoUI.lua a GitHub junto a ElHoyoHub.lua o pon la versión nueva en la carpeta del executor.")
table.insert(cleanup, { Disconnect = function() pcall(UI.Unload, UI) end })

-- Colores fijos para lo que no dibuja la librería (consola, ESP, zona segura): los de la paleta Abismo roja
local C = {
	bg = Color3.fromRGB(13, 12, 19), surface = Color3.fromRGB(19, 18, 26), line = Color3.fromRGB(38, 34, 48),
	accent = Color3.fromRGB(225, 29, 72), on = Color3.fromRGB(34, 197, 94), warn = Color3.fromRGB(245, 158, 11),
	err = Color3.fromRGB(239, 68, 68), text = Color3.fromRGB(236, 236, 244), dim = Color3.fromRGB(128, 128, 150),
}
local FONT_SEMI = Enum.Font.GothamMedium

------------------------------------------------------------------ Idioma (traducción de nombres)
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
table.insert(cleanup, { Disconnect = function() gui:Destroy() end })

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
hubLog = log
do
	local reported = {} -- mismo error, una sola vez (un bucle que falla cada 0,2 s llenaría la consola)
	reportError = function(err)
		local first = tostring(err):match("^[^\n]*")
		if reported[first] then return end
		reported[first] = true
		log(T("Error interno: ", "Internal error: ") .. first, "error")
	end
end

------------------------------------------------------------------ Ventana y pestañas
local win = UI:CreateWindow({ Folder = "ElHoyoHub", ToggleKey = false, SubBrand = "HUB v" .. HUB_VERSION }) -- versión bajo el logo
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
-- Quién encendió cada interruptor de forma automática: owners[nombre] = { [dueño] = true }. Así Auto Expert,
-- Auto Quest y Treasure Rain no apagan lo que otro (o tú) necesita. Vacío/nil = lo encendiste tú.
local owners = {}

-- Interruptor. onChange(estado) al pulsarlo o al cargar un perfil; .set(v) lo cambia sin llamar a onChange.
-- noSave = es un ajuste, no una función (no entra en perfiles ni en "Apagar todo").
-- obj.transient = true: no va en perfiles, pero sí se apaga con "Apagar todo" y al cerrar (Seguir, Espectar).
local function toggle(page, text, onChange, desc, noSave)
	local key = type(text) == "table" and text.es or text
	local obj = { value = false, onChange = onChange, noSave = noSave }
	local o = {
		Name = uiText(text),
		Tip = desc and uiText(desc) or nil,
		Callback = function(v) -- pulsado a mano o cargado de un perfil: deja de ser de ninguna automatización
			obj.value = v
			owners[key] = nil
			task.spawn(onChange, v)
		end,
	}
	if noSave then o.Flag = false end
	local control = boxFor(page):Toggle(o)
	function obj.set(v)
		obj.value = v == true
		control:Set(obj.value, true)
	end
	toggles[key] = obj
	return obj
end

-- Una automatización pide (on = true) o suelta (on = false) un interruptor. Solo se apaga cuando lo suelta el
-- último que lo pidió; si ya lo tenías encendido tú, nadie lo apaga.
local function want(name, owner, on)
	local t = toggles[name]
	if not t then return end
	local set = owners[name]
	if on then
		if not t.value then
			owners[name] = { [owner] = true }
			t.set(true)
			task.spawn(t.onChange, true)
		elseif set then
			set[owner] = true
		end
	elseif set and set[owner] then
		set[owner] = nil
		if next(set) == nil then
			owners[name] = nil
			if t.value then
				t.set(false)
				task.spawn(t.onChange, false)
			end
		end
	end
end

-- Apaga las funciones (no los ajustes). sync = esperar a que cada una termine de apagarse (al cerrar el hub).
local function turnAllOff(sync)
	local n = 0
	for _, t in toggles do
		if t.value and (not t.noSave or t.transient) then
			t.set(false)
			if sync then pcall(t.onChange, false) else task.spawn(t.onChange, false) end
			n += 1
		end
	end
	table.clear(owners)
	return n
end
-- Lo primero al cerrar: apagar todo para devolver el personaje, la cámara y los objetos a como estaban
table.insert(cleanup, 1, { Disconnect = function() turnAllOff(true) end })


local function button(parent, text, onClick, desc)
	return boxFor(parent):Button({ Name = uiText(text), Callback = guarded(onClick), Tip = desc and uiText(desc) or nil })
end

-- Lista desplegable de una opción. onPick(índice). Se guarda en config, no en los perfiles.
local function combo(page, text, options, default, onPick, desc)
	local names = {}
	for i, opt in options do names[i] = uiText(opt) end
	return boxFor(page):Combo({
		Name = uiText(text), Options = names, Default = default, Flag = false,
		Tip = desc and uiText(desc) or nil, Callback = guarded(function(_, i) onPick(i) end),
	})
end

-- Lista desplegable de varias opciones. onChange(tabla índice -> true/false).
local function multi(page, text, options, defaults, onChange, desc)
	local names = {}
	for i, opt in options do names[i] = uiText(opt) end
	return boxFor(page):Multi({
		Name = uiText(text), Options = names, Default = defaults, Flag = false,
		Tip = desc and uiText(desc) or nil, Callback = guarded(onChange),
	})
end

-- Caja de texto. Flag = false: lo escrito se guarda en config (si hace falta), nunca en los perfiles; antes iba
-- en ellos y la URL del webhook salía al exportar o copiar un perfil.
local function input(page, text, placeholder, default, onDone, desc)
	return boxFor(page):Input({ Name = uiText(text), Placeholder = uiText(placeholder), Default = default, Flag = false,
		Callback = guarded(onDone), Tip = desc and uiText(desc) or nil })
end

-- 3 grupos y 11 pestañas: más no caben en la barra lateral (34 px por pestaña, 470 px de alto)
win:Group(uiText(L("PRINCIPAL", "MAIN")))
local pageHome = addTab(L("Inicio", "Home"), "STAR")
local pagePlayer = addTab(L("Jugador", "Player"), "RUNNING")
local pageTp = addTab("Teleports", "GLOBE")
local pageGuis = addTab(L("Tiendas", "Shops"), "TH_LARGE")
win:Group(uiText(L("FARMEO", "FARMING")))
local pageAuto = addTab(L("Automatización", "Automation"), "BOLT")
local pageBoss = addTab(L("Jefes", "Bosses"), "SKULL")
local pageTrain = addTab(L("Entrenamiento", "Training"), "FIRE")
local pageQuest = addTab(L("Misiones", "Quests"), "AWARD")
local pageFruits = addTab(L("Frutas", "Fruits"), "GEM")
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

-- Solo una función puede moverte a la vez (Sam, Chest, Train). Sin esto, Auto Sam te sacaba del dojo
-- en mitad de una partida y Auto Chest te movía cada medio segundo.
local busy -- nombre de la función que te está moviendo, o nil

-- Evitar jugadores (Zona segura): una función automática no te lleva a un sitio con otro jugador a menos de
-- avoid.radius studs. Espera hasta AVOID_WAIT s a que se vaya; con skip = true no espera (para saltar a otro
-- barril o cofre). Los teletransportes a mano (botones) no se frenan.
local avoid = { on = false, radius = 60 }
local AVOID_WAIT = 20
local avoidLogged = 0
local function playerNear(pos)
	for _, p in Players:GetPlayers() do
		local hrp = p ~= player and p.Character and p.Character:FindFirstChild("HumanoidRootPart")
		if hrp and (hrp.Position - pos).Magnitude < avoid.radius then return p.Name end
	end
end

-- Devuelve false si no te movió. shortcut: teletransporte directo; si el juego te expulsa por distancia, ir por tramos
local function teleport(pos, skip)
	local hrp = getHRP()
	if not hrp then return false end
	if busy == "Escape" then return false end -- Huida automática: nadie te mueve hasta que te recuperes
	if avoid.on and busy then
		local t0 = os.clock()
		local who = playerNear(pos)
		while who and not skip and os.clock() - t0 < AVOID_WAIT do
			task.wait(0.5)
			who = playerNear(pos)
		end
		if who then
			if os.clock() - avoidLogged > 5 then -- que no llene la consola
				avoidLogged = os.clock()
				log(T("Evitar jugadores: ", "Avoid players: ") .. who .. T(" está en el sitio, no voy (", " is there, not going (") .. busy .. ")")
			end
			return false
		end
		hrp = getHRP()
		if not hrp then return false end
	end
	hrp.CFrame = CFrame.new(pos)
	hrp.AssemblyLinearVelocity = Vector3.zero
	return true
end

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

section(pageTrain, "Haki")
for _, haki in HAKIS do
	local enabled, noEnergyLogged = false, false

	local function hasSkill()
		local char = player.Character
		return char ~= nil and (char:GetAttribute(haki.max) or 0) > 0
	end

	local t
	t = toggle(pageTrain, "Auto " .. haki.name, function(on)
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
		session.compass += 1
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
	-- dentro de los 10 studs del clic; si hay alguien (Evitar jugadores) se salta este cofre
	if not teleport(chest:GetPivot().Position + Vector3.new(0, 3, 0), true) then return end
	task.wait(speed.wait) -- que el servidor vea que estás al lado antes de clicar
	local t0 = os.clock()
	repeat
		clickChest(chest)
		task.wait(0.25)
	until not chest.Parent or os.clock() - t0 >= speed.stay
	if not chest.Parent then session.chests += 1 end
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

------------------------------------------------------------------ Auto Rewards y Challenges
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
-- DailyRewardService.RF.ClaimAll: reclama todos los regalos disponibles de golpe
local REWARD_EVERY = 60
local autoRewards, autoChallenges = false, false
local claimAllGifts = getRemote("DailyRewardService", "RF", "ClaimAll")

local function claimRewards()
	local ok, result = call(claimAllGifts, "InvokeServer")
	if not ok then
		log("Rewards: error " .. tostring(result), "error")
	elseif result then
		log(T("Rewards: reclamado -> ", "Rewards: claimed -> ") .. tostring(result), "ok", true)
	end
end

-- Challenges: se pulsan los botones "Claim" de su apartado en el menú del juego (PlayerGui.MenuNew).
-- shortcut: sin grabar; no sé la ruta exacta del apartado ni qué id pide ChallengeService.RE.Claim. Se buscan
-- botones con "Claim" dentro de cualquier parte de PlayerGui cuyo nombre contenga "Challenge". Si no hay ninguna,
-- lo dice una vez (entonces: abrir Challenges y pasar EscaneoGUI).
local challengeWarned = false
local function claimChallenges()
	local menu = player.PlayerGui -- el menú Challenges del juego; se busca en todas sus pantallas
	local claimed, found = 0, false
	for _, d in menu and menu:GetDescendants() or {} do
		if d:IsA("GuiButton") then
			local inside, p = false, d.Parent
			while p and p ~= menu do
				if p.Name:lower():find("challenge") then inside = true break end
				p = p.Parent
			end
			if inside then
				found = true
				local child = d:FindFirstChild("Text")
				local text = (child and child:IsA("TextLabel")) and child.Text or (d:IsA("TextButton") and d.Text or "")
				if text:lower():find("claim") and d.Visible then
					pressGuiButton(d)
					claimed += 1
					task.wait(0.3)
				end
			end
		end
	end
	if claimed > 0 then log(T("Challenges: reclamados ", "Challenges: claimed ") .. claimed, "ok", true) end
	if not found and not challengeWarned then
		challengeWarned = true
		log(T("Challenges: no encuentro su apartado en el menú. Ábrelo una vez y pásame EscaneoGUI",
			"Challenges: can't find its section in the menu. Open it once and send me EscaneoGUI"), "warn")
	end
end

section(pageAuto, L("Farmeo", "Farming"))
toggle(pageAuto, "Auto Rewards", function(on)
	autoRewards = on
	log("Auto Rewards " .. (on and "ON" or "OFF"))
	if on then claimRewards() end
end, L("Reclama las recompensas diarias y por hora al encenderlo y después cada minuto.",
	"Claims the daily and hourly rewards when turned on and then every minute."))
toggle(pageAuto, "Auto Claim Challenges (beta)", function(on)
	autoChallenges = on
	challengeWarned = false
	log("Auto Claim Challenges " .. (on and "ON" or "OFF"))
	if on then task.spawn(claimChallenges) end
end, L("Reclama los Challenges completados (menú Challenges del juego) cada minuto.",
	"Claims finished Challenges (the game's Challenges menu) every minute."))

task.spawn(function()
	while alive do
		task.wait(REWARD_EVERY)
		if autoRewards then claimRewards() end
		if autoChallenges then pcall(claimChallenges) end
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
			session.fish += 1
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

------------------------------------------------------------------ Combate compartido (Auto Quest, Auto Boss)
local QUEST_DIST = 4 -- studs detrás del enemigo

-- Arma: la que tengas en la mano si vale; si no, la primera del inventario. slot = "Melee" / "Sword" / ... o nil
local function equipWeapon(slot)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then return end
	local function fits(tool)
		local s = tool:IsA("Tool") and tool:GetAttribute("WeaponSlot")
		return s and s ~= "Utility" and (not slot or s == slot)
	end
	local held = char:FindFirstChildOfClass("Tool")
	if held and fits(held) then return end
	local backpack = player:FindFirstChild("Backpack")
	for _, tool in backpack and backpack:GetChildren() or {} do
		if fits(tool) then
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
	if ok and delivered then session.deliveries += 1 end
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

section(pageQuest, "Auto Quest", 1)
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
	want("Auto Pesca (beta)", "Quest", false) -- solo se apaga si nadie más (Auto Expert, tú) la quiere
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
			if claimQuest(giver) then
					session.quests += 1
					log(T("Quest: entregada", "Quest: turned in"), "ok", true)
				end
			returnTo(questStart)
			questStart = nil
			releaseMove("Quest")
		end
		task.wait(1)
		return
	end

	if fishing and not target then
		if not questFishing then
			questFishing = true
			want("Auto Pesca (beta)", "Quest", true)
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

section(pageQuest, "Auto Quest", 1) -- Merlin también da misiones: va en la misma caja
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
section(pagePlayer, L("Protección", "Protection"), 2)
toggle(pagePlayer, L("Zona segura", "Safe zone"), function(on)
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

toggle(pagePlayer, L("Evitar jugadores", "Avoid players"), function(on)
	avoid.on = on
	log(T("Evitar jugadores ", "Avoid players ") .. (on and "ON" or "OFF"))
end, L("Las funciones automáticas no te llevan a un sitio con otro jugador cerca: esperan a que se vaya o (barriles) pasan al siguiente.",
	"Automatic features don't take you somewhere with another player nearby: they wait until they leave or (barrels) skip to the next."))
do
	local RADII = { 30, 60, 100, 200 }
	local names = {}
	for i, r in RADII do names[i] = r .. " studs" end
	local pick = table.find(RADII, tonumber(config.avoidRadius)) or 2
	avoid.radius = RADII[pick]
	combo(pagePlayer, L("Radio para evitar", "Avoid radius"), names, pick, function(i)
		avoid.radius = RADII[i]
		config.avoidRadius = RADII[i]
		saveConfig()
	end, L("A qué distancia de otro jugador no te teletransporta.", "How close to another player it won't teleport you."))
end

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

note(pagePlayer, L("Auto Sam, Auto Chest, Auto Train y Frutas te mueven por el mapa: si hay varios encendidos, se turnan.",
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
		session.fruits += 1
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
section(pageQuest, L("Ir a un NPC de misiones", "Go to a quest giver"), 2)
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
-- Menús de NPCs: te lleva un momento al NPC, le habla y te devuelve a donde estabas
-- shortcut: no sabemos cómo se habla con los NPCs; se prueban ClickDetector y ProximityPrompt.
-- Si el juego cierra el menú al alejarte, habría que quedarse junto al NPC.
local function talkTo(entry)
	local npc, hrp = merchant(entry.model), getHRP()
	if not npc then return log(T("No encuentro a ", "Can't find ") .. entry.name, "warn") end
	if not hrp then return end
	if not claimMove("GUIs") then return log(T("Otra función te está moviendo, prueba en un momento", "Another feature is moving you, try again in a moment"), "warn") end
	local back = hrp.CFrame
	-- shortcut: el clic solo vale a menos de 32 studs (lo comprueba el servidor), así que hay que ir; se vuelve al
	-- instante y la ventana se queda abierta. Si alguna tienda se cierra al alejarte, habría que quedarse.
	teleport(npc:GetPivot().Position + Vector3.new(0, 3, 4))
	task.wait(0.2)
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
	task.wait(0.25)
	hrp = getHRP()
	if hrp then hrp.CFrame = back end
	releaseMove("GUIs")
	if talked then
		log(T("Abriendo el menú de ", "Opening the menu of ") .. entry.name)
	else
		log(T("No sé cómo hablar con ", "Don't know how to talk to ") .. entry.name, "warn")
	end
end

section(pageGuis, L("Tiendas y NPCs", "Shops and NPCs"))
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
--  * Beber: en la mano y clic, uno a uno (la pantalla Drink con "Drink all" es la del bar, no de estos zumos).
-- Exprimidor (confirmado por el usuario): un clic y a los pocos segundos da los zumos de todas las frutas.
-- Sin confirmar: si se nota un barril vacío.
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
local BARREL_COOLDOWN = 180 -- shortcut: el usuario calcula 2-3 min hasta que se rellena; mirar si el barril cambia al vaciarse
local autoStats = false
local visited = {} -- pieza del barril -> os.clock() de la última visita
local juiceFailed = false -- os.clock() del último fallo, o false
config.juiceFruits = config.juiceFruits or {}
local fruitNames = { Banana = true, ["Prickly Pear"] = true } -- y las que salgan de los barriles
-- Las "...Grapple" salen de los barriles pero no dan zumo (confirmado por el usuario): se tiran
local function isGrapple(name) return name:find("Grapple%s*$") ~= nil end
for name in config.juiceFruits do
	if isGrapple(name) then config.juiceFruits[name] = nil else fruitNames[name] = true end
end

local function tools()
	local out = {}
	for _, holder in { player:FindFirstChild("Backpack"), player.Character } do
		for _, t in holder and holder:GetChildren() or {} do
			if t:IsA("Tool") then table.insert(out, t) end
		end
	end
	return out
end
local function humanoid() return player.Character and player.Character:FindFirstChildOfClass("Humanoid") end
local function isDrink(t) -- "Banana Juice", "Coconut Milk"...
	return t.Name:find("Juice") ~= nil or t.Name:find("Smoothie") ~= nil or t.Name:find("Milk") ~= nil
end

-- Tirar las Grapple: en la mano y fuera del personaje (como la tecla Retroceso); si no se suelta, la tecla
local function dropGrapples()
	local hum = humanoid()
	if not hum then return end
	local n = 0
	for _, t in tools() do
		if isGrapple(t.Name) and t.Parent then
			hum:EquipTool(t)
			task.wait(0.2)
			if t.CanBeDropped then pcall(function() t.Parent = workspace end) end
			task.wait(0.2)
			if t.Parent == player.Character then
				VIM:SendKeyEvent(true, Enum.KeyCode.Backspace, false, game)
				VIM:SendKeyEvent(false, Enum.KeyCode.Backspace, false, game)
				task.wait(0.3)
			end
			if t.Parent ~= player.Character and t.Parent ~= player:FindFirstChild("Backpack") then n += 1 end
		end
	end
	hum:UnequipTools()
	if n > 0 then log(T("Auto Stats: tiradas ", "Auto Stats: dropped ") .. n .. " Grapple") end
end

-- Todos los barriles y cajas del mapa, en ruta (siempre al más cercano desde donde estás), sin pausas largas
local function collect()
	local hrp = getHRP()
	local map = workspace:FindFirstChild("Map")
	local root = map and map:FindFirstChild("Barrels")
	if not (hrp and root) then return end
	local pending = {}
	for _, cd in root:GetDescendants() do
		if cd:IsA("ClickDetector") and cd.Parent:IsA("BasePart")
			and os.clock() - (visited[cd.Parent] or -math.huge) > BARREL_COOLDOWN then
			table.insert(pending, cd)
		end
	end
	local before = {}
	for _, t in tools() do before[t] = true end
	local here, clicked, skipped = hrp.Position, 0, 0
	local char = player.Character
	while #pending > 0 and autoStats and player.Character == char and getHRP() do
		local best, bestD = 1, math.huge
		for i, cd in pending do
			local d = (cd.Parent.Position - here).Magnitude
			if d < bestD then best, bestD = i, d end
		end
		local cd = table.remove(pending, best)
		local part = cd.Parent
		if part.Parent then
			here = part.Position
			if teleport(part.Position + Vector3.new(0, 4, 0), true) then
				visited[part] = os.clock()
				task.wait(0.2) -- que el servidor vea que estás al lado (ClickDetector de 8 studs)
				if fireclickdetector then fireclickdetector(cd, 0) end
				clicked += 1
				task.wait(0.1)
			else
				skipped += 1 -- hay alguien: se prueba en la siguiente vuelta
			end
		end
	end
	task.wait(0.5) -- las últimas frutas pueden tardar en llegar
	-- lo nuevo que no es zumo ha salido de los barriles: es fruta (así se aprenden las que no conocíamos)
	local got = 0
	for _, t in tools() do
		if not before[t] and not isDrink(t) and not isGrapple(t.Name) then
			got += 1
			if not fruitNames[t.Name] then
				fruitNames[t.Name] = true
				config.juiceFruits[t.Name] = true
				saveConfig()
				log(T("Auto Stats: fruta nueva ", "Auto Stats: new fruit ") .. t.Name)
			end
		end
	end
	if clicked == 0 and skipped == 0 then return end -- vuelta sin barriles listos: nada que contar
	log(T("Auto Stats: ", "Auto Stats: ") .. clicked .. T(" barriles", " barrels")
		.. (skipped > 0 and (", " .. skipped .. T(" con gente", " with people")) or "") .. T(", frutas nuevas ", ", new fruits ") .. got)
end

-- start: adónde volver nada más clicar (o la zona segura); los zumos llegan aunque no estés al lado
local function makeJuice(start)
	if juiceFailed and os.clock() - juiceFailed < 60 then return end
	local count = 0
	for _, t in tools() do
		if fruitNames[t.Name] then count += 1 end
	end
	if count == 0 then return end
	-- JuicingBowl es una carpeta (no tiene GetPivot): se usa su pieza con ClickDetector
	local map = workspace:FindFirstChild("Map")
	local other = map and map:FindFirstChild("Other")
	local bowl = other and other:FindFirstChild("JuicingBowl", true)
	local detector
	for _, d in bowl and bowl:GetDescendants() or {} do
		if d:IsA("ClickDetector") and d.Parent:IsA("BasePart") then
			detector = d
			if d.Parent.Name == "Bowl" then break end
		end
	end
	if not detector then
		return log(T("Auto Stats: no encuentro el exprimidor (Map.Other...JuicingBowl)", "Auto Stats: can't find the juicer (Map.Other...JuicingBowl)"), "warn")
	end
	if not teleport(detector.Parent.Position + Vector3.new(0, 3, 4)) then return end -- alguien en el exprimidor
	task.wait(0.25)
	-- Un clic y a los pocos segundos convierte todas las frutas en zumos (confirmado por el usuario)
	if fireclickdetector then fireclickdetector(detector, 0) end
	task.wait(0.2)
	returnTo(start) -- shortcut: si resulta que hay que quedarse al lado mientras exprime, esperar aquí antes de volver
	local t0 = os.clock()
	local left
	repeat
		task.wait(0.5)
		left = 0
		for _, t in tools() do
			if fruitNames[t.Name] then left += 1 end
		end
	until left < count or os.clock() - t0 > 10
	if left >= count then
		juiceFailed = os.clock() -- no insistir en cada vuelta: otra vez dentro de 1 min
		return log(T("Auto Stats: el exprimidor no gasta las frutas. Pásame lo que salga en la consola",
			"Auto Stats: the juicer doesn't use the fruits. Send me what the console shows"), "warn")
	end
	task.wait(1) -- por si los zumos llegan uno a uno
	log(T("Auto Stats: exprimidas ", "Auto Stats: juiced ") .. (count - left) .. T(" frutas", " fruits"))
end

-- Los zumos se beben como cualquier Tool: en la mano y clic (confirmado por el usuario; no tienen "Drink all").
-- Algunos se quedaban sin beber: el juego tarda en dejar beber el siguiente (animación). Ahora cada zumo se
-- reintenta hasta que desaparece y se dan hasta 3 pasadas por si quedó alguno.
local function drinkGone(d)
	return not (d:IsDescendantOf(player) or (player.Character and d:IsDescendantOf(player.Character)))
end

-- Beber a la vez: todas las bebidas en el personaje al mismo tiempo y Activate en todas seguidas. Renombrarlas no
-- sirve: el nombre solo cambia en tu pantalla y el servidor las sigue viendo separadas.
-- shortcut: no sé si el servidor acepta varias Tools en la mano; las que no se gasten van al bucle de una en una.
local function drinkTogether()
	local char, hum = player.Character, humanoid()
	if not (char and hum) then return end
	local list = {}
	for _, t in tools() do
		if isDrink(t) then table.insert(list, t) end
	end
	if #list < 2 then return end
	for _, d in list do d.Parent = char end
	task.wait(0.3)
	for _, d in list do pcall(function() d:Activate() end) end
	task.wait(1.5)
	local gone = 0
	for _, d in list do
		if drinkGone(d) then gone += 1 end
	end
	hum:UnequipTools()
	session.juices += gone
	if gone > 0 then log(T("Auto Stats: bebidos a la vez ", "Auto Stats: drank at once ") .. gone .. "/" .. #list, "ok") end
end

local drinking = false
local function drinkAll()
	if drinking then return end
	drinking = true
	pcall(drinkTogether)
	local drank, failed = 0, {}
	for _ = 1, 3 do
		local list = {}
		for _, t in tools() do
			if isDrink(t) then table.insert(list, t) end
		end
		if #list == 0 then break end
		table.clear(failed)
		for _, d in list do
			if not autoStats then break end
			local hum = humanoid()
			if not hum then
				drinking = false
				return
			end
			for try = 1, 6 do
				if drinkGone(d) then break end
				if d.Parent ~= player.Character then
					hum:EquipTool(d)
					task.wait(0.3)
				end
				d:Activate()
				if try >= 3 then clickMouse() end -- si Activate no basta, clic real
				local t0 = os.clock()
				while not drinkGone(d) and os.clock() - t0 < 1.2 do task.wait(0.1) end
			end
			if drinkGone(d) then drank += 1 else table.insert(failed, d.Name) end
		end
	end
	local hum = humanoid()
	if hum then hum:UnequipTools() end
	drinking = false
	session.juices += drank
	if drank > 0 then log(T("Auto Stats: bebidos ", "Auto Stats: drank ") .. drank .. T(" zumos", " juices"), "ok", true) end
	if #failed > 0 then
		log(T("Auto Stats: no se gastaron al clicar: ", "Auto Stats: not used up by clicking: ") .. table.concat(failed, ", "), "warn")
	end
end

section(pageAuto, L("Farmeo", "Farming"))
toggle(pageAuto, "Auto Stats (beta)", function(on)
	autoStats = on
	juiceFailed = false
	if not on then releaseMove("Stats") end
	log("Auto Stats " .. (on and "ON" or "OFF"))
end, L("Clica barriles y cajas para sacar frutas normales, las exprime en el puesto de zumos y se bebe todos los zumos seguidos.",
	"Clicks barrels and crates for normal fruits, juices them at the juice stand and drinks every juice in a row."))

task.spawn(function()
	while alive do
		task.wait(2)
		if autoStats and getHRP() and claimMove("Stats") then -- sin personaje (muerto): esperar al nuevo
			local hrp = getHRP()
			local start = hrp and hrp.CFrame
			local ok, err = pcall(function()
				collect()
				makeJuice(start)
				dropGrapples()
				drinkAll()
			end)
			if not ok then log("Auto Stats: error " .. tostring(err), "error") end
			if start then returnTo(start) end
			releaseMove("Stats")
			task.wait(5) -- siempre recogiendo: los barriles vacíos se saltan solos (BARREL_COOLDOWN)
		end
	end
end)

-- Vigila el inventario: si aparece un zumo (el exprimidor tarda, o te lo dan), se bebe aunque no toque vuelta
task.spawn(function()
	while alive do
		task.wait(3)
		if autoStats and (not busy or busy == "Stats") then
			for _, t in tools() do
				if isDrink(t) then
					pcall(drinkAll)
					break
				end
			end
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
-- Te echaron a los 20 min con solo el aviso Idled: ahora además, cada 2 min, clic virtual, movimiento de
-- ratón y un saltito (por si el juego mira el personaje y no solo la entrada).
local function nudge()
	VirtualUser:CaptureController()
	VirtualUser:ClickButton2(Vector2.new())
	local m = UIS:GetMouseLocation()
	VIM:SendMouseMoveEvent(m.X + 2, m.Y, game)
	VIM:SendMouseMoveEvent(m.X, m.Y, game)
end
table.insert(cleanup, player.Idled:Connect(function()
	if antiAfk then nudge() end
end))
task.spawn(function()
	while alive do
		task.wait(120)
		if antiAfk then
			nudge()
			local h = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
			if h and not busy then h.Jump = true end
		end
	end
end)

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
section(pagePlayer, L("Protección", "Protection"), 2)
toggle(pagePlayer, "Auto Respawn", function(on)
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
local function serverHop(fewest)
	-- Lista pública de servidores de Roblox; uno al azar con hueco que no sea este (o el que tenga menos gente)
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
	local pick = options[math.random(#options)]
	if fewest == true then
		local best
		for _, sv in data.data do
			if table.find(options, sv.id) and (not best or (sv.playing or 0) < (best.playing or 0)) then best = sv end
		end
		pick = best and best.id or pick
	end
	log(T("Cambiando de servidor...", "Switching server..."), "ok", true)
	TeleportService:TeleportToPlaceInstance(game.PlaceId, pick, player)
end
button(pageMisc, L("Server Hop (menos gente)", "Server Hop (fewest players)"), function() serverHop(true) end,
	L("Te lleva al servidor con menos jugadores de la lista.", "Takes you to the server with the fewest players in the list."))
button(pageMisc, "Server Hop", function() serverHop() end, L("Te lleva a otro servidor del juego con hueco, elegido al azar.", "Takes you to another server of the game with free slots, picked at random."))

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
	if wh.admins then sendWebhook(T("Admin en el servidor", "Admin in the server")) end
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
local ESP_MAX_DIST = math.huge -- se ve desde cualquier distancia (si el juego tiene cargado al objetivo)
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
						mark(char, root, string.format("%s%s  %d studs", p.Name, lv and (" · Lv " .. lv) or "",
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
						mark(c, part, string.format("%s  %d studs", T("Cofre", "Chest"), (part.Position - hrp.Position).Magnitude), C.warn)
					end
				end
			end
			if espOn.fruits then
				for _, f in groundFruits() do
					mark(f.tool, f.part, string.format("%s Fruit  %d studs", f.name, (f.part.Position - hrp.Position).Magnitude),
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

------------------------------------------------------------------ Movilidad (pestaña Jugador)
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
-- Todo en tu cliente: el juego podría notar velocidades raras (shortcut: sin anti-cheat conocido; si expulsa,
-- bajar los valores).
local move = { fly = false, speed = false, jump = false, infJump = false, noclip = false, clickTp = false }
local FLY_SPEEDS, WALK_SPEEDS, JUMP_MULTS = { 50, 100, 200, 400 }, { 24, 32, 50, 75, 100 }, { 1.5, 2, 3, 5 }
local flySpeed = FLY_SPEEDS[tonumber(config.flySpeed) or 2] or 100
local walkSpeed = WALK_SPEEDS[tonumber(config.walkSpeed) or 2] or 32
local jumpMult = JUMP_MULTS[tonumber(config.jumpMult) or 2] or 2
local base = {} -- valores del juego antes de tocarlos: { walk, power, height }

local function hum()
	return player.Character and player.Character:FindFirstChildOfClass("Humanoid")
end
local function remember()
	local h = hum()
	if h and not base.walk then base = { walk = h.WalkSpeed, power = h.JumpPower, height = h.JumpHeight } end
end
table.insert(cleanup, player.CharacterAdded:Connect(function() base = {} end)) -- personaje nuevo, valores nuevos

section(pagePlayer, L("Movilidad", "Movement"), 1)
toggle(pagePlayer, "Fly", function(on)
	move.fly = on
	local h, hrp = hum(), getHRP()
	if not on and h then h.PlatformStand = false end
	if not on and hrp then hrp.AssemblyLinearVelocity = Vector3.zero end
end, L("Vuela con W A S D hacia donde mira la cámara; Espacio sube y Ctrl baja.",
	"Fly with W A S D towards where the camera looks; Space goes up and Ctrl goes down."))
do
	local names = {}
	for i, v in FLY_SPEEDS do names[i] = tostring(v) end
	combo(pagePlayer, L("Velocidad de vuelo", "Fly speed"), names, table.find(FLY_SPEEDS, flySpeed) or 2, function(i)
		flySpeed = FLY_SPEEDS[i]
		config.flySpeed = i
		saveConfig()
	end, L("Studs por segundo al volar.", "Studs per second while flying."))
end
toggle(pagePlayer, "Speed", function(on)
	move.speed = on
	if on then remember() elseif hum() and base.walk then hum().WalkSpeed = base.walk end
end, L("Corres más rápido.", "You run faster."))
do
	local names = {}
	for i, v in WALK_SPEEDS do names[i] = tostring(v) end
	combo(pagePlayer, L("Velocidad al correr", "Walk speed"), names, table.find(WALK_SPEEDS, walkSpeed) or 2, function(i)
		walkSpeed = WALK_SPEEDS[i]
		config.walkSpeed = i
		saveConfig()
	end, L("WalkSpeed con Speed encendido (lo normal ronda 16).", "WalkSpeed with Speed on (normal is around 16)."))
end
toggle(pagePlayer, "Jump", function(on)
	move.jump = on
	local h = hum()
	if on then
		remember()
	elseif h and base.power then
		h.JumpPower, h.JumpHeight = base.power, base.height
	end
end, L("Saltas más alto.", "You jump higher."))
do
	local names = {}
	for i, v in JUMP_MULTS do names[i] = "x" .. v end
	combo(pagePlayer, L("Altura de salto", "Jump height"), names, table.find(JUMP_MULTS, jumpMult) or 2, function(i)
		jumpMult = JUMP_MULTS[i]
		config.jumpMult = i
		saveConfig()
	end, L("Cuántas veces el salto normal.", "How many times the normal jump."))
end
toggle(pagePlayer, L("Salto infinito", "Infinite jump"), function(on) move.infJump = on end,
	L("Puedes volver a saltar en el aire.", "You can jump again in mid-air."))
-- Colisión original de cada pieza que Noclip apagó, para devolverla al apagarlo (antes te quedabas sin colisión)
local noclipped = setmetatable({}, { __mode = "k" })
toggle(pagePlayer, "Noclip", function(on)
	move.noclip = on
	if not on then
		for p, was in noclipped do
			if p.Parent then p.CanCollide = was end
		end
		table.clear(noclipped)
	end
end,
	L("Atraviesas paredes y suelos.", "You go through walls and floors."))
toggle(pagePlayer, "Click TP", function(on) move.clickTp = on end,
	L("Mantén Alt y haz clic: te teletransporta a ese punto.", "Hold Alt and click: teleports you to that point."))

table.insert(cleanup, game:GetService("RunService").Heartbeat:Connect(function()
	local h, hrp = hum(), getHRP()
	if not (h and hrp) then return end
	if move.fly then
		local cam = workspace.CurrentCamera
		local dir = Vector3.zero
		if not UIS:GetFocusedTextBox() then
			if UIS:IsKeyDown(Enum.KeyCode.W) then dir += cam.CFrame.LookVector end
			if UIS:IsKeyDown(Enum.KeyCode.S) then dir -= cam.CFrame.LookVector end
			if UIS:IsKeyDown(Enum.KeyCode.D) then dir += cam.CFrame.RightVector end
			if UIS:IsKeyDown(Enum.KeyCode.A) then dir -= cam.CFrame.RightVector end
			if UIS:IsKeyDown(Enum.KeyCode.Space) then dir += Vector3.yAxis end
			if UIS:IsKeyDown(Enum.KeyCode.LeftControl) then dir -= Vector3.yAxis end
		end
		h.PlatformStand = true
		hrp.AssemblyLinearVelocity = dir.Magnitude > 0 and dir.Unit * flySpeed or Vector3.zero
	end
	-- el juego puede volver a poner sus valores: se repiten en cada frame
	if move.speed then
		remember()
		h.WalkSpeed = walkSpeed
	end
	if move.jump then
		remember()
		if base.power then h.JumpPower, h.JumpHeight = base.power * jumpMult, base.height * jumpMult end
	end
end))
table.insert(cleanup, game:GetService("RunService").Stepped:Connect(function()
	if not move.noclip or not player.Character then return end
	for _, p in player.Character:GetDescendants() do
		if p:IsA("BasePart") and p.CanCollide then
			if noclipped[p] == nil then noclipped[p] = true end
			p.CanCollide = false
		end
	end
end))
table.insert(cleanup, UIS.JumpRequest:Connect(function()
	local h = hum()
	if move.infJump and h then h:ChangeState(Enum.HumanoidStateType.Jumping) end
end))
table.insert(cleanup, UIS.InputBegan:Connect(function(input)
	if not move.clickTp or input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
	if not (UIS:IsKeyDown(Enum.KeyCode.LeftAlt) or UIS:IsKeyDown(Enum.KeyCode.RightAlt)) or overOurGui() then return end
	local hrp = getHRP()
	if hrp then
		hrp.CFrame = CFrame.new(mouse.Hit.Position + Vector3.new(0, 3, 0)) * hrp.CFrame.Rotation
		hrp.AssemblyLinearVelocity = Vector3.zero
	end
end))
end

------------------------------------------------------------------ Huida (pestaña Jugador, Protección)
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
-- Un god mode de verdad no se puede hacer desde el cliente: la vida la lleva el servidor. Lo más parecido: si la
-- vida baja del límite, te saca al cielo (zona segura o una plataforma temporal) hasta que te recuperas, y
-- ninguna función te mueve mientras tanto.
local LIMITS = { 20, 35, 50, 70 }
local escapeOn = false
local limit = LIMITS[tonumber(config.escapeAt) or 2] or 35
local escaping = false

local function escape(h)
	escaping = true
	busy = "Escape" -- se queda con el movimiento aunque otra función lo tuviera
	local hrp = getHRP()
	local temp
	if safePart then
		goSafe()
	elseif hrp then
		temp = Instance.new("Part")
		temp.Name = "ElHoyoHubEscape"
		temp.Anchored = true
		temp.Size = Vector3.new(20, 2, 20)
		temp.Transparency = 1
		temp.CFrame = CFrame.new(hrp.Position.X, SAFE_HEIGHT, hrp.Position.Z)
		temp.Parent = workspace
		hrp.CFrame = temp.CFrame + Vector3.new(0, 4, 0)
		hrp.AssemblyLinearVelocity = Vector3.zero
	end
	log(T("Huida: vida baja, te saco de ahí", "Escape: low health, getting you out"), "warn", true)
	local t0 = os.clock()
	while alive and h.Parent and h.Health > 0 and h.Health < h.MaxHealth * 0.9 and os.clock() - t0 < 60 do task.wait(0.5) end
	if temp then temp:Destroy() end
	if busy == "Escape" then busy = nil end
	escaping = false
	log(T("Huida: recuperado, las funciones siguen", "Escape: recovered, features carry on"))
end

section(pagePlayer, L("Protección", "Protection"), 2)
toggle(pagePlayer, L("Huida automática", "Auto escape"), function(on) escapeOn = on end,
	L("No es un god mode (la vida la lleva el servidor): si tu vida baja del límite, te lleva al cielo hasta que te recuperas.",
		"Not a god mode (the server owns your health): if your health drops below the limit, it takes you up to the sky until you recover."))
do
	local names = {}
	for i, v in LIMITS do names[i] = v .. "%" end
	combo(pagePlayer, L("Huir con vida bajo", "Escape below health"), names, table.find(LIMITS, limit) or 2, function(i)
		limit = LIMITS[i]
		config.escapeAt = i
		saveConfig()
	end, L("Porcentaje de vida que hace saltar la huida.", "Health percentage that triggers the escape."))
end
task.spawn(function()
	while alive do
		task.wait(0.2)
		local h = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if escapeOn and not escaping and h and h.Health > 0 and h.Health < h.MaxHealth * limit / 100 then
			task.spawn(escape, h)
		end
	end
end)
end

------------------------------------------------------------------ Auto Boss
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
-- Jefes de la wiki (datos.json, lista Enemies) y la isla donde salen, para ir allí si el jefe no está cargado
-- (el mapa solo carga lo cercano). shortcut: islas deducidas de la wiki y nombre del modelo sin comprobar (se busca
-- por texto en Alive.NPCs); si no lo encuentra, decir cómo se llama el modelo (ESP o EscaneoPersonaje).
local BOSSES = {
	{ name = "Captain Blacksurf", island = "IslandDeepwake" },
	{ name = "Gunner Captain", island = "IslandCaver" },
	{ name = "Ryuma", island = "IslandHalloween" },
	{ name = "Gecko Moria", island = "IslandHalloween" },
	{ name = "Perona", island = "IslandHalloween" },
	{ name = "Vokun" }, -- sin isla conocida: solo si está cargado (cerca)
}
local WEAPONS = { { L("La de la mano", "The one in hand"), false }, { L("Cualquiera", "Any"), nil }, { "Melee", "Melee" },
	{ L("Espada", "Sword"), "Sword" }, { L("Fruta", "Fruit"), "Fruit" } }
local MODES = { L("Encima + hitbox grande", "On top + big hitbox"), L("Detrás", "Behind") }
local modePick = math.clamp(tonumber(config.bossMode) or 1, 1, #MODES)
-- Encima: te pones pegado sobre el jefe mirando hacia abajo y su HumanoidRootPart se agranda en tu pantalla, así
-- cada clic le da. shortcut: el agrandado es solo local; vale si el juego mira los golpes desde el cliente
-- (si no hace más daño así, usar "Detrás").
local HITBOX, ABOVE = 25, 7
local grown = setmetatable({}, { __mode = "k" }) -- raíz del jefe -> valores originales
local function shrinkAll() -- deja los jefes como estaban (al apagar Auto Boss, cambiar de modo o cerrar)
	for root, was in grown do
		if root.Parent then root.Size, root.Transparency, root.CanCollide = was.size, was.transparency, was.canCollide end
	end
	table.clear(grown)
end
local function attackAbove(boss)
	local root, hrp = boss:FindFirstChild("HumanoidRootPart"), getHRP()
	if not (root and hrp) then return end
	if not grown[root] then
		grown[root] = { size = root.Size, transparency = root.Transparency, canCollide = root.CanCollide }
		root.Size = Vector3.new(HITBOX, HITBOX, HITBOX)
		root.Transparency = 0.85
		root.CanCollide = false
	end
	hrp.CFrame = CFrame.new(root.Position + Vector3.new(0, ABOVE, 0)) * CFrame.Angles(-math.pi / 2, 0, 0)
	hrp.AssemblyLinearVelocity = Vector3.zero
	local cam = workspace.CurrentCamera
	cam.CFrame = CFrame.lookAt(root.Position + Vector3.new(0, ABOVE + 14, 8), root.Position)
	local p, onScreen = cam:WorldToViewportPoint(root.Position)
	if onScreen then
		VIM:SendMouseMoveEvent(p.X, p.Y, game)
		VIM:SendMouseButtonEvent(p.X, p.Y, 0, true, game, 0)
		VIM:SendMouseButtonEvent(p.X, p.Y, 0, false, game, 0)
	end
end
local autoBoss = false
local bossPick = math.clamp(tonumber(config.bossPick) or 1, 1, #BOSSES)
local weaponPick = math.clamp(tonumber(config.bossWeapon) or 1, 1, #WEAPONS)
local bossStart, lastSearch, lastSkill, lastSeen = nil, -math.huge, 0, nil
local slotsLogged = false

local function findBoss(entry)
	local folder = workspace:FindFirstChild("Alive")
	local npcs = folder and folder:FindFirstChild("NPCs")
	local want = entry.name:lower()
	for _, m in npcs and npcs:GetChildren() or {} do
		local h = m:FindFirstChildOfClass("Humanoid")
		if h and h.Health > 0 and m:FindFirstChild("HumanoidRootPart") and m.Name:lower():find(want, 1, true) then return m end
	end
end

local function skillKeys()
	local keys = {}
	for k in tostring(config.bossKeys or "Z X C V"):gmatch("%S+") do
		local code = Enum.KeyCode[k:upper()]
		if code then table.insert(keys, code) end
	end
	return keys
end

section(pageBoss, "Auto Boss", 1)
toggle(pageBoss, "Auto Boss (beta)", function(on)
	autoBoss = on
	if not on then
		shrinkAll()
		if bossStart then returnTo(bossStart) end
		bossStart = nil
		releaseMove("Boss")
	end
	log("Auto Boss " .. (on and "ON" or "OFF"))
end, L("Va a por el jefe elegido y le ataca hasta matarlo; cuando reaparece, repite.",
	"Goes after the chosen boss and attacks it until it dies; when it respawns, repeats."))
do
	local names = {}
	for i, b in BOSSES do names[i] = b.name end
	combo(pageBoss, L("Jefe", "Boss"), names, bossPick, function(i)
		bossPick = i
		config.bossPick = i
		saveConfig()
	end, L("A qué jefe atacar.", "Which boss to attack."))
	local wnames = {}
	for i, w in WEAPONS do wnames[i] = w[1] end
	local mnames = {}
	for i, m in MODES do mnames[i] = m end
	combo(pageBoss, L("Cómo atacar", "How to attack"), mnames, modePick, function(i)
		modePick = i
		if i ~= 1 then shrinkAll() end
		config.bossMode = i
		saveConfig()
	end, L("Encima: pegado sobre el jefe con su hitbox agrandada y clic continuo. Detrás: como Auto Quest.",
		"On top: right above the boss with its hitbox enlarged and constant clicking. Behind: like Auto Quest."))
	combo(pageBoss, L("Arma", "Weapon"), wnames, weaponPick, function(i)
		weaponPick = i
		config.bossWeapon = i
		saveConfig()
	end, L("Con qué atacar: Melee, espada o la fruta (si tu fruta va en la mano).", "What to attack with: melee, sword or your fruit (if it goes in your hand)."))
	input(pageBoss, L("Teclas de habilidades", "Skill keys"), "Z X C V", config.bossKeys or "Z X C V", function(text)
		config.bossKeys = text
		saveConfig()
	end, L("Teclas que pulsa cada 2 s mientras ataca (habilidades de fruta o de arma). Vacío = ninguna.",
		"Keys it presses every 2 s while attacking (fruit or weapon skills). Empty = none."))
end
-- Aviso por webhook cuando aparece cualquier jefe de la lista (aunque Auto Boss esté apagado)
local warned = setmetatable({}, { __mode = "k" }) -- jefes ya avisados (no retiene modelos borrados)
task.spawn(function()
	while alive do
		task.wait(5)
		if wh.bosses then
			for _, b in BOSSES do
				local m = findBoss(b)
				if m and not warned[m] then
					warned[m] = true
					sendWebhook(T("Jefe vivo: ", "Boss alive: ") .. b.name)
				end
			end
		end
	end
end)
note(pageBoss, L("Si el jefe no está cargado, va a su isla y lo busca. Las islas y los nombres salen de la wiki: si no lo encuentra, dímelo.",
	"If the boss isn't loaded, it goes to its island and looks for it. Islands and names come from the wiki: if it can't find it, tell me."))

task.spawn(function()
	while alive do
		task.wait(0.15)
		if autoBoss and getHRP() and claimMove("Boss") then
			local entry = BOSSES[bossPick]
			local boss = findBoss(entry)
			if not boss then
				if lastSeen then
					log(T("Auto Boss: ", "Auto Boss: ") .. entry.name .. T(" derrotado (o desaparecido)", " defeated (or gone)"), "ok", true)
					lastSeen = nil
				end
				-- ir a su isla a buscarlo como mucho cada 15 s; entre medias, de vuelta a donde estabas
				if os.clock() - lastSearch > 15 and not entry.island then
					lastSearch = os.clock()
					log(T("Auto Boss: ", "Auto Boss: ") .. entry.name .. T(" no está cerca y no sé en qué isla sale: ve a su zona", " isn't nearby and I don't know its island: go to its area"))
				elseif os.clock() - lastSearch > 15 then
					lastSearch = os.clock()
					local map = workspace:FindFirstChild("Map")
					local island = map and map:FindFirstChild("Islands") and map.Islands:FindFirstChild(entry.island)
					local target = island and (island:FindFirstChild("QuestBoard") or island:FindFirstChildWhichIsA("BasePart", true))
					local hrp = getHRP()
					if target and hrp then
						if not bossStart then bossStart = hrp.CFrame end
						teleport(target:GetPivot().Position + Vector3.new(0, 5, 0))
						task.wait(2) -- que cargue la zona
						if not findBoss(entry) then
							log(T("Auto Boss: ", "Auto Boss: ") .. entry.name .. T(" no está ahora; espero a que salga", " isn't here now; waiting for it to spawn"))
							if bossStart then returnTo(bossStart) end
							bossStart = nil
						end
					end
				end
				releaseMove("Boss")
				task.wait(1)
			else
				local hrp = getHRP()
				if not bossStart and hrp then bossStart = hrp.CFrame end
				if lastSeen ~= boss then
					log(T("Auto Boss: atacando a ", "Auto Boss: attacking ") .. boss.Name)
					lastSeen = boss
				end
				local slot = WEAPONS[weaponPick][2]
				if slot ~= false then equipWeapon(slot) end
				if slot and not slotsLogged then
					local held = player.Character and player.Character:FindFirstChildOfClass("Tool")
					if not (held and held:GetAttribute("WeaponSlot") == slot) then
						slotsLogged = true
						local seen = {}
						for _, t in (player:FindFirstChild("Backpack") or player):GetChildren() do
							if t:IsA("Tool") and t:GetAttribute("WeaponSlot") then table.insert(seen, t.Name .. "=" .. t:GetAttribute("WeaponSlot")) end
						end
						log(T("Auto Boss: no tengo arma de tipo ", "Auto Boss: no weapon of type ") .. slot .. " (" .. table.concat(seen, ", ") .. ")", "warn")
					end
				end
				if modePick == 1 then attackAbove(boss) else attack(boss) end
				if os.clock() - lastSkill > 2 then
					lastSkill = os.clock()
					for _, key in skillKeys() do
						VIM:SendKeyEvent(true, key, false, game)
						VIM:SendKeyEvent(false, key, false, game)
						task.wait(0.15)
					end
				end
			end
		end
	end
end)
end

------------------------------------------------------------------ Inicio
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
local DISCORD_URL = nil -- poner aquí la invitación cuando exista
local hubStart = os.clock()
local rows = {}
local function row(key) rows[key] = note(pageHome, " ") end

local function span(seconds)
	seconds = math.max(0, math.floor(seconds))
	local h, m, s = seconds // 3600, seconds % 3600 // 60, seconds % 60
	if h > 0 then return string.format("%dh %02dm", h, m) end
	if m > 0 then return string.format("%dm %02ds", m, s) end
	return s .. "s"
end

section(pageHome, L("Servidor", "Server"), 1)
for _, k in { "players", "ping", "fps", "uptime", "clock", "xp" } do row(k) end
button(pageHome, L("Copiar enlace de este servidor", "Copy this server's link"), function()
	local link = string.format("https://www.roblox.com/games/start?placeId=%d&gameInstanceId=%s", game.PlaceId, game.JobId)
	if setclipboard then setclipboard(link) end
	log(T("Enlace copiado: tus amigos entran a este mismo servidor", "Link copied: your friends join this same server"), "ok", true)
end, L("Copia un enlace que mete a quien lo abra en este mismo servidor.", "Copies a link that puts whoever opens it in this same server."))

section(pageHome, L("Tú", "You"), 2)
for _, k in { "level", "session", "compass", "merlin", "active", "summary" } do row(k) end

section(pageHome, "El Hoyo Hub", 2)
note(pageHome, L("Versión " .. HUB_VERSION, "Version " .. HUB_VERSION))
button(pageHome, "Discord", function()
	if DISCORD_URL then
		if setclipboard then setclipboard(DISCORD_URL) end
		log(T("Invitación de Discord copiada", "Discord invite copied"), "ok", true)
	else
		log(T("Aún no hay Discord: muy pronto", "No Discord yet: coming soon"), "warn", true)
	end
end, L("Copia la invitación al Discord del hub.", "Copies the hub's Discord invite."))

section(pageHome, L("Novedades", "What's new"), 1)
note(pageHome, L("v1.3: Auto Boss con Vokun y modo encima con hitbox grande, zumos a la vez y vigilando el inventario, Auto Expert, Auto Treasure Rain, vender peces, seguir y espectar jugadores, webhook de Discord, Server Hop con menos gente, modo AFK total y resumen de la sesión.",
	"v1.3: Auto Boss with Vokun and on-top mode with a big hitbox, juices at once and inventory watch, Auto Expert, Auto Treasure Rain, sell fish, follow and spectate players, Discord webhook, Server Hop with fewest players, full AFK mode and a session summary."))
note(pageHome, L("v1.2: nueva distribución (Inicio, Jefes, Jugador), Auto Boss, Movilidad (fly, speed, jump, noclip, click TP), Huida automática, Auto Claim Challenges, Auto Rewards, ESP a cualquier distancia, tiendas más rápidas y Anti-AFK reforzado.",
	"v1.2: new layout (Home, Bosses, Player), Auto Boss, Movement (fly, speed, jump, noclip, click TP), Auto escape, Auto Claim Challenges, Auto Rewards, ESP at any distance, faster shops and a stronger Anti-AFK."))

local frames, fps = 0, 0
table.insert(cleanup, game:GetService("RunService").RenderStepped:Connect(function() frames += 1 end))
task.spawn(function()
	while alive do
		fps, frames = frames, 0
		local now = workspace:GetServerTimeNow()
		local function set(key, text) if rows[key] then rows[key].Text = text end end
		set("players", T("Jugadores: ", "Players: ") .. #Players:GetPlayers() .. " / " .. Players.MaxPlayers)
		set("ping", "Ping: " .. math.floor(player:GetNetworkPing() * 2000) .. " ms") -- GetNetworkPing es solo ida
		set("fps", "FPS: " .. fps)
		set("uptime", T("Servidor abierto: ", "Server up: ") .. span(workspace.DistributedGameTime))
		set("clock", workspace:GetAttribute("IsNight") and T("Ahora es de noche", "It's night now") or T("Ahora es de día", "It's day now"))
		local xpEnds, xpMult = workspace:GetAttribute("XpEventEndsAt"), workspace:GetAttribute("XpEventMultiplier")
		if type(xpEnds) == "number" and xpEnds > now then
			set("xp", T("Evento de EXP x", "EXP event x") .. tostring(xpMult) .. T(", quedan ", ", ") .. span(xpEnds - now) .. T("", " left"))
		else
			set("xp", T("Sin evento de EXP", "No EXP event"))
		end
		local char = player.Character
		set("level", T("Nivel: ", "Level: ") .. tostring(char and char:GetAttribute("Level") or "?"))
		set("session", T("Sesión con el hub: ", "Session with the hub: ") .. span(os.clock() - hubStart))
		local token = player:GetAttribute("CompassTokenAt")
		set("compass", T("Próximo compass: ", "Next compass: ") .. ((type(token) == "number" and token > now) and span(token - now) or T("listo", "ready")))
		local merlin = player:GetAttribute("MerlinCooldownEnd")
		set("merlin", "Merlin: " .. ((type(merlin) == "number" and merlin > now) and span(merlin - now) or T("listo", "ready")))
		local active = 0
		for _, t in toggles do
			if t.value then active += 1 end
		end
		set("active", T("Funciones encendidas: ", "Features on: ") .. active)
		set("summary", string.format(T("Sesión: %d compass, %d cofres, %d frutas, %d zumos, %d peces, %d misiones, %d entregas",
			"Session: %d compass, %d chests, %d fruits, %d juices, %d fish, %d quests, %d deliveries"),
			session.compass, session.chests, session.fruits, session.juices, session.fish, session.quests, session.deliveries))
		task.wait(1)
	end
end)
end

------------------------------------------------------------------ Jugadores: seguir y espectar (pestaña Jugador)
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
local targetName = ""
local following, spectating = false, false

local function findPlayer()
	if targetName == "" then return nil end
	local want = targetName:lower()
	for _, p in Players:GetPlayers() do
		if p ~= player and (p.Name:lower():find(want, 1, true) or p.DisplayName:lower():find(want, 1, true)) then return p end
	end
end
local function targetRoot()
	local p = findPlayer()
	return p, p and p.Character and p.Character:FindFirstChild("HumanoidRootPart")
end

section(pagePlayer, L("Jugadores", "Players"), 1)
input(pagePlayer, L("Jugador", "Player"), L("nombre (vale un trozo)", "name (part is fine)"), "", function(text)
	targetName = text:match("^%s*(.-)%s*$")
	local p = findPlayer()
	log(p and (T("Jugador elegido: ", "Player picked: ") .. p.Name) or T("No hay nadie con ese nombre", "Nobody with that name"), p and "info" or "warn")
end, L("Escribe el nombre (o parte) del jugador para ir a él, seguirle o espectarle.", "Type the player's name (or part of it) to go to, follow or spectate them."))
button(pagePlayer, L("Ir a él", "Go to them"), function()
	local p, root = targetRoot()
	if not root then return log(T("No veo a ese jugador (¿lejos o sin elegir?)", "Can't see that player (far away or not picked?)"), "warn") end
	local hrp = getHRP()
	if hrp then hrp.CFrame = root.CFrame * CFrame.new(0, 0, 4) end
	log(T("Llevado junto a ", "Taken to ") .. p.Name)
end, L("Te teletransporta detrás del jugador.", "Teleports you behind the player."))
local function spectateSubject()
	local p = findPlayer()
	return p and p.Character and p.Character:FindFirstChildOfClass("Humanoid")
end
local function myHumanoid()
	return player.Character and player.Character:FindFirstChildOfClass("Humanoid")
end
local followToggle = toggle(pagePlayer, L("Seguir", "Follow"), function(on)
	following = on
	if not on then releaseMove("Follow") end
end, L("Te mantiene pegado detrás del jugador elegido. Mientras sigue, las demás funciones no te mueven.",
	"Keeps you right behind the chosen player. While following, other features don't move you."), true)
followToggle.transient = true
local spectateToggle = toggle(pagePlayer, L("Espectar", "Spectate"), function(on)
	spectating = on
	local h = on and spectateSubject()
	workspace.CurrentCamera.CameraSubject = h or myHumanoid()
	if on and not h then log(T("No veo a ese jugador para espectarle", "Can't see that player to spectate"), "warn") end
end, L("La cámara sigue al jugador elegido. Apágalo para volver a ti.", "The camera follows the chosen player. Turn it off to come back to you."), true)
spectateToggle.transient = true

task.spawn(function()
	while alive do
		task.wait(0.2)
		if following then
			local _, root = targetRoot()
			local hrp = getHRP()
			if root and hrp and claimMove("Follow") then
				hrp.CFrame = root.CFrame * CFrame.new(0, 0, 4)
				hrp.AssemblyLinearVelocity = Vector3.zero
			elseif not root then
				releaseMove("Follow") -- sin nadie a quien seguir, las demás funciones pueden volver a moverte
			end
		end
		if spectating then -- el jugador reapareció (Humanoid nuevo): la cámara se iba con el cuerpo viejo
			local cam, h = workspace.CurrentCamera, spectateSubject()
			if h and cam.CameraSubject ~= h then cam.CameraSubject = h end
		end
	end
end)
end

------------------------------------------------------------------ Treasure Rain
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
-- Evento: caen 15 cofres en una isla en poco tiempo (wiki). Normalmente hay ~70 cofres repartidos, así que no vale
-- contar cuántos hay: se mira cuántos aparecen de golpe. shortcut: 8 nuevos en 20 s = lluvia; ajustar si salta sin evento.
local rainOn = false
local recent = {}
local rainUntil = 0 -- hasta cuándo pide Auto Chest (os.clock)
local inst = workspace:FindFirstChild("Instances")
local chests = inst and inst:FindFirstChild("Chests")

section(pageAuto, L("Compass y cofres", "Compass & chests"))
toggle(pageAuto, "Auto Treasure Rain", function(on)
	rainOn = on
	if not on and rainUntil > 0 then
		rainUntil = 0
		want("Auto Chest", "Rain", false)
	end
end, L("Cuando caen muchos cofres de golpe (evento Treasure Rain), enciende Auto Chest unos minutos. Si Auto Chest ya estaba encendido, no lo apaga.",
	"When lots of chests drop at once (Treasure Rain event), turns on Auto Chest for a few minutes. If Auto Chest was already on, it leaves it on."))
if chests then
	table.insert(cleanup, chests.ChildAdded:Connect(function()
		if not rainOn then return end
		local now = os.clock()
		table.insert(recent, now)
		while recent[1] and now - recent[1] > 20 do table.remove(recent, 1) end
		if #recent >= 8 and rainUntil == 0 then
			table.clear(recent)
			rainUntil = now + 180 -- 3 min: la lluvia dura poco
			log(T("¡Treasure Rain! Enciendo Auto Chest", "Treasure Rain! Turning on Auto Chest"), "ok", true)
			sendWebhook(T("Treasure Rain en el servidor", "Treasure Rain in the server"))
			want("Auto Chest", "Rain", true)
		end
	end))
end
-- Fin de la lluvia en el bucle (no task.delay): así apagar Treasure Rain o cerrar el hub lo cancela sin más
task.spawn(function()
	while alive do
		task.wait(5)
		if rainUntil > 0 and os.clock() > rainUntil then
			rainUntil = 0
			want("Auto Chest", "Rain", false)
			log(T("Treasure Rain: terminado", "Treasure Rain: over"))
		end
	end
end)
end

------------------------------------------------------------------ Auto Expert
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
-- Las misiones de The Expert salen en PlayerGui.MissionGui ("[Hard] Catch 7 fish.", barra "4 / 7"). Se leen sus
-- textos y se pide (want) la función que toca: pescar -> Auto Pesca, cofres -> Auto Chest, paquetes -> Auto Merlin.
-- shortcut: solo visto "Catch N fish"; los demás tipos se deducen por palabras y se apuntan en la consola.
-- shortcut: la barra "a / b" se busca junto a la misión (mismo padre); sin confirmar la estructura de MissionGui,
-- si no se encuentra la misión cuenta como pendiente hasta que desaparece (como en v1.3.0).
local expertOn = false
local active = {} -- interruptores que Auto Expert ha pedido
local lastSeen = ""
local RULES = {
	{ words = { "fish", "catch" }, toggle = "Auto Pesca (beta)" },
	{ words = { "chest" }, toggle = "Auto Chest" },
	{ words = { "package", "deliver", "merlin" }, toggle = "Auto Merlin (beta)" },
	{ words = { "compass", "treasure" }, toggle = "Auto Sam (compass)" },
}

-- Progreso "a / b" en la misma tarjeta que el texto de la misión; nil si no se ve
local function progressOf(label)
	local card = label.Parent
	for _, d in card and card:GetDescendants() or {} do
		if d ~= label and d:IsA("TextLabel") then
			local a, b = d.Text:match("^%s*(%d+)%s*/%s*(%d+)%s*$")
			if a then return tonumber(a), tonumber(b) end
		end
	end
	return nil
end

local function missions()
	local gui = player.PlayerGui:FindFirstChild("MissionGui")
	local out = {}
	for _, d in gui and gui:GetDescendants() or {} do
		if d:IsA("TextLabel") and d.Visible and d.Text:match("^%s*%[") then
			local a, b = progressOf(d)
			table.insert(out, { text = d.Text, done = a ~= nil and b ~= nil and b > 0 and a >= b, progress = a and (a .. "/" .. b) })
		end
	end
	return out
end

local function releaseAll()
	for name in active do want(name, "Expert", false) end
	table.clear(active)
end

section(pageQuest, "The Expert", 1)
toggle(pageQuest, "Auto Expert (beta)", function(on)
	expertOn = on
	if not on then releaseAll() end
end, L("Lee las misiones de The Expert y enciende lo que haga falta (pescar, cofres, paquetes, compass). Al acabar las apaga, salvo las que encendiste tú.",
	"Reads The Expert's missions and turns on what's needed (fishing, chests, packages, compass). When done it turns them off, except the ones you turned on."))

task.spawn(function()
	while alive do
		task.wait(3)
		if expertOn then
			local list = missions()
			local parts = {}
			for _, m in list do table.insert(parts, m.text .. (m.progress and " (" .. m.progress .. ")" or "")) end
			local text = table.concat(parts, " | ")
			if text ~= lastSeen then
				lastSeen = text
				log("Expert: " .. (text ~= "" and text or T("sin misiones", "no missions")))
			end
			local needed = {}
			for _, m in list do
				if not m.done then
					local lower = m.text:lower()
					for _, rule in RULES do
						for _, w in rule.words do
							if lower:find(w, 1, true) then needed[rule.toggle] = true end
						end
					end
				end
			end
			for name in needed do
				if not active[name] then
					active[name] = true
					want(name, "Expert", true)
				end
			end
			for name in active do
				if not needed[name] then
					active[name] = nil
					want(name, "Expert", false)
				end
			end
		end
	end
end)
end

------------------------------------------------------------------ Vender peces
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
-- FishingService.RF.SellFish (EscaneoServicios) junto al Fish Merchant (FishMerchant). shortcut: sin grabar; se
-- llama sin argumentos y se apunta lo que responde. Cocinar (x5) aún sin datos.
local sellFish = getRemote("FishingService", "RF", "SellFish")
local autoSellFish = false

local function sellAllFish()
	local npc = merchant("FishMerchant")
	local hrp = getHRP()
	if not (npc and hrp) then return log(T("Peces: no encuentro al Fish Merchant", "Fish: can't find the Fish Merchant"), "warn") end
	if not claimMove("SellFish") then return end
	local back = hrp.CFrame
	if teleport(npc:GetPivot().Position + Vector3.new(0, 3, 4)) then
		task.wait(0.4)
		local ok, result = call(sellFish, "InvokeServer")
		log(T("Peces: vender -> ", "Fish: sell -> ") .. tostring(result), (ok and result) and "ok" or "warn", ok and result)
	end
	returnTo(back)
	releaseMove("SellFish")
end

section(pageAuto, L("Farmeo", "Farming"))
button(pageAuto, L("Vender peces", "Sell fish"), sellAllFish, L("Va al Fish Merchant, vende los peces y vuelve.", "Goes to the Fish Merchant, sells your fish and comes back."))
toggle(pageAuto, L("Auto vender peces (beta)", "Auto sell fish (beta)"), function(on) autoSellFish = on end,
	L("Vende los peces cada 5 minutos.", "Sells your fish every 5 minutes."))
task.spawn(function()
	while alive do
		task.wait(300)
		if autoSellFish then pcall(sellAllFish) end
	end
end)
end

------------------------------------------------------------------ Webhook de Discord
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
local announced = setmetatable({}, { __mode = "k" }) -- frutas ya avisadas (claves débiles: no retiene las borradas)
section(pageMisc, "Discord webhook")
-- La URL es un secreto (quien la tenga puede escribir en tu canal): no se muestra entera ni se escribe en la consola.
local function masked()
	return validWebhook(config.webhook) and T("guardado (…", "saved (…") .. config.webhook:sub(-4) .. ")" or ""
end
input(pageMisc, "Webhook", "https://discord.com/api/webhooks/...", "", function(text)
	text = text:match("^%s*(.-)%s*$")
	if text == "" then return end -- vaciar la caja no borra el guardado: para eso está "Borrar webhook"
	if not validWebhook(text) then
		return log(T("Eso no es una URL de webhook de Discord (https://discord.com/api/webhooks/...)",
			"That isn't a Discord webhook URL (https://discord.com/api/webhooks/...)"), "warn", true)
	end
	config.webhook = text
	saveConfig()
	log(T("Webhook guardado ", "Webhook saved ") .. masked() .. T(". Usa \"Enviar prueba\" para comprobarlo.", ". Use \"Send test\" to check it."), "ok", true)
end, L("Pega la URL de un webhook de tu servidor de Discord para recibir avisos. Se guarda en ElHoyoHub.json, no en los perfiles.",
	"Paste a webhook URL from your Discord server to get alerts. It's stored in ElHoyoHub.json, not in presets."))
button(pageMisc, L("Enviar prueba", "Send test"), function()
	sendWebhook(T("Mensaje de prueba", "Test message"), function(ok, why)
		if ok then
			log(T("Webhook: prueba enviada ", "Webhook: test sent ") .. masked(), "ok", true)
		else
			log("Webhook: " .. tostring(why), "warn", true)
		end
	end)
end, L("Manda un mensaje de prueba al webhook guardado.", "Sends a test message to the saved webhook."))
button(pageMisc, L("Borrar webhook", "Delete webhook"), function()
	config.webhook = nil
	saveConfig()
	log(T("Webhook borrado", "Webhook deleted"), "ok", true)
end, L("Olvida la URL guardada.", "Forgets the saved URL."))
if config.webhook ~= nil and not validWebhook(config.webhook) then
	table.insert(bootNotes, { "Webhook guardado no válido: no se usará hasta que pongas uno de Discord", "Saved webhook is invalid: it won't be used until you set a Discord one" })
end
toggle(pageMisc, L("Avisar: frutas raras en el suelo", "Alert: rare fruits on the ground"), function(on) wh.fruits = on end,
	L("Manda un aviso cuando hay una Devil Fruit Rara o mejor tirada.", "Sends an alert when a Rare or better Devil Fruit is lying around."))
toggle(pageMisc, L("Avisar: jefes", "Alert: bosses"), function(on) wh.bosses = on end,
	L("Manda un aviso cuando aparece un jefe de la lista de Auto Boss.", "Sends an alert when a boss from the Auto Boss list appears."))
toggle(pageMisc, L("Avisar: admins", "Alert: admins"), function(on) wh.admins = on end,
	L("Manda un aviso cuando Detectar admins encuentra uno.", "Sends an alert when Detect admins finds one."))
task.spawn(function()
	while alive do
		task.wait(5)
		if wh.fruits then
			for _, f in groundFruits() do
				if f.rank >= 3 and not announced[f.tool] then
					announced[f.tool] = true
					sendWebhook(T("Fruta en el suelo: ", "Fruit on the ground: ") .. f.name)
				end
			end
		end
	end
end)
end

------------------------------------------------------------------ Modo AFK total
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
-- Enciende de una vez lo mejor para farmear sin estar (la zona segura primero, para que el resto vuelva a ella)
local AFK_SET = { "Zona segura", "Anti-AFK", "Auto Respawn", "Huida automática", "Auto Sam (compass)", "Auto Chest",
	"Auto Treasure Rain", "Auto Stats (beta)", "Auto Rewards", "Auto Claim Challenges (beta)", "Collect Devil Fruits" }
section(pageHome, L("Modo AFK", "AFK mode"), 1)
button(pageHome, L("Encender modo AFK total", "Turn on full AFK mode"), function()
	local n = 0
	for _, name in AFK_SET do
		local t = toggles[name]
		if t and not t.value then
			t.set(true)
			task.spawn(t.onChange, true)
			n += 1
			task.wait(0.2)
		end
	end
	log(T("Modo AFK: encendidas ", "AFK mode: turned on ") .. n .. T(" funciones", " features"), "ok", true)
end, L("Enciende zona segura, Anti-AFK, respawn, huida, Sam, cofres, Treasure Rain, Auto Stats, recompensas, challenges y frutas.",
	"Turns on safe zone, Anti-AFK, respawn, escape, Sam, chests, Treasure Rain, Auto Stats, rewards, challenges and fruits."))
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
	return type(config.hubUrl) == "string" and config.hubUrl:match("^https://") ~= nil -- solo https: el cargador ejecuta lo que descarga
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
note(pageSettings, L("Versión " .. HUB_VERSION, "Version " .. HUB_VERSION))
button(pageSettings, L("Apagar todo", "Turn everything off"), function()
	local n = turnAllOff(false)
	log(T("Apagadas ", "Turned off ") .. n .. T(" funciones", " features"), "ok", true)
end, L("Apaga todas las funciones encendidas sin cerrar el hub.", "Turns off every active feature without closing the hub."))
button(pageSettings, L("Cerrar El Hoyo Hub", "Close El Hoyo Hub"), function() closeHub() end,
	L("Apaga todas las funciones, deja el personaje como estaba y cierra el hub.", "Turns off every feature, restores your character and closes the hub."))
end

------------------------------------------------------------------ Ocultar, cursor
-- Mostrar / ocultar con la tecla elegida (la librería no la gestiona: ToggleKey = false)
table.insert(cleanup, UIS.InputBegan:Connect(function(input)
	if waitingKey or UIS:GetFocusedTextBox() then return end
	if input.KeyCode.Name == config.key then main.Visible = not main.Visible end
end))

-- Cursor: el juego a veces lo esconde. Encima del hub o la consola se fuerza a que se vea.
table.insert(cleanup, game:GetService("RunService").RenderStepped:Connect(function()
	if overOurGui() then UIS.MouseIconEnabled = true end
end))

------------------------------------------------------------------ Migraciones
-- v1.3.1 (configVersion 2): las cajas de texto ya no van en los perfiles. Los perfiles viejos aún guardan lo que
-- se escribió en ellas (la URL del webhook incluida) y la librería lo volvería a guardar: se quita del disco.
-- Solo se borran valores de texto de esas cajas; interruptores y demás quedan igual.
if (tonumber(config.configVersion) or 1) < CONFIG_VERSION then
	local INPUT_KEYS = { "/Webhook", "/URL", "/Player", "/Skill keys" } -- final de la ruta de cada caja de texto
	local cleaned = 0
	if listfiles and readfile and writefile then
		for _, dir in { "ElHoyoHub/configs", "ElHoyoHub/trash" } do
			local okList, files = pcall(listfiles, dir)
			for _, path in okList and files or {} do
				local okRead, data = pcall(function() return HttpService:JSONDecode(readfile(path)) end)
				if okRead and type(data) == "table" and type(data.values) == "table" then
					local changed = false
					for id, value in data.values do
						local isInput = false
						for _, suffix in INPUT_KEYS do
							if type(id) == "string" and type(value) == "string" and id:sub(-#suffix) == suffix then isInput = true end
						end
						if isInput or (type(value) == "string" and value:find("/api/webhooks/", 1, true)) then
							data.values[id] = nil
							changed = true
						end
					end
					if changed then
						cleaned += 1
						pcall(writefile, path, HttpService:JSONEncode(data))
					end
				end
			end
		end
	end
	if cleaned > 0 then table.insert(bootNotes, { "Perfiles limpiados (sin URLs ni textos guardados): " .. cleaned, "Presets cleaned (no URLs or saved text): " .. cleaned }) end
	config.configVersion = CONFIG_VERSION
	saveConfig()
end

------------------------------------------------------------------ Inicio
if not alive then return closeHub() end -- otra ejecución cerró este hub mientras cargaba: no dejar nada a medias
fitBoxes()
win:Finish() -- coloca todo y carga el último perfil usado (eso enciende sus funciones)
log(T("El Hoyo Hub cargado (v", "El Hoyo Hub loaded (v") .. HUB_VERSION .. ")", "ok", true)
for _, msg in bootNotes do log(T(msg[1], msg[2]), "warn") end
for _, missing in missingRemotes do
	log(T("No encuentro la señal ", "Can't find the signal ") .. missing .. T(" (¿actualización del juego?)", " (game update?)"), "error")
end
end

local ok, err = xpcall(ElHoyoHubMain, debug.traceback)
if not ok then
	warn("[El Hoyo Hub] " .. tostring(err))
	-- lo que llegó a cargarse (bucles, ventana) se cierra: si no, quedaba funcionando a medias y sin botón de cerrar
	pcall(function() local g = getgenv and getgenv(); if g and g.ElHoyoHubClose then g.ElHoyoHubClose() end end)
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
