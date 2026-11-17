-- El Hoyo Hub
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

------------------------------------------------------------------ Estilo
-- Paletas. Dentro de cada una todos los colores son distintos: así se sabe qué color de la paleta
-- usa cada elemento y se puede cambiar de paleta en caliente.
local PALETTE_ORDER = { "Abismo", "Pirata", "Haki", "Océano" }
local PALETTES = {
	Abismo = { -- fondos casi negros en capas, acento morado
		bg = "0E0E15", surface = "15151E", card = "1B1B26", cardHover = "232332", line = "2A2A3A",
		accent = "8B5CF6", accentSoft = "261F3D", on = "22C55E", off = "3A3A4C",
		text = "ECECF4", dim = "8E8EA6", warn = "F59E0B", err = "EF4444",
	},
	Pirata = { -- azul marino, acento dorado
		bg = "0B1622", surface = "102033", card = "15283F", cardHover = "1C324D", line = "24405F",
		accent = "F2B33D", accentSoft = "3A3020", on = "2EC27E", off = "34465C",
		text = "F1E9D8", dim = "9AA7B8", warn = "F59E0C", err = "EF4445",
	},
	Haki = { -- negro, acento rojo
		bg = "0D0D0D", surface = "151515", card = "1C1C1C", cardHover = "252525", line = "2E2E2E",
		accent = "E11D48", accentSoft = "3A1520", on = "22C55F", off = "3A3A3A",
		text = "F5F5F5", dim = "9A9A9A", warn = "F59E0D", err = "EF4446",
	},
	["Océano"] = { -- gris azulado, acento turquesa
		bg = "0F1417", surface = "151C21", card = "1B2329", cardHover = "222C33", line = "2C3840",
		accent = "14B8A6", accentSoft = "133533", on = "22C560", off = "33404A",
		text = "E6EEF2", dim = "8FA3AE", warn = "F59E0E", err = "EF4447",
	},
}
local C = {}
local function loadPalette(name)
	for k, hex in PALETTES[name] or PALETTES.Abismo do C[k] = Color3.fromHex(hex) end
end
loadPalette(config.palette)
local FONT, FONT_SEMI, FONT_BOLD = Enum.Font.Gotham, Enum.Font.GothamMedium, Enum.Font.GothamBold
local FAST, NORMAL = 0.12, 0.22 -- duraciones: interacción / transición

------------------------------------------------------------------ Idioma y colores enlazados
-- Textos fijos de la interfaz: L("español", "english"). Se actualizan solos al cambiar de idioma.
-- Mensajes que se crean en el momento (consola, avisos): T("español", "english").
-- Los colores de la paleta pasados a new() se recuerdan igual, para cambiar de paleta en caliente.
local LANG = config.lang
local function L(es, en)
	return { es = es, en = en }
end
local function T(es, en)
	return LANG == "en" and en or es
end
local function tr(v)
	if type(v) == "table" then return LANG == "en" and v.en or v.es end
	return v
end
local function colorKey(c)
	for k, v in C do
		if v == c then return k end
	end
end
local bindings = setmetatable({}, { __mode = "k" }) -- objeto -> { propiedad -> L(...) o nombre de color }
local function bind(obj, prop, v)
	local key = typeof(v) == "Color3" and colorKey(v)
	obj[prop] = tr(v)
	if type(v) == "table" or key then
		bindings[obj] = bindings[obj] or {}
		bindings[obj][prop] = key or v
	elseif bindings[obj] then
		bindings[obj][prop] = nil -- ahora tiene un valor fijo
	end
end
local refreshHooks = {} -- cosas que se recolorean a mano (interruptores, pestaña elegida...)
local function refreshAll()
	for obj, props in bindings do
		for prop, v in props do
			obj[prop] = type(v) == "string" and C[v] or tr(v)
		end
	end
	for _, f in refreshHooks do f() end
end
local function setLang(lang)
	LANG = lang
	genv.ElHoyoHubLang = lang
	config.lang = lang
	saveConfig()
	refreshAll()
end
local function setPalette(name)
	loadPalette(name)
	config.palette = name
	saveConfig()
	refreshAll()
end

local function tween(obj, props, t, style)
	local tw = TweenService:Create(obj, TweenInfo.new(t or NORMAL, style or Enum.EasingStyle.Quint, Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

local function new(class, props)
	local obj = Instance.new(class)
	for k, v in props do
		if k ~= "Parent" then bind(obj, k, v) end -- un L(...) se traduce y se vuelve a traducir al cambiar idioma
	end
	obj.Parent = props.Parent
	return obj
end

local function round(obj, r)
	new("UICorner", { CornerRadius = UDim.new(0, r or 8), Parent = obj })
end

local function outline(obj, color, transparency)
	return new("UIStroke", {
		Color = color or C.line,
		Transparency = transparency or 0,
		Thickness = 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = obj,
	})
end

local function pad(obj, x, y)
	new("UIPadding", {
		PaddingLeft = UDim.new(0, x),
		PaddingRight = UDim.new(0, x),
		PaddingTop = UDim.new(0, y or x),
		PaddingBottom = UDim.new(0, y or x),
		Parent = obj,
	})
end

local function isOver(f)
	if not f.Visible then return false end
	local p, s = f.AbsolutePosition, f.AbsoluteSize
	return mouse.X >= p.X and mouse.X <= p.X + s.X and mouse.Y >= p.Y and mouse.Y <= p.Y + s.Y
end

-- Arrastrar con suavidad desde "handle" moviendo "target"
local function draggable(handle, target)
	local dragging, startPos, startMouse
	handle.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging, startPos, startMouse = true, target.Position, i.Position
		end
	end)
	table.insert(cleanup, UIS.InputChanged:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = i.Position - startMouse
			tween(target, { Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y) }, 0.08)
		end
	end))
	table.insert(cleanup, UIS.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
	end))
end

-- Resalte de hover y de foco (mando/teclado) para cualquier control
-- base/hover son nombres de colores de la paleta (se leen al momento: siguen a la paleta elegida)
local function hoverFx(obj, stroke, base, hover)
	local function on()
		tween(obj, { BackgroundColor3 = C[hover] }, FAST)
		if stroke then tween(stroke, { Color = C.accent, Transparency = 0.4 }, FAST) end
	end
	local function off()
		tween(obj, { BackgroundColor3 = C[base] }, FAST)
		if stroke then tween(stroke, { Color = C.line, Transparency = 0 }, FAST) end
	end
	obj.MouseEnter:Connect(on)
	obj.MouseLeave:Connect(off)
	obj.SelectionGained:Connect(on)
	obj.SelectionLost:Connect(off)
end

local gui = new("ScreenGui", {
	Name = "ElHoyoHub",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = (gethui and gethui()) or game:GetService("CoreGui"),
})

------------------------------------------------------------------ Tooltips
local tip = new("TextLabel", {
	Visible = false,
	ZIndex = 60,
	Size = UDim2.fromOffset(220, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = C.surface,
	BackgroundTransparency = 1,
	TextTransparency = 1,
	TextColor3 = C.text,
	Font = FONT,
	TextSize = 12,
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = gui,
})
round(tip, 6)
pad(tip, 8, 6)
local tipStroke = outline(tip, C.line, 1)
local tipToken = 0

local function hideTip()
	tipToken += 1
	local my = tipToken
	tween(tip, { TextTransparency = 1, BackgroundTransparency = 1 }, FAST)
	tween(tipStroke, { Transparency = 1 }, FAST)
	task.delay(FAST, function()
		if my == tipToken then tip.Visible = false end
	end)
end

-- Muestra "text" tras una pequeña espera con el ratón encima
local function tooltip(obj, text)
	if not text or text == "" then return end
	obj.MouseEnter:Connect(function()
		tipToken += 1
		local my = tipToken
		task.delay(0.45, function()
			if my ~= tipToken or not alive then return end
			local v = workspace.CurrentCamera.ViewportSize
			tip.Text = tr(text)
			tip.Position = UDim2.fromOffset(math.min(mouse.X + 14, v.X - 232), math.min(mouse.Y + 18, v.Y - 60))
			tip.Visible = true
			tween(tip, { TextTransparency = 0, BackgroundTransparency = 0 }, FAST)
			tween(tipStroke, { Transparency = 0 }, FAST)
		end)
	end)
	obj.MouseLeave:Connect(hideTip)
end

------------------------------------------------------------------ Notificaciones
local toastHolder = new("Frame", {
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(1, -16, 1, -16),
	Size = UDim2.fromOffset(280, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	ZIndex = 40,
	Parent = gui,
})
new("UIListLayout", {
	Padding = UDim.new(0, 8),
	SortOrder = Enum.SortOrder.LayoutOrder,
	VerticalAlignment = Enum.VerticalAlignment.Bottom,
	Parent = toastHolder,
})
local LEVEL_KEY = { info = "text", ok = "on", warn = "warn", error = "err" }
local function levelColor(level)
	return C[LEVEL_KEY[level] or "text"] -- se lee en el momento: sigue a la paleta actual
end
local toasts, toastCount = {}, 0

local function toast(msg, level)
	toastCount += 1
	local t = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = C.surface,
		BackgroundTransparency = 1,
		LayoutOrder = toastCount,
		ZIndex = 40,
		Parent = toastHolder,
	})
	round(t, 8)
	local stroke = outline(t, C.line, 1)
	local s = new("UIScale", { Scale = 0.94, Parent = t })
	local bar = new("Frame", {
		Size = UDim2.new(0, 3, 1, -16),
		Position = UDim2.fromOffset(8, 8),
		BackgroundColor3 = levelColor(level),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 41,
		Parent = t,
	})
	round(bar, 2)
	local label = new("TextLabel", {
		Text = msg,
		Font = FONT,
		TextSize = 13,
		TextColor3 = C.text,
		TextTransparency = 1,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		ZIndex = 41,
		Parent = t,
	})
	new("UIPadding", { PaddingLeft = UDim.new(0, 20), PaddingRight = UDim.new(0, 12), PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10), Parent = label })
	tween(t, { BackgroundTransparency = 0 }, NORMAL)
	tween(stroke, { Transparency = 0 }, NORMAL)
	tween(bar, { BackgroundTransparency = 0 }, NORMAL)
	tween(label, { TextTransparency = 0 }, NORMAL)
	tween(s, { Scale = 1 }, NORMAL)
	table.insert(toasts, t)
	if #toasts > 4 then table.remove(toasts, 1):Destroy() end -- como mucho 4 a la vez

	task.delay(3.5, function()
		if not t.Parent then return end
		tween(t, { BackgroundTransparency = 1 }, NORMAL)
		tween(stroke, { Transparency = 1 }, NORMAL)
		tween(bar, { BackgroundTransparency = 1 }, NORMAL)
		tween(label, { TextTransparency = 1 }, NORMAL)
		tween(s, { Scale = 0.94 }, NORMAL)
		task.wait(NORMAL)
		local i = table.find(toasts, t)
		if i then table.remove(toasts, i) end
		t:Destroy()
	end)
end

------------------------------------------------------------------ Consola
local consoleWin = new("Frame", {
	Size = UDim2.fromOffset(380, 240),
	Position = UDim2.new(1, -396, 1, -360),
	BackgroundColor3 = C.bg,
	Visible = false,
	ClipsDescendants = true,
	Parent = gui,
})
round(consoleWin, 12)
outline(consoleWin)
local consoleScale = new("UIScale", { Parent = consoleWin })

local consoleHeader = new("Frame", { Size = UDim2.new(1, 0, 0, 40), BackgroundTransparency = 1, Parent = consoleWin })
new("TextLabel", {
	Text = L("Consola", "Console"),
	Font = FONT_BOLD,
	TextSize = 14,
	TextColor3 = C.text,
	TextXAlignment = Enum.TextXAlignment.Left,
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(16, 0),
	Size = UDim2.new(1, -120, 1, 0),
	Parent = consoleHeader,
})
draggable(consoleHeader, consoleWin)
new("Frame", { Size = UDim2.new(1, 0, 0, 1), Position = UDim2.fromOffset(0, 40), BackgroundColor3 = C.line, BorderSizePixel = 0, Parent = consoleWin })

local consoleList = new("ScrollingFrame", {
	Position = UDim2.fromOffset(0, 41),
	Size = UDim2.new(1, 0, 1, -41),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 3,
	ScrollBarImageColor3 = C.accent,
	Parent = consoleWin,
})
new("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder, Parent = consoleList })
pad(consoleList, 12, 8)

local MAX_LINES = 150
local lines, lineCount = {}, 0

-- notify = true también lo muestra como notificación. Errores y avisos siempre se notifican.
local function log(msg, level, notify)
	print("[El Hoyo Hub] " .. msg)
	if not alive then return end
	level = level or "info"
	lineCount += 1
	local line = new("TextLabel", {
		Text = os.date("%H:%M:%S") .. "  " .. msg,
		TextColor3 = levelColor(level),
		TextTransparency = 1,
		Font = Enum.Font.Code,
		TextSize = 13,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = lineCount,
		Parent = consoleList,
	})
	tween(line, { TextTransparency = 0 }, NORMAL)
	table.insert(lines, line)
	if #lines > MAX_LINES then table.remove(lines, 1):Destroy() end
	task.defer(function()
		consoleList.CanvasPosition = Vector2.new(0, consoleList.AbsoluteCanvasSize.Y)
	end)
	-- Los errores siempre avisan; lo demás solo con las notificaciones activadas
	if level == "error" or (config.notify and (notify or level == "warn")) then toast(msg, level) end
end

local consoleShown = false
local function setConsole(show)
	consoleShown = show
	if show then
		consoleWin.Visible = true
		consoleScale.Scale = 0.96
		tween(consoleScale, { Scale = 1 }, NORMAL)
	else
		tween(consoleScale, { Scale = 0.96 }, FAST)
		task.delay(FAST, function()
			if not consoleShown then consoleWin.Visible = false end
		end)
	end
end

-- Botón de icono sin fondo (cabeceras): se ilumina al pasar por encima y explica lo que hace
local function iconButton(parent, text, hint, hoverColor, onClick) -- hoverColor: nombre de color de la paleta
	local b = new("TextButton", {
		Text = text,
		Font = FONT_BOLD,
		TextSize = 15,
		TextColor3 = C.dim,
		BackgroundColor3 = C.cardHover,
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Size = UDim2.fromOffset(30, 28),
		Parent = parent,
	})
	round(b, 6)
	b.MouseEnter:Connect(function() tween(b, { BackgroundTransparency = 0, TextColor3 = C[hoverColor] }, FAST) end)
	b.MouseLeave:Connect(function() tween(b, { BackgroundTransparency = 1, TextColor3 = C.dim }, FAST) end)
	b.MouseButton1Click:Connect(onClick)
	tooltip(b, hint)
	return b
end

local function iconRow(parent)
	local row = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(0, 28),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		Parent = parent,
	})
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = row,
	})
	return row
end

local consoleIcons = iconRow(consoleHeader)
iconButton(consoleIcons, "⌫", L("Borrar la consola", "Clear the console"), "text", function()
	for _, l in lines do l:Destroy() end
	table.clear(lines)
end)
iconButton(consoleIcons, "×", L("Cerrar la consola", "Close the console"), "err", function() setConsole(false) end)

------------------------------------------------------------------ Ventana principal
local HEADER_H, TABS_H = 56, 34

-- Tamaño según la pantalla: cabe en móviles y no se hace enorme en monitores grandes
local function fitSize()
	local v = workspace.CurrentCamera.ViewportSize
	return math.clamp(v.X - 32, 340, 600), math.clamp(v.Y - 96, 300, 430)
end
local WIDTH, HEIGHT = fitSize()

local main = new("Frame", {
	Size = UDim2.fromOffset(WIDTH, HEIGHT),
	Position = UDim2.new(0.5, -WIDTH / 2, 0.5, -HEIGHT / 2),
	BackgroundColor3 = C.bg,
	ClipsDescendants = true,
	Parent = gui,
})
round(main, 12)
outline(main)
local userScale = math.clamp(tonumber(config.scale) or 1, 0.5, 2)
local mainScale = new("UIScale", { Scale = userScale * 0.96, Parent = main })

local header = new("Frame", { Size = UDim2.new(1, 0, 0, HEADER_H), BackgroundTransparency = 1, Parent = main })
local logo = new("Frame", {
	Size = UDim2.fromOffset(28, 28),
	Position = UDim2.new(0, 16, 0.5, -14),
	BackgroundColor3 = C.accentSoft,
	Parent = header,
})
round(logo, 8)
local dot = new("Frame", { Size = UDim2.fromOffset(10, 10), Position = UDim2.fromOffset(9, 9), BackgroundColor3 = C.accent, Parent = logo })
round(dot, 5)
new("TextLabel", {
	Text = "El Hoyo Hub",
	Font = FONT_BOLD,
	TextSize = 16,
	TextColor3 = C.text,
	TextXAlignment = Enum.TextXAlignment.Left,
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(54, 10),
	Size = UDim2.new(1, -170, 0, 20),
	Parent = header,
})
local function keyHint()
	return L(config.key .. " para mostrar u ocultar", config.key .. " to show or hide")
end
local subtitle = new("TextLabel", {
	Text = keyHint(),
	Font = FONT,
	TextSize = 12,
	TextColor3 = C.dim,
	TextXAlignment = Enum.TextXAlignment.Left,
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(54, 30),
	Size = UDim2.new(1, -170, 0, 16),
	Parent = header,
})
draggable(header, main)

local closeHub -- se define al final; los botones de cerrar la llaman
local minimized = false
local headerIcons = iconRow(header)
iconButton(headerIcons, "≡", L("Mostrar u ocultar la consola", "Show or hide the console"), "accent", function() setConsole(not consoleShown) end)
iconButton(headerIcons, "–", L("Minimizar", "Minimize"), "text", function()
	minimized = not minimized
	tween(main, { Size = UDim2.fromOffset(WIDTH, minimized and HEADER_H or HEIGHT) }, NORMAL)
end)
iconButton(headerIcons, "×", L("Cerrar El Hoyo Hub (apaga todo)", "Close El Hoyo Hub (turns everything off)"), "err", function() closeHub() end)

-- Barra de secciones: pestañas en fila con un fondo que se desliza a la elegida
local tabBar = new("Frame", {
	Position = UDim2.fromOffset(16, HEADER_H),
	Size = UDim2.new(1, -32, 0, TABS_H),
	BackgroundColor3 = C.surface,
	Parent = main,
})
round(tabBar, 8)
local tabIndicator = new("Frame", {
	Size = UDim2.new(0.2, -4, 1, -4),
	Position = UDim2.new(0, 2, 0, 2),
	BackgroundColor3 = C.accentSoft,
	BorderSizePixel = 0,
	Parent = tabBar,
})
round(tabIndicator, 6)
local tabRow = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 2, Parent = tabBar })
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, SortOrder = Enum.SortOrder.LayoutOrder, Parent = tabRow })

local content = new("Frame", {
	Position = UDim2.fromOffset(0, HEADER_H + TABS_H + 8),
	Size = UDim2.new(1, 0, 1, -(HEADER_H + TABS_H + 8)),
	BackgroundTransparency = 1,
	ClipsDescendants = true,
	Parent = main,
})

-- Pulso suave del punto del logo
task.spawn(function()
	while alive do
		tween(dot, { BackgroundTransparency = 0.5 }, 1.4, Enum.EasingStyle.Sine).Completed:Wait()
		tween(dot, { BackgroundTransparency = 0 }, 1.4, Enum.EasingStyle.Sine).Completed:Wait()
	end
end)

------------------------------------------------------------------ Secciones y controles
local tabs, currentTab = {}, nil
local order = 0
local function nextOrder()
	order += 1
	return order
end

local function selectTab(tab)
	if currentTab == tab then return end
	local index = table.find(tabs, tab)
	tween(tabIndicator, { Position = UDim2.new((index - 1) / #tabs, 2, 0, 2) }, NORMAL)
	for _, t in tabs do
		local sel = t == tab
		tween(t.btn, { TextColor3 = sel and C.text or C.dim }, FAST)
		if not sel then t.page.Visible = false end
	end
	tab.page.Visible = true
	tab.page.CanvasPosition = Vector2.zero
	tab.page.Position = UDim2.fromOffset(0, 8)
	tween(tab.page, { Position = UDim2.fromOffset(0, 0) }, NORMAL)
	currentTab = tab
end
-- Al cambiar de paleta, la pestaña elegida vuelve a tener su color de "elegida"
table.insert(refreshHooks, function()
	if currentTab then currentTab.btn.TextColor3 = C.text end
end)

-- Cuadrículas de cada página: 2 columnas, o 1 si la ventana es estrecha.
local GRID_KINDS = {
	card = { height = 46, wide = 2, narrow = 1 },
	action = { height = 40, wide = 2, narrow = 1 },
	tp = { height = 38, wide = 2, narrow = 1 },
	chip = { height = 30, wide = 4, narrow = 3 },
}
local grids, currentGrid = {}, {}

local function layoutGrid(g)
	local kind = GRID_KINDS[g.kind]
	local cols = WIDTH < 460 and kind.narrow or kind.wide
	g.layout.CellSize = UDim2.new(1 / cols, -8 * (cols - 1) / cols, 0, kind.height)
end

local function makeGrid(page, kind)
	local f = new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = nextOrder(),
		Parent = page,
	})
	local g = {
		kind = kind,
		frame = f,
		layout = new("UIGridLayout", { CellPadding = UDim2.fromOffset(8, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = f }),
	}
	layoutGrid(g)
	table.insert(grids, g)
	return g
end

-- Cuadrícula donde va el siguiente control de este tipo (se abre una nueva tras un título o nota)
local function gridFor(page, kind)
	local g = currentGrid[page]
	if not g or g.kind ~= kind then
		g = makeGrid(page, kind)
		currentGrid[page] = g
	end
	return g.frame
end

local pages = {}
local function addTab(name, desc)
	local btn = new("TextButton", {
		Text = name,
		Font = FONT_SEMI,
		TextScaled = true, -- se encoge si la ventana es estrecha, sin pasar de 13
		TextColor3 = C.dim,
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		LayoutOrder = #tabs + 1,
		Parent = tabRow,
	})
	new("UITextSizeConstraint", { MaxTextSize = 13, Parent = btn })
	pad(btn, 4, 9)
	local page = new("ScrollingFrame", {
		Visible = false,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = C.accent,
		Parent = content,
	})
	new("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder, Parent = page })
	new("UIPadding", {
		PaddingTop = UDim.new(0, 6),
		PaddingBottom = UDim.new(0, 16),
		PaddingLeft = UDim.new(0, 16),
		PaddingRight = UDim.new(0, 16),
		Parent = page,
	})
	-- Descripción de la sección, siempre arriba de la página
	new("TextLabel", {
		Text = desc,
		Font = FONT,
		TextSize = 13,
		TextColor3 = C.dim,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = nextOrder(),
		Parent = page,
	})

	local tab = { btn = btn, page = page }
	table.insert(tabs, tab)
	pages[page] = true
	for _, t in tabs do t.btn.Size = UDim2.new(1 / #tabs, 0, 1, 0) end
	tabIndicator.Size = UDim2.new(1 / #tabs, -4, 1, -4)
	btn.MouseButton1Click:Connect(function() selectTab(tab) end)
	btn.MouseEnter:Connect(function()
		if currentTab ~= tab then tween(btn, { TextColor3 = C.text }, FAST) end
	end)
	btn.MouseLeave:Connect(function()
		if currentTab ~= tab then tween(btn, { TextColor3 = C.dim }, FAST) end
	end)
	tooltip(btn, desc)
	return page
end

local function section(page, text)
	currentGrid[page] = nil
	new("TextLabel", {
		Text = text,
		Font = FONT_BOLD,
		TextSize = 13,
		TextColor3 = C.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 22),
		LayoutOrder = nextOrder(),
		Parent = page,
	})
end

-- Aviso informativo de ancho completo
local function note(page, text)
	currentGrid[page] = nil
	local box = new("Frame", {
		BackgroundColor3 = C.accentSoft,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = nextOrder(),
		Parent = page,
	})
	round(box, 8)
	local label = new("TextLabel", {
		Text = text,
		Font = FONT,
		TextSize = 12,
		TextColor3 = C.text,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = box,
	})
	pad(label, 12, 10)
	return label
end

-- Campo de texto de ancho completo (p. ej. nombre de un perfil). El borde se ilumina mientras escribes.
local function input(page, placeholder)
	currentGrid[page] = nil
	local box = new("TextBox", {
		Text = "",
		PlaceholderText = placeholder,
		ClearTextOnFocus = false,
		Font = FONT,
		TextSize = 13,
		TextColor3 = C.text,
		PlaceholderColor3 = C.dim,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundColor3 = C.card,
		Size = UDim2.new(1, 0, 0, 38),
		LayoutOrder = nextOrder(),
		Parent = page,
	})
	round(box, 8)
	pad(box, 12, 0)
	local stroke = outline(box)
	box.Focused:Connect(function() tween(stroke, { Color = C.accent }, FAST) end)
	box.FocusLost:Connect(function() tween(stroke, { Color = C.line }, FAST) end)
	return box
end

-- Todos los interruptores por nombre (en español): para los perfiles y "Apagar todo"
local toggles = {}

-- Tarjeta con título e interruptor (la explicación va en el tooltip). onChange(estado) se llama al
-- pulsarla; .set(v) la cambia sin llamar a onChange. noSave = es un ajuste, no una función (no entra en
-- los perfiles ni en "Apagar todo").
local function toggle(page, text, onChange, desc, noSave)
	local card = new("TextButton", {
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.card,
		LayoutOrder = nextOrder(),
		Parent = gridFor(page, "card"),
	})
	round(card, 10)
	hoverFx(card, outline(card), "card", "cardHover")
	new("TextLabel", {
		Text = text,
		Font = FONT_SEMI,
		TextSize = 14,
		TextColor3 = C.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(1, -76, 1, 0),
		Parent = card,
	})
	local switch = new("Frame", { Size = UDim2.fromOffset(40, 22), Position = UDim2.new(1, -54, 0.5, -11), BackgroundColor3 = C.off, Parent = card })
	round(switch, 11)
	local knob = new("Frame", { Size = UDim2.fromOffset(18, 18), Position = UDim2.fromOffset(2, 2), BackgroundColor3 = C.text, Parent = switch })
	round(knob, 9)
	tooltip(card, desc) -- la explicación solo aparece al pasar el cursor

	local id = type(text) == "table" and text.es or text
	local obj = { value = false, onChange = onChange, noSave = noSave }
	function obj.set(v)
		obj.value = v
		tween(switch, { BackgroundColor3 = v and C.on or C.off }, FAST)
		tween(knob, { Position = UDim2.fromOffset(v and 20 or 2, 2) }, FAST)
	end
	card.MouseButton1Click:Connect(function()
		obj.set(not obj.value)
		task.spawn(onChange, obj.value)
	end)
	table.insert(refreshHooks, function() switch.BackgroundColor3 = obj.value and C.on or C.off end)
	toggles[id] = obj
	return obj
end

-- Botón de acción. Si "parent" es una página, va a su cuadrícula de acciones; si es una cuadrícula
-- creada con grid(), va dentro de ella.
local function button(parent, text, onClick, desc)
	local inList = not pages[parent] -- botones de una lista (teleports, GUIs): texto a la izquierda y flecha
	local b = new("TextButton", {
		Text = text,
		Font = FONT_SEMI,
		TextSize = 13,
		TextColor3 = C.text,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = inList and Enum.TextXAlignment.Left or Enum.TextXAlignment.Center,
		BackgroundColor3 = C.card,
		AutoButtonColor = false,
		LayoutOrder = nextOrder(),
		Parent = inList and parent or gridFor(parent, "action"),
	})
	round(b, 8)
	hoverFx(b, outline(b), "card", "cardHover")
	if inList then
		new("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 28), Parent = b })
		local arrow = new("TextLabel", {
			Text = "›",
			Font = FONT_BOLD,
			TextSize = 18,
			TextColor3 = C.dim,
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, 20, 0.5, -1),
			Size = UDim2.fromOffset(16, 16),
			Parent = b,
		})
		b.MouseEnter:Connect(function() tween(arrow, { TextColor3 = C.accent, Position = UDim2.new(1, 23, 0.5, -1) }, FAST) end)
		b.MouseLeave:Connect(function() tween(arrow, { TextColor3 = C.dim, Position = UDim2.new(1, 20, 0.5, -1) }, FAST) end)
	end
	local s = new("UIScale", { Parent = b })
	b.MouseButton1Click:Connect(function()
		tween(s, { Scale = 0.97 }, 0.06).Completed:Wait()
		tween(s, { Scale = 1 }, FAST)
		task.spawn(onClick)
	end)
	tooltip(b, desc)
	return b
end

-- Cuadrícula para listas de botones (teleports, GUIs) o de chips (kind = "chip")
local function grid(page, kind)
	currentGrid[page] = nil
	return makeGrid(page, kind or "tp").frame
end

-- Chip seleccionable (p. ej. elegir frutas). Marcado = fondo morado suave y texto morado.
local function chip(parent, text, onClick, desc)
	local b = new("TextButton", {
		Text = text,
		Font = FONT_SEMI,
		TextSize = 12,
		TextColor3 = C.dim,
		TextTruncate = Enum.TextTruncate.AtEnd,
		BackgroundColor3 = C.card,
		AutoButtonColor = false,
		LayoutOrder = nextOrder(),
		Parent = parent,
	})
	round(b, 15)
	local stroke = outline(b)
	local obj = { value = false }
	function obj.set(v)
		obj.value = v
		tween(b, { BackgroundColor3 = v and C.accentSoft or C.card, TextColor3 = v and C.accent or C.dim }, FAST)
		tween(stroke, { Color = v and C.accent or C.line }, FAST)
	end
	b.MouseEnter:Connect(function() if not obj.value then tween(b, { TextColor3 = C.text }, FAST) end end)
	b.MouseLeave:Connect(function() if not obj.value then tween(b, { TextColor3 = C.dim }, FAST) end end)
	b.MouseButton1Click:Connect(function() onClick(obj) end)
	tooltip(b, desc)
	table.insert(refreshHooks, function() obj.set(obj.value) end)
	return obj
end

local pageAuto = addTab(L("Automatización", "Automation"),
	L("Automatizaciones que funcionan solas mientras están encendidas.", "Automations that run on their own while turned on."))
local pageTrain = addTab("Train",
	L("Entrenamiento de haki con Rayleigh, en bucle hasta el límite diario.", "Haki training with Rayleigh, looped until the daily limit."))
local pageFruits = addTab(L("Frutas", "Fruits"), L("Recoge Devil Fruits del mapa: las que elijas o cualquiera desde una rareza mínima.", "Collects Devil Fruits on the map: the ones you pick or any from a minimum rarity."))
local pageTp = addTab("Teleports", L("Viaja al instante a NPCs e islas.", "Travel instantly to NPCs and islands."))
local pageGuis = addTab("GUIs", L("Abre los menús del juego desde donde estés.", "Open the game's menus from anywhere."))
local pageMisc = addTab("Misc", L("Utilidades sueltas.", "Miscellaneous utilities."))
local pageSettings = addTab(L("Ajustes", "Settings"), L("Idioma, tamaño y posición del hub.", "Language, size and position of the hub."))

-- Si cambia el tamaño de la pantalla, la ventana y las columnas se adaptan
table.insert(cleanup, workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
	WIDTH, HEIGHT = fitSize()
	tween(main, { Size = UDim2.fromOffset(WIDTH, minimized and HEADER_H or HEIGHT) }, NORMAL)
	for _, g in grids do layoutGrid(g) end
end))


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

-- Velocidad de Auto Chest (chips: solo uno marcado)
local speedGrid = grid(pageAuto, "chip")
local speedChips = {}
for i, sp in CHEST_SPEEDS do
	speedChips[i] = chip(speedGrid, sp.name, function()
		config.chestSpeed = i
		saveConfig()
		for j, c in speedChips do c.set(j == i) end
	end, L("Velocidad de Auto Chest. Si se salta muchos cofres, usa una más lenta.", "Auto Chest speed. If it skips many chests, use a slower one."))
	speedChips[i].set(i == config.chestSpeed)
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

------------------------------------------------------------------ Zona segura
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
local safeBack -- dónde estabas al encenderla
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

-- shortcut: se supone que una fruta suelta es una Tool en el workspace con el nombre de la fruta
-- (p. ej. "Chop Fruit"); los objetos sueltos que no encajan se apuntan en la consola para ajustarlo.
local function fruitOf(obj)
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
	hrp = getHRP()
	if hrp and firetouchinterest then
		firetouchinterest(hrp, handle, 0)
		firetouchinterest(hrp, handle, 1)
	end
	local t0 = os.clock()
	while onGround(tool) and os.clock() - t0 < 1.5 do task.wait(0.1) end
	returnTo(back)
	if onGround(tool) then
		fruitTried[tool] = os.clock()
		log(T("Frutas: no pude coger ", "Fruits: couldn't pick up ") .. name, "warn")
	else
		log(T("Frutas: recogida ", "Fruits: picked up ") .. name, "ok", true)
	end
end

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

-- Rareza mínima: un chip por rareza, solo uno marcado
section(pageFruits, L("Rareza mínima", "Minimum rarity"))
local rarityGrid = grid(pageFruits, "chip")
local rarityChips = {}
for rank, r in FRUIT_RARITIES do
	rarityChips[rank] = chip(rarityGrid, r.name, function()
		config.fruitMin = rank
		saveConfig()
		for i, c in rarityChips do c.set(i == rank) end
	end, L("Solo recoge frutas de esta rareza o mejores.", "Only picks up fruits of this rarity or better."))
	rarityChips[rank].set(rank == config.fruitMin)
end

-- Frutas concretas: varias a la vez; si no hay ninguna marcada, vale cualquiera
local fruitChips = {}
for _, r in FRUIT_RARITIES do
	section(pageFruits, r.name)
	local g = grid(pageFruits, "chip")
	for _, f in r.fruits do
		fruitChips[f] = chip(g, f, function(c)
			config.fruitSel[f] = (not c.value) or nil
			saveConfig()
			c.set(not c.value)
		end, L("Marca o desmarca " .. f .. ".", "Select or unselect " .. f .. "."))
		fruitChips[f].set(config.fruitSel[f] == true)
	end
end
note(pageFruits, L("Si no marcas ninguna fruta, recoge cualquiera desde la rareza mínima. Si marcas algunas, solo esas (y que cumplan la rareza mínima).",
	"If you don't select any fruit, it picks up any from the minimum rarity. If you select some, only those (as long as they meet the minimum rarity)."))
button(pageFruits, L("Quitar selección", "Clear selection"), function()
	table.clear(config.fruitSel)
	saveConfig()
	for _, c in fruitChips do c.set(false) end
end, L("Desmarca todas las frutas.", "Unselects every fruit."))

local NPCS -- también lo usa la pestaña GUIs
end

------------------------------------------------------------------ Teleports
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
-- NPCs con interfaz o servicio útil (también los usa la pestaña GUIs)
NPCS = {
	{ name = "Quest Man (Sam's Bar)", model = "QuestMerchant2" },
	{ name = "Silvers Rayleigh", model = "QuestHakiMerchant" },
	{ name = "Strange Compass Shop", model = "FriendMerchant" },
	{ name = "Fish Merchant", model = "QuestFishMerchant" },
}

section(pageTp, "NPCs")
local npcGrid = grid(pageTp)
for _, entry in NPCS do
	button(npcGrid, entry.name, function()
		local npc = merchant(entry.model)
		if not npc then return log(T("No encuentro a ", "Can't find ") .. entry.name, "warn") end
		teleport(npc:GetPivot().Position + Vector3.new(0, 3, 4))
		log(T("Llevado a ", "Taken to ") .. entry.name)
	end, L("Te lleva junto a " .. entry.name, "Takes you to " .. entry.name))
end

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

section(pageTp, L("Islas", "Islands"))
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
for _, island in islands do
	local name = islandName(island)
	button(islandGrid, name, function()
		-- El tablón está en tierra firme. Sin tablón: la isla si es un modelo, o cualquier pieza suya
		-- (una carpeta no tiene posición y GetPivot daría error)
		local target = island:FindFirstChild("QuestBoard")
			or (island:IsA("PVInstance") and island)
			or island:FindFirstChildWhichIsA("BasePart", true)
		if not target then return log(T("No sé dónde está ", "Don't know where this is: ") .. name, "warn") end
		teleport(target:GetPivot().Position + Vector3.new(0, 5, 0))
		log(T("Llevado a ", "Taken to ") .. name)
	end, L("Te lleva a " .. name, "Takes you to " .. name))
end
if #islands == 0 then note(pageTp, L("No encuentro Workspace.Map.Islands.", "Can't find Workspace.Map.Islands.")) end

end

------------------------------------------------------------------ GUIs
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
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

local waitingKey = false -- también lo usa la tecla para ocultar
local applyProfile -- también se usa al iniciar
end

------------------------------------------------------------------ Ajustes
do -- bloque propio: sus variables no cuentan para el límite de 200 locales del script
section(pageSettings, L("Idioma", "Language"))
button(pageSettings, "Español", function()
	setLang("es")
	log("Idioma: español", "ok", true)
end, L("Pone el hub en español.", "Switches the hub to Spanish."))
button(pageSettings, "English", function()
	setLang("en")
	log("Language: English", "ok", true)
end, L("Pone el hub en inglés.", "Switches the hub to English."))

section(pageSettings, L("Paleta de colores", "Color palette"))
for _, name in PALETTE_ORDER do
	button(pageSettings, name, function()
		setPalette(name)
		log(T("Paleta: ", "Palette: ") .. name, "ok", true)
	end, L("Cambia los colores del hub a la paleta " .. name .. ".", "Changes the hub colors to the " .. name .. " palette."))
end

section(pageSettings, L("Interfaz", "Interface"))
local notifyToggle = toggle(pageSettings, L("Notificaciones", "Notifications"), function(on)
	config.notify = on
	saveConfig()
end, L("Muestra avisos abajo a la derecha. Los errores se avisan siempre.", "Shows notices at the bottom right. Errors are always shown."), true)
notifyToggle.set(config.notify)

waitingKey = false
local keyButton
keyButton = button(pageSettings, L("Tecla: " .. config.key, "Key: " .. config.key), function()
	if waitingKey then return end
	waitingKey = true
	bind(keyButton, "Text", L("Pulsa una tecla...", "Press a key..."))
	local input
	repeat
		input = UIS.InputBegan:Wait()
	until input.UserInputType == Enum.UserInputType.Keyboard and not UIS:GetFocusedTextBox()
	config.key = input.KeyCode.Name
	saveConfig()
	bind(keyButton, "Text", L("Tecla: " .. config.key, "Key: " .. config.key))
	bind(subtitle, "Text", keyHint())
	task.defer(function() waitingKey = false end) -- que esa misma pulsación no oculte el hub
	log(T("Tecla para ocultar: ", "Hide key: ") .. config.key, "ok", true)
end, L("Elige la tecla que muestra u oculta el hub.", "Choose the key that shows or hides the hub."))

local function setScale(v)
	userScale = math.clamp(v, 0.5, 2)
	config.scale = userScale
	saveConfig()
	tween(mainScale, { Scale = userScale }, NORMAL)
end
button(pageSettings, L("Tamaño +", "Size +"), function() setScale(userScale + 0.1) end, L("Agranda el hub un 10 %.", "Makes the hub 10% bigger."))
button(pageSettings, L("Tamaño −", "Size −"), function() setScale(userScale - 0.1) end, L("Reduce el hub un 10 %.", "Makes the hub 10% smaller."))
button(pageSettings, L("Restablecer posición y tamaño", "Reset position and size"), function()
	setScale(1)
	tween(main, { Position = UDim2.new(0.5, -WIDTH / 2, 0.5, -HEIGHT / 2) }, 0.35)
end, L("Vuelve al tamaño original y centra el hub en la pantalla.", "Goes back to the original size and centers the hub on screen."))
note(pageSettings, L("También puedes arrastrar la esquina ◢ de abajo a la derecha para cambiar el tamaño. Todo lo que cambies aquí se guarda para la próxima vez.",
	"You can also drag the ◢ corner at the bottom right to resize. Everything you change here is saved for next time."))

------------------------------------------------------------------ Perfiles
-- Un perfil guarda qué funciones están encendidas y los ajustes (idioma, paleta, tecla, avisos, tamaño)
-- con el nombre que elijas. Se guardan en config.profiles (archivo ElHoyoHub.json).
local DEFAULT_PROFILE = { toggles = {}, lang = "es", palette = "Abismo", key = "RightShift", notify = true, scale = 1 }

local function currentProfile()
	local on = {}
	for id, t in toggles do
		if t.value and not t.noSave then on[id] = true end
	end
	return { toggles = on, lang = LANG, palette = config.palette, key = config.key, notify = config.notify, scale = userScale }
end

applyProfile = function(p)
	for id, t in toggles do
		local want = not t.noSave and p.toggles ~= nil and p.toggles[id] == true
		if not t.noSave and t.value ~= want then
			t.set(want)
			task.spawn(t.onChange, want)
		end
	end
	if p.lang then setLang(p.lang) end
	if p.palette and PALETTES[p.palette] then setPalette(p.palette) end
	if p.key and Enum.KeyCode[p.key] then
		config.key = p.key
		bind(keyButton, "Text", L("Tecla: " .. config.key, "Key: " .. config.key))
		bind(subtitle, "Text", keyHint())
	end
	if p.notify ~= nil then
		config.notify = p.notify
		notifyToggle.set(p.notify)
	end
	if p.scale then setScale(p.scale) end
	saveConfig()
end

section(pageSettings, L("Perfiles", "Profiles"))
local profileName = input(pageSettings, L("Nombre del perfil", "Profile name"))

local function nameOrWarn()
	local name = profileName.Text:match("^%s*(.-)%s*$")
	if name == "" then
		log(T("Escribe un nombre de perfil", "Type a profile name"), "warn")
		return nil
	end
	return name
end

local profileList -- cuadrícula con los perfiles guardados (se rellena abajo)
local function refreshProfiles()
	for _, child in profileList:GetChildren() do
		if child:IsA("GuiButton") then child:Destroy() end
	end
	local names = {}
	for name in config.profiles do table.insert(names, name) end
	table.sort(names)
	for _, name in names do
		button(profileList, name, function() profileName.Text = name end,
			L("Pone este nombre en el campo de arriba.", "Puts this name in the field above."))
	end
end

-- Borrar y Resetear piden pulsar dos veces (en 3 s) para no perder nada por error
local armed = {}
local function confirmed(action)
	if armed[action] and os.clock() - armed[action] < 3 then
		armed[action] = nil
		return true
	end
	armed[action] = os.clock()
	log(T("Pulsa otra vez para confirmar", "Press again to confirm"), "warn")
	return false
end

button(pageSettings, L("Guardar", "Save"), function()
	local name = nameOrWarn()
	if not name then return end
	config.profiles[name] = currentProfile()
	saveConfig()
	refreshProfiles()
	log(T("Perfil guardado: ", "Profile saved: ") .. name, "ok", true)
end, L("Guarda las funciones encendidas y los ajustes con este nombre (si ya existe, lo sobrescribe).",
	"Saves the active features and settings under this name (overwrites it if it exists)."))
button(pageSettings, L("Cargar", "Load"), function()
	local name = nameOrWarn()
	if not name then return end
	local p = config.profiles[name]
	if not p then return log(T("No existe el perfil ", "There's no profile called ") .. name, "warn") end
	applyProfile(p)
	log(T("Perfil cargado: ", "Profile loaded: ") .. name, "ok", true)
end, L("Enciende y apaga las funciones y aplica los ajustes de este perfil.", "Turns features on and off and applies this profile's settings."))
button(pageSettings, L("Borrar", "Delete"), function()
	local name = nameOrWarn()
	if not name then return end
	if not config.profiles[name] then return log(T("No existe el perfil ", "There's no profile called ") .. name, "warn") end
	if not confirmed("delete:" .. name) then return end
	config.profiles[name] = nil
	saveConfig()
	refreshProfiles()
	log(T("Perfil borrado: ", "Profile deleted: ") .. name, "ok", true)
end, L("Borra este perfil. Pulsa dos veces para confirmar.", "Deletes this profile. Press twice to confirm."))
button(pageSettings, L("Resetear", "Reset"), function()
	if not confirmed("reset") then return end
	applyProfile(DEFAULT_PROFILE)
	log(T("Todo apagado y ajustes por defecto", "Everything off and default settings"), "ok", true)
end, L("Apaga todas las funciones y vuelve a los ajustes por defecto. No borra tus perfiles. Pulsa dos veces para confirmar.",
	"Turns every feature off and goes back to the default settings. Doesn't delete your profiles. Press twice to confirm."))

note(pageSettings, L("Perfiles guardados (pulsa uno para elegirlo):", "Saved profiles (click one to pick it):"))
profileList = grid(pageSettings)
refreshProfiles()

-- Perfil que se carga solo al abrir el hub (útil al cambiar de servidor)
local autoProfileNote = note(pageSettings, "")
local function showAutoProfile()
	bind(autoProfileNote, "Text", config.autoProfile
		and L("Al abrir el hub se carga el perfil: " .. config.autoProfile, "When the hub opens it loads the profile: " .. config.autoProfile)
		or L("Ningún perfil se carga solo al abrir el hub.", "No profile loads automatically when the hub opens."))
end
showAutoProfile()
button(pageSettings, L("Cargar al iniciar", "Load on start"), function()
	local name = nameOrWarn()
	if not name then return end
	if not config.profiles[name] then return log(T("No existe el perfil ", "There's no profile called ") .. name, "warn") end
	config.autoProfile = name
	saveConfig()
	showAutoProfile()
	log(T("Se cargará al iniciar: ", "Will load on start: ") .. name, "ok", true)
end, L("Este perfil se cargará solo cada vez que se abra el hub.", "This profile will load by itself every time the hub opens."))
button(pageSettings, L("No cargar al iniciar", "Don't load on start"), function()
	config.autoProfile = nil
	saveConfig()
	showAutoProfile()
end, L("Ningún perfil se cargará solo al abrir el hub.", "No profile will load by itself when the hub opens."))

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
local urlBox = input(pageSettings, L("URL raw del script (la de tu loadstring)", "Script raw URL (the one in your loadstring)"))
urlBox.Text = config.hubUrl or ""
urlBox.FocusLost:Connect(function()
	config.hubUrl = urlBox.Text:match("^%s*(.-)%s*$")
	saveConfig()
	applyAutoexec()
end)
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
end, L("El hub se abre solo al entrar al juego y al cambiar de servidor. Junto con \"Cargar al iniciar\", sigue farmeando donde lo dejaste.",
	"The hub opens by itself when you join the game and when you change server. Together with \"Load on start\", it keeps farming where you left off."), true)
autoExecToggle.set(config.autoExec == true)
note(pageSettings, L("Se guarda un archivo ElHoyoHub.lua en la carpeta autoexec de tu executor que descarga el hub de esa URL. Solo se ejecuta en este juego.",
	"A file ElHoyoHub.lua is saved in your executor's autoexec folder that downloads the hub from that URL. It only runs in this game."))
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
button(pageSettings, L("Cerrar El Hoyo Hub", "Close El Hoyo Hub"), function() closeHub() end,
	L("Apaga todas las funciones y cierra el hub.", "Turns off every feature and closes the hub."))

end

------------------------------------------------------------------ Tamaño, ocultar, cursor, cerrar
-- Esquina para escalar todo el hub arrastrando
local grip = new("TextButton", {
	Text = "◢",
	TextSize = 12,
	TextColor3 = C.line,
	BackgroundTransparency = 1,
	Size = UDim2.fromOffset(16, 16),
	Position = UDim2.new(1, -18, 1, -18),
	ZIndex = 5,
	Parent = main,
})
grip.MouseEnter:Connect(function() tween(grip, { TextColor3 = C.accent }, FAST) end)
grip.MouseLeave:Connect(function() tween(grip, { TextColor3 = C.line }, FAST) end)
tooltip(grip, L("Arrastra para cambiar el tamaño", "Drag to resize"))
local resizing, startX, startScale = false, 0, 1
grip.MouseButton1Down:Connect(function()
	resizing, startX, startScale = true, mouse.X, userScale
end)
table.insert(cleanup, UIS.InputChanged:Connect(function(input)
	if resizing and input.UserInputType == Enum.UserInputType.MouseMovement then
		userScale = math.clamp(startScale + (mouse.X - startX) / 300, 0.5, 2)
		mainScale.Scale = userScale
	end
end))
table.insert(cleanup, UIS.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 and resizing then
		resizing = false
		config.scale = userScale
		saveConfig()
	end
end))

local mainShown = true
local function setMain(show)
	mainShown = show
	hideTip()
	if show then
		main.Visible = true
		mainScale.Scale = userScale * 0.96
		tween(mainScale, { Scale = userScale }, NORMAL)
	else
		tween(mainScale, { Scale = userScale * 0.96 }, FAST)
		task.delay(FAST, function()
			if not mainShown then main.Visible = false end
		end)
	end
end
table.insert(cleanup, UIS.InputBegan:Connect(function(input)
	if waitingKey or UIS:GetFocusedTextBox() then return end
	if input.KeyCode.Name == config.key then setMain(not mainShown) end
end))

-- Cursor: el juego a veces lo esconde o lo bloquea en el centro. Un botón Modal visible libera el ratón
-- mientras el hub está abierto, y encima del hub o la consola se fuerza a que se vea.
new("TextButton", { Text = "", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0), Modal = true, Parent = main })
table.insert(cleanup, game:GetService("RunService").RenderStepped:Connect(function()
	if overOurGui() then UIS.MouseIconEnabled = true end
end))

closeHub = function()
	alive = false
	for _, c in cleanup do c:Disconnect() end
	tween(mainScale, { Scale = userScale * 0.94 }, FAST)
	tween(main, { BackgroundTransparency = 1 }, FAST)
	task.delay(FAST, function() gui:Destroy() end)
end

------------------------------------------------------------------ Inicio
genv.ElHoyoHubClose = closeHub
selectTab(tabs[1])
tween(mainScale, { Scale = userScale }, NORMAL)
log(T("El Hoyo Hub cargado", "El Hoyo Hub loaded"), "ok", true)
for _, name in missingRemotes do
	log(T("No encuentro la señal ", "Can't find the signal ") .. name .. T(" (¿actualización del juego?)", " (game update?)"), "error")
end
if config.autoProfile and config.profiles[config.autoProfile] then
	applyProfile(config.profiles[config.autoProfile])
	log(T("Perfil cargado al iniciar: ", "Profile loaded on start: ") .. config.autoProfile, "ok", true)
end

