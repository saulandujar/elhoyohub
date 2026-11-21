-- El Hoyo Hub v1.5.4-rc1 (build 62ad6e91). ARCHIVO GENERADO por tools/build.js: no editar aquí,
-- el código está en src/ (ver ARCHITECTURE.md). Módulos: Lifecycle, Components, Config, Webhook, Tokens, Layout, Search, Notifications, ElHoyoUI, Console, Ownership, Protection, Knowledge, KnowledgeView, CatalogIndex, Profiles, Diagnostics, NpcFarm, Favorites.
local import -- se asigna después de los módulos: así los módulos la ven (upvalue) y pueden importar otros
local __modules = {}
__modules["Lifecycle"] = function(...)
-- Lifecycle: ciclo de vida del hub. Sin dependencias de Roblox más allá de `task` (inyectable para pruebas).
--  * life.alive / life.stage ("loading" → "ready" → "closing" → "closed"; "failed" si la carga falla)
--  * life.cleanup: lista de cosas con :Disconnect() que se deshacen al cerrar, EN ORDEN (el primero, primero)
--  * life.addFinal: lo que se deshace DESPUÉS de todo lo anterior (la interfaz y la GUI: así ninguna conexión que
--    aún no se ha soltado se encuentra la ventana destruida) · life.startedAt / life.readyAt: tiempos de carga
--  * life.spawn / life.delay / life.defer: como task.*, pero el error va a life.errors en vez de perderse
--  * life.errors: registro de errores con contador (los repetidos no se esconden: suman y se vuelven a avisar)
--  * 1.4.1: cada hilo es una TAREA con id y origen (componente). Un hilo lanzado desde otro HEREDA su origen: los
--    bucles internos de una función también la identifican. Tipos de error: recoverable | config | critical.
--    life.tasks(), life.cancel(origen), life.try(origen, fn, ...), life.leaks() (lo que sobrevive al cierre).
-- Sustituye al `task` global envuelto de 1.3.1: así el código dice lo que hace y el `task` de Roblox no cambia.
local Lifecycle = {}

local ErrorLog = {}
ErrorLog.__index = ErrorLog
-- max: errores distintos que se guardan; remind: cada cuántos s se vuelve a avisar uno que se repite
function ErrorLog.new(max, remind, clock)
	return setmetatable({ list = {}, byKey = {}, max = max or 30, remind = remind or 60, clock = clock or os.clock, total = 0,
		byKind = {}, bySource = {} }, ErrorLog)
end
-- Apunta un error. Devuelve el texto a mostrar o nil si no toca avisar todavía (repetido hace poco).
-- kind = "recoverable" (por defecto) | "config" | "critical"
function ErrorLog:add(err, source, kind)
	local text = tostring(err)
	local first = text:match("^[^\n]*") or text
	local key = (source or "") .. "|" .. first
	local now = self.clock()
	kind = kind or "recoverable"
	self.total += 1
	self.byKind[kind] = (self.byKind[kind] or 0) + 1
	if source then self.bySource[source] = (self.bySource[source] or 0) + 1 end
	local e = self.byKey[key]
	if e then
		e.count += 1
		e.last = now
		if now - e.shown >= self.remind then
			local unseen = e.count - e.shownCount
			e.shown, e.shownCount = now, e.count
			return first .. " (x" .. unseen .. " más desde el último aviso)"
		end
		return nil
	end
	e = { key = key, message = first, trace = text, source = source, kind = kind, count = 1, first = now, last = now, shown = now, shownCount = 1 }
	self.byKey[key] = e
	table.insert(self.list, e)
	if #self.list > self.max then
		local old = table.remove(self.list, 1)
		self.byKey[old.key] = nil
	end
	return first
end
-- Los más recientes primero
function ErrorLog:recent(n)
	local out = {}
	for i = #self.list, math.max(1, #self.list - (n or 10) + 1), -1 do table.insert(out, self.list[i]) end
	return out
end
Lifecycle.ErrorLog = ErrorLog

-- opts.task (por defecto el de Roblox), opts.onError(texto, entrada) para mostrarlo (consola del hub)
function Lifecycle.new(opts)
	opts = opts or {}
	local realTask = opts.task or task
	local clock = opts.clock or os.clock
	local life = { alive = true, stage = "loading", onError = false, cleanup = {}, final = {}, closeErrors = 0,
		errors = ErrorLog.new(opts.maxErrors, opts.remind, opts.clock), threads = 0, startedAt = clock(), readyAt = nil }

	-- Si mostrar un error falla (o vuelve a llamar a report), no se entra en bucle: se cuenta y ya está
	life.reportFailures = 0
	local reporting = false
	function life.report(err, source, kind)
		local shown = life.errors:add(err, source, kind)
		if shown and life.alive and life.onError and not reporting then
			reporting = true
			local ok = pcall(life.onError, shown, source, kind)
			reporting = false
			if not ok then life.reportFailures += 1 end
		end
	end

	-- Tareas: id, origen, cuándo empezó. sourceOf[hilo] = origen, para que los hilos hijos lo hereden.
	local sourceOf = setmetatable({}, { __mode = "k" })
	local running = {} -- [entry] = true mientras corre
	local nextId = 0
	local function current() return sourceOf[coroutine.running()] end
	life.current = current

	local function guarded(fn, source)
		if type(fn) ~= "function" then return fn end -- un hilo se deja igual
		return function(...)
			local co = coroutine.running()
			sourceOf[co] = source
			nextId += 1
			local entry = { id = nextId, source = source, at = clock(), thread = co }
			running[entry] = true
			life.threads += 1
			local ok, err = xpcall(fn, debug.traceback, ...)
			life.threads -= 1
			running[entry] = nil
			if not ok and life.alive then life.report(err, source) end
		end
	end
	life.guarded = guarded
	-- spawn/defer/delay heredan el origen del hilo que los llama; spawnAs lo pone explícitamente
	function life.spawn(fn, ...) return realTask.spawn(guarded(fn, current()), ...) end
	function life.spawnAs(source, fn, ...) return realTask.spawn(guarded(fn, source), ...) end
	function life.defer(fn, ...) return realTask.defer(guarded(fn, current()), ...) end
	function life.delay(t, fn, ...) return realTask.delay(t, guarded(fn, current()), ...) end

	-- Tareas en curso: { id, source, age }
	function life.tasks()
		local out = {}
		for entry in running do
			if coroutine.status(entry.thread) == "dead" then running[entry] = nil
			else table.insert(out, { id = entry.id, source = entry.source, age = clock() - entry.at }) end
		end
		table.sort(out, function(a, b) return a.id < b.id end)
		return out
	end
	-- Cancela las tareas de un origen (que no sea la que llama). Devuelve cuántas.
	function life.cancel(source)
		local n, me = 0, coroutine.running()
		for entry in running do
			if entry.source == source and entry.thread ~= me and coroutine.status(entry.thread) ~= "dead" then
				if pcall(realTask.cancel, entry.thread) then n += 1 end
				running[entry] = nil
				life.threads -= 1
			end
		end
		return n
	end
	-- pcall que NO esconde el fallo: lo apunta con su origen y tipo. Devuelve ok, resultado (o mensaje).
	function life.try(source, fn, ...)
		local ok, res = pcall(fn, ...)
		if not ok then life.report(res, source, "recoverable") end
		return ok, res
	end

	-- Registra algo que hay que deshacer al cerrar: una conexión, o una función. Devuelve lo mismo.
	function life.add(item, first)
		local entry = type(item) == "function" and { Disconnect = item } or item
		if first then table.insert(life.cleanup, 1, entry) else table.insert(life.cleanup, entry) end
		return item
	end
	function life.connect(signal, fn) return life.add(signal:Connect(fn)) end
	-- Igual que add, pero se deshace al final del cierre (después de todo lo registrado con add)
	function life.addFinal(item)
		table.insert(life.final, type(item) == "function" and { Disconnect = item } or item)
		return item
	end

	-- Lo que se soltó al cerrar, para comprobar después que de verdad se soltó (life.leaks)
	local released = setmetatable({}, { __mode = "k" })
	-- Cerrar varias veces no hace nada más. Cada paso va en pcall: uno que falle no deja el resto sin deshacer.
	function life.close()
		if not life.alive then return false end
		life.alive = false
		life.stage = "closing"
		for _, group in { life.cleanup, life.final } do
			for _, c in group do
				local ok, err = pcall(c.Disconnect, c)
				released[c] = true
				if not ok then
					life.closeErrors += 1
					life.errors:add(err, "close", "critical")
				end
			end
			table.clear(group)
		end
		life.stage = "closed"
		return true
	end

	-- Tras cerrar: conexiones que siguen conectadas y tareas que siguen vivas (no debería haber ninguna; las tareas
	-- que esperan con task.wait salen solas al ver life.alive = false: `grace` = segundos que se les dan)
	function life.leaks(grace)
		local out = { connections = 0, tasks = {} }
		for c in released do
			if type(c) == "table" and c.Connected == true or typeof and typeof(c) == "RBXScriptConnection" and c.Connected then
				out.connections += 1
			end
		end
		for _, t in life.tasks() do
			if t.age > (grace or 0) then table.insert(out.tasks, t) end
		end
		return out
	end

	-- Para diagnósticos: cuántas cosas hay registradas y cuántas conexiones siguen vivas
	function life.stats()
		local connections, connected = 0, 0
		for _, c in life.cleanup do
			if typeof and typeof(c) == "RBXScriptConnection" or type(c) == "table" and c.Connected ~= nil then
				connections += 1
				if c.Connected then connected += 1 end
			end
		end
		return { cleanups = #life.cleanup, finals = #life.final, connections = connections, connected = connected, threads = life.threads,
			errors = #life.errors.list, errorTotal = life.errors.total, closeErrors = life.closeErrors, tasks = #life.tasks(),
			errorKinds = table.clone(life.errors.byKind), reportFailures = life.reportFailures,
			initTime = life.readyAt and (life.readyAt - life.startedAt) or nil }
	end
	return life
end

-- Un hub por sesión: registra el cierre en `registry` (getgenv()) y cierra el anterior. Devuelve si había otro.
function Lifecycle.claim(registry, key, life)
	local previous = registry[key]
	if type(previous) == "function" then pcall(previous) end
	registry[key] = life.close
	return previous ~= nil
end

-- ¿Sirve esta versión de una dependencia? (número o nil = 1)
function Lifecycle.compatible(version, minimum)
	return (tonumber(version) or 1) >= minimum
end

return Lifecycle
end
__modules["Components"] = function(...)
-- Components: estado central de los componentes del hub (infraestructura, informativos y funciones).
-- v2 (1.4.1): separa la INTENCIÓN (desiredState: lo que se pidió) del ESTADO REAL (runtimeState, alias `state`: lo que
-- está pasando), la disponibilidad (dependencias) y el motivo. Contrato reutilizable para componentes internos:
--   impl = { init(c), start(c, token), stop(c), pause(c), resume(c), destroy(c) }   (todas opcionales)
--   c:init() c:start() c:stop() c:pause() c:resume() c:destroy() c:getStatus()
-- start/stop son idempotentes; cada start/stop cambia la GENERACIÓN: un token o una tarea de una generación vieja ya
-- no puede tocar el componente (c:token().alive() == false). Sin Roblox: reloj, spawn y cancel se inyectan.
local Components = {}

Components.STATES = { "Disabled", "Initializing", "Ready", "Running", "Waiting", "Paused", "Stopping", "Error", "Unavailable" }
local VALID = {}
for _, s in Components.STATES do VALID[s] = true end
Components.VALID = VALID
-- Intenciones posibles
Components.DESIRED = { Disabled = true, Running = true, Paused = true }

-- Activo = cuenta como tiempo de actividad y satisface a quien dependa de él
local ACTIVE = { Running = true, Waiting = true, Paused = true }
local SATISFIES = { Ready = true, Running = true, Waiting = true, Paused = true }
Components.ACTIVE, Components.SATISFIES = ACTIVE, SATISFIES

-- Transiciones permitidas (de -> a). Error se puede alcanzar desde cualquiera (fail).
local ALLOWED = {
	Disabled = { Initializing = true, Ready = true, Running = true, Unavailable = true },
	Initializing = { Ready = true, Running = true, Unavailable = true, Disabled = true },
	Ready = { Running = true, Waiting = true, Stopping = true, Disabled = true, Unavailable = true },
	Running = { Waiting = true, Paused = true, Stopping = true, Ready = true, Disabled = true },
	Waiting = { Running = true, Paused = true, Stopping = true, Ready = true, Disabled = true },
	Paused = { Running = true, Waiting = true, Stopping = true, Disabled = true },
	Stopping = { Disabled = true, Ready = true },
	Error = { Initializing = true, Ready = true, Running = true, Stopping = true, Disabled = true },
	Unavailable = { Initializing = true, Ready = true, Disabled = true },
}
Components.ALLOWED = ALLOWED
local HISTORY = 12 -- transiciones guardadas por componente

function Components.canMove(from, to)
	if from == to then return VALID[to] == true end
	if to == "Error" then return VALID[from] == true end
	return ALLOWED[from] ~= nil and ALLOWED[from][to] == true
end

local Component = {}
Component.__index = function(t, k)
	if k == "runtimeState" then return rawget(t, "state") end
	return Component[k]
end

-- Cambia el estado REAL. Devuelve true si cambió (o ya estaba), false + motivo si no está permitido.
function Component:set(state, reason)
	if not VALID[state] then return false, "estado desconocido: " .. tostring(state) end
	if not Components.canMove(self.state, state) then
		self.rejected += 1
		return false, self.state .. " -> " .. state .. " no permitido"
	end
	local now = self.registry.clock()
	if ACTIVE[state] and not ACTIVE[self.state] then
		self.activeSince = now
		self.startedAt = now
	end
	if not ACTIVE[state] and ACTIVE[self.state] then
		if self.activeSince then self.activeTotal += now - self.activeSince end
		self.activeSince = nil
		self.stoppedAt = now
	end
	local from = self.state
	local changed = from ~= state
	self.state, self.reason, self.since = state, reason, changed and now or self.since
	if changed then
		self.lastTransition = { from = from, to = state, at = now, reason = reason }
		table.insert(self.history, self.lastTransition)
		if #self.history > HISTORY then table.remove(self.history, 1) end
		self.registry:_changed(self)
	end
	return true
end

-- Intención: lo que se pidió (el interruptor, un start/stop). No cambia el estado real.
function Component:setDesired(desired)
	if not Components.DESIRED[desired] then return false end
	self.desiredState = desired
	return true
end

-- Error: guarda el mensaje (primera línea), cuántos lleva y de qué tipo (recoverable | config | critical)
function Component:fail(err, kind)
	kind = kind or "recoverable"
	self.errors += 1
	self.errorKinds[kind] = (self.errorKinds[kind] or 0) + 1
	self.lastError = (tostring(err):match("^[^\n]*"))
	self.lastErrorKind = kind
	return self:set("Error", self.lastError)
end

-- Tiempo activo (Running/Waiting/Paused) acumulado, contando el tramo actual
function Component:uptime()
	local t = self.activeTotal
	if self.activeSince then t += self.registry.clock() - self.activeSince end
	return t
end

-- Recursos propios (conexiones, funciones de limpieza): se sueltan con release(), en orden inverso
function Component:track(item)
	table.insert(self.resources, type(item) == "function" and { Disconnect = item } or item)
	return item
end
function Component:release()
	local n = #self.resources
	for i = n, 1, -1 do
		local item = self.resources[i]
		local ok, err = pcall(item.Disconnect, item)
		if not ok then self.registry:_report(self, err, "recoverable") end -- no se esconde: se apunta
	end
	table.clear(self.resources)
	return n
end

-- ¿Están todas sus dependencias registradas y en un estado que sirve? Devuelve ok y la primera que falla.
function Component:available()
	for _, dep in self.deps do
		local d = self.registry.byName[dep]
		if not d then return false, dep .. " no existe" end
		if not SATISFIES[d.state] then
			return false, dep .. " está en " .. d.state .. (d.reason and (" (" .. tostring(d.reason) .. ")") or "")
		end
	end
	return true
end

-- Token de la generación actual: alive() es false en cuanto hay otro start/stop o destroy
function Component:token()
	local gen = self.generation
	return { generation = gen, alive = function() return self.generation == gen and not self.destroyed end }
end

-- Lanza una tarea del componente: lleva su nombre (sus errores lo marcan en Error), se cancela al parar y no hace
-- nada si al empezar su generación ya no es la actual.
function Component:spawn(fn, ...)
	local token = self:token()
	local reg = self.registry
	local entry = { name = self.name, generation = token.generation }
	local thread = reg.spawn(function(...)
		if not token.alive() then return end
		local ok, err = xpcall(fn, debug.traceback, token, ...)
		self.tasks[entry] = nil
		if not ok and token.alive() then reg:_report(self, err, "recoverable") end
	end, ...)
	entry.thread = thread
	if thread ~= nil and (type(thread) ~= "thread" or coroutine.status(thread) ~= "dead") then self.tasks[entry] = true end
	return thread
end
function Component:taskCount()
	local n = 0
	for entry in self.tasks do
		if type(entry.thread) == "thread" and coroutine.status(entry.thread) == "dead" then self.tasks[entry] = nil else n += 1 end
	end
	return n
end
local function cancelTasks(self)
	local n = 0
	for entry in self.tasks do
		if type(entry.thread) == "thread" and coroutine.status(entry.thread) ~= "dead" then
			local ok = pcall(self.registry.cancel, entry.thread)
			if ok then n += 1 end
		end
		self.tasks[entry] = nil
	end
	return n
end

-- Llama a un paso del contrato en pcall. Un fallo marca Error (con su tipo) y devuelve false + mensaje.
local function hook(self, name, ...)
	local fn = self.impl and self.impl[name]
	if not fn then return true end
	local ok, err = pcall(fn, self, ...)
	if not ok then
		self:fail(err, name == "init" and "config" or "recoverable")
		return false, self.lastError
	end
	return true
end

function Component:init()
	if self.destroyed then return false, "destruido" end
	if self.initialized then return true end
	local okDeps, why = self:available()
	if not okDeps then
		self:set("Unavailable", why)
		return false, why
	end
	self:set("Initializing", nil)
	local ok, err = hook(self, "init")
	if not ok then return false, err end
	self.initialized = true
	self:set("Ready", nil)
	return true
end

function Component:start()
	self:setDesired("Running")
	if self.destroyed then return false, "destruido" end
	if self.state == "Running" or self.state == "Waiting" then return true end -- idempotente
	if self.state == "Paused" then return self:resume() end
	if not self.initialized or self.state == "Unavailable" then
		self.initialized = self.initialized and self.state ~= "Unavailable"
		local ok, why = self:init()
		if not ok then return false, why end
	end
	local okDeps, why = self:available()
	if not okDeps then
		self:set("Unavailable", why)
		return false, why
	end
	self.generation += 1
	if self.state == "Error" then self:set("Ready", "reintento") end
	local ok, err = hook(self, "start", self:token())
	if not ok then return false, err end
	if self.state ~= "Error" then self:set("Running", nil) end
	return true
end

function Component:stop(reason)
	self:setDesired("Disabled")
	if not (ACTIVE[self.state] or self.state == "Stopping") then return true end -- idempotente: ya parado
	self.generation += 1 -- lo que lanzó el start anterior ya no puede tocar nada
	self:set("Stopping", reason)
	cancelTasks(self)
	hook(self, "stop")
	if self.state == "Stopping" then self:set(self.initialized and "Ready" or "Disabled", reason) end
	return true
end

function Component:pause()
	if self.state == "Paused" then return true end
	if not (self.state == "Running" or self.state == "Waiting") then return false, "no está en marcha (" .. self.state .. ")" end
	self:setDesired("Paused")
	local ok, err = hook(self, "pause")
	if not ok then return false, err end
	self:set("Paused", nil)
	return true
end

function Component:resume()
	if self.state == "Running" then return true end
	if self.state ~= "Paused" then return false, "no está en pausa (" .. self.state .. ")" end
	self:setDesired("Running")
	local ok, err = hook(self, "resume")
	if not ok then return false, err end
	self:set("Running", nil)
	return true
end

function Component:destroy(reason)
	if self.destroyed then return true end
	self:stop(reason)
	hook(self, "destroy")
	self.destroyed = true
	self.generation += 1
	cancelTasks(self)
	self:release()
	if self.state ~= "Disabled" then
		if not self:set("Disabled", reason) then self.state = "Disabled" end
	end
	return true
end

function Component:getStatus()
	local ok, why = self:available()
	return {
		name = self.name, kind = self.kind, state = self.state, runtimeState = self.state, desiredState = self.desiredState,
		matches = (self.desiredState == "Running" and (self.state == "Running" or self.state == "Waiting"))
			or (self.desiredState == "Paused" and self.state == "Paused")
			or (self.desiredState == "Disabled" and not ACTIVE[self.state]),
		reason = self.reason, available = ok, unavailableWhy = why, availability = ok and "available" or "unavailable",
		deps = table.clone(self.deps), lastError = self.lastError, lastErrorKind = self.lastErrorKind, errors = self.errors,
		errorKinds = table.clone(self.errorKinds), resources = #self.resources, tasks = self:taskCount(),
		uptime = self:uptime(), startedAt = self.startedAt, stoppedAt = self.stoppedAt, lastTransition = self.lastTransition,
		generation = self.generation, destroyed = self.destroyed == true, rejected = self.rejected,
	}
end

local Registry = {}
Registry.__index = Registry

-- opts.clock (os.clock), opts.spawn(fn, ...) -> hilo (task.spawn), opts.cancel(hilo) (task.cancel),
-- opts.onError(componente, mensaje, tipo): para llevar el error al registro del hub
function Components.new(opts)
	opts = opts or {}
	local hasTask = type(task) == "table"
	return setmetatable({
		list = {}, byName = {}, clock = opts.clock or os.clock, listeners = {}, onError = opts.onError,
		spawn = opts.spawn or (hasTask and task.spawn) or function(fn, ...) local co = coroutine.create(fn); coroutine.resume(co, ...); return co end,
		cancel = opts.cancel or (hasTask and task.cancel) or function(co) coroutine.close(co) end,
	}, Registry)
end

-- info = { kind = "core" | "info" | "feature", deps = { nombres }, state = inicial (Disabled), reason, impl = contrato }
function Registry:register(name, info)
	info = info or {}
	local existing = self.byName[name]
	if existing then return existing end
	local c = setmetatable({
		name = name, kind = info.kind or "core", deps = info.deps or {}, state = "Disabled", reason = nil,
		desiredState = "Disabled", since = self.clock(), activeSince = nil, activeTotal = 0, errors = 0, errorKinds = {},
		lastError = nil, resources = {}, rejected = 0, registry = self, impl = info.impl, generation = 0, tasks = {},
		history = {}, initialized = info.state == "Ready", startedAt = nil, stoppedAt = nil,
	}, Component)
	self.byName[name] = c
	table.insert(self.list, c)
	if info.state and info.state ~= "Disabled" then
		c:set(info.state, info.reason)
		if ACTIVE[info.state] then c.desiredState = "Running" end
	end
	return c
end

function Registry:get(name) return self.byName[name] end

function Registry:onChange(fn) table.insert(self.listeners, fn) end
function Registry:_changed(c)
	for _, fn in self.listeners do
		local ok, err = pcall(fn, c)
		if not ok then self.listenerErrors = (self.listenerErrors or 0) + 1; self.lastListenerError = tostring(err) end
	end
end
-- Error de una tarea o de un recurso: marca el componente y avisa al hub (una sola vez: sin bucles de aviso)
function Registry:_report(c, err, kind)
	c:fail(err, kind)
	if self.onError and not self.reporting then
		self.reporting = true
		pcall(self.onError, c, c.lastError, kind)
		self.reporting = false
	end
end

-- Dependencias: lo que no puede funcionar pasa a Unavailable (con el motivo); lo que vuelve a poder, a Ready.
-- No toca lo apagado ni lo que está en Error (eso lo decide quien lo usa). Devuelve cuántos cambió.
function Registry:refresh()
	local n = 0
	for _ = 1, #self.list do -- varias pasadas: una cadena a -> b -> c se resuelve entera
		local changed = false
		for _, c in self.list do
			local ok, why = c:available()
			if not ok and c.state ~= "Disabled" and c.state ~= "Error" and c.state ~= "Unavailable" then
				if ACTIVE[c.state] then c.generation += 1; cancelTasks(c) end
				c:set("Stopping", why)
				c:set("Disabled", why)
				c:set("Unavailable", why)
				changed, n = true, n + 1
			elseif ok and c.state == "Unavailable" and #c.deps > 0 then
				c:set("Ready", nil)
				c.initialized = c.impl == nil or c.initialized
				changed, n = true, n + 1
			end
		end
		if not changed then break end
	end
	return n
end

-- Ciclos de dependencias (a necesita b y b necesita a): lista de nombres en ciclo
function Registry:cycles()
	local out, state = {}, {}
	local function visit(c, path)
		if state[c.name] == "done" then return end
		if state[c.name] == "open" then table.insert(out, table.concat(path, " -> ") .. " -> " .. c.name); return end
		state[c.name] = "open"
		table.insert(path, c.name)
		for _, dep in c.deps do
			local d = self.byName[dep]
			if d then visit(d, path) end
		end
		table.remove(path)
		state[c.name] = "done"
	end
	for _, c in self.list do visit(c, {}) end
	return out
end

-- Para el Diagnóstico: una fila por componente (getStatus), en orden de registro
function Registry:snapshot()
	local out = {}
	for _, c in self.list do table.insert(out, c:getStatus()) end
	return out
end

-- Cuántos hay en cada estado (para una línea de resumen)
function Registry:counts()
	local out = {}
	for _, c in self.list do out[c.state] = (out[c.state] or 0) + 1 end
	return out
end

-- Componentes cuya intención no coincide con su estado real (p. ej. pedido Running y está en Error)
function Registry:mismatches()
	local out = {}
	for _, c in self.list do
		local s = c:getStatus()
		if not s.matches then table.insert(out, s) end
	end
	return out
end

-- Al cerrar el hub: para y destruye todos (los últimos registrados primero), suelta recursos y cancela tareas.
-- Devuelve recursos soltados y la lista de lo que sobrevive (tareas vivas o recursos sin soltar: no debería haber).
function Registry:shutdown(reason)
	local released = 0
	for i = #self.list, 1, -1 do
		local c = self.list[i]
		released += #c.resources
		c:destroy(reason)
	end
	local survivors = {}
	for _, c in self.list do
		if c:taskCount() > 0 or #c.resources > 0 then table.insert(survivors, c.name) end
	end
	return released, survivors
end

return Components
end
__modules["Config"] = function(...)
-- Config: carga, validación y migraciones de ElHoyoHub.json y de los perfiles de la librería.
-- Sin Roblox: el acceso a archivos y JSON se inyecta (fs, json) para poder probarlo con datos simulados.
--   fs = { read(path) -> texto|nil, write(path, texto), list(dir) -> {rutas}, exists(path) -> bool }
--   json = { decode(texto) -> valor (puede lanzar error), encode(valor) -> texto }
local Config = {}

Config.VERSION = 3 -- configVersion actual. Historial en Config.MIGRATIONS.

-- Esquema central (1.4.1): una entrada por ajuste de ElHoyoHub.json. De aquí salen los tipos, los valores de serie,
-- los rangos y qué es secreto. Los valores de serie son los MISMOS que antes usaba src/main.lua (`config.x or N`).
--   id: clave estable · type · default · range {min, max} (los números fuera se RECORTAN, como hacía main) ·
--   integer · options (valores válidos) · category · persist ("config" = ElHoyoHub.json; nunca van en perfiles de la
--   librería) · sensitive (no sale en exportaciones ni diagnósticos) · since (versión en que apareció) ·
--   migration (número de Config.MIGRATIONS que la toca, si alguna)
-- Las claves que no están aquí (de versiones futuras o pasadas) se conservan tal cual: no se borra nada.
local HUB_URL = "https://raw.githubusercontent.com/saulandujar/elhoyohub/refs/heads/main/ElHoyoHub.lua"
Config.SCHEMA = {
	{ id = "configVersion", type = "number", default = nil, category = "hub", since = "1.3.1" },
	{ id = "profiles", type = "table", default = {}, category = "hub", since = "1.1.0" },
	{ id = "lang", type = "string", default = "es", options = { "es", "en" }, category = "interface", since = "1.0.0" },
	{ id = "palette", type = "string", default = "Abismo", category = "interface", since = "1.1.0" },
	{ id = "key", type = "string", default = "RightShift", category = "interface", since = "1.0.0" },
	{ id = "notify", type = "boolean", default = true, category = "interface", since = "1.1.0" },
	{ id = "scale", type = "number", default = 1, range = { 0.5, 2 }, category = "interface", since = "1.1.0" },
	{ id = "hubUrl", type = "string", default = HUB_URL, category = "hub", since = "1.2.0" },
	{ id = "autoExec", type = "boolean", default = false, category = "hub", since = "1.2.0" },
	{ id = "webhook", type = "string", default = nil, category = "discord", sensitive = true, since = "1.3.0", migration = 2 },
	{ id = "chestSpeed", type = "number", default = 2, range = { 1, 3 }, integer = true, category = "automation", since = "1.2.0" },
	{ id = "fishSpot", type = "table", default = nil, category = "automation", since = "1.2.0" },
	{ id = "juiceFruits", type = "table", default = {}, category = "automation", since = "1.3.0" },
	{ id = "questGiver", type = "number", default = 4, range = { 1, 14 }, integer = true, category = "quests", since = "1.2.0" },
	{ id = "fruitMin", type = "number", default = 1, range = { 1, 4 }, integer = true, category = "fruits", since = "1.2.0" },
	{ id = "fruitSel", type = "table", default = {}, category = "fruits", since = "1.2.0" },
	{ id = "sellRarities", type = "table", default = nil, category = "fruits", since = "1.3.0" },
	{ id = "boxRarities", type = "table", default = nil, category = "fruits", since = "1.3.0" },
	{ id = "avoidRadius", type = "number", default = 60, options = { 30, 60, 100, 200 }, category = "protection", since = "1.3.0" },
	{ id = "escapeAt", type = "number", default = 2, range = { 1, 10 }, integer = true, category = "protection", since = "1.3.0" },
	{ id = "flySpeed", type = "number", default = 2, range = { 1, 10 }, integer = true, category = "movement", since = "1.2.0" },
	{ id = "walkSpeed", type = "number", default = 2, range = { 1, 10 }, integer = true, category = "movement", since = "1.2.0" },
	{ id = "jumpMult", type = "number", default = 2, range = { 1, 10 }, integer = true, category = "movement", since = "1.2.0" },
	{ id = "bossMode", type = "number", default = 1, range = { 1, 10 }, integer = true, category = "bosses", since = "1.3.0" },
	{ id = "bossPick", type = "number", default = 1, range = { 1, 50 }, integer = true, category = "bosses", since = "1.3.0" },
	{ id = "bossWeapon", type = "number", default = 1, range = { 1, 10 }, integer = true, category = "bosses", since = "1.3.0" },
	{ id = "bossKeys", type = "string", default = "Z X C V", category = "bosses", since = "1.3.0" },
	-- 1.5.0: favoritos (ids estables de controles) y tecla del buscador global (con Ctrl)
	{ id = "favorites", type = "table", default = {}, category = "interface", since = "1.5.0" },
	{ id = "searchKey", type = "string", default = "K", category = "interface", since = "1.5.0" },
	-- 1.5.1: Bounty (NPCs). Índices de las listas de src/modules/NpcFarm.lua; el punto, { x, y, z }
	{ id = "bountyPoint", type = "table", default = nil, category = "bounty", since = "1.5.1" },
	{ id = "bountySkills", type = "table", default = { true, true, true, true }, category = "bounty", since = "1.5.1" },
	{ id = "bountyInterval", type = "number", default = 2, range = { 1, 4 }, integer = true, category = "bounty", since = "1.5.1" },
	{ id = "bountyRadius", type = "number", default = 2, range = { 1, 4 }, integer = true, category = "bounty", since = "1.5.1" },
	{ id = "bountyLow", type = "number", default = 2, range = { 1, 3 }, integer = true, category = "bounty", since = "1.5.1" },
	{ id = "bountyRecover", type = "number", default = 2, range = { 1, 3 }, integer = true, category = "bounty", since = "1.5.1" },
	-- 1.5.3: de dónde se lee la vida (Huida y Bounty)
	{ id = "healthSource", type = "string", default = "auto", options = { "auto", "humanoid", "attribute" }, category = "protection", since = "1.5.3" },
}
Config.BY_ID = {}
Config.TYPES = {} -- compatibilidad con 1.3.2: tipo de cada clave
for _, s in Config.SCHEMA do
	Config.BY_ID[s.id] = s
	Config.TYPES[s.id] = s.type
end

local function copy(v)
	if type(v) ~= "table" then return v end
	local out = {}
	for k, x in v do out[k] = copy(x) end
	return out
end

-- Valores de serie del esquema (copias: nadie comparte tablas) con `overrides` encima
function Config.defaults(overrides)
	local out = {}
	for _, s in Config.SCHEMA do
		if s.default ~= nil then out[s.id] = copy(s.default) end
	end
	for k, v in overrides or {} do out[k] = v end
	return out
end

-- Comprueba un valor contra su entrada del esquema. Devuelve ok, valor (quizá recortado), motivo.
-- Clave desconocida = válida tal cual (compatibilidad).
function Config.check(id, value)
	local s = Config.BY_ID[id]
	if not s then return true, value end
	if type(value) ~= s.type then return false, nil, "tipo " .. type(value) .. " (se esperaba " .. s.type .. ")" end
	if s.type == "number" then
		if value ~= value then return false, nil, "no es un número" end
		if s.integer then value = math.floor(value + 0.5) end
		if s.range then value = math.clamp(value, s.range[1], s.range[2]) end
	end
	if s.options and table.find(s.options, value) == nil then return false, nil, "valor no permitido: " .. tostring(value) end
	return true, value
end

-- Copia de la config sin lo sensible (para exportar o diagnosticar)
function Config.public(config)
	local out = {}
	for k, v in config do
		local s = Config.BY_ID[k]
		if not (s and s.sensitive) and k ~= "profiles" then out[k] = copy(v) end
	end
	return out
end

-- Resumen del esquema por categoría (Diagnóstico)
function Config.summary(config)
	local out = { total = #Config.SCHEMA, custom = 0, unknown = 0, byCategory = {} }
	for _, s in Config.SCHEMA do
		out.byCategory[s.category] = (out.byCategory[s.category] or 0) + 1
		if config and config[s.id] ~= nil and s.default ~= nil and type(s.default) ~= "table" and config[s.id] ~= s.default then
			out.custom += 1
		end
	end
	for k in config or {} do if not Config.BY_ID[k] then out.unknown += 1 end end
	return out
end

-- Patrón de URL de webhook de Discord (cualquier subdominio de discord(app).com). Sirve para tapar secretos.
local WEBHOOK_ANY = "https://[%w%.%-]*discord[%w%.%-]*%.com/api/webhooks/[%w/_%-]+"

-- Quita secretos de un texto cualquiera (copias de seguridad, informes)
function Config.redactSecrets(text)
	return (tostring(text):gsub(WEBHOOK_ANY, "[webhook oculto]"))
end

-- Lee path con los valores de `defaults`. Devuelve config, notas ({es, en}), estado.
-- estado = { file = "missing"|"ok"|"corrupt", ignored = {claves} }
function Config.load(fs, json, path, defaults)
	local config, notes, state = {}, {}, { file = "missing", ignored = {} }
	for k, v in defaults do config[k] = v end
	local ok, text = pcall(fs.read, path)
	if not ok or type(text) ~= "string" then return config, notes, state end
	local decoded, data = pcall(json.decode, text)
	if not decoded or type(data) ~= "table" then
		state.file = "corrupt"
		-- copia del archivo roto antes de que el próximo guardado lo pise, SIN secretos (la URL del webhook)
		pcall(fs.write, path .. ".bak", Config.redactSecrets(text))
		table.insert(notes, { "ElHoyoHub.json estaba dañado: se usan los ajustes de serie (copia sin secretos en ElHoyoHub.json.bak)",
			"ElHoyoHub.json was damaged: using default settings (copy without secrets in ElHoyoHub.json.bak)" })
		return config, notes, state
	end
	state.file = "ok"
	state.clamped = {}
	for k, v in data do
		local ok, value, why = false, nil, "clave no válida"
		if type(k) == "string" then ok, value, why = Config.check(k, v) end
		if ok then
			if value ~= v then table.insert(state.clamped, k) end -- recortado al rango (lo mismo que hacía main)
			config[k] = value
		else
			table.insert(state.ignored, tostring(k))
			table.insert(notes, { "Ajuste ignorado (" .. tostring(why) .. "): " .. tostring(k), "Setting ignored (invalid value): " .. tostring(k) })
		end
	end
	return config, notes, state
end

-- Rutas de controles de perfiles: las de la librería, "Pestaña/Caja/Nombre" en inglés.
-- Regla (CLAUDE.md > Conservación funcional): una migración NUNCA borra interruptores ni ajustes de funciones
-- que siguen existiendo; solo secretos y datos de controles que de verdad se quitaron (con permiso del usuario).

local function isSecretValue(id, value)
	if type(value) ~= "string" then return false end
	return value:find("/api/webhooks/", 1, true) ~= nil or (type(id) == "string" and id:sub(-8) == "/Webhook")
end

-- Reescribe cada perfil (y la papelera) con `edit(values) -> cambió?`. Devuelve cuántos archivos cambió.
local function editProfiles(fs, json, dirs, edit)
	local changed = 0
	for _, dir in dirs do
		local okList, files = pcall(fs.list, dir)
		for _, file in okList and files or {} do
			local okRead, data = pcall(function() return json.decode(fs.read(file)) end)
			if okRead and type(data) == "table" and type(data.values) == "table" and edit(data.values) then
				changed += 1
				pcall(fs.write, file, json.encode(data))
			end
		end
	end
	return changed
end

-- Migraciones en orden. Cada una lleva de la versión n-1 a la n y debe poder repetirse sin daño.
Config.MIGRATIONS = {
	-- 2 (1.3.1): las URLs de webhook salen de los perfiles. Solo secretos: los demás textos se quedan.
	[2] = function(ctx)
		local n = editProfiles(ctx.fs, ctx.json, ctx.profileDirs, function(values)
			local changed = false
			for id, value in values do
				if isSecretValue(id, value) then
					values[id] = nil
					changed = true
				end
			end
			return changed
		end)
		if n > 0 then table.insert(ctx.notes, { "Perfiles sin URLs de webhook: " .. n, "Presets without webhook URLs: " .. n }) end
	end,
	-- 3 (1.3.2): la copia .bak de un ElHoyoHub.json roto (1.3.1 la guardaba tal cual) pierde las URLs de webhook.
	[3] = function(ctx)
		local bak = ctx.path .. ".bak"
		local okBak, text = pcall(ctx.fs.read, bak)
		if okBak and type(text) == "string" then
			local clean = Config.redactSecrets(text)
			if clean ~= text then pcall(ctx.fs.write, bak, clean) end
		end
	end,
}

-- Lleva config de su configVersion a Config.VERSION. Devuelve las versiones aplicadas.
-- ctx = { fs, json, path, profileDirs, config, notes }
function Config.migrate(ctx)
	local from = tonumber(ctx.config.configVersion) or 1
	local applied = {}
	for v = from + 1, Config.VERSION do
		local step = Config.MIGRATIONS[v]
		if step then
			local ok, err = pcall(step, ctx)
			if not ok then
				table.insert(ctx.notes, { "Migración " .. v .. " fallida: " .. tostring(err), "Migration " .. v .. " failed: " .. tostring(err) })
				return applied -- se para: la siguiente vez se reintenta desde aquí
			end
		end
		ctx.config.configVersion = v
		table.insert(applied, v)
	end
	return applied
end

return Config
end
__modules["Webhook"] = function(...)
-- Webhook: avisos a Discord. Sin Roblox: request, json, reloj y spawn se inyectan.
-- La URL es un secreto (quien la tenga escribe en el canal): no mostrarla entera ni escribirla en la consola.
local Webhook = {}

local HOSTS = { ["discord.com"] = true, ["discordapp.com"] = true, ["ptb.discord.com"] = true, ["canary.discord.com"] = true }

function Webhook.valid(url)
	if type(url) ~= "string" then return false end
	local host = url:match("^https://([%w%.]+)/api/webhooks/%d+/[%w_%-]+$")
	return HOSTS[host] == true
end

-- Para mostrarla: solo los 4 últimos caracteres
function Webhook.mask(url)
	return Webhook.valid(url) and ("…" .. url:sub(-4)) or ""
end

-- deps = { request, json = {encode}, clock, spawn, getUrl() -> url, T(es, en), onFail(texto) }
function Webhook.new(deps)
	local self = { perMinute = deps.perMinute or 20, sent = {}, warned = -math.huge }
	local T = deps.T or function(es) return es end

	-- done(ok, motivo) opcional (botón de prueba). Sin done, un fallo se avisa con onFail como mucho 1 vez/min.
	function self.send(text, done)
		local url = deps.getUrl()
		local function finish(ok, why)
			if done then
				done(ok, why)
			elseif not ok and deps.onFail and deps.clock() - self.warned > 60 then
				self.warned = deps.clock()
				deps.onFail(why)
			end
		end
		if not deps.request then return finish(false, T("tu executor no permite peticiones HTTP", "your executor can't make HTTP requests")) end
		if not Webhook.valid(url) then return finish(false, T("no hay una URL de webhook de Discord válida", "no valid Discord webhook URL")) end
		local now = deps.clock()
		while self.sent[1] and now - self.sent[1] > 60 do table.remove(self.sent, 1) end
		if #self.sent >= self.perMinute then return finish(false, T("demasiados avisos seguidos, se descartan", "too many alerts in a row, dropped")) end
		table.insert(self.sent, now)
		deps.spawn(function()
			local ok, res = pcall(deps.request, {
				Url = url, Method = "POST", Headers = { ["Content-Type"] = "application/json" },
				Body = deps.json.encode({
					content = "**El Hoyo Hub** · " .. tostring(text):sub(1, 1800),
					allowed_mentions = { parse = {} }, -- nadie recibe menciones (@everyone, @here, roles)
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
	return self
end

return Webhook
end
__modules["Tokens"] = function(...)
-- Tokens: el sistema de diseño de El Hoyo UI en un solo sitio (1.5.0). Solo datos (sin Roblox): colores en
-- hexadecimal (la librería los convierte con Color3.fromHex), tipografía, espaciado, radios, opacidades, duraciones
-- y colores de estado. Un componente nuevo debe sacar de aquí sus valores en vez de escribir números sueltos.
-- Reglas de la identidad (ver ARCHITECTURE.md > Sistema de diseño): fondos muy oscuros por capas (Top/Body < Side <
-- Group < Frame), un único acento carmesí #E11D48, bordes de 1 px discretos, radios pequeños (4–8; 14 solo la
-- ventana), texto 12 px (11 títulos de grupo, 13 títulos de sección), animaciones cortas que no bloquean.
local Tokens = {}

Tokens.ACCENT = "#E11D48" -- carmesí del logo

-- Paletas: { [nombre] = "#RRGGBB" | { "#RRGGBB", opacidad } }. Abismo es la de serie y el respaldo de las demás.
Tokens.palettes = {
	Abismo = {
		Text = "#ECECF4", Disabled = "#808096", Soft = "#BEBECE", Border = "#24202D", PopupBorder = "#342E40",
		FrameInactive = "#1A1822", FrameActive = "#3A1222", TabActive = "#2A1520", Button = "#1C1A24",
		ButtonHovered = "#121118", ButtonActive = "#16141D", Side = "#0F0E15", Top = "#0B0A10", Body = "#0B0A10",
		Group = "#131219", Popup = "#13121A", FieldBg = "#1C1A24", SwitchOff = "#1E1B26", SwitchRim = { "#FFFFFF", 0.07 },
		KnobOff = "#8C889C", Divider = { "#FFFFFF", 0.118 }, LabelOff = "#9694A2", LabelOn = "#FFFFFF",
		Separator = "#1E1C27", Ink = "#FFFFFF", SwatchLine = { "#FFFFFF", 0.08 },
		-- estados (1.5.0)
		Success = "#22C55E", Warning = "#F59E0B", Danger = "#EF4444", Info = "#60A5FA", Muted = "#5B5A6E",
	},
	Light = {
		Text = "#1C1E25", Disabled = "#767B87", Soft = "#4F535E", Border = "#DADDE4", PopupBorder = "#CCD0DA",
		FrameInactive = "#E3E6ED", FrameActive = "#D1DBF4", TabActive = "#D9DEEA", Button = "#E7E9EF",
		ButtonHovered = "#DDE0E7", ButtonActive = "#D4D7DF", Side = "#EAECF1", Top = "#F4F5F8", Body = "#F1F2F6",
		Group = "#FCFCFD", Popup = "#F6F7FA", FieldBg = "#E5E7EE", SwitchOff = "#CACED8", SwitchRim = { "#000000", 0.06 },
		KnobOff = "#FFFFFF", Divider = { "#000000", 0.1 }, LabelOff = "#767B87", LabelOn = "#1C1E25",
		Separator = "#DADDE4", Ink = "#1C1E25", SwatchLine = { "#000000", 0.12 },
		Success = "#16A34A", Warning = "#D97706", Danger = "#DC2626", Info = "#2563EB", Muted = "#9CA3AF",
	},
}

-- Tipografía (px)
Tokens.text = { caption = 11, body = 12, title = 13, heading = 14 }
-- Espaciado (px) y alturas de fila
Tokens.space = { xs = 2, sm = 4, md = 8, lg = 12, xl = 16, gutter = 10 }
Tokens.size = { row = 25, tab = 34, tabPill = 30, sideWidth = 150, header = 61, icon = 14 }
-- Radios (px): pequeños, sin esquinas exageradas
Tokens.radius = { control = 6, card = 8, popup = 10, window = 14 }
-- Opacidades de los estados interactivos (sobre el color de su capa)
Tokens.opacity = { idle = 0.5, hover = 0.8, pressed = 0.95, disabled = 0.35, activeFill = 1 }
-- Velocidades de animación (la librería usa Anim(valor, velocidad): más alto = más rápido)
Tokens.motion = { fast = 16, normal = 12, slow = 5, page = 2.8 }
-- Estado de un componente (Components) → token de color del punto de estado
Tokens.status = {
	Running = "Success", Waiting = "Warning", Paused = "Warning", Initializing = "Info", Ready = "Muted",
	Disabled = "Muted", Stopping = "Warning", Error = "Danger", Unavailable = "Muted",
}
-- Niveles de notificación → token de color
Tokens.notify = { info = "Info", success = "Success", warning = "Warning", error = "Danger" }

-- Resuelve un token de color de una paleta (con respaldo en Abismo). Devuelve hex y opacidad.
function Tokens.color(theme, name)
	local p = Tokens.palettes[theme] or Tokens.palettes.Abismo
	local v = p[name] or Tokens.palettes.Abismo[name]
	if type(v) == "table" then return v[1], v[2] end
	return v, 1
end

-- Comprueba que todas las paletas tienen los mismos nombres que Abismo y hex válidos. Devuelve problemas.
function Tokens.validate()
	local problems = {}
	local function hex(v) return type(v) == "string" and v:match("^#%x%x%x%x%x%x$") ~= nil end
	for theme, p in Tokens.palettes do
		for name in Tokens.palettes.Abismo do
			if p[name] == nil then table.insert(problems, theme .. ": falta " .. name) end
		end
		for name, v in p do
			local h, a = v, 1
			if type(v) == "table" then h, a = v[1], v[2] end
			if not hex(h) then table.insert(problems, theme .. "." .. name .. ": hex no válido") end
			if type(a) ~= "number" or a < 0 or a > 1 then table.insert(problems, theme .. "." .. name .. ": opacidad") end
		end
	end
	for state, token in Tokens.status do
		if Tokens.palettes.Abismo[token] == nil then table.insert(problems, "estado " .. state .. ": token " .. token) end
	end
	if not hex(Tokens.ACCENT) then table.insert(problems, "acento") end
	return problems
end

return Tokens
end
__modules["Layout"] = function(...)
-- Layout: matemáticas de colocación de El Hoyo UI (1.5.0), sin Roblox, para poder probarlas con Lune.
-- Coordenadas "lógicas" = las del Stage de la librería (píxeles de pantalla divididos por la escala).
-- * fitScale: la escala que pidió el usuario, salvo que la ventana no quepa: entonces la mayor que sí cabe.
-- * breakpoint / compact: tramo de resolución y si la barra lateral debe compactarse (grupos plegados).
-- * clampWindow: posición restaurada o arrastrada siempre visible (entera si cabe; si no, la cabecera).
-- * placePopup: listas desplegables debajo del control o, si no caben, encima; nunca fuera de la pantalla.
-- * sidebar / scrollTo: posiciones de la barra lateral con grupos plegados y desplazamiento.
local Layout = {}

Layout.BASE = { w = 800, h = 600 } -- tamaño de la ventana a escala 1
Layout.SCALE = { min = 0.5, max = 2, step = 0.05 }
Layout.MARGIN = 16
Layout.HEADER = 61 -- alto de la cabecera (lo mínimo que debe verse para poder arrastrar)
Layout.SIDE = { group = 12, groupLabel = 16.5, tab = 34, height = 470 }

local function size(v) return v.X or v.x or v[1], v.Y or v.y or v[2] end

-- Escala efectiva para un viewport (en píxeles reales). Devuelve escala, motivo ("user" | "fit").
function Layout.fitScale(view, userScale, margin)
	local vw, vh = size(view)
	margin = margin or Layout.MARGIN
	local want = math.clamp(tonumber(userScale) or 1, Layout.SCALE.min, Layout.SCALE.max)
	local fits = math.min((vw - 2 * margin) / Layout.BASE.w, (vh - 2 * margin) / Layout.BASE.h)
	if want <= fits then return want, "user" end
	local s = math.floor(fits / Layout.SCALE.step + 1e-9) * Layout.SCALE.step
	s = math.floor(s * 100 + 0.5) / 100 -- sin restos de coma flotante (1.7, no 1.7000000000000002)
	return math.clamp(s, Layout.SCALE.min, want), "fit"
end

-- Tramo de resolución (píxeles reales): "small" < 720 de alto o < 1100 de ancho; "hd" < 1080; "fhd" < 1440; "qhd"
function Layout.breakpoint(view)
	local vw, vh = size(view)
	if vh < 720 or vw < 1100 then return "small" end
	if vh < 1080 then return "hd" end
	if vh < 1440 then return "fhd" end
	return "qhd"
end

-- ¿Barra lateral compacta? Con poco alto lógico (la ventana ya va reducida) los grupos se pliegan salvo el activo.
function Layout.compact(view, scale)
	local _, vh = size(view)
	return vh / (scale or 1) < Layout.BASE.h + 2 * Layout.MARGIN or Layout.breakpoint(view) == "small"
end

-- Posición válida de la ventana (lógica). Si cabe entera, dentro con margen; si no, al menos la cabecera.
function Layout.clampWindow(pos, win, view, margin)
	local px, py = size(pos)
	local ww, wh = size(win)
	local vw, vh = size(view)
	margin = margin or 0
	local function axis(p, w, v, keep)
		if w + 2 * margin <= v then return math.clamp(p, margin, v - w - margin) end
		return math.clamp(p, keep - w, 0) -- más grande que la pantalla: que se vea su principio
	end
	local x = axis(px, ww, vw, math.min(ww, vw))
	local y = axis(py, wh, vh, math.min(wh, vh))
	-- nunca por encima del borde superior: la cabecera (para arrastrar) siempre a la vista
	y = math.max(y, math.min(0, vh - Layout.HEADER))
	return x, y
end

-- Lista desplegable de w×h para un control en (ax, ay) de alto ah. Debajo si cabe; si no encima; si tampoco, la
-- que más sitio tenga y recortada al alto disponible. Devuelve x, y, alto final, "below" | "above".
function Layout.placePopup(ax, ay, ah, w, h, view, margin)
	local vw, vh = size(view)
	margin = margin or 8
	local below = vh - margin - (ay + ah + 4)
	local above = ay - 4 - margin
	local x = math.clamp(ax, margin, math.max(margin, vw - w - margin))
	if h <= below then return x, ay + ah + 4, h, "below" end
	if h <= above then return x, ay - 4 - h, h, "above" end
	if below >= above then return x, ay + ah + 4, math.max(0, below), "below" end
	local hh = math.max(0, above)
	return x, ay - 4 - hh, hh, "above"
end

-- Barra lateral SIN scroll propio (1.5.3). Todo tiene que verse de un vistazo: las filas se encogen hasta MIN_TAB
-- y los grupos usan separaciones compactas. Si ni así cabe, modo acordeón: los títulos de TODOS los grupos siguen a
-- la vista y solo se despliega el grupo activo (nada queda inaccesible; Ctrl+K y Ctrl+RePág/AvPág también llevan).
Layout.SIDE.minTab = 22
Layout.SIDE.maxTab = 34
Layout.SIDE.specs = { { gap = 12, label = 16.5, minTab = 28 }, { gap = 6, label = 14, minTab = 22 } } -- holgado, compacto

-- Medidas para `tabs` secciones visibles y `groups` grupos en `height` px. Devuelve { tab, gap, label, fits }.
function Layout.sidebarFit(tabs, groups, height)
	height = height or Layout.SIDE.height
	for _, spec in Layout.SIDE.specs do
		local fixed = groups * spec.label + math.max(0, groups - 1) * spec.gap
		local tab = math.min(Layout.SIDE.maxTab, math.floor((height - fixed) / math.max(1, tabs)))
		if tab >= spec.minTab then return { tab = tab, gap = spec.gap, label = spec.label, fits = true } end
	end
	local last = Layout.SIDE.specs[#Layout.SIDE.specs]
	return { tab = Layout.SIDE.minTab, gap = last.gap, label = last.label, fits = false }
end

-- Barra lateral. items = { { kind = "group", key, collapsed } | { kind = "tab", group = key } } en orden.
-- active = clave del grupo de la sección activa (para el acordeón). Devuelve { y = { [i] = posición o nil si oculta },
-- total, metrics, accordion, hidden = { [clave] = true } }. Mismos cálculos que relayoutSide de la librería.
function Layout.sidebar(items, height, active)
	height = height or Layout.SIDE.height
	local groups, tabsIn = 0, {}
	for _, it in items do
		if it.kind == "group" then groups += 1; tabsIn[it.key] = 0
		elseif it.group then tabsIn[it.group] = (tabsIn[it.group] or 0) + 1 end
	end
	local function visibleTabs(hidden)
		local n = 0
		for _, it in items do
			if it.kind == "tab" and not (it.group and hidden[it.group]) then n += 1 end
		end
		return n
	end
	local hidden = {}
	for _, it in items do if it.kind == "group" and it.collapsed then hidden[it.key] = true end end
	local m = Layout.sidebarFit(visibleTabs(hidden), groups, height)
	local accordion = false
	if not m.fits then -- acordeón: solo el grupo activo desplegado
		accordion = true
		for _, it in items do if it.kind == "group" and it.key ~= active then hidden[it.key] = true end end
		m = Layout.sidebarFit(visibleTabs(hidden), groups, height)
	end
	local ys, y, first = {}, 0, true
	for i, it in items do
		if it.kind == "group" then
			if not first then y += m.gap end
			first = false
			ys[i] = y + 1
			y = math.floor(y + m.label)
		elseif not (it.group and hidden[it.group]) then
			ys[i] = y
			y += m.tab
		end
	end
	return { y = ys, total = y, metrics = m, accordion = accordion, hidden = hidden, maxScroll = 0 }
end

------------------------------------------------------------------ Cajas de una página (1.5.4)
-- Prueba real (1.5.3): había que desplazar DENTRO de cajas como Movilidad. Ahora cada caja mide lo que su contenido
-- (altura natural, nunca recortada) y las cajas se apilan en dos columnas, una debajo de otra con GAP px. Si todo
-- junto supera el alto de la página, hay UN solo scroll: el de la página entera.
Layout.PAGE = { w = 600, h = 509, gap = 8, columnGap = 8 }

-- Altura natural de una caja con n filas de control (la misma cuenta que TabMeta:layout: flow.y − spacing + padY +
-- cabecera 18, con flow.y = padY + n·(fila + spacing)). Solo para pruebas y estimaciones.
function Layout.boxNatural(n, rowH, spacing, padY)
	rowH, spacing, padY = rowH or 25, spacing or 8, padY or 8
	return padY + n * (rowH + spacing) - spacing + padY + 18
end

-- boxes = { { column = 1 | 2 | "auto", natural = alto, height = "auto" | número fijo } } en orden de creación.
-- "auto" va a la columna que esté más baja en ese momento (sin huecos grandes). Devuelve
-- { boxes = { { column, x, y, h } }, columns = { alto1, alto2 }, total, maxScroll }.
function Layout.stack(boxes, opts)
	opts = opts or {}
	local P = Layout.PAGE
	local gap, view = opts.gap or P.gap, opts.view or P.h
	local widths = opts.widths or { (P.w - P.columnGap) / 2, (P.w - P.columnGap) / 2 }
	local cursors, out = { 0, 0 }, {}
	for i, b in boxes do
		local col = b.column
		if col ~= 1 and col ~= 2 then col = cursors[2] < cursors[1] and 2 or 1 end
		local h = (type(b.height) == "number" and b.height > 0) and b.height or b.natural
		h = math.max(0, math.floor(h))
		local x = col == 1 and 0 or math.floor(widths[1] + P.columnGap)
		out[i] = { column = col, x = x, y = cursors[col], h = h }
		cursors[col] += h + gap
	end
	local total = math.max(0, math.max(cursors[1], cursors[2]) - gap)
	return { boxes = out, columns = { math.max(0, cursors[1] - gap), math.max(0, cursors[2] - gap) }, total = total,
		maxScroll = math.max(0, total - view) }
end

-- Scroll de la página: nuevo desplazamiento tras girar la rueda z (positivo = hacia arriba), siempre en [0, max]
function Layout.scrollBy(y, z, maxScroll, step)
	return math.clamp(y - z * (step or 60), 0, math.max(0, maxScroll))
end

-- Desplazamiento para que una fila (y, alto) se vea entera en una ventana de `height`
function Layout.scrollTo(rowY, rowH, scroll, height, maxScroll)
	local s = scroll
	if rowY < s then s = rowY end
	if rowY + rowH > s + height then s = rowY + rowH - height end
	return math.clamp(s, 0, math.max(0, maxScroll or s))
end

return Layout
end
__modules["Search"] = function(...)
-- Search: búsqueda global de El Hoyo UI (1.5.0), sin Roblox. Normaliza texto (mayúsculas, acentos, ñ), puntúa,
-- agrupa resultados por fuente y guarda un historial corto. La librería pinta; aquí no se ejecuta nada: un resultado
-- solo dice ADÓNDE ir (el que llama decide; la búsqueda nunca pulsa un control).
-- entrada = { label, group, path?, aliases?, tip?, key? }
local Search = {}

-- Grupos en el orden en que se muestran
Search.GROUPS = { "controls", "settings", "profiles", "catalog", "history" }
Search.PER_GROUP = 5
Search.LIMIT = 10
Search.HISTORY = 8

local FOLD = {
	[0xE1] = "a", [0xE0] = "a", [0xE4] = "a", [0xE2] = "a", [0xC1] = "a", [0xC0] = "a", [0xC4] = "a", [0xC2] = "a",
	[0xE9] = "e", [0xE8] = "e", [0xEB] = "e", [0xEA] = "e", [0xC9] = "e", [0xC8] = "e", [0xCB] = "e", [0xCA] = "e",
	[0xED] = "i", [0xEC] = "i", [0xEF] = "i", [0xEE] = "i", [0xCD] = "i", [0xCC] = "i", [0xCF] = "i", [0xCE] = "i",
	[0x130] = "i", [0x131] = "i",
	[0xF3] = "o", [0xF2] = "o", [0xF6] = "o", [0xF4] = "o", [0xD3] = "o", [0xD2] = "o", [0xD6] = "o", [0xD4] = "o",
	[0xFA] = "u", [0xF9] = "u", [0xFC] = "u", [0xFB] = "u", [0xDA] = "u", [0xD9] = "u", [0xDC] = "u", [0xDB] = "u",
	[0xF1] = "n", [0xD1] = "n", [0xE7] = "c", [0xC7] = "c", [0x11E] = "g", [0x11F] = "g", [0x15E] = "s", [0x15F] = "s",
}

-- Caché del texto normalizado: los nombres de controles y entidades se repiten en cada pulsación (medido con
-- tools/bench.js). Tope de tamaño para que no crezca sin límite.
local foldCache, foldCount = {}, 0
Search.CACHE_MAX = 4000

-- Minúsculas y sin acentos, carácter a carácter (la posición en caracteres se conserva: sirve para resaltar)
function Search.fold(text)
	text = tostring(text or "")
	local hit = foldCache[text]
	if hit then return hit end
	local out = {}
	for _, code in utf8.codes(text) do
		if code >= 65 and code <= 90 then
			table.insert(out, string.char(code + 32))
		elseif FOLD[code] then
			table.insert(out, FOLD[code])
		elseif code >= 0x410 and code <= 0x42F then
			table.insert(out, utf8.char(code + 0x20))
		else
			table.insert(out, utf8.char(code))
		end
	end
	local folded = table.concat(out)
	foldCount += 1
	if foldCount > Search.CACHE_MAX then table.clear(foldCache); foldCount = 1 end
	foldCache[text] = folded
	return folded
end

-- Posición (en caracteres, desde 1) de q en text, sin mayúsculas ni acentos; nil si no está
function Search.find(text, q)
	local f, fq = Search.fold(text), Search.fold(q)
	if fq == "" then return nil end
	local at = string.find(f, fq, 1, true)
	return at and utf8.len(f, 1, at) or nil
end

local GROUP_ORDER = {}
for i, g in Search.GROUPS do GROUP_ORDER[g] = i end

-- Puntúa entradas para q. Devuelve hits { entry, at (posición en label o nil), field, score } agrupados en el orden
-- de GROUPS, como mucho PER_GROUP por grupo y LIMIT en total.
function Search.rank(entries, q, opts)
	opts = opts or {}
	local fq = Search.fold(q):match("^%s*(.-)%s*$")
	local hits = {}
	if fq == "" then return hits end
	for _, e in entries do
		local best, at, field = 0, nil, nil
		local label = Search.fold(e.label)
		local p = string.find(label, fq, 1, true)
		if p then
			best = (label == fq and 100) or (p == 1 and 80) or 60
			at, field = utf8.len(label, 1, p), "label"
		end
		if best < 50 then
			for _, a in e.aliases or {} do
				if string.find(Search.fold(a), fq, 1, true) then best, field = 50, "alias"; break end
			end
		end
		if best < 40 and e.path and string.find(Search.fold(e.path), fq, 1, true) then best, field = 40, "path" end
		if best < 30 and e.tip and string.find(Search.fold(e.tip), fq, 1, true) then best, field = 30, "tip" end
		if best > 0 then table.insert(hits, { entry = e, at = at, field = field, score = best }) end
	end
	table.sort(hits, function(a, b)
		local ga, gb = GROUP_ORDER[a.entry.group] or 99, GROUP_ORDER[b.entry.group] or 99
		if ga ~= gb then return ga < gb end
		if a.score ~= b.score then return a.score > b.score end
		return Search.fold(a.entry.label) < Search.fold(b.entry.label)
	end)
	local out, perGroup = {}, {}
	for _, h in hits do
		local g = h.entry.group or "?"
		perGroup[g] = (perGroup[g] or 0) + 1
		if perGroup[g] <= (opts.perGroup or Search.PER_GROUP) then table.insert(out, h) end
		if #out >= (opts.limit or Search.LIMIT) then break end
	end
	return out
end

-- Historial: lo último primero, sin repetidos (sin distinguir mayúsculas/acentos), como mucho HISTORY
function Search.remember(history, q)
	q = tostring(q or ""):match("^%s*(.-)%s*$")
	if #q < 2 then return history end
	local out, key = { q }, Search.fold(q)
	for _, h in history or {} do
		if type(h) == "string" and Search.fold(h) ~= key and #out < Search.HISTORY then table.insert(out, h) end
	end
	return out
end

-- Trozos de un texto para pintarlo resaltado: antes, coincidencia, después (posición y largo en caracteres)
function Search.split(text, at, len)
	text = tostring(text)
	if not at then return text, "", "" end
	local a = utf8.offset(text, at) or (#text + 1)
	local b = utf8.offset(text, at + len) or (#text + 1)
	return text:sub(1, a - 1), text:sub(a, b - 1), text:sub(b)
end

return Search
end
__modules["Notifications"] = function(...)
-- Notifications: niveles, duplicados e historial de las notificaciones de El Hoyo UI (1.5.0). Sin Roblox: la
-- librería pinta; aquí se decide si una notificación es nueva o repetida y se guarda el historial.
local Notifications = {}
Notifications.__index = Notifications

Notifications.LEVELS = { info = true, success = true, warning = true, error = true }
-- nombres que usa el hub en log() → nivel
local ALIAS = { ok = "success", warn = "warning", err = "error", ["error"] = "error", info = "info", success = "success", warning = "warning" }

function Notifications.level(name)
	return ALIAS[tostring(name or "info"):lower()] or "info"
end

-- opts = { clock, max (historial), window (s en los que un aviso igual cuenta como repetido) }
function Notifications.new(opts)
	opts = opts or {}
	return setmetatable({ list = {}, clock = opts.clock or os.clock, max = opts.max or 30, window = opts.window or 4,
		counts = { info = 0, success = 0, warning = 0, error = 0 } }, Notifications)
end

-- Apunta una notificación. Devuelve la entrada y si hay que MOSTRARLA (false = repetida hace poco: solo suma).
function Notifications:push(level, title, text)
	level = Notifications.level(level)
	title, text = tostring(title or ""), tostring(text or "")
	local now = self.clock()
	self.counts[level] += 1
	for i = #self.list, math.max(1, #self.list - 5), -1 do
		local e = self.list[i]
		if e.level == level and e.title == title and e.text == text and now - e.last <= self.window then
			e.count += 1
			e.last = now
			return e, false
		end
	end
	local e = { level = level, title = title, text = text, count = 1, first = now, last = now }
	table.insert(self.list, e)
	if #self.list > self.max then table.remove(self.list, 1) end
	return e, true
end

-- Historial, lo más reciente primero (opcional: solo un nivel)
function Notifications:history(limit, level)
	local out = {}
	for i = #self.list, 1, -1 do
		local e = self.list[i]
		if not level or e.level == level then table.insert(out, e) end
		if limit and #out >= limit then break end
	end
	return out
end

function Notifications:clear()
	table.clear(self.list)
end

-- Texto de una entrada para listas ("x3" si se repitió)
function Notifications.line(e, now)
	local ago = now and math.max(0, math.floor(now - e.last)) or nil
	return string.format("[%s]%s %s%s%s", e.level, e.count > 1 and (" x" .. e.count) or "", e.title ~= "" and (e.title .. ": ") or "",
		e.text, ago and string.format("  (hace %ds)", ago) or "")
end

return Notifications
end
__modules["ElHoyoUI"] = function(...)
--!nocheck
--[[
	El Hoyo UI — librería de interfaz de El Hoyo Hub.
	Basada en "Neverlose Reloaded UI" (recreación en Roblox de https://github.com/kdt255/Neverlose-Reloaded),
	modificada para El Hoyo Hub: paleta Abismo con acento rojo, logo y marca propios, perfil del jugador,
	español, sin widgets de relleno, y controles nuevos (Button, Label, Input).

	Uso:
		local UI = loadstring(source)()
		local Window = UI:CreateWindow({ Folder = "ElHoyoHub", ToggleKey = false })
		local Tab = Window:Tab({ Name = "Auto", Icon = "BOLT" })
		local Box = Tab:Box({ Name = "HAKI", Column = 1 })
		Box:Toggle({ Name = "Auto Buso", Callback = print })
		Box:Button({ Name = "Teleport", Callback = function() end })
		Box:Label("Texto informativo")      -- o Box:Label(function() return texto end, líneas): texto vivo, alto fijo
		Box:Input({ Name = "URL", Placeholder = "https://...", Callback = print })
		Window:Finish()
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Library, round, clamp, sat, FontMedium, FontSemi, Palettes, Accent, White, Black, T, A, applyPalette, tr, New, Box, Stroke, Shadow, setXY, setWH, Files, encodeJSON, decodeJSON, toHex, fromHex, safeName, Screen, Stage, StageScale, Probe, Scale, buildScreen, Widths, measure, preloadFonts, mouseAbs, toStage, inside, viewport, Scope
do -- bloque propio: sus locales no cuentan en el pico de registros (tools/wrap_block.js)
local HttpService = game:GetService("HttpService")

-- Version: nivel de API. ElHoyoHub.lua se niega a usar una librería más vieja que la que necesita (UI_MIN_VERSION).
-- 2 = v1.3.1 (Unload completo, escala limitada, ventana dentro de la pantalla).
Library = { Version = 5, Language = 1, Theme = "Abismo", ThemeNames = { "Abismo", "Light" } } -- 1 = español

-- (1.5.0) sin alias locales de math: math.floor etc. compilan igual (GETIMPORT) y no gastan registros
function round(x) return math.floor(x + 0.5) end
function clamp(x, a, b) return (x < a and a) or (x > b and b) or x end
function sat(x) return clamp(x, 0, 1) end

local FONT_ID = "rbxassetid://12187365364" -- Inter
FontMedium = Font.new(FONT_ID, Enum.FontWeight.Medium)
FontSemi = Font.new(FONT_ID, Enum.FontWeight.SemiBold)

--[[ ---------------------------------------- Theme ---------------------------------------- ]]

-- Colores: src/ui/Tokens.lua (sistema de diseño, 1.5.0). Aquí solo se pasan a Color3: { Color3, opacidad }.
local Tokens = import("Tokens")
Palettes = {}
for theme, p in Tokens.palettes do
	local out = {}
	for name, v in p do
		local hex, alpha = v, 1
		if type(v) == "table" then hex, alpha = v[1], v[2] end
		out[name] = { Color3.fromHex(hex), alpha }
	end
	Palettes[theme] = out
end
Library.Tokens = Tokens
Library.Layout = import("Layout") -- colocación y escala (1.5.0)
Library.Search = import("Search") -- búsqueda global (1.5.0)

Accent = Color3.fromHex(Tokens.ACCENT) -- rojo carmesí del logo
White, Black = Color3.new(1, 1, 1), Color3.new(0, 0, 0)
T, A = {}, {}

local Fallback = Palettes.Abismo -- a theme file may name only some colours; the rest come from here

function applyPalette()
	local palette = Palettes[Library.Theme] or Fallback
	for name, value in Fallback do
		local entry = palette[name] or value
		T[name], A[name] = entry[1], entry[2]
	end
	T.Title = T.Ink
end
applyPalette()

--[[ ---------------------------------------- Translations --------------------------------- ]]

local Translations = {
	["Search functions..."] = { "Buscar funciones..." },
	["No matching functions"] = { "No hay coincidencias" },
	["No results. Try another word."] = { "Sin resultados. Prueba otra palabra." },
	["Recent"] = { "Recientes" }, ["Catalog"] = { "Catálogo" }, ["Settings"] = { "Ajustes" },
	["Click to fold or unfold this group."] = { "Pulsa para plegar o desplegar este grupo." },
	["Functions"] = { "Funciones" },
	["Select"] = { "Elegir" },
	["Click to enable or disable this option."] = { "Pulsa para activar o desactivar esta opción." },
	["Open this section to adjust its settings."] = { "Abre esta sección para ajustarla." },
	["Select one item from the list."] = { "Elige una opción de la lista." },
	["Select one or more items. Click a selected item again to remove it."] = { "Elige una o varias. Pulsa otra vez una elegida para quitarla." },
	["Click the swatch to edit the color."] = { "Pulsa la muestra para cambiar el color." },
	["Click the swatch to edit the colors."] = { "Pulsa la muestra para cambiar los colores." },
	["Language"] = { "Idioma" },
	["Menu Scale"] = { "Tamaño del menú" },
	["Style"] = { "Estilo" },
	["English"] = { "English" },
	["Spanish"] = { "Español" },
	["Abismo"] = { "Abismo" },
	["Light"] = { "Claro" },
	["Accent"] = { "Acento" },
	["Presets"] = { "Perfiles" },
	["Search"] = { "Buscar" },
	["Newest First"] = { "Más recientes" },
	["Recently Modified"] = { "Modificados hace poco" },
	["Alphabetical"] = { "Alfabético" },
	["Share"] = { "Compartir" },
	["Duplicate"] = { "Duplicar" },
	["Delete"] = { "Borrar" },
	["Bin is empty"] = { "La papelera está vacía" },
	["No presets found"] = { "No hay perfiles" },
	["Cloud"] = { "Nube" },
	["Config Created"] = { "Perfil creado" },
	["Config Saved"] = { "Perfil guardado" },
	["Config Loaded"] = { "Perfil cargado" },
	["Config Deleted"] = { "Perfil borrado" },
	["Config Renamed"] = { "Perfil renombrado" },
	["Config Restored"] = { "Perfil restaurado" },
	["Config Duplicated"] = { "Perfil duplicado" },
	["Config not loaded"] = { "Perfil no cargado" },
	["Delete forever?"] = { "¿Borrar para siempre?" },
	["Click again to delete %s forever"] = { "Vuelve a pulsar para borrar %s para siempre" },
	["Created new config"] = { "Nuevo perfil creado" },
	["Saved changes to %s"] = { "Cambios guardados en %s" },
	["Loaded config: %s"] = { "Perfil cargado: %s" },
	["Removed config: %s"] = { "Perfil borrado: %s" },
	["Uploaded %s to the cloud"] = { "%s subido a la nube" },
	["Downloaded %s"] = { "%s descargado" },
	["Copied a share link for %s"] = { "Enlace de %s copiado" },
	["Duplicated %s"] = { "%s duplicado" },
	["Restored %s"] = { "%s restaurado" },
	["Renamed %s to %s"] = { "%s renombrado a %s" },
	["Copied %s to the clipboard"] = { "%s copiado al portapapeles" },
	["Clipboard is not available"] = { "El portapapeles no está disponible" },
	["Default"] = { "Por defecto" },
	["Enabled"] = { "Activado" },
	["Disabled"] = { "Desactivado" },
	["Name"] = { "Nombre" },
}
Library.Translations = Translations -- El Hoyo Hub añade aquí sus propios textos

function tr(text)
	local row = Library.Language > 0 and Translations[text]
	return row and row[Library.Language] or text
end

--[[ ---------------------------------------- Instances ------------------------------------ ]]

function New(class, props, parent)
	local object = Instance.new(class)
	for key, value in props do object[key] = value end
	if parent then object.Parent = parent end
	return object
end

function Box(parent, x, y, w, h, color, radius)
	local frame = New("Frame", {
		Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, h), BorderSizePixel = 0,
		BackgroundColor3 = color or White, BackgroundTransparency = color and 0 or 1,
	}, parent)
	if radius then New("UICorner", { CornerRadius = UDim.new(0, radius) }, frame) end
	return frame
end

function Stroke(frame, color, thickness)
	return New("UIStroke", {
		Color = color or White, Thickness = thickness or 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, frame)
end

-- Not every client has UIShadow yet. Those that don't simply go without a shadow.
function Shadow(parent, blur, transparency, offsetY)
	local ok, shadow = pcall(function()
		return New("UIShadow", {
			BlurRadius = UDim.new(0, blur), Color = Black, Offset = UDim2.fromOffset(0, offsetY or 0), Transparency = transparency,
		}, parent)
	end)
	return ok and shadow or nil
end

function setXY(frame, x, y) frame.Position = UDim2.fromOffset(x, y) end
function setWH(frame, w, h) frame.Size = UDim2.fromOffset(w, h) end

--[[ ---------------------------------------- Files ----------------------------------------- ]]

local hasDisk = type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"
	and type(isfolder) == "function" and type(makefolder) == "function" and type(listfiles) == "function"

Files = { memory = {}, disk = hasDisk }

function Files.folder(path)
	if hasDisk then pcall(function() if not isfolder(path) then makefolder(path) end end) end
end

function Files.write(path, text)
	if not text then return end
	if hasDisk then pcall(writefile, path, text) else Files.memory[path] = text end
end

function Files.read(path)
	if not hasDisk then return Files.memory[path] end
	local ok, text = pcall(function() return isfile(path) and readfile(path) or nil end)
	return ok and text or nil
end

function Files.delete(path)
	if not hasDisk then
		Files.memory[path] = nil
	elseif type(delfile) == "function" then
		pcall(delfile, path)
	end
end

function Files.list(folder)
	local names = {}
	if hasDisk then
		local ok, paths = pcall(listfiles, folder)
		if ok then
			for _, path in paths do table.insert(names, string.match(path, "([^/\\]+)$")) end
		end
	else
		local prefix = folder .. "/"
		for path in Files.memory do
			if string.sub(path, 1, #prefix) == prefix then table.insert(names, string.sub(path, #prefix + 1)) end
		end
	end
	table.sort(names)
	return names
end

function encodeJSON(value)
	local ok, text = pcall(HttpService.JSONEncode, HttpService, value)
	return ok and text or nil
end

function decodeJSON(text)
	if not text then return nil end
	local ok, value = pcall(HttpService.JSONDecode, HttpService, text)
	return ok and value or nil
end

function toHex(color, alpha)
	local text = string.format("%02X%02X%02X", round(color.R * 255), round(color.G * 255), round(color.B * 255))
	if alpha and alpha < 1 then text ..= string.format("%02X", round(alpha * 255)) end
	return text
end

function fromHex(text)
	if type(text) ~= "string" then return nil end
	local digits = string.gsub(text, "[^%x]", "")
	if #digits ~= 6 and #digits ~= 8 then return nil end
	local function byte(i) return tonumber(string.sub(digits, i, i + 1), 16) end
	return Color3.fromRGB(byte(1), byte(3), byte(5)), #digits == 8 and byte(7) / 255 or 1
end

function safeName(name) return (string.gsub(name, '[\\/:*?"<>|]', "_")) end

--[[ ---------------------------------------- Screen ---------------------------------------- ]]

-- (declarada arriba) Screen, Stage, StageScale, Probe
Scale = 1
function buildScreen()
	if Screen then return end
	local parent = (gethui and gethui()) or game:GetService("CoreGui")
	local previous = parent:FindFirstChild("ElHoyoUI")
	if previous then previous:Destroy() end
	Screen = New("ScreenGui", {
		Name = "ElHoyoUI", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 50,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, parent)
	Stage = Box(Screen, 0, 0, 0, 0)
	Stage.Size = UDim2.fromScale(1, 1)
	StageScale = New("UIScale", { Scale = 1 }, Stage)
	Probe = New("TextLabel", {
		Text = "", BackgroundTransparency = 1, TextTransparency = 1, Size = UDim2.fromOffset(1000, 40),
		Position = UDim2.fromOffset(-2000, -2000), FontFace = FontMedium, TextSize = 12,
	}, Screen)
end

Widths = {}
function measure(text, size, font)
	local key = (font == FontSemi and "S" or "M") .. size .. text
	local cached = Widths[key]
	if cached then return cached end
	Probe.FontFace, Probe.TextSize, Probe.Text = font or FontMedium, size, text
	local width = Probe.TextBounds.X
	if width > 0 then Widths[key] = width end
	return width
end

-- Inter is a cloud font, so everything measured must wait until it has arrived.
function preloadFonts()
	local ok, service = pcall(game.GetService, game, "TextService")
	if not ok or not service then return end
	for _, font in { FontMedium, FontSemi } do
		pcall(function()
			local params = Instance.new("GetTextBoundsParams")
			params.Text, params.Font, params.Size, params.Width = "Neverlose", font, 12, 500
			service:GetTextBoundsAsync(params)
		end)
	end
end

-- Mouse in the same space as AbsolutePosition.
function mouseAbs() return UserInputService:GetMouseLocation() + Screen.AbsolutePosition end
function toStage(point) return (point - Stage.AbsolutePosition) / Scale end
function inside(gui, p)
	local a, s = gui.AbsolutePosition, gui.AbsoluteSize
	return p.X >= a.X and p.Y >= a.Y and p.X < a.X + s.X and p.Y < a.Y + s.Y
end
function viewport() return Stage.AbsoluteSize / Scale end

--[[ ---------------------------------------- Scopes ---------------------------------------- ]]
-- A scope owns painters (redrawn on theme, language and fades) and hit regions. Its effective
-- alpha is what a pushed ImGuiStyleVar_Alpha would have been.

Scope = {}
Scope.__index = Scope

end
local function newScope(parent)
	local scope = setmetatable({ parent = parent, own = 1, alpha = parent and parent.alpha or 1, painters = {}, items = {}, wheels = {}, kids = {}, inert = false }, Scope)
	if parent then table.insert(parent.kids, scope) end
	return scope
end

function Scope:paint(fn)
	table.insert(self.painters, fn)
	fn()
	return fn
end

function Scope:refresh()
	self.alpha = self.own * (self.parent and self.parent.alpha or 1)
	for _, fn in self.painters do fn() end
	for _, kid in self.kids do kid:refresh() end
end

function Scope:setAlpha(alpha)
	if self.own ~= alpha then
		self.own = alpha
		self:refresh()
	end
end

local Root = newScope(nil)

--[[ ---------------------------------------- Animation ------------------------------------- ]]

local Moving, Queue, Stepping, Tickers, Anim, Run, stepAnimations, Popups, Windows, Hover, Held, Dragging, Tip, ShowTip, HideTip, Hit, Wheel, pick, targetAt, updatePointer, closePopupsTo, onPress, onRelease
do -- bloque propio: sus locales no cuentan en el pico de registros (tools/wrap_block.js)
Moving, Queue, Stepping = {}, {}, false
Tickers = {}

function Anim(value, speed, callback, epsilon)
	return setmetatable({ v = value, t = value, speed = speed or 15, cb = callback, eps = epsilon or 0.002 }, { __index = {
		to = function(self, target, newSpeed)
			if newSpeed then self.speed = newSpeed end
			self.t = target
			if self.v ~= target then
				if Stepping then Queue[self] = true else Moving[self] = true end
			end
		end,
		set = function(self, value2)
			self.v, self.t = value2, value2
			Moving[self], Queue[self] = nil, nil
			if self.cb then self.cb(value2) end
		end,
	} })
end

function Run(fn) Tickers[fn] = true end

function stepAnimations(dt)
	dt = math.min(dt, 0.05)
	Stepping = true
	for anim in Moving do
		anim.v += (anim.t - anim.v) * (1 - math.exp(-anim.speed * dt))
		if math.abs(anim.t - anim.v) < anim.eps then
			anim.v = anim.t
			Moving[anim] = nil
		end
		if anim.cb then anim.cb(anim.v) end
	end
	for fn in Tickers do
		if fn(dt) == false then Tickers[fn] = nil end
	end
	Stepping = false
	for anim in Queue do Moving[anim] = true end
	table.clear(Queue)
end

--[[ ---------------------------------------- Input ----------------------------------------- ]]
-- ImGui's rules, not Roblox's: the top popup owns the pointer, a press outside only closes,
-- the held widget keeps the pointer, and the first widget submitted wins an overlap.

Popups, Windows = {}, {}
Hover, Held, Dragging = nil, nil, nil
Tip = { item = nil, time = 0 }
-- (declarada arriba) ShowTip, HideTip

function Hit(scope, gui, handlers)
	handlers.gui = gui
	table.insert(scope.items, handlers)
	return handlers
end

function Wheel(scope, gui, fn)
	table.insert(scope.wheels, { gui = gui, fn = fn })
end

function pick(scope, p, field)
	if scope.inert or (scope.clip and not inside(scope.clip, p)) then return nil end
	for i = #scope.kids, 1, -1 do
		local found = pick(scope.kids[i], p, field)
		if found then return found end
	end
	for _, item in scope[field] do
		if item.gui.Visible ~= false and not item.off and inside(item.gui, p) then return item end
	end
	return nil
end

function targetAt(p, field)
	if #Popups > 0 then
		local top = Popups[#Popups]
		return inside(top.frame, p) and pick(top.scope, p, field) or nil
	end
	for i = #Windows, 1, -1 do
		local window = Windows[i]
		if window.frame.Visible and inside(window.frame, p) then return pick(window.scope, p, field) end
	end
	return nil
end

local function setHover(item)
	if Hover == item then return end
	if Hover and Hover.hover then Hover.hover(false) end
	Hover = item
	if item and item.hover then item.hover(true) end
	Tip.item, Tip.time = item, 0
end

function updatePointer(dt)
	local p = mouseAbs()
	if Held then
		if Held.drag then Held.drag(p) end
	elseif not Dragging then
		setHover(targetAt(p, "items"))
	end
	if Dragging then Dragging(p) end
	local wants = Tip.item and Tip.item.tip and not Held and not Dragging
	if wants then
		Tip.time += dt
		if Tip.time > 0.5 then ShowTip(Tip.item) end
	else
		HideTip()
	end
end

-- (declarada arriba) closePopupsTo

local function beginDrag(owner, p)
	local grab = toStage(p) - owner.dragTarget
	Dragging = function(point) owner:dragTo(toStage(point) - grab) end
end

function onPress(p)
	if #Popups > 0 then
		local level = 0
		for i = #Popups, 1, -1 do
			if inside(Popups[i].frame, p) then level = i break end
		end
		if level < #Popups then
			closePopupsTo(level)
			return
		end
	end
	setHover(targetAt(p, "items"))
	if Hover then
		Held = Hover
		if Held.down then Held.down(p) end
		return
	end
	if #Popups > 0 then
		beginDrag(Popups[#Popups], p)
		return
	end
	for i = #Windows, 1, -1 do
		local window = Windows[i]
		if window.frame.Visible and inside(window.frame, p) then
			if window.dragTo then beginDrag(window, p) end
			return
		end
	end
end

function onRelease(p)
	Dragging = nil
	local item = Held
	Held = nil
	if item then
		if item.up then item.up(p) end
		if item.click and inside(item.gui, p) then item.click(p) end
	end
end
end

local Connected = false
local Connections = {}

local function connect(signal, fn)
	local connection = signal:Connect(fn)
	table.insert(Connections, connection)
	return connection
end

local function connectInput()
	if Connected then return end
	Connected = true
	connect(UserInputService.InputBegan, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			onPress(mouseAbs())
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			local p = mouseAbs()
			local item = targetAt(p, "items")
			if item and item.right then item.right(p) end
		end
	end)
	connect(UserInputService.InputEnded, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then onRelease(mouseAbs()) end
	end)
	connect(UserInputService.InputChanged, function(input)
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			local target = targetAt(mouseAbs(), "wheels")
			if target then target.fn(input.Position.Z) end
		end
	end)
	connect(RunService.RenderStepped, function(dt)
		stepAnimations(dt)
		updatePointer(dt)
	end)
end

--[[ ---------------------------------------- Icons ----------------------------------------- ]]
-- Outlines from the original's icon font, 512 units to the em with y running down from the top
-- of the em. They are rasterised with exact coverage to whatever size the widget asks for, then
-- drawn as runs of 1px frames, which is what a baked font atlas amounts to.

local glyphContours, Shapes, LazyRoots, ShapeMeta
do -- bloque propio: sus locales no cuentan en el pico de registros (tools/wrap_block.js)
local GlyphData = {
	CROSSHAIRS = {512,"500,224,509,227,512,236,512,276,509,285,500,288,470,288,449,353,408,408,353,449,288,470,288,500,285,509,276,512,236,512,227,509,224,500,224,470,159,449,104,408,63,353,42,288,12,288,3,285,0,276,0,236,3,227,12,224,42,224,63,159,104,104,159,63,224,42,224,12,227,3,236,0,276,0,285,3,288,12,288,42,353,63,408,104,449,159,470,224;288,405,329,390,364,364,390,329,405,288,364,288,355,285,352,276,352,236,355,227,364,224,405,224,390,183,364,148,329,122,288,107,288,148,285,157,276,160,236,160,227,157,224,148,224,107,183,122,148,148,122,183,107,224,148,224,157,227,160,236,160,276,157,285,148,288,107,288,122,329,148,364,183,390,224,405,224,364,227,355,236,352,276,352,285,355,288,364;278,234,288,256,278,278,256,288,234,278,224,256,234,234,256,224"},
	MOUSE = {384,"0,352,0,224,384,224,384,352,379,394,363,432,337,465,304,491,266,507,224,512,160,512,118,507,80,491,47,465,21,432,5,394;176,0,176,192,0,192,0,160,5,118,21,80,47,47,80,21,118,5,160,0;224,0,266,5,304,21,337,47,363,80,379,118,384,160,384,192,208,192,208,0"},
	IMAGE = {512,"464,448,48,448,30,444,14,434,4,418,0,400,0,112,4,94,14,78,30,68,48,64,464,64,482,68,498,78,508,94,512,112,512,400,508,418,498,434,482,444;152,136,133,124,112,120,91,124,72,136,60,155,56,176,60,197,72,216,91,228,112,232,133,228,152,216,164,197,168,176,164,155;64,384,448,384,448,272,360,184,344,184,208,320,152,264,136,264,64,336"},
	USER = {448,"314,218,273,247,224,256,175,247,134,218,105,177,96,128,105,79,134,38,175,9,224,0,273,9,314,38,343,79,352,128,343,177;314,288,365,298,408,328,438,371,448,422,448,464,444,482,434,498,418,508,400,512,48,512,30,508,14,498,4,482,0,464,0,422,10,371,40,328,83,298,134,288,151,288,187,300,224,304,261,300,297,288"},
	GLOBE = {496,"336,160,160,160,174,98,195,50,220,18,248,8,276,18,301,50,322,98;155,192,341,192,344,256,341,320,155,320,152,256;477,160,369,160,349,78,319,18,369,39,414,72,450,112;177,18,146,78,127,160,19,160,46,112,82,72,127,39;487,192,496,256,487,320,373,320,376,256,373,192;120,256,123,320,9,320,0,256,9,192,123,192;160,352,336,352,322,414,301,462,276,494,248,504,220,494,195,462,174,414;319,494,350,434,369,352,477,352,450,400,414,440,369,473;19,352,127,352,147,434,177,494,127,473,82,440,46,400"},
	MAGIC = {512,"224,96,208,64,176,48,208,32,224,0,240,32,272,48,240,64;80,160,53,107,0,80,53,53,80,0,107,53,160,80,107,107;432,288,459,341,512,368,459,395,432,448,405,395,352,368,405,341;503,94,512,117,503,139,139,503,117,512,94,503,9,418,0,395,9,373,373,9,395,0,418,9;359,203,446,117,395,66,309,153"},
	SLIDERS_H = {512,"496,384,508,388,512,400,512,432,508,444,496,448,160,448,160,464,156,476,144,480,112,480,100,476,96,464,96,448,16,448,4,444,0,432,0,400,4,388,16,384,96,384,96,368,100,356,112,352,144,352,156,356,160,368,160,384;496,224,508,228,512,240,512,272,508,284,496,288,416,288,416,304,412,316,400,320,368,320,356,316,352,304,352,288,16,288,4,284,0,272,0,240,4,228,16,224,352,224,352,208,356,196,368,192,400,192,412,196,416,208,416,224;496,64,508,68,512,80,512,112,508,124,496,128,288,128,288,144,284,156,272,160,240,160,228,156,224,144,224,128,16,128,4,124,0,112,0,80,4,68,16,64,224,64,224,48,228,36,240,32,272,32,284,36,288,48,288,64"},
	SAVE = {448,"434,130,444,146,448,164,448,432,444,450,434,466,418,476,400,480,48,480,30,476,14,466,4,450,0,432,0,80,4,62,14,46,30,36,48,32,316,32,334,36,350,46;178,398,199,411,224,416,249,411,270,398,283,377,288,352,283,327,270,306,249,293,224,288,199,293,178,306,165,327,160,352,165,377;320,111,316,103,313,100,305,96,76,96,67,99,64,108,64,212,67,221,76,224,308,224,317,221,320,212"},
	CHEVRON_DOWN = {448,"207,381,13,187,6,170,13,153,35,131,52,124,69,130,224,285,379,130,396,124,413,131,435,153,442,170,435,187,241,381,224,389"},
	CHEVRON_RIGHT = {320,"285,273,91,467,74,474,57,467,35,445,28,428,34,411,189,256,34,101,28,84,35,67,57,45,74,38,91,45,285,239,293,256"},
	SEARCH = {512,"505,443,512,460,505,477,477,505,460,512,443,505,343,405,336,388,336,372,276,405,208,416,153,409,104,389,61,355,27,312,7,263,0,208,7,153,27,104,61,61,104,27,153,7,208,0,263,7,312,27,355,61,389,104,409,153,416,208,405,276,372,336,388,336,405,343;118,298,159,327,208,336,257,327,298,298,327,257,336,208,327,159,298,118,257,89,208,80,159,89,118,118,89,159,80,208,89,257"},
	RUNNING = {416,"306,82,290,92,272,96,254,92,238,82,228,66,224,48,228,30,238,14,254,4,272,0,290,4,306,14,316,30,320,48,316,66;114,317,130,342,152,360,162,366,154,387,136,409,109,416,32,416,10,406,0,384,10,362,32,352,99,352;384,224,406,234,416,256,406,278,384,288,330,288,304,281,287,261,267,220,235,298,297,334,317,358,318,388,287,490,276,506,256,512,246,510,228,495,225,470,253,383,168,333,150,318,140,297,136,274,142,252,179,165,164,160,139,167,99,197,76,204,55,192,48,168,61,146,100,116,139,98,181,99,252,120,288,138,314,171,340,224"},
	AWARD = {384,"98,363,122,379,150,384,185,374,133,502,122,512,107,507,70,469,18,471,4,464,2,449,48,337,73,351,82,353,95,360;384,449,382,464,368,471,316,469,279,507,264,512,253,502,201,374,236,384,264,379,288,363,296,356,301,354,313,351,338,337;264,340,240,352,214,346,193,340,172,346,146,352,122,340,117,335,113,332,109,328,106,326,102,325,96,324,90,322,83,320,65,310,55,291,50,274,46,266,41,258,29,245,18,227,18,206,22,188,24,179,22,170,18,153,18,132,29,113,41,101,46,94,50,85,55,67,65,49,83,38,100,34,108,30,116,25,128,12,146,1,167,1,184,6,193,7,202,6,219,1,240,1,258,12,270,25,278,30,286,34,303,38,321,49,331,67,336,85,340,94,345,101,357,113,368,132,368,153,364,170,362,179,364,188,368,206,368,227,357,245,345,258,340,266,336,274,331,291,321,310,303,320,295,322,288,324,284,326,278,328,274,330,270,334;126,108,106,139,99,176,106,213,126,244,157,265,193,272,229,265,260,244,280,213,287,176,280,139,260,108,229,87,193,80,157,87"},
	WIND = {512,"157,256,192,262,222,280,245,306,255,339,252,380,232,416,200,440,160,448,127,442,98,426,77,401,66,370,69,358,82,352,114,352,124,354,130,362,141,378,160,384,174,381,184,372,192,347,180,328,158,320,16,320,4,316,0,304,0,272,4,260,16,256;16,224,4,220,0,208,0,176,4,164,16,160,350,160,372,152,384,133,376,108,366,99,352,96,333,102,322,118,316,126,306,128,274,128,261,122,258,110,272,75,298,48,334,34,373,34,398,44,420,60,436,82,446,107,446,150,426,188,393,215,352,224;400,256,449,266,488,298,510,343,509,395,498,423,478,448,453,467,424,477,383,479,345,466,314,440,295,405,297,390,310,384,344,384,358,392,376,410,400,416,418,412,434,402,444,386,448,368,444,350,434,334,418,324,400,320,284,320,268,285,244,256"},
	TINT = {352,"205,22,248,122,274,164,297,196,336,260,348,296,352,334,346,381,329,423,300,460,264,489,222,506,176,512,130,506,88,489,52,460,23,423,6,381,0,334,4,296,16,260,56,196,79,163,104,121,147,22,158,6,176,0,195,6;176,448,188,444,192,432,188,420,176,416,145,410,120,392,102,367,96,336,92,324,80,320,68,324,64,336,72,379,97,415,133,440"},
	BOLT = {320,"297,160,309,163,318,172,318,196,142,500,133,509,121,512,102,503,98,482,144,288,25,288,7,280,1,261,33,21,41,6,57,0,201,0,220,10,224,30,182,160"},
	CLOUD_SHOWERS = {512,"416,128,453,135,484,156,505,187,512,224,505,261,484,292,453,313,416,320,96,320,59,313,28,292,7,261,0,224,5,194,18,168,40,147,66,133,64,112,72,69,97,33,133,8,176,0,207,4,234,16,258,36,275,61,302,39,336,32,367,38,392,56,410,81,416,112,414,128;64,384,64,464,60,476,48,480,36,476,32,464,32,384,36,372,48,368,60,372;160,416,160,496,156,508,144,512,132,508,128,496,128,416,132,404,144,400,156,404;256,384,256,464,252,476,240,480,228,476,224,464,224,384,228,372,240,368,252,372;352,416,352,496,348,508,336,512,324,508,320,496,320,416,324,404,336,400,348,404;448,384,448,464,444,476,432,480,420,476,416,464,416,384,420,372,432,368,444,372"},
	SNOWFLAKE = {448,"441,345,448,354,447,366,431,393,422,401,410,399,377,379,383,405,382,416,373,424,358,428,346,426,339,417,320,346,257,310,257,388,310,441,315,452,310,464,299,475,288,480,277,475,257,456,257,496,252,508,241,512,209,512,198,508,193,496,193,456,173,475,162,480,151,475,139,464,134,452,139,442,193,388,193,310,130,346,111,417,104,426,92,428,77,424,68,417,66,405,73,379,40,399,28,401,19,393,3,366,0,354,9,345,43,326,17,319,7,312,6,300,10,285,16,276,29,274,99,293,163,256,99,219,29,238,16,236,10,227,6,212,7,200,17,193,43,186,9,167,0,158,3,146,19,119,28,111,40,113,73,133,67,107,68,96,77,88,92,84,104,86,111,95,130,166,193,202,193,124,139,71,135,60,139,48,151,37,162,31,173,37,193,56,193,16,198,4,209,0,241,0,252,4,257,16,257,56,277,37,288,32,299,37,311,48,315,60,311,71,257,124,257,202,320,166,339,95,346,86,358,84,373,88,382,96,383,107,377,133,410,113,422,111,431,119,447,146,449,158,441,167,407,186,433,193,443,200,444,212,440,227,434,236,421,238,351,219,287,256,351,293,421,274,434,276,440,285,444,300,443,312,433,319,407,326"},
	FONT = {448,"432,416,444,420,448,432,448,464,444,476,432,480,304,480,292,476,288,464,288,432,292,420,304,416,324,416,300,352,148,352,124,416,144,416,156,420,160,432,160,464,156,476,144,480,16,480,4,476,0,464,0,432,4,420,16,416,39,416,170,54,182,38,200,32,248,32,266,38,278,54,409,416;177,272,271,272,224,143"},
	FONT_CASE = {640,"230,86,351,427,352,432,348,444,336,448,285,448,276,445,270,437,251,384,101,384,82,437,76,445,67,448,16,448,4,444,0,432,1,427,122,86,134,70,152,64,200,64,218,70;130,304,222,304,176,175;624,160,636,164,640,176,640,432,636,444,624,448,592,448,580,444,576,432,576,430,544,444,512,448,463,439,422,410,393,369,384,320,384,288,393,239,422,198,463,169,512,160,544,164,576,178,576,176,580,164,592,160;560,320,560,288,556,270,546,254,530,244,512,240,494,244,478,254,468,270,464,288,464,320,468,338,478,354,494,364,512,368,530,364,546,354,556,338"},
	USER_CIRCLE = {496,"72,80,124,40,183,16,248,8,313,16,372,40,424,80,464,132,488,191,496,256,488,321,464,380,424,432,372,472,313,496,248,504,183,496,124,472,72,432,32,380,8,321,0,256,8,191,32,132;310,130,282,110,248,104,214,110,186,130,166,158,160,192,166,226,186,254,214,274,248,280,282,274,310,254,330,226,336,192,330,158;394,380,377,356,354,336,326,324,296,320,289,321,248,328,207,321,200,320,170,324,142,336,119,356,102,380,144,418,192,440,248,448,304,440,352,418"},
	PROJECT_DIAGRAM = {640,"384,320,406,330,416,352,416,480,406,502,384,512,256,512,234,502,224,480,224,352,234,330,256,320;192,32,192,64,416,64,416,128,192,128,192,176,256,288,224,296,201,320,128,192,32,192,10,182,0,160,0,32,10,10,32,0,160,0,182,10;608,0,630,10,640,32,640,160,630,182,608,192,480,192,458,182,448,160,448,32,458,10,480,0"},
	SKULL = {512,"512,224,506,274,487,321,457,363,418,398,406,411,404,428,413,494,410,506,398,512,320,512,320,456,312,448,296,448,288,456,288,512,224,512,224,456,216,448,200,448,192,456,192,512,114,512,102,506,99,494,108,428,106,411,94,398,55,363,25,321,6,274,0,224,8,165,33,112,75,66,128,29,189,7,256,0,323,7,384,29,437,66,479,112,504,165;115,301,136,315,160,320,184,315,205,301,219,280,224,256,219,232,205,211,184,197,160,192,136,197,115,211,101,232,96,256,101,280;307,301,328,315,352,320,376,315,397,301,411,280,416,256,411,232,397,211,376,197,352,192,328,197,307,211,293,232,288,256,293,280"},
	ADJUST = {512,"80,432,40,380,16,321,8,256,16,191,40,132,80,80,132,40,191,16,256,8,321,16,380,40,432,80,472,132,496,191,504,256,496,321,472,380,432,432,380,472,321,496,256,504,191,496,132,472;256,440,304,434,348,416,386,386,416,348,434,304,440,256,434,208,416,164,386,126,348,96,304,78,256,72"},
	TREE = {384,"379,378,385,390,383,402,375,413,362,416,225,416,225,440,255,489,254,504,241,512,145,512,132,504,131,489,161,440,161,416,24,416,11,413,3,402,1,390,7,378,87,288,56,288,43,285,35,275,33,262,38,251,117,160,88,160,75,156,67,146,65,134,71,122,181,5,193,0,205,5,315,122,321,134,319,146,311,156,298,160,269,160,348,251,353,262,351,275,343,285,330,288,299,288"},
	ELLIPSIS_H = {512,"307,205,323,228,328,256,323,284,307,307,284,323,256,328,228,323,205,307,189,284,184,256,189,228,205,205,228,189,256,184,284,189;381,205,404,189,432,184,460,189,483,205,499,228,504,256,499,284,483,307,460,323,432,328,404,323,381,307,365,284,360,256,365,228;29,205,52,189,80,184,108,189,131,205,147,228,152,256,147,284,131,307,108,323,80,328,52,323,29,307,13,284,8,256,13,228"},
	TIMES = {352,"244,256,344,356,353,378,344,401,322,423,299,432,277,423,177,323,77,423,55,432,32,423,10,401,1,378,10,356,110,256,10,156,1,134,10,111,32,89,55,80,77,89,177,189,277,89,299,80,322,89,344,111,353,134,344,156"},
	FILE_IMPORT = {512,"16,288,128,288,128,352,16,352,4,348,0,336,0,304,4,292;505,105,512,122,512,128,384,128,384,0,390,0,407,7;352,136,359,153,376,160,512,160,512,488,505,505,488,512,152,512,135,505,128,488,128,352,256,352,256,417,258,426,266,432,283,428,379,332,385,320,379,308,283,212,266,208,258,214,256,223,256,288,128,288,128,24,135,7,152,0,352,0"},
	USER_MINUS = {640,"624,208,636,212,640,224,640,256,636,268,624,272,432,272,420,268,416,256,416,224,420,212,432,208;314,218,273,247,224,256,175,247,134,218,105,177,96,128,105,79,134,38,175,9,224,0,273,9,314,38,343,79,352,128,343,177;314,288,365,298,408,328,438,371,448,422,448,464,444,482,434,498,418,508,400,512,48,512,30,508,14,498,4,482,0,464,0,422,10,371,40,328,83,298,134,288,151,288,187,300,224,304,261,300,297,288"},
	LIST_ALT = {512,"464,480,48,480,30,476,14,466,4,450,0,432,0,80,4,62,14,46,30,36,48,32,464,32,482,36,498,46,508,62,512,80,512,432,508,450,498,466,482,476;156,132,144,123,128,120,112,123,100,132,91,144,88,160,91,176,100,188,112,197,128,200,144,197,156,188,165,176,168,160,165,144;156,228,144,219,128,216,112,219,100,228,91,240,88,256,91,272,100,284,112,293,128,296,144,293,156,284,165,272,168,256,165,240;156,324,144,315,128,312,112,315,100,324,91,336,88,352,91,368,100,380,112,389,128,392,144,389,156,380,165,368,168,352,165,336;416,176,416,144,413,135,404,132,204,132,195,135,192,144,192,176,195,185,204,188,404,188,413,185;416,272,416,240,413,231,404,228,204,228,195,231,192,240,192,272,195,281,204,284,404,284,413,281;416,368,416,336,413,327,404,324,204,324,195,327,192,336,192,368,195,377,204,380,404,380,413,377"},
	EXPAND_ALT = {448,"213,315,120,408,153,439,160,451,158,465,150,476,136,480,24,480,7,473,0,456,0,344,4,330,15,322,29,320,41,327,72,360,165,267,176,262,187,267,213,293,218,304;235,197,328,104,295,73,288,61,290,47,298,36,312,32,424,32,441,39,448,56,448,168,444,182,433,190,419,192,407,185,376,152,283,245,272,250,261,245,235,219,230,208"},
	TEXT_HEIGHT = {576,"304,32,316,36,320,48,320,144,316,156,304,160,272,160,260,156,256,144,256,112,200,112,200,416,240,416,252,420,256,432,256,464,252,476,240,480,80,480,68,476,64,464,64,432,68,420,80,416,120,416,120,112,64,112,64,144,60,156,48,160,16,160,4,156,0,144,0,48,4,36,16,32;560,368,569,370,575,378,571,395,491,475,480,480,469,475,389,395,385,378,391,370,400,368,448,368,448,144,400,144,391,142,385,134,389,117,469,37,480,32,491,37,571,117,575,134,569,142,560,144,512,144,512,368"},
	TEXT_SIZE = {640,"624,32,636,36,640,48,640,144,636,156,624,160,592,160,580,156,576,144,576,112,488,112,488,416,528,416,540,420,544,432,544,464,540,476,528,480,368,480,356,476,352,464,352,432,356,420,368,416,408,416,408,112,320,112,320,144,316,156,304,160,272,160,260,156,256,144,256,48,260,36,272,32;304,224,316,228,320,240,320,304,316,316,304,320,272,320,260,316,256,304,256,288,200,288,200,416,224,416,236,420,240,432,240,464,236,476,224,480,96,480,84,476,80,464,80,432,84,420,96,416,120,416,120,288,64,288,64,304,60,316,48,320,16,320,4,316,0,304,0,240,4,228,16,224"},
	CLONE = {512,"464,0,482,4,498,14,508,30,512,48,512,336,508,354,498,370,482,380,464,384,176,384,158,380,142,370,132,354,128,336,128,48,132,30,142,14,158,4,176,0;176,416,384,416,384,464,380,482,370,498,354,508,336,512,48,512,30,508,14,498,4,482,0,464,0,176,4,158,14,142,30,132,48,128,96,128,96,336,102,367,120,392,145,410"},
	RULER_TRIANGLE = {512,"502,452,512,470,509,490,496,507,477,512,35,512,10,502,0,477,0,35,10,10,36,0,60,10,111,62,73,100,73,111,84,123,95,123,134,84,190,141,152,179,152,191,163,202,174,202,213,163,269,220,231,258,231,270,242,281,254,281,292,243,349,299,310,338,310,349,321,360,333,360,371,322,428,378,389,417,389,428,401,439,412,439,450,401;128,384,253,384,128,259"},
	FILL_DRIP = {576,"512,320,548,376,569,418,576,448,571,473,558,494,537,507,512,512,487,507,466,494,453,473,448,448,452,428,464,400,496,344;503,217,512,240,503,262,281,484,250,505,213,512,176,505,145,484,28,367,7,336,0,299,7,262,28,231,123,136,37,50,31,39,37,27,59,5,71,-1,82,5,168,91,250,9,272,0,295,9;386,288,435,240,272,77,213,136,272,195,281,218,272,240,250,249,227,240,168,181,87,263,73,276,66,288"},
	COG = {512,"487,316,493,322,493,330,471,380,438,424,424,427,381,402,352,422,320,437,320,486,318,494,311,498,256,504,202,498,194,494,192,486,192,437,160,422,131,402,89,427,74,424,41,380,19,330,25,316,67,291,64,256,67,221,25,196,19,190,19,182,41,132,74,88,89,86,131,110,160,90,192,75,192,26,194,18,201,14,256,8,311,14,318,18,320,26,320,75,352,90,381,110,423,85,438,88,471,132,493,182,493,190,487,196,445,221,445,291;200,312,225,330,256,336,287,330,312,312,330,287,336,256,330,225,312,200,287,182,256,176,225,182,200,200,182,225,176,256,182,287"},
	SHIELD_ALT = {512,"466,84,488,101,496,128,490,204,474,274,449,337,417,388,382,430,346,464,274,508,238,508,197,487,158,458,121,420,87,376,58,325,36,264,21,198,16,128,24,101,46,84,238,4,256,0,274,4;256,446,303,416,345,377,380,328,408,271,425,208,432,139,256,65"},
	SYNC_ALT = {512,"371,133,318,99,256,88,201,97,152,124,115,164,93,215,89,222,81,224,24,224,14,220,12,210,29,155,58,107,98,66,146,34,198,14,256,8,319,16,376,39,427,77,463,41,475,34,489,36,500,44,504,58,504,192,497,209,480,216,346,216,332,212,324,201,322,187,329,175;32,296,166,296,180,300,188,311,190,325,183,337,141,379,194,413,256,424,311,415,360,388,397,348,419,297,423,290,431,288,488,288,498,292,500,302,483,357,454,405,414,446,366,478,314,498,256,504,193,496,136,473,85,435,49,471,37,478,23,476,12,468,8,454,8,320,15,303"},
	MUSIC = {512,"470,2,480,0,502,10,512,32,512,384,505,409,484,430,453,443,416,448,379,443,348,430,327,409,320,384,327,359,348,338,379,325,416,320,448,324,448,139,192,214,192,448,185,473,164,494,133,507,96,512,59,507,28,494,7,473,0,448,7,423,28,402,59,389,96,384,128,388,128,127,134,107,150,96"},
	COPYRIGHT = {512,"80,80,132,40,191,16,256,8,321,16,380,40,432,80,472,132,496,191,504,256,496,321,472,380,432,432,380,472,321,496,256,504,191,496,132,472,80,432,40,380,16,321,8,256,16,191,40,132;373,355,376,347,374,340,349,306,340,302,331,305,322,313,299,326,265,334,234,328,210,310,196,284,191,254,196,224,211,200,234,183,265,178,298,184,327,202,336,205,345,200,367,165,369,159,366,150,354,139,340,131,318,122,263,112,206,122,160,153,129,199,119,255,129,312,160,358,206,390,263,400,323,388,346,377,360,368"},
	COMMENTS = {576,"209,352,151,346,98,327,54,346,9,352,2,347,3,338,22,314,39,284,10,240,1,192,8,150,28,112,62,79,105,53,154,37,209,32,264,37,313,53,356,79,390,112,410,150,417,192,410,234,390,272,356,305,313,331,264,347;539,412,556,442,575,466,576,475,569,480,524,474,480,455,427,474,369,480,308,473,253,453,208,422,177,382,209,384,272,378,328,359,378,328,418,287,441,242,449,192,448,172,500,196,541,230,568,273,577,320,568,368"},
	CLOUD = {640,"538,227,578,242,611,271,633,309,640,352,631,401,602,442,561,471,512,480,144,480,88,470,42,438,10,392,0,336,7,292,27,252,58,220,96,200,96,192,101,150,117,112,143,79,176,53,214,37,256,32,298,38,337,54,370,80,395,112,420,100,448,96,485,103,516,124,537,155,544,192"},
	PLUS = {448,"416,208,438,218,448,240,448,272,438,294,416,304,272,304,272,448,262,470,240,480,208,480,186,470,176,448,176,304,32,304,10,294,0,272,0,240,10,218,32,208,176,208,176,64,186,42,208,32,240,32,262,42,272,64,272,208"},
	TRASH_RESTORE = {448,"53,467,32,128,416,128,395,467,391,484,380,499,365,509,347,512,101,512,83,509,68,499,57,484;123,291,120,310,126,317,135,320,192,320,192,432,196,444,208,448,240,448,252,444,256,432,256,320,313,320,322,317,328,310,325,291,235,197,224,192,213,197;432,32,444,36,448,48,448,80,444,92,432,96,16,96,4,92,0,80,0,48,4,36,16,32,136,32,145,13,154,3,167,0,281,0,294,3,303,13,312,32"},
	CLOUD_UPLOAD_ALT = {640,"538,227,578,242,611,271,633,309,640,352,631,401,602,442,561,471,512,480,144,480,88,470,42,438,10,392,0,336,7,292,27,252,58,220,96,200,96,192,101,150,117,112,143,79,176,53,214,37,256,32,298,38,337,54,370,80,395,112,420,100,448,96,485,103,516,124,537,155,544,192;393,288,402,286,408,278,405,261,299,155,288,150,277,155,171,261,168,278,174,286,183,288,248,288,248,400,252,412,264,416,312,416,324,412,328,400,328,288"},
	SORT_AMOUNT_DOWN = {512,"305,416,316,420,321,432,321,464,316,476,305,480,241,480,230,476,225,464,225,432,230,420,241,416;177,352,186,354,192,362,188,379,108,475,97,480,86,475,6,379,2,362,8,354,17,352,65,352,65,48,70,36,81,32,113,32,124,36,129,48,129,352;433,160,444,164,449,176,449,208,444,220,433,224,241,224,230,220,225,208,225,176,230,164,241,160;369,288,380,292,385,304,385,336,380,348,369,352,241,352,230,348,225,336,225,304,230,292,241,288;497,32,508,36,513,48,513,80,508,92,497,96,241,96,230,92,225,80,225,48,230,36,241,32"},
	GEM = {576,"486,0,576,160,475,160,406,0;358,0,427,160,149,160,218,0;90,0,170,0,101,160,0,160;0,192,101,192,224,444,222,448,219,447;148,192,428,192,291,510,288,512,285,510;352,444,475,192,576,192,357,447,354,448"},
	CLOUD_DOWNLOAD_ALT = {640,"538,227,578,242,611,271,633,309,640,352,631,401,602,442,561,471,512,480,144,480,88,470,42,438,10,392,0,336,7,292,27,252,58,220,96,200,96,192,101,150,117,112,143,79,176,53,214,37,256,32,298,38,337,54,370,80,395,112,420,100,448,96,485,103,516,124,537,155,544,192;405,315,408,298,402,290,393,288,328,288,328,176,324,164,312,160,264,160,252,164,248,176,248,288,183,288,174,290,168,298,171,315,277,421,288,426,299,421"},
	SHARE = {512,"504,190,512,208,504,226,328,378,316,384,302,382,292,373,288,360,288,272,243,274,205,278,146,296,124,311,110,330,101,354,98,383,101,418,111,458,111,469,104,477,83,476,51,447,24,408,6,366,0,322,4,281,15,245,32,215,55,192,83,173,118,158,196,142,288,136,288,56,292,43,302,34,316,32,328,38"},
	COPY = {448,"320,448,320,488,313,505,296,512,24,512,7,505,0,488,0,120,7,103,24,96,96,96,96,392,100,413,112,432,131,444,152,448;320,104,327,121,344,128,448,128,448,392,441,409,424,416,152,416,135,409,128,392,128,24,135,7,152,0,320,0;441,73,448,90,448,96,352,96,352,0,358,0,375,7"},
	TRASH = {448,"432,32,444,36,448,48,448,80,444,92,432,96,16,96,4,92,0,80,0,48,4,36,16,32,136,32,145,13,154,3,167,0,281,0,294,3,303,13,312,32;53,467,32,128,416,128,395,467,391,484,380,499,365,509,347,512,101,512,83,509,68,499,57,484"},
	UNDO = {512,"212,224,12,224,4,220,0,212,0,12,3,3,12,0,60,0,69,3,72,12,72,90,110,55,156,30,205,13,258,8,323,17,382,41,433,82,473,133,497,192,504,256,496,322,472,380,432,432,380,472,321,496,256,504,195,497,140,476,90,440,85,431,89,422,123,388,131,384,140,388,194,421,256,432,302,426,344,409,380,380,409,344,426,302,432,256,426,210,409,168,380,132,344,103,302,86,256,80,214,85,176,100,142,122,114,152,212,152,220,156,224,164,224,212,220,220"},
	CHECK = {512,"174,439,7,273,0,255,7,237,44,201,62,193,80,201,192,313,432,73,450,65,468,73,505,109,512,127,505,145,210,439,192,447"},
	FIRE = {384,"216,24,220,51,234,77,276,124,324,171,347,199,366,234,380,275,384,320,378,370,359,415,328,456,287,487,242,506,192,512,142,506,97,487,56,456,25,415,6,370,0,320,6,270,24,225,55,185,67,178,81,179,92,188,96,202,96,287,101,312,114,333,135,347,159,352,184,347,205,334,219,313,224,288,214,255,192,226,164,199,140,168,128,130,128,107,136,78,150,46,172,11,184,1,199,1,212,9"},
	STAR = {576,"259,18,271,4,288,0,305,4,317,18,382,150,528,172,544,178,554,193,555,211,546,226,440,329,465,475,463,492,452,506,436,512,419,508,288,440,157,508,140,512,124,506,113,492,111,475,136,329,30,226,21,211,22,193,32,178,48,172,194,150"},
	WATER = {576,"562,384,572,390,576,400,576,432,571,444,559,448,518,440,480,422,436,442,385,448,334,442,288,422,244,442,193,448,142,442,96,422,59,440,17,448,5,444,0,432,0,400,4,390,14,384,45,376,71,362,95,352,118,360,151,377,191,384,231,378,264,361,287,352,310,360,343,377,384,384,424,378,456,361,480,353,504,361,531,376;562,240,572,246,576,256,576,288,571,300,559,304,518,296,480,278,436,298,385,304,334,298,288,278,244,298,193,304,142,298,96,278,59,296,17,304,5,300,0,288,0,256,4,246,14,240,45,232,71,218,95,208,118,216,151,233,191,240,231,234,264,217,287,208,310,216,343,233,384,240,424,234,456,217,480,209,504,217,531,232;562,96,572,102,576,112,576,144,571,156,559,160,518,152,480,134,436,154,385,160,334,154,288,134,244,154,193,160,142,154,96,134,59,152,17,160,5,156,0,144,0,112,4,102,14,96,45,88,71,74,95,64,118,72,151,89,191,96,231,90,264,73,287,64,310,72,343,89,384,96,424,90,456,73,480,65,504,73,530,88"},
	PALETTE = {512,"205,5,283,1,356,20,421,58,470,114,502,181,513,255,508,280,494,301,473,315,448,320,368,320,334,328,310,352,299,384,307,418,315,446,309,476,292,499,265,510,217,510,166,496,117,470,74,435,39,389,14,332,1,269,6,203,31,134,76,74,136,30;74,310,97,320,120,310,129,288,120,266,97,256,74,266,65,288;106,182,129,192,152,182,161,160,152,138,129,128,106,138,97,160;234,118,257,128,280,118,289,96,280,74,257,64,234,74,225,96;362,182,385,192,408,182,417,160,408,138,385,128,362,138,353,160"},
	SUN = {512,"189,188,220,167,257,160,294,167,325,188,346,219,353,256,346,293,325,324,294,345,257,352,220,345,189,324,168,293,161,256,168,219;503,240,513,256,503,272,409,319,442,419,438,437,420,441,320,408,272,502,266,510,257,512,241,502,194,408,94,441,76,438,72,419,105,319,11,272,1,256,11,240,105,193,72,93,76,75,94,71,194,104,241,10,257,0,273,10,320,104,420,71,438,75,442,93,409,193;257,384,306,375,348,346,376,305,385,256,376,207,348,166,306,137,257,128,208,137,166,166,138,207,129,256,138,305,166,346,208,375"},
	WAVE_SQUARE = {640,"476,480,324,480,298,470,288,444,288,96,192,96,192,252,182,278,156,288,16,288,4,284,0,272,0,240,4,228,16,224,128,224,128,68,138,42,164,32,316,32,342,42,352,68,352,416,448,416,448,260,458,234,484,224,624,224,636,228,640,240,640,272,636,284,624,288,512,288,512,444,502,470"},
	ATOM = {448,"202,234,225,224,248,234,257,256,248,278,225,288,202,278,193,256;439,128,450,166,441,208,414,256,441,304,450,346,439,384,413,412,375,426,323,426,296,474,263,502,225,512,187,502,154,474,127,426,75,426,37,412,11,384,0,346,9,304,36,256,9,208,0,166,11,128,37,100,75,86,127,86,154,38,187,10,225,0,263,10,296,38,323,86,375,86,413,100;64,352,78,361,108,363,101,323,79,304,64,334;101,189,108,149,105,148,102,148,77,151,64,160,64,178,79,208;191,101,225,114,259,101,242,73,225,64,208,73;259,411,225,398,191,411,208,439,225,448,242,439;168,312,194,330,225,336,256,330,282,312,299,287,305,256,299,225,282,200,256,182,225,176,194,182,168,200,151,225,145,256,151,287;386,352,386,334,371,304,349,323,342,363,372,361;371,208,386,178,386,160,373,151,348,148,345,148,342,149,349,189"},
	CERTIFICATE = {512,"460,256,506,301,512,312,512,324,506,335,495,341,432,357,450,419,450,432,444,443,433,450,420,449,358,431,342,494,336,505,325,512,312,512,302,505,257,459,212,505,202,512,189,512,178,505,172,494,156,431,94,449,81,450,70,443,64,432,64,419,82,357,19,341,8,335,2,324,2,312,8,301,54,256,8,211,2,200,2,188,8,177,19,171,82,155,64,93,64,80,70,69,81,62,94,63,156,81,172,18,178,7,189,0,202,0,212,7,257,54,302,7,313,0,326,1,336,7,342,18,358,81,420,63,433,62,444,69,450,80,450,93,432,155,495,171,506,177,512,188,512,200,506,211"},
	MOUNTAIN = {640,"635,463,640,480,636,495,624,508,608,512,32,512,16,508,4,495,0,480,5,463,293,15,305,4,320,0,335,4,347,15;320,91,218,250,256,288,320,224,405,224"},
	TH = {512,"149,56,149,136,142,153,125,160,24,160,7,153,0,136,0,56,7,39,24,32,125,32,142,39;331,296,324,313,307,320,205,320,188,313,181,296,181,216,188,199,205,192,307,192,324,199,331,216;363,56,370,39,387,32,488,32,505,39,512,56,512,136,505,153,488,160,387,160,370,153,363,136;331,136,324,153,307,160,205,160,188,153,181,136,181,56,188,39,205,32,307,32,324,39,331,56;125,192,142,199,149,216,149,296,142,313,125,320,24,320,7,313,0,296,0,216,7,199,24,192;0,376,7,359,24,352,125,352,142,359,149,376,149,456,142,473,125,480,24,480,7,473,0,456;387,320,370,313,363,296,363,216,370,199,387,192,488,192,505,199,512,216,512,296,505,313,488,320;387,480,370,473,363,456,363,376,370,359,387,352,488,352,505,359,512,376,512,456,505,473,488,480;181,376,188,359,205,352,307,352,324,359,331,376,331,456,324,473,307,480,205,480,188,473,181,456"},
	TH_LARGE = {512,"296,32,488,32,505,39,512,56,512,216,505,233,488,240,296,240,279,233,272,216,272,56,279,39;216,32,233,39,240,56,240,216,233,233,216,240,24,240,7,233,0,216,0,56,7,39,24,32;0,296,7,279,24,272,216,272,233,279,240,296,240,456,233,473,216,480,24,480,7,473,0,456;296,480,279,473,272,456,272,296,279,279,296,272,488,272,505,279,512,296,512,456,505,473,488,480"},
	ROCKET = {512,"505,19,510,56,512,102,504,168,478,224,438,271,384,313,384,417,376,442,357,460,259,509,248,512,231,505,224,488,224,384,202,407,178,416,156,407,105,356,96,332,105,310,128,288,24,288,7,281,0,264,3,253,52,154,70,136,95,128,199,128,241,74,288,34,344,8,410,0,456,2,493,7;356,156,368,165,384,168,400,165,412,156,421,144,424,128,421,112,412,100,400,91,384,88,368,91,356,100,347,112,344,128,347,144"},
	VECTOR_SQUARE = {512,"512,128,502,150,480,160,480,352,502,362,512,384,512,480,502,502,480,512,384,512,362,502,352,480,160,480,150,502,128,512,32,512,10,502,0,480,0,384,10,362,32,352,32,160,10,150,0,128,0,32,10,10,32,0,128,0,150,10,160,32,352,32,362,10,384,0,480,0,502,10,512,32;416,64,416,96,448,96,448,64;64,64,64,96,96,96,96,64;96,448,96,416,64,416,64,448;448,448,448,416,416,416,416,448;416,352,416,160,384,160,362,150,352,128,352,96,160,96,160,128,150,150,128,160,96,160,96,352,128,352,150,362,160,384,160,416,352,416,352,384,362,362,384,352"},
	CLOUD_RAIN = {512,"416,128,453,135,484,156,505,187,512,224,505,261,484,292,453,313,416,320,96,320,59,313,28,292,7,261,0,224,5,194,18,168,40,147,66,133,64,112,72,69,97,33,133,8,176,0,207,4,234,16,258,36,275,61,302,39,336,32,367,38,392,56,410,81,416,112,414,128;88,374,96,368,104,374,127,420,140,443,144,462,140,481,130,498,114,508,96,512,78,508,62,498,52,481,48,462,52,444,65,420;248,374,256,368,264,374,287,420,300,443,304,462,300,481,290,498,274,508,256,512,238,508,222,498,212,481,208,462,212,444,225,420;408,374,416,368,424,374,447,420,460,443,464,462,460,481,450,498,434,508,416,512,398,508,382,498,372,481,368,462,372,444,385,420"},
	BULLSEYE = {496,"72,80,124,40,183,16,248,8,313,16,372,40,424,80,464,132,488,191,496,256,488,321,464,380,424,432,372,472,313,496,248,504,183,496,124,472,72,432,32,380,8,321,0,256,8,191,32,132;118,386,156,416,200,434,248,440,296,434,340,416,378,386,408,348,426,304,432,256,426,208,408,164,378,126,340,96,296,78,248,72,200,78,156,96,118,126,88,164,70,208,64,256,70,304,88,348;158,166,199,137,248,128,297,137,338,166,367,207,376,256,367,305,338,346,297,375,248,384,199,375,158,346,129,305,120,256,129,207;203,301,224,315,248,320,272,315,293,301,307,280,312,256,307,232,293,211,272,197,248,192,224,197,203,211,189,232,184,256,189,280"},
	VOLUME_MUTE = {512,"215,71,227,64,241,66,252,74,256,88,256,424,252,438,241,446,227,448,215,441,126,352,24,352,7,345,0,328,0,184,7,167,24,160,126,160;462,256,507,302,513,313,507,324,484,347,473,353,462,347,416,302,370,347,359,353,348,347,325,324,319,313,325,302,370,256,325,210,319,199,325,188,348,165,359,159,370,165,416,210,462,165,473,159,484,165,507,188,513,199,507,210"},
	MICROPHONE_ALT = {352,"336,192,348,196,352,208,352,256,341,318,308,372,260,411,200,430,200,464,256,464,268,468,272,480,272,496,268,508,256,512,96,512,84,508,80,496,80,480,84,468,96,464,152,464,152,430,111,419,75,399,44,368,11,312,0,248,0,208,4,196,16,192,32,192,44,196,48,208,48,250,56,298,81,340,118,370,163,383,216,378,262,350,294,308,304,256,304,208,308,196,320,192;80,256,80,96,87,59,108,28,139,7,176,0,213,7,244,28,265,59,272,96,187,96,179,98,176,104,176,120,179,126,187,128,272,128,272,160,187,160,179,162,176,168,176,184,179,190,187,192,272,192,272,224,187,224,179,226,176,232,176,248,179,254,187,256,272,256,265,293,244,324,213,345,176,352,139,345,108,324,87,293"},
	FILM = {512,"488,64,505,71,512,88,512,424,505,441,488,448,480,448,480,428,477,419,468,416,428,416,419,419,416,428,416,448,96,448,96,428,93,419,84,416,44,416,35,419,32,428,32,448,24,448,7,441,0,424,0,88,7,71,24,64,32,64,32,84,35,93,44,96,84,96,93,93,96,84,96,64,416,64,416,84,419,93,428,96,468,96,477,93,480,84,480,64;96,372,96,332,93,323,84,320,44,320,35,323,32,332,32,372,35,381,44,384,84,384,93,381;96,276,96,236,93,227,84,224,44,224,35,227,32,236,32,276,35,285,44,288,84,288,93,285;96,180,96,140,93,131,84,128,44,128,35,131,32,140,32,180,35,189,44,192,84,192,93,189;368,388,368,292,365,283,356,280,156,280,147,283,144,292,144,388,147,397,156,400,356,400,365,397;368,220,368,124,365,115,356,112,156,112,147,115,144,124,144,220,147,229,156,232,356,232,365,229;480,372,480,332,477,323,468,320,428,320,419,323,416,332,416,372,419,381,428,384,468,384,477,381;480,276,480,236,477,227,468,224,428,224,419,227,416,236,416,276,419,285,428,288,468,288,477,285;480,180,480,140,477,131,468,128,428,128,419,131,416,140,416,180,419,189,428,192,468,192,477,189"},
	EXTERNAL_LINK_ALT = {512,"432,320,444,324,448,336,448,464,444,482,434,498,418,508,400,512,48,512,30,508,14,498,4,482,0,464,0,112,4,94,14,78,30,68,48,64,208,64,220,68,224,80,224,112,220,124,208,128,64,128,64,448,384,448,384,336,388,324,400,320;488,0,505,7,512,24,512,152,508,166,497,174,483,176,471,169,435,133,192,377,175,384,158,377,135,354,128,337,135,320,379,77,343,41,336,29,338,15,346,4,360,0"},
}


local GlyphCache, RasterCache = {}, {}

function glyphContours(name)
	local cached = GlyphCache[name]
	if cached then return cached end
	local data = assert(GlyphData[name], name)
	local contours, x0, y0, x1, y1 = {}, math.huge, math.huge, -math.huge, -math.huge
	for part in string.gmatch(data[2], "[^;]+") do
		local c, i = {}, 0
		for number in string.gmatch(part, "-?%d+") do
			i += 1
			local value = tonumber(number)
			c[i] = value
			if i % 2 == 1 then x0, x1 = math.min(x0, value), math.max(x1, value) else y0, y1 = math.min(y0, value), math.max(y1, value) end
		end
		table.insert(contours, c)
	end
	cached = { adv = data[1], contours = contours, x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
	GlyphCache[name] = cached
	return cached
end

local function addSpan(cov, a, b, weight, width)
	if b <= 0 or a >= width then return end
	a, b = math.max(a, 0), math.min(b, width)
	local i0, i1 = math.floor(a), math.floor(b)
	if i0 == i1 then
		cov[i0] = (cov[i0] or 0) + (b - a) * weight
		return
	end
	cov[i0] = (cov[i0] or 0) + (i0 + 1 - a) * weight
	for i = i0 + 1, i1 - 1 do cov[i] = (cov[i] or 0) + weight end
	if b > i1 then cov[i1] = (cov[i1] or 0) + (b - i1) * weight end
end

local byX = function(a, b) return a[1] < b[1] end

-- contours: lists of x,y in design pixels. device: how many device pixels one design pixel is.
local function rasterize(contours, unit, device)
	local k = unit * device
	local edges, minX, minY, maxX, maxY = {}, math.huge, math.huge, -math.huge, -math.huge
	for _, c in contours do
		local n = #c // 2
		for i = 1, n do
			local x1, y1 = c[i * 2 - 1] * k, c[i * 2] * k
			local j = i % n + 1
			local x2, y2 = c[j * 2 - 1] * k, c[j * 2] * k
			minX, maxX, minY, maxY = math.min(minX, x1), math.max(maxX, x1), math.min(minY, y1), math.max(maxY, y1)
			if y1 < y2 then
				table.insert(edges, { y1, y2, x1, (x2 - x1) / (y2 - y1), 1 })
			elseif y2 < y1 then
				table.insert(edges, { y2, y1, x2, (x1 - x2) / (y1 - y2), -1 })
			end
		end
	end
	local x0, y0 = math.floor(minX), math.floor(minY)
	local width, height = math.ceil(maxX) - x0, math.ceil(maxY) - y0
	local rects, open = {}, {}
	local SUB = 5
	for row = 0, height - 1 do
		local cov = {}
		for s = 0, SUB - 1 do
			local y = y0 + row + (s + 0.5) / SUB
			local hits = {}
			for _, e in edges do
				if y >= e[1] and y < e[2] then table.insert(hits, { e[3] + (y - e[1]) * e[4], e[5] }) end
			end
			table.sort(hits, byX)
			local winding = 0
			for i = 1, #hits - 1 do
				winding += hits[i][2]
				if winding ~= 0 then addSpan(cov, hits[i][1] - x0, hits[i + 1][1] - x0, 1 / SUB, width) end
			end
		end
		local nextOpen, x = {}, 0
		while x < width do
			local level = math.floor(math.min(cov[x] or 0, 1) * 15 + 0.5)
			local start = x
			repeat x += 1 until x >= width or math.floor(math.min(cov[x] or 0, 1) * 15 + 0.5) ~= level
			if level > 0 then
				local key = start * 4096 + (x - start) * 16 + level
				local rect = open[key]
				if rect then
					rect[4] += 1
				else
					rect = { start, row, x - start, 1, level / 15 }
					table.insert(rects, rect)
				end
				nextOpen[key] = rect
			end
		end
		open = nextOpen
	end
	return { x0 = x0, y0 = y0, w = width, h = height, rects = rects }
end

Shapes = setmetatable({}, { __mode = "k" })
LazyRoots = {}

ShapeMeta = {}
ShapeMeta.__index = ShapeMeta

function ShapeMeta:rebuild()
	if self.deferred then return end
	local key = self.key and (self.key .. "@" .. Scale)
	local raster = key and RasterCache[key]
	if not raster then
		raster = rasterize(self.contours, self.unit, Scale)
		if key then RasterCache[key] = raster end
	end
	for _, frame in self.frames do frame:Destroy() end
	table.clear(self.frames)
	self.raster = raster
	-- Offsets are whole numbers, so the holder rounds up and each run is placed by its share of
	-- the holder's real device size. Every run then lands on an exact device pixel at any scale.
	local holderW, holderH = math.ceil(raster.w / Scale), math.ceil(raster.h / Scale)
	local deviceW, deviceH = holderW * Scale, holderH * Scale
	for _, r in raster.rects do
		table.insert(self.frames, New("Frame", {
			BorderSizePixel = 0, BackgroundColor3 = self.color,
			BackgroundTransparency = 1 - r[5] * self.alpha,
			Position = UDim2.fromScale(r[1] / deviceW, r[2] / deviceH),
			Size = UDim2.fromScale(r[3] / deviceW, r[4] / deviceH),
		}, self.holder))
	end
	setWH(self.holder, holderW, holderH)
	self:at(self.px, self.py)
end

function ShapeMeta:at(x, y)
	self.px, self.py = x, y
	if self.raster then setXY(self.holder, x + self.raster.x0 / Scale, y + self.raster.y0 / Scale) end
	return self
end

function ShapeMeta:paint(color, alpha)
	alpha = alpha or 1
	if self.color == color and self.alpha == alpha then return self end
	local changed = self.color ~= color
	self.color, self.alpha = color, alpha
	if self.deferred then return self end
	local rects = self.raster.rects
	for i, frame in self.frames do
		if changed then frame.BackgroundColor3 = color end
		frame.BackgroundTransparency = 1 - rects[i][5] * alpha
	end
	return self
end

-- A glyph is positioned by the centre of its ink, as the original does for nearly every icon.
function ShapeMeta:center(cx, cy)
	return self:at(round(cx - self.inkX), round(cy - self.inkY))
end

function ShapeMeta:setVisible(state) self.holder.Visible = state end
end

local function Shape(parent, contours, unit, key)
	local shape = setmetatable({
		holder = Box(parent, 0, 0, 0, 0), contours = contours, unit = unit or 1, key = key,
		frames = {}, color = White, alpha = 1, px = 0, py = 0, inkX = 0, inkY = 0,
	}, ShapeMeta)
	local lazy = parent
	while lazy and not LazyRoots[lazy] do lazy = lazy.Parent end
	if lazy then
		shape.deferred = true
		table.insert(LazyRoots[lazy], shape)
	else
		shape:rebuild()
	end
	Shapes[shape] = true
	return shape
end

local function flushLazy(root)
	local pending = LazyRoots[root]
	if not pending then return end
	LazyRoots[root] = nil
	for _, shape in pending do
		shape.deferred = false
		shape:rebuild()
	end
end

local function Glyph(parent, name, size)
	local g = glyphContours(name)
	local unit = size / 512
	local shape = Shape(parent, g.contours, unit, name .. "#" .. size)
	shape.inkX, shape.inkY = (g.x0 + g.x1) * 0.5 * unit, (g.y0 + g.y1) * 0.5 * unit
	shape.boxW = g.adv * unit
	shape.name = name
	return shape
end

-- An anti-aliased polyline with square ends, used for the hand-drawn chevrons and the check.
local function strokeContours(points, thickness)
	local contours, half = {}, thickness * 0.5
	for i = 1, #points - 2, 2 do
		local x1, y1, x2, y2 = points[i], points[i + 1], points[i + 2], points[i + 3]
		local dx, dy = x2 - x1, y2 - y1
		local length = math.sqrt(dx * dx + dy * dy)
		local nx, ny = -dy / length * half, dx / length * half
		-- extended by half the width so that the joints overlap
		local ex, ey = dx / length * half, dy / length * half
		local a, b = { x1 - ex + nx, y1 - ey + ny }, { x2 + ex + nx, y2 + ey + ny }
		local c, d = { x2 + ex - nx, y2 + ey - ny }, { x1 - ex - nx, y1 - ey - ny }
		table.insert(contours, { a[1], a[2], b[1], b[2], c[1], c[2], d[1], d[2] })
	end
	return contours
end

local function setRasterScale(scale)
	scale = clamp(tonumber(scale) or 1, 0.5, 2) -- un settings.json roto (0, 100...) dejaba la ventana inservible
	Scale = scale
	StageScale.Scale = scale
	Stage.Size = UDim2.fromScale(1 / scale, 1 / scale)
	table.clear(Widths)
	for shape in Shapes do
		if shape.holder.Parent then shape:rebuild() end
	end
end

local function repaintAll()
	applyPalette()
	Root:refresh()
end

--[[ ---------------------------------------- Text ------------------------------------------ ]]

-- From the live client: Inter's capitals start 2px below a Top-aligned label's top edge.
local CapCentre = { [11] = 6, [12] = 6.4, [14] = 7.5 }

-- Top of a label whose capitals are centred on cy.
local function capY(cy, size)
	return round(cy - CapCentre[size])
end

local function Label(parent, text, x, y, size, font, color)
	return New("TextLabel", {
		Text = text, Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(math.max(measure(text, size, font) + 4, 4), math.ceil(size * 1.3)),
		BackgroundTransparency = 1, BorderSizePixel = 0, FontFace = font or FontMedium, TextSize = size,
		TextColor3 = color or White, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
	}, parent)
end

local function setText(label, text, size, font)
	if label.Text ~= text then
		label.Text = text
		label.Size = UDim2.fromOffset(math.max(measure(text, size, font) + 4, 4), label.Size.Y.Offset)
	end
end

-- A label held to a rectangle. If it overflows it fades at the edge and creeps along while hovered.
local function ScrollText(parent, x, y, w, h, size, font)
	local clip = Box(parent, x, y, w, h)
	clip.ClipsDescendants = true
	local label = Label(clip, "", 0, capY(h * 0.5, size), size, font)
	local object = { clip = clip, label = label, scroll = 0, over = 0, hovered = false, text = nil, wait = 0 }
	local fade = New("UIGradient", { Enabled = false }, label)

	local function refreshFade()
		label.Position = UDim2.fromOffset(-round(object.scroll), label.Position.Y.Offset)
		if object.over <= 0 then
			fade.Enabled = false
			return
		end
		local width = object.textW
		local rectW = clip.Size.X.Offset
		local band = math.min(18, rectW * 0.4)
		local left, right = sat(object.scroll / band), sat((object.over - object.scroll) / band)
		local a0 = object.scroll / width
		local a1 = (object.scroll + band) / width
		local b0 = (object.scroll + rectW - band) / width
		local b1 = (object.scroll + rectW) / width
		local keys = { NumberSequenceKeypoint.new(0, left > 0 and 1 or 0) }
		local function add(t, v)
			t = clamp(t, 0.0001, 0.9999)
			if t > keys[#keys].Time + 0.0005 then table.insert(keys, NumberSequenceKeypoint.new(t, v)) end
		end
		add(a0, left)
		add(a1, 0)
		add(b0, 0)
		add(b1, right)
		table.insert(keys, NumberSequenceKeypoint.new(1, right > 0 and 1 or 0))
		fade.Transparency = NumberSequence.new(keys)
		fade.Enabled = true
	end

	local ticking = false
	local function ensureTicker()
		if ticking then return end
		ticking = true
		Run(function(dt)
			if object.over > 0 and object.hovered then
				object.wait += dt
				if object.wait >= 0.25 then object.scroll = math.min(object.over, object.scroll + 40 * dt) end
			else
				object.wait = 0
				object.scroll += (0 - object.scroll) * (1 - math.exp(-14 * dt))
				if object.scroll < 0.01 then object.scroll = 0 end
			end
			refreshFade()
			if object.scroll == 0 and not object.hovered then
				ticking = false
				return false
			end
			return true
		end)
	end

	function object:set(text)
		if self.text == text then return end
		self.text = text
		setText(label, text, size, font)
		self.textW = math.max(measure(text, size, font), 1)
		self.over = math.max(0, self.textW - clip.Size.X.Offset)
		self.scroll = 0
		refreshFade()
	end
	function object:paint(color, alpha)
		label.TextColor3 = color
		label.TextTransparency = 1 - alpha
	end
	function object:hover(state)
		self.hovered = state
		if self.over > 0 then ensureTicker() end
	end
	function object:width(w2)
		setWH(clip, w2, h)
		if self.textW then
			self.over = math.max(0, self.textW - w2)
			refreshFade()
		end
	end
	return object
end

--[[ ---------------------------------------- Popup cards ----------------------------------- ]]

local CurrentWindow
local ZCounter = 100
local function nextZ() ZCounter += 1 return ZCounter end

local Card = {}
Card.__index = Card

local function buildSurface(frame, width, height, rounding, border)
	local surface = Box(frame, 0, 0, width, height, T.Popup, rounding)
	local shadow = Shadow(surface, 26, 0.5, 6)
	local ring
	if border then
		ring = Stroke(Box(frame, 1, 1, width - 2, height - 2, nil, math.max(rounding - 1, 0)), T.PopupBorder)
	end
	return surface, shadow, ring
end

local function resizeSurface(card, width, height)
	setWH(card.surface, width, height)
	if card.ring then setWH(card.ring.Parent, width - 2, height - 2) end
	setWH(card.frame, width, height)
end

function Card:paintSurface()
	local a = self.scope.alpha
	self.surface.BackgroundColor3, self.surface.BackgroundTransparency = T.Popup, 1 - a
	if self.shadow then self.shadow.Transparency = 1 - 0.5 * a end
	if self.ring then
		self.ring.Color = T.PopupBorder
		self.ring.Transparency = 1 - a
	end
end

local function newCard(o)
	local width, padding = o.width or 240, o.padding or 10
	local rounding = o.rounding or 12
	local frame = Box(Stage, 0, 0, width, 40)
	frame.Visible, frame.Active, frame.Name = false, true, o.name or "Card"
	local surface, shadow, ring = buildSurface(frame, width, 40, rounding, o.border ~= false)
	local content = Box(frame, 0, 0, width, 40)
	local card = setmetatable({
		frame = frame, surface = surface, shadow = shadow, ring = ring, content = content,
		width = width, height = 40, padding = padding, build = o.build, place = o.place,
		scope = newScope(Root), state = 0, isOpen = false, built = false, base = Vector2.zero, drag = Vector2.zero, dragTarget = Vector2.zero,
	}, Card)
	card.scope.own = 0
	card.scope:paint(function() card:paintSurface() end)
	return card
end

function Card:setHeight(height)
	self.height = height
	resizeSurface(self, self.width, height)
	setWH(self.content, self.width, height)
	self:paintSurface()
end

function Card:apply()
	local p = self.base + self.drag
	setXY(self.frame, round(p.X), round(p.Y))
	self:paintSurface()
end

function Card:dragTo(target)
	self.dragTarget = target
	if self.dragging then return end
	self.dragging = true
	Run(function(dt)
		self.drag = self.drag:Lerp(self.dragTarget, 1 - math.exp(-20 * dt))
		if (self.dragTarget - self.drag).Magnitude < 0.5 then self.drag = self.dragTarget end
		self:apply()
		if self.drag == self.dragTarget then
			self.dragging = false
			return false
		end
		return true
	end)
end

function Card:startFade()
	if self.fading then return end
	self.fading = true
	Run(function(dt)
		local value = self.state
		if self.isOpen then
			value += (1 - value) * (1 - math.exp(-15 * dt))
			if value > 0.998 then value = 1 end
		else
			value = math.max(0, value - dt / 0.16)
			if value < 0.01 then value = 0 end
		end
		self.state = value
		self.scope:setAlpha(value)
		if value == 0 then self.frame.Visible = false end
		if (self.isOpen and value == 1) or value == 0 then
			self.fading = false
			return false
		end
		return true
	end)
end

function Card:open(level, ...)
	closePopupsTo(level or 0)
	self.level = #Popups + 1
	if not self.built then
		self.built = true
		if self.build then self.build(self) end
	end
	if self.onOpen then self.onOpen(...) end
	self.drag, self.dragTarget = Vector2.zero, Vector2.zero
	if self.place then self.base = self.place(self, ...) end
	self.isOpen = true
	table.insert(Popups, self)
	self.frame.ZIndex = nextZ()
	self.frame.Visible = true
	self:apply()
	self:startFade()
	if self.onState then self.onState(true) end
end

function Card:close()
	self.isOpen = false
	self:startFade()
	if self.onState then self.onState(false) end
end

function Card:destroy()
	if self.isOpen then closePopupsTo((self.level or 1) - 1) end
	local index = table.find(Root.kids, self.scope)
	if index then table.remove(Root.kids, index) end
	self.frame:Destroy()
end

closePopupsTo = function(level)
	for i = #Popups, level + 1, -1 do
		local card = table.remove(Popups, i)
		card:close()
	end
end

local function keepOnScreen(card, x, y, margin)
	margin = margin or 10
	local view = viewport()
	return Vector2.new(clamp(x, margin, math.max(margin, view.X - card.width - margin)), clamp(y, margin, math.max(margin, view.Y - card.height - margin)))
end

-- Beside the click, centred on its row, outside the menu when there is room.
local function placeBeside(card, click)
	local x, y = click.X + 45, click.Y
	if CurrentWindow then
		local a = CurrentWindow:pos()
		local top, bottom = a.Y, a.Y + 600
		y = clamp(y, top + 16 + card.height * 0.5, math.max(top + 16 + card.height * 0.5, bottom - 16 - card.height * 0.5))
	end
	return keepOnScreen(card, x, y - card.height * 0.5)
end

--[[ ---------------------------------------- Tooltip --------------------------------------- ]]

do -- bloque propio: sus locales no cuentan en el pico de registros (tools/wrap_block.js)
local TipFrame, TipTitle, TipBody, TipOwner, TipCard
local TipAlpha = 0

local function buildTip()
	TipCard = newCard({ width = 200, rounding = 10, name = "Tooltip" })
	TipCard.frame.Active = false
	TipFrame = TipCard.frame
	TipTitle = Label(TipCard.content, "", 14, capY(20.5, 14), 14, FontSemi)
	TipBody = Label(TipCard.content, "", 14, capY(44.5, 12), 12)
	TipCard.scope:paint(function()
		local a = TipCard.scope.alpha
		TipTitle.TextColor3, TipTitle.TextTransparency = T.Text, 1 - a
		TipBody.TextColor3, TipBody.TextTransparency = T.Soft, 1 - a
	end)
end

local function runTip()
	Run(function(dt)
		local showing = TipOwner ~= nil
		TipAlpha = showing and math.min(1, TipAlpha + dt / 0.12) or math.max(0, TipAlpha - dt / 0.14)
		TipCard.scope:setAlpha(TipAlpha)
		if TipAlpha == 0 then
			TipFrame.Visible = false
			Tip.running = false
			return false
		end
		return true
	end)
end

ShowTip = function(item)
	if TipOwner == item then return end
	if not TipFrame then buildTip() end
	TipOwner = item
	local title, body = tr(item.tip[1]), tr(item.tip[2])
	TipTitle.Text, TipBody.Text = title, body
	local titleW, bodyW = measure(title, 14, FontSemi), measure(body, 12)
	local lines = bodyW > 320 and math.ceil(bodyW / 320) or 1
	local width = math.ceil(math.max(titleW, math.min(bodyW, 320))) + 28
	TipBody.TextWrapped = lines > 1
	setWH(TipTitle, titleW + 4, 18)
	setWH(TipBody, math.min(bodyW, 320) + 2, lines * 15 + 2)
	TipCard.width = width
	TipCard.height = 12 + 17 + 8 + lines * 15 + 12
	resizeSurface(TipCard, width, TipCard.height)
	setWH(TipCard.content, width, TipCard.height)
	local a = toStage(item.gui.AbsolutePosition)
	local s = item.gui.AbsoluteSize / Scale
	local spot = keepOnScreen(TipCard, a.X + s.X + 30, a.Y, 6)
	setXY(TipFrame, round(spot.X), round(spot.Y))
	TipFrame.ZIndex = 100000
	TipFrame.Visible = true
	TipCard:paintSurface()
	if not Tip.running then
		Tip.running = true
		runTip()
	end
end

HideTip = function()
	TipOwner = nil
end
end

--[[ ---------------------------------------- Small parts ----------------------------------- ]]

local function Switch(parent, x, y, scope)
	local track = Box(parent, x, y, 30, 19, White, 9)
	track:FindFirstChildOfClass("UICorner").CornerRadius = UDim.new(1, 0)
	local rimFrame = Box(track, 1, 1, 28, 17, nil, 8)
	rimFrame:FindFirstChildOfClass("UICorner").CornerRadius = UDim.new(1, 0)
	local rim = Stroke(rimFrame)
	local knob = Box(track, 2, 2, 15, 15, White, 8)
	knob:FindFirstChildOfClass("UICorner").CornerRadius = UDim.new(1, 0)
	return function(t)
		t = sat(t)
		local a = scope.alpha
		track.BackgroundColor3 = T.SwitchOff:Lerp(Accent, t)
		track.BackgroundTransparency = 1 - a
		rim.Color, rim.Transparency = T.SwitchRim, 1 - A.SwitchRim * (1 - t) * a
		setXY(knob, round(2 + 11 * t), 2)
		knob.BackgroundColor3 = T.KnobOff:Lerp(White, t)
		knob.BackgroundTransparency = 1 - a
	end
end

-- A 4px bar on a half pixel, as ImGui rasterises it: half coverage on the rows either side.
local function SoftBar(parent, x, y, w, color, corners)
	local bar = Box(parent, x, y, w, 5, color, 2)
	local g = New("UIGradient", {
		Rotation = 90,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, .5), NumberSequenceKeypoint.new(.199, .5), NumberSequenceKeypoint.new(.2, 0),
			NumberSequenceKeypoint.new(.799, 0), NumberSequenceKeypoint.new(.8, .5), NumberSequenceKeypoint.new(1, .5),
		}),
	}, bar)
	return bar, g
end

local circle, newColor, Preview, encodeColor, decodeColor, buildPicker
do -- bloque propio: sus locales no cuentan en el pico de registros (tools/wrap_block.js)
function circle(frame)
	frame:FindFirstChildOfClass("UICorner").CornerRadius = UDim.new(1, 0)
	return frame
end

--[[ ---------------------------------------- Colours --------------------------------------- ]]

function newColor(c, alpha, c2, alpha2, gradient)
	return { a = c, aa = alpha or 1, b = c2 or c, ba = alpha2 or alpha or 1, gradient = gradient or false }
end
Library.Color = newColor

function Preview(parent, x, y, size, radius, scope)
	local base = Box(parent, x, y, size, size, Color3.fromRGB(204, 204, 204), radius)
	local cell = math.max(2, size / 3)
	local checks = {}
	for row = 0, 2 do
		for col = 0, 2 do
			if (row + col) % 2 == 1 then
				local px, py = math.floor(col * cell), math.floor(row * cell)
				table.insert(checks, Box(base, px, py, math.ceil(cell), math.ceil(cell), Color3.fromRGB(128, 128, 128)))
			end
		end
	end
	local fill = Box(base, 0, 0, size, size, White, radius)
	local grad = New("UIGradient", {}, fill)
	local lineFrame = Box(base, 1, 1, size - 2, size - 2, nil, math.max(radius - 1, 1))
	local line = Stroke(lineFrame)
	return base, function(value, alpha)
		alpha = alpha or scope.alpha
		local c1, a1 = value.gradient and value.b or value.a, value.gradient and value.ba or value.aa
		local clear = value.aa < 1 or a1 < 1
		base.BackgroundTransparency = clear and 1 - alpha or 1
		for _, f in checks do f.BackgroundTransparency = clear and 1 - alpha or 1 end
		fill.BackgroundTransparency = 1 - alpha
		grad.Color = ColorSequence.new(value.a, c1)
		grad.Transparency = NumberSequence.new(1 - value.aa, 1 - a1)
		line.Color, line.Transparency = T.SwatchLine, 1 - A.SwatchLine * alpha
	end
end

function encodeColor(col)
	return { c = toHex(col.a), a = col.aa, c2 = toHex(col.b), a2 = col.ba, g = col.gradient }
end

function decodeColor(col, data)
	if type(data) ~= "table" then return end
	col.a = fromHex(data.c) or col.a
	col.b = fromHex(data.c2) or col.b
	col.aa, col.ba = tonumber(data.a) or col.aa, tonumber(data.a2) or col.ba
	col.gradient = data.g == true
end

local function hsv(color)
	local h, s, v = color:ToHSV()
	return h, s, v
end

local function hexOf(c, a)
	return string.format("%02X%02X%02X%02X", round(c.R * 255), round(c.G * 255), round(c.B * 255), round(a * 255))
end

-- Builds the picker's controls into a card. Returns the y the extras start at.
function buildPicker(flow, slots, allowGradient, onChange, onSlot)
	local card, parent, scope = flow.card, flow.parent, flow.scope
	local p0, y0, w = flow.x, flow.y, flow.w
	local slot = 1
	local mode = 0
	local states = {}
	local function state(i)
		local st = states[i]
		if not st then
			st = { h = { 0, 0 }, s = { 0, 0 }, v = { 1, 1 }, stop = 1, grab = nil, synced = {} }
			states[i] = st
		end
		return st
	end
	local redraw
	local view = { init = false, h = 0, a = 1, grad = 0, s = { 0, 0 }, v = { 1, 1 } }

	local top = y0
	local chipFrames, ring, nameLabel
	if #slots > 1 then
		local row_w = #slots * 16 + (#slots - 1) * 9
		local x0 = p0 + round((w - row_w) * 0.5)
		local cy = y0 + 16 + 8
		nameLabel = Box(parent, p0, y0, w, 18)
		nameLabel = New("TextLabel", {
			Text = "", Size = UDim2.fromOffset(w, 18), BackgroundTransparency = 1, FontFace = FontMedium, TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Top,
		}, nameLabel)
		ring = Box(parent, x0 - 3, cy - 3, 22, 22, nil, 6)
		local ringStroke = Stroke(ring, Accent, 1.5)
		chipFrames = {}
		for i, s in slots do
			local cx = x0 + (i - 1) * 25
			local base, paintPreview = Preview(parent, cx, cy, 16, 4, scope)
			local hoverRing = Box(parent, cx - 2, cy - 2, 20, 20, nil, 6)
			local hoverStroke = Stroke(hoverRing, T.Text)
			local ht = Anim(0, 14)
			local function paint()
				paintPreview(s.value)
				hoverStroke.Color, hoverStroke.Transparency = T.Text, 1 - 0.25 * ht.v * scope.alpha
			end
			ht.cb = paint
			scope:paint(paint)
			chipFrames[i] = paint
			Hit(scope, base, {
				hover = function(b) ht:to((b and i ~= slot) and 1 or 0) end,
				click = function()
					slot = i
					setXY(ring, x0 + (i - 1) * 25 - 3, cy - 3)
					nameLabel.Text = tr(slots[i].name or "")
					view.init = false
					if onSlot then onSlot(i) end
					redraw()
				end,
			})
		end
		scope:paint(function()
			ringStroke.Color, ringStroke.Transparency = Accent, 1 - scope.alpha
			nameLabel.TextColor3, nameLabel.TextTransparency = T.Text, 1 - scope.alpha
			nameLabel.Text = tr(slots[slot].name or "")
		end)
		top = cy + 16 + 16
	end

	local svH = round(w * 0.82)
	local sv = Box(parent, p0, top, w, svH, White, 8)
	local svColor = New("UIGradient", {}, sv)
	local svBlack = Box(parent, p0, top, w, svH, Black, 8)
	New("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(1, 0) }, svBlack)

	local function knob(radius)
		local outer = circle(Box(parent, 0, 0, radius * 2, radius * 2, White, 1))
		local shadow = Shadow(outer, 5, 0.55, 1)
		local inner = circle(Box(parent, 0, 0, (radius - 2) * 2, (radius - 2) * 2, White, 1))
		return function(x, y, fill, alpha)
			x, y = round(x), round(y)
			setXY(outer, x - radius, y - radius)
			setXY(inner, x - radius + 2, y - radius + 2)
			outer.BackgroundTransparency = 1 - alpha
			if shadow then shadow.Transparency = 1 - 0.45 * alpha end
			inner.BackgroundColor3, inner.BackgroundTransparency = fill, 1 - alpha
		end
	end

	local link = Box(parent, 0, 0, 0, 0, White)
	local linkShadow = Shadow(link, 3, 0.6, 0)
	local otherKnob = knob(6)
	local mainKnob = knob(7)

	local hueY = top + svH + 14
	local hueBar = Box(parent, p0, hueY, w, 8, White, 4)
	New("UIGradient", { Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromHSV(0, 1, 1)), ColorSequenceKeypoint.new(1 / 6, Color3.fromHSV(1 / 6, 1, 1)),
		ColorSequenceKeypoint.new(2 / 6, Color3.fromHSV(2 / 6, 1, 1)), ColorSequenceKeypoint.new(3 / 6, Color3.fromHSV(3 / 6, 1, 1)),
		ColorSequenceKeypoint.new(4 / 6, Color3.fromHSV(4 / 6, 1, 1)), ColorSequenceKeypoint.new(5 / 6, Color3.fromHSV(5 / 6, 1, 1)),
		ColorSequenceKeypoint.new(1, Color3.fromHSV(0, 1, 1)),
	}) }, hueBar)
	local huePill = Box(parent, 0, hueY - 4, 7, 16, White, 3)
	local hueShadow = Shadow(huePill, 4, 0.65, 1)
	local hueFill = Box(huePill, 1, 1, 5, 14, White, 2)
	local hueHit = Box(parent, p0, hueY - 5, w, 18)

	local alphaY = hueY + 8 + 12
	local alphaBase = Box(parent, p0, alphaY, w, 8, Color3.fromRGB(204, 204, 204), 4)
	local alphaChecks = {}
	for col = 1, math.floor(w / 4) - 2 do
		for row = 0, 1 do
			if (col + row) % 2 == 1 then
				table.insert(alphaChecks, Box(alphaBase, col * 4, row * 4, 4, 4, Color3.fromRGB(128, 128, 128)))
			end
		end
	end
	local alphaFill = Box(parent, p0, alphaY, w, 8, White, 4)
	local alphaGrad = New("UIGradient", { Transparency = NumberSequence.new(1, 0) }, alphaFill)
	local alphaKnob = circle(Box(parent, 0, alphaY - 2, 12, 12, White, 1))
	local alphaKnobShadow = Shadow(alphaKnob, 4, 0.6, 1)
	local alphaHit = Box(parent, p0, alphaY - 5, w, 18)

	local ry = alphaY + 8 + 14
	local rowH = 26
	local fmtChevron = Glyph(parent, "CHEVRON_DOWN", 11)
	local fmtLabel = Label(parent, "HEX", round(p0 + fmtChevron.boxW + 5), capY(ry + 13, 11), 11)
	local fmtHit = Box(parent, p0, ry, round(fmtChevron.boxW + 5 + measure("HEX", 11) + 4), rowH)
	local fmtWidth = fmtChevron.boxW + 5 + measure("HEX", 11)
	local btnW = allowGradient and 22 or 0
	local btnX = p0 + w - btnW
	local pctW = 44
	local pctX = btnX - (allowGradient and 6 or 0) - pctW
	local valX = p0 + fmtWidth + 12
	local valW = math.max(40, pctX - 6 - valX)
	fmtChevron:center(p0 + fmtChevron.boxW * 0.5, ry + 13)
	local valBox = Box(parent, valX, ry, valW, rowH, White, 6)
	local _, previewPaint = Preview(parent, valX + 8, ry + 7, 12, 3, scope)
	local hash = Label(parent, "#", valX + 8 + 12 + 7, capY(ry + 13, 11), 11)
	local textX = valX + 8 + 12 + 7 + measure("#", 11) + 1
	local input = New("TextBox", {
		Text = "", ClearTextOnFocus = false, BackgroundTransparency = 1, FontFace = FontMedium, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(textX, capY(ry + 13, 11)), Size = UDim2.fromOffset(valX + valW - 8 - textX, 15),
		ClipsDescendants = true,
	}, parent)
	local pctBox = Box(parent, pctX, ry, pctW, rowH, White, 6)
	local pctInput = New("TextBox", {
		Text = "100%", ClearTextOnFocus = false, BackgroundTransparency = 1, FontFace = FontMedium, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(pctX, capY(ry + 13, 11)), Size = UDim2.fromOffset(pctW, 15),
	}, parent)
	local gradIcon, gradT
	if allowGradient then
		gradIcon = Glyph(parent, "ADJUST", 13)
		gradIcon:center(btnX + btnW * 0.5, ry + 13)
		gradT = Anim(0, 15)
	end
	local fmtT = Anim(0, 15)

	local function current() return slots[slot].value end
	local function stops(col, i)
		if i == 1 then return col.a, col.aa end
		return col.b, col.ba
	end
	local function setStop(col, i, c, a)
		if i == 1 then col.a, col.aa = c, a else col.b, col.ba = c, a end
	end
	local function sync()
		local st, col = state(slot), current()
		for i = 1, 2 do
			local c, a = stops(col, i)
			local key = hexOf(c, a)
			if st.synced[i] ~= key then
				local h, s, v = hsv(c)
				if s > 0 and v > 0 then st.h[i] = h end
				if v > 0 then st.s[i] = s end
				st.v[i] = v
				st.synced[i] = key
			end
		end
		if not col.gradient then st.stop = 1 end
	end
	local function commit(i)
		local st, col = state(slot), current()
		local c = Color3.fromHSV(st.h[i], st.s[i], st.v[i])
		local _, a = stops(col, i)
		setStop(col, i, c, a)
		st.synced[i] = hexOf(c, a)
		if onChange then onChange(col) end
	end
	local function startGradient(s, v)
		local st, col = state(slot), current()
		col.gradient = true
		st.h[2], st.s[2], st.v[2] = st.h[1], s, v
		col.ba = col.aa
		commit(2)
		st.stop = 2
	end

	local writingInputs = false
	local dragging = false
	local viewTicking = false

	local function drawNow()
		local st, col = state(slot), current()
		local a = scope.alpha
		local d = st.stop
		local svX = function(i) return p0 + view.s[i] * w end
		local svY = function(i) return top + (1 - view.v[i]) * svH end
		local hueColor = Color3.fromHSV(view.h, 1, 1)
		svColor.Color = ColorSequence.new(White, hueColor)
		sv.BackgroundTransparency, svBlack.BackgroundTransparency = 1 - a, 1 - a
		local shown = Color3.fromHSV(view.h, view.s[d], view.v[d])
		mainKnob(svX(d), svY(d), shown, a)
		otherKnob(svX(3 - d), svY(3 - d), select(1, stops(col, 3 - d)), a * view.grad)
		local x1, y1, x2, y2 = svX(1), svY(1), svX(2), svY(2)
		local dx, dy = x2 - x1, y2 - y1
		local len = math.sqrt(dx * dx + dy * dy)
		if view.grad > 0.01 and len > 14 then
			link.Visible = true
			link.Size = UDim2.fromOffset(round(len - 14), 2)
			link.AnchorPoint = Vector2.new(0.5, 0.5)
			link.Position = UDim2.fromOffset(round((x1 + x2) * 0.5), round((y1 + y2) * 0.5))
			link.Rotation = math.deg(math.atan2(dy, dx))
			link.BackgroundTransparency = 1 - 0.95 * view.grad * a
			if linkShadow then linkShadow.Transparency = 1 - 0.4 * view.grad * a end
		else
			link.Visible = false
		end

		hueBar.BackgroundTransparency = 1 - a
		local hx = clamp(p0 + view.h * w, p0 + 3.5, p0 + w - 3.5)
		setXY(huePill, round(hx - 3.5), hueY - 4)
		huePill.BackgroundTransparency = 1 - a
		if hueShadow then hueShadow.Transparency = 1 - 0.35 * a end
		hueFill.BackgroundColor3, hueFill.BackgroundTransparency = hueColor, 1 - a

		alphaBase.BackgroundTransparency = 1 - a
		for _, f in alphaChecks do f.BackgroundTransparency = 1 - a end
		alphaFill.BackgroundColor3, alphaFill.BackgroundTransparency = shown, 1 - a
		local ax = clamp(p0 + view.a * w, p0 + 6, p0 + w - 6)
		setXY(alphaKnob, round(ax - 6), alphaY - 2)
		alphaKnob.BackgroundTransparency = 1 - a
		if alphaKnobShadow then alphaKnobShadow.Transparency = 1 - 0.4 * a end

		local fmtCol = T.Disabled:Lerp(T.Text, fmtT.v)
		fmtChevron:paint(fmtCol, a)
		fmtLabel.TextColor3, fmtLabel.TextTransparency = fmtCol, 1 - a
		fmtLabel.Text = mode == 0 and "HEX" or "RGB"
		valBox.BackgroundColor3, valBox.BackgroundTransparency = T.FieldBg, 1 - A.FieldBg * a
		pctBox.BackgroundColor3, pctBox.BackgroundTransparency = T.FieldBg, 1 - A.FieldBg * a
		previewPaint(col, a)
		hash.TextColor3, hash.TextTransparency = T.Disabled, (mode == 0) and 1 - a or 1
		input.TextColor3, input.TextTransparency = T.Text, 1 - a
		pctInput.TextColor3, pctInput.TextTransparency = T.Text, 1 - a
		if gradIcon then gradIcon:paint(col.gradient and Accent or T.Disabled:Lerp(T.Text, gradT.v), a) end
		if chipFrames then chipFrames[slot]() end
	end

	redraw = function()
		sync()
		local st, col = state(slot), current()
		local d = st.stop
		local c, ca = stops(col, d)
		writingInputs = true
		if not input:IsFocused() then
			input.Text = mode == 0 and hexOf(c, ca) or string.format("%d, %d, %d", round(c.R * 255), round(c.G * 255), round(c.B * 255))
		end
		if not pctInput:IsFocused() then pctInput.Text = round(ca * 100) .. "%" end
		writingInputs = false
		local gradTarget = col.gradient and 1 or 0
		if not view.init or dragging then
			view.h, view.a = st.h[d], ca
			for i = 1, 2 do view.s[i], view.v[i] = st.s[i], st.v[i] end
			if not view.init then view.grad = gradTarget end
			view.init = true
			if dragging then view.grad = gradTarget end
			drawNow()
			return
		end
		if viewTicking then return end
		viewTicking = true
		Run(function(dt)
			local ease = 1 - math.exp(-18 * dt)
			local st2, col2 = state(slot), current()
			local d2 = st2.stop
			local _, ca2 = stops(col2, d2)
			local dh = st2.h[d2] - view.h
			if dh > 0.5 then dh -= 1 elseif dh < -0.5 then dh += 1 end
			view.h = (view.h + dh * ease) % 1
			if math.abs(dh) < 0.0005 then view.h = st2.h[d2] end
			local settled = math.abs(dh) < 0.0005
			local function approach(value, target)
				local nextValue = value + (target - value) * ease
				if math.abs(target - nextValue) < 0.0005 then return target end
				settled = false
				return nextValue
			end
			view.a = approach(view.a, ca2)
			for i = 1, 2 do view.s[i] = approach(view.s[i], st2.s[i]); view.v[i] = approach(view.v[i], st2.v[i]) end
			view.grad = approach(view.grad, col2.gradient and 1 or 0)
			drawNow()
			if settled then
				viewTicking = false
				return false
			end
			return true
		end)
	end

	local function fieldValues(point)
		local at = toStage(point) - toStage(sv.AbsolutePosition)
		return sat(at.X / w), 1 - sat(at.Y / svH)
	end
	local function nearKnob(point, i)
		local st = state(slot)
		local at = toStage(point) - toStage(sv.AbsolutePosition)
		local dx, dy = at.X - st.s[i] * w, at.Y - (1 - st.v[i]) * svH
		return dx * dx + dy * dy <= 11 * 11
	end
	Hit(scope, sv, {
		down = function(point)
			local st, col = state(slot), current()
			st.grab = st.stop
			if col.gradient then
				local n = nearKnob(point, 1) and 1 or (nearKnob(point, 2) and 2)
				if n then st.grab = n end
			end
			st.stop = st.grab
			dragging = true
			st.s[st.grab], st.v[st.grab] = fieldValues(point)
			commit(st.grab)
			redraw()
		end,
		drag = function(point)
			local st = state(slot)
			if st.grab then
				st.s[st.grab], st.v[st.grab] = fieldValues(point)
				commit(st.grab)
				redraw()
			end
		end,
		up = function() dragging = false; state(slot).grab = nil end,
		right = function(point)
			if not allowGradient then return end
			local st, col = state(slot), current()
			local ms, mv = fieldValues(point)
			if not col.gradient then
				startGradient(ms, mv)
			elseif nearKnob(point, 2) then
				col.gradient = false
				st.stop = 1
			elseif nearKnob(point, 1) then
				col.a, col.aa = col.b, col.ba
				st.h[1], st.s[1], st.v[1] = st.h[2], st.s[2], st.v[2]
				st.synced[1] = hexOf(col.a, col.aa)
				col.gradient = false
				st.stop = 1
			else
				st.s[2], st.v[2] = ms, mv
				commit(2)
				st.stop = 2
			end
			if onChange then onChange(col) end
			redraw()
		end,
	})
	local function barValue(point)
		return sat((toStage(point).X - toStage(hueBar.AbsolutePosition).X) / w)
	end
	Hit(scope, hueHit, {
		down = function(point)
			dragging = true
			local st = state(slot)
			st.h[st.stop] = clamp(barValue(point), 0, 0.9999)
			commit(st.stop)
			redraw()
		end,
		drag = function(point)
			local st = state(slot)
			st.h[st.stop] = clamp(barValue(point), 0, 0.9999)
			commit(st.stop)
			redraw()
		end,
		up = function() dragging = false end,
	})
	local function setAlpha(value)
		local st, col = state(slot), current()
		local c = stops(col, st.stop)
		setStop(col, st.stop, c, value)
		st.synced[st.stop] = hexOf(c, value)
		if onChange then onChange(col) end
		redraw()
	end
	Hit(scope, alphaHit, {
		down = function(point) dragging = true; setAlpha(barValue(point)) end,
		drag = function(point) setAlpha(barValue(point)) end,
		up = function() dragging = false end,
	})
	Hit(scope, fmtHit, {
		hover = function(b) fmtT:to(b and 1 or 0) end,
		click = function() mode = 1 - mode; redraw() end,
	})
	fmtT.cb = function() drawNow() end

	Hit(scope, input, {})
	Hit(scope, pctInput, {})
	input:GetPropertyChangedSignal("Text"):Connect(function()
		if writingInputs or not input:IsFocused() then return end
		local st, col = state(slot), current()
		local c, a = stops(col, st.stop)
		if mode == 0 then
			local digits = string.gsub(input.Text, "[^%x]", "")
			if #digits == 6 or #digits == 8 then
				local v = tonumber(digits, 16)
				local alpha = a
				if #digits == 8 then alpha = (v % 256) / 255; v = v // 256 end
				setStop(col, st.stop, Color3.fromRGB((v // 65536) % 256, (v // 256) % 256, v % 256), alpha)
				if onChange then onChange(col) end
				redraw()
			end
		else
			local numbers = {}
			for n in string.gmatch(input.Text, "%d+") do table.insert(numbers, math.min(tonumber(n), 255)) end
			if #numbers == 3 then
				setStop(col, st.stop, Color3.fromRGB(numbers[1], numbers[2], numbers[3]), a)
				if onChange then onChange(col) end
				redraw()
			end
		end
	end)
	input.FocusLost:Connect(function() redraw() end)
	pctInput.FocusLost:Connect(function()
		local n = tonumber(string.match(pctInput.Text, "%d+"))
		if n then setAlpha(math.min(n, 100) / 100) else redraw() end
	end)
	Wheel(scope, pctBox, function(z)
		local st, col = state(slot), current()
		local _, a = stops(col, st.stop)
		setAlpha(sat(a + z * 0.01))
	end)
	if allowGradient then
		local gradHit = Box(parent, btnX, ry, btnW, rowH)
		Hit(scope, gradHit, {
			hover = function(b) gradT:to(b and 1 or 0) end,
			click = function()
				local st, col = state(slot), current()
				if col.gradient then
					col.gradient = false
					st.stop = 1
					if onChange then onChange(col) end
				else
					startGradient(st.s[1], st.v[1] > 0.5 and st.v[1] - 0.4 or st.v[1] + 0.4)
				end
				redraw()
			end,
		})
		gradT.cb = function() drawNow() end
	end

	scope:paint(function()
		if view.init then drawNow() end
	end)
	card.onOpen = function()
		view.init = false
		redraw()
	end
	return ry + rowH, ry + rowH + 12
end
end

--[[ ---------------------------------------- Rows ------------------------------------------ ]]

local Flow = {}
Flow.__index = Flow

local function newFlow(o)
	return setmetatable({
		parent = o.parent, scope = o.scope, x = o.x or 0, y = o.y or 0, w = o.w, rw = o.rw or o.w, spacing = o.spacing or 0,
		separators = o.separators or false, card = o.card, level = o.level or 0, started = false, search = o.search, win = o.win,
		path = o.path or "", store = o.store, hostRight = o.hostRight, trail = 0,
	}, Flow)
end

function Flow:rowBegin()
	if self.separators and self.started then
		local line = Box(self.parent, self.x, self.y, self.rw, 1, T.Separator)
		self.scope:paint(function()
			line.BackgroundColor3, line.BackgroundTransparency = T.Separator, 1 - self.scope.alpha
		end)
		self.y += self.spacing
	end
	self.started = true
end

function Flow:advance(height)
	self.y += height + self.spacing
	self.trail = 0
end

-- Where the content really ends, without the gap left after the last section.
function Flow:bottom() return self.y - self.trail end

-- 1.5.0: la entrada lleva la descripción (tip) y la clave estable del control (la misma base que su id en perfiles)
function Flow:note(label, tip)
	if not self.search then return nil end
	local entry = { label = label, box = self.search.box, tabName = self.search.tabName, tab = self.search.tab, flash = 0, paint = nil,
		tip = type(tip) == "string" and tip or nil, key = (self.path or "?") .. "/" .. tostring(label), group = "controls" }
	table.insert(self.search.win.searchIndex, entry)
	return entry
end

-- Every control with a flag is saved in configs. A control inside a card that has not been built
-- yet picks its saved value up from `pending` the moment it is created.
function Flow:flag(o, name, get, set)
	local store = self.store
	if not store or o.Flag == false then return nil end
	local base = o.Flag or (self.path .. "/" .. name)
	local count = (store.used[base] or 0) + 1
	store.used[base] = count
	local id = count > 1 and (base .. "#" .. count) or base
	store.controls[id] = { get = get, set = set }
	local waiting = store.pending[id]
	if waiting ~= nil then
		store.pending[id] = nil
		set(waiting)
	end
	return id
end

function Flow:changed()
	if self.store and self.store.onChange then self.store.onChange() end
end

local function flashColor(color, entry)
	if entry and entry.flash > 0 then return color:Lerp(Accent, math.min(1, entry.flash / 0.7)) end
	return color
end

local function splitIcon(name)
	local icon, text = string.match(name, "^%[(.-)%]%s*(.*)$")
	return icon, text or name
end

-- Same slot a colour swatch uses: just left of the toggle about to be drawn.
function Flow:swatchRect()
	return self.rw - 30 - 8 - 15, 5
end

function Flow:makeSwatch(row, x, y, value, o)
	local slots = o.slots or { { name = o.name, value = value } }
	local current = slots[1].value
	local size = 15
	local base, paintPreview = Preview(row, x, y, size, 4, self.scope)
	local ring = Box(row, x - 1, y - 1, size + 2, size + 2, nil, 5)
	local ringStroke = Stroke(ring)
	local hot = Anim(0, 15)
	local scope = self.scope
	local function paint()
		paintPreview(current)
		ringStroke.Color = White
		ringStroke.Transparency = 1 - 0.35 * hot.v * scope.alpha
	end
	hot.cb = paint
	scope:paint(paint)
	local level, win, path, store = self.level, self.win, self.path, self.store
	local cardObject
	local flow = self
	local function changed(col)
		paint()
		if o.onChange then o.onChange(col) end
		flow:changed()
	end
	local function ensure()
		if cardObject then return cardObject end
		local allow = o.allowGradient ~= false
		cardObject = newCard({
			width = 274, padding = 16, name = "ColorPicker",
			build = function(card)
				local inner = newFlow({ parent = card.content, scope = card.scope, x = 16, y = 16, w = 242, rw = 240, card = card, level = card.level, win = win, path = path .. "/" .. (o.name or "Color"), store = store })
				local bottom, lineY = buildPicker(inner, slots, allow, changed, function(i)
					current = slots[i].value
					paint()
				end)
				local height = bottom
				inner.y = bottom + 20
				if o.extras then
					local line = Box(card.content, 16, lineY, 242, 1, T.PopupBorder)
					card.scope:paint(function()
						line.BackgroundColor3, line.BackgroundTransparency = T.PopupBorder, 1 - 0.55 * card.scope.alpha
					end)
					o.extras(inner)
					height = inner:bottom()
				end
				card:setHeight(height + 16)
			end,
			place = function(card)
				local at = toStage(base.AbsolutePosition)
				local view = viewport()
				local right = at.X + size + 12 + 274 <= view.X - 10
				local x0 = right and at.X + size + 12 or at.X - 12 - 274
				return keepOnScreen(card, x0, at.Y - 18)
			end,
		})
		return cardObject
	end
	Hit(scope, base, {
		hover = function(b) hot:to(b and 1 or 0) end,
		click = function()
			ensure():open(level)
			paint()
		end,
	})
	for _, slot in slots do
		local suffix = o.slots and ("." .. slot.name) or ".Color"
		self:flag(o, (o.name or "Color") .. suffix, function() return encodeColor(slot.value) end, function(data)
			decodeColor(slot.value, data)
			paint()
		end)
	end
	return paint
end

function Flow:dotsButton(row, x, y, o)
	local rect = Box(row, x - 3, y - 2, 21, 19, White, 6)
	local dots = {}
	for i = -1, 1 do dots[i] = circle(Box(rect, 9 + i * 4, 8, 3, 3, White, 1)) end
	local t = Anim(0, 15)
	local isUp, hovered = false, false
	local scope = self.scope
	local function paint()
		local a = scope.alpha
		rect.BackgroundColor3 = T.FrameInactive
		rect.BackgroundTransparency = 1 - 0.85 * t.v * a
		local col = T.Disabled:Lerp(T.Text, math.max(t.v, isUp and 1 or 0))
		for _, d in dots do d.BackgroundColor3, d.BackgroundTransparency = col, 1 - a end
	end
	t.cb = paint
	scope:paint(paint)
	local level, win, path, store = self.level, self.win, self.path, self.store
	local width = o.width or 240
	local card
	Hit(scope, rect, {
		hover = function(b)
			hovered = b
			t:to((b or isUp) and 1 or 0)
		end,
		click = function()
			if not card then
				card = newCard({
					width = width, name = "Options",
					build = function(c)
						local flow = newFlow({ parent = c.content, scope = c.scope, x = 10, y = 10, w = width - 20, rw = math.min(240, width - 20), card = c, level = c.level, win = win, path = path .. "/" .. (o.name or "Options") .. " options", store = store })
						o.build(flow)
						c:setHeight(flow:bottom() + 10)
					end,
					place = function(c)
						local at = toStage(rect.AbsolutePosition)
						return placeBeside(c, Vector2.new(at.X + 21, at.Y + 9))
					end,
				})
				card.onState = function(state)
					isUp = state
					t:to((state or hovered) and 1 or 0)
					paint()
				end
			end
			card:open(level)
		end,
	})
end

function Flow:Toggle(o)
	self:rowBegin()
	local W, scope, top = self.rw, self.scope, self.y
	local icon, text = splitIcon(o.Name)
	local value = o.Default == true
	local row = Box(self.parent, self.x, top, W, 25)
	local entry = self:note(text, o.Tip)
	local labelRight = W - 30 - 8 - 10 -- 10 px para el punto de estado
	if o.Color then
		local sx, sy = self:swatchRect()
		self:makeSwatch(row, sx, sy, o.Color, { name = text, extras = o.ColorExtras, onChange = o.ColorChanged, Flag = o.Flag and (o.Flag .. ".Color") or nil })
		labelRight = sx - 8
	elseif o.Options then
		local sx, sy = self:swatchRect()
		self:dotsButton(row, sx, sy, { build = o.Options, width = o.OptionsWidth, name = text })
		labelRight = sx - 11
	end
	local hover, on = Anim(0, 15), Anim(value and 1 or 0, 12)
	local paintSwitch = Switch(row, W - 30, 3, scope)
	local textX = 0
	local iconShape
	if icon then
		iconShape = Glyph(row, icon, 13.07)
		iconShape:center(7, 12.5)
		textX = 18
	end
	local label = ScrollText(row, textX, 0, labelRight - textX, 25, 12)
	-- Punto de estado (1.5.0): el interruptor es la INTENCIÓN; el punto, el estado REAL que informa el hub
	-- (Components): verde en marcha, ámbar esperando, rojo error, gris no disponible. Sin estado, no se ve.
	local dot = Box(row, W - 30 - 11, 10, 6, 6, T.Muted, 3)
	local status = nil
	local function paint()
		local t = math.max(on.v, hover.v)
		local color = flashColor(T.LabelOff:Lerp(T.LabelOn, t), entry)
		if status == "Unavailable" then color = T.Disabled end
		local token = status and Library.Tokens.status[status]
		dot.Visible = token ~= nil and not (status == "Disabled" and not value)
		if token then dot.BackgroundColor3, dot.BackgroundTransparency = T[token] or T.Muted, 1 - scope.alpha end
		label:set(tr(text))
		label:paint(color, scope.alpha)
		if iconShape then iconShape:paint(color, scope.alpha) end
		paintSwitch(on.v)
	end
	hover.cb, on.cb = paint, paint
	if entry then entry.paint = paint end
	scope:paint(paint)
	local flow = self
	local object = {}
	function object:Set(state, silent)
		value = state == true
		on:to(value and 1 or 0)
		if o.Callback and not silent then o.Callback(value) end
		flow:changed()
	end
	function object:Get() return value end
	-- Estado real (Components): "Running", "Waiting", "Error", "Unavailable"… o nil para ocultar el punto
	function object:SetStatus(state)
		if status == state then return end
		status = state
		paint()
	end
	Hit(scope, row, {
		hover = function(b) hover:to(b and 1 or 0); label:hover(b) end,
		click = function() object:Set(not value) end,
		tip = o.Tip ~= false and { text, o.Tip or "Click to enable or disable this option." } or nil,
	})
	self:flag(o, text, function() return value end, function(v) object:Set(v == true) end)
	self:advance(25)
	return object
end

-- Label, track and a value box you can type into. The same row in the menu and in every card.
function Flow:Slider(o)
	self:rowBegin()
	local W, scope, top = self.rw, self.scope, self.y
	local lo, hi = o.Min or 0, o.Max or 100
	local decimals = o.Decimals or 0
	local step = 10 ^ -decimals
	local format = o.Format or (decimals > 0 and ("%." .. decimals .. "f") or "%d")
	local value = clamp(o.Default or lo, lo, hi)
	local row = Box(self.parent, self.x, top, W, 25)
	local entry = self:note(o.Name, o.Tip)
	local numberW = 38
	local right = W - numberW - 12
	local left = math.floor(math.max(math.min(82, W * 0.45), right - 74))
	if right < left + 36 then left = math.floor(math.max(0, right - 36)) end
	local trackW = right - left
	local track = SoftBar(row, left, 10, trackW, T.FieldBg)
	local fill = SoftBar(row, left, 10, 0, Accent)
	local knob = circle(Box(row, left - 6, 6, 13, 13, White, 1))
	local label = ScrollText(row, 0, 0, left - 8, 25, 12)
	local box = Box(row, W - numberW, 2, numberW, 21, T.FieldBg, 6)
	local boxLine = Box(box, 1, 1, numberW - 2, 19, nil, 5)
	local stroke = Stroke(boxLine, T.Border)
	local input = New("TextBox", {
		Text = "", BackgroundTransparency = 1, BorderSizePixel = 0, ClearTextOnFocus = false, FontFace = FontMedium, TextSize = 12, Size = UDim2.fromOffset(numberW, 16),
		Position = UDim2.fromOffset(0, capY(10.5, 12)), TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Top,
	}, box)
	local hoverA, focusA, fillA = Anim(0, 15), Anim(0, 15), nil
	local editing = false
	local function shown() return string.format(format, value) end
	local function paint()
		local a = scope.alpha
		local x = fillA.v
		local color = flashColor(T.Disabled:Lerp(T.Text, math.max(x > 0.1 and 1 or 0, hoverA.v)), entry)
		label:set(tr(o.Name))
		label:paint(color, a)
		track.BackgroundColor3, track.BackgroundTransparency = T.FieldBg, 1 - A.FieldBg * a
		fill.BackgroundColor3, fill.BackgroundTransparency = Accent, 1 - a
		setWH(fill, round(x), 5)
		fill.Visible = x > 0.1
		setXY(knob, round(left + x - 6.5), 6)
		knob.BackgroundTransparency = 1 - a
		box.BackgroundColor3, box.BackgroundTransparency = T.FieldBg, 1 - A.FieldBg * a
		stroke.Color, stroke.Transparency = T.Border:Lerp(Accent, focusA.v), 1 - a
		local text = editing and input.Text or shown()
		local boxW = math.max(numberW, math.ceil(measure(text ~= "" and text or "0", 12)) + 14)
		if box.Size.X.Offset ~= boxW then
			setWH(box, boxW, 21)
			setXY(box, W - boxW, 2)
			setWH(boxLine, boxW - 2, 19)
			setWH(input, boxW, 16)
		end
		if not editing then input.Text = text end
		input.TextColor3, input.TextTransparency = T.Text, 1 - a
	end
	fillA = Anim(0, 15, paint, 0.05)
	hoverA.cb, focusA.cb = paint, paint
	if entry then entry.paint = paint end

	local flow = self
	local object = {}
	function object:Set(new, silent)
		new = clamp(round(new / step) * step, lo, hi)
		if new == value then
			paint()
			return
		end
		value = new
		fillA:to((value - lo) / math.max(hi - lo, 1e-6) * trackW)
		if o.Callback and not silent then o.Callback(value) end
		flow:changed()
		paint()
	end
	function object:Get() return value end
	fillA:set((value - lo) / math.max(hi - lo, 1e-6) * trackW)
	scope:paint(paint)

	input.Focused:Connect(function()
		editing = true
		input.Text = string.format(decimals > 0 and ("%." .. decimals .. "f") or "%d", value)
		input.CursorPosition = #input.Text + 1
		input.SelectionStart = 1
		focusA:to(1)
	end)
	input.FocusLost:Connect(function()
		editing = false
		local typed = tonumber((string.gsub(input.Text, "[^%d%.%-]", "")))
		if typed then object:Set(typed) end
		input.Text = shown()
		focusA:to(0)
		paint()
	end)
	input:GetPropertyChangedSignal("Text"):Connect(function()
		if editing then paint() end
	end)

	local function fromPoint(p)
		local at = toStage(p).X - toStage(row.AbsolutePosition).X
		object:Set(lo + sat((at - left) / trackW) * (hi - lo))
	end
	Hit(scope, box, { hover = function(b) hoverA:to(b and 1 or 0) end })
	Hit(scope, Box(row, left - 7, 0, trackW + 14, 25), {
		down = fromPoint,
		drag = fromPoint,
		hover = function(b) hoverA:to(b and 1 or 0) end,
	})
	Hit(scope, row, {
		hover = function(b) hoverA:to(b and 1 or 0); label:hover(b) end,
		tip = o.Tip and { o.Name, o.Tip } or nil,
	})
	Wheel(scope, row, function(z)
		if editing then return end
		local notches = z > 0 and math.ceil(z) or math.floor(z)
		object:Set(value + notches * math.max(step, math.floor((hi - lo) * 0.01 + 0.5)))
	end)
	self:flag(o, o.Name, function() return value end, function(v)
		if type(v) == "number" then object:Set(v) end
	end)
	self:advance(25)
	return object
end

do -- bloque propio: sus locales no cuentan en el pico de registros (tools/wrap_block.js)
local function chevronShape(parent, up)
	local d = up and -1 or 1
	return Shape(parent, strokeContours({ -3, -1.5 * d, 0, 1.5 * d, 3, -1.5 * d }, 1.15), 1, up and "CHEV_U" or "CHEV_D")
end

local function selectableRows(card, listW, options, isSelected, onPick, indent)
	local rows = {}
	for i, option in options do
		local row = Box(card.content, 6, 6 + (i - 1) * 29, listW - 12, 25)
		local plate = Box(row, 0, 0, listW - 12, 25, T.FrameInactive, 6)
		local check = Glyph(row, "CHECK", 11.2)
		local t, hover = Anim(isSelected(i) and 1 or 0, 12), Anim(0, 15)
		local label = Label(row, "", 28, capY(12.5, 12), 12)
		local function paint()
			local a = card.scope.alpha
			plate.BackgroundColor3, plate.BackgroundTransparency = T.FrameInactive, 1 - hover.v * 0.6 * a
			check:paint(Accent, t.v * a)
			check:center(15 + (1 - t.v) * -4, 12.5)
			label.TextColor3 = T.Disabled:Lerp(T.Text, math.max(t.v, hover.v))
			label.TextTransparency = 1 - a
			setText(label, tr(option), 12)
			if indent then setXY(label, round(10 + 18 * indent.v), capY(12.5, 12)) end
		end
		t.cb, hover.cb = paint, paint
		card.scope:paint(paint)
		Hit(card.scope, row, {
			hover = function(b) hover:to(b and 1 or 0) end,
			click = function() onPick(i) end,
		})
		rows[i] = { refresh = function() t:to(isSelected(i) and 1 or 0) end, paint = paint }
	end
	return rows
end

local function dropdown(self, o, multi)
	self:rowBegin()
	local W, scope, level = self.rw, self.scope, self.level
	local options = o.Options
	local row = Box(self.parent, self.x, self.y, W, 25)
	local entry = self:note(o.Name, o.Tip)
	local comboW = math.min(130, math.max(70, W - 72))
	if o.Color then self:makeSwatch(row, W - comboW - 8 - 15, 5, o.Color, { name = o.Name }) end
	local bb = Box(row, W - comboW, 2, comboW, 21, T.FieldBg, 8)
	local line = Stroke(Box(bb, 1, 1, comboW - 2, 19, nil, 7), T.Border)
	local arrowDown = chevronShape(bb, false):at(comboW - 11, 10.5)
	local arrowUp = chevronShape(bb, true):at(comboW - 11, 10.5)
	local preview = ScrollText(bb, 10, 0, comboW - 34, 21, 12)
	local label = ScrollText(row, 0, 0, W - comboW - 8 - (o.Color and 23 or 0), 25, 12)
	local index, chosen = multi and 1 or (o.Default or 1), {}
	if multi then
		for i in options do chosen[i] = o.Default and o.Default[i] or false end
	end
	local hover, openA = Anim(0, 15), Anim(0, 15)
	local function isSelected(i)
		if multi then return chosen[i] end
		return i == index
	end
	local function anySelected()
		for i in options do
			if chosen[i] then return true end
		end
		return false
	end
	local function previewText()
		if not multi then return tr(options[index] or "") end
		local parts = {}
		for i, option in options do
			if chosen[i] then table.insert(parts, tr(option)) end
		end
		return #parts > 0 and table.concat(parts, ", ") or tr("Select")
	end
	local function paint()
		local a = scope.alpha
		local color = T.Disabled:Lerp(T.Text, math.max(openA.v, hover.v))
		bb.BackgroundColor3, bb.BackgroundTransparency = T.FieldBg, 1 - A.FieldBg * a
		line.Color, line.Transparency = T.Border, 1 - a
		arrowDown:paint(T.Text, a * (1 - openA.v))
		arrowUp:paint(T.Text, a * openA.v)
		preview:set(previewText())
		preview:paint(color, a)
		label:set(tr(o.Name))
		label:paint(flashColor(color, entry), a)
	end
	hover.cb, openA.cb = paint, paint
	if entry then entry.paint = paint end
	scope:paint(paint)

	local card, rows, indent, offset
	local function centreOffset() return 7 + (index - 0.5) * 29 end
	local function refresh()
		if rows then
			for _, r in rows do r.refresh() end
		end
		if indent then indent:to(anySelected() and 1 or 0) end
		if offset and not multi then offset:to(centreOffset()) end
		paint()
	end
	local flow = self
	local object = {}
	local function fire()
		if o.Callback then
			if multi then o.Callback(chosen) else o.Callback(options[index], index) end
		end
		flow:changed()
	end
	function object:Set(new, silent)
		if multi then
			for i in options do chosen[i] = new[i] == true end
		else
			index = new
		end
		refresh()
		if not silent then fire() end
	end
	function object:Get()
		if multi then return chosen end
		return options[index], index
	end
	local function ensure()
		if card then return card end
		local listW = comboW
		for _, option in options do listW = math.max(listW, math.ceil(measure(tr(option), 12)) + 46) end
		local height = 12 + #options * 25 + (#options - 1) * 4
		card = newCard({
			width = listW, rounding = 10, padding = 6, name = multi and "MultiList" or "ComboList",
			build = function(c)
				if multi then indent = Anim(anySelected() and 1 or 0, 12) end
				rows = selectableRows(c, listW, options, isSelected, function(i)
					if multi then
						chosen[i] = not chosen[i]
					else
						index = i
					end
					refresh()
					fire()
				end, indent)
				if indent then
					indent.cb = function()
						for _, r in rows do r.paint() end
					end
				end
				c:setHeight(height)
			end,
			place = function(c)
				local at, size = toStage(bb.AbsolutePosition), bb.AbsoluteSize / Scale
				local hostEdge = flow.hostRight and flow.hostRight() or at.X + size.X
				local x = math.max(at.X + size.X, hostEdge) + 8
				local middle = at.Y + size.Y * 0.5
				if multi then return keepOnScreen(c, x, middle - height * 0.5, 3) end
				c.middle = middle
				offset = offset or Anim(0, 12, function(v)
					c.base = Vector2.new(c.base.X, c.middle - v)
					c:apply()
				end)
				local target = centreOffset()
				offset.v, offset.t = target, target
				return keepOnScreen(c, x, middle - target, 3)
			end,
		})
		card.onState = function(state) openA:to(state and 1 or 0) end
		return card
	end
	Hit(scope, bb, {
		hover = function(b) hover:to(b and 1 or 0); preview:hover(b) end,
		click = function() ensure():open(level) end,
		tip = o.Tip and { o.Name, o.Tip } or nil,
	})
	self:flag(o, o.Name, function()
		if not multi then return options[index] end
		local names = {}
		for i, option in options do
			if chosen[i] then table.insert(names, option) end
		end
		return names
	end, function(v)
		if multi then
			if type(v) ~= "table" then return end
			local picked = {}
			for i, option in options do picked[i] = table.find(v, option) ~= nil end
			object:Set(picked)
		else
			local i = type(v) == "number" and v or table.find(options, v)
			if i and options[i] then object:Set(i) end
		end
	end)
	self:advance(25)
	return object
end

function Flow:Combo(o) return dropdown(self, o, false) end
function Flow:Multi(o) return dropdown(self, o, true) end

-- A row with a chevron that opens a card beside itself.
function Flow:SubMenu(o)
	self:rowBegin()
	local W, scope, level, top = self.rw, self.scope, self.level, self.y
	local row = Box(self.parent, self.x, top, W, 25)
	local entry = self:note(o.Name, o.Tip)
	local t = Anim(0, 15)
	local chevron = Glyph(row, "CHEVRON_RIGHT", 14)
	chevron:center(W - 4 - chevron.boxW * 0.5, 12.5)
	local label = ScrollText(row, 0, 0, W - 4 - chevron.boxW - 8, 25, 12)
	local isUp, hovered = false, false
	local function paint()
		local a = scope.alpha
		local color = flashColor(T.Disabled:Lerp(T.Text, t.v), entry)
		label:set(tr(o.Name))
		label:paint(color, a)
		chevron:paint(color, a)
	end
	t.cb = paint
	if entry then entry.paint = paint end
	scope:paint(paint)
	local width = o.Width or 240
	local flow = self
	local card
	local function ensure()
		if card then return card end
		card = newCard({
			width = width, name = o.Name,
			build = function(c)
				local title = Label(c.content, "", 13, capY(20, 14), 14, FontSemi)
				c.scope:paint(function()
					setText(title, tr(o.Name), 14, FontSemi)
					title.TextColor3, title.TextTransparency = T.Text, 1 - c.scope.alpha
				end)
				local inner = newFlow({ parent = c.content, scope = c.scope, x = 10, y = 36, w = width - 20, rw = math.min(240, width - 20), card = c, level = c.level, win = flow.win, path = flow.path .. "/" .. o.Name, store = flow.store })
				o.Build(inner)
				c:setHeight(inner:bottom() + 10)
			end,
			place = function(c, click) return placeBeside(c, click) end,
		})
		card.onState = function(state)
			isUp = state
			t:to((state or hovered) and 1 or 0)
		end
		return card
	end
	Hit(scope, row, {
		hover = function(b)
			hovered = b
			t:to((b or isUp) and 1 or 0)
			label:hover(b)
		end,
		click = function(p)
			if o.Callback then o.Callback() end
			if o.Build then ensure():open(level, toStage(p)) end
		end,
		tip = { o.Name, o.Tip or "Open this section to adjust its settings." },
	})
	self:advance(25)
	return { card = ensure }
end

-- A row of its own: label left, colour swatch right.
function Flow:Color(o)
	self:rowBegin()
	local W, scope, top = self.rw, self.scope, self.y
	local row = Box(self.parent, self.x, top, W, 25)
	local entry = self:note(o.Name, o.Tip)
	local t = Anim(0, 15)
	self:makeSwatch(row, W - 15, 5, o.Color or (o.Slots and o.Slots[1].value), { name = o.Name, slots = o.Slots, extras = o.Extras, onChange = o.Callback })
	local label = ScrollText(row, 0, 0, W - 15 - 8, 25, 12)
	local function paint()
		local color = flashColor(T.Disabled:Lerp(T.Text, t.v), entry)
		label:set(tr(o.Name))
		label:paint(color, scope.alpha)
	end
	t.cb = paint
	if entry then entry.paint = paint end
	scope:paint(paint)
	Hit(scope, row, {
		hover = function(b) t:to(b and 1 or 0); label:hover(b) end,
		tip = { o.Name, o.Tip or (o.Slots and "Click the swatch to edit the colors." or "Click the swatch to edit the color.") },
	})
	self:advance(25)
	return {}
end

--[[ ---------------------------------------- Popup rows ------------------------------------ ]]

function Flow:Separator()
	local line = Box(self.parent, self.x, self.y + 6, self.rw, 1, T.PopupBorder)
	local scope = self.scope
	scope:paint(function()
		line.BackgroundColor3, line.BackgroundTransparency = T.PopupBorder, 1 - 0.55 * scope.alpha
	end)
	self.y += 13
	self.trail = 0
end

function Flow:Space(height) self.y += height end

-- A group inside a card, built like the menu's own group boxes: an inset panel, rows divided by
-- hairlines. Border = false gives plain rows with no panel.
function Flow:Section(o, build)
	local panel = o.Border ~= false
	local padY = panel and (o.Pad or 6) or 0
	local inset = o.Inset or (panel and 12 or 4)
	local top = self.y
	local scope, card = self.scope, self.card
	local plate, stroke, plateLine
	if panel then
		plate = Box(self.parent, self.x, top, self.w, 10, T.Body, 10)
		plateLine = Box(self.parent, self.x + 1, top + 1, self.w - 2, 8, nil, 9)
		stroke = Stroke(plateLine, T.Border)
		scope:paint(function()
			plate.BackgroundColor3, plate.BackgroundTransparency = T.Body, 1 - scope.alpha
			stroke.Color, stroke.Transparency = T.Border, 1 - scope.alpha
		end)
	end
	local inner = newFlow({
		parent = self.parent, scope = scope, x = self.x + inset, y = top + padY, w = self.w - inset * 2, rw = self.w - inset * 2,
		spacing = panel and 4 or 0, separators = panel, card = card, level = self.level, win = self.win, path = self.path, store = self.store,
		hostRight = function()
			local a = toStage(card.frame.AbsolutePosition)
			return a.X + card.width
		end,
	})
	build(inner)
	local contentEnd = inner.y - (inner.started and inner.spacing or 0)
	local total = contentEnd - top + padY
	if panel then
		setWH(plate, self.w, total)
		setWH(plateLine, self.w - 2, total - 2)
	end
	self.y = top + total + 8
	self.trail = 8
end

function Flow:rowImpl(icon, label, lit, deferred)
	local W, scope, top = self.rw, self.scope, self.y
	local row = Box(self.parent, self.x, top, W, 33)
	local t = Anim(0, 15)
	local lx = 4
	local glyph
	if icon then
		glyph = Glyph(row, icon, 14)
		glyph:center(15, 16.5)
		lx = 4 + 22 + 10
	end
	local text = Label(row, "", lx, capY(16.5, 12), 12)
	local hovered, active = false, lit or false
	local handlers = { hover = function(b) hovered = b; t:to((b or active) and 1 or 0) end }
	local state = { row = row, t = t, top = top, W = W, handlers = handlers, setLit = function(on) active = on; t:to((on or hovered) and 1 or 0) end }
	local extra
	local function paint()
		local a = scope.alpha
		if glyph then glyph:paint(T.Disabled:Lerp(T.Text, t.v * 0.6), a) end
		setText(text, tr(label), 12)
		text.TextColor3, text.TextTransparency = T.Text, 1 - a * (0.8 + 0.2 * t.v)
		if extra then extra() end
	end
	t.cb = paint
	state.setExtra = function(fn) extra = fn end
	state.paint = paint
	state.labelEnd = function() return lx + measure(tr(label), 12) end
	if not deferred then scope:paint(paint) end
	self.y += 33
	self.trail = 0
	return state
end

function Flow:Row(icon, label, callback)
	local r = self:rowImpl(icon, label, false)
	r.handlers.click = callback
	Hit(self.scope, r.row, r.handlers)
	return r
end

-- Botón: una fila con fondo suave que se ilumina y ejecuta Callback al pulsarla. o = { Name, Icon, Callback, Tip }
function Flow:Button(o)
	self:rowBegin()
	local W, scope, top = self.rw, self.scope, self.y
	local row = Box(self.parent, self.x, top, W, 25)
	local entry = self:note(o.Name, o.Tip)
	local plate = Box(row, 0, 1, W, 23, T.FrameInactive, 6)
	local icon, text = splitIcon(o.Name)
	icon = icon or o.Icon
	local textX, glyph = 10, nil
	if icon then
		glyph = Glyph(row, icon, 13)
		glyph:center(17, 12.5)
		textX = 30
	end
	local label = ScrollText(row, textX, 0, W - textX - 24, 25, 12)
	local arrow = Glyph(row, "CHEVRON_RIGHT", 12)
	arrow:center(W - 12, 12.5)
	local hot = Anim(0, 15)
	local function paint()
		local a = scope.alpha
		plate.BackgroundColor3, plate.BackgroundTransparency = T.FrameInactive, 1 - (0.5 + 0.4 * hot.v) * a
		local color = flashColor(T.LabelOff:Lerp(T.LabelOn, hot.v), entry)
		label:set(tr(text))
		label:paint(color, a)
		if glyph then glyph:paint(color, a) end
		arrow:paint(T.Disabled:Lerp(Accent, hot.v), a)
	end
	hot.cb = paint
	if entry then entry.paint = paint end
	scope:paint(paint)
	Hit(scope, row, {
		hover = function(b) hot:to(b and 1 or 0); label:hover(b) end,
		click = function() if o.Callback then task.spawn(o.Callback) end end,
		tip = o.Tip and { text, o.Tip } or nil,
	})
	self:advance(25)
	return { row = row }
end

-- Texto informativo que ocupa varias líneas si hace falta.
-- Versión 3: text puede ser una función (texto vivo: cada repintado vuelve a leerla, así un cambio de tema no
-- borra lo escrito) y fixedLines reserva un alto fijo (lo que no quepa se corta con "…").
function Flow:Label(text, fixedLines)
	self:rowBegin()
	local W, scope = self.rw, self.scope
	local function current() return type(text) == "function" and tostring(text() or "") or tr(text) end
	local label = New("TextLabel", {
		Text = "", Position = UDim2.fromOffset(self.x, self.y), Size = UDim2.fromOffset(W, fixedLines and fixedLines * 15 or 0),
		AutomaticSize = fixedLines and Enum.AutomaticSize.None or Enum.AutomaticSize.Y, BackgroundTransparency = 1,
		FontFace = FontMedium, TextSize = 12, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top, TextTruncate = fixedLines and Enum.TextTruncate.AtEnd or Enum.TextTruncate.None,
	}, self.parent)
	scope:paint(function()
		label.Text = current()
		label.TextColor3, label.TextTransparency = T.Disabled, 1 - scope.alpha
	end)
	local lines = fixedLines or math.max(1, math.ceil(measure(current(), 12) / math.max(W, 1)))
	self:advance(lines * 15 + 2)
	return label
end

-- Campo de texto con etiqueta. Callback(texto) al terminar de escribir. o = { Name, Placeholder, Default, Callback, Tip }
function Flow:Input(o)
	self:rowBegin()
	local W, scope, top = self.rw, self.scope, self.y
	local row = Box(self.parent, self.x, top, W, 25)
	local fieldW = math.floor(W * 0.62)
	local label = ScrollText(row, 0, 0, W - fieldW - 8, 25, 12)
	local field = Box(row, W - fieldW, 2, fieldW, 21, T.FieldBg, 6)
	local line = Stroke(Box(field, 1, 1, fieldW - 2, 19, nil, 5), T.Border)
	local input = New("TextBox", {
		Text = o.Default or "", PlaceholderText = o.Placeholder or "", ClearTextOnFocus = false,
		Position = UDim2.fromOffset(8, 0), Size = UDim2.fromOffset(fieldW - 16, 21), BackgroundTransparency = 1,
		FontFace = FontMedium, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
	}, field)
	local focused = false
	local function paint()
		local a = scope.alpha
		label:set(tr(o.Name))
		label:paint(T.LabelOff:Lerp(T.LabelOn, focused and 1 or 0), a)
		field.BackgroundColor3, field.BackgroundTransparency = T.FieldBg, 1 - A.FieldBg * a
		line.Color, line.Transparency = focused and Accent or T.Border, 1 - a
		input.TextColor3, input.PlaceholderColor3 = T.Text, T.Disabled
		input.TextTransparency = 1 - a
	end
	scope:paint(paint)
	input.Focused:Connect(function() focused = true; paint() end)
	input.FocusLost:Connect(function()
		focused = false
		paint()
		if o.Callback then o.Callback(input.Text) end
	end)
	local object = {}
	function object:Set(text) input.Text = text or "" end
	function object:Get() return input.Text end
	self:advance(25)
	return object
end

function Flow:PopupToggle(icon, label, default, callback)
	local r = self:rowImpl(icon, label, false, true)
	local value = default == true
	local on = Anim(value and 1 or 0, 12)
	local paintSwitch = Switch(r.row, r.W - 4 - 30, 7, self.scope)
	local flow = self
	local object = {}
	r.setExtra(function() paintSwitch(on.v) end)
	on.cb = r.paint
	self.scope:paint(r.paint)
	function object:Set(state, silent)
		value = state == true
		on:to(value and 1 or 0)
		if callback and not silent then callback(value) end
		flow:changed()
	end
	function object:Get() return value end
	r.handlers.click = function() object:Set(not value) end
	Hit(self.scope, r.row, r.handlers)
	self:flag({}, label, function() return value end, function(v) object:Set(v == true) end)
	return object
end
end

local choiceWidth, choiceRows, optionCard
do -- bloque propio: sus locales no cuentan en el pico de registros (tools/wrap_block.js)
function choiceWidth(options)
	local widest = 0
	for _, option in options do widest = math.max(widest, measure(tr(option), 12)) end
	return math.ceil(math.max(170, widest + 64))
end

local function checkContours()
	local sz = 9
	local thickness = math.max(sz / 5, 1)
	sz -= thickness * 0.5
	local p = thickness * 0.25
	local third = sz / 3
	local bx, by = p + third, p + sz - third * 0.5
	return strokeContours({ bx - third, by - third, bx, by, bx + third * 2, by - third * 2 }, thickness)
end

-- Rows of a little option card: a sliding check, the label pushed along behind it.
function choiceRows(c, flowW, options, isSelected, onPick, startY)
	local rows = {}
	for i, option in options do
		local row = Box(c.content, 10, startY + (i - 1) * 33, flowW, 33)
		local plate = Box(row, 0, 0, flowW, 33, T.FrameInactive, 6)
		local check = Shape(row, checkContours(), 1, "CHECKMARK")
		check:at(10, 12)
		local t, hover = Anim(isSelected(i) and 1 or 0, 18), Anim(0, 15)
		local label = Label(row, "", 10, capY(16.5, 12), 12)
		local function paint()
			local a = c.scope.alpha
			plate.BackgroundColor3, plate.BackgroundTransparency = T.FrameInactive, 1 - hover.v * 0.6 * a
			check:paint(T.Text, t.v * a)
			setXY(label, round(10 + 22 * t.v), capY(16.5, 12))
			setText(label, tr(option), 12)
			label.TextColor3, label.TextTransparency = T.Disabled:Lerp(T.Text, math.max(t.v, hover.v)), 1 - a
		end
		t.cb, hover.cb = paint, paint
		c.scope:paint(paint)
		Hit(c.scope, row, {
			hover = function(b) hover:to(b and 1 or 0) end,
			click = function() onPick(i) end,
		})
		rows[i] = function() t:to(isSelected(i) and 1 or 0) end
	end
	return rows
end

function optionCard(flow, options, getIndex, setIndex, rowTop, onState)
	local card, rows
	local width = choiceWidth(options)
	card = newCard({
		width = width, name = "OptionCard",
		build = function(c)
			rows = choiceRows(c, width - 20, options, function(i) return i == getIndex() end, function(i)
				setIndex(i)
				for _, r in rows do r() end
			end, 10)
			c:setHeight(20 + #options * 33)
		end,
		place = function(c)
			local at = toStage(flow.card.frame.AbsolutePosition)
			return keepOnScreen(c, at.X + flow.card.width + 8, at.Y + rowTop - 10)
		end,
	})
	card.onState = onState
	return card
end

function Flow:Option(icon, label, options, default, callback)
	local r = self:rowImpl(icon, label, false, true)
	local index = default or 1
	local chevron = Glyph(r.row, "CHEVRON_RIGHT", 13)
	local chevX = r.W - 4 - chevron.boxW
	chevron:center(chevX + chevron.boxW * 0.5, 16.5)
	local value = New("TextLabel", {
		Text = "", BackgroundTransparency = 1, FontFace = FontMedium, TextSize = 12, Size = UDim2.fromOffset(120, 16), TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(round(chevX - 6 - 120), capY(16.5, 12)), TextXAlignment = Enum.TextXAlignment.Right, TextYAlignment = Enum.TextYAlignment.Top,
	}, r.row)
	local scope = self.scope
	r.setExtra(function()
		local color = T.Disabled:Lerp(T.Text, r.t.v * 0.6)
		chevron:paint(color, scope.alpha)
		-- a long value stops short of the row's own label
		local right = round(chevX - 6)
		local room = math.max(20, right - math.ceil(r.labelEnd()) - 12)
		setWH(value, room, 16)
		setXY(value, right - room, capY(16.5, 12))
		value.Text = tr(options[index])
		value.TextColor3, value.TextTransparency = color, 1 - scope.alpha
	end)
	scope:paint(r.paint)
	local flow = self
	local object = {}
	function object:Get() return options[index], index end
	function object:Set(i, silent)
		index = i
		r.paint()
		if callback and not silent then callback(options[index], index) end
		flow:changed()
	end
	local card
	r.handlers.click = function()
		if not card then
			card = optionCard(flow, options, function() return index end, function(i) object:Set(i) end, r.top, function(state) r.setLit(state) end)
		end
		card:open(flow.level)
	end
	Hit(scope, r.row, r.handlers)
	self:flag({}, label, function() return options[index] end, function(v)
		local i = table.find(options, v)
		if i then object:Set(i) end
	end)
	return object
end
end

--[[ ---------------------------------------- Shared bits ----------------------------------- ]]

local function IconButton(parent, scope, name, x, y, w, h, colors, onClick, plate)
	local holder = Box(parent, x, y, w, h)
	local glyph = Glyph(holder, name, 14)
	glyph:center(w * 0.5, h * 0.5)
	local t = Anim(0, 15)
	local function paint()
		local idle, hot = colors()
		glyph:paint(idle:Lerp(hot, t.v), scope.alpha)
		if plate then plate(t.v) end
	end
	t.cb = paint
	scope:paint(paint)
	Hit(scope, holder, { hover = function(b) t:to(b and 1 or 0) end, click = onClick })
	return holder, paint, glyph
end

local function DimHot() return T.Disabled, T.Text end

-- Icon + label rows of the small popup menus.
local function MenuRow(c, y, width, icon, label, colors, onClick)
	local row = Box(c.content, 10, y, width, 33)
	local glyph = Glyph(row, icon, 14)
	glyph:center(10 + glyph.boxW * 0.5, 16.5)
	local text = Label(row, "", 36, capY(16.5, 12), 12)
	local t = Anim(0, 15)
	local function paint()
		local idle, hot = colors()
		local color = idle:Lerp(hot, t.v)
		glyph:paint(color, c.scope.alpha)
		setText(text, tr(label), 12)
		text.TextColor3, text.TextTransparency = color, 1 - c.scope.alpha
	end
	t.cb = paint
	c.scope:paint(paint)
	Hit(c.scope, row, { hover = function(b) t:to(b and 1 or 0) end, click = onClick })
end

local Logo, PlayerAvatar, pushNotification
do -- bloque propio: sus locales no cuentan en el pico de registros (tools/wrap_block.js)
local Avatar = {}
do
	local head, body = {}, {}
	for i = 0, 47 do
		local a = i / 48 * math.pi * 2
		table.insert(head, 15 + math.cos(a) * 6)
		table.insert(head, 12 + math.sin(a) * 6)
	end
	-- the shoulders are a circle cropped by the avatar's own circular mask
	local steps = 20
	local s0 = math.asin(11.25 / 15.16)
	for i = 0, steps do
		local a = -s0 + 2 * s0 * i / steps
		table.insert(body, 15 + math.sin(a) * 15.16)
		table.insert(body, 34.66 - math.cos(a) * 15.16)
	end
	local e0 = math.acos(9.5 / 15)
	for i = 1, steps - 1 do
		local a = e0 - 2 * e0 * i / steps
		table.insert(body, 15 + math.sin(a) * 15)
		table.insert(body, 15 + math.cos(a) * 15)
	end
	function Avatar.new(parent, x, y, size, scope)
		local unit = size / 30
		local shape = Shape(parent, { head, body }, unit, "AVATAR" .. size)
		shape:at(x, y)
		scope:paint(function() shape:paint(Color3.fromRGB(130, 133, 143), scope.alpha) end)
		return shape
	end
end

-- Logo de El Hoyo Hub: cuadrado oscuro con anillos que se hunden hacia un centro negro; el segundo, rojo.
function Logo(parent, x, y, size, scope)
	local holder = Box(parent, x, y, size, size, Color3.fromRGB(18, 17, 24), round(size * 0.24))
	local rings = {}
	local shades = { 0.30, 0.0, 0.42, 0.56, 0.7 } -- el segundo anillo es el rojo
	for i, shade in shades do
		local d = round(size * (0.84 - (i - 1) * 0.13))
		local ring = circle(Box(holder, round((size - d) / 2), round((size - d) / 2), d, d, Color3.fromRGB(14, 13, 19), 1))
		local stroke = Stroke(ring, Accent, i == 2 and 1.5 or 1)
		rings[i] = { frame = ring, stroke = stroke, shade = shade }
	end
	local core = circle(Box(holder, round(size * 0.35), round(size * 0.35), round(size * 0.3), round(size * 0.3), Black, 1))
	scope:paint(function()
		local a = scope.alpha
		holder.BackgroundTransparency = 1 - a
		for i, r in rings do
			r.frame.BackgroundTransparency = 1 - a
			r.stroke.Color = i == 2 and Accent or Color3.fromRGB(40, 36, 50):Lerp(Black, r.shade)
			r.stroke.Transparency = 1 - a * (i == 2 and 1 or 0.8)
		end
		core.BackgroundTransparency = 1 - a
	end)
	return holder
end

-- Foto del jugador (o la silueta de siempre si Roblox no la da)
function PlayerAvatar(parent, x, y, size, scope)
	local ok, image = pcall(function()
		return Players:GetUserThumbnailAsync(Players.LocalPlayer.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
	end)
	if not ok then return Avatar.new(parent, x, y, size, scope) end
	local frame = circle(Box(parent, x, y, size, size, Color3.fromRGB(30, 27, 38), 1))
	local img = New("ImageLabel", { Image = image, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, frame)
	New("UICorner", { CornerRadius = UDim.new(1, 0) }, img)
	scope:paint(function()
		frame.BackgroundTransparency = 1 - scope.alpha
		img.ImageTransparency = 1 - scope.alpha
	end)
	return frame
end

--[[ ---------------------------------------- Notifications --------------------------------- ]]

local Notes, NoteLayer, NotesLog = {}, nil, nil

-- 1.5.0: nivel (info | success | warning | error, también ok/warn) con su color de Tokens; una notificación igual
-- en menos de 4 s no se apila: la que se ve suma "×N". Historial en Library.NotificationLog (módulo Notifications).
function pushNotification(title, message, level)
	NotesLog = NotesLog or import("Notifications").new()
	Library.NotificationLog = NotesLog
	local entry, show = NotesLog:push(level, title, message)
	if not show then
		for _, n in Notes do
			if n.entry == entry then
				n.age = math.min(n.age, 0.4)
				n.setCount(entry.count)
			end
		end
		return
	end
	if not NoteLayer then
		NoteLayer = Box(Stage, 0, 0, 0, 0)
		NoteLayer.Size = UDim2.fromScale(1, 1)
		NoteLayer.ZIndex = 200000
	end
	local W, H = 300, 64
	local levelToken = Library.Tokens.notify[entry.level] or "Info"
	local frame = Box(NoteLayer, 0, 0, W, H)
	local bg = Box(frame, 0, 0, W, H, T.Popup, 8)
	local shadow = Shadow(bg, 16, 0.55, 3)
	local line = Stroke(Box(bg, 1, 1, W - 2, H - 2, nil, 7), T.PopupBorder)
	local stripe = Box(frame, 0, 10, 3, H - 20, T[levelToken] or Accent, 2)
	local noteScope = newScope(nil)
	local logo = Logo(frame, 14, 14, 36, noteScope)
	local head = Label(frame, title, 62, capY(22, 12), 12, FontSemi)
	local body = Label(frame, message, 62, capY(42, 12), 12)
	local count = Label(frame, "", W - 40, capY(22, 11), 11, FontSemi)
	local barBack = Box(frame, 10, H - 4, W - 20, 2, T.FrameInactive, 1)
	local bar = Box(frame, 10, H - 4, W - 20, 2, T[levelToken] or Accent, 1)
	body.TextTruncate = Enum.TextTruncate.AtEnd
	body.Size = UDim2.fromOffset(W - 74, 16)
	local note = { frame = frame, age = 0, offset = 1, entry = entry }
	function note.setCount(n) count.Text = n > 1 and ("×" .. n) or "" end
	table.insert(Notes, note)
	local _ = logo
	Run(function(dt)
		note.age += dt
		local age = note.age
		note.offset += (0 - note.offset) * clamp(dt * 6, 0, 1)
		local alpha = 1
		if age < 0.15 then alpha = age / 0.15 end
		if age > 3 then alpha = 1 - (age - 3) end
		alpha = sat(alpha)
		local index = table.find(Notes, note)
		local view = viewport()
		setXY(frame, round(view.X - W - 12 + note.offset * 320), 12 + (H + 8) * (index - 1))
		local accent = T[levelToken] or Accent
		if shadow then shadow.Transparency = 1 - 0.45 * alpha end
		bg.BackgroundColor3, bg.BackgroundTransparency = T.Popup, 1 - alpha
		line.Color, line.Transparency = T.PopupBorder, 1 - alpha
		stripe.BackgroundColor3, stripe.BackgroundTransparency = accent, 1 - alpha
		noteScope:setAlpha(alpha)
		head.TextColor3, head.TextTransparency = T.Text, 1 - alpha
		body.TextColor3, body.TextTransparency = T.Disabled, 1 - alpha
		count.TextColor3, count.TextTransparency = accent, 1 - alpha
		barBack.BackgroundColor3, barBack.BackgroundTransparency = T.FrameInactive, 1 - alpha
		bar.BackgroundColor3, bar.BackgroundTransparency = accent, 1 - alpha
		setWH(bar, round((W - 20) * sat(1 - age / 3)), 2)
		if age > 4 then
			table.remove(Notes, index)
			frame:Destroy()
			return false
		end
		return true
	end)
end
end
--[[ ---------------------------------------- Tabs and boxes -------------------------------- ]]

local TabMeta = {}
TabMeta.__index = TabMeta

function TabMeta:Columns(weights) self.weights = weights end

function TabMeta:Box(o)
	local win, page = self.win, self.page
	local column = o.Column or 1
	-- "auto" (1.5.4): la columna la decide layout() (la más baja); necesita columnas del mismo ancho
	if column == "auto" and self.weights then column = (#self.boxes % 2) + 1 end
	local box = { name = o.Name, column = column, height = o.Height or "auto", tab = self, spacing = o.RowSpacing or 8, padY = o.PadY or 8 }
	local holder = Box(self.canvas or page, 0, 0, 100, 100)
	local fill = Box(holder, 0, 18, 100, 80, T.Group, 9)
	local lineFrame = Box(holder, 1, 19, 98, 78, nil, 8)
	local line = Stroke(lineFrame, T.Border)
	local title = Label(holder, "", 12, 0, 11, FontSemi)
	local content = Box(holder, 0, 18, 100, 80)
	local scope = newScope(self.scope)
	local scroller
	local flow = newFlow({ parent = content, scope = scope, x = 12, y = box.padY, w = 100, rw = 100, spacing = box.spacing, separators = true, level = 0, win = win,
		path = self.name .. "/" .. o.Name, store = win.store, search = { win = win, tab = self, tabName = self.name, box = o.Name } })
	flow.hostRight = function()
		local a = toStage(holder.AbsolutePosition)
		return a.X + box.width
	end
	scope:paint(function()
		local a = scope.alpha
		fill.BackgroundColor3, fill.BackgroundTransparency = T.Group, 1 - a
		line.Color, line.Transparency = T.Border, 1 - a
		setText(title, tr(o.Name), 11, FontSemi)
		title.TextColor3, title.TextTransparency = T.Title, 1 - 0.5 * a
	end)
	box.holder, box.fill, box.lineFrame, box.content, box.flow, box.scope = holder, fill, lineFrame, content, flow, scope
	-- the widgets are built knowing the column width, which the column split decides
	local columns = self.weights
	local total = 0
	for i = 1, 2 do total += columns and columns[i] or 1 end
	local usable = 600 - 8
	local width = usable * (columns and columns[box.column] or 1) / total -- "auto" = 1 de 2 (iguales)
	box.width = width
	flow.w, flow.rw = width - 24, width - 24
	setWH(holder, width, 100)
	setWH(fill, width, 80)
	setWH(lineFrame, width - 2, 78)
	setWH(content, width, 80)
	if o.Scrollable then
		content.ClipsDescendants = true
		scope.clip = content
		local inner = Box(content, 0, 0, width, 80)
		flow.parent = inner
		box.inner = inner
		scroller = { y = 0, max = 0 }
		box.scroller = scroller
		local fadeTop = Box(content, 0, 0, width, 40, White)
		local fadeBottom = Box(content, 0, 40, width, 40, White)
		local gTop = New("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(0, 1) }, fadeTop)
		local gBottom = New("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(1, 0) }, fadeBottom)
		box.fadeTop, box.fadeBottom = fadeTop, fadeBottom
		local function paintFades()
			local topStrength = sat(scroller.y / 40)
			local bottomStrength = sat((scroller.max - scroller.y) / 40)
			local color = T.Group
			fadeTop.BackgroundColor3, fadeBottom.BackgroundColor3 = color, color
			fadeTop.BackgroundTransparency = 1 - topStrength * scope.alpha
			fadeBottom.BackgroundTransparency = 1 - bottomStrength * scope.alpha
		end
		box.paintFades = paintFades
		scope:paint(paintFades)
		Wheel(scope, content, function(z)
			scroller.y = clamp(scroller.y - z * 75, 0, scroller.max)
			setXY(inner, 0, -scroller.y)
			paintFades()
		end)
	end
	table.insert(self.boxes, box)
	setmetatable(box, { __index = function(_, key)
		local method = Flow[key]
		if method then return function(_, ...) return method(flow, ...) end end
	end })
	return box
end

-- 1.5.4: cada caja mide lo que su contenido (sin recortes ni scroll propio) y se apilan con Library.Layout.stack (la
-- misma función que prueban los tests). Si no cabe todo, la página entera se desplaza. Se puede volver a llamar si
-- el contenido cambia (las cajas de debajo bajan).
function TabMeta:layout()
	local columns = self.weights
	local total, widths = 0, {}
	for i = 1, 2 do total += columns and columns[i] or 1 end
	local usable = 600 - 8
	for i = 1, 2 do widths[i] = usable * (columns and columns[i] or 1) / total end
	local input = {}
	for i, box in self.boxes do
		local natural = box.flow.y - box.spacing + box.padY + 18
		box.natural = natural
		input[i] = { column = box.column, natural = natural, height = box.height }
	end
	local L = Library.Layout.stack(input, { widths = widths, view = Library.Layout.PAGE.h })
	for i, box in self.boxes do
		local p = L.boxes[i]
		local h = p.h
		box.boxHeight, box.placedColumn = h, p.column
		setXY(box.holder, p.x, p.y)
		setWH(box.holder, box.width, h)
		setWH(box.fill, box.width, h - 18)
		setWH(box.lineFrame, box.width - 2, h - 20)
		setWH(box.content, box.width, h - 18)
		if box.scroller then -- cajas con scroll propio (API antigua): ya caben enteras, así que no se desplazan
			local viewH = h - 18
			setWH(box.inner, box.width, math.max(box.natural - 18, viewH))
			box.scroller.max = math.max(0, box.natural - 18 - viewH)
			box.scroller.y = math.min(box.scroller.y, box.scroller.max)
			setXY(box.inner, 0, -box.scroller.y)
			setXY(box.fadeBottom, 0, viewH - math.min(40, viewH * 0.25))
			setWH(box.fadeTop, box.width, math.min(40, viewH * 0.25))
			setWH(box.fadeBottom, box.width, math.min(40, viewH * 0.25))
			box.paintFades()
		end
	end
	if self.canvas then
		setWH(self.canvas, 600, math.max(Library.Layout.PAGE.h, L.total))
		self.pageScroll.max = L.maxScroll
		self:scrollTo(self.pageScroll.y)
	end
	self.stackInfo = L
end

-- One line of a framed list: accent border while selected, optional trailing action.
function Flow:Framed(label, o)
	o = o or {}
	local W, scope, top = o.Width or self.rw, self.scope, self.y
	local row = Box(self.parent, self.x, top, W, 36)
	local fill = Box(row, 0, 0, W, 36, T.FrameInactive, 8)
	local lineFrame = Box(row, 1, 1, W - 2, 34, nil, 7)
	local line = Stroke(lineFrame, Accent)
	local icon, text = splitIcon(label)
	local textX = 12
	local glyph
	if icon then
		glyph = Glyph(row, icon, 14)
		glyph:center(12 + glyph.boxW * 0.5, 18)
		textX = round(12 + glyph.boxW + 8)
	end
	local name = Label(row, "", textX, capY(18, 12), 12)
	local hot, on = Anim(0, 15), Anim(o.Selected and 1 or 0, 14)
	local actionHot, actionFill, actionPaint, actionLabel, actionGlyph
	if o.ActionIcon or o.ActionLabel then
		actionHot = Anim(0, 15)
		local iconW = 0
		if o.ActionIcon then iconW = glyphContours(o.ActionIcon).adv / 512 * 14 end
		local labelW = o.ActionLabel and measure(tr(o.ActionLabel), 12) or 0
		local aw = iconW + labelW + (o.ActionIcon and o.ActionLabel and 6 or 0) + 16
		local ax = W - 6 - aw
		local action = Box(row, ax, 6, aw, 24)
		actionFill = Box(action, 0, 0, aw, 24, T.FrameInactive, 6)
		if o.ActionIcon then
			actionGlyph = Glyph(action, o.ActionIcon, 14)
			actionGlyph:center(8 + iconW * 0.5, 12)
		end
		if o.ActionLabel then
			actionLabel = Label(action, tr(o.ActionLabel), 8 + iconW + (o.ActionIcon and 6 or 0), capY(12, 12), 12)
		end
		actionPaint = function()
			local a = scope.alpha
			actionFill.BackgroundColor3, actionFill.BackgroundTransparency = T.FrameInactive, 1 - 0.8 * actionHot.v * a
			local color = T.Disabled:Lerp(T.Text, actionHot.v)
			if actionGlyph then actionGlyph:paint(color, a) end
			if actionLabel then actionLabel.TextColor3, actionLabel.TextTransparency = color, 1 - a end
		end
		actionHot.cb = actionPaint
		scope:paint(actionPaint)
		Hit(scope, action, { hover = function(b) actionHot:to(b and 1 or 0) end, click = o.Action })
	end
	local function paint()
		local a = scope.alpha
		fill.BackgroundColor3, fill.BackgroundTransparency = T.FrameInactive, 1 - (0.45 + 0.35 * hot.v) * a
		line.Color = T.PopupBorder:Lerp(Accent, on.v)
		line.Transparency = 1 - (0.55 + 0.45 * on.v) * a
		setText(name, tr(text), 12)
		name.TextColor3 = T.Text
		name.TextTransparency = 1 - (0.85 + 0.15 * math.max(hot.v, on.v)) * a
		if glyph then glyph:paint(T.Text, (0.85 + 0.15 * math.max(hot.v, on.v)) * a) end
	end
	hot.cb, on.cb = paint, paint
	scope:paint(paint)
	Hit(scope, row, { hover = function(b) hot:to(b and 1 or 0) end, click = o.Callback })
	self.y += 36 + self.spacing
	local object = {}
	function object:Select(state) on:to(state and 1 or 0) end
	return object
end

--[[ ---------------------------------------- Window ---------------------------------------- ]]

local WindowMeta = {}
WindowMeta.__index = WindowMeta

function WindowMeta:pos() return self.position end

function WindowMeta:dragTo(target)
	self.dragTarget = target
	if self.queueSettings then self.queueSettings() end -- guarda la posición (agrupado: una escritura por pausa)
	if self.moving then return end
	self.moving = true
	Run(function(dt)
		self.position = self.position:Lerp(self.dragTarget, 1 - math.exp(-20 * dt))
		if (self.dragTarget - self.position).Magnitude < 0.5 then self.position = self.dragTarget end
		setXY(self.frame, round(self.position.X), round(self.position.Y))
		if self.position == self.dragTarget then
			self.moving = false
			return false
		end
		return true
	end)
end

-- Barra lateral extensible (1.5.0): grupos plegables (clic en su título; plegados muestran cuántas secciones
-- tienen), desplazamiento con la rueda cuando no cabe, barra de acento en la sección activa, última sección y grupos
-- plegados recordados en settings.json, y navegación con win:stepTab(±1). Ya no hay límite de 11 secciones.
function WindowMeta:Group(name)
	self.groupFirst = self.groupFirst == nil
	local win = self
	local key = tostring(name)
	local saved = type(self.saved.collapsed) == "table" and self.saved.collapsed or {}
	local group = { kind = "group", first = self.groupFirst, key = key, collapsed = saved[key] == true, count = 0 }
	local label = Label(self.sideInner, "", 10, 0, 11, FontSemi)
	local hit = Box(self.sideInner, 0, 0, 150, 16)
	local hot = Anim(0, 15)
	local scope = self.sideScope
	local function paint()
		local text = tr(name)
		if group.collapsed or group.autoFolded then text = text .. "  +" .. group.count end
		setText(label, text, 11, FontSemi)
		label.TextColor3, label.TextTransparency = T.Title, 1 - (0.5 + 0.3 * hot.v) * scope.alpha
	end
	hot.cb = paint
	scope:paint(paint)
	group.frame, group.hit, group.paint = label, hit, paint
	Hit(scope, hit, {
		hover = function(b) hot:to(b and 1 or 0) end,
		click = function()
			if not win:inSide(hit) then return end
			win:toggleGroup(group)
		end,
		tip = { name, "Click to fold or unfold this group." },
	})
	self.currentGroup = group
	table.insert(self.sideItems, group)
end

function WindowMeta:toggleGroup(group, state)
	-- acordeón (no cabe todo): pulsar un grupo plegado automáticamente lo despliega y pliega los demás (sin guardar)
	if self.sideAccordion and state == nil and group.autoFolded then
		self.focusGroup = group.key
		self:relayoutSide()
		return
	end
	if state == nil then state = not group.collapsed end
	if group.collapsed == state then return end
	group.collapsed = state
	group.paint()
	self:relayoutSide()
	self.queueSettings()
end

-- ¿Está este elemento dentro de la barra? (1.5.3: ya no hay scroll; se conserva por compatibilidad)
function WindowMeta:inSide(frame)
	local clip, p = self.sideClip, frame.AbsolutePosition
	if not clip then return true end
	local c, cs = clip.AbsolutePosition, clip.AbsoluteSize
	return p.Y + frame.AbsoluteSize.Y * 0.5 >= c.Y and p.Y + frame.AbsoluteSize.Y * 0.5 <= c.Y + cs.Y
end

-- 1.5.3: la barra no se desplaza (todo cabe o acordeón); se conserva la función por compatibilidad
function WindowMeta:scrollSide()
	self.sideScroll = 0
	setXY(self.sideInner, 0, 0)
end

function WindowMeta:selectTab(tab, instantly)
	if self.current == tab then return end
	local previous = self.current
	self.current = tab
	if previous then
		previous.page.Visible = false
		previous.scope.inert = true
	end
	flushLazy(tab.page)
	tab.page.Visible = true
	tab.scope.inert = false
	local parent = tab.parentTab
	self:setExpanded(tab.expandedOwner or (parent) or (tab.children and tab) or nil)
	for _, t in self.tabs do t:paintActive() end
	if instantly then self.pageAnim:set(1) else self.pageAnim:set(0); self.pageAnim:to(1) end
	-- su grupo se despliega (si el usuario lo había plegado) y, en acordeón, pasa a ser el desplegado
	local top = parent or tab
	if top.group and top.group.collapsed then self:toggleGroup(top.group, false) end
	self.focusGroup = nil
	self:relayoutSide()
	self.saved.lastTab = tab.name
	if self.queueSettings then self.queueSettings() end
	if self.onTabChanged then task.spawn(self.onTabChanged, tab) end
end

-- Siguiente / anterior sección seleccionable (las que tienen subsecciones se saltan: se entra en la primera)
function WindowMeta:stepTab(dir)
	local list = {}
	for _, item in self.sideItems do
		if item.kind == "tab" and not item.tab.children then table.insert(list, item.tab) end
	end
	if #list == 0 then return end
	local i = table.find(list, self.current) or 0
	self:selectTab(list[((i - 1 + dir) % #list) + 1])
end

function WindowMeta:setExpanded(owner)
	if self.expanded == owner then return end
	if self.expanded then self.expanded.expandAnim:to(0) end
	self.expanded = owner
	if owner then owner.expandAnim:to(1) end
end

-- 1.5.3: SIN scroll propio. Las posiciones y el alto de fila salen de Library.Layout.sidebar (la misma función que
-- prueban los tests): todas las secciones a la vista; si no caben ni con filas de 22 px, acordeón (los títulos de
-- todos los grupos siguen visibles y se despliega el de la sección activa o el que pulses).
function WindowMeta:relayoutSide()
	local simple, map = {}, {}
	for _, item in self.sideItems do
		if item.kind == "group" then
			table.insert(simple, { kind = "group", key = item.key, collapsed = item.collapsed })
			map[#simple] = item
		elseif item.kind == "tab" and not item.tab.parentTab then
			table.insert(simple, { kind = "tab", group = item.tab.group and item.tab.group.key or nil })
			map[#simple] = item
		end
	end
	local activeTop = self.current and (self.current.parentTab or self.current)
	local focus = self.focusGroup or (activeTop and activeTop.group and activeTop.group.key)
	local L = Library.Layout.sidebar(simple, Library.Layout.SIDE.height, focus)
	local m = L.metrics
	self.sideMetrics, self.sideAccordion = m, L.accordion
	for i, s in simple do
		local item = map[i]
		if s.kind == "group" then
			setXY(item.frame, 10, L.y[i])
			setXY(item.hit, 0, L.y[i] - 1)
			local auto = L.accordion and L.hidden[s.key] == true and not item.collapsed
			if item.autoFolded ~= auto then
				item.autoFolded = auto
				item.paint()
			end
		else
			local tab = item.tab
			local hidden = L.y[i] == nil
			tab.hiddenInGroup = hidden
			tab.row.Visible = not hidden
			if tab.subClip then tab.subClip.Visible = not hidden end
			if not hidden then
				tab:fit(m.tab)
				setXY(tab.row, 0, L.y[i])
				tab.sideY = L.y[i]
				if tab.children then
					tab.subBase = L.y[i] + m.tab
					setXY(tab.subClip, 0, tab.subBase)
				end
			end
		end
	end
	-- subsecciones (la API las conserva; el hub no las usa): debajo de su sección, con el mismo alto de fila
	for _, item in self.sideItems do
		if item.kind == "tab" and item.tab.parentTab then
			local tab, parent = item.tab, item.tab.parentTab
			local v = parent.hiddenInGroup and 0 or parent.expandAnim.v
			tab:fit(m.tab)
			tab.row.Visible = v > 0.01
			tab.rowScope.own = v
			tab.rowScope:refresh()
			setXY(tab.row, 0, (item.subIndex - 1) * m.tab)
			if item.subIndex == #parent.children then setWH(parent.subClip, 150, round(#parent.children * m.tab * v)) end
		end
	end
	self.sideMax = 0
	self:scrollSide()
end

function WindowMeta:Tab(o)
	local win = self
	local parentTab = o.Parent
	local tab = setmetatable({ win = win, name = o.Name, boxes = {}, parentTab = parentTab, group = not parentTab and self.currentGroup or nil }, TabMeta)
	if tab.group then tab.group.count += 1 end
	local host = parentTab and parentTab.subClip or self.sideInner
	local row = Box(host, 0, 0, 150, 30)
	local indent = parentTab and 10 or 0
	local scope = newScope(self.sideScope)
	local pill = Box(row, 6 + indent, 0, 138 - indent, 30, T.TabActive, 6)
	local bar = Box(row, 6 + indent, 8, 2, 14, Accent, 1) -- indicador de sección activa
	local glyph = Glyph(row, o.Icon, 14)
	glyph:center(6 + indent + 9 + 8, 15)
	local label = ScrollText(row, 6 + indent + 32, 0, 138 - indent - 32 - 8, 30, 12)
	local active, hover = Anim(0, 4.85), Anim(0, 4.85)
	local function paint()
		local a = scope.alpha
		pill.BackgroundColor3 = T.TabActive
		pill.BackgroundTransparency = 1 - sat(active.v + hover.v * 0.4) * a
		bar.BackgroundColor3, bar.BackgroundTransparency = Accent, 1 - active.v * a
		local icon = T.Disabled
		if hover.v > 0 then icon = icon:Lerp(T.Text, hover.v) end
		if active.v > 0 then icon = icon:Lerp(Accent, active.v) end
		glyph:paint(icon, a)
		label:set(tr(o.Name))
		label:paint(T.Disabled:Lerp(T.Text, sat(active.v + hover.v)), a)
	end
	active.cb, hover.cb = paint, paint
	scope:paint(paint)
	tab.row, tab.rowScope = row, scope
	-- 1.5.3: alto de fila que decide relayoutSide (todas las secciones a la vista); el contenido queda centrado
	function tab:fit(h)
		if tab.fitH == h then return end
		tab.fitH = h
		setWH(row, 150, h)
		setXY(pill, 6 + indent, 1)
		setWH(pill, 138 - indent, h - 2)
		setXY(bar, 6 + indent, math.floor((h - 14) / 2))
		glyph:center(6 + indent + 9 + 8, h / 2)
		setXY(label.clip, 6 + indent + 32, math.floor((h - 30) / 2))
	end
	function tab:paintActive()
		local on = win.current == tab or (tab.children and win.current and win.current.parentTab == tab)
		active:to(on and 1 or 0)
	end
	Hit(scope, row, {
		hover = function(b) hover:to(b and 1 or 0); label:hover(b) end,
		click = function()
			if not win:inSide(row) then return end
			if tab.children then
				local cur = win.current
				if not (cur and cur.parentTab == tab) then
					win:selectTab(tab.children[1])
				else
					win:setExpanded(tab)
				end
			else
				win:selectTab(tab)
			end
		end,
	})
	local page = Box(self.pages, 0, 0, 600, 509)
	page.Visible = false
	LazyRoots[page] = {}
	tab.page = page
	tab.pageScope = newScope(self.pagesScope)
	tab.pageScope.inert = true
	tab.scope = tab.pageScope
	-- 1.5.4: las cajas van en un lienzo que se desplaza dentro de la página (UN scroll por página, ninguno por caja).
	-- La página recorta lo de fuera y su scope (clip) impide clics en lo que no se ve.
	page.ClipsDescendants = true
	tab.canvas = Box(page, 0, 0, 600, 509)
	tab.pageScroll = { y = 0, max = 0 }
	tab.pageScope.clip = page
	local scrollBar = Box(page, 600 - 3, 0, 3, 40, Accent, 2)
	scrollBar.Visible = false
	tab.scrollBar = scrollBar
	function tab:scrollTo(y)
		local sc = tab.pageScroll
		sc.y = math.clamp(y, 0, sc.max)
		setXY(tab.canvas, 0, -round(sc.y))
		scrollBar.Visible = sc.max > 0
		if sc.max > 0 then
			local viewH = Library.Layout.PAGE.h
			local barH = math.max(24, round(viewH * viewH / (viewH + sc.max)))
			setWH(scrollBar, 3, barH)
			setXY(scrollBar, 600 - 3, round((viewH - barH) * sc.y / sc.max))
			scrollBar.BackgroundColor3, scrollBar.BackgroundTransparency = Accent, 0.45
		end
	end
	-- la rueda sobre cualquier parte de la página (las zonas con rueda propia, como el mapa, van antes)
	Wheel(tab.pageScope, page, function(z) tab:scrollTo(Library.Layout.scrollBy(tab.pageScroll.y, z, tab.pageScroll.max)) end)
	local entry = { kind = "tab", tab = tab }
	table.insert(self.tabs, tab)
	if parentTab then
		-- sub-tabs live in their parent's clip; relayout handles position and fade
		parentTab.children = parentTab.children or {}
		table.insert(parentTab.children, tab)
		entry.subIndex = #parentTab.children
	else
		function tab:EnableChildren()
			tab.expandAnim = Anim(0, 12, function() win:relayoutSide() end, 0.01)
			tab.subClip = Box(win.sideInner, 0, 0, 150, 0)
			tab.subClip.ClipsDescendants = true
			return tab
		end
	end
	table.insert(self.sideItems, entry)
	if not self.current and not parentTab then self:selectTab(tab, true) end
	return tab
end

function WindowMeta:Finish()
	for _, tab in self.tabs do tab:layout() end
	-- modo compacto (poco alto): solo queda desplegado el grupo de la sección activa (sin guardarlo)
	if self.compact then
		local keep = self.current and (self.current.parentTab or self.current).group
		for _, item in self.sideItems do
			if item.kind == "group" and item ~= keep then item.collapsed = true; item.paint() end
		end
	end
	-- vuelve a la última sección visitada (por su nombre estable)
	for _, tab in self.tabs do
		if tab.name == self.restoreTab and not tab.children then self:selectTab(tab, true) break end
	end
	self:relayoutSide()
	for _, tab in self.tabs do tab:paintActive() end
	self.configs.init()
	self.scope:refresh()
	return self
end

-- Puts a value that is not a control into configs.
function WindowMeta:Flag(id, get, set)
	self.store.controls[id] = { get = get, set = set }
	local waiting = self.store.pending[id]
	if waiting ~= nil then
		self.store.pending[id] = nil
		set(waiting)
	end
end

function WindowMeta:Get(id)
	local control = self.store.controls[id]
	if control then return control.get() end
	return self.store.pending[id]
end

do -- bloque propio: sus locales no cuentan en el pico de registros (tools/wrap_block.js)
local function settingsChanged()
	if CurrentWindow then CurrentWindow.queueSettings() end
end

function Library:SetTheme(name)
	if not Palettes[name] then return end
	Library.Theme = name
	repaintAll()
	settingsChanged()
end

function Library:SetAccent(color)
	Accent = color
	repaintAll()
	settingsChanged()
end

function Library:SetLanguage(index)
	Library.Language = index
	if CurrentWindow and CurrentWindow.onLanguage then CurrentWindow.onLanguage() end
	repaintAll()
	settingsChanged()
end

function Library:SetScale(scale)
	if CurrentWindow then CurrentWindow.userScale = scale end -- la elegida (la ajustada a la pantalla no se guarda)
	setRasterScale(scale)
	repaintAll()
	settingsChanged()
end

local function buildSearch(win, top)
	local scope, parent = win.topScope, win.frame
	local rightX, baseY = 785, 15
	local plate = Box(parent, rightX - 30, baseY, 30, 30, T.FrameInactive, 6)
	local iconHit = Box(parent, rightX - 30, baseY, 30, 30)
	local mag = Glyph(parent, "SEARCH", 14)
	mag:center(rightX - 15, baseY + 15)
	local input = New("TextBox", {
		Text = "", PlaceholderText = "", ClearTextOnFocus = false, BackgroundTransparency = 1, FontFace = FontMedium, TextSize = 12, Visible = false,
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, ClipsDescendants = true,
	}, parent)
	local placeholder = Label(parent, "", 0, 0, 12)
	placeholder.Visible = false
	local isOpen, hovered, hotA, openA = false, false, nil, nil
	local results
	local listFrame, listScope, listRows = nil, nil, {}
	local listA = 0
	local sel = 1
	local hits = {}
	local function paint()
		local a, o, h = scope.alpha, openA.v, hotA.v
		local e = o * o * (3 - 2 * o)
		local width = 30 + (250 - 30) * e
		setXY(plate, round(rightX - width), baseY)
		setWH(plate, round(width), 30)
		plate.BackgroundColor3, plate.BackgroundTransparency = T.FrameInactive, 1 - (0.5 + 0.3 * math.max(h, e)) * a
		mag:paint(T.Disabled:Lerp(T.Text, math.max(h, e)), a)
		local textX = round(rightX - width + 12)
		local textW = math.max(1, rightX - 30 + 4 - textX)
		input.Visible = e > 0.01
		placeholder.Visible = e > 0.01 and input.Text == ""
		setXY(input, textX, capY(baseY + 15, 12))
		setWH(input, textW, 16)
		setXY(placeholder, textX, capY(baseY + 15, 12))
		input.TextColor3, input.TextTransparency = T.Text, 1 - e * a
		setText(placeholder, tr("Search functions..."), 12)
		placeholder.TextColor3, placeholder.TextTransparency = T.Disabled, 1 - 0.75 * e * a
	end
	hotA, openA = Anim(0, 15, paint), Anim(0, 16, paint)
	scope:paint(paint)

	local foldMap = { [0x401] = 0x435, [0x451] = 0x435, [0x130] = 105, [0x131] = 105, [0xC7] = 99, [0xE7] = 99, [0x11E] = 103, [0x11F] = 103, [0x15E] = 115, [0x15F] = 115, [0xD6] = 111, [0xF6] = 111, [0xDC] = 117, [0xFC] = 117 }
	local function fold(text)
		local out = {}
		for _, code in utf8.codes(text) do
			if code >= 65 and code <= 90 then code += 32
			elseif code >= 0x410 and code <= 0x42F then code += 0x20
			else code = foldMap[code] or code end
			table.insert(out, utf8.char(code))
		end
		return table.concat(out)
	end
	-- 1.5.0: lista más ancha (340), 10 filas, grupo y favorito a la derecha
	local rowW, rowH, listW, ROWS = 328, 30, 340, 10
	local GROUP_LABEL = { controls = "Functions", settings = "Settings", profiles = "Presets", catalog = "Catalog", history = "Recent" }
	local function ensureList()
		if listFrame then return end
		local card = newCard({ width = listW, rounding = 10, name = "SearchList" })
		card.frame.Active = true
		listFrame, listScope = card, card.scope
		table.insert(Windows, { frame = card.frame, scope = card.scope })
		for i = 1, ROWS do
			local row = Box(card.content, 6, 6 + (i - 1) * rowH, rowW, rowH)
			local bg = Box(row, 0, 0, rowW, rowH, T.FrameInactive, 6)
			local labelClip = Box(row, 0, 0, rowW, rowH)
			labelClip.ClipsDescendants = true
			local a = Label(labelClip, "", 10, capY(16, 12), 12)
			local b = Label(labelClip, "", 0, capY(16, 12), 12)
			local m = Label(labelClip, "", 0, capY(16, 12), 12)
			local path = New("TextLabel", {
				Text = "", BackgroundTransparency = 1, FontFace = FontMedium, TextSize = 11, Size = UDim2.fromOffset(170, 16),
				Position = UDim2.fromOffset(rowW - 10 - 170, capY(15, 11)), TextXAlignment = Enum.TextXAlignment.Right, TextYAlignment = Enum.TextYAlignment.Top,
				TextTruncate = Enum.TextTruncate.AtEnd,
			}, row)
			local t = Anim(0, 15)
			local rowObj = { row = row }
			local function paintRow()
				local alpha = card.scope.alpha
				bg.BackgroundColor3, bg.BackgroundTransparency = T.FrameInactive, 1 - 0.8 * t.v * alpha
				a.TextColor3, a.TextTransparency = T.Text, 1 - alpha
				m.TextColor3, m.TextTransparency = Accent, 1 - alpha
				b.TextColor3, b.TextTransparency = T.Text, 1 - alpha
				path.TextColor3, path.TextTransparency = T.Disabled, 1 - 0.9 * alpha
			end
			t.cb = paintRow
			card.scope:paint(paintRow)
			rowObj.fill = function(entry, startAt, needleLen)
				local shown = entry.group == "history" and entry.label or tr(entry.label)
				local first = utf8.offset(shown, startAt or (utf8.len(shown) + 1)) or (#shown + 1)
				local after = utf8.offset(shown, (startAt or 0) + needleLen) or (#shown + 1)
				local part1, part2, part3 = string.sub(shown, 1, first - 1), string.sub(shown, first, after - 1), string.sub(shown, after)
				setText(a, part1, 12)
				setText(m, part2, 12)
				setText(b, part3, 12)
				local w1 = part1 ~= "" and measure(part1, 12) or 0
				setXY(m, round(10 + w1), capY(16, 12))
				setXY(b, round(10 + w1 + (part2 ~= "" and measure(part2, 12) or 0)), capY(16, 12))
				local where = entry.path or (tr(entry.tabName or "") .. " · " .. tr(entry.box or ""))
				local star = entry.key and win.isFavorite and win.isFavorite(entry.key) and "★ " or ""
				path.Text = star .. tr(GROUP_LABEL[entry.group or "controls"] or "Functions") .. " · " .. where
				setWH(labelClip, math.max(1, rowW - 10 - measure(path.Text, 12) - 6), rowH)
				rowObj.entry = entry
			end
			rowObj.t = t
			Hit(card.scope, row, {
				hover = function(state)
					if state then
						sel = i
						for k, r in listRows do r.t:to(k == sel and 1 or 0) end
					end
				end,
				click = function() if rowObj.entry then results(rowObj.entry) end end,
			})
			listRows[i] = rowObj
		end
		local empty = Label(card.content, "", 16, capY(22, 12), 12)
		empty.Visible = false
		card.scope:paint(function()
			setText(empty, tr("No results. Try another word."), 12)
			empty.TextColor3, empty.TextTransparency = T.Disabled, 1 - card.scope.alpha
		end)
		card.empty = empty
	end
	local function setList(show)
		ensureList()
		local card = listFrame
		card.frame.ZIndex = 50000
		if show then
			card.frame.Visible = true
			local a = toStage(parent.AbsolutePosition)
			card.base = Vector2.new(a.X + rightX - listW, a.Y + baseY + 30 + 8)
			card:apply()
			card.isOpen = true
		else
			card.isOpen = false
		end
		card:startFade()
	end
	-- Entradas para buscar: los controles (con su texto traducido, descripción y sección) y lo que añadan los
	-- proveedores del hub (win.searchProviders: perfiles, catálogo…). Se rehace en cada búsqueda: es barato.
	local function candidates(q)
		local list = {}
		for _, entry in win.searchIndex do
			if not string.match(entry.label, "^%d+$") then
				entry.text = tr(entry.label)
				entry.group = (entry.tab and entry.tab.name == "Settings") and "settings" or "controls"
				table.insert(list, { label = entry.text, tip = entry.tip and tr(entry.tip) or nil, group = entry.group,
					path = tr(entry.tabName or "") .. " " .. tr(entry.box or ""), source = entry })
			end
		end
		for _, provider in win.searchProviders or {} do
			local ok, extra = pcall(provider, q)
			if ok and type(extra) == "table" then
				for _, e in extra do table.insert(list, { label = e.label, tip = e.tip, group = e.group or "catalog", aliases = e.aliases, path = e.path, source = e }) end
			end
		end
		return list
	end
	local function refreshHits()
		local raw = input.Text
		table.clear(hits)
		if raw:match("^%s*$") then
			-- sin texto: las últimas búsquedas (elegir una la vuelve a escribir; no ejecuta nada)
			for _, h in win.saved.searchHistory or {} do
				if #hits >= ROWS then break end
				table.insert(hits, { { label = h, group = "history", path = "", history = true }, nil })
			end
		else
			for _, h in Library.Search.rank(candidates(raw), raw, { limit = ROWS }) do
				local src = h.entry.source
				table.insert(hits, { src, h.field == "label" and h.at or nil })
			end
		end
		local q = fold(raw)
		sel = clamp(sel, 1, math.max(1, #hits))
		ensureList()
		for i, row in listRows do
			local hit = hits[i]
			row.row.Visible = hit ~= nil
			if hit then row.fill(hit[1], hit[2], utf8.len(q)) end
			row.t:to(i == sel and 1 or 0)
		end
		listFrame.empty.Visible = #hits == 0 and q ~= ""
		listFrame:setHeight(12 + math.max(1, #hits) * rowH)
		setList(isOpen and (q ~= "" or #hits > 0) and input:IsFocused())
	end
	local function setOpen(state)
		isOpen = state
		openA:to(state and 1 or 0)
		if state then
			input.Visible = true
			input:CaptureFocus()
		else
			input.Text = ""
			input:ReleaseFocus()
			setList(false)
		end
	end
	results = function(entry)
		-- se apunta la búsqueda en el historial (solo el texto; nunca se ejecuta nada al elegir)
		if not entry.history then
			win.saved.searchHistory = Library.Search.remember(win.saved.searchHistory or {}, input.Text)
			if win.queueSettings then win.queueSettings() end
		end
		if entry.history then input.Text = entry.label; input.CursorPosition = #input.Text + 1; return end
		if entry.pick then -- de un proveedor (perfil, entidad del catálogo): lleva a su sección
			setOpen(false)
			task.spawn(entry.pick)
			return
		end
		win:selectTab(entry.tab)
		local tabObj = entry.tab
		if tabObj and tabObj.parentTab then win:setExpanded(tabObj.parentTab) end
		setOpen(false)
		entry.flash = 1.2
		Run(function(dt)
			entry.flash = math.max(0, entry.flash - dt)
			if entry.paint then entry.paint() end
			return entry.flash > 0
		end)
	end
	input:GetPropertyChangedSignal("Text"):Connect(function()
		placeholder.Visible = input.Visible and input.Text == ""
		if isOpen then refreshHits() end
	end)
	input.FocusLost:Connect(function(enter)
		if enter and hits[sel] then
			results(hits[sel][1])
			return
		end
		if listFrame and listFrame.frame.Visible and inside(listFrame.frame, mouseAbs()) then return end
		if input.Text == "" and isOpen and not hovered then setOpen(false) else setList(false) end
	end)
	Hit(scope, iconHit, {
		hover = function(b) hovered = b; hotA:to(b and 1 or 0) end,
		click = function() setOpen(not isOpen) end,
	})
	Hit(scope, input, {})
	connect(UserInputService.InputBegan, function(input2)
		if not isOpen then return end
		local ctrl = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
		if input2.KeyCode == Enum.KeyCode.Escape then
			setOpen(false)
		elseif ctrl and input2.KeyCode == Enum.KeyCode.Return and hits[sel] and hits[sel][1].key and win.toggleFavorite then
			win.toggleFavorite(hits[sel][1].key) -- Ctrl+Enter: favorito (no ejecuta la función)
			refreshHits()
		elseif #hits > 0 and (input2.KeyCode == Enum.KeyCode.Down or input2.KeyCode == Enum.KeyCode.Up) then
			local count = #hits
			sel = input2.KeyCode == Enum.KeyCode.Down and sel % count + 1 or (sel - 2) % count + 1
			for k, r in listRows do r.t:to(k == sel and 1 or 0) end
		end
	end)
	win.search = { setOpen = setOpen, isOpen = function() return isOpen end }
	-- ir a un control por su clave estable (favoritos, accesos rápidos): misma navegación que un resultado
	function win:goToKey(key)
		for _, entry in self.searchIndex do
			if entry.key == key then results(entry) return true end
		end
		return false
	end
	function win:findKey(key)
		for _, entry in self.searchIndex do if entry.key == key then return entry end end
		return nil
	end
end

-- Presets on disk. One JSON file per preset; `selected` is the one loaded right now.
local function newConfigs(win, onChanged)
	local store = win.store
	local configDir, trashDir = win.folder .. "/configs", win.folder .. "/trash"
	local M = { list = {}, trash = {}, selected = 1 }
	local sequence = 0

	local function stamp()
		sequence += 1
		return os.time() + sequence / 1000
	end
	local function pathFor(dir, name) return dir .. "/" .. safeName(name) .. ".json" end
	local function snapshot()
		local values = {}
		for id, value in store.pending do values[id] = value end
		for id, control in store.controls do values[id] = control.get() end
		return values
	end
	-- v4: aplicar un perfil es atómico. Si el hub puso win.profileApply (módulo Profiles), valida todo antes y deshace
	-- si algo falla; si no, se aplica como siempre. Devuelve ok, problemas.
	local function apply(values)
		if type(values) ~= "table" then return false, { "values no es una tabla" } end
		if win.profileApply then return win.profileApply(values, store.controls, store.pending) end
		for id, value in values do
			local control = store.controls[id]
			if control then control.set(value) else store.pending[id] = value end
		end
		return true, {}
	end
	local function writeConfig(dir, cfg, values)
		Files.write(pathFor(dir, cfg.name), encodeJSON({ name = cfg.name, created = cfg.created, modified = cfg.modified, values = values,
			profileVersion = win.profileVersion }))
	end
	local function readValues(dir, cfg)
		local data = decodeJSON(Files.read(pathFor(dir, cfg.name)))
		return type(data) == "table" and data.values or {}
	end
	local function unique(list, name, except)
		local function taken(candidate)
			local key = string.lower(safeName(candidate))
			for _, cfg in list do
				if cfg ~= except and string.lower(safeName(cfg.name)) == key then return true end
			end
			return false
		end
		if not taken(name) then return name end
		local n = 2
		while taken(name .. " " .. n) do n += 1 end
		return name .. " " .. n
	end
	local function scan(dir, into)
		table.clear(into)
		for _, file in Files.list(dir) do
			if string.sub(file, -5) == ".json" then
				local data = decodeJSON(Files.read(dir .. "/" .. file))
				if type(data) == "table" then
					table.insert(into, { name = data.name or string.sub(file, 1, -6), created = tonumber(data.created) or 0, modified = tonumber(data.modified) or 0 })
				end
			end
		end
	end

	function M.current() return M.list[M.selected] end

	function M.create(name)
		local time = stamp()
		local cfg = { name = unique(M.list, name), created = time, modified = time }
		table.insert(M.list, cfg)
		writeConfig(configDir, cfg, snapshot())
		return #M.list
	end

	function M.save(i)
		local cfg = M.list[i]
		cfg.modified = stamp()
		writeConfig(configDir, cfg, snapshot())
	end

	-- El perfil activo solo cambia si se aplicó entero
	function M.load(i)
		local ok, problems = apply(readValues(configDir, M.list[i]))
		if not ok then return false, problems end
		M.selected = i
		win.queueSettings()
		return true
	end
	-- Para el hub (v4): valores actuales, valores guardados de un perfil, volver a lo guardado, crear desde valores
	M.snapshot = snapshot
	function M.peek(i) return M.list[i] and readValues(configDir, M.list[i]) or nil end
	function M.revert() return apply(readValues(configDir, M.current())) end
	function M.createFrom(name, values)
		local time = stamp()
		local cfg = { name = unique(M.list, name), created = time, modified = time }
		table.insert(M.list, cfg)
		writeConfig(configDir, cfg, values)
		if win.configsChanged then win.configsChanged() end
		return #M.list, cfg
	end

	function M.rename(i, name)
		local cfg = M.list[i]
		local values = readValues(configDir, cfg)
		Files.delete(pathFor(configDir, cfg.name))
		cfg.name = unique(M.list, name, cfg)
		cfg.modified = stamp()
		writeConfig(configDir, cfg, values)
		win.queueSettings()
	end

	function M.duplicate(i)
		local source = M.list[i]
		local time = stamp()
		local copy = { name = unique(M.list, source.name), created = time, modified = time }
		writeConfig(configDir, copy, readValues(configDir, source))
		table.insert(M.list, i + 1, copy)
		if M.selected > i then M.selected += 1 end
		return copy
	end

	function M.remove(i)
		local cfg = table.remove(M.list, i)
		local values = readValues(configDir, cfg)
		Files.delete(pathFor(configDir, cfg.name))
		cfg.name = unique(M.trash, cfg.name)
		writeConfig(trashDir, cfg, values)
		table.insert(M.trash, cfg)
		if #M.list == 0 then M.create("Default") end
		if M.selected > i or M.selected > #M.list then M.selected = math.max(1, M.selected - 1) end
		win.queueSettings()
		return cfg
	end

	function M.restore(j)
		local cfg = table.remove(M.trash, j)
		local values = readValues(trashDir, cfg)
		Files.delete(pathFor(trashDir, cfg.name))
		cfg.name = unique(M.list, cfg.name)
		cfg.modified = stamp()
		writeConfig(configDir, cfg, values)
		table.insert(M.list, cfg)
		return cfg
	end

	function M.purge(j)
		local cfg = table.remove(M.trash, j)
		Files.delete(pathFor(trashDir, cfg.name))
	end

	-- Hands the preset's file to the clipboard, where the executor provides one.
	-- v4: con win.profileExport (módulo Profiles) se copia una versión SIN secretos
	function M.export(i)
		if type(setclipboard) ~= "function" then return false end
		if win.profileExport then
			local okText, text = pcall(win.profileExport, M.list[i], readValues(configDir, M.list[i]))
			return okText and (pcall(setclipboard, text)) or false
		end
		return (pcall(setclipboard, Files.read(pathFor(configDir, M.list[i].name)) or ""))
	end

	function M.init()
		Files.folder(configDir)
		Files.folder(trashDir)
		scan(configDir, M.list)
		scan(trashDir, M.trash)
		if #M.list == 0 then M.create("Default") end
		M.selected = 1
		for i, cfg in M.list do
			if cfg.name == win.saved.lastConfig then M.selected = i end
		end
		apply(readValues(configDir, M.current()))
		onChanged()
	end

	return M
end

local function buildConfigPopup(win, configs, onChanged)
	local sortMode = 1
	local searchText = ""
	local card, rowsScope, searchInput
	local rebuild, rowMenu, sortMenu, binMenu, menuRow
	local listClip, listInner, listScroll
	local listY, width, inner, rowH, rowGap = 90, 340, 320, 36, 8

	local function notify(title, text, ...)
		pushNotification(tr(title), string.format(tr(text), ...))
	end
	local function copied(i)
		if configs.export(i) then
			notify("Share", "Copied %s to the clipboard", configs.list[i].name)
		else
			pushNotification(tr("Share"), tr("Clipboard is not available"))
		end
	end
	local function order()
		local out = {}
		local needle = string.lower(searchText)
		for i, cfg in configs.list do
			if needle == "" or string.find(string.lower(cfg.name), needle, 1, true) then table.insert(out, i) end
		end
		table.sort(out, function(a, b)
			local x, y = configs.list[a], configs.list[b]
			if sortMode == 2 then return x.modified > y.modified end
			if sortMode == 3 then return string.lower(x.name) < string.lower(y.name) end
			return x.created > y.created
		end)
		return out
	end
	local function pick(i)
		if i == configs.selected then return end
		local ok, problems = configs.load(i)
		if not ok then
			notify("Config not loaded", "%s", tostring(problems and problems[1] or "?"))
			return
		end
		notify("Config Loaded", "Loaded config: %s", configs.list[i].name)
		rebuild()
		onChanged()
	end

	rebuild = function()
		if not card or not listClip then return end
		if rowsScope then
			local index = table.find(card.scope.kids, rowsScope)
			if index then table.remove(card.scope.kids, index) end
		end
		rowsScope = newScope(card.scope)
		rowsScope.clip = listClip
		for _, child in listInner:GetChildren() do child:Destroy() end
		local list = order()
		local rows = math.max(1, #list)
		local listH = math.min(rows, 7) * (rowH + rowGap) - rowGap
		setWH(listClip, inner, listH)
		setWH(listInner, inner, rows * (rowH + rowGap) - rowGap)
		listScroll.max = math.max(0, rows * (rowH + rowGap) - rowGap - listH)
		listScroll.y = clamp(listScroll.y, 0, listScroll.max)
		setXY(listInner, 0, -listScroll.y)
		card:setHeight(10 + listY + listH + 10)
		if #list == 0 then
			local empty = Label(listInner, "", 0, capY(rowH * 0.5, 12), 12)
			empty.Text = tr("No presets found")
			setWH(empty, inner, 16)
			empty.TextXAlignment = Enum.TextXAlignment.Center
			rowsScope:paint(function() empty.TextColor3, empty.TextTransparency = T.Disabled, 1 - rowsScope.alpha end)
		end
		for n, i in list do
			local cfg = configs.list[i]
			local isSelected = i == configs.selected
			local rowFrame = Box(listInner, 0, (n - 1) * (rowH + rowGap), inner, rowH)
			local fill = Box(rowFrame, 0, 0, inner, rowH, T.FrameInactive, 8)
			local tint = Box(rowFrame, 0, 0, inner, rowH, Accent, 8)
			local line = Stroke(Box(rowFrame, 1, 1, inner - 2, rowH - 2, nil, 7), Accent)
			local nameLabel = Label(rowFrame, "", 12, capY(rowH * 0.5, 12), 12)
			local hov = Anim(isSelected and 1 or 0, 15)
			local function paintRow()
				local a = rowsScope.alpha
				fill.BackgroundColor3, fill.BackgroundTransparency = T.FrameInactive, 1 - (0.45 + 0.4 * hov.v) * a
				tint.BackgroundColor3, tint.BackgroundTransparency = Accent, isSelected and 1 - 0.1 * a or 1
				line.Color = isSelected and Accent or T.PopupBorder
				line.Transparency = 1 - (isSelected and 1 or 0.5) * a
				setText(nameLabel, cfg.name, 12)
				nameLabel.TextColor3 = T.Text
				nameLabel.TextTransparency = 1 - ((isSelected and 1 or 0.85) + (isSelected and 0 or 0.15) * hov.v) * a
			end
			hov.cb = paintRow
			rowsScope:paint(paintRow)
			local actX = inner - 10 - 26
			local menuX = actX - 26 - 2
			IconButton(rowFrame, rowsScope, "ELLIPSIS_H", menuX, 0, 26, rowH, DimHot, function()
				menuRow = i
				rowMenu:open(1, mouseAbs())
			end)
			IconButton(rowFrame, rowsScope, isSelected and "SAVE" or "CLOUD_DOWNLOAD_ALT", actX, 0, 26, rowH, DimHot, function()
				if isSelected then
					configs.save(i)
					notify("Config Saved", "Saved changes to %s", cfg.name)
				else
					pick(i)
				end
			end)
			local lastClick = 0
			Hit(rowsScope, rowFrame, {
				hover = function(b) hov:to((b or isSelected) and 1 or 0) end,
				click = function()
					local now = os.clock()
					if now - lastClick < 0.35 then
						local box = New("TextBox", {
							Text = cfg.name, ClearTextOnFocus = false, BackgroundTransparency = 1, FontFace = FontMedium, TextSize = 12,
							TextColor3 = T.Text, Position = UDim2.fromOffset(12, capY(rowH * 0.5, 12)), Size = UDim2.fromOffset(menuX - 18, 16),
							TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, ZIndex = 5,
						}, rowFrame)
						nameLabel.Visible = false
						box:CaptureFocus()
						box.FocusLost:Connect(function(enter)
							if enter and box.Text ~= "" and box.Text ~= cfg.name then
								local old = cfg.name
								configs.rename(i, box.Text)
								notify("Config Renamed", "Renamed %s to %s", old, cfg.name)
							end
							box:Destroy()
							rebuild()
							onChanged()
						end)
						return
					end
					lastClick = now
					pick(i)
				end,
			})
		end
		rowsScope:refresh()
	end

	local function miniCard(w, build, offX, offY)
		return newCard({
			width = w, name = "CfgMenu", build = build,
			place = function(self2, point)
				local at = toStage(point or mouseAbs())
				local a = win:pos()
				return Vector2.new(clamp(at.X + offX, a.X + 10, a.X + 800 - w - 10), clamp(at.Y + offY, a.Y + 10, a.Y + 600 - self2.height - 10))
			end,
		})
	end
	local function red()
		local color = Color3.new(.898, .286, .29)
		return color, color
	end

	rowMenu = miniCard(152, function(c)
		MenuRow(c, 10, 132, "SHARE", "Share", DimHot, function()
			if configs.list[menuRow] then copied(menuRow) end
			closePopupsTo(1)
		end)
		MenuRow(c, 43, 132, "COPY", "Duplicate", DimHot, function()
			if configs.list[menuRow] then
				local copy = configs.duplicate(menuRow)
				notify("Config Duplicated", "Duplicated %s", copy.name)
				rebuild()
			end
			closePopupsTo(1)
		end)
		MenuRow(c, 76, 132, "TRASH", "Delete", red, function()
			if configs.list[menuRow] then
				local gone = configs.remove(menuRow)
				notify("Config Deleted", "Removed config: %s", gone.name)
				rebuild()
				onChanged()
			end
			closePopupsTo(1)
		end)
		c:setHeight(20 + 33 * 3)
	end, 8, 14)

	local sortOptions = { "Newest First", "Recently Modified", "Alphabetical" }
	local sortW = choiceWidth(sortOptions)
	sortMenu = miniCard(sortW, function(c)
		local rows
		rows = choiceRows(c, sortW - 20, sortOptions, function(i) return i == sortMode end, function(i)
			sortMode = i
			for _, r in rows do r() end
			rebuild()
		end, 10)
		c:setHeight(20 + 3 * 33)
	end, -(sortW - 28), 24)

	local binScope, binRebuild
	binMenu = miniCard(216, function(c)
		local holder = Box(c.content, 10, 10, 196, 33)
		binRebuild = function()
			if binScope then
				local index = table.find(c.scope.kids, binScope)
				if index then table.remove(c.scope.kids, index) end
			end
			binScope = newScope(c.scope)
			for _, child in holder:GetChildren() do child:Destroy() end
			if #configs.trash == 0 then
				local empty = New("TextLabel", {
					Text = tr("Bin is empty"), BackgroundTransparency = 1, FontFace = FontMedium, TextSize = 12, Size = UDim2.fromOffset(196, 16),
					Position = UDim2.fromOffset(0, capY(16.5, 12)), TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Top,
				}, holder)
				binScope:paint(function() empty.TextColor3, empty.TextTransparency = T.Disabled, 1 - binScope.alpha end)
			end
			for i, cfg in configs.trash do
				local y = (i - 1) * 33
				local name = Label(holder, cfg.name, 2, y + capY(16.5, 12), 12)
				binScope:paint(function() name.TextColor3, name.TextTransparency = T.Text, 1 - binScope.alpha end)
				-- borrar para siempre pide un segundo clic en 4 s (v4)
				IconButton(holder, binScope, "TRASH", 196 - 52 - 6, y, 26, 33, red, function()
					local now = os.clock()
					if not (configs.purgeArmed and configs.purgeArmed.name == cfg.name and now - configs.purgeArmed.at < 4) then
						configs.purgeArmed = { name = cfg.name, at = now }
						notify("Delete forever?", "Click again to delete %s forever", cfg.name)
						return
					end
					configs.purgeArmed = nil
					configs.purge(i)
					binRebuild()
				end)
				IconButton(holder, binScope, "UNDO", 196 - 26, y, 26, 33, DimHot, function()
					local back = configs.restore(i)
					notify("Config Restored", "Restored %s", back.name)
					binRebuild()
					rebuild()
				end)
			end
			local n = math.max(1, #configs.trash)
			setWH(holder, 196, n * 33)
			c:setHeight(20 + n * 33)
			binScope:refresh()
		end
		binRebuild()
	end, -110, 24)
	binMenu.onOpen = function() if binRebuild then binRebuild() end end

	local function ensure()
		if card then return card end
		card = newCard({
			width = width, name = "Presets",
			place = function()
				local a = win:pos()
				return Vector2.new(a.X + 190 + 35, a.Y + 15 + 36)
			end,
			build = function(c)
				local content, scope = c.content, c.scope
				local o = 10
				local iconW = glyphContours("CLOUD").adv / 512 * 14
				local badgeW = 12 + iconW + 7 + measure(tr("Presets"), 14, FontSemi) + 12
				local badge = Box(content, o, o, round(badgeW), 30, Accent, 8)
				local cloud = Glyph(badge, "CLOUD", 14)
				cloud:center(12 + iconW * 0.5, 15)
				local title = Label(badge, "", round(12 + iconW + 7), capY(15, 14), 14, FontSemi)
				scope:paint(function()
					badge.BackgroundColor3, badge.BackgroundTransparency = Accent, 1 - scope.alpha
					cloud:paint(White, scope.alpha)
					setText(title, tr("Presets"), 14, FontSemi)
					title.TextColor3, title.TextTransparency = White, 1 - scope.alpha
				end)
				local top = o + 1
				local x = o + inner - 28
				IconButton(content, scope, "PLUS", x, top, 28, 28, DimHot, function()
					configs.selected = configs.create("Unnamed")
					win.queueSettings()
					pushNotification(tr("Config Created"), tr("Created new config"))
					rebuild()
					onChanged()
				end)
				x -= 34
				IconButton(content, scope, "TRASH_RESTORE", x, top, 28, 28, DimHot, function() binMenu:open(1, mouseAbs()) end)
				x -= 34
				IconButton(content, scope, "CLOUD_UPLOAD_ALT", x, top, 28, 28, function() return Accent, T.Text end, function()
					if configs.current() then copied(configs.selected) end
				end)

				local searchY = o + 30 + 14
				local fieldW = inner - 34 - 8
				local field = Box(content, o, searchY, fieldW, 34, T.FrameInactive, 8)
				local fieldLine = Stroke(Box(field, 1, 1, fieldW - 2, 32, nil, 7), T.PopupBorder)
				local mag = Glyph(field, "SEARCH", 14)
				mag:center(12 + mag.boxW * 0.5, 17)
				local textX = round(12 + mag.boxW + 10)
				searchInput = New("TextBox", {
					Text = "", ClearTextOnFocus = false, BackgroundTransparency = 1, FontFace = FontMedium, TextSize = 12,
					TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(textX, capY(17, 12)),
					Size = UDim2.fromOffset(fieldW - 12 - textX, 16), ClipsDescendants = true,
				}, field)
				local hint = Label(field, "", textX, capY(17, 12), 12)
				local sortBox = Box(content, o + inner - 34, searchY, 34, 34, T.FrameInactive, 8)
				local sortLine = Stroke(Box(sortBox, 1, 1, 32, 32, nil, 7), T.PopupBorder)
				IconButton(content, scope, "SORT_AMOUNT_DOWN", o + inner - 34, searchY, 34, 34, DimHot, function() sortMenu:open(1, mouseAbs()) end)
				scope:paint(function()
					local a = scope.alpha
					field.BackgroundColor3, field.BackgroundTransparency = T.FrameInactive, 1 - 0.85 * a
					sortBox.BackgroundColor3, sortBox.BackgroundTransparency = T.FrameInactive, 1 - 0.85 * a
					fieldLine.Color, fieldLine.Transparency = T.PopupBorder, 1 - 0.6 * a
					sortLine.Color, sortLine.Transparency = T.PopupBorder, 1 - 0.6 * a
					mag:paint(T.Disabled, a)
					searchInput.TextColor3, searchInput.TextTransparency = T.Text, 1 - a
					setText(hint, tr("Search"), 12)
					hint.TextColor3, hint.TextTransparency = T.Disabled, 1 - 0.75 * a
				end)
				searchInput:GetPropertyChangedSignal("Text"):Connect(function()
					searchText = searchInput.Text
					hint.Visible = searchText == "" and not searchInput:IsFocused()
					rebuild()
				end)
				Hit(scope, searchInput, {})
				searchInput.Focused:Connect(function() hint.Visible = false end)
				searchInput.FocusLost:Connect(function() hint.Visible = searchInput.Text == "" end)

				listClip = Box(content, o, o + listY, inner, 100)
				listClip.ClipsDescendants = true
				listInner = Box(listClip, 0, 0, inner, 100)
				listScroll = { y = 0, max = 0 }
				Wheel(scope, listClip, function(z)
					listScroll.y = clamp(listScroll.y - z * 75, 0, listScroll.max)
					setXY(listInner, 0, -listScroll.y)
				end)
				rebuild()
			end,
		})
		return card
	end
	return function()
		local c = ensure()
		c:open(0)
		rebuild()
	end
end

local function buildUserCard(win, profile)
	local language, scales = { "English", "Spanish" }, { "75%", "100%", "125%", "150%", "175%", "200%" }
	local scaleValues = { .75, 1, 1.25, 1.5, 1.75, 2 }
	return newCard({
		width = 250, name = "UserCard",
		place = function(c)
			local a = win:pos()
			return keepOnScreen(c, a.X + 160 + 10, a.Y + 592 - c.height)
		end,
		build = function(c)
			local content, scope = c.content, c.scope
			PlayerAvatar(content, 14, 10, 40, scope)
			local name = Label(content, "", 66, 12, 12, FontSemi)
			local till = Label(content, "", 66, 26, 11)
			local renew = Label(content, "", 66, 39, 11)
			scope:paint(function()
				local a = scope.alpha
				setText(name, profile.name, 12, FontSemi)
				setText(till, tr(profile.till), 11)
				setText(renew, "El Hoyo Hub", 11)
				name.TextColor3, name.TextTransparency = T.Text, 1 - a
				till.TextColor3, till.TextTransparency = T.Disabled, 1 - a
				renew.TextColor3, renew.TextTransparency = Accent, 1 - a
			end)
			local flow = newFlow({ parent = content, scope = scope, x = 10, y = 56, w = 230, rw = 230, card = c, level = c.level, win = win, path = "settings" })
			flow:Option("GLOBE", "Language", language, Library.Language + 1, function(_, i) Library:SetLanguage(i - 1) end)
			flow:Option("TEXT_HEIGHT", "Menu Scale", scales, table.find(scaleValues, Scale) or 2, function(_, i) Library:SetScale(scaleValues[i]) end)

			-- Style: the cog opens the theme list, the swatch edits the accent colour.
			local accentValue = newColor(Accent, 1)
			local themeCard, accentCard
			local r = flow:rowImpl("FILL_DRIP", "Style", false, true)
			local swX, swY = r.W - 4 - 15, 9
			local previewBase, paintAccent = Preview(r.row, swX, swY, 15, 4, scope)
			local swHot, cogT = Anim(0, 15), Anim(0, 15)
			local swRing = Stroke(Box(r.row, swX - 1, swY - 1, 17, 17, nil, 5), White)
			local cog = Glyph(r.row, "COG", 14)
			cog:center(swX - 9 - cog.boxW * 0.5, 16.5)
			local cogHit = Box(r.row, round(swX - 13 - cog.boxW), 6, round(cog.boxW + 8), 21)
			r.setExtra(function()
				accentValue.a = Accent
				paintAccent(accentValue, scope.alpha)
				swRing.Transparency = 1 - 0.35 * swHot.v * scope.alpha
				cog:paint(T.Disabled:Lerp(T.Text, math.max(cogT.v, r.t.v * 0.6)), scope.alpha)
			end)
			swHot.cb, cogT.cb = r.paint, r.paint
			scope:paint(r.paint)
			local function openTheme()
				if not themeCard then
					themeCard = optionCard(flow, Library.ThemeNames, function() return table.find(Library.ThemeNames, Library.Theme) or 1 end, function(i)
						Library:SetTheme(Library.ThemeNames[i])
					end, r.top, function(state) r.setLit(state); cogT:to(state and 1 or 0) end)
				end
				themeCard:open(c.level)
			end
			Hit(scope, previewBase, {
				hover = function(b) swHot:to(b and 1 or 0) end,
				click = function()
					if not accentCard then
						accentCard = newCard({
							width = 274, padding = 16, name = "AccentCard",
							build = function(pc)
								local pf = newFlow({ parent = pc.content, scope = pc.scope, x = 16, y = 16, w = 242, rw = 240, card = pc, level = pc.level, win = win })
								local bottom = buildPicker(pf, { { name = "Accent", value = accentValue } }, false, function(col)
									Library:SetAccent(col.a)
								end)
								pc:setHeight(bottom + 16)
							end,
							place = function(pc)
								local at = toStage(previewBase.AbsolutePosition)
								return keepOnScreen(pc, at.X + 15 + 12, at.Y - 18)
							end,
						})
					end
					accentCard:open(c.level)
				end,
			})
			Hit(scope, cogHit, { hover = function(b) cogT:to(b and 1 or 0) end, click = openTheme })
			r.handlers.click = openTheme
			Hit(scope, r.row, r.handlers)

			c:setHeight(flow:bottom() + 10)
		end,
	})
end

-- There is no media session to read from inside Roblox, so the player shows its offline state.
local function buildSpotify(win)
	local width = 268 + 22
	local height = 145 + 22
	local view = viewport()
	local frame = Box(Stage, round(view.X - 268 - 90), 130, width, height)
	frame.Visible, frame.Active, frame.Name = false, true, "Spotify"
	local surface, shadow = buildSurface(frame, width, height, 16, false)
	local content = Box(frame, 0, 0, width, height)
	local scope = newScope(Root)
	local widget = { frame = frame, scope = scope, position = Vector2.new(frame.Position.X.Offset, 130), dragTarget = Vector2.new(frame.Position.X.Offset, 130) }
	scope.own = 0
	function widget:dragTo(target)
		widget.dragTarget = target
		if widget.moving then return end
		widget.moving = true
		Run(function(dt)
			widget.position = widget.position:Lerp(widget.dragTarget, 1 - math.exp(-9 * dt))
			if (widget.dragTarget - widget.position).Magnitude < 0.5 then widget.position = widget.dragTarget end
			setXY(frame, round(widget.position.X), round(widget.position.Y))
			if widget.position == widget.dragTarget then
				widget.moving = false
				return false
			end
			return true
		end)
	end
	local pad, w = 11, 268
	local music = Glyph(content, "MUSIC", 14)
	music:center(pad + music.boxW * 0.5, pad + 8.5)
	local heading = Label(content, "", round(pad + music.boxW + 7), capY(pad + 8.5, 11), 11, FontSemi)
	local dotsRect = Box(content, pad + w - 21, pad - 1, 21, 19, T.FrameInactive, 6)
	local dots = {}
	for i = -1, 1 do dots[i] = circle(Box(dotsRect, 9 + i * 4, 8, 3, 3, White, 1)) end
	local y = pad + 24
	local gc = Vector2.new(pad + w * 0.5, y + 24)
	local rings2 = {}
	for i = 3, 1, -1 do
		local r = 13 + i * 5
		local f = circle(Box(content, gc.X - r, gc.Y - r, r * 2, r * 2, nil, 1))
		rings2[i] = { Stroke(f, Accent, 1.5), f, r, i }
	end
	local glyph = Glyph(content, "MUSIC", 14)
	glyph:center(gc.X, gc.Y)
	local head = New("TextLabel", {
		Text = "", BackgroundTransparency = 1, FontFace = FontSemi, TextSize = 14, Size = UDim2.fromOffset(w, 20), Position = UDim2.fromOffset(pad, capY(y + 54.5, 14)),
		TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Top,
	}, content)
	local sub = New("TextLabel", {
		Text = "", BackgroundTransparency = 1, FontFace = FontSemi, TextSize = 11, Size = UDim2.fromOffset(w, 16), Position = UDim2.fromOffset(pad, capY(y + 74, 11)),
		TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Top,
	}, content)
	local btnLabelW = measure(tr("Open Spotify"), 11, FontSemi)
	local btnW = round(math.min(w, btnLabelW + 52))
	local btn = Box(content, round(pad + (w - btnW) * 0.5), y + 88, btnW, 30, Accent, 15)
	local ext = Glyph(btn, "EXTERNAL_LINK_ALT", 14)
	local block = ext.boxW + 7 + btnLabelW
	local bx = (btnW - block) * 0.5
	ext:center(bx + ext.boxW * 0.5, 15)
	local btnLabel = Label(btn, "", round(bx + ext.boxW + 7), capY(15, 11), 11, FontSemi)
	local dotT, btnT = Anim(0, 15), Anim(0, 15)
	local function paint()
		local a = scope.alpha
		surface.BackgroundColor3, surface.BackgroundTransparency = T.Popup, 1 - a
		if shadow then shadow.Transparency = 1 - 0.5 * a end
		music:paint(Accent, a)
		setText(heading, tr("Spotify"), 11, FontSemi)
		heading.TextColor3, heading.TextTransparency = T.Text, 1 - 0.85 * a
		dotsRect.BackgroundColor3, dotsRect.BackgroundTransparency = T.FrameInactive, 1 - 0.85 * dotT.v * a
		for _, d in dots do d.BackgroundColor3, d.BackgroundTransparency = T.Disabled:Lerp(T.Text, dotT.v), 1 - a end
		for i, r in rings2 do r[1].Color, r[1].Transparency = Accent, 1 - (0.13 / i) * a end
		glyph:paint(Accent, 0.85 * a)
		head.Text, head.TextColor3, head.TextTransparency = tr("Spotify is not running"), T.Text, 1 - a
		sub.Text, sub.TextColor3, sub.TextTransparency = tr("Start it and this connects on its own."), T.Disabled, 1 - a
		btn.BackgroundColor3, btn.BackgroundTransparency = Accent, 1 - (0.85 + 0.15 * btnT.v) * a
		ext:paint(White, a)
		setText(btnLabel, tr("Open Spotify"), 11, FontSemi)
		btnLabel.TextColor3, btnLabel.TextTransparency = White, 1 - a
	end
	dotT.cb, btnT.cb = paint, paint
	scope:paint(paint)
	Hit(scope, btn, { hover = function(b) btnT:to(b and 1 or 0) end })
	local optionsCard
	Hit(scope, dotsRect, {
		hover = function(b) dotT:to(b and 1 or 0) end,
		click = function()
			if not optionsCard then
				optionsCard = newCard({
					width = 272, name = "SpotifyOptions",
					place = function()
						return Vector2.new(widget.position.X + width + 8, widget.position.Y)
					end,
					build = function(c)
						local flow = newFlow({ parent = c.content, scope = c.scope, x = 10, y = 10, w = 252, rw = 252, card = c, level = c.level, win = win })
						flow:PopupToggle("VOLUME_MUTE", "Mute", false)
						flow:Separator()
						flow:PopupToggle("MICROPHONE_ALT", "Show Lyrics", false)
						flow:Option("IMAGE", "Background", { "With Lyrics Background", "Without Lyrics Background" }, 1)
						flow:PopupToggle("FILM", "Preview GIF", false)
						flow:Separator()
						flow:Section({ Border = false }, function(section)
							section:Slider({ Name = "Volume", Min = 0, Max = 100, Default = 100, Format = "%d%%" })
						end)
						c:setHeight(flow:bottom() + 10)
					end,
				})
			end
			optionsCard:open(0)
		end,
	})
	local shown = Anim(0, 12, function(v)
		scope:setAlpha(math.max(v, 0))
		frame.Visible = v > 0.004
	end, 0.004)
	table.insert(Windows, widget)
	frame.ZIndex = 50
	win.setSpotify = function(state) shown:to(state and 1 or 0) end
end

-- Reads the themes folder and settings.json, before anything is drawn.
local function loadSaved(folder)
	local themeDir = folder .. "/themes"
	Files.folder(folder)
	Files.folder(themeDir)
	for name, palette in Palettes do
		local path = themeDir .. "/" .. name .. ".json"
		if not Files.read(path) then
			local colors = {}
			for key, entry in palette do colors[key] = toHex(entry[1], entry[2]) end
			Files.write(path, encodeJSON({ Colors = colors }))
		end
	end
	local names = {}
	for _, file in Files.list(themeDir) do
		if string.sub(file, -5) == ".json" then
			local name = string.sub(file, 1, -6)
			local data = decodeJSON(Files.read(themeDir .. "/" .. file))
			if type(data) == "table" and type(data.Colors) == "table" then
				local palette = {}
				for key, value in data.Colors do
					local color, alpha = fromHex(value)
					if color then palette[key] = { color, alpha } end
				end
				Palettes[name] = palette
				table.insert(names, name)
			end
		end
	end
	local rank = { Abismo = 1, Light = 2 }
	table.sort(names, function(a, b)
		local x, y = rank[a] or 3, rank[b] or 3
		if x ~= y then return x < y end
		return a < b
	end)
	if #names > 0 then Library.ThemeNames = names end

	local saved = decodeJSON(Files.read(folder .. "/settings.json"))
	saved = type(saved) == "table" and saved or {}
	if Palettes[saved.theme] then Library.Theme = saved.theme end
	Accent = fromHex(saved.accent) or Accent
	if saved.language == 0 or saved.language == 1 then Library.Language = saved.language end
	applyPalette()
	return saved
end

function Library:CreateWindow(o)
	o = o or {}
	buildScreen()
	preloadFonts()
	connectInput()
	local folder = o.Folder or "ElHoyoHub"
	local saved = loadSaved(folder)
	-- 1.5.0: la escala del usuario se respeta si la ventana cabe; si no, se usa la mayor que cabe (sin guardarla)
	local userScale = math.clamp(tonumber(saved.scale) or 1, Library.Layout.SCALE.min, Library.Layout.SCALE.max)
	local function fit()
		local px = viewport() * Scale
		local s, why = Library.Layout.fitScale({ px.X, px.Y }, userScale)
		if math.abs(s - Scale) > 1e-3 then setRasterScale(s) end
		return why, px
	end
	local fitWhy, px = fit()
	local view = viewport()
	-- posición guardada (validada: siempre se ve la cabecera) o centrada
	local sp = type(saved.position) == "table" and saved.position or nil
	local sx, sy = (sp and tonumber(sp[1])) or math.floor((view.X - 800) * 0.5), (sp and tonumber(sp[2])) or math.floor((view.Y - 600) * 0.5)
	sx, sy = Library.Layout.clampWindow({ sx, sy }, { 800, 600 }, { view.X, view.Y }, 0)
	local start = o.Position or Vector2.new(math.floor(sx), math.floor(sy))
	local frame = Box(Stage, start.X, start.Y, 800, 600)
	frame.Active, frame.Name, frame.ZIndex = true, "Menu", 10
	New("TextButton", { Modal = true, Text = "", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0) }, frame) -- frees a locked mouse
	local scope = newScope(Root)
	local win = setmetatable({
		frame = frame, scope = scope, position = start, dragTarget = start, tabs = {}, sideItems = {}, searchIndex = {}, Library = Library,
		folder = folder, saved = saved, store = { controls = {}, pending = {}, used = {} },
		userScale = userScale, autoScaled = fitWhy == "fit", restoreTab = saved.lastTab, compact = Library.Layout.compact({ px.X, px.Y }, Scale),
	}, WindowMeta)
	win.settingsStore = { controls = {}, pending = type(saved.values) == "table" and saved.values or {}, used = {} }
	table.insert(Windows, win)
	CurrentWindow = win

	local waiting, timer = false, 0
	local function writeSettings()
		local values = {}
		for id, value in win.settingsStore.pending do values[id] = value end
		for id, control in win.settingsStore.controls do values[id] = control.get() end
		local current = win.configs and win.configs.current()
		Files.write(folder .. "/settings.json", encodeJSON({
			theme = Library.Theme, accent = toHex(Accent), language = Library.Language, scale = win.userScale,
			lastConfig = current and current.name or nil, values = values,
			-- 1.5.0: última sección, grupos plegados y posición de la ventana
			lastTab = win.saved.lastTab, collapsed = (function()
				local out = {}
				for _, item in win.sideItems do if item.kind == "group" and item.collapsed then out[item.key] = true end end
				return out
			end)(), position = { math.floor(win.dragTarget.X), math.floor(win.dragTarget.Y) },
		}))
	end
	-- Dragging the accent colour changes it every frame, so writes wait for a pause.
	function win.queueSettings()
		timer = 0.4
		if waiting then return end
		waiting = true
		Run(function(dt)
			timer -= dt
			if timer > 0 then return true end
			waiting = false
			writeSettings()
			return false
		end)
	end
	win.settingsStore.onChange = win.queueSettings

	local side = Box(frame, 0, 0, 800, 600, T.Side, 14)
	Shadow(side, 22, 0.45, 4)
	local plate = Box(frame, 170, 0, 630, 600, T.Body, 14)
	local topClip = Box(frame, 170, 0, 630, 61)
	topClip.ClipsDescendants = true
	local topBar = Box(topClip, 0, 0, 630, 120, T.Top, 14)
	local topLine = Box(frame, 185, 60, 600, 1, T.Border)
	local sideLine = Box(frame, 10, 60, 150, 1, T.Border)
	local userLine = Box(frame, 10, 552, 150, 1, T.Border)
	scope:paint(function()
		side.BackgroundColor3, plate.BackgroundColor3, topBar.BackgroundColor3 = T.Side, T.Body, T.Top
		topLine.BackgroundColor3, sideLine.BackgroundColor3, userLine.BackgroundColor3 = T.Border, T.Border, T.Border
	end)

	-- wordmark, tracked by hand like the original
	local sideScope = newScope(scope)
	win.sideScope = sideScope
	local function tracked(text, x, y, size, font, spacing, alpha)
		local letters = {}
		local pen = x
		for i = 1, #text do
			local ch = string.sub(text, i, i)
			if ch ~= " " then table.insert(letters, Label(frame, ch, round(pen), y, size, font)) end
			pen += measure(ch, size, font) + spacing
		end
		sideScope:paint(function()
			for _, letter in letters do
				letter.TextColor3, letter.TextTransparency = T.Text, 1 - alpha * sideScope.alpha
			end
		end)
	end
	Logo(frame, 18, 14, 32, sideScope)
	tracked(o.Brand or "EL HOYO", 60, 15, 14, FontSemi, 0.935, 1)
	tracked(o.SubBrand or "HUB", 60, 31, 11, FontSemi, 2.17, 0.62)

	-- la barra lateral recorta (1.5.3: sin scroll propio; todo cabe o acordeón)
	win.sideClip = Box(frame, 10, 70, 150, Library.Layout.SIDE.height)
	win.sideClip.ClipsDescendants = true
	win.sideInner = Box(win.sideClip, 0, 0, 150, Library.Layout.SIDE.height)
	-- al cambiar el tamaño de la pantalla: reajustar la escala y que la ventana siga a la vista
	local camera = workspace.CurrentCamera
	if camera then
		connect(camera:GetPropertyChangedSignal("ViewportSize"), function()
			local why, now = fit()
			win.autoScaled = why == "fit"
			win.compact = Library.Layout.compact({ now.X, now.Y }, Scale)
			local v = viewport()
			local x, y = Library.Layout.clampWindow({ win.dragTarget.X, win.dragTarget.Y }, { 800, 600 }, { v.X, v.Y }, 0)
			win:dragTo(Vector2.new(math.floor(x), math.floor(y)))
		end)
	end

	-- content area
	local pagesScope = newScope(scope)
	win.pagesScope = pagesScope
	local pages = Box(frame, 185, 81, 600, 509)
	win.pages = pages
	win.pageAnim = Anim(0, 2.76, function(v)
		setXY(pages, 185, 81 - round(5 * v))
		pagesScope:setAlpha(v)
	end, 0.004)

	-- top bar
	local topScope = newScope(scope)
	win.topScope = topScope
	local presetPlate = Box(frame, 190, 15, 160, 30, T.FrameInactive, 6)
	local saveHit = Box(frame, 190, 15, 35, 30)
	local saveIcon = Glyph(frame, "SAVE", 14)
	saveIcon:center(190 + 17, 30)
	local divider = Box(frame, 225, 15, 1, 30, T.Divider)
	local dropHit = Box(frame, 225, 15, 125, 30)
	local dropClip = Box(frame, 225, 15, 100, 30)
	dropClip.ClipsDescendants = true
	local dropLabel = Label(dropClip, "", 0, capY(15, 12), 12)
	local dropChevron = Glyph(frame, "CHEVRON_DOWN", 14)
	local saveHot, dropHot, presetA = false, false, nil
	local function layoutTop()
		local current = win.configs and win.configs.current()
		local name = current and current.name or "None"
		local textW = measure(name, 12)
		local chevW = glyphContours("CHEVRON_DOWN").adv / 512 * 14
		local dropW = math.floor(clamp(textW + chevW + 40, 125, 300))
		local btnW = 35 + dropW
		setWH(presetPlate, btnW, 30)
		setWH(dropHit, dropW, 30)
		local labelArea = dropW - chevW - 24
		setWH(dropClip, 12 + labelArea, 30)
		setText(dropLabel, name, 12)
		setXY(dropLabel, round(12 + (labelArea - math.min(textW, labelArea)) * 0.5), capY(15, 12))
		dropChevron:center(190 + btnW - 12 - chevW * 0.5, 30)
	end
	local function paintTop()
		local a = topScope.alpha
		presetPlate.BackgroundColor3 = T.FrameInactive
		presetPlate.BackgroundTransparency = 1 - (0.5 + presetA.v * 0.3) * a
		saveIcon:paint(saveHot and Accent or T.Text, a)
		divider.BackgroundColor3, divider.BackgroundTransparency = T.Divider, 1 - A.Divider * a
		dropLabel.TextColor3, dropLabel.TextTransparency = T.Text, 1 - a
		dropChevron:paint(T.Disabled, a)
	end
	presetA = Anim(0, 15, paintTop)
	topScope:paint(paintTop)
	local function presetsChanged()
		layoutTop()
		paintTop()
	end
	win.configs = newConfigs(win, presetsChanged)
	win.configsChanged = presetsChanged
	layoutTop()
	local function updatePreset()
		presetA:to((saveHot or dropHot) and 1 or 0)
		paintTop()
	end
	Hit(topScope, saveHit, {
		hover = function(b) saveHot = b; updatePreset() end,
		click = function()
			local current = win.configs.current()
			if current then
				win.configs.save(win.configs.selected)
				pushNotification(tr("Config Saved"), string.format(tr("Saved changes to %s"), current.name))
			end
		end,
	})
	local openConfigs = buildConfigPopup(win, win.configs, presetsChanged)
	Hit(topScope, dropHit, { hover = function(b) dropHot = b; updatePreset() end, click = openConfigs })
	buildSearch(win)

	-- account block
	local lp = Players.LocalPlayer
	local profile = { name = o.UserName or lp.DisplayName, status = o.UserStatus or ("@" .. lp.Name), till = o.UserStatus or ("@" .. lp.Name) }
	local userHit = Box(frame, 10, 552, 150, 40)
	PlayerAvatar(userHit, 8, 5, 30, sideScope)
	local nameL = Label(userHit, "", 47, 7, 12)
	local subL = Label(userHit, "", 47, 21, 11)
	local chev = Glyph(userHit, "CHEVRON_RIGHT", 13)
	chev:center(150 - 10 - chev.boxW * 0.5, 20)
	local cardT = Anim(0, 15)
	local cardOpen = false
	local userCard
	local function paintUser()
		local a = sideScope.alpha
		setText(nameL, profile.name, 12)
		setText(subL, tr(profile.status), 11)
		nameL.TextColor3, nameL.TextTransparency = T.Text, 1 - a
		subL.TextColor3, subL.TextTransparency = T.Disabled, 1 - a
		chev:paint(T.Disabled:Lerp(T.Text, cardT.v), a)
	end
	cardT.cb = paintUser
	sideScope:paint(paintUser)
	local userHover = false
	Hit(sideScope, userHit, {
		hover = function(b) userHover = b; cardT:to((b or cardOpen) and 1 or 0) end,
		click = function()
			if not userCard then
				userCard = buildUserCard(win, profile)
				userCard.onState = function(state) cardOpen = state; cardT:to((state or userHover) and 1 or 0) end
			end
			userCard:open(0)
		end,
	})

	if o.ToggleKey ~= false then
		local key = o.ToggleKey or Enum.KeyCode.RightShift
		connect(UserInputService.InputBegan, function(input, processed)
			if not processed and input.KeyCode == key then
				frame.Visible = not frame.Visible
				if not frame.Visible then closePopupsTo(0) end
			end
		end)
	end
	win.Screen = Screen
	win.Notify = function(_, title, text, level) pushNotification(title, text, level) end
	Library.Notify = function(_, title, text, level) pushNotification(title, text, level) end
	return win
end

--[[ ---------------------------------------- Icon tabs, chips, ESP card -------------------- ]]

local function IconTabs(win, parent, scope, topRight, icons, labels, trailing, onClick)
	local h, pad, gap = 26, 9, 4
	local count = #icons
	local segs = {}
	local active, held = 1, nil
	local trailingHolder
	local function layout()
		local total = 0
		for i, seg in segs do
			seg.width = pad * 2 + seg.iconW + seg.open.v * (6 + measure(tr(labels[i]), 12))
			total += seg.width + gap
		end
		local trailingW = pad * 2 + trailing.iconW
		total += trailingW + gap * 2
		total -= gap
		local x = topRight - total
		for _, seg in segs do
			setXY(seg.frame, round(x), 0)
			setWH(seg.frame, round(seg.width), h)
			setWH(seg.plate, round(seg.width), h)
			x += seg.width + gap
		end
		x += gap
		setXY(trailing.frame, round(x), 0)
	end
	local function paintSeg(i)
		local seg = segs[i]
		local a = scope.alpha
		local plateA = math.max(seg.open.v, math.max(seg.hot.v, i == held and 1 or 0) * 0.5)
		seg.plate.BackgroundColor3, seg.plate.BackgroundTransparency = T.FrameInactive, 1 - 0.9 * plateA * a
		local color = T.Disabled:Lerp(T.Text, math.max(seg.hot.v, i == held and 1 or 0)):Lerp(Accent, seg.open.v)
		seg.glyph:paint(color, a)
		setText(seg.label, tr(labels[i]), 12)
		seg.label.TextColor3, seg.label.TextTransparency = color, 1 - seg.open.v * a
	end
	for i, name in icons do
		local frame = Box(parent, 0, 0, 40, h)
		frame.ClipsDescendants = true
		local plate = Box(frame, 0, 0, 40, h, T.FrameInactive, 8)
		local glyph = Glyph(frame, name, 14)
		glyph:center(pad + glyph.boxW * 0.5, 13)
		local label = Label(frame, "", round(pad + glyph.boxW + 6), capY(13, 12), 12)
		local seg = { frame = frame, plate = plate, glyph = glyph, label = label, iconW = glyph.boxW }
		seg.open = Anim(i == 1 and 1 or 0, 14, function() layout(); paintSeg(i) end)
		seg.hot = Anim(0, 15, function() paintSeg(i) end)
		segs[i] = seg
		scope:paint(function() paintSeg(i) end)
		Hit(scope, frame, {
			hover = function(b) seg.hot:to(b and 1 or 0) end,
			click = function()
				if i ~= count then
					active = i
					for k, s in segs do s.open:to(k == active and 1 or 0) end
				end
				onClick(i)
			end,
		})
	end
	local frame = Box(parent, 0, 0, 30, h)
	local plate = Box(frame, 0, 0, 30, h, T.FrameInactive, 8)
	local glyph = Glyph(frame, "EXPAND_ALT", 14)
	glyph:center(pad + glyph.boxW * 0.5, 13)
	trailing.frame, trailing.iconW = frame, glyph.boxW
	setWH(frame, round(pad * 2 + glyph.boxW), h)
	setWH(plate, round(pad * 2 + glyph.boxW), h)
	local hot = Anim(0, 15)
	local function paintTrailing()
		local a = scope.alpha
		plate.BackgroundColor3, plate.BackgroundTransparency = T.FrameInactive, 1 - 0.45 * hot.v * a
		glyph:paint(T.Disabled:Lerp(T.Text, hot.v), a)
	end
	hot.cb = paintTrailing
	scope:paint(paintTrailing)
	Hit(scope, frame, { hover = function(b) hot:to(b and 1 or 0) end, click = function() onClick(count + 1) end })
	scope:paint(layout)
	return { setHeld = function(i)
		held = i
		for k in segs do paintSeg(k) end
	end }
end

local function Chips(flow, labels, getValues, refreshers)
	local h, pad, gap, gapY = 24, 11, 6, 10
	local avail, origin = flow.rw, flow.y
	local x, y = 0, 0
	local scope = flow.scope
	for i, label in labels do
		local width = math.ceil(measure(tr(label), 12) + pad * 2)
		if x > 0 and x + width > avail then
			x = 0
			y += h + gapY
		end
		local chip = Box(flow.parent, flow.x + x, origin + y, width, h, T.FrameInactive, 8)
		local stroke = Stroke(Box(chip, 1, 1, width - 2, h - 2, nil, 7), Accent)
		local text = Label(chip, "", pad, capY(12, 12), 12)
		local hot, on = Anim(0, 15), Anim(getValues()[i] and 1 or 0, 14)
		local function paint()
			local a = scope.alpha
			local bgAlpha = (0.55 + 0.35 * hot.v) + ((0.22 + 0.08 * hot.v) - (0.55 + 0.35 * hot.v)) * on.v
			chip.BackgroundColor3 = T.FrameInactive:Lerp(Accent, on.v)
			chip.BackgroundTransparency = 1 - bgAlpha * a
			stroke.Color, stroke.Transparency = Accent, 1 - 0.55 * on.v * a
			setText(text, tr(label), 12)
			text.TextColor3 = T.Disabled:Lerp(T.Text, hot.v):Lerp(Accent, on.v)
			text.TextTransparency = 1 - a
		end
		hot.cb, on.cb = paint, paint
		scope:paint(paint)
		Hit(scope, chip, {
			hover = function(b) hot:to(b and 1 or 0) end,
			click = function()
				local values = getValues()
				values[i] = not values[i]
				on:to(values[i] and 1 or 0)
			end,
		})
		table.insert(refreshers, function() on:to(getValues()[i] and 1 or 0) end)
		x += width + gap
	end
	flow.y = origin + y + h
end

local function buildAmbience(win)
	local frame = win.frame
	local clip = Box(frame, 170, 0, 630, 600)
	clip.ClipsDescendants = true
	clip.Visible = false
	clip.ZIndex = 40
	local scrim = Box(clip, -20, 0, 650, 600, T.Body, 20)
	local edge = Box(clip, 0, 0, 1, 600, T.Border)
	local scope = newScope(win.scope)
	scope.inert = true
	local content = newScope(scope)
	local holder = Box(clip, 0, 0, 630, 600)
	local state = 0
	local isOpen = false
	local function paint()
		local scrimA = sat(state / 0.45)
		scrim.BackgroundColor3, scrim.BackgroundTransparency = T.Body, 1 - scrimA
		edge.BackgroundColor3, edge.BackgroundTransparency = T.Border, 1 - 0.6 * scrimA
	end
	scope:paint(paint)
	local function apply()
		paint()
		content:setAlpha(math.max(sat((state - 0.45) / 0.55), 0.0001))
		clip.Visible = state > 0
	end
	local function setOpen(open)
		isOpen = open
		scope.inert = not open
		win.sideScope.inert = open
		win.pagesScope.inert = open
		win.topScope.inert = open
		Run(function(dt)
			if isOpen then
				state += (1 - state) * (1 - math.exp(-15 * dt))
				if state > 0.998 then state = 1 end
			else
				state = math.max(0, state - dt / 0.16)
				if state < 0.01 then state = 0 end
			end
			apply()
			return not ((isOpen and state == 1) or state == 0)
		end)
	end
	-- corner buttons
	IconButton(holder, content, "TIMES", 630 - 14 - 24, 12, 24, 24, DimHot, function() setOpen(false) end)
	IconButton(holder, content, "ELLIPSIS_H", 630 - 14 - 48 - 2, 12, 24, 24, DimHot, function() end)
	local gap = 14
	local usable = 630 - gap * 2 - gap
	local w1 = math.floor(usable * 0.454)
	local w2 = usable - w1
	-- left column: no box round the map list
	local title = Label(holder, "", gap + 12, 46, 11, FontSemi)
	content:paint(function()
		setText(title, tr("MAP SELECTION"), 11, FontSemi)
		title.TextColor3, title.TextTransparency = T.Title, 1 - 0.5 * content.alpha
	end)
	local left = newFlow({ parent = holder, scope = content, x = gap, y = 46 + 18, w = w1, rw = w1, spacing = gap, win = win })
	local mapRows = {}
	local mapChoice = 1
	local function pickMap(i)
		mapChoice = i
		for k, r in mapRows do r:Select(k == i) end
	end
	win:Flag("Ambience/MAP SELECTION", function() return mapChoice end, function(v) if mapRows[v] then pickMap(v) end end)
	mapRows[1] = left:Framed("Global", { Selected = true, ActionIcon = "ELLIPSIS_H", Action = function() end, Callback = function() pickMap(1) end, Width = w1 })
	mapRows[2] = left:Framed("Main Menu", { ActionIcon = "FILE_IMPORT", ActionLabel = "Add", Action = function() pushNotification(tr("Ambience"), tr("Added the current map")) end, Callback = function() pickMap(2) end, Width = w1 })
	if mapChoice ~= 1 then pickMap(mapChoice) end
	-- right column: the effects box
	local boxX = gap + w1 + gap
	local holderBox = Box(holder, boxX, 46, w2, 400)
	local fill = Box(holderBox, 0, 18, w2, 380, T.Group, 13)
	local lineF = Box(holderBox, 1, 19, w2 - 2, 378, nil, 12)
	local line = Stroke(lineF, T.Border)
	local boxTitle = Label(holderBox, "", 12, 0, 11, FontSemi)
	local inner = Box(holderBox, 0, 18, w2, 380)
	local flow = newFlow({ parent = inner, scope = content, x = 12, y = 6, w = w2 - 24, rw = w2 - 24, spacing = 6, separators = true, level = 0, win = win, path = "Ambience/EFFECTS", store = win.store })
	flow.hostRight = function() return toStage(holderBox.AbsolutePosition).X + w2 end
	content:paint(function()
		local a = content.alpha
		fill.BackgroundColor3, fill.BackgroundTransparency = T.Group, 1 - a
		line.Color, line.Transparency = T.Border, 1 - a
		setText(boxTitle, tr("EFFECTS"), 11, FontSemi)
		boxTitle.TextColor3, boxTitle.TextTransparency = T.Title, 1 - 0.5 * a
	end)
	local fxColors = {
		Color3.new(.66, .62, .86), Color3.new(1, 1, 1), Color3.new(.85, .85, .88), Color3.new(.88, .88, .92), Color3.new(1, 1, 1), Color3.new(.8, .84, .92),
		Color3.new(.9, .9, .95), Color3.new(1, 1, 1), Color3.new(.86, .88, .95), Color3.new(.84, .86, .94), Color3.new(.82, .86, .96),
	}
	local fxLabels = { "Nightmode", "Fullbright", "Exposure", "Sunlight", "Sky", "Fog", "Bloom", "Vignette", "Local Contrast", "Color Correction", "Depth of Field" }
	local fxDots = { false, false, true, false, false, false, true, false, true, true, true }
	for i, label in fxLabels do
		if fxDots[i] then
			flow:Toggle({ Name = label, Tip = false, Options = function(f)
				f:Option("ADJUST", "Mode", { "Default", "Soft", "Strong" }, 1)
				f:Separator()
				f:Section({ Border = false }, function(s) s:Slider({ Name = "Amount", Min = 0, Max = 100, Default = 50 }) end)
			end })
		else
			flow:Toggle({ Name = label, Tip = false, Color = newColor(fxColors[i]) })
		end
	end
	flow:SubMenu({ Name = "Weather", Build = function(c)
		c:Section({ Border = true }, function(s)
			s:Toggle({ Name = "[WIND]Wind", Tip = false, Options = function(f) f:PopupToggle("TREE", "Affect Foliage", false) end })
			s:Toggle({ Name = "[TINT]Model Wetness", Tip = false, Options = function(f) f:PopupToggle("USER", "Players Only", false) end })
		end)
		c:Section({ Border = true }, function(s)
			s:Toggle({ Name = "[BOLT]Thunder", Tip = false, Color = newColor(Color3.new(.44, .69, 1)) })
			s:Toggle({ Name = "[CLOUD_SHOWERS]Rain", Tip = false, Color = newColor(Color3.new(.86, .91, 1)) })
			s:Toggle({ Name = "[SNOWFLAKE]Snow", Tip = false, Color = newColor(Color3.new(.95, .95, .97)) })
		end)
	end })
	flow:SubMenu({ Name = "Removals", Build = function(c)
		c:Section({ Border = true }, function(s)
			s:Toggle({ Name = "Smoke", Tip = false })
			s:Toggle({ Name = "Flashbang", Tip = false })
			s:Toggle({ Name = "Scope Blur", Tip = false })
		end)
	end })
	local total = flow.y - 6 + 6 + 18
	setWH(holderBox, w2, total)
	setWH(fill, w2, total - 18)
	setWH(lineF, w2 - 2, total - 20)
	setWH(inner, w2, total - 18)
	apply()
	return function() setOpen(true) end
end

--[[ ---------------------------------------- Demo ------------------------------------------ ]]

function Library:Demo(o)
	local win = Library:CreateWindow(o)
	local function rows(box, count, default)
		for i = 1, count do box:Toggle({ Name = tostring(i), Default = default }) end
	end
	local items = { "Head", "Chest", "Stomach", "Legs" }

	win:Group("AIMBOT")
	local rage = win:Tab({ Name = "Rage", Icon = "CROSSHAIRS" })
	local legit = win:Tab({ Name = "Legit", Icon = "MOUSE" })
	win:Group("COMMON")
	local visuals = win:Tab({ Name = "Visuals", Icon = "IMAGE" }):EnableChildren()
	local players = win:Tab({ Name = "Players", Icon = "USER", Parent = visuals })
	local world = win:Tab({ Name = "World", Icon = "GLOBE", Parent = visuals })
	local shader = win:Tab({ Name = "Shader", Icon = "MAGIC", Parent = visuals })
	local misc = win:Tab({ Name = "Miscellaneous", Icon = "SLIDERS_H" })

	-- Rage
	local main = rage:Box({ Name = "MAIN", Column = 1 })
	main:Toggle({ Name = "Enabled", Default = true })
	main:Toggle({ Name = "Silent Aim", Default = true })
	main:Toggle({ Name = "Automatic Fire", Default = true })
	main:Toggle({ Name = "Aim Through Walls", Default = true })
	main:Slider({ Name = "Field Of View", Min = 0, Max = 180, Default = 90, Tip = "Adjust the field of view in degrees." })
	rows(rage:Box({ Name = "SELECTION", Column = 1 }), 6, true)
	rows(rage:Box({ Name = "OTHER", Column = 2 }), 6, true)
	local anti = rage:Box({ Name = "ANTI-AIM", Column = 2 })
	anti:Toggle({ Name = "Enabled", Default = false })
	local function pitchBody(card)
		card:Section({ Border = true }, function(s)
			s:Toggle({ Name = "Checkbox", Default = true })
			s:Combo({ Name = "Combo", Options = items, Tip = "Select one item from the list." })
			s:Multi({ Name = "Multi", Options = items, Default = { true, true, true, false }, Tip = "Select one or more items. Click a selected item again to remove it." })
		end)
		card:Section({ Border = true }, function(s)
			s:Toggle({ Name = "[RUNNING]Checkbox" })
			s:Toggle({ Name = "[AWARD]Checkbox", Tip = "Hello, this is info box!" })
			s:Toggle({ Name = "Checkbox" })
			s:Slider({ Name = "Slider", Min = 0, Max = 100, Default = 90, Tip = "Drag the bar to adjust the value from 0 to 100." })
		end)
	end
	for _, name in { "Pitch", "Yaw", "Freestanding", "Mouse Override" } do
		anti:SubMenu({ Name = name, Build = pitchBody })
	end

	-- Legit
	local baby = legit:Box({ Name = "Baby", Column = 1, Height = -0.5 })
	baby:Toggle({ Name = "Kill Effect", Default = true, Color = newColor(Color3.new(.96, .22, .3)) })
	baby:Color({ Name = "Additional Colors", Color = newColor(Color3.new(1, .22, .3), 1, Color3.new(1, .58, .66), 1, true) })
	baby:Toggle({ Name = "Glow", Tip = false, Color = newColor(Color3.new(.32, .49, .99)), ColorExtras = function(f)
		f:Section({ Border = false }, function(s)
			s:Slider({ Name = "Spread Force", Min = 0, Max = 100, Default = 20 })
			s:Slider({ Name = "Speed", Min = 0, Max = 100, Default = 45 })
		end)
	end })
	baby:Toggle({ Name = "Name", Tip = false, Color = newColor(White, 210 / 255), ColorExtras = function(f)
		f:Option("FONT", "Font", { "Regular", "Bold", "Italic" }, 1)
		f:Option("FONT_CASE", "Case", { "Default", "Uppercase", "Lowercase" }, 1)
		f:Separator()
		f:PopupToggle("USER_CIRCLE", "Draw Avatar", false)
	end })
	local function trajectory(f)
		f:Option("PROJECT_DIAGRAM", "Style", { "Line", "Dots", "Arrows" }, 1)
		f:PopupToggle("SKULL", "Show On Death", true)
		f:Separator()
		f:Section({ Border = false }, function(s) s:Slider({ Name = "Opacity", Min = 0, Max = 100, Default = 80 }) end)
	end
	local ad = legit:Box({ Name = "Ad", Column = 1, Height = 0 })
	ad:Toggle({ Name = "Grenade Trajectory", Tip = false, Options = trajectory })
	ad:SubMenu({ Name = "Weather", Build = function(c)
		c:Section({ Border = true }, function(s)
			s:Toggle({ Name = "[WIND]Wind", Tip = false })
			s:Toggle({ Name = "[TINT]Model Wetness", Tip = false })
		end)
		c:Section({ Border = true }, function(s)
			s:Toggle({ Name = "[BOLT]Thunder", Tip = false, Color = newColor(Color3.new(.66, .8, 1)) })
			s:Toggle({ Name = "[CLOUD_SHOWERS]Rain", Tip = false, Color = newColor(Color3.new(.86, .91, 1)) })
			s:Toggle({ Name = "[SNOWFLAKE]Snow", Tip = false, Color = newColor(Color3.new(.95, .95, .97)) })
		end)
	end })
	local nonIcon = legit:Box({ Name = "Non icon name", Column = 2, Height = 0 })
	nonIcon:Color({ Name = "Layout", Slots = {
		{ name = "Layout", value = newColor(Color3.new(.08, .08, .08)) }, { name = "Background", value = newColor(Black) },
		{ name = "Border", value = newColor(Color3.new(.16, .17, .21)) }, { name = "Accent", value = newColor(Color3.new(.32, .49, .99)) },
		{ name = "Text", value = newColor(Color3.new(.55, .56, .6)) },
	} })

	-- Players
	local enemy = players:Box({ Name = "ENEMY", Column = 1 })
	enemy:Toggle({ Name = "Enabled" })
	enemy:Toggle({ Name = "Offscreen Arrow", Color = newColor(White) })
	enemy:Toggle({ Name = "Sounds", Color = newColor(Color3.new(1, .29, .47)) })
	local model = players:Box({ Name = "ENEMY MODEL", Column = 1 })
	local modes = { "Disabled", "Flat", "Glow", "Chams" }
	model:Combo({ Name = "Player", Options = modes, Color = newColor(Color3.new(.45, .45, .95)) })
	model:Combo({ Name = "Behind Walls", Options = modes, Color = newColor(Color3.new(.36, .9, .9)) })
	model:Combo({ Name = "On Shot", Options = modes, Color = newColor(Color3.new(.8, .86, .86)) })
	model:Combo({ Name = "History", Options = modes, Color = newColor(Color3.new(.85, .85, .87)) })
	model:Combo({ Name = "Ragdolls", Options = modes, Color = newColor(Color3.new(.69, .66, .85)) })
	model:Toggle({ Name = "Kill Effect", Color = newColor(Color3.new(.96, .22, .3)) })
	model:Toggle({ Name = "Glow", Color = newColor(Color3.new(.72, .73, .98)) })
	do
		local page, scope = players.page, players.pageScope
		local espCard
		local sections = {
			{ "Main", { "Bounding Box", "Name", "Distance", "Health Bar", "Ammo Bar", "Skeleton" } },
			{ "Flags", { "Unarmored", "Defuser", "Blind", "Scoped", "Reload", "Immunity", "Slowed", "Vulnerable", "Bomb", "Hostage", "Defuse", "Pin Pulled", "Money", "Order Priority", "Delay" } },
			{ "Weapon", { "Text", "Icon", "Readiness Bar", "Bomb", "Defuser", "Taser" } },
			{ "Aimbot", { "Hit Chance", "Hitboxes" } },
		}
		-- section -> side (1 Enemies, 2 Friends) -> ticked chips; each side keeps its own set
		local espValues = {
			{ { true, true, false, true, false, false }, { true, false, false, false, false, false } },
			{ {}, {} }, { { true, false, false, false, false, false }, {} }, { {}, {} },
		}
		local espSide = 1
		local refreshers = {}
		local function refreshChips()
			for _, refresh in refreshers do refresh() end
		end
		for i, section in sections do
			for side, sideName in { "Enemies", "Friends" } do
				win:Flag("Players/ESP Items/" .. section[1] .. "/" .. sideName, function()
					local names = {}
					for k, label in section[2] do
						if espValues[i][side][k] then table.insert(names, label) end
					end
					return names
				end, function(names)
					if type(names) ~= "table" then return end
					for k, label in section[2] do espValues[i][side][k] = table.find(names, label) ~= nil end
					refreshChips()
				end)
			end
		end
		local tabsObj
		local espOpen = false
		local handleHot, handleTurn
		local function ensureCard()
			if espCard then return espCard end
			espCard = newCard({
				width = 296, padding = 12, name = "EspItems",
				place = function(c)
					local a = toStage(page.AbsolutePosition)
					return keepOnScreen(c, a.X + 304, a.Y + 34)
				end,
				build = function(c)
					local title = Label(c.content, "", 13, capY(20, 14), 14, FontSemi)
					c.scope:paint(function()
						setText(title, tr("ESP Items"), 14, FontSemi)
						title.TextColor3, title.TextTransparency = T.Text, 1 - c.scope.alpha
					end)
					local flow = newFlow({ parent = c.content, scope = c.scope, x = 12, y = 36, w = 272, rw = 272, card = c, level = c.level, win = win })
					for i, section in sections do
						flow:Section({ Border = true, Pad = 10, Inset = 10 }, function(s)
							local head = Label(s.parent, "", s.x, s.y + capY(7.5, 12), 12)
							s.scope:paint(function()
								setText(head, tr(section[1]), 12)
								head.TextColor3, head.TextTransparency = T.Text, 1 - s.scope.alpha
							end)
							s.y += 15 + 10
							Chips(s, section[2], function() return espValues[i][espSide] end, refreshers)
						end)
					end
					c:setHeight(flow:bottom() + 12)
				end,
			})
			espCard.onState = function(state)
				espOpen = state
				tabsObj.setHeld(state and 3 or nil)
				handleTurn:to(state and 1 or 0)
				handleHot:to(state and 1 or 0)
			end
			return espCard
		end
		-- chip widths depend on the language, so the card is rebuilt the next time it opens
		win.onLanguage = function()
			if espCard then
				espCard:destroy()
				espCard = nil
				table.clear(refreshers)
			end
		end
		tabsObj = IconTabs(win, page, scope, 600, { "USER", "USER_MINUS", "LIST_ALT" }, { "Enemies", "Friends", "ESP Items" }, {}, function(i)
			if i == 3 then
				ensureCard():open(0)
			elseif i <= 2 then
				espSide = i
				refreshChips()
			end
		end)
		-- the pull-up handle: a clip keeps the single plate's bottom edge square
		local hw, hh = 46, 18
		local handle = Box(page, round(304 + (296 - hw) * 0.5), 509 - hh, hw, hh)
		handle.ClipsDescendants = true
		local handlePlate = Box(handle, 0, 0, hw, hh * 2, T.FrameInactive, 9)
		local upChev = Shape(handle, strokeContours({ -4.5, 3, 0, -3, 4.5, 3 }, 1.6), 1, "HANDLE_U"):at(hw * 0.5, hh * 0.5)
		local dnChev = Shape(handle, strokeContours({ -4.5, -3, 0, 3, 4.5, -3 }, 1.6), 1, "HANDLE_D"):at(hw * 0.5, hh * 0.5)
		local function paintHandle()
			local a = scope.alpha
			local hot = handleHot.v
			handlePlate.BackgroundColor3 = T.FrameInactive
			handlePlate.BackgroundTransparency = 1 - (0.55 + 0.35 * hot) * a
			local color = T.Disabled:Lerp(T.Text, hot)
			upChev:paint(color, a * (1 - handleTurn.v))
			dnChev:paint(color, a * handleTurn.v)
		end
		handleHot, handleTurn = Anim(0, 15, paintHandle), Anim(0, 14, paintHandle)
		scope:paint(paintHandle)
		Hit(scope, handle, {
			hover = function(b) handleHot:to((b or espOpen) and 1 or 0) end,
			click = function() ensureCard():open(0) end,
		})
	end

	-- World
	local function worldPopup(card)
		card:Section({ Border = true }, function(s)
			s:Toggle({ Name = "Enabled", Default = true, Tip = false })
			s:Combo({ Name = "Style", Options = { "Default", "Filled", "Outlined" } })
			s:Toggle({ Name = "Outline", Tip = false })
		end)
		card:Section({ Border = false }, function(s) s:Slider({ Name = "Size", Min = 0, Max = 100, Default = 45 }) end)
	end
	local selectItems, overlayItems = { "Select", "Always", "In Air", "On Key" }, { "Default", "Classic", "Minimal" }
	local openAmbience = buildAmbience(win)
	local view = world:Box({ Name = "VIEW", Column = 1, RowSpacing = 7, PadY = 6 })
	for _, name in { "View Options", "Scope Options", "Viewmodel Options", "Perspective Options" } do view:SubMenu({ Name = name, Build = worldPopup }) end
	view:Combo({ Name = "Unlock Spectating", Options = selectItems })
	view:Combo({ Name = "Visual Recoil", Options = selectItems })
	local worldEsp = world:Box({ Name = "WORLD ESP", Column = 1, RowSpacing = 7, PadY = 6 })
	for _, name in { "Bomb", "Weapons", "Hostages", "Grenades" } do worldEsp:SubMenu({ Name = name, Build = worldPopup }) end
	worldEsp:Toggle({ Name = "Grenade Trajectory", Tip = false, Options = trajectory })
	worldEsp:Toggle({ Name = "Grenade Proximity Warnings" })
	local hud = world:Box({ Name = "HUD", Column = 2, RowSpacing = 7, PadY = 6 })
	hud:Combo({ Name = "Radar", Options = selectItems })
	hud:Combo({ Name = "Scope Overlay", Options = overlayItems })
	hud:Toggle({ Name = "Inaccuracy Overlay", Color = newColor(Color3.new(.62, .64, .7)) })
	for _, name in { "Death Notices", "Scoreboard", "Crosshairs" } do hud:SubMenu({ Name = name, Build = worldPopup }) end
	local miscWorld = world:Box({ Name = "MISCELLANEOUS", Column = 2, RowSpacing = 7, PadY = 6 })
	miscWorld:SubMenu({ Name = "Windows", Build = worldPopup })
	miscWorld:SubMenu({ Name = "Removals", Build = worldPopup })
	miscWorld:SubMenu({ Name = "Ambience", Tip = "Per-map lighting and weather.", Callback = openAmbience })
	for _, name in { "Hit Marker", "Bullet Tracers", "Bullet Impacts" } do miscWorld:SubMenu({ Name = name, Build = worldPopup }) end

	-- Shader: the controls are all here, but Roblox has no shaders to run them with.
	shader:Columns({ 0.42, 0.58 })
	local background = shader:Box({ Name = "BACKGROUND", Column = 1 })
	background:Toggle({ Name = "Enabled", Tip = "Draw the selected effect behind the menu's panels.", Options = function(f)
		f:Section({ Border = false }, function(s)
			s:Slider({ Name = "Opacity", Min = 0, Max = 100, Default = 35, Format = "%d%%" })
			s:Slider({ Name = "Speed", Min = 0, Max = 300, Default = 100, Format = "%d%%" })
		end)
	end })
	background:Toggle({ Name = "Blur On Shader", Tip = "Blur the selected effect behind the menu.", OptionsWidth = 240, Options = function(f)
		f:Section({ Border = false }, function(s) s:Slider({ Name = "Blur Intensity", Min = 0, Max = 30, Default = 8, Format = "%d px" }) end)
	end })
	local effect = shader:Box({ Name = "EFFECT", Column = 2, Height = 0, Scrollable = true, RowSpacing = 3, PadY = 6 })
	local effects = {
		{ "Plasma", "FIRE" }, { "Galaxy", "STAR" }, { "Liquid Ether", "WATER" }, { "Liquid Chrome", "TINT" }, { "Color Bends", "PALETTE" }, { "Light Rays", "SUN" },
		{ "Lightning", "BOLT" }, { "Line Waves", "WAVE_SQUARE" }, { "Particles", "ATOM" }, { "Pixel Snow", "SNOWFLAKE" }, { "Prism", "GEM" }, { "Prismatic Burst", "CERTIFICATE" },
		{ "Liquid Glass", "ADJUST" }, { "Mesh Gradient", "FILL_DRIP" }, { "Aurora", "MOUNTAIN" }, { "Dot Matrix", "TH" }, { "Hex Grid", "TH_LARGE" }, { "Starfield Warp", "ROCKET" },
		{ "Voronoi", "VECTOR_SQUARE" }, { "Rain on Glass", "CLOUD_RAIN" }, { "Click Ripple", "BULLSEYE" },
	}
	local effectRows, picked = {}, 1
	local function pickEffect(i)
		picked = i
		for k, row in effectRows do row:Select(k == picked) end
	end
	for i, item in effects do
		effectRows[i] = effect:Framed("[" .. item[2] .. "]" .. item[1], {
			Selected = i == 1,
			Callback = function() pickEffect(i) end,
		})
	end
	win:Flag("Shader/EFFECT/Selected", function() return picked end, function(v) if effectRows[v] then pickEffect(v) end end)

	win:Finish()
	return win
end

function Library:Unload()
	for _, connection in Connections do connection:Disconnect() end
	table.clear(Connections)
	Connected = false -- si se vuelve a crear una ventana con esta misma copia, que reconecte la entrada
	table.clear(Moving)
	table.clear(Tickers)
	table.clear(Popups)
	table.clear(Windows)
	Hover, Held, Dragging = nil, nil, nil
	if Screen then Screen:Destroy() end
	Screen = nil
end

-- Running the file again replaces the previous copy instead of stacking on top of it.
if type(_G) == "table" then
	if type(_G.ElHoyoUI) == "table" and _G.ElHoyoUI.Unload then
		pcall(_G.ElHoyoUI.Unload, _G.ElHoyoUI)
	end
	_G.ElHoyoUI = Library
end
end

return Library
end
__modules["Console"] = function(...)
-- Console: la ventana de registro del hub (arrastrable, ⌫ borrar, × cerrar, máx. 150 líneas) y log().
-- Movida tal cual desde src/main.lua (1.4.0): mismo aspecto y comportamiento. El hub le inyecta lo que usa.
-- deps = { gui, C (colores), UIS, UI (librería, para Notify), life, config, T, cleanup }
-- Devuelve { frame, set(show), shown(), log(msg, nivel, notify), setTitle(texto), onVisible = nil (lo pone el hub) }.
local Console = {}

function Console.new(deps)
local gui, C, UIS, UI, life, config, T, cleanup = deps.gui, deps.C, deps.UIS, deps.UI, deps.life, deps.config, deps.T, deps.cleanup
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
local api = {} -- api.onVisible(show): aviso al hub (Components) cada vez que se muestra u oculta
local function setConsole(show)
	consoleShown = show
	consoleWin.Visible = show
	if api.onVisible then api.onVisible(show) end
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
	if not life.alive then return end
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
	life.defer(function()
		consoleList.CanvasPosition = Vector2.new(0, consoleList.AbsoluteCanvasSize.Y)
	end)
	if UI.Notify and (level == "error" or (config.notify and (notify or level == "warn"))) then
		local title = level == "error" and "Error" or level == "warn" and T("Aviso", "Warning") or "El Hoyo Hub"
		pcall(UI.Notify, UI, title, msg, level) -- 1.5.0: el nivel da el color
	end
end
api.frame = consoleWin
api.set = setConsole
api.shown = function() return consoleShown end
api.log = log
api.setTitle = function(text) consoleTitle.Text = text end
return api
end

return Console
end
__modules["Ownership"] = function(...)
-- Ownership: quién encendió cada interruptor. Una automatización pide (want on) o suelta (want off) un
-- interruptor; solo se apaga cuando lo suelta el último que lo pidió. Lo que encendió el usuario (o un perfil)
-- no tiene dueño y ninguna automatización lo apaga.
-- toggles[nombre] = { value, set(v), onChange(v), noSave, transient }
local Ownership = {}

function Ownership.new(toggles, spawn)
	local self = { owners = {} }

	-- El usuario (o un perfil) cambió el interruptor: deja de ser de nadie
	function self.userChanged(name)
		self.owners[name] = nil
	end

	function self.want(name, owner, on)
		local t = toggles[name]
		if not t then return false end
		local set = self.owners[name]
		if on then
			if not t.value then
				self.owners[name] = { [owner] = true }
				t.set(true)
				spawn(t.onChange, true)
			elseif set then
				set[owner] = true
			end
		elseif set and set[owner] then
			set[owner] = nil
			if next(set) == nil then
				self.owners[name] = nil
				if t.value then
					t.set(false)
					spawn(t.onChange, false)
				end
			end
		end
		return true
	end

	-- Apaga las funciones (no los ajustes). sync = esperar a que cada una se apague (al cerrar el hub).
	function self.turnAllOff(sync)
		local n = 0
		for _, t in toggles do
			if t.value and (not t.noSave or t.transient) then
				t.set(false)
				if sync then pcall(t.onChange, false) else spawn(t.onChange, false) end
				n += 1
			end
		end
		table.clear(self.owners)
		return n
	end

	------------------------------------------------------------------ Recursos compartidos (1.5.2)
	-- Turnos de recursos que varias funciones usan a la vez: "move" (mover el personaje; el antiguo busy/claimMove)
	-- y "hand" (la herramienta equipada). Coordinación: un dueño por recurso; una petición de otro se deniega y se
	-- apunta; `preempt` (la Huida) quita el turno y, al soltarlo, se lo DEVUELVE al anterior (antes se perdía).
	-- `use` solo observa (no bloquea): apunta usos solapados, para detectar conflictos sin cambiar el comportamiento.
	-- epoch = personaje actual: tras reaparecer, lo pedido con el personaje anterior se marca como referencia vieja.
	local clock = os.clock
	self.leases, self.stack, self.uses, self.events, self.epoch = {}, {}, {}, {}, 1
	self.MAX_EVENTS = 40
	local function event(kind, resource, owner, detail)
		table.insert(self.events, { kind = kind, resource = resource, owner = owner, detail = detail, at = clock(), epoch = self.epoch })
		if #self.events > self.MAX_EVENTS then table.remove(self.events, 1) end
	end
	self.event = event
	function self.setClock(fn) clock = fn end

	function self.holder(resource)
		local l = self.leases[resource]
		return l and l.owner or nil
	end
	-- Pide el turno. Devuelve ok y quién lo tiene. opts.preempt: lo quita a quien lo tenga (y se lo devuelve luego)
	function self.acquire(resource, owner, opts)
		local l = self.leases[resource]
		if l and l.owner == owner then
			l.epoch = self.epoch
			return true, owner
		end
		if l and not (opts and opts.preempt) then
			event("denied", resource, owner, l.owner)
			return false, l.owner
		end
		if l then
			self.stack[resource] = self.stack[resource] or {}
			table.insert(self.stack[resource], l)
			event("preempted", resource, owner, l.owner)
		end
		self.leases[resource] = { owner = owner, at = clock(), epoch = self.epoch }
		return true, owner
	end
	-- Suelta el turno. Si no lo tenía (ya lo soltó otro, p. ej. al apagar la función), se apunta como liberación tardía.
	function self.release(resource, owner)
		local l = self.leases[resource]
		if not l or l.owner ~= owner then
			-- también puede estar guardado debajo de quien se lo quitó: se borra de ahí
			local st = self.stack[resource]
			for i = #(st or {}), 1, -1 do
				if st[i].owner == owner then table.remove(st, i); return true end
			end
			event("late_release", resource, owner, l and l.owner or nil)
			return false
		end
		local st = self.stack[resource]
		local prev = st and table.remove(st)
		self.leases[resource] = prev
		if prev then event("restored", resource, prev.owner, owner) end
		return true
	end
	-- Uso observado (sin bloquear): devuelve una función para terminarlo. Si otro lo estaba usando, conflicto.
	function self.use(resource, owner)
		local list = self.uses[resource] or {}
		self.uses[resource] = list
		for _, u in list do
			if u.owner ~= owner then event("overlap", resource, owner, u.owner) end
		end
		local entry = { owner = owner, at = clock(), epoch = self.epoch }
		table.insert(list, entry)
		return function()
			local i = table.find(list, entry)
			if i then table.remove(list, i) end
		end
	end
	-- ¿Quién está usando el recurso (aparte de except)? Para que una función espere en vez de pisar a otra.
	function self.inUse(resource, except)
		for _, u in self.uses[resource] or {} do
			if u.owner ~= except then return u.owner end
		end
		return nil
	end
	-- ¿Alguien pidió el recurso a su dueño hace menos de `window` s y se le denegó? (para ceder el turno)
	function self.wanted(resource, holder, window)
		local now = clock()
		for i = #self.events, 1, -1 do
			local e = self.events[i]
			if now - e.at > (window or 3) then break end
			if e.kind == "denied" and e.resource == resource and e.detail == holder then return e.owner end
		end
		return nil
	end
	-- Personaje nuevo (reaparición): lo pedido con el anterior queda como referencia vieja. Los usos de la mano se
	-- cierran (la herramienta del cuerpo anterior ya no existe); los turnos de movimiento se avisan, no se quitan.
	function self.newEpoch(reason)
		self.epoch += 1
		for resource, l in self.leases do
			if l.epoch < self.epoch then event("stale", resource, l.owner, reason) end
		end
		for resource, list in self.uses do
			for _, u in list do event("stale_use", resource, u.owner, reason) end
			table.clear(list)
		end
		return self.epoch
	end
	-- Turnos que llevan demasiado (posible recurso sin liberar)
	function self.leaked(maxAge)
		local out, now = {}, clock()
		for resource, l in self.leases do
			if now - l.at > (maxAge or 300) then table.insert(out, { resource = resource, owner = l.owner, age = now - l.at }) end
		end
		return out
	end
	-- Resumen para el Diagnóstico
	function self.coordination()
		local counts = {}
		for _, e in self.events do counts[e.kind] = (counts[e.kind] or 0) + 1 end
		local held = {}
		for resource, l in self.leases do held[resource] = l.owner end
		return { held = held, counts = counts, events = self.events, epoch = self.epoch }
	end
	return self
end

return Ownership
end
__modules["Protection"] = function(...)
-- Protection: la DECISIÓN de la Huida automática (1.5.2), separada de Roblox para poder probarla con simulaciones.
-- No añade capacidades: misma regla que antes (vida bajo el límite -> sube; vuelve al 90 % o a los 60 s), con los
-- fallos de 1.5.0 corregidos (no se paraba al apagarla, decía "recuperado" al agotar el tiempo, seguía con el
-- personaje viejo). También lee la vida de las dos fuentes posibles para DIAGNOSTICAR (no para decidir) por qué
-- podría no saltar: Humanoid.Health frente al atributo Health del personaje que documenta EscaneoPersonaje.
local Protection = {}

Protection.RECOVER = 0.9 -- vuelve con el 90 % de la vida
Protection.TIMEOUT = 60 -- como mucho 60 s arriba

-- Lectura de vida. humanoid = { Health, MaxHealth } o nil; attrs = atributos del personaje (tabla) o nil.
-- La decisión usa SOLO el Humanoid (como siempre). attr* son para el diagnóstico.
function Protection.read(humanoid, attrs)
	local r = { ok = false }
	if humanoid then
		r.health, r.max = tonumber(humanoid.Health), tonumber(humanoid.MaxHealth)
		r.ok = r.health ~= nil and r.max ~= nil and r.max > 0
		r.pct = r.ok and r.health / r.max or nil
	end
	if type(attrs) == "table" then
		r.attrHealth, r.attrShield, r.attrMax = tonumber(attrs.Health), tonumber(attrs.Shield), tonumber(attrs.MaxHealth)
	end
	-- Indicio de que el juego lleva la vida en su atributo y no en el Humanoid (hipótesis: hay que verlo en el juego)
	r.mismatch = (r.ok and r.attrHealth ~= nil and math.abs(r.attrHealth - r.health) > 0.5) == true
	return r
end

------------------------------------------------------------------ Fuentes de vida (1.5.3)
-- Prueba real del usuario (1.5.2): la vida que enseñaba el hub NO coincidía con la real y la Huida no saltó al bajar
-- del 30 %. Aquí se reúnen TODAS las fuentes candidatas que se encuentran por nombre (sin inventar rutas): el Humanoid,
-- y cualquier atributo o valor (NumberValue/IntValue) cuyo nombre contenga "health" o sea "hp", del personaje, del
-- Humanoid o del jugador. Cada una con su porcentaje si se sabe su máximo.
-- snap = { humanoid = { Health, MaxHealth } | nil, attrs = { character = {...}, humanoid = {...}, player = {...} },
--          values = { { path, name, value } } }
local function isHealthName(n)
	n = tostring(n):lower()
	return (n:find("health", 1, true) ~= nil or n == "hp") and n:find("max", 1, true) == nil and n:find("regen", 1, true) == nil
end
local function maxFor(tbl, name)
	for _, k in { "Max" .. name, name .. "Max", "MaxHealth", "HealthMax", "MaxHP" } do
		if type(tbl) == "table" and tonumber(tbl[k]) then return tonumber(tbl[k]), k end
	end
	return nil
end
Protection.isHealthName = isHealthName

function Protection.sources(snap)
	snap = snap or {}
	local out = {}
	local hum = snap.humanoid
	local humMax = hum and tonumber(hum.MaxHealth)
	if hum and tonumber(hum.Health) then
		local h = tonumber(hum.Health)
		table.insert(out, { id = "humanoid", label = "Humanoid.Health", value = h, max = humMax,
			pct = humMax and humMax > 0 and h / humMax or nil, maxFrom = "Humanoid.MaxHealth" })
	end
	for _, where in { "character", "humanoid", "player" } do
		local tbl = snap.attrs and snap.attrs[where]
		if type(tbl) == "table" then
			local names = {}
			for name in tbl do table.insert(names, name) end
			table.sort(names)
			for _, name in names do
				local v = tonumber(tbl[name])
				if v and isHealthName(name) then
					local max, from = maxFor(tbl, name)
					if not max and humMax and humMax > 0 then max, from = humMax, "Humanoid.MaxHealth (supuesto)" end
					table.insert(out, { id = where .. ":" .. name, label = "atributo " .. name .. " (" .. where .. ")", value = v, max = max,
						pct = max and max > 0 and v / max or nil, maxFrom = from })
				end
			end
		end
	end
	for _, val in snap.values or {} do
		local v = tonumber(val.value)
		if v and isHealthName(val.name) then
			local max = humMax
			table.insert(out, { id = "value:" .. tostring(val.path), label = "valor " .. tostring(val.path), value = v, max = max,
				pct = max and max > 0 and v / max or nil, maxFrom = max and "Humanoid.MaxHealth (supuesto)" or nil })
		end
	end
	return out
end

Protection.MODES = { "auto", "humanoid", "attribute" }

-- Elige la fuente. mode "humanoid" = el Humanoid; "attribute" = el atributo Health del personaje (documentado);
-- "auto" = el Humanoid, salvo que otra fuente con porcentaje marque menos vida mientras el Humanoid sigue lleno
-- (exactamente lo que vio el usuario): entonces esa, y se queda con ella (sticky) mientras exista.
-- Devuelve fuente (o nil) y motivo.
function Protection.select(sources, mode, sticky)
	local byId = {}
	for _, s in sources do byId[s.id] = s end
	local hum = byId.humanoid
	if mode == "humanoid" then return hum, hum and "elegida: Humanoid" or "no hay Humanoid" end
	if mode == "attribute" then
		local a = byId["character:Health"]
		return a, a and "elegida: atributo Health" or "el personaje no tiene atributo Health"
	end
	if sticky and byId[sticky] and byId[sticky].pct then return byId[sticky], "auto: se mantiene " .. byId[sticky].label end
	if hum and hum.pct then
		local best
		for _, s in sources do
			if s.id ~= "humanoid" and s.pct and s.pct < hum.pct - 0.02 and hum.pct >= 0.98 and (not best or s.pct < best.pct) then best = s end
		end
		if best then return best, "auto: el Humanoid sigue lleno y " .. best.label .. " marca menos vida" end
		return hum, "auto: Humanoid (ninguna otra fuente marca menos vida)"
	end
	for _, s in sources do
		if s.pct then return s, "auto: no hay Humanoid legible; se usa " .. s.label end
	end
	return nil, "no se encuentra ninguna fuente de vida legible"
end

-- Lectura con la forma de read() a partir de una fuente (para step)
function Protection.fromSource(s)
	if not s or not s.pct then return { ok = false } end
	return { ok = true, health = s.value, max = s.max, pct = s.pct, source = s.id }
end

-- Grabación para la prueba real: samples = { { [id] = valor } }. Devuelve por fuente: mínimo, máximo y si cambió.
function Protection.summarize(samples)
	local stats = {}
	for _, sample in samples do
		for id, v in sample do
			local s = stats[id] or { id = id, min = v, max = v, first = v, last = v, n = 0 }
			s.min, s.max, s.last, s.n = math.min(s.min, v), math.max(s.max, v), v, s.n + 1
			stats[id] = s
		end
	end
	local out = {}
	for _, s in stats do
		s.changed = s.max - s.min > 0.5
		table.insert(out, s)
	end
	table.sort(out, function(a, b)
		if a.changed ~= b.changed then return a.changed end
		return a.id < b.id
	end)
	return out
end

-- Un paso de la máquina de estados. state = { escaping, since, character } (se modifica).
-- input = { enabled, limit (%), reading, character (identidad), now, alive (hub) }
-- Devuelve acción ("start" | "stop" | nil) y motivo.
function Protection.step(state, input)
	local r = input.reading or {}
	if not state.escaping then
		if not input.enabled then return nil, "apagada" end
		if not r.ok then return nil, "sin personaje o sin vida legible" end
		if r.health <= 0 then return nil, "muerto (esperando reaparición)" end
		if r.pct < (input.limit or 35) / 100 then
			state.escaping, state.since, state.character = true, input.now, input.character
			return "start", string.format("vida %d%% < %d%%", math.floor(r.pct * 100 + 0.5), input.limit)
		end
		return nil, string.format("vigilando: vida %d%% (límite %d%%)", math.floor(r.pct * 100 + 0.5), input.limit)
	end
	local why
	if input.alive == false then why = "hub cerrado"
	elseif not input.enabled then why = "apagada durante la huida"
	elseif input.character ~= state.character then why = "personaje nuevo (reaparición)"
	elseif not r.ok or r.health <= 0 then why = "muerto durante la huida"
	elseif r.pct >= Protection.RECOVER then why = "recuperado"
	elseif input.now - state.since >= Protection.TIMEOUT then why = "tiempo agotado (sin recuperar)" end
	if why then
		state.escaping, state.since, state.character = false, nil, nil
		return "stop", why
	end
	return nil, string.format("huyendo: vida %d%%", math.floor(r.pct * 100 + 0.5))
end

return Protection
end
__modules["Knowledge"] = function(...)
-- Knowledge: consultas sobre el catálogo del juego (datos en src/generated/CatalogIndex.lua, generado por
-- tools/gen_catalog.js desde data/catalog.json). Datos, lógica e interfaz separados: este módulo no sabe nada de la
-- UI ni de Roblox, y solo habla de lo DOCUMENTADO (wiki, evidencia grabada). El estado del juego en este momento
-- (qué NPC está cargado, qué función está encendida) no entra aquí: eso es del hub y de Components.
-- Interfaz estable (1.4.0): get, find, findAll, search, query, status, relations, related, requirements, rewards,
-- sources, sheet, archived, invalidRefs, ambiguous, incomplete, stats, known; Knowledge.validate(index).
local Knowledge = {}
Knowledge.__index = Knowledge

-- Categorías, estados y relaciones válidos (los mismos que comprueba el generador)
Knowledge.CATEGORIES = { island = true, region = true, npc = true, enemy = true, event = true, system = true, info = true,
	fruit = true, weapon = true, item = true, objective = true, mechanic = true, location = true }
Knowledge.VERIFICATION = { confirmed = true, inferred = true, documented = true, unknown = true, possibly_obsolete = true, archived = true }
Knowledge.RELATIONS = { links_to = true, mentions = true, located_at = true, in_region = true, summoned_by = true, drops = true,
	gives_quest = true, sells = true, rewards = true, requires = true, targets = true, part_of = true, related = true }

-- Textos para las fichas { es, en } (la UI elige el idioma). Sin traducir = se muestra la clave.
Knowledge.LABELS = {
	-- categorías
	island = { "Isla", "Island" }, region = { "Región", "Region" }, npc = { "NPC", "NPC" }, enemy = { "Enemigo", "Enemy" },
	event = { "Evento", "Event" }, system = { "Sistema", "System" }, info = { "Información", "Info" }, fruit = { "Fruta", "Fruit" },
	weapon = { "Arma / talento", "Weapon / talent" }, item = { "Objeto", "Item" }, objective = { "Tipo de misión", "Quest objective" },
	mechanic = { "Mecánica", "Mechanic" }, location = { "Lugar", "Place" },
	-- estados
	confirmed = { "CONFIRMADO en el juego", "CONFIRMED in game" }, inferred = { "DEDUCIDO (sin confirmar)", "INFERRED (unconfirmed)" },
	documented = { "DOCUMENTADO (wiki)", "DOCUMENTED (wiki)" }, unknown = { "DESCONOCIDO (sin datos)", "UNKNOWN (no data)" },
	possibly_obsolete = { "POSIBLEMENTE ANTIGUO", "POSSIBLY OUTDATED" }, archived = { "ARCHIVADO", "ARCHIVED" },
	contradictory = { "CONTRADICTORIO", "CONTRADICTORY" },
	-- relaciones (salientes / entrantes)
	links_to = { "enlaza a", "links to" }, mentions = { "menciona", "mentions" }, located_at = { "está en", "located at" },
	in_region = { "región", "region" }, summoned_by = { "lo invoca", "summoned by" }, drops = { "suelta", "drops" },
	gives_quest = { "da la misión", "gives quest" }, sells = { "vende", "sells" }, rewards = { "recompensa", "rewards" },
	requires = { "necesita", "requires" }, targets = { "objetivo", "targets" }, part_of = { "parte de", "part of" },
	related = { "relacionado", "related" },
	["in:located_at"] = { "aquí está", "found here" }, ["in:drops"] = { "lo suelta", "dropped by" },
	["in:gives_quest"] = { "la da", "given by" }, ["in:sells"] = { "lo vende", "sold by" }, ["in:summoned_by"] = { "invoca a", "summons" },
	["in:rewards"] = { "se consigue en", "rewarded by" }, ["in:requires"] = { "lo necesita", "required by" },
	["in:mentions"] = { "lo menciona", "mentioned by" }, ["in:links_to"] = { "enlazado desde", "linked from" },
	["in:in_region"] = { "contiene", "contains" }, ["in:part_of"] = { "incluye", "includes" }, ["in:targets"] = { "objetivo de", "target of" },
	["in:related"] = { "relacionado", "related" },
	-- secciones de la ficha
	aliases = { "Otros nombres", "Other names" }, status = { "Estado", "Status" }, sources = { "Fuentes", "Sources" },
	requirements = { "Requisitos", "Requirements" }, rewardsSection = { "Recompensas", "Rewards" },
	relationsSection = { "Relaciones", "Relations" }, facts = { "Datos de la wiki", "Wiki facts" }, abilities = { "Habilidades", "Abilities" },
	unknownSection = { "Se desconoce", "Unknown" }, contradictions = { "Contradicciones", "Contradictions" },
	internal = { "Nombre en el juego", "In-game name" },
}

local EMPTY = table.freeze and table.freeze({}) or {}
local function list(v) return type(v) == "table" and v or EMPTY end
local function lower(s) return tostring(s or ""):lower() end

-- index = { meta, entities = { { id, name, aliases, category, verification, relations = {{tipo, destino, vía}}, ... } } }
-- Aguanta índices incompletos (campos que faltan = vacíos) y entradas sin id (se ignoran: validate las informa).
function Knowledge.new(index)
	index = type(index) == "table" and index or {}
	local self = setmetatable({ meta = index.meta or {}, list = {}, byId = {}, byName = {}, incoming = {}, cache = {} }, Knowledge)
	local lists = list(self.meta.lists)
	for _, e in list(index.entities) do
		-- esquema 3 (compacto): wiki = número de meta.lists, card solo si no es el nombre, srcEvidence. Se expande
		-- aquí una vez a la forma del esquema 2 (source = { list, card } | { evidence }); el 2 se lee tal cual.
		if type(e) == "table" and e.source == nil then
			if e.wiki then e.source = { list = lists[e.wiki], card = e.card or e.name }
			elseif e.srcEvidence then e.source = { evidence = e.srcEvidence } end
		end
		if type(e) == "table" and type(e.id) == "string" and self.byId[e.id] == nil then
			self.byId[e.id] = e
			table.insert(self.list, e)
			local names = { e.name }
			for _, a in list(e.aliases) do table.insert(names, a) end
			local seen = {}
			for _, n in names do
				local key = lower(n)
				if key ~= "" and not seen[key] then
					seen[key] = true
					self.byName[key] = self.byName[key] or {}
					table.insert(self.byName[key], e)
				end
			end
			for _, r in list(e.relations) do
				if type(r) == "table" and r[2] then
					self.incoming[r[2]] = self.incoming[r[2]] or {}
					table.insert(self.incoming[r[2]], { r[1], e.id, r[3] })
				end
			end
		end
	end
	return self
end

function Knowledge:get(id) return self.byId[id] end

-- Por nombre visible o alias (sin distinguir mayúsculas); category opcional. Prefiere lo vigente a lo archivado.
function Knowledge:find(name, category)
	local fallback
	for _, e in self.byName[lower(name)] or EMPTY do
		if not category or e.category == category then
			if e.verification ~= "archived" then return e end
			fallback = fallback or e
		end
	end
	return fallback
end

-- Todas las entidades con ese nombre o alias (para ver ambigüedades: un NPC y un arma con el mismo nombre)
function Knowledge:findAll(name)
	return table.clone(self.byName[lower(name)] or EMPTY)
end

local function hasFact(e, kinds)
	for _, f in list(e.facts) do if kinds[f[1]] then return true end end
	return false
end
local function hasRelation(e, types)
	for _, r in list(e.relations) do if types[r[1]] then return true end end
	return false
end
-- ¿Tiene requisitos / recompensas documentados? (mismos criterios que requirements() y rewards())
local function hasRequirements(e)
	if hasFact(e, { requirement = true, cost = true }) or hasRelation(e, { requires = true }) then return true end
	for _, a in list(e.abilities) do if a[3] then return true end end
	return false
end
local function hasRewards(e) return hasFact(e, { reward = true }) or hasRelation(e, { rewards = true, drops = true }) end

local function matches(e, filter)
	if filter.archived == "only" then
		if e.verification ~= "archived" then return false end
	elseif not filter.includeArchived and e.verification == "archived" then
		return false
	end
	if filter.category and e.category ~= filter.category then return false end
	if filter.categories and table.find(filter.categories, e.category) == nil then return false end
	if filter.has == "requirements" and not hasRequirements(e) then return false end
	if filter.has == "rewards" and not hasRewards(e) then return false end
	if filter.verification and e.verification ~= filter.verification then return false end
	if filter.group and e.group ~= filter.group then return false end
	if filter.role and table.find(list(e.roles), filter.role) == nil then return false end
	if filter.contradictory and #list(e.contradictions) == 0 then return false end
	if filter.incomplete and #list(e.unknown) == 0 then return false end
	return true
end

-- filter = { category, categories = {...}, verification, group, role, contradictory, incomplete,
--           has = "requirements" | "rewards", includeArchived, archived = "only" }
function Knowledge:query(filter)
	filter = filter or {}
	local out = {}
	for _, e in self.list do
		if matches(e, filter) then table.insert(out, e) end
	end
	return out
end

-- Búsqueda por texto (nombre, alias o id) con filtros. Orden: igual > empieza por > contiene; luego por nombre.
-- Texto vacío = todo lo que pase el filtro. limit opcional.
-- Clave de caché de una búsqueda (el catálogo no cambia en la sesión: el resultado de una búsqueda tampoco)
local FILTER_KEYS = { "category", "verification", "group", "role", "contradictory", "incomplete", "has", "includeArchived", "archived" }
local function cacheKey(q, filter)
	local parts = { q }
	for _, k in FILTER_KEYS do table.insert(parts, tostring(filter[k])) end
	if filter.categories then table.insert(parts, table.concat(filter.categories, ",")) end
	return table.concat(parts, "|")
end
Knowledge.CACHE_MAX = 64

function Knowledge:search(text, filter, limit)
	filter = filter or {}
	local q = lower(text):gsub("^%s+", ""):gsub("%s+$", "")
	local key = cacheKey(q, filter)
	local cached = self.cache[key]
	if cached then
		self.cacheHits = (self.cacheHits or 0) + 1
		local out = {}
		for i, e in cached do
			if limit and i > limit then break end
			out[i] = e
		end
		return out
	end
	self.cacheMisses = (self.cacheMisses or 0) + 1
	local scored = {}
	for _, e in self.list do
		if matches(e, filter) then
			local best = q == "" and 1 or 0
			if q ~= "" then
				local names = { e.name, e.id }
				for _, a in list(e.aliases) do table.insert(names, a) end
				for _, n in names do
					local s = lower(n)
					local score = (s == q and 3) or (s:sub(1, #q) == q and 2) or (s:find(q, 1, true) and 1) or 0
					if score > best then best = score end
				end
			end
			if best > 0 then table.insert(scored, { e = e, score = best }) end
		end
	end
	table.sort(scored, function(a, b)
		if a.score ~= b.score then return a.score > b.score end
		return lower(a.e.name) < lower(b.e.name)
	end)
	local all, out = {}, {}
	for i, s in scored do
		all[i] = s.e
		if not limit or i <= limit then out[i] = s.e end
	end
	self.cacheSize = (self.cacheSize or 0) + 1
	if self.cacheSize > Knowledge.CACHE_MAX then table.clear(self.cache); self.cacheSize = 1 end -- tope de memoria
	self.cache[key] = all
	return out
end

-- Estado documental: verification + banderas. contradictory = la wiki (o la wiki y el juego) se contradicen.
function Knowledge:status(id)
	local e = self.byId[id]
	if not e then return nil end
	return {
		verification = e.verification,
		contradictory = #list(e.contradictions) > 0,
		incomplete = #list(e.unknown) > 0,
		stale = e.verification == "possibly_obsolete",
		archived = e.verification == "archived",
		label = (#list(e.contradictions) > 0 and e.verification ~= "archived") and "contradictory" or e.verification,
	}
end

-- Relaciones de una entidad: { type, direction ("out" | "in"), id, entity (nil si el destino no existe), via, valid }
function Knowledge:relations(id, relType)
	local out = {}
	local e = self.byId[id]
	for _, r in e and list(e.relations) or EMPTY do
		if not relType or r[1] == relType then
			local target = self.byId[r[2]]
			table.insert(out, { type = r[1], direction = "out", id = r[2], entity = target, via = r[3], valid = target ~= nil })
		end
	end
	for _, r in self.incoming[id] or EMPTY do
		if not relType or r[1] == relType then
			table.insert(out, { type = r[1], direction = "in", id = r[2], entity = self.byId[r[2]], via = r[3], valid = true })
		end
	end
	return out
end

-- Compatibilidad con 1.3.2: solo las entidades (salientes por defecto, "in" = entrantes)
function Knowledge:related(id, relType, direction)
	local out = {}
	for _, r in self:relations(id, relType) do
		if r.direction == (direction == "in" and "in" or "out") and r.entity then table.insert(out, r.entity) end
	end
	return out
end

-- Requisitos documentados: hechos de tipo requisito/coste, relaciones "requires" y requisitos de habilidades.
-- { kind = "fact" | "cost" | "relation" | "ability", text, id? }
function Knowledge:requirements(id)
	local e = self.byId[id]
	local out = {}
	if not e then return out end
	for _, f in list(e.facts) do
		if f[1] == "requirement" or f[1] == "cost" then table.insert(out, { kind = f[1] == "cost" and "cost" or "fact", text = f[2] }) end
	end
	for _, r in self:relations(id, "requires") do
		if r.direction == "out" then table.insert(out, { kind = "relation", id = r.id, text = r.entity and r.entity.name or r.id }) end
	end
	for _, a in list(e.abilities) do
		if a[3] then table.insert(out, { kind = "ability", text = tostring(a[1]) .. ": " .. tostring(a[3]) }) end
	end
	return out
end

-- Recompensas documentadas: hechos de recompensa y relaciones "rewards" / "drops" (salientes)
function Knowledge:rewards(id)
	local e = self.byId[id]
	local out = {}
	if not e then return out end
	for _, f in list(e.facts) do
		if f[1] == "reward" then table.insert(out, { kind = "fact", text = f[2] }) end
	end
	for _, r in self:relations(id) do
		if r.direction == "out" and (r.type == "rewards" or r.type == "drops") then
			table.insert(out, { kind = "relation", type = r.type, id = r.id, text = r.entity and r.entity.name or r.id })
		end
	end
	return out
end

-- Procedencia: tarjeta de la wiki, evidencia del juego (con su nivel) y nombres internos vistos
function Knowledge:sources(id)
	local e = self.byId[id]
	local out = {}
	if not e then return out end
	local src = e.source or EMPTY
	if src.card then table.insert(out, { kind = "wiki", list = src.list, card = src.card }) end
	if src.evidence then table.insert(out, { kind = "evidence", note = src.evidence }) end
	if type(e.evidence) == "table" then
		table.insert(out, { kind = "evidence", level = e.evidence.level, note = e.evidence.note })
	end
	for _, name in list(e.internal) do table.insert(out, { kind = "internal", note = name }) end
	if #out == 0 then table.insert(out, { kind = "none" }) end
	return out
end

function Knowledge:archived() return self:query({ archived = "only" }) end

-- Relaciones que apuntan a ids que no existen (en un índice sano: ninguna)
function Knowledge:invalidRefs()
	local out = {}
	for _, e in self.list do
		for _, r in list(e.relations) do
			if not self.byId[r[2]] then table.insert(out, { from = e.id, type = r[1], to = r[2] }) end
		end
	end
	return out
end

-- Nombres o alias compartidos por varias entidades vigentes: { name, ids = {...} }
function Knowledge:ambiguous()
	local out = {}
	for key, entries in self.byName do
		local ids = {}
		for _, e in entries do
			if e.verification ~= "archived" then table.insert(ids, e.id) end
		end
		if #ids > 1 then
			table.sort(ids)
			table.insert(out, { name = key, ids = ids })
		end
	end
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

-- Información incompleta: { [campo] = número de entidades vigentes sin ese dato } (de una categoría o de todas)
function Knowledge:incomplete(category)
	local fields, total = {}, 0
	for _, e in self:query({ category = category }) do
		if #list(e.unknown) > 0 then total += 1 end
		for _, f in list(e.unknown) do fields[f] = (fields[f] or 0) + 1 end
	end
	return fields, total
end

function Knowledge:stats()
	local byCategory, byVerification, contradictory = {}, {}, 0
	for _, e in self.list do
		byCategory[e.category] = (byCategory[e.category] or 0) + 1
		byVerification[e.verification] = (byVerification[e.verification] or 0) + 1
		if #list(e.contradictions) > 0 then contradictory += 1 end
	end
	return { total = #self.list, schema = self.meta.schema, version = self.meta.version, wiki = self.meta.wikiLastActivity,
		byCategory = byCategory, byVerification = byVerification, contradictory = contradictory, invalid = #self:invalidRefs() }
end

-- ¿Se sabe este dato de la entidad? (false si está en su lista de desconocidos o no existe)
function Knowledge:known(id, field)
	local e = self.byId[id]
	return e ~= nil and table.find(list(e.unknown), field) == nil
end

-- Ficha de una entidad, lista para pintar: { id, name, category, status, sections = { { key, items = { texto } } } }.
-- tr(par {es, en}) traduce las etiquetas (por defecto, español). Sin deducciones: solo lo que dice el catálogo.
function Knowledge:sheet(id, tr)
	local e = self.byId[id]
	if not e then return nil end
	tr = tr or function(pair) return pair[1] end
	local function label(key)
		local pair = Knowledge.LABELS[key]
		return pair and tr(pair) or key
	end
	local st = self:status(id)
	local sections = {}
	local function add(key, items)
		if #items > 0 then table.insert(sections, { key = key, title = label(key), items = items }) end
	end
	local statusItems = { label(st.label) }
	if st.label == "contradictory" then table.insert(statusItems, label(e.verification)) end
	if st.stale and st.label ~= "possibly_obsolete" then table.insert(statusItems, label("possibly_obsolete")) end
	add("status", statusItems)
	add("aliases", table.clone(list(e.aliases)))
	local src = {}
	for _, s in self:sources(id) do
		if s.kind == "wiki" then table.insert(src, "Wiki: " .. tostring(s.list or "?") .. " › " .. tostring(s.card))
		elseif s.kind == "evidence" then table.insert(src, (s.level and (label(s.level) .. ": ") or "") .. tostring(s.note or "-"))
		elseif s.kind == "internal" then table.insert(src, label("internal") .. ": " .. tostring(s.note))
		else table.insert(src, "-") end
	end
	add("sources", src)
	local req = {}
	for _, r in self:requirements(id) do table.insert(req, r.text) end
	add("requirements", req)
	local rew = {}
	for _, r in self:rewards(id) do table.insert(rew, (r.type and (label(r.type) .. ": ") or "") .. r.text) end
	add("rewardsSection", rew)
	local rel = {}
	for _, r in self:relations(id) do
		-- las menciones y enlaces entrantes son ruido (decenas por isla): solo las salientes
		if r.direction == "out" or (r.type ~= "mentions" and r.type ~= "links_to") then
			local key = r.direction == "in" and ("in:" .. r.type) or r.type
			local name = r.entity and r.entity.name or (r.id .. " (?)")
			table.insert(rel, label(key) .. " › " .. name .. (r.valid and "" or " [referencia rota]"))
		end
	end
	add("relationsSection", rel)
	local facts = {}
	for _, f in list(e.facts) do
		if f[1] ~= "requirement" and f[1] ~= "cost" and f[1] ~= "reward" then table.insert(facts, f[2]) end
	end
	add("facts", facts)
	local ab = {}
	for _, a in list(e.abilities) do table.insert(ab, tostring(a[1]) .. (a[3] and (" (" .. a[3] .. ")") or "")) end
	add("abilities", ab)
	add("unknownSection", table.clone(list(e.unknown)))
	add("contradictions", table.clone(list(e.contradictions)))
	return { id = e.id, name = e.name, category = e.category, categoryLabel = label(e.category), status = st, sections = sections }
end

-- Comprueba la integridad del índice. Devuelve problemas (vacía = bien) y avisos (no rompen nada).
function Knowledge.validate(index)
	local problems, warnings, seen = {}, {}, {}
	if type(index) ~= "table" or type(index.entities) ~= "table" then return { "índice sin lista de entidades" }, warnings end
	for i, e in index.entities do
		local where = tostring(type(e) == "table" and e.id or ("#" .. i))
		if type(e) ~= "table" then
			table.insert(problems, where .. ": no es una tabla")
		else
			if type(e.id) ~= "string" or e.id == "" then table.insert(problems, where .. ": sin id") end
			if type(e.name) ~= "string" or e.name == "" then table.insert(problems, where .. ": sin nombre") end
			if not Knowledge.CATEGORIES[e.category] then table.insert(problems, where .. ": categoría " .. tostring(e.category)) end
			if not Knowledge.VERIFICATION[e.verification] then table.insert(problems, where .. ": verificación " .. tostring(e.verification)) end
			if e.id then
				if seen[e.id] then table.insert(problems, where .. ": id repetido") end
				seen[e.id] = true
			end
			for _, field in { "aliases", "relations", "unknown", "contradictions", "facts", "abilities", "roles" } do
				if e[field] ~= nil and type(e[field]) ~= "table" then table.insert(problems, where .. ": " .. field .. " no es lista") end
			end
			if e.source == nil and e.wiki == nil and e.srcEvidence == nil and e.verification ~= "unknown" then
				table.insert(warnings, where .. ": sin fuente")
			end
		end
	end
	for _, e in index.entities do
		if type(e) == "table" and type(e.relations) == "table" then
			for _, r in e.relations do
				if not Knowledge.RELATIONS[r[1]] then table.insert(problems, tostring(e.id) .. ": relación de tipo " .. tostring(r[1])) end
				if not seen[r[2]] then table.insert(problems, tostring(e.id) .. " -" .. tostring(r[1]) .. "-> " .. tostring(r[2]) .. ": destino inexistente") end
			end
		end
	end
	-- mismo nombre en dos entidades vigentes de la MISMA categoría: el generador lo prohíbe
	local names = {}
	for _, e in index.entities do
		if type(e) == "table" and e.verification ~= "archived" and type(e.name) == "string" then
			local k = tostring(e.category) .. "|" .. e.name:lower()
			if names[k] then table.insert(problems, tostring(e.id) .. ": nombre repetido en " .. tostring(e.category) .. " (" .. names[k] .. ")") end
			names[k] = names[k] or tostring(e.id)
		end
	end
	return problems, warnings
end

return Knowledge
end
__modules["KnowledgeView"] = function(...)
-- KnowledgeView: capa de presentación del catálogo para el explorador (y cualquier vista informativa). Sobre
-- Knowledge: filtros agrupados (grupo, estado, papel), orden, búsqueda con alias, etiquetas traducidas, estado de
-- verificación, datos desconocidos y navegación por entidades relacionadas con historial. Sin Roblox ni UI: devuelve
-- textos ya formateados; el hub solo los pinta. Solo lee: nada de aquí se convierte en órdenes para el juego.
local KnowledgeView = {}
KnowledgeView.__index = KnowledgeView

-- Grupos (combo "Mostrar"): ≤ 9 opciones para que la lista desplegable quepa en pantalla
KnowledgeView.GROUPS = {
	{ label = { "Todo", "All" }, filter = {} },
	{ label = { "Mundo (islas y lugares)", "World (islands, places)" }, filter = { categories = { "island", "region", "location" } } },
	{ label = { "NPCs", "NPCs" }, filter = { category = "npc" } },
	{ label = { "Enemigos y jefes", "Enemies and bosses" }, filter = { category = "enemy" } },
	{ label = { "Misiones y eventos", "Quests and events" }, filter = { categories = { "objective", "event" } } },
	{ label = { "Objetos y armas", "Items and weapons" }, filter = { categories = { "item", "weapon" } } },
	{ label = { "Frutas", "Fruits" }, filter = { category = "fruit" } },
	{ label = { "Sistemas y progresión", "Systems & progression" }, filter = { categories = { "system", "mechanic" } } },
	{ label = { "Información", "Info" }, filter = { category = "info" } },
}
-- Estado de la información
KnowledgeView.STATUS = {
	{ label = { "Cualquiera", "Any" }, filter = {} },
	{ label = { "Confirmado", "Confirmed" }, filter = { verification = "confirmed" } },
	{ label = { "Documentado", "Documented" }, filter = { verification = "documented" } },
	{ label = { "Deducido", "Inferred" }, filter = { verification = "inferred" } },
	{ label = { "Contradictorio", "Contradictory" }, filter = { contradictory = true } },
	{ label = { "Incompleto", "Incomplete" }, filter = { incomplete = true } },
	{ label = { "Con requisitos", "With requirements" }, filter = { has = "requirements" } },
	{ label = { "Con recompensas", "With rewards" }, filter = { has = "rewards" } },
	{ label = { "Archivado", "Archived" }, filter = { archived = "only" } },
}
-- Papel (para lo que la wiki marca: jefes, comerciantes, quien da misiones…)
KnowledgeView.ROLES = {
	{ label = { "Cualquiera", "Any" }, role = nil },
	{ label = { "Jefe", "Boss" }, role = "boss" },
	{ label = { "Élite", "Elite" }, role = "elite" },
	{ label = { "Comerciante", "Merchant" }, role = "merchant" },
	{ label = { "Da misiones", "Quest giver" }, role = "quest_giver" },
}
KnowledgeView.SORTS = {
	{ label = { "Relevancia", "Relevance" }, key = "relevance" },
	{ label = { "Nombre", "Name" }, key = "name" },
	{ label = { "Estado (confirmado primero)", "Status (confirmed first)" }, key = "status" },
	{ label = { "Categoría", "Category" }, key = "category" },
}
local STATUS_RANK = { confirmed = 1, inferred = 2, documented = 3, possibly_obsolete = 4, unknown = 5, archived = 6 }

-- k = Knowledge; tr({es, en}) -> texto en el idioma actual
function KnowledgeView.new(k, tr)
	return setmetatable({ k = k, tr = tr or function(p) return p[1] end, query = "", group = 1, status = 1, role = 1,
		sort = 1, results = {}, sel = 1, related = {}, relSel = 1, history = {}, focus = nil }, KnowledgeView)
end

local function merge(...)
	local out = {}
	for _, f in { ... } do for k, v in f do out[k] = v end end
	return out
end
function KnowledgeView:filter()
	local f = merge(KnowledgeView.GROUPS[self.group].filter, KnowledgeView.STATUS[self.status].filter)
	f.role = KnowledgeView.ROLES[self.role].role
	return f
end
function KnowledgeView:label(key) local p = self.k.LABELS[key]; return p and self.tr(p) or tostring(key) end

-- Recalcula los resultados (búsqueda + filtros + orden). Vuelve a la primera y borra el historial.
function KnowledgeView:run()
	local list = self.k:search(self.query, self:filter())
	local sortKey = KnowledgeView.SORTS[self.sort].key
	if sortKey ~= "relevance" then
		local lowerName = function(e) return e.name:lower() end
		table.sort(list, function(a, b)
			if sortKey == "status" then
				local ra, rb = STATUS_RANK[a.verification] or 9, STATUS_RANK[b.verification] or 9
				if ra ~= rb then return ra < rb end
			elseif sortKey == "category" and a.category ~= b.category then
				return self:label(a.category) < self:label(b.category)
			end
			return lowerName(a) < lowerName(b)
		end)
	end
	self.results, self.sel, self.history, self.focus = list, 1, {}, nil
	self:_related()
	return #list
end

function KnowledgeView:set(field, value)
	self[field] = value
	return self:run()
end
function KnowledgeView:reset()
	self.query, self.group, self.status, self.role, self.sort = "", 1, 1, 1, 1
	return self:run()
end

-- Entidad que se está viendo: la elegida en la lista o, si se navegó por relacionadas, esa
function KnowledgeView:current() return self.focus or self.results[self.sel] end

-- Relacionadas útiles de la entidad actual (sin las menciones/enlaces entrantes: son ruido), sin repetir
function KnowledgeView:_related()
	local e = self:current()
	local out, seen = {}, {}
	for _, r in e and self.k:relations(e.id) or {} do
		if r.entity and not seen[r.id] and (r.direction == "out" or (r.type ~= "mentions" and r.type ~= "links_to")) then
			seen[r.id] = true
			table.insert(out, { entity = r.entity, label = self:label(r.direction == "in" and ("in:" .. r.type) or r.type) })
		end
	end
	self.related, self.relSel = out, 1
end

function KnowledgeView:move(step)
	if self.focus then return false end -- dentro de una relacionada: primero "Volver"
	if #self.results == 0 then return false end
	self.sel = ((self.sel - 1 + step) % #self.results) + 1
	self:_related()
	return true
end
function KnowledgeView:nextRelated()
	if #self.related == 0 then return false end
	self.relSel = (self.relSel % #self.related) + 1
	return true
end
-- Abre la relacionada marcada (guarda de dónde viene para "Volver")
function KnowledgeView:openRelated()
	local r = self.related[self.relSel]
	if not r then return false end
	table.insert(self.history, { focus = self.focus, relSel = self.relSel })
	self.focus = r.entity
	self:_related()
	return true
end
function KnowledgeView:back()
	local h = table.remove(self.history)
	if not h then return false end
	self.focus = h.focus
	self:_related()
	self.relSel = math.min(h.relSel, math.max(1, #self.related))
	return true
end

local function short(self, verification)
	return (self:label(verification):match("^(%S+)"))
end

-- Lista visible: contador, ventana de `rows` filas alrededor de la elegida, "?N" = datos desconocidos
function KnowledgeView:listText(rows)
	rows = rows or 7
	local n = #self.results
	if n == 0 then
		return self.tr({ "Sin resultados. Prueba otro nombre o pulsa \"Restablecer filtros\".",
			"No results. Try another name or press \"Reset filters\"." })
	end
	local out = { string.format(self.tr({ "%d resultados · %d/%d", "%d results · %d/%d" }), n, self.sel, n) }
	local first = math.clamp(self.sel - math.floor(rows / 2), 1, math.max(1, n - rows + 1))
	for i = first, math.min(n, first + rows - 1) do
		local e = self.results[i]
		local st = self.k:status(e.id)
		local unknown = #(e.unknown or {})
		table.insert(out, (i == self.sel and not self.focus and "▶ " or "    ") .. e.name .. " · " .. self:label(e.category) .. " · "
			.. short(self, st.label) .. (unknown > 0 and (" · ?" .. unknown) or ""))
	end
	return table.concat(out, "\n")
end

-- Ficha: título, ruta de navegación, fuentes una por línea, secciones, relacionadas numeradas (▶ = la marcada)
function KnowledgeView:sheetLines()
	local e = self:current()
	local sheet = e and self.k:sheet(e.id, self.tr)
	if not sheet then return {} end
	local out = { "■ " .. sheet.name .. " — " .. sheet.categoryLabel }
	if #self.history > 0 then
		table.insert(out, self.tr({ "  (desde la lista: ", "  (from the list: " }) .. #self.history .. self.tr({ " saltos; \"‹ Volver\" para regresar)", " jumps; \"‹ Back\" to return)" }))
	end
	for _, sec in sheet.sections do
		if sec.key == "sources" then
			table.insert(out, sec.title .. ":")
			for _, item in sec.items do table.insert(out, "  • " .. item) end
		elseif sec.key == "unknownSection" then
			table.insert(out, "? " .. sec.title .. ": " .. table.concat(sec.items, ", "))
		elseif sec.key ~= "relationsSection" then
			table.insert(out, sec.title .. ": " .. table.concat(sec.items, " · "))
		end
	end
	if #self.related > 0 then
		table.insert(out, self:label("relationsSection") .. " (" .. #self.related .. "):")
		for i, r in self.related do
			table.insert(out, (i == self.relSel and "  ▶ " or "    ") .. r.label .. " › " .. r.entity.name)
		end
	end
	return out
end

-- Opciones traducidas de un combo (GROUPS, STATUS, ROLES, SORTS) como pares {es, en} para la UI
function KnowledgeView.options(list)
	local out = {}
	for i, o in list do out[i] = o.label end
	return out
end

return KnowledgeView
end
__modules["CatalogIndex"] = function(...)
-- GENERADO por tools/gen_catalog.js desde datos.json y data/overlay.json. No editar a mano.
-- Índice compacto del catálogo (data/catalog.json tiene los textos). Lo consulta el módulo Knowledge.
return {
	meta = {schema=3,version="96e9c99e",wikiLastActivity="2026-11-17T00:16:38.605Z",total=235,lists={"Enemies","World Events","Uncommon Devil Fruits","Rare Devil Fruits","Common Devil Fruits","Ultra Rare Devil Fruits","About","Points of Interest","NPCs (Locations)","Systems","Talents"}},
	entities = {
		{id="enemy.abyss_crustacean",name="Abyss Crustacean",category="enemy",verification="documented",roles={"boss"},wiki=0,card="Fishing",relations={{"summoned_by","item.deep_reach_rod","wiki"}},unknown={"drops","internalName","level","location","respawnTime"},facts={{"spawn","Each fish caught with the Deep Reach Rod has a 1% chance to hook the Abyss Crustacean (Lv. 3000), which drags you and everyone nearby into its trench."},{"duration","It has 2,000,000 health and 10 minutes before it sinks back into the dark."}}},
		{id="enemy.angry_bob",name="Angry Bob",category="enemy",group="other",verification="documented",wiki=1,unknown={"drops","internalName","level","location"},facts={{"reward","For now, just leave him alone, he doesn’t give much anyways."}}},
		{id="enemy.bandits",name="Bandits",category="enemy",group="other",verification="documented",wiki=1,relations={{"located_at","island.windmill_and_town_island","wiki"}},unknown={"drops","internalName","level"}},
		{id="enemy.blue_crab",name="Blue Crab",category="enemy",group="other",verification="documented",wiki=1,unknown={"drops","internalName","level","location"}},
		{id="enemy.boar",name="Boar",category="enemy",group="other",verification="confirmed",internal={"Alive.NPCs 'Lv12 Boar'"},wiki=1,evidence={level="confirmed",note="Auto Quest (Defeat)"},unknown={"drops","level","location"}},
		{id="enemy.captain_blacksurf",name="Captain Blacksurf",category="enemy",group="other",verification="documented",roles={"boss"},wiki=1,relations={{"links_to","island.deepwaken_trench","wiki-link"},{"mentions","island.deepwaken_trench","name"},{"located_at","island.deepwaken_trench","wiki"},{"drops","item.merlins_logbook","wiki"}},unknown={"internalName","level","respawnTime"}},
		{id="enemy.cave_demons",name="Cave Demons",category="enemy",group="other",verification="documented",wiki=1,unknown={"drops","internalName","level","location"}},
		{id="enemy.crab",name="Crab",category="enemy",group="other",verification="documented",wiki=1,unknown={"drops","internalName","level","location"}},
		{id="enemy.death_spire_knight",name="Caballero de Death Spire (sin nombre)",category="enemy",verification="documented",roles={"boss","summoned"},wiki=0,card="Death Spire",relations={{"located_at","island.death_spire","wiki"},{"summoned_by","objective.offer_fruits","wiki"}},unknown={"drops","internalName","level","name","respawnTime"},facts={{"spawn","if you bring 13 devil fruits for the lower circle, and 3 for what’s at the top, you can summon a knight of steel, darkness, and evil."}}},
		{id="enemy.fishman_pirates",name="Fishman Pirates",category="enemy",group="other",verification="documented",wiki=1,relations={{"links_to","enemy.captain_blacksurf","wiki-link"},{"mentions","enemy.captain_blacksurf","name"}},unknown={"drops","internalName","level","location"},facts={{"reward","Followers of Captain Blacksurf, not sure what he gives these subordinates of his in terms of payment for them to follow him so closely and blindly."}}},
		{id="enemy.freddy",name="Freddy",category="enemy",group="other",verification="documented",wiki=1,unknown={"drops","internalName","level","location"}},
		{id="enemy.gecko_moria",name="Gecko Moria",category="enemy",group="halloween",verification="possibly_obsolete",roles={"boss","seasonal"},wiki=1,relations={{"links_to","island.halloween_island","wiki-link"},{"mentions","island.halloween_island","name"},{"in_region","region.halloween","wiki-group"},{"located_at","island.halloween_island","wiki"}},unknown={"drops","internalName","level","respawnTime"}},
		{id="enemy.ghost",name="Ghost",category="enemy",group="halloween",verification="possibly_obsolete",wiki=1,relations={{"in_region","region.halloween","wiki-group"}},unknown={"drops","internalName","level"}},
		{id="enemy.gunner_captain",name="Gunner Captain",category="enemy",group="other",verification="documented",roles={"boss?"},wiki=1,unknown={"drops","internalName","level","location"},contradictions={"El hub lo busca en IslandCaver; la wiki no dice su isla (Caver Island es 'The Gunners Cave Island': relación probable, no confirmada)."}},
		{id="enemy.gunslinger",name="Gunslinger",category="enemy",group="other",verification="documented",wiki=1,unknown={"drops","internalName","level","location"}},
		{id="enemy.gunslinger_brothers",name="Gunslinger Brothers",category="enemy",group="other",verification="documented",wiki=1,unknown={"drops","internalName","level","location"}},
		{id="enemy.gunslinger_elites",name="Gunslinger Elites",category="enemy",verification="documented",roles={"elite"},wiki=0,card="The Expert",unknown={"drops","internalName","level","location","members"},facts={{"requirement","Elite: kill one of the Gunslinger Elites."}}},
		{id="enemy.marines",name="Marines",category="enemy",verification="documented",roles={"elite"},wiki=0,card="Marine Base",relations={{"located_at","island.marine_base","wiki"}},unknown={"drops","internalName","level"},facts={{"requirement","A logia won't serve you well since they all know how to use Buso Haki."}}},
		{id="enemy.perona_ghost_princess",name="Perona, Ghost Princess",aliases={"Perona"},category="enemy",group="halloween",verification="possibly_obsolete",roles={"boss","seasonal","summoned"},wiki=1,relations={{"in_region","region.halloween","wiki-group"},{"summoned_by","objective.light_candles","wiki"},{"located_at","island.halloween_island","wiki"}},unknown={"drops","internalName","level","respawnTime"},facts={{"spawn","If you light four candles near her house, she spawns in the center to haunt."}}},
		{id="enemy.purple_crab",name="Purple Crab",category="enemy",group="other",verification="documented",wiki=1,unknown={"drops","internalName","level","location"}},
		{id="enemy.ryuma",name="Ryuma",category="enemy",group="halloween",verification="possibly_obsolete",roles={"boss?","seasonal"},wiki=1,relations={{"in_region","region.halloween","wiki-group"}},unknown={"drops","internalName","level"},contradictions={"El hub lo trata como jefe; la wiki no lo llama jefe."}},
		{id="enemy.the_freds",name="The Freds",category="enemy",group="other",verification="documented",wiki=1,relations={{"links_to","enemy.freddy","wiki-link"},{"mentions","enemy.freddy","name"}},unknown={"drops","internalName","level","location"}},
		{id="enemy.thieves",name="Thieves",category="enemy",group="other",verification="documented",wiki=1,relations={{"located_at","island.windmill_and_town_island","wiki"}},unknown={"drops","internalName","level"}},
		{id="enemy.thug",name="Thug",category="enemy",group="other",verification="documented",wiki=1,relations={{"mentions","island.sams_bar_and_pirates_land","name"},{"located_at","island.sams_bar_and_pirates_land","wiki"}},unknown={"drops","internalName","level"}},
		{id="enemy.vokun",name="Vokun",category="enemy",verification="documented",roles={"elite"},wiki=0,card="The Expert",unknown={"drops","internalName","level","location"},facts={{"requirement","Elite: kill Vokun."}}},
		{id="enemy.zombie",name="Zombie",category="enemy",group="halloween",verification="possibly_obsolete",wiki=1,relations={{"in_region","region.halloween","wiki-group"}},unknown={"drops","internalName","level"}},
		{id="event.crew_seige",name="Crew Seige",category="event",verification="documented",wiki=2,unknown={"duration","frequency","location","trigger"},facts={{"reward","Those who win and claim the flag get rewarded."}}},
		{id="event.ghost_ship",name="Ghost Ship",category="event",verification="documented",wiki=2,relations={{"rewards","item.treasure_map","wiki"}},unknown={"duration","frequency","location","trigger"},facts={{"reward","Defeat them for rewards and a mysterious Treasure Map."}}},
		{id="event.ghost_ship__archived",name="Ghost Ship",category="event",verification="archived",wiki=2},
		{id="event.treasure_rain",name="Treasure Rain",category="event",verification="documented",wiki=2,relations={{"rewards","item.treasure_chest","wiki"}},unknown={"frequency","location","trigger"},facts={{"duration","This event last for a short time so find the chest quickly before others."},{"spawn","15 chests spawn total."},{"cost","Rare Chest (Blue Glow):~25,000 Beri, ~5 Gems"},{"cost","Epic Chest (Purple Glow): ~50,000 Beri, ~20 Gems, ~2 Compasses"},{"cost","Legendary (Gold glow): ~200,000 Beri, ~35 Gems, ~4 Compasses"}}},
		{id="event.xp_boost",name="Evento de EXP (multiplicador)",category="event",verification="confirmed",internal={"workspace @XpEventEndsAt","workspace @XpEventMultiplier"},srcEvidence="fila 'xp' de Inicio",evidence={level="confirmed"},unknown={"duration","frequency","location","trigger"}},
		{id="fruit.barrier",name="Barrier",aliases={"Bari Bari No Mi"},category="fruit",verification="documented",rarity="Uncommon",fruitType="Paramecia",wiki=3,unknown={"internalName"},abilities={{"Wall","move","25 Defense"},{"Slam","move","50 Melee"},{"Prison","move","300 Defense"},{"Room","move","100 Defense"},{"Barrier Bat","move","200 Melee"},{"Barrier Body","move","400 Defense"}}},
		{id="fruit.bomb",name="Bomb",aliases={"Bomu Bomu No Mi"},category="fruit",verification="documented",rarity="Uncommon",fruitType="Paramecia",wiki=3,unknown={"internalName"},facts={{"spawn","Every strike carries a hidden detonation."},{"requirement","(Requires a Bare-Handed Melee Fighting Style | Deals an additional instance of explosive damage on top of normal melee damage | Scales with Melee Stat & Melee Affinity)"}},abilities={{"Explosive Touch","passive",nil},{"Bomb Punch","move","50 Melee"},{"Bomb Boost","move","50 Melee"},{"Booger Bomb","move","200 Sniper"},{"Bomb Wave","move","300 Sniper"},{"Full Body","move","400 Defense"}}},
		{id="fruit.candy",name="Candy",aliases={"Ame Ame No Mi"},category="fruit",verification="documented",rarity="Rare",fruitType="Logia",wiki=4,unknown={"internalName"},facts={{"reward","Sweetness gives way to sharpness."},{"spawn","(Max Damage: 250 | Base Damage: 150 | Additional 10 Damage for every 0.1 Defense Affinity with Haki | Damage scales with Defense Affinity | Increases user's damage resistance by 15% × Defense Affinity)"},{"duration","(Max Damage: 6,000 | Projectile Size scales with Sniper Affinity and Charge | Slow duration: 2–4 seconds, scales with Affinity)"},{"duration","(Stun duration: 2–4 seconds, scales with Affinity)"}},abilities={{"Logia Reflex","passive",nil},{"Candy Blades","move","50 Sword"},{"Spike Body","move","75 Defense"},{"Jawbreaker","move","100 Sniper"},{"Syrup Trap","move","125 Defense"},{"Syrup Wave","move","150 Melee"},{"Syrup Hook","move","175 Sniper"}}},
		{id="fruit.chilly",name="Chilly",aliases={"Hie Hie No Mi"},category="fruit",verification="documented",rarity="Rare",fruitType="Logia",wiki=4,unknown={"internalName"},facts={{"reward","Additionally, their mastery over freezing temperatures grants immunity to the hypothermic effects of Snow."},{"duration","(Max Damage: 2,000 | Maximum Freeze duration: 6 seconds | Can freeze Tsunamis created by Quake)"}},abilities={{"Logia Reflex","passive",nil},{"Freezing Punch","move","100 Melee"},{"Chilly Sword","move","50 Sword"},{"Ice Path","move","70 Melee"},{"Ice Wave","move","400 Sniper"}}},
		{id="fruit.chop",name="Chop",aliases={"Bara Bara No Mi"},category="fruit",verification="documented",rarity="Common",fruitType="Paramecia",wiki=5,unknown={"internalName"},facts={{"duration","Once reaching the target, the arm will slash away repeatedly for ~10 seconds."}},abilities={{"Chop Choke","move","100 Melee"},{"Chop Pursuit","move","150 Sword"},{"Chop Car","move","200 Melee"},{"Chop Buzzsaw","move","250 Sword"},{"Chop Festival","move","300 Melee"}}},
		{id="fruit.clear",name="Clear",category="fruit",verification="archived",rarity="Common",fruitType="Paramecia",wiki=5,unknown={"internalName"}},
		{id="fruit.clone",name="Clone",aliases={"Mane Mane No Mi"},category="fruit",verification="archived",rarity="Common",fruitType="Paramecia",wiki=5,unknown={"internalName"}},
		{id="fruit.dark",name="Dark",aliases={"Yami Yami No Mi"},category="fruit",verification="documented",rarity="Ultra Rare",fruitType="Special Paramecia",wiki=6,unknown={"internalName"},facts={{"requirement","You may be one with the darkness, but you now carry the burden of the supernatural, having a body that must bear its costs."}},abilities={{"Inexorable Touch","passive",nil},{"Dark Body","passive",nil},{"Cursed","passive",nil},{"Dark Charge","move",nil},{"Dark Vortex","move",nil},{"Black Hole","move",nil}}},
		{id="fruit.diamond",name="Diamond",aliases={"Kira Kira No Mi"},category="fruit",verification="documented",rarity="Uncommon",fruitType="Paramecia",wiki=3,unknown={"internalName"},facts={{"spawn","(Damage Reduction starts at 35% w/ maxed Defense Stat | Increases by 2.5% for every 0.1 Defense Affinity | Knockback Resistance scales with Affinity | Cannot be disabled by stuns | Weighs down and sinks small boats while active)"}},abilities={{"Diamond Bar","passive",nil},{"Diamond Capacity","passive",nil},{"Recharge","passive",nil},{"Activation Cooldown","passive",nil},{"Break Cooldown","passive",nil},{"Diamond Body","move","20 Defense"},{"Diamond Sword","move","50 Sword"},{"Diamond Cluster","move","80 Defense"}}},
		{id="fruit.dough",name="Dough",aliases={"Mochi Mochi No Mi"},category="fruit",verification="documented",rarity="Ultra Rare",fruitType="Special Paramecia",wiki=6,unknown={"internalName"},abilities={{"Burning Mochi","move","300 Sniper"},{"Dough Bazooka","move","250 Melee"},{"Mochi Gatling","move","500 Melee"},{"Donut Roll","move","300 Melee"},{"Mochi Wasteland","move","450 Defense"},{"Torque Mochi","move","500 Defense"}}},
		{id="fruit.flare",name="Flare",aliases={"Mera Mera No Mi"},category="fruit",verification="documented",rarity="Rare",fruitType="Logia",wiki=4,unknown={"internalName"},facts={{"requirement","(Immune to Melee, Sword, and Gun attacks without Haki | Burn deals up to 350 damage per tick at maximum Affinity | Burn damage scales with the required stat of each ability | Burn can be removed by entering water)"},{"spawn","The user releases a tremendous wave of fire that expands horizontally in every direction, creating a 360-degree explosion of flames capable of striking opponents surrounding them."},{"duration","Charging takes approximately 15 seconds."}},abilities={{"Logia Reflex","passive",nil},{"Jet","move","100 Melee"},{"Fire Fist","move","50 Sniper"},{"Fire Wave","move","200 Defense"},{"Flame Pillar","move","250 Defense"},{"Flame Emperor","move","400 Sniper"}}},
		{id="fruit.float",name="Float",aliases={"Fuwa Fuwa No Mi"},category="fruit",verification="documented",rarity="Uncommon",fruitType="Paramecia",wiki=3,unknown={"internalName"},facts={{"duration","(Increased Dash Distance | Reduced Dash Cooldown | Holding Spacebar/Jump activates Floating | Float Duration scales with Haki, ranging from 5–10 seconds | Flight Disabled | Stuns interrupt Floating)"},{"spawn","The user summons six small rocks that begin floating and orbiting around their body while the ability is being charged."},{"duration","(Charge Time: 6 seconds | Cooldown: 6 seconds | Six projectiles | 1,500 Damage per Rock × Affinity | Decent-sized projectile hitboxes | Rocks visually orbit the user similarly to Vampire's Necromancy)"},{"spawn","The user summons two enormous stone slabs on opposite sides of a targeted location before forcefully bringing them together."},{"requirement","Its broad area of effect makes it particularly effective against groups of opponents, although its relatively short range requires careful positioning."},{"spawn","The summoned construct uses the same environmental material manipulation mechanic as Gravity Assault."},{"spawn","The user summons six enormous lions around their position, commanding them to charge toward a central location."},{"duration","(Six Giant Lions | 5,000 Damage × Affinity per Lion | Ground Spike deals an additional 5,000 Damage × Affinity | Applies Slow similar to Tsunami | Charge Time: 20 seconds | Cooldown: 2 minutes | Uses the same charge and cooldown system as Meteor)"}},abilities={{"Weightless","passive",nil},{"Rock Rush","move","50 Sniper"},{"Crushing Pillars","move","100 Defense"},{"Float Prison","move","150 Defense"},{"Lion's Mane","move","200 Melee"},{"Float Slab","move","250 Defense"},{"Lion's Cage","move","400 Sniper"}}},
		{id="fruit.gas",name="Gas",aliases={"Gasu Gasu No Mi"},category="fruit",verification="documented",rarity="Rare",fruitType="Logia",wiki=4,unknown={"internalName"},abilities={{"Logia Reflex","passive",nil},{"Gas Form","move","200 Melee"},{"Blue Sword","move","50 Sword"},{"Airless World","move","100 Defense"},{"Gastille","move","200 Sniper"},{"Flammable","move","250 Defense"},{"Gas Robe","move","300 Defense"}}},
		{id="fruit.gravity",name="Gravity",aliases={"Zushi Zushi No Mi"},category="fruit",verification="documented",rarity="Rare",fruitType="Paramecia",wiki=4,unknown={"internalName"},facts={{"spawn","By altering the gravity surrounding themselves and their opponents, the user can levitate, repel enemies, crush targets beneath immense pressure, and summon devastating celestial objects from the heavens."},{"reward","Even the strongest will eventually yield to gravity."},{"spawn","The user manipulates gravitational forces to summon a barrage of meteors from above, raining them down across the surrounding area."},{"spawn","After being summoned, the meteor begins its descent, eventually crashing into the battlefield with tremendous destructive force and destroying everything caught within its impact."}},abilities={{"Gravity Flying","move","200 Defense"},{"Gravity Repel","move","75 Sniper"},{"Gravity Assault","move","100 Sniper"},{"Crushing Force","move","300 Defense"},{"Meteor Shower","move","300 Sniper"},{"Meteor Crash","move","400 Sniper"}}},
		{id="fruit.gum",name="Gum",aliases={"Gomu Gomu No Mi"},category="fruit",verification="documented",rarity="Uncommon",fruitType="Paramecia",wiki=3,unknown={"internalName"},facts={{"reward","Gum is a Paramecia-type Devil Fruit that grants the user's body the properties of rubber, allowing them to stretch, extend, and propel their limbs with tremendous force."},{"reward","The user's rubber composition grants immunity to melee and gun attacks, as well as Rumble abilities, provided the attacker does not have Haki."},{"requirement","This transformation unlocks an entirely new set of Jet-based techniques."},{"requirement","Upon unlocking Second Gear at 100 Melee, the user gains access to the Jet ability moveset while transformed."},{"requirement","Even the greatest engines must eventually slow down."}},abilities={{"Rubber Body","passive",nil},{"Normal Mode","move",nil},{"Pistol","move","25 Melee"},{"Bazooka","move","50 Melee"},{"Gatling","move","75 Melee"},{"Gum Rocket","move","100 Melee"},{"2nd Gear","move","100 Melee"},{"Jet Pistol","move","125 Melee"},{"Jet Bazooka","move","150 Melee"},{"Jet Gatling","move","175 Melee"},{"Jet Rocket","move","200 Melee"},{"Gear Down","move","100 Melee"},{"Smelt & Hot","move",nil},{"Vampire","move",nil},{"Venom","move",nil},{"Magma","move",nil},{"Candy & Snow","move",nil},{"Dark","move",nil}}},
		{id="fruit.hobby",name="Hobby",aliases={"Hobi Hobi No Mi"},category="fruit",verification="documented",rarity="Uncommon",fruitType="Paramecia",wiki=3,unknown={"internalName"},facts={{"requirement","Those under the effect of your transformation skill cannot willingly end themselves and must wait for their time to be their self again by the grace of your mercy."},{"requirement","(Requires the target to be transformed)"}},abilities={{"Transform","move","50 Melee"},{"Revert","move","50 Melee"},{"Target","move","150 Melee"}}},
		{id="fruit.hollow",name="Hollow",aliases={"Horo Horo No Mi"},category="fruit",verification="documented",rarity="Rare",fruitType="Paramecia",wiki=4,unknown={"internalName"},facts={{"requirement","(Float-type flight | Momentum affects movement speed | Projection is immune to damage | Physical body remains vulnerable | Required for Possession)"},{"spawn","The user summons a multitude of miniature Hollows that seek out nearby enemies, relentlessly pursuing and damaging their targets."},{"spawn","(75 Base Damage per Hollow | Haki Supported & Damage and number of mini-hollows spawned scales w/ Sniper Affinity)"}},abilities={{"Projection","move","100 Defense"},{"Fade","move","100 Defense"},{"Negative Hollow","move","100 Sniper"},{"Special Hollow","move","300 Sniper"},{"Mini-Hollow","move","200 Sniper"}}},
		{id="fruit.hot",name="Hot",aliases={"Atsu Atsu No Mi"},category="fruit",verification="documented",rarity="Common",fruitType="Paramecia",wiki=5,unknown={"internalName"},facts={{"reward","Hot is a paramecia-type that give the user the ability to produce and control an unprecedented amount of heat."},{"spawn","Unleash every ounce of accumulated heat in a devastating burst."}},abilities={{"Nose Jet","move","200 Defense"},{"Hot Body","move","50 Defense"},{"Overheat","move","250 Defense"},{"Overheat","move","C"},{"Damage Formula","move",nil},{"Heatwave","move","300 Defense"},{"Damage Formula","move",nil}}},
		{id="fruit.light",name="Light",aliases={"Pika Pika No Mi"},category="fruit",verification="documented",rarity="Rare",fruitType="Logia",wiki=4,unknown={"internalName"},facts={{"spawn","A continuous stream of concentrated light, growing increasingly destructive with every passing moment."},{"spawn","(Duration: 5 seconds | 20 Hits | Hits every 0.25 seconds | Starting Damage: 10, scaling up to 20 with Affinity | Damage progressively increases with each hit | Starting Damage scales with Affinity)"}},abilities={{"Logia Reflex","passive",nil},{"Light Sword","move","100 Sword"},{"Light Blast","move","20 Sniper"},{"Yata Mirror","move","300 Melee"},{"Light Beam","move","250 Sniper"},{"Sacred Jewels","move","300 Defense"}}},
		{id="fruit.love",name="Love",aliases={"Mero Mero No Mi"},category="fruit",verification="documented",rarity="Uncommon",fruitType="Paramecia",wiki=3,unknown={"internalName"},abilities={{"Petrified Vulnerability","passive",nil},{"Petrify","move","25 Defense"},{"Glare","move","100 Sniper"},{"Pistol Kiss","move","150 Sniper"},{"Beam","move","200 Sniper"},{"Slave Arrow","move","250 Sniper"},{"Arrow Storm","move","300 Sniper"}}},
		{id="fruit.luck",name="Luck",aliases={"Raki Raki No Mi"},category="fruit",verification="documented",rarity="Uncommon",fruitType="Paramecia",wiki=3,unknown={"internalName"},facts={{"reward","Its unique mechanics revolve around a Luck Bar, rewarding fortunate outcomes while allowing the user to gradually improve the effectiveness of their abilities."},{"duration","(Removes current stun | Increased Luck for 5 seconds)"},{"reward","The user activates a roulette-style slot machine, rolling for a variety of potential rewards."},{"reward","However, matching three identical symbols grants a special reward depending on the result."},{"duration","- 3 Skulls: The user is stunned for 1 second but receives additional Luck Bar."},{"reward","- 3 Sevens: Increases the user's health regeneration and significantly enhances the luck effectiveness of other abilities, preventing them from producing unfavorable rewards."},{"cost","There is a 1-in-6 chance of the coin landing on its damaging outcome, dealing damage equivalent to 25% of the target's health multiplied by the user's Sniper Affinity."},{"reward","Any other result grants the user additional Luck Bar based on their Sniper Affinity."},{"requirement","When the user is already benefiting from luck-enhancing effects granted by other abilities, the probability of obtaining the damaging outcome increases to 1-in-3."},{"spawn","The user summons a golden skull that radiates an aura of luck, temporarily enhancing their fortune and draining the health of nearby opponents."},{"duration","(Luck enhancement lasts 5 seconds × Defense Affinity | Nearby opponents lose 2.5–5% of their health per second | Fortune's Purge detonates the skull for additional damage)"}},abilities={{"Fortune's Favor","passive",nil},{"Fortune's Purge","move",nil},{"Slot Machine","move",nil},{"Dice Roll","move",nil},{"Coin Throw","move",nil},{"Golden Casino","move",nil}}},
		{id="fruit.magma",name="Magma",aliases={"Magu Magu No Mi"},category="fruit",verification="documented",rarity="Rare",fruitType="Logia",wiki=4,unknown={"internalName"},facts={{"reward","Their elemental nature also grants natural resistance against other forms of heat and elemental attacks."},{"reward","While Magma Body is active, the user's intense temperature grants immunity to the slowing effects of Snow."},{"reward","(Max Damage: 400 | Applies Burn | Burn damage scales with Defense Affinity | Grants immunity to Snow's Slow while active)"},{"duration","(Max Damage: 6,000 | Chargeable | Magma Burn deals up to 200 damage over time | Burn duration: 20 seconds)"},{"spawn","The longer the ability is charged, the higher the magma fists spawn, allowing them to descend from greater heights and gradually grow larger as they fall."}},abilities={{"Logia Reflex","passive",nil},{"Magma's Dominance","passive",nil},{"Magma Body","move","200 Defense"},{"Magma Pool","move","20 Defense"},{"Great Eruption","move","50 Melee"},{"Magma Flow","move","200 Sniper"},{"Volcanic Leap","move","150 Melee"},{"Magma Rain","move","400 Melee"}}},
		{id="fruit.ope",name="Ope",aliases={"Ope Ope No Mi"},category="fruit",verification="documented",rarity="Rare",fruitType="Paramecia",wiki=4,unknown={"internalName"},facts={{"reward","Unlike most Devil Fruits, its abilities rely heavily on stamina management, rewarding users who carefully manage their resources and control the battlefield."},{"spawn","Every operation comes at a cost."},{"requirement","- Stamina Consumption: All Ope abilities require stamina to activate."},{"reward","- Kill Reward: Killing another player restores 50% of the user's stamina."},{"requirement","(Size scales with Defense and Defense Affinity | Required to use all other Ope abilities | Stamina regeneration is reduced while active )"},{"duration","(150 Stamina per use | Maximum Damage: 50% of target's maximum HP | Disables the target's Devil Fruit abilities for 2 seconds upon crushing the heart | Does not award Bounty or Beri upon killing the target)"},{"duration","(Maximum HP Reduction: 25% × Sword Affinity | Duration: 5 seconds × Sword Affinity | Uses Sword Affinity | Maximum HP reduction is not direct damage | Healing is capped at the temporarily reduced maximum HP)"}},abilities={{"Stamina Bar","passive",nil},{"Room","move","40 Defense"},{"Shambles","move","100 Defense"},{"Severance","move","200 Sword"},{"Scalpel","move","400 Sword"},{"Gamma Knife","move","300 Sword"}}},
		{id="fruit.phoenix",name="Phoenix",aliases={"Tori Tori No Mi"},category="fruit",verification="documented",rarity="Ultra Rare",fruitType="Mythical Zoan",wiki=6,unknown={"internalName"},facts={{"reward","Phoenix is a Zoan-type devil fruit that grants the user the ability to turn into a phoenix and phoenix hybrid at will, as well as granting immense healing power to themselves and those around the user."}},abilities={{"Phoenix Flames","passive",nil}}},
		{id="fruit.plasma",name="Plasma",aliases={"Zuma Zuma No Mi"},category="fruit",verification="documented",rarity="Rare",fruitType="Paramecia",wiki=4,unknown={"internalName"},facts={{"requirement","The sphere automatically attacks any opponents who venture sufficiently close, dealing continuous damage without requiring the user to manually target them."},{"spawn","The user releases a tremendous burst of plasma in every direction, damaging nearby opponents caught within its radius."},{"spawn","(Maximum Damage: 7,200 | Damage starts at 4,200 with maximum Defense and increases by 300 for every 0.1 Defense Affinity with Haki)"}},abilities={{"Logia Reflex","passive",nil},{"Energize","move","80 Melee"},{"Plasma Coil","move","180 Sniper"},{"Plasma Burst","move","240 Defense"},{"Plasma Cannon","move","360 Sniper"}}},
		{id="fruit.pumpkin",name="Pumpkin",aliases={"Kabo Kabo No Mi"},category="fruit",verification="documented",rarity="Rare",wiki=4,unknown={"internalName"},facts={{"spawn","Pumpkin is a non-cannon seaonsal-born paramecia-type Devil Fruit that allows the user to summon and manipulate pumpkins, vines, and supernatural plant-based constructs."},{"spawn","The user summons a collection of vines that erupt from the ground at a targeted location, ensnaring anyone caught within their reach."},{"duration","(Max Range: 120 studs | Damage: 900 | Area Radius: 11–16 studs | Root Duration: 1.6 seconds | Rooted opponents can still attack | 9-second cooldown)"},{"duration","(Damage Reduction: 80–88% | Duration: 3.5–4.5 seconds | Burst Damage: 700 | Explosion Radius: 13–17 studs | Cooldown: 15 seconds after the ability ends | Stuns break the shell without triggering its explosion)"},{"spawn","Additional lanterns are gathered every 0.4 seconds, allowing the user to build up a devastating volley of explosive projectiles."},{"spawn","(Duration: 7 seconds | Area Width: 22–30 studs | Reduces enemy movement speed by 50% | Pumpkin eruption every 0.5–0.7 seconds | 160 Damage per tick| Damage cannot be dodged | Stuns do not terminate the ability | 20-second cooldown)"},{"duration","- Duration: 20–30 seconds."},{"duration","- Vine Snare: Root duration increases from 1.6 to 2.2 seconds."},{"duration","(Cooldown: 60 seconds after the transformation ends)"}},abilities={{"Pumpkin Bomb","move","50 Sniper"},{"Vine Snare","move","100 Defense"},{"Pumpkin Shield","move","150 Defense"},{"Lantern Barrage","move","250 Sniper"},{"Patch Field","move","350 Defense"},{"Pumpking Form","move","450 Defense"},{"Transformation Effects","move",nil},{"Enhanced Ability Interactions","move",nil}}},
		{id="fruit.quake",name="Quake",aliases={"Gura Gura No Mi"},category="fruit",verification="documented",rarity="Ultra Rare",fruitType="Paramecia",wiki=6,unknown={"internalName"},facts={{"spawn","Summon two tsunamis from both the left and right of the user."},{"spawn","The ground beneath your foes will be their downfall, every tremor comes unseen."},{"spawn","The user summons pillars of earth that deal damage."}},abilities={{"Seismic Wave","move",nil}}},
		{id="fruit.rumble",name="Rumble",aliases={"Goro Goro No Mi"},category="fruit",verification="documented",rarity="Rare",fruitType="Logia",wiki=4,unknown={"internalName"},facts={{"spawn","By harnessing tremendous electrical energy, the user can summon lightning strikes, unleash devastating electrical bursts, and travel across the battlefield through instantaneous lightning teleports."},{"spawn","However, with sufficient charge, the technique changes entirely: instead of firing a beam, the user summons a darkened cloud above the targeted location, calling down a devastating lightning strike upon the area."},{"spawn","(Damage: 600 in beam form or up to 12,000 in charged form | Range and Damage scale with Affinity | Charged form summons a lightning cloud above the target location)"},{"spawn","Zeus heeds your call, summon a giant storm cloud overhead, unleashing a relentless barrage of lightning bolts upon the battlefield."}},abilities={{"Logia Reflex","passive",nil},{"Lightning Teleport","passive",nil},{"Rumble Staff","move","100 Sword"},{"El Thor","move","200 Sniper"},{"Lightning Blitz","move","50 Melee"},{"Overload","move","100 Defense"},{"Thunderstorm","move","400 Defense"}}},
		{id="fruit.sand",name="Sand",aliases={"Suna Suna No Mi"},category="fruit",verification="documented",rarity="Rare",fruitType="Logia",wiki=4,unknown={"internalName"},facts={{"spawn","By controlling the shifting sands, the user can summon devastating sand formations, create bladed weapons, and unleash powerful sandstorms capable of trapping opponents."}},abilities={{"Logia Reflex","passive",nil},{"Sand Flying","move","100 Melee"},{"Sand Spike","move","50 Sniper"},{"Desert Spada","move","150 Sword"},{"Sandstorm","move","100 Defense"}}},
		{id="fruit.shadow",name="Shadow",aliases={"Kage Kage No Mi"},category="fruit",verification="possibly_obsolete",rarity="Rare",fruitType="Paramecia",wiki=4,unknown={"internalName"},facts={{"spawn","(3,200 Damage per Hit | Attacks every 4 seconds | Pursuit Duration: 10 seconds | Maximum Tracking Range: 200 studs)"},{"spawn","(Punches every 0.75 seconds | Shadow Wave every 3.5 seconds | Shadow Wave Damage: 1,200 | Shadow Wave can hit airborne targets)"},{"spawn","The user gathers shadows to unleash an enormous explosion of destructive energy, with its initial blast becoming stronger for every shadow consumed."},{"spawn","(Initial Explosion: 4,000 Damage + 1,000 per Shadow | Increased Explosion Radius | Continuous Aura: 700 Damage every 2 seconds | 40% Damage Reduction | 40-second cooldown)"}},abilities={{"Brick Bat","move",nil},{"Kage Kiri","move",nil},{"Doppelman","move",nil},{"Kagemusha","move",nil},{"Shadow Zombie","move",nil},{"Shadow's Asgard","move",nil}}},
		{id="fruit.slip",name="Slip",aliases={"Sube Sube No Mi"},category="fruit",verification="documented",rarity="Common",fruitType="Paramecia",wiki=5,unknown={"abilities","internalName"}},
		{id="fruit.smelt",name="Smelt",aliases={"Gutsu Gutsu No Mi"},category="fruit",verification="documented",rarity="Uncommon",fruitType="Paramecia",wiki=3,unknown={"internalName"},facts={{"reward","The user's molten composition grants immunity to Flare and Magma attacks, allowing them to withstand the intense heat of these elements without suffering damage."},{"requirement","(Speed scales with Defense Affinity | Haki must remain active to retain the increased damage after activation)"}},abilities={{"Molten Body","passive",nil},{"Molten Sword","move","50 Sword"},{"Silver Body","move","20 Defense"},{"Spew","move","50 Defense"},{"Ore Feast","move","100 Defense"}}},
		{id="fruit.smoke",name="Smoke",aliases={"Moku Moku No Mi"},category="fruit",verification="documented",rarity="Rare",fruitType="Logia",wiki=4,unknown={"internalName"},abilities={{"Fly","move","100 Melee"},{"White Out","move","100 Melee"},{"White Fist","move","50 Melee"},{"Whiteout Burst","move","300 Defense"},{"Smoke Screen","move","350 Defense"}}},
		{id="fruit.snow",name="Snow",aliases={"Yuki Yuki No Mi"},category="fruit",verification="documented",rarity="Rare",fruitType="Logia",wiki=4,unknown={"internalName"},facts={{"requirement","(Requires contact with another player to apply Hypothermia | Hypothermia deals 395 damage per tick for 15 ticks at 2.0 Defense Affinity and maximum Defense)"},{"duration","(Hypothermia deals 500 damage per tick | Size scales with Defense and Affinity | Both variants disappear after 10 seconds)"}},abilities={{"Logia Reflex","passive",nil},{"Snow Globe","move","100 Defense"},{"Snow Body","move","100 Defense"},{"Snow Pellet","move","150 Sniper"},{"Snow Angel","move","200 Defense"},{"Snow Boulder","move","100 Sniper"},{"Snow Ring","move","200 Defense"}}},
		{id="fruit.spin",name="Spin",aliases={"Fruit Fruit No Mi"},category="fruit",verification="documented",rarity="Common",fruitType="Paramecia",wiki=5,unknown={"abilities","internalName"}},
		{id="fruit.spring",name="Spring",aliases={"Bane Bane No Mi"},category="fruit",verification="confirmed",rarity="Common",fruitType="Paramecia",internal={"Workspace.Instances.Drops 'Spring Fruit' (FruitItem = Spring)"},wiki=5,evidence={level="confirmed"},abilities={{"Jump","move","20 Melee"}}},
		{id="fruit.string",name="String",aliases={"Ito Ito No Mi"},category="fruit",verification="documented",rarity="Uncommon",fruitType="Paramecia",wiki=3,unknown={"internalName"},facts={{"duration","The web stays up for around 5 seconds."}},abilities={{"Release","move","10 Sniper"},{"Tether","move","50 Sniper"},{"Sky String","move","50 Sniper"},{"Flapping Thread","move","250 Sniper"},{"Bird Cage","move","300 Defense"},{"God Thread","move","400 Sniper"}}},
		{id="fruit.swim",name="Swim",aliases={"Sui Sui No Mi"},category="fruit",verification="documented",rarity="Common",fruitType="Paramecia",wiki=5,unknown={"internalName"},abilities={{"Swim","move","80 Melee"},{"Dive","move","100 Melee"}}},
		{id="fruit.vampire",name="Vampire",aliases={"Batto Batto No Mi"},category="fruit",verification="documented",rarity="Ultra Rare",fruitType="Mythical Zoan",wiki=6,unknown={"internalName"},facts={{"spawn","Every soul taken is another servant waiting to be awakened."},{"reward","Soul Collection: Killing an NPC or player through any means causes them to drop a soul, which can be collected and used for Necromancy."},{"reward","This ability grants increased movement speed and provides 50% damage reduction while active."},{"spawn","The user summons a swarm of bats that relentlessly pursue an individual target, rapidly dealing special damage."}},abilities={{"Soul Reaper","passive",nil},{"Sanguine Vampiris","move","50 Sword"},{"Hypnosis","move","300 Sniper"},{"Shadow Step","move","100 Melee"},{"Necromancy","move","100 Defence"},{"Bat Swarm","move","200 Sniper"},{"Transform","move","400 Melee"}}},
		{id="fruit.venom",name="Venom",aliases={"Doku Doku No Mi"},category="fruit",verification="documented",rarity="Rare",fruitType="Paramecia",wiki=4,unknown={"internalName"},facts={{"spawn","- Fast Venom: Deals damage every 0.1 seconds."},{"spawn","- Normal/Medium Venom: Deals damage every 0.4 seconds."},{"spawn","- Slow Venom: Deals damage every 0.6 seconds."},{"requirement","Requires Poison Coat to be active and will deactivate it upon use."},{"spawn","Travel through your summoned Venom Hydra, entering its body and emerging from its mouth, allowing long-distance movement similar to Light's Yata Mirror."}},abilities={{"Venom Immunity","passive",nil},{"Venom Composition","passive",nil},{"Damage Over Time","passive",nil},{"Venom Road","passive",nil},{"Venom Demon Interaction","passive",nil},{"Poison Breath","move","50 Sniper"},{"Poison Coat","move","200 Defense"},{"Venom Hydra","move","400 Sniper"},{"Chloro Ball","move","400 Sniper"},{"Venom Demon Interaction","move",nil},{"Venom Demon","move","500 Defense"}}},
		{id="info.credits",name="Credits",category="info",verification="documented",wiki=7},
		{id="info.credits__archived",name="Credits",category="info",verification="archived",wiki=7,facts={{"requirement","The simplicity of the game kept many players hooked, and albeit a rather addictive, unique, and fun fruit obtainment method."}}},
		{id="info.info",name="Info",category="info",verification="archived",wiki=7},
		{id="info.legendary_mode",name="Legendary Mode",category="info",verification="documented",wiki=7,relations={{"links_to","island.mountain_island","wiki-link"},{"mentions","island.mountain_island","name"}},facts={{"requirement","To obtain Legendary Mode, players must max out every stat except buso and/or ken haki, achieve a bounty of 10 million, and have eaten a devil fruit."},{"requirement","### “_TO KNOW EVERYTHING, YOU MUST GIVE… EVERYTHING._”"}}},
		{id="info.primordial",name="Primordial",category="info",verification="documented",wiki=7,facts={{"requirement","The simplicity of the game kept many players hooked, and albeit a rather addictive, unique, and fun fruit obtainment method was one the greatest things to look forward to, alongside it’s unique and primary devil fruit mechanic: Legendary Mode."}}},
		{id="info.rarity_boxes",name="Rarity Boxes",category="info",verification="unknown",wiki=7,unknown={"description"}},
		{id="info.stats_and_affinity",name="Stats & Affinity",category="info",verification="documented",wiki=7,facts={{"requirement","You level these up to increase devil fruit damage, weapon damage, effects, and unlock skills attuned to that specific stat."}}},
		{id="island.abandoned_base",name="Abandoned Base",category="island",group="other",verification="documented",wiki=8,unknown={"internalName"},facts={{"requirement","There must’ve been a reason for it long ago considering the watch towers placement."}}},
		{id="island.big_snow",name="Big Snow",category="island",group="other",verification="documented",wiki=8,unknown={"internalName"}},
		{id="island.caver_island",name="Caver Island",aliases={"The Gunners Cave Island"},category="island",group="other",verification="inferred",internal={"Map.Islands.IslandCaver"},wiki=8,evidence={level="inferred",note="QuestCaver (Sheriff Dale) en ella"},relations={{"mentions","npc.krusch","name"}}},
		{id="island.cliff_tops",name="Cliff Tops",category="island",group="other",verification="inferred",internal={"Map.Islands.IslandCliffs"},wiki=8,evidence={level="inferred"}},
		{id="island.clover_isle",name="Clover Isle",aliases={"Expertise Island"},category="island",group="other",verification="documented",wiki=8,relations={{"links_to","npc.the_expert","wiki-link"},{"mentions","npc.the_expert","name"}},unknown={"internalName"}},
		{id="island.crab_isle",name="Crab Isle",category="island",group="other",verification="inferred",internal={"Map.Islands.Island15"},wiki=8,evidence={level="inferred",note="tiene QuestCrabIsle al lado"}},
		{id="island.crescent",name="Crescent",category="island",group="other",verification="documented",wiki=8,unknown={"internalName"}},
		{id="island.death_spire",name="Death Spire",category="island",group="other",verification="documented",wiki=8,unknown={"internalName"},facts={{"spawn","They say if you bring 13 devil fruits for the lower circle, and 3 for what’s at the top, you can summon a knight of steel, darkness, and evil."}}},
		{id="island.deepwaken_trench",name="Deepwaken Trench",category="island",group="other",verification="inferred",internal={"Map.Islands.IslandDeepwake"},wiki=8,evidence={level="inferred",note="nombre interno visto; correspondencia por nombre"},relations={{"mentions","enemy.captain_blacksurf","name"}},facts={{"spawn","Every once in a while, the town’s champion swims by to challenge any of powerful locals."},{"reward","Be wary, he’s not an easy foe, and if by some miracle you do win, he may be humble enough to give you his surfboard."}}},
		{id="island.galley_isle",name="Galley Isle",aliases={"Plaza"},category="island",group="other",verification="documented",wiki=8,relations={{"mentions","npc.fish_merchant","name"}},unknown={"internalName"}},
		{id="island.gull_rock",name="Gull Rock",aliases={"Not much is on this rock"},category="island",group="other",verification="documented",wiki=8,unknown={"internalName"}},
		{id="island.halloween_island",name="Halloween Island",aliases={"Moria’s Land","Shadow Island","Spooky Island"},category="island",group="halloween",verification="inferred",internal={"Map.Islands.IslandHalloween"},wiki=8,evidence={level="inferred",note="nombre interno visto en 1.3.0"},relations={{"in_region","region.halloween","wiki-group"}},facts={{"reward","Or Shadow Island, considering the creepy vibes this place gives off, is a seasonal island that’s appeared from the fog this Halloween to grant several tricks… and a new treat."},{"spawn","Do not fear though, explore this island before it vanishes sometimes late Fall."}}},
		{id="island.jungle_island",name="Jungle Island",aliases={"The Jungle"},category="island",group="other",verification="documented",wiki=8,unknown={"internalName"}},
		{id="island.marine_base",name="Marine Base",aliases={"Marine Fort"},category="island",group="other",verification="inferred",internal={"Map.Islands.Island4"},wiki=8,evidence={level="inferred",note="tiene QuestMarine al lado"},relations={{"mentions","enemy.marines","name"}}},
		{id="island.merlins_island",name="Merlin's Island",aliases={"Merlin’s Island"},category="island",group="other",verification="documented",wiki=8,unknown={"internalName"}},
		{id="island.mountain_island",name="Mountain Island",category="island",group="other",verification="inferred",internal={"Map.Islands.IslandMountain"},wiki=8,evidence={level="inferred"}},
		{id="island.pyramid",name="Pyramid",aliases={"Pyramid Island"},category="island",group="other",verification="documented",wiki=8,unknown={"internalName"}},
		{id="island.race_track_island",name="Race Track Island",category="island",group="other",verification="documented",wiki=8,unknown={"internalName"}},
		{id="island.rasputins_tower",name="Rasputin's Tower",category="island",verification="archived",wiki=8,unknown={"internalName"}},
		{id="island.revelry_island",name="Revelry Island",category="island",group="other",verification="documented",wiki=8,unknown={"internalName"},facts={{"reward","The drinks are a life saver, and provide a boost far greater than what Sam’s bartender might give."}}},
		{id="island.rot_island",name="Rot Island",aliases={"Rotted Island"},category="island",group="other",verification="documented",wiki=8,unknown={"internalName"}},
		{id="island.sams_bar_and_pirates_land",name="Sam's Bar & Pirate's Land",aliases={"Sam’s Bar","Pirate's Land","Sam's Bar"},category="island",group="other",verification="confirmed",internal={"Map.Islands.IslandPirate"},wiki=8,evidence={level="confirmed",note="QuestMerchant2 'Quest Man' (~ -1305, 217, -1352); compass reclamado"}},
		{id="island.sand_dunes",name="Sand Dunes",aliases={"The Dunes"},category="island",group="other",verification="inferred",internal={"Map.Islands.IslandSandCastle"},wiki=8,evidence={level="inferred",note="los Fred y su NPC están ahí"},relations={{"mentions","npc.fortune_teller","name"},{"mentions","enemy.the_freds","name"}},facts={{"reward","There’s a fortune teller in the back who gives strange compasses… nothing likes Sam’s."}}},
		{id="island.smith_island",name="Smith Island",category="island",group="other",verification="unknown",wiki=8,unknown={"description","internalName"}},
		{id="island.snowy_island",name="Snowy Island",aliases={"Little Snow"},category="island",group="other",verification="documented",wiki=8,unknown={"internalName"}},
		{id="island.tree_island",name="Tree Island",aliases={"Bob Land"},category="island",group="other",verification="inferred",internal={"Map.Islands.IslandTREEA"},wiki=8,evidence={level="inferred"},relations={{"mentions","npc.calm_bob","name"}}},
		{id="island.windmill_and_town_island",name="Windmill & Town Island",aliases={"Spawn Islands","Windmill Island","Town Island"},category="island",group="other",verification="inferred",internal={"Map.Islands.IslandWindmill","Map.Islands.IslandTown"},wiki=8,evidence={level="inferred",note="la wiki junta dos islas del juego"},contradictions={"La wiki junta en una tarjeta dos islas que en el juego son modelos distintos (IslandWindmill, IslandTown)."},facts={{"spawn","Spawn Islands,"}}},
		{id="item.black_abyss_crab_toy",name="Black Abyss Crab Toy",category="item",verification="documented",wiki=0,card="Fishing"},
		{id="item.blessed_rod",name="Blessed Rod (Tier 4)",category="item",verification="documented",wiki=0,card="Fishing",relations={{"requires","item.super_rod","wiki"},{"requires","objective.sell_to_chef","wiki"},{"requires","objective.open_caches","wiki"},{"requires","objective.defeat_boss_times","wiki"},{"requires","objective.bring_item","wiki"}},facts={{"requirement","Catch 2,000 fish, sell 500 to the Chef, open 15 Emerald Caches, beat Captain Blacksurf five times and bring Merlin his logbook (a rare drop of his). Then he blesses your Super Rod for 10,000,000 Beri."}}},
		{id="item.compass",name="Compass",category="item",verification="confirmed",internal={"Tool Compass"},srcEvidence="Auto Sam",evidence={level="confirmed"}},
		{id="item.deep_reach_rod",name="Deep Reach Rod (Tier 5)",category="item",verification="documented",wiki=0,card="Fishing",relations={{"requires","item.blessed_rod","wiki"},{"requires","objective.difficult_catches","wiki"},{"rewards","item.black_abyss_crab_toy","wiki"}},facts={{"requirement","Catch 2,000 fish with a Blessed Rod in your bag and he tells you about the deep; land 25 Hard or Impossible catches with it and he hands you the Deep Cache"}}},
		{id="item.df_coin",name="DFCoin",category="item",verification="documented",wiki=0,card="Suspicious Man"},
		{id="item.essence",name="Essence",category="item",verification="documented",wiki=0,card="Trait Sage",unknown={"obtainment"},facts={{"cost","Exchange two essences to gain a trait roll."}}},
		{id="item.fish",name="Pez (Small / Medium / Large / Huge)",category="item",verification="confirmed",wiki=0,card="Fishing",facts={{"reward","Sell Value at 10/10: Small 1,000; Medium 5,000; Large 10,000; Huge 25,000 beri (x5 cooked)"}}},
		{id="item.fishing_cache",name="Cache de pesca (Copper T1 … Ruby T7, Deep Reach)",category="item",verification="documented",wiki=0,card="Fishing",unknown={"rewards"},contradictions={"La wiki dice 'Ruby requires at least Rod Tier 4', pero la tabla pone la Blessed Rod (Tier 4) como Unavailable en todas las dificultades."},facts={{"reward","Caches can yield different rewards depending on the Tier, Copper is Tier 1, and Ruby is Tier 7."}}},
		{id="item.fruit_box",name="Caja de fruta (Common Box…)",category="item",verification="confirmed",internal={"Tool '<Rareza> Box'","FruitBoxService.RE.Open"},srcEvidence="Auto abrir cajas",evidence={level="confirmed"},unknown={"dropRates","obtainment"}},
		{id="item.golden_compass",name="Golden Compass",category="item",verification="documented",wiki=0,card="Suspicious Man",facts={{"cost","Golden Compass: 14 DFCoins"}}},
		{id="item.haki_book",name="Haki Book (Ken / Buso)",category="item",verification="confirmed",srcEvidence="inventario",unknown={"obtainment","use"}},
		{id="item.merlins_logbook",name="Logbook (drop de Captain Blacksurf)",category="item",verification="documented",wiki=0,card="Fishing"},
		{id="item.package",name="Package (Merlin)",category="item",verification="confirmed",internal={"Tool Package"},srcEvidence="Auto Merlin",evidence={level="confirmed"},unknown={"obtainment"}},
		{id="item.stat_juice",name="Zumo de fruta normal",category="item",verification="confirmed",srcEvidence="Auto Stats"},
		{id="item.sturdy_rod",name="Sturdy Rod (Tier 2)",category="item",verification="documented",wiki=0,card="Fishing",relations={{"requires","objective.fish_count","wiki"}},facts={{"requirement","Obtainment: Keep fishing until you reach 200 Fish caught."},{"duration","Catch Rate: ~15 seconds per fish."}}},
		{id="item.super_rod",name="Super Rod (Tier 3)",category="item",verification="documented",wiki=0,card="Fishing",relations={{"requires","item.sturdy_rod","wiki"}},facts={{"requirement","Owning the Sturdy Rod and 1 million Beri, then talking to Merlin will allow you to get the Super Rod."},{"duration","Catch Rate: ~10 seconds per fish."}}},
		{id="item.treasure_chest",name="Cofre (Common / Rare / Epic / Legendary)",category="item",verification="confirmed",wiki=0,card="Treasure Rain",relations={{"rewards","item.compass","wiki"}},contradictions={"Common Chest '~5,00 Beri' (errata en la wiki: ¿5.000?)."},facts={{"reward","Epic Chest (Purple Glow): ~50,000 Beri, ~20 Gems, ~2 Compasses; Legendary (Gold glow): ~200,000 Beri, ~35 Gems, ~4 Compasses"}}},
		{id="item.treasure_map",name="Treasure Map",category="item",verification="documented",wiki=0,card="Ghost Ship",unknown={"use"}},
		{id="item.wood_rod",name="Wood Rod (Tier 1)",category="item",verification="documented",wiki=0,card="Fishing",facts={{"requirement","Obtainment: Do a quest for Merlin, and he’ll give you this rod."},{"duration","Catch Rate: ~25 seconds per fish."}}},
		{id="location.fisher_plaza",name="Fisher Plaza",category="location",verification="documented",wiki=0,card="Fishing",unknown={"island"}},
		{id="mechanic.cooking",name="Cocinar pescado (x5 de valor)",category="mechanic",verification="documented",wiki=0,card="Fishing",relations={{"part_of","system.fishing","wiki"},{"related","npc.chef","wiki"}},unknown={"location","remotes"}},
		{id="mechanic.expertise",name="Expertise (misiones de The Expert)",category="mechanic",verification="documented",wiki=0,card="The Expert",relations={{"rewards","mechanic.sam_compass","wiki"}},contradictions={"EXP por misión: Easy 100 > Medium 30 > Hard 20 (al revés de lo esperable; tal cual en la wiki)."},facts={{"spawn","He offers a quest every xx:00 UTC."},{"cost","You can upgrade this up to 2 times for a total of 3 stored quests • First upgrade: 500 Gems • Second upgrade: 1000"},{"reward","Quest exp (Normal/Elite): 100/140 Easy, 30/50 Medium, 20/40 Hard"}}},
		{id="mechanic.fishing_rod_progression",name="Progresión de cañas (Tier 1 → 5)",category="mechanic",verification="documented",wiki=0,card="Fishing",relations={{"part_of","system.fishing","wiki"}}},
		{id="mechanic.fruit_exchange",name="Canje de frutas por recompensas",category="mechanic",verification="documented",wiki=0,card="Suspicious Man",relations={{"part_of","npc.suspicious_man","wiki"}},facts={{"reward","Common Fruits: 25K Beri; Uncommon Fruits: 100K Beri; Rare Fruits: 1M Beri/ 50 Gems/ 1 DFCoin; Ultra Rare Box: 15M Beri/ 500 Gems/ 10 DFCoins"},{"cost","Prices are halved on weekends (Friday, Saturday, and Sunday.)"}}},
		{id="mechanic.fruit_summon",name="Invocación con frutas (Death Spire)",category="mechanic",verification="documented",wiki=0,card="Death Spire",relations={{"part_of","island.death_spire","wiki"}}},
		{id="mechanic.haki_training",name="Entrenamiento de haki (dojo)",category="mechanic",verification="confirmed",internal={"HakiDojoService Start/Strike/Answer/Game"},srcEvidence="Auto Train",evidence={level="confirmed"},relations={{"related","npc.silvers_rayleigh","evidence"}}},
		{id="mechanic.quest_exp_allocation",name="Reparto de EXP de misiones",category="mechanic",verification="documented",wiki=0,card="Quest Givers",relations={{"related","objective.board_quest","wiki"}}},
		{id="mechanic.sam_compass",name="Compass de Sam (cada 20 min)",category="mechanic",verification="confirmed",internal={"player @CompassTokenAt","Tool Compass @TreasureTarget"},srcEvidence="Auto Sam",evidence={level="confirmed"},facts={{"spawn","Expertise quests reward Expertise exp and reduce Sam’s current quest timer by 5 minutes."}}},
		{id="mechanic.stat_juices",name="Zumos de stats (barriles y exprimidor)",category="mechanic",verification="confirmed",internal={"Map.Barrels","Map.Other.Tent2.Model.JuicingBowl"},srcEvidence="Auto Stats",evidence={level="confirmed"},relations={{"rewards","item.stat_juice","evidence"}}},
		{id="npc.advanced_bartender_dance_club",name="Advanced Bartender (Dance Club)",category="npc",group="other",verification="documented",wiki=9,unknown={"internalName","location"},facts={{"reward","Gives Exp drinks for each stat that matches color."}}},
		{id="npc.bartender_sams",name="Bartender (Sam's)",category="npc",group="other",verification="unknown",wiki=9,unknown={"description","internalName","location"}},
		{id="npc.beachcomber_lou",name="Beachcomber Lou",category="npc",group="quest_givers",verification="confirmed",roles={"quest_giver"},internal={"Map.Merchants.QuestCrabIsle"},wiki=9,evidence={level="confirmed"},unknown={"location","quests"}},
		{id="npc.boatmaster",name="Boatmaster",category="npc",group="other",verification="documented",roles={"merchant"},wiki=9,unknown={"internalName","location"}},
		{id="npc.calm_bob",name="Calm Bob",category="npc",group="quest_givers",verification="confirmed",roles={"quest_giver"},internal={"Map.Merchants.QuestTreea"},wiki=9,evidence={level="confirmed"},unknown={"location","quests"}},
		{id="npc.candy_witch_hazel",name="Candy Witch Hazel",category="npc",group="halloween",verification="unknown",wiki=9,relations={{"in_region","region.halloween","wiki-group"}},unknown={"description","internalName"}},
		{id="npc.captain_bram",name="Captain Bram",aliases={"Guard Captain Bram"},category="npc",group="quest_givers",verification="confirmed",roles={"quest_giver"},internal={"Map.Merchants.QuestTown"},wiki=9,evidence={level="confirmed"},unknown={"location","quests"}},
		{id="npc.chef",name="Chef",category="npc",verification="documented",wiki=0,card="Fishing",unknown={"internalName","location","name"},facts={{"requirement","Fish can be cooked at campfires or the fryer next to the chef."}}},
		{id="npc.climber_edda",name="Climber Edda",category="npc",group="quest_givers",verification="confirmed",roles={"quest_giver"},internal={"Map.Merchants.QuestCliffs"},wiki=9,evidence={level="confirmed"},unknown={"location","quests"}},
		{id="npc.dancer",name="Dancer",category="npc",group="other",verification="unknown",wiki=9,unknown={"description","internalName","location"}},
		{id="npc.death_spire_mage",name="Mago de Death Spire (sin nombre)",category="npc",verification="documented",wiki=0,card="Death Spire",relations={{"located_at","island.death_spire","wiki"}},unknown={"internalName","name"},facts={{"spawn","There’s an old mage that rests somewhere on the lower circle, maybe he can tell you more?"}}},
		{id="npc.dockmaster_rolf",name="Dockmaster Rolf",category="npc",group="quest_givers",verification="confirmed",roles={"quest_giver"},internal={"Map.Merchants.QuestWindmill"},wiki=9,evidence={level="confirmed"},unknown={"location","quests"}},
		{id="npc.elder_moray",name="Elder Moray",category="npc",group="quest_givers",verification="confirmed",roles={"quest_giver"},internal={"Map.Merchants.QuestDeepwake"},wiki=9,evidence={level="confirmed"},unknown={"location","quests"}},
		{id="npc.fish_merchant",name="Fish Merchant",category="npc",group="other",verification="confirmed",roles={"merchant"},internal={"Map.Merchants.FishMerchant"},wiki=9,evidence={level="confirmed",note="venta sin grabar"},relations={{"located_at","location.fisher_plaza","wiki"}},contradictions={"La wiki lo sitúa en 'Fisher Plaza', que no aparece entre las islas (Points of Interest)."}},
		{id="npc.fortune_teller",name="Fortune Teller",category="npc",group="other",verification="unknown",wiki=9,unknown={"description","internalName","location"}},
		{id="npc.gravekeeper_mort",name="Gravekeeper Mort",category="npc",group="halloween",verification="unknown",wiki=9,relations={{"in_region","region.halloween","wiki-group"}},unknown={"description","internalName"}},
		{id="npc.hal_the_deserter",name="Hal the Deserter",category="npc",group="quest_givers",verification="confirmed",roles={"quest_giver"},internal={"Map.Merchants.QuestMarine"},wiki=9,evidence={level="confirmed"},unknown={"location","quests"}},
		{id="npc.hermit_oswin",name="Hermit Oswin",category="npc",group="quest_givers",verification="confirmed",roles={"quest_giver"},internal={"Map.Merchants.QuestPursuer"},wiki=9,evidence={level="confirmed"},unknown={"location","quests"}},
		{id="npc.krusch",name="Krusch",category="npc",group="other",verification="unknown",wiki=9,relations={{"located_at","island.caver_island","wiki"}},unknown={"description","internalName"}},
		{id="npc.little_boo",name="Little Boo",category="npc",group="halloween",verification="possibly_obsolete",wiki=9,relations={{"in_region","region.halloween","wiki-group"}},unknown={"internalName"}},
		{id="npc.lucy_affinity_diviner",name="Lucy, Affinity Diviner",aliases={"Lucy"},category="npc",group="other",verification="unknown",wiki=9,relations={{"related","info.stats_and_affinity","wiki"}},unknown={"description","internalName","location"}},
		{id="npc.mama_fredda",name="Mama Fredda",category="npc",group="quest_givers",verification="confirmed",roles={"quest_giver"},internal={"Map.Merchants.QuestSandCastle"},wiki=9,evidence={level="confirmed"},unknown={"location","quests"}},
		{id="npc.merlin",name="Merlin",category="npc",group="other",verification="confirmed",roles={"quest_giver","merchant"},internal={"Map.Merchants.QuestFishMerchant"},wiki=9,evidence={level="confirmed",note="MerlinService TakePackage/Deliver grabados"},relations={{"located_at","island.merlins_island","wiki"},{"gives_quest","objective.deliver_package","evidence"},{"gives_quest","objective.fish_count","evidence"},{"sells","item.wood_rod","wiki"},{"sells","item.super_rod","wiki"},{"sells","item.blessed_rod","wiki"}}},
		{id="npc.mirra_the_runaway",name="Mirra the Runaway",category="npc",verification="archived",wiki=9,unknown={"internalName","location"}},
		{id="npc.old_fishman",name="Old Fishman",category="npc",group="other",verification="unknown",wiki=9,unknown={"description","internalName","location"}},
		{id="npc.old_miner_gus",name="Old Miner Gus",category="npc",group="quest_givers",verification="confirmed",roles={"quest_giver"},internal={"Map.Merchants.QuestMountain"},wiki=9,evidence={level="confirmed"},unknown={"location","quests"}},
		{id="npc.old_pirate_gil",name="Old Pirate Gil",category="npc",group="quest_givers",verification="confirmed",roles={"quest_giver"},internal={"Map.Merchants.QuestPirate"},wiki=9,evidence={level="confirmed"},unknown={"location","quests"}},
		{id="npc.old_vasska",name="Old Vasska",category="npc",verification="archived",wiki=9,unknown={"internalName","location"}},
		{id="npc.otto",name="Otto",aliases={"Farmer Otto"},category="npc",group="quest_givers",verification="confirmed",roles={"quest_giver"},internal={"Map.Merchants.QuestFarm"},wiki=9,evidence={level="confirmed",note="misión FarmBoars entregada"},relations={{"gives_quest","objective.kill_enemies","evidence"}},unknown={"location"}},
		{id="npc.sam",name="Sam",aliases={"Quest Man"},category="npc",group="other",verification="confirmed",roles={"quest_giver"},internal={"Map.Merchants.QuestMerchant2"},wiki=9,evidence={level="confirmed",note="'Quest Man'; CompassQuestService.RF.Claim"},relations={{"located_at","island.sams_bar_and_pirates_land","evidence"},{"gives_quest","objective.claim_compass","evidence"},{"rewards","item.compass","evidence"}}},
		{id="npc.sam_dance_club",name="Sam (Dance Club)",category="npc",group="other",verification="unknown",wiki=9,unknown={"description","internalName","location"}},
		{id="npc.shanks",name="Shanks",category="npc",group="other",verification="confirmed",internal={"Map.Merchants.HakiRankMerchant"},wiki=9,evidence={level="confirmed"},unknown={"location"}},
		{id="npc.sheriff_dale",name="Sheriff Dale",category="npc",group="quest_givers",verification="confirmed",roles={"quest_giver"},internal={"Map.Merchants.QuestCaver"},wiki=9,evidence={level="confirmed"},unknown={"location","quests"}},
		{id="npc.silvers_rayleigh",name="Silvers Rayleigh",aliases={"Haki Master","Silver Rayleigh"},category="npc",group="other",verification="confirmed",internal={"Map.Merchants.QuestHakiMerchant"},wiki=9,evidence={level="confirmed",note="HakiDojoService grabado"},relations={{"located_at","island.mountain_island","wiki"}}},
		{id="npc.smith_hagan",name="Smith Hagan",category="npc",group="other",verification="documented",roles={"crafter"},wiki=9,unknown={"internalName","location"}},
		{id="npc.sniper_dealer",name="Sniper Dealer",category="npc",group="other",verification="inferred",roles={"merchant"},internal={"Map.Merchants.SniperMerchant"},wiki=9,evidence={level="inferred",note="correspondencia por nombre"},unknown={"location"}},
		{id="npc.suspicious_man",name="Suspicious Man",category="npc",group="other",verification="inferred",roles={"merchant"},internal={"Map.Merchants.SellerMerchant"},wiki=9,evidence={level="inferred",note="SellerMerchant compra frutas junto a Sam (FruitTradeService grabado); que sea Suspicious Man es deducción"},relations={{"sells","item.golden_compass","wiki"},{"rewards","item.df_coin","wiki"}},unknown={"location"},facts={{"reward","Talk to him to exchange your devil fruits into Rewards"},{"cost","Rare Fruits: 1M Beri/ 50 Gems/ 1 DFCoin"},{"cost","Ultra Rare Box: 15M Beri/ 500 Gems/ 10 DFCoins"}}},
		{id="npc.sword_dealer",name="Sword Dealer",category="npc",group="other",verification="inferred",roles={"merchant"},internal={"Map.Merchants.SwordMerchant"},wiki=9,evidence={level="inferred",note="correspondencia por nombre"},unknown={"location"}},
		{id="npc.the_expert",name="The Expert",category="npc",group="other",verification="confirmed",roles={"quest_giver"},internal={"Map.Merchants.ExpertiseMerchant"},wiki=9,evidence={level="confirmed",note="misiones en PlayerGui.MissionGui"},relations={{"mentions","enemy.gunslinger","name"},{"mentions","enemy.vokun","name"},{"mentions","enemy.marines","name"},{"mentions","enemy.gunslinger_elites","name"},{"gives_quest","objective.kill_enemies","wiki"},{"gives_quest","objective.kill_players","wiki"},{"gives_quest","objective.deal_damage","wiki"},{"gives_quest","objective.earn_beri","wiki"},{"gives_quest","objective.sell_fish_value","wiki"},{"gives_quest","objective.fish_count","wiki"},{"gives_quest","objective.mission_objectives","wiki"},{"gives_quest","objective.elite_kill","wiki"}},unknown={"location"},facts={{"reward","Talking with The Expert gives you an expertise quest so you can gain exp for your Expertise(s)."},{"spawn","He offers a quest every xx:00 UTC."},{"reward","Expertise quests reward Expertise exp and reduce Sam’s current quest timer by 5 minutes."},{"requirement","Elite quests require killing tougher enemies and grant more exp."}}},
		{id="npc.the_marine_warden",name="The Marine Warden",category="npc",group="other",verification="documented",wiki=9,unknown={"internalName","location"}},
		{id="npc.timmy",name="Timmy",category="npc",group="other",verification="unknown",wiki=9,unknown={"description","internalName","location"}},
		{id="npc.trait_sage",name="Trait Sage",category="npc",group="other",verification="confirmed",roles={"service"},internal={"Map.Merchants.TraitSage"},wiki=9,evidence={level="confirmed"},relations={{"links_to","system.character_traits","wiki-link"},{"requires","item.essence","wiki"}},unknown={"location"}},
		{id="objective.board_quest",name="Misión de tablón (Quest Givers): tipos sin documentar",category="objective",verification="unknown",wiki=0,card="Quest Givers",unknown={"description","givers","objectiveTypes","rewards"},facts={{"reward","At the bottom, you can select where the Exp of each completed quest goes to"}}},
		{id="objective.bring_item",name="Llevar un objeto a un NPC",category="objective",verification="documented",wiki=0,card="Fishing",relations={{"requires","item.merlins_logbook","wiki"}},unknown={"givers","rewards"},facts={{"requirement","bring Merlin his logbook (a rare drop of his)"}}},
		{id="objective.claim_compass",name="Reclamar el tesoro del compass",category="objective",verification="confirmed",srcEvidence="Auto Sam",unknown={"rewards"}},
		{id="objective.deal_damage",name="Hacer X de daño",category="objective",verification="documented",wiki=0,card="The Expert",unknown={"rewards"},facts={{"requirement","Deal a certain amount of damage."}}},
		{id="objective.defeat_boss_times",name="Derrotar a un jefe N veces",category="objective",verification="documented",wiki=0,card="Fishing",relations={{"targets","enemy.captain_blacksurf","wiki"}},unknown={"givers","rewards"},facts={{"requirement","beat Captain Blacksurf five times"}}},
		{id="objective.deliver_package",name="Entregar un paquete",category="objective",verification="confirmed",internal={"Tool Package @DeliveryTarget","MerlinService.RF.Deliver"},wiki=0,card="Merlin's Island",evidence={level="confirmed"},unknown={"rewards"},facts={{"requirement","You’d come here to gather packages and chat while waiting for that old Fisherman over there to prepare another delivery for you."}}},
		{id="objective.difficult_catches",name="Pescar N capturas Hard o Impossible",category="objective",verification="documented",wiki=0,card="Fishing",unknown={"givers","rewards"},facts={{"requirement","land 25 Hard or Impossible catches with it"}}},
		{id="objective.earn_beri",name="Ganar X Beri",category="objective",verification="documented",wiki=0,card="The Expert",unknown={"rewards"},facts={{"requirement","Earn a certain amount of beris."}}},
		{id="objective.elite_kill",name="Élite: derrotar a un enemigo élite",category="objective",verification="documented",wiki=0,card="The Expert",relations={{"targets","enemy.vokun","wiki"},{"targets","enemy.marines","wiki"},{"targets","enemy.gunslinger_elites","wiki"}},facts={{"reward","Elite quests require killing tougher enemies and grant more exp."}}},
		{id="objective.fish_count",name="Pescar N peces",category="objective",verification="confirmed",internal={"MissionGui '[Hard] Catch 7 fish.'"},wiki=0,card="The Expert",evidence={level="confirmed"},unknown={"rewards"},facts={{"requirement","Fish a certain amount."}}},
		{id="objective.kill_enemies",name="Derrotar N enemigos concretos",category="objective",verification="confirmed",internal={"QuestTracker 'Defeat <enemigo> (Lv N+): a/b'"},wiki=0,card="The Expert",evidence={level="confirmed"},unknown={"rewards"},facts={{"requirement","Kill a set number of certain enemies."}}},
		{id="objective.kill_players",name="Derrotar N jugadores",category="objective",verification="documented",roles={"pvp"},wiki=0,card="The Expert",unknown={"rewards"},facts={{"requirement","Kill a set number of players."}}},
		{id="objective.light_candles",name="Encender velas (invocación)",category="objective",verification="possibly_obsolete",wiki=0,card="Perona, Ghost Princess",unknown={"givers","rewards"},facts={{"spawn","If you light four candles near her house, she spawns in the center to haunt."}}},
		{id="objective.mission_objectives",name="Completar N objetivos de misión (compasses de Sam, paquetes de Merlin)",category="objective",verification="documented",wiki=0,card="The Expert",relations={{"requires","mechanic.sam_compass","wiki"},{"requires","objective.deliver_package","wiki"}},unknown={"rewards"},facts={{"requirement","Complete a certain number of mission objectives (Sam - compasses and Merlin packages)."}}},
		{id="objective.offer_fruits",name="Ofrecer frutas del diablo (invocación)",category="objective",verification="documented",wiki=0,card="Death Spire",unknown={"givers","rewards"},facts={{"requirement","bring 13 devil fruits for the lower circle, and 3 for what’s at the top"}}},
		{id="objective.open_caches",name="Abrir N caches de un tipo",category="objective",verification="documented",wiki=0,card="Fishing",relations={{"requires","item.fishing_cache","wiki"}},unknown={"givers","rewards"},facts={{"requirement","open 15 Emerald Caches"}}},
		{id="objective.sell_fish_value",name="Vender peces por X Beri",category="objective",verification="documented",wiki=0,card="The Expert",unknown={"rewards"},facts={{"requirement","Sell fish worth a certain amount of beri."}}},
		{id="objective.sell_to_chef",name="Vender N peces al Chef",category="objective",verification="documented",wiki=0,card="Fishing",relations={{"targets","npc.chef","wiki"}},unknown={"givers","rewards"},facts={{"requirement","sell 500 to the Chef"}}},
		{id="region.halloween",name="Halloween (temporada)",category="region",verification="possibly_obsolete",wiki=0,card="Halloween Island",unknown={"returnDate"},facts={{"duration","explore this island before it vanishes sometimes late Fall"}}},
		{id="system.bounties",name="Bounties",category="system",verification="documented",wiki=10,facts={{"spawn","Players who are strong enough to be noted will appear here."},{"reward","Rewards vary on the player’s: Level, Haki, Bounty, and Kills"}}},
		{id="system.challenges",name="Challenges",category="system",verification="documented",wiki=10},
		{id="system.character_traits",name="Character Traits",category="system",verification="documented",wiki=10,facts={{"cost","- Jeweler — +10–70% Gems Earned (3%)"}}},
		{id="system.fishing",name="Fishing",category="system",verification="confirmed",internal={"FishingService Cast/Reel/Hit","PlayerGui.Fishing"},wiki=10,evidence={level="confirmed",note="minijuego Scatter grabado"},relations={{"mentions","island.galley_isle","name"},{"mentions","npc.fish_merchant","name"},{"mentions","enemy.captain_blacksurf","name"},{"mentions","enemy.abyss_crustacean","name"},{"rewards","item.fish","wiki"},{"rewards","item.fishing_cache","wiki"}},facts={{"cost","Small: 1,000 beri (5,000 cooked)"},{"cost","Medium: 5,000 beri (25,000 cooked)"},{"cost","Large: 10,000 beri (50,000 cooked)"},{"cost","Huge: 25,000 beri (125,000 cooked)"},{"requirement","Obtainment: Do a quest for Merlin, and he’ll give you this rod."},{"duration","Catch Rate: ~25 seconds per fish."},{"requirement","Obtainment: Keep fishing until you reach 200 Fish caught."},{"duration","Catch Rate: ~15 seconds per fish."},{"requirement","Obtainment: Owning the Sturdy Rod and 1 million Beri, then talking to Merlin will allow you to get the Super Rod."},{"duration","Catch Rate: ~10 seconds per fish."},{"requirement","Obtainment: Catch 2,000 fish, sell 500 to the Chef, open 15 Emerald Caches, beat Captain Blacksurf five times and bring Merlin his logbook (a rare drop of his)."},{"duration","Catch Rate: ~6.5 seconds per fish."}}},
		{id="system.gladiator_board",name="Gladiator Board",category="system",verification="documented",wiki=10},
		{id="weapon.aqua_staff",name="Aqua Staff",category="weapon",group="sword",verification="documented",wiki=11,unknown={"internalName"},facts={{"requirement","Fish for a chance to obtain this magical wand of potent water energy."}},abilities={{"Obtainment","move",nil},{"Special","move",nil}}},
		{id="weapon.bisento",name="Bisento",category="weapon",group="sword",verification="documented",wiki=11,unknown={"internalName"},abilities={{"Special","move",nil}}},
		{id="weapon.blunderbuss",name="Blunderbuss",category="weapon",group="sniper",verification="documented",wiki=11,unknown={"abilities","internalName"}},
		{id="weapon.candy_cane_kogatana",name="Candy Cane Kogatana",category="weapon",verification="archived",wiki=11,unknown={"internalName"}},
		{id="weapon.crossbow",name="Crossbow",category="weapon",group="sniper",verification="documented",wiki=11,unknown={"abilities","internalName"}},
		{id="weapon.dagger",name="Dagger",category="weapon",group="sword",verification="documented",wiki=11,unknown={"internalName"},abilities={{"Special","move",nil}}},
		{id="weapon.divine_axe",name="Divine Axe",category="weapon",group="sword",verification="documented",wiki=11,unknown={"internalName"},abilities={{"Special","move",nil}}},
		{id="weapon.flail",name="Flail",category="weapon",group="sword",verification="documented",wiki=11,unknown={"internalName"},abilities={{"Special","move",nil}}},
		{id="weapon.flintlock",name="Flintlock",category="weapon",group="sniper",verification="documented",wiki=11,unknown={"abilities","internalName"}},
		{id="weapon.golden_fish",name="Golden Fish",category="weapon",group="sword",verification="documented",wiki=11,unknown={"internalName"},facts={{"requirement","Obtained from catching a total of 1,000k Fish."}},abilities={{"Obtainment","move",nil}}},
		{id="weapon.ice_dagger",name="Ice Dagger",category="weapon",group="sword",verification="documented",wiki=11,unknown={"internalName"},abilities={{"Special","move",nil}}},
		{id="weapon.ice_spear",name="Ice Spear",category="weapon",group="sword",verification="documented",wiki=11,unknown={"internalName"},facts={{"spawn","Summon a rain of spears at the player’s cursor, each landing with a small AOE and dealing 340 sword damage."}},abilities={{"Special","move",nil}}},
		{id="weapon.kanshou_and_bakuya",name="Kanshou & Bakuya",category="weapon",group="sword",verification="documented",wiki=11,unknown={"internalName"},facts={{"reward","Why give them to us?"}},abilities={{"Special","move",nil}}},
		{id="weapon.katana",name="Katana",category="weapon",group="sword",verification="documented",wiki=11,unknown={"internalName"},abilities={{"Special","move",nil}}},
		{id="weapon.kogatana",name="Kogatana",category="weapon",group="sword",verification="documented",wiki=11,unknown={"internalName"},abilities={{"Special","move",nil}}},
		{id="weapon.krizma",name="Krizma",category="weapon",group="sword",verification="documented",wiki=11,unknown={"internalName"},facts={{"requirement","The creator of this sword must've known what he was going for with this serrated blade."}},abilities={{"Special","move",nil}}},
		{id="weapon.lightning_sword",name="Lightning Sword",category="weapon",group="sword",verification="documented",wiki=11,unknown={"internalName"},facts={{"spawn","Enhancing your every output of damage by 1.25x for 10 seconds."}},abilities={{"Special","move",nil}}},
		{id="weapon.lollipop",name="Lollipop",category="weapon",group="sword",verification="documented",wiki=11,unknown={"internalName"},abilities={{"Special","move",nil}}},
		{id="weapon.magma_gun",name="Magma Gun",category="weapon",group="sniper",verification="documented",wiki=11,unknown={"internalName"},facts={{"reward","M1: Shoots a small magma bullet in a straight line without drop."}},abilities={{"Special","move",nil}}},
		{id="weapon.masamune",name="Masamune",category="weapon",group="sword",verification="documented",wiki=11,unknown={"internalName"},abilities={{"Special","move",nil}}},
		{id="weapon.melee",name="Melee",category="weapon",group="utility",verification="documented",wiki=11,unknown={"abilities","internalName"}},
		{id="weapon.meteorite_sword",name="Meteorite Sword",category="weapon",group="sword",verification="documented",wiki=11,unknown={"internalName"},facts={{"duration","Creates a protective shield over the user that negates damage for 3 seconds, providing 6.5k worth of overguard."}},abilities={{"Special","move",nil}}},
		{id="weapon.old_miner_gus",name="Old Miner Gus",category="weapon",verification="archived",wiki=11,unknown={"internalName"}},
		{id="weapon.roger",name="Roger",category="weapon",group="sword",verification="documented",wiki=11,unknown={"internalName"},abilities={{"Special","move",nil}}},
		{id="weapon.ruby_anchor",name="Ruby Anchor",category="weapon",group="sword",verification="documented",wiki=11,relations={{"mentions","system.fishing","name"}},unknown={"internalName"},facts={{"requirement","Obtained through lots of fishing."}},abilities={{"Obtainment","move",nil},{"Special","move",nil}}},
		{id="weapon.rusted_cutlass",name="Rusted Cutlass",category="weapon",group="sword",verification="documented",wiki=11,unknown={"internalName"},abilities={{"Special","move",nil}}},
		{id="weapon.scissors_blade",name="Scissors Blade",category="weapon",group="sword",verification="documented",wiki=11,unknown={"internalName"},abilities={{"Special","move",nil}}},
		{id="weapon.slingshot",name="Slingshot",category="weapon",group="sniper",verification="documented",wiki=11,unknown={"abilities","internalName"}},
		{id="weapon.special",name="Special",category="weapon",group="sniper",verification="documented",wiki=11,unknown={"abilities","internalName"}},
		{id="weapon.stars",name="Stars",category="weapon",group="sniper",verification="documented",wiki=11,unknown={"abilities","internalName"}},
		{id="weapon.swords__archived",name="Swords",category="weapon",verification="archived",wiki=11,unknown={"internalName"}},
		{id="weapon.tachi",name="Tachi",category="weapon",group="sword",verification="documented",wiki=11,unknown={"internalName"},abilities={{"Special","move",nil}}},
		{id="weapon.ultra_great_sword",name="Ultra Great Sword",category="weapon",group="sword",verification="documented",wiki=11,unknown={"internalName"},abilities={{"Special","move",nil}}},
		{id="weapon.wakizashi",name="Wakizashi",category="weapon",group="sword",verification="documented",wiki=11,unknown={"internalName"},abilities={{"Special","move",nil}}},
		{id="weapon.yoru",name="Yoru",category="weapon",group="sword",verification="documented",wiki=11,unknown={"internalName"},abilities={{"Special","move",nil}}},
	},
}
end
__modules["Profiles"] = function(...)
-- Profiles: reglas de los perfiles de la librería (ElHoyoHub/configs/*.json = { name, created, modified, values,
-- profileVersion }). values[ruta "Pestaña/Caja/Nombre"] = valor del control. Sin Roblox ni archivos: la librería
-- guarda y aplica; aquí se valida, se compara, se limpia de secretos y se decide si una aplicación es segura.
-- Aplicar un perfil es atómico: o se aplica entero o no se toca nada (Profiles.apply con vuelta atrás).
local Profiles = {}

Profiles.VERSION = 1 -- formato de archivo de perfil (1.4.1). Los de antes no llevan profileVersion: valen como 0.
Profiles.MAX_VALUES = 2000
Profiles.MAX_TEXT = 200000

-- Ids que cambiaron de sitio (1.5.0): ruta vieja -> ruta nueva. Se aplican al leer un perfil (migración explícita).
Profiles.ALIASES = {}

-- Copia de values con las rutas viejas cambiadas por las nuevas (si la nueva ya tiene valor, gana la nueva)
function Profiles.migrateIds(values, aliases)
	aliases = aliases or Profiles.ALIASES
	local out, moved = {}, 0
	for id, v in values do
		local new = aliases[id]
		if new then moved += 1 else out[id] = v end
	end
	for id, v in values do
		local new = aliases[id]
		if new and out[new] == nil then out[new] = v end
	end
	return out, moved
end

local WEBHOOK = "discord[%w%.%-]*%.com/api/webhooks/"

-- ¿Es un secreto? Rutas de controles secretos (el webhook) o cualquier texto con una URL de webhook.
function Profiles.isSecret(id, value)
	if type(id) == "string" and (id:sub(-8) == "/Webhook" or id:lower():find("webhook", 1, true)) then return true end
	if type(value) == "string" and value:find(WEBHOOK) then return true end
	return false
end

-- Valores que puede tener un control: booleano, número, texto, o lista/mapa plano de esos (Multi, colores)
local function plainValue(v, depth)
	local t = type(v)
	if t == "boolean" or t == "string" then return true end
	if t == "number" then return v == v and v ~= math.huge and v ~= -math.huge end
	if t == "table" and (depth or 0) < 2 then
		local n = 0
		for k, x in v do
			n += 1
			if n > 200 or (type(k) ~= "string" and type(k) ~= "number") or not plainValue(x, (depth or 0) + 1) then return false end
		end
		return true
	end
	return false
end

-- Comprueba un perfil (la tabla del archivo, o solo sus values). known[id] = valor actual del control (para el tipo).
-- Devuelve ok, problemas (lista de textos), avisos, values limpios (sin secretos ni entradas rotas).
function Profiles.validate(data, known)
	local problems, warnings, clean = {}, {}, {}
	if type(data) ~= "table" then return false, { "el perfil no es una tabla" }, warnings, clean end
	local values = data.values ~= nil and data.values or data
	if type(values) ~= "table" then return false, { "values no es una tabla" }, warnings, clean end
	values = Profiles.migrateIds(values)
	local version = tonumber(data.profileVersion) or 0
	if version > Profiles.VERSION then
		table.insert(problems, "perfil de una versión más nueva (" .. version .. " > " .. Profiles.VERSION .. ")")
	end
	local n = 0
	for id, value in values do
		n += 1
		if type(id) ~= "string" or id == "" then
			table.insert(problems, "ruta no válida: " .. tostring(id))
		elseif Profiles.isSecret(id, value) then
			table.insert(warnings, "secreto quitado: " .. id)
		elseif not plainValue(value) then
			table.insert(problems, id .. ": valor no válido (" .. type(value) .. ")")
		elseif known and known[id] ~= nil and type(known[id]) ~= type(value) then
			table.insert(problems, id .. ": tipo " .. type(value) .. ", el control es " .. type(known[id]))
		else
			if known and known[id] == nil then table.insert(warnings, "control que no existe ahora (se guarda para luego): " .. id) end
			clean[id] = value
		end
	end
	if n > Profiles.MAX_VALUES then table.insert(problems, "demasiados valores (" .. n .. ")") end
	return #problems == 0, problems, warnings, clean
end

local function same(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in a do if not same(v, b[k]) then return false end end
	for k in b do if a[k] == nil then return false end end
	return true
end
Profiles.same = same

-- Vista previa: qué cambiaría al aplicar `values` sobre `current`. { changes = {{id, from, to}}, unchanged, unknown }
function Profiles.diff(current, values)
	local out = { changes = {}, unchanged = 0, unknown = {} }
	for id, to in values or {} do
		local from = current and current[id]
		if from == nil then
			table.insert(out.unknown, id)
		elseif same(from, to) then
			out.unchanged += 1
		else
			table.insert(out.changes, { id = id, from = from, to = to })
		end
	end
	table.sort(out.changes, function(a, b) return a.id < b.id end)
	table.sort(out.unknown)
	return out
end

-- ¿Hay cambios sin guardar? Compara lo guardado con lo actual (solo controles que existen en los dos)
function Profiles.dirty(saved, current)
	local n = 0
	for id, now in current or {} do
		local was = saved and saved[id]
		if was ~= nil and not same(was, now) then n += 1 end
	end
	return n > 0, n
end

-- Aplicación controlada. controls[id] = { get(), set(v) }. Valida TODO antes de tocar nada; si un set falla a
-- mitad, deja todos como estaban. Devuelve ok, problemas, avisos, cuántos aplicó.
function Profiles.apply(values, controls, pending)
	local known = {}
	for id, c in controls do
		local ok, v = pcall(c.get)
		if ok then known[id] = v end
	end
	local ok, problems, warnings, clean = Profiles.validate(values, known)
	if not ok then return false, problems, warnings, 0 end
	local before, done = {}, {}
	for id in clean do if controls[id] then before[id] = known[id] end end
	local applied = 0
	for id, value in clean do
		local c = controls[id]
		if c then
			local okSet, err = pcall(c.set, value)
			if not okSet then
				for _, back in done do pcall(controls[back].set, before[back]) end -- vuelta atrás
				return false, { id .. ": " .. tostring(err) }, warnings, 0
			end
			table.insert(done, id)
			applied += 1
		elseif pending then
			pending[id] = value -- control que se crea más tarde (lo recoge al nacer)
		end
	end
	return true, {}, warnings, applied
end

-- Exportación segura: sin secretos, con versión de formato y quién la hizo. Devuelve la tabla y lo quitado.
function Profiles.export(cfg, values, hubVersion)
	local out, removed = {}, {}
	for id, v in values or {} do
		if Profiles.isSecret(id, v) then table.insert(removed, id) else out[id] = v end
	end
	table.sort(removed)
	return { name = cfg and cfg.name or "Perfil", profileVersion = Profiles.VERSION, exportedBy = hubVersion, values = out }, removed
end

-- Importación: texto JSON -> perfil validado. Devuelve ok, perfil {name, values}, problemas, avisos.
function Profiles.import(text, json, known)
	if type(text) ~= "string" or text:match("^%s*$") then return false, nil, { "texto vacío" }, {} end
	if #text > Profiles.MAX_TEXT then return false, nil, { "demasiado largo (" .. #text .. " caracteres)" }, {} end
	local okDecode, data = pcall(json.decode, text)
	if not okDecode then return false, nil, { "no es JSON válido" }, {} end
	if type(data) ~= "table" or type(data.values) ~= "table" then return false, nil, { "falta la lista values (¿es un perfil del hub?)" }, {} end
	local ok, problems, warnings, clean = Profiles.validate(data, known)
	if not ok then return false, nil, problems, warnings end
	-- quita lo que rompe un nombre de archivo (control, < > : " / \ | ? *); los acentos se quedan
	local name = type(data.name) == "string" and data.name:gsub('[%c<>:"/\\|%?%*]', ""):sub(1, 40) or ""
	if name:match("^%s*$") then name = "Importado" end
	return true, { name = name, values = clean, profileVersion = Profiles.VERSION }, {}, warnings
end

-- Texto corto de un valor para la vista previa
function Profiles.show(v)
	if type(v) == "table" then
		local parts = {}
		for k, x in v do
			if x == true then table.insert(parts, tostring(k)) elseif x ~= false then table.insert(parts, tostring(k) .. "=" .. tostring(x)) end
		end
		table.sort(parts)
		return "{" .. table.concat(parts, ", ") .. "}"
	end
	return tostring(v)
end

return Profiles
end
__modules["Diagnostics"] = function(...)
-- Diagnostics: informe del estado del hub para copiar y pegar al pedir ayuda. Sin Roblox: el hub le pasa una
-- tabla con los datos ya leídos (Diagnostics.format) y aquí solo se da formato y se quitan secretos.
-- Nunca sale: la URL del webhook, tu nombre o DisplayName, tu UserId, el JobId del servidor ni rutas locales.
local Diagnostics = {}

local WEBHOOK_ANY = "https://[%w%.%-]*discord[%w%.%-]*%.com/api/webhooks/[%w/_%-]+"

local function escapePattern(s)
	return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

-- secrets = lista de textos que no pueden salir (nombre, UserId, JobId...). Se cambian por "[oculto]".
function Diagnostics.redact(text, secrets)
	text = tostring(text):gsub(WEBHOOK_ANY, "[webhook oculto]")
	for _, s in secrets or {} do
		s = tostring(s)
		if #s >= 3 then
			-- sin distinguir mayúsculas (los nombres de Roblox se escriben de varias formas)
			local pattern = escapePattern(s):gsub("%a", function(c) return "[" .. c:lower() .. c:upper() .. "]" end)
			text = text:gsub(pattern, "[oculto]")
		end
	end
	return text
end

local function line(out, k, v) table.insert(out, string.format("%-22s %s", k .. ":", tostring(v))) end

-- r = { hubVersion, build, uiVersion, uiMin, stage, uptime, fps, memoryMb, luaKb, executor, deps = {nombre=bool},
--       config = {file, version, target, ignored = {}, webhook = bool, migrations = {números}}, life = {cleanups,
--       finals, connections, connected, threads, errors, errorTotal, closeErrors, initTime}, features = {nombres},
--       components = {{name, status} | {name, kind, state, reason, lastError, errors, uptime, deps, available,
--       unavailableWhy, resources}} (Components:snapshot), componentCounts = {[estado] = n},
--       catalog = {entities, version, schema, wiki, contradictory, invalid}, errors = {{message, count, ago}} }
local function componentStatus(c)
	if c.status then return tostring(c.status) end -- formato de 1.3.2
	local parts = { tostring(c.state) .. (c.reason and (" (" .. tostring(c.reason) .. ")") or "") }
	if c.desiredState and c.matches == false then table.insert(parts, "PEDIDO " .. tostring(c.desiredState)) end
	if (c.tasks or 0) > 0 then table.insert(parts, c.tasks .. " tareas") end
	if c.lastTransition then
		table.insert(parts, "última transición " .. tostring(c.lastTransition.from) .. "→" .. tostring(c.lastTransition.to))
	end
	if (c.uptime or 0) >= 1 then table.insert(parts, "activo " .. math.floor(c.uptime) .. " s") end
	if c.deps and #c.deps > 0 then table.insert(parts, "necesita " .. table.concat(c.deps, ", ") .. (c.available == false and (" [" .. tostring(c.unavailableWhy) .. "]") or "")) end
	if (c.resources or 0) > 0 then table.insert(parts, c.resources .. " recursos") end
	if c.lastError then
		table.insert(parts, "último error x" .. tostring(c.errors or 1) .. (c.lastErrorKind and (" [" .. c.lastErrorKind .. "]") or "")
			.. ": " .. tostring(c.lastError))
	end
	return table.concat(parts, " · ")
end
function Diagnostics.format(r, secrets)
	local out = { "El Hoyo Hub — diagnóstico" }
	line(out, "Hub", tostring(r.hubVersion) .. (r.build and (" (build " .. r.build .. ")") or ""))
	line(out, "UI", tostring(r.uiVersion) .. " (mínimo " .. tostring(r.uiMin) .. ", " .. ((tonumber(r.uiVersion) or 1) >= (r.uiMin or 1) and "compatible" or "INCOMPATIBLE") .. ")")
	line(out, "Estado", r.stage)
	line(out, "Abierto", r.uptime and (math.floor(r.uptime) .. " s") or "?")
	if r.life and r.life.initTime then line(out, "Carga", string.format("%.2f s", r.life.initTime)) end
	line(out, "FPS", r.fps or "?")
	line(out, "Memoria", (r.memoryMb and (math.floor(r.memoryMb) .. " MB total") or "?") .. (r.luaKb and (", Lua " .. math.floor(r.luaKb) .. " KB") or ""))
	line(out, "Executor", r.executor or "?")
	if r.deps then
		local have, missing = {}, {}
		for name, ok in r.deps do table.insert(ok and have or missing, name) end
		table.sort(have)
		table.sort(missing)
		line(out, "Funciones disponibles", #have > 0 and table.concat(have, ", ") or "-")
		line(out, "Funciones que faltan", #missing > 0 and table.concat(missing, ", ") or "-")
	end
	if r.config then
		local c = r.config
		line(out, "Config", string.format("archivo %s, versión %s/%s, webhook %s", tostring(c.file), tostring(c.version),
			tostring(c.target), c.webhook and "configurado" or "no"))
		if c.ignored and #c.ignored > 0 then line(out, "Ajustes ignorados", table.concat(c.ignored, ", ")) end
		if c.migrations then
			local applied = {}
			for _, v in c.migrations do table.insert(applied, tostring(v)) end
			line(out, "Migraciones", #applied > 0 and ("aplicadas ahora: " .. table.concat(applied, ", ")) or
				(tostring(c.version) == tostring(c.target) and "al día" or "pendientes"))
		end
	end
	if r.life then
		local l = r.life
		line(out, "Recursos", string.format("%d registrados (+%d al final del cierre), %d conexiones (%d vivas), %d hilos en curso",
			l.cleanups or 0, l.finals or 0, l.connections or 0, l.connected or 0, l.threads or 0))
		if (l.closeErrors or 0) > 0 then line(out, "Fallos al cerrar", l.closeErrors) end
	end
	if r.catalog then
		local cat = r.catalog
		line(out, "Catálogo", string.format("%d entidades, versión %s, esquema %s, wiki %s", cat.entities or 0, tostring(cat.version),
			tostring(cat.schema or "?"), tostring(cat.wiki or "?")))
		if cat.contradictory or cat.invalid then
			line(out, "  calidad", string.format("%d con contradicciones, %d referencias rotas", cat.contradictory or 0, cat.invalid or 0))
		end
	end
	if r.componentCounts then
		local parts = {}
		for _, st in { "Initializing", "Ready", "Running", "Waiting", "Paused", "Stopping", "Error", "Unavailable", "Disabled" } do
			if r.componentCounts[st] then table.insert(parts, st .. " " .. r.componentCounts[st]) end
		end
		line(out, "Componentes", table.concat(parts, ", ") .. (r.mismatches and r.mismatches > 0 and (" · " .. r.mismatches .. " con estado distinto del pedido") or ""))
	end
	if r.profile then
		local p = r.profile
		line(out, "Perfil", string.format("%s (formato v%s), %s cambios sin guardar, %d perfiles", p.active and "activo" or "ninguno",
			tostring(p.format), tostring(p.unsaved or 0), p.count or 0))
	end
	if r.config and r.config.schema then
		local sc = r.config.schema
		line(out, "Ajustes", string.format("%d en el esquema, %d cambiados, %d desconocidos%s", sc.total or 0, sc.custom or 0, sc.unknown or 0,
			r.config.clamped and #r.config.clamped > 0 and (", recortados: " .. table.concat(r.config.clamped, ", ")) or ""))
	end
	if r.life and r.life.errorKinds and next(r.life.errorKinds) then
		local parts = {}
		for _, k in { "recoverable", "config", "critical" } do
			if r.life.errorKinds[k] then table.insert(parts, k .. " " .. r.life.errorKinds[k]) end
		end
		line(out, "Errores por tipo", table.concat(parts, ", "))
	end
	if r.tasksBySource and next(r.tasksBySource) then
		local parts = {}
		for source, n in r.tasksBySource do table.insert(parts, tostring(source) .. " " .. n) end
		table.sort(parts)
		line(out, "Tareas vivas", table.concat(parts, ", "))
	end
	if r.coordination then
		local c = r.coordination
		local held = {}
		for res, who in c.held or {} do table.insert(held, res .. "=" .. tostring(who)) end
		table.sort(held)
		local counts = c.counts or {}
		line(out, "Coordinación", string.format("%s · denegadas %d, solapes %d, liberaciones tardías %d, referencias viejas %d, devueltas %d",
			#held > 0 and table.concat(held, ", ") or "recursos libres", counts.denied or 0, counts.overlap or 0, counts.late_release or 0,
			(counts.stale or 0) + (counts.stale_use or 0), counts.restored or 0))
		local ev = c.events or {}
		for i = math.max(1, #ev - 4), #ev do
			local e = ev[i]
			table.insert(out, string.format("  %s %s: %s%s", tostring(e.kind), tostring(e.resource), tostring(e.owner), e.detail and (" / " .. tostring(e.detail)) or ""))
		end
	end
	if r.lastClose then
		local s = r.lastClose.components or {}
		line(out, "Cierre anterior", #s == 0 and "limpio (nada sobrevivió)" or ("sobrevivieron: " .. table.concat(s, ", ")))
	end
	line(out, "Funciones encendidas", r.features and #r.features > 0 and table.concat(r.features, ", ") or "-")
	for _, c in r.components or {} do line(out, "  " .. tostring(c.name), componentStatus(c)) end
	local errs = r.errors or {}
	line(out, "Errores", #errs == 0 and "ninguno" or (#errs .. " distintos"))
	for _, e in errs do
		table.insert(out, string.format("  x%d  hace %ds  %s%s", e.count or 1, math.floor(e.ago or 0),
			e.source and ("[" .. tostring(e.source) .. (e.kind and ("/" .. e.kind) or "") .. "] ") or "", tostring(e.message)))
	end
	return Diagnostics.redact(table.concat(out, "\n"), secrets)
end

return Diagnostics
end
__modules["NpcFarm"] = function(...)
-- NpcFarm: la lógica del apartado Bounty (NPCs) de 1.5.1, sin Roblox, para probarla con simulaciones.
-- SOLO NPCs controlados por el juego (Workspace.Alive.NPCs): un candidato que sea el personaje de un jugador, o esté
-- en la carpeta de jugadores, se descarta SIEMPRE (pickTarget). Las habilidades son TECLAS (las mismas Z X C V que
-- usa Auto Boss); qué hace cada una depende de tu arma o fruta: el hub no inventa nombres de habilidades.
local NpcFarm = {}

NpcFarm.KEYS = { "Z", "X", "C", "V" }
NpcFarm.INTERVALS = { 1, 2, 3, 5 } -- s entre una tanda de habilidades y la siguiente
NpcFarm.RADII = { 50, 100, 200, 400 } -- studs alrededor del punto de referencia
NpcFarm.LOW = { 20, 35, 50 } -- % de vida para retirarse a la zona segura
NpcFarm.RECOVER = { 70, 90, 100 } -- % de vida para volver
NpcFarm.OWNER = "Bounty" -- nombre del dueño de los recursos (move, hand)

local function dist(a, b)
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end
NpcFarm.dist = dist

-- ¿Puede ser objetivo? Nunca un jugador; nunca algo muerto o sin posición.
function NpcFarm.valid(c)
	if type(c) ~= "table" then return false, "no es un candidato" end
	if c.isPlayer or c.inPlayersFolder then return false, "es un jugador" end
	if not c.position then return false, "sin posición" end
	if not c.health or c.health <= 0 then return false, "muerto" end
	return true
end

-- El NPC válido más cercano al punto de referencia dentro del radio (nil si no hay)
function NpcFarm.pickTarget(candidates, ref, radius)
	local best, bestD = nil, math.huge
	for _, c in candidates or {} do
		if NpcFarm.valid(c) then
			local d = dist(c.position, ref)
			if d <= radius and d < bestD then best, bestD = c, d end
		end
	end
	return best, best and bestD or nil
end

-- Teclas elegidas (selected[i] = true para NpcFarm.KEYS[i]); nada elegido = ninguna
function NpcFarm.skills(selected)
	local out = {}
	for i, key in NpcFarm.KEYS do
		if type(selected) == "table" and selected[i] == true then table.insert(out, key) end
	end
	return out
end

-- Índice guardado -> valor de una lista (fuera de rango: el de serie, 2)
function NpcFarm.pick(list, index)
	return list[tonumber(index) or 2] or list[2] or list[1]
end

-- Un paso. state = { phase, character, lastSkill } (se modifica). input = { enabled, point, alive, character, pct,
-- low, recover, target, moveHolder, safeZone, now, interval }.
-- Devuelve { action, state, reason, useSkills } con action: "stop" | "wait" | "retreat" | "recover" | "return" | "fight"
-- y state (Components): Disabled | Waiting | Paused | Running.
function NpcFarm.step(state, input)
	local function out(action, compState, reason, extra)
		local r = { action = action, state = compState, reason = reason }
		for k, v in extra or {} do r[k] = v end
		return r
	end
	if not input.enabled then
		state.phase = "idle"
		return out("stop", "Disabled", "apagado")
	end
	if not input.point then return out("wait", "Waiting", "sin punto de referencia (guárdalo primero)") end
	if not input.alive then
		state.phase = "dead"
		return out("wait", "Waiting", "muerto: esperando reaparición")
	end
	if state.character ~= nil and input.character ~= state.character then
		state.character, state.phase = input.character, "idle" -- vuelve una sola vez
		return out("return", "Waiting", "reaparecido: volviendo al punto de referencia")
	end
	state.character = input.character
	local pct = input.pct or 1
	if state.phase == "recovering" then
		if pct * 100 >= input.recover then
			state.phase = "idle" -- vuelve una sola vez (antes repetía la vuelta en el paso siguiente)
			return out("return", "Waiting", string.format("recuperado (%d%%): volviendo al punto", math.floor(pct * 100 + 0.5)))
		end
		return out("recover", "Paused", string.format("recuperando en la zona segura: %d%% de %d%%", math.floor(pct * 100 + 0.5), input.recover))
	end
	if pct * 100 < input.low then
		if not input.safeZone then
			return out("wait", "Paused", "vida baja y la zona segura está apagada: actívala para retirarte")
		end
		state.phase = "recovering"
		return out("retreat", "Paused", string.format("vida baja (%d%%): a la zona segura", math.floor(pct * 100 + 0.5)))
	end
	if input.moveHolder and input.moveHolder ~= NpcFarm.OWNER then
		return out("wait", "Waiting", "otra función tiene el movimiento: " .. tostring(input.moveHolder))
	end
	if not input.target then
		state.phase = "idle"
		return out("wait", "Waiting", "ningún NPC cerca del punto", { stay = true }) -- se queda en el punto, con el turno
	end
	state.phase = "fighting"
	local useSkills = state.lastSkill == nil or input.now - state.lastSkill >= (input.interval or 2)
	if useSkills then state.lastSkill = input.now end
	return out("fight", "Running", "atacando a " .. tostring(input.target.name), { useSkills = useSkills })
end

return NpcFarm
end
__modules["Favorites"] = function(...)
-- Favorites: lista ordenada de favoritos por IDENTIFICADOR ESTABLE (la ruta "Pestaña/Caja/Nombre" en inglés que
-- usan los perfiles). Un favorito no es otra copia del control: es un acceso que lleva al control original, así no
-- hay dos controles con estados distintos. Sin Roblox; se guarda en config.favorites.
local Favorites = {}
Favorites.MAX = 20

-- Limpia una lista guardada: solo textos, sin repetidos, como mucho MAX; aplica alias de ids movidos (old -> new)
function Favorites.normalize(list, aliases)
	local out, seen = {}, {}
	for _, key in type(list) == "table" and list or {} do
		if type(key) == "string" and key ~= "" then
			key = aliases and aliases[key] or key
			if not seen[key] and #out < Favorites.MAX then
				seen[key] = true
				table.insert(out, key)
			end
		end
	end
	return out
end

function Favorites.has(list, key) return table.find(list, key) ~= nil end

-- Añade al final (o quita si ya está). Devuelve la lista y true si quedó añadido.
function Favorites.toggle(list, key)
	local i = table.find(list, key)
	if i then
		table.remove(list, i)
		return list, false
	end
	if #list >= Favorites.MAX then return list, false end
	table.insert(list, key)
	return list, true
end

-- Mueve un favorito dir posiciones (−1 arriba, +1 abajo). Devuelve si se movió.
function Favorites.move(list, key, dir)
	local i = table.find(list, key)
	if not i then return false end
	local j = math.clamp(i + dir, 1, #list)
	if j == i then return false end
	list[i], list[j] = list[j], list[i]
	return true
end

-- Separa los que apuntan a controles que existen de los que ya no (un control renombrado sin alias)
function Favorites.resolve(list, exists)
	local ok, missing = {}, {}
	for _, key in list do
		if exists(key) then table.insert(ok, key) else table.insert(missing, key) end
	end
	return ok, missing
end

return Favorites
end
local __loaded = {}
function import(name) -- declarada antes de los módulos (local import): un módulo puede importar otro
	local m = __loaded[name]
	if m == nil then
		local f = __modules[name]
		if not f then error("módulo no incluido en el build: " .. tostring(name)) end
		m = f()
		__loaded[name] = m
	end
	return m
end
local HUB_BUILD = "62ad6e91"
-- El Hoyo Hub
-- Versión: subir HUB_VERSION en cada cambio que se suba a GitHub (así se ve si el executor cargó el nuevo)
local HUB_VERSION = "1.5.4-rc1" -- Release Candidate: falta pasar las pruebas en el juego (TESTING.md)
local UI_MIN_VERSION = 5 -- ElHoyoUI.lua con Library.Version menor no vale (cambió algo que el hub necesita)
-- Todo el hub va dentro de una función protegida: si algo falla al cargar, en vez de no abrirse sin más,
-- sale una ventana con el error (y se copia al portapapeles) para poder arreglarlo.
local function ElHoyoHubMain()
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local VIM = game:GetService("VirtualInputManager")
local VirtualUser = game:GetService("VirtualUser")
local player = Players.LocalPlayer
local mouse = player:GetMouse()

-- Ciclo de vida (módulo Lifecycle). Si ya hay un hub abierto (se volvió a ejecutar el script), se cierra antes:
-- dos hubs harían todo doble. Se registra ya aquí, antes de esperar a nada: así un hub a medio cargar (o que
-- falló al cargar) también se puede cerrar, y si se vuelve a ejecutar mientras carga, este se para.
-- Hilos: life.spawn / life.delay / life.defer (como task.*, pero sus errores salen en la consola del hub).
local genv = getgenv and getgenv() or {}
local Lifecycle = import("Lifecycle")
local life = Lifecycle.new()
Lifecycle.claim(genv, "ElHoyoHubClose", life)
local cleanup = life.cleanup -- table.insert(cleanup, conexión) = se desconecta al cerrar
local closeHub = life.close
-- Estado central de los componentes (módulo Components): infraestructura, informativos y funciones. Al cerrar,
-- justo después de "Apagar todo", suelta sus recursos y los deja Disabled.
local comps = import("Components").new({
	-- error de una tarea propia de un componente (c:spawn): al registro general con su nombre (sin volver a marcarlo)
	onError = function(c, message, kind) life.errors:add(message, c.name, kind) end,
})
comps:register("Hub", { state = "Initializing", reason = "cargando" })
life.add(function()
	local _, survivors = comps:shutdown("cierre")
	genv.ElHoyoHubLastClose = { components = survivors } -- lo lee el Diagnóstico del siguiente hub
end)

local missingRemotes = {} -- se avisan en la consola cuando ya existe
local getRemote
do -- Services solo lo usa getRemote (menos locales en ElHoyoHubMain)
local Services = game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Packages"):WaitForChild("_Index")
	:WaitForChild("sleitnick_knit@1.7.0"):WaitForChild("knit"):WaitForChild("Services")
function getRemote(service, kind, name)
	-- Con límite de tiempo: si el juego renombra algo, esa función deja de ir pero el hub sí carga
	local svc = Services:WaitForChild(service, 5)
	local folder = svc and svc:WaitForChild(kind, 5)
	local remote = folder and folder:WaitForChild(name, 5)
	if not remote then table.insert(missingRemotes, service .. "." .. kind .. "." .. name) end
	return remote
end
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
-- Módulo Config: carga con tipos validados, copia .bak sin secretos si el archivo está roto, migraciones.
-- Si el executor no deja escribir archivos, los ajustes duran solo la sesión.
local HttpService = game:GetService("HttpService")
local Config = import("Config")
local CONFIG_FILE = "ElHoyoHub.json"
local PROFILE_DIRS = { "ElHoyoHub/configs", "ElHoyoHub/trash" } -- perfiles de la librería (para migraciones)
local diskFs = {
	read = function(p) return isfile and readfile and isfile(p) and readfile(p) or nil end,
	write = function(p, t) if writefile then writefile(p, t) end end,
	list = function(d) return listfiles and isfolder and isfolder(d) and listfiles(d) or {} end,
}
local json = {
	decode = function(t) return HttpService:JSONDecode(t) end,
	encode = function(v) return HttpService:JSONEncode(v) end,
}
-- Valores de serie: Config.SCHEMA (una sola lista con tipos, rangos y secretos). Aquí solo lo que depende de la sesión.
local config, bootNotes, configState = Config.load(diskFs, json, CONFIG_FILE, Config.defaults({ lang = genv.ElHoyoHubLang or "es" }))
comps:register("Config", { state = "Ready", reason = tostring(configState.file) })
local saveConfig
do
local saveQueued = false
function saveConfig()
	if not writefile or saveQueued then return end
	saveQueued = true
	life.delay(1, function() -- agrupa varios cambios seguidos en una sola escritura
		saveQueued = false
		local ok, text = pcall(json.encode, config)
		if ok then pcall(writefile, CONFIG_FILE, text) end
	end)
end
end

-- Lo conseguido en esta sesión (sale en Inicio)
local hubStats = { fps = 0 } -- lo rellena Inicio; lo lee Diagnóstico
local session = { compass = 0, chests = 0, fruits = 0, juices = 0, fish = 0, quests = 0, deliveries = 0 }

-- Avisos a Discord (módulo Webhook): solo URLs de webhook de Discord, sin menciones, ≤ 20 por minuto.
local hubLog -- = log(), cuando existe
local wh = { fruits = false, bosses = false, admins = false }
local sendWebhook, validWebhook
do
	local Webhook = import("Webhook")
	local requestFn = request or http_request or (syn and syn.request) or (http and http.request)
	comps:register("Webhook", { kind = "info", state = requestFn and "Ready" or "Unavailable",
		reason = not requestFn and "el executor no tiene request" or nil })
	validWebhook = Webhook.valid
	sendWebhook = Webhook.new({
		request = requestFn,
		json = json, clock = os.clock, spawn = life.spawn, T = T,
		getUrl = function() return config.webhook end,
		onFail = function(why) if hubLog then hubLog("Webhook: " .. why, "warn") end end,
	}).send
end

------------------------------------------------------------------ Interfaz: El Hoyo UI
-- La librería va DENTRO del ElHoyoHub.lua publicado (tools/build.js la incluye): hub y UI son siempre de la
-- misma versión. La comprobación de versión solo salta si alguien junta a mano archivos de versiones distintas.
local UI = import("ElHoyoUI")
assert(Lifecycle.compatible(UI.Version, UI_MIN_VERSION), "ElHoyoUI versión " .. tostring(UI.Version or 1)
	.. " y el hub necesita " .. UI_MIN_VERSION .. ": usa el ElHoyoHub.lua publicado (lleva la UI dentro).")
-- La interfaz y la GUI se destruyen al FINAL del cierre (life.addFinal): antes se apagan funciones y conexiones
life.addFinal(function() pcall(UI.Unload, UI) end)
comps:register("UI", { state = "Ready", reason = "v" .. tostring(UI.Version) })

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
life.addFinal(function() gui:Destroy() end)

local console = import("Console").new({ gui = gui, C = C, UIS = UIS, UI = UI, life = life, config = config, T = T, cleanup = cleanup })
local consoleWin, setConsole, log = console.frame, console.set, console.log
-- La consola con el contrato de Components: visible = Running, oculta = Ready (intención = lo que pidió el usuario)
do
	-- sin impl: la consola se muestra sola; el componente solo refleja intención y estado (sin bucles de aviso)
	local consoleComp = comps:register("Console", { kind = "info", state = "Ready" })
	console.onVisible = function(show)
		if show then consoleComp:start() else consoleComp:stop() end
	end
end
hubLog = log
-- Los hilos heredan el origen (life.spawn dentro de una función lleva su nombre): el error marca ESA función
life.onError = function(message, source, kind)
	log(T("Error interno: ", "Internal error: ") .. (source and ("[" .. tostring(source) .. "] ") or "") .. message, "error")
	local c = source and comps:get(source)
	if c then c:fail(message, kind) end
end

------------------------------------------------------------------ Ventana y pestañas
local win = UI:CreateWindow({ Folder = "ElHoyoHub", ToggleKey = false, SubBrand = "HUB v" .. HUB_VERSION }) -- versión bajo el logo
local main = win.frame
local function syncLang()
	LANG = UI.Language == 1 and "es" or "en"
	console.setTitle(T("Consola", "Console"))
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
		-- 1.5.4: sin scroll propio (la caja crece) y, si la sección no fija columna, "auto" = la columna más baja
		box = page.tab:Box({ Name = uiText(label), Column = column or "auto", Scrollable = false })
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

-- text puede ser una función (texto vivo) y lines un alto fijo en líneas (ElHoyoUI v3)
local function note(page, text, lines)
	return boxFor(page):Label(uiText(text), lines)
end

-- Todos los interruptores por nombre (en español): para "Apagar todo"
local toggles = {}
-- Quién encendió cada interruptor (módulo Ownership): Auto Expert, Auto Quest y Treasure Rain usan want() y
-- no apagan lo que otro (o tú) necesita.
local ownership = import("Ownership").new(toggles, life.spawn)

-- Interruptor. onChange(estado) al pulsarlo o al cargar un perfil; .set(v) lo cambia sin llamar a onChange.
-- noSave = es un ajuste, no una función (no entra en perfiles ni en "Apagar todo").
-- obj.transient = true: no va en perfiles, pero sí se apaga con "Apagar todo" y al cerrar (Seguir, Espectar).
local function toggle(page, text, onChange, desc, noSave)
	local key = type(text) == "table" and text.es or text
	local obj = { value = false, onChange = onChange, noSave = noSave }
	-- su estado en Components sale del interruptor (una sola fuente de verdad); los ajustes no son componentes
	local comp = not noSave and comps:register(key, { kind = "feature" }) or nil
	local o = {
		Name = uiText(text),
		Tip = desc and uiText(desc) or nil,
		Callback = function(v) -- pulsado a mano o cargado de un perfil: deja de ser de ninguna automatización
			obj.value = v
			ownership.userChanged(key)
			if comp then
				comp:setDesired(v and "Running" or "Disabled") -- intención: el interruptor
				-- estado real: el juego no confirma que una función "va", así que encendida = Waiting (en marcha, sin
				-- confirmar), nunca Running; Error si falla cualquier hilo suyo
				comp:set(v and "Waiting" or "Disabled", v and "encendida (sin confirmación del juego)" or "usuario / perfil")
			end
			life.spawnAs(key, onChange, v) -- sus hilos internos heredan el nombre
		end,
	}
	if noSave then o.Flag = false end
	local control = boxFor(page):Toggle(o)
	obj.control = control -- para el punto de estado (control:SetStatus)
	function obj.set(v)
		obj.value = v == true
		control:Set(obj.value, true)
		if comp then
			comp:setDesired(obj.value and "Running" or "Disabled")
			comp:set(obj.value and "Waiting" or "Disabled", obj.value and "encendida por una automatización (sin confirmar)" or "automático")
		end
	end
	toggles[key] = obj
	return obj
end

local want, turnAllOff = ownership.want, ownership.turnAllOff
-- Lo primero al cerrar: apagar todo para devolver el personaje, la cámara y los objetos a como estaban
life.add(function() turnAllOff(true) end, true)


local function button(parent, text, onClick, desc)
	return boxFor(parent):Button({ Name = uiText(text), Callback = life.guarded(onClick), Tip = desc and uiText(desc) or nil })
end

-- Lista desplegable de una opción. onPick(índice). Se guarda en config, no en los perfiles.
local function combo(page, text, options, default, onPick, desc)
	local names = {}
	for i, opt in options do names[i] = uiText(opt) end
	return boxFor(page):Combo({
		Name = uiText(text), Options = names, Default = default, Flag = false,
		Tip = desc and uiText(desc) or nil, Callback = life.guarded(function(_, i) onPick(i) end),
	})
end

-- Lista desplegable de varias opciones. onChange(tabla índice -> true/false).
local function multi(page, text, options, defaults, onChange, desc)
	local names = {}
	for i, opt in options do names[i] = uiText(opt) end
	return boxFor(page):Multi({
		Name = uiText(text), Options = names, Default = defaults, Flag = false,
		Tip = desc and uiText(desc) or nil, Callback = life.guarded(onChange),
	})
end

-- Caja de texto. secret = true: nunca va en los perfiles (Flag = false), p. ej. la URL del webhook, que salía al
-- copiar o exportar un perfil. Las demás se guardan en los perfiles como siempre.
local function input(page, text, placeholder, default, onDone, desc, secret)
	return boxFor(page):Input({ Name = uiText(text), Placeholder = uiText(placeholder), Default = default,
		Flag = if secret then false else nil, Callback = life.guarded(onDone), Tip = desc and uiText(desc) or nil })
end

-- Navegación (1.5.0): 4 grupos plegables y 15 secciones; la barra lateral se desplaza, así que ya no hay límite
-- de 11. Los ids de los perfiles salen de "Pestaña/Caja/Nombre": añadir o reordenar secciones no los cambia; lo que
-- se movió de sitio está en data/ui_moves.json y en Profiles.ALIASES (migración explícita).
local pagesX = {} -- secciones nuevas de 1.5.0, en una tabla para no sumar locales a ElHoyoHubMain
local hubShared = {} -- 1.5.3: lo que comparten secciones (lectura de vida: Huida y Bounty)
win:Group(uiText(L("PRINCIPAL", "MAIN")))
pagesX.dash = addTab(L("Panel", "Dashboard"), "TH")
local pageHome = addTab(L("Inicio", "Home"), "STAR")
pagesX.explorer = addTab(L("Explorador", "Explorer"), "SEARCH")
win:Group(uiText(L("MUNDO", "WORLD")))
local pagePlayer = addTab(L("Jugador", "Player"), "RUNNING")
local pageTp = addTab("Teleports", "GLOBE")
local pageGuis = addTab(L("Tiendas", "Shops"), "TH_LARGE")
win:Group(uiText(L("FARMEO", "FARMING")))
local pageAuto = addTab(L("Automatización", "Automation"), "BOLT")
local pageBoss = addTab(L("Jefes", "Bosses"), "SKULL")
local pageTrain = addTab(L("Entrenamiento", "Training"), "FIRE")
local pageQuest = addTab(L("Misiones", "Quests"), "AWARD")
local pageFruits = addTab(L("Frutas", "Fruits"), "GEM")
pagesX.bounty = addTab("Bounty (NPCs)", "CROSSHAIRS")
win:Group("HUB")
pagesX.profiles = addTab(L("Perfiles", "Presets"), "SAVE")
pagesX.diag = addTab(L("Diagnóstico", "Diagnostics"), "PROJECT_DIAGRAM")
local pageMisc = addTab("Misc", "SLIDERS_H")
local pageSettings = addTab(L("Ajustes", "Settings"), "COG")

-- Antes (≤ 1.5.3) se repartía aquí el alto de la página entre las cajas, cada una con scroll propio.
-- 1.5.4: ya no se reparte: cada caja mide lo que su contenido y la página entera se desplaza (un solo scroll,
-- ElHoyoUI TabMeta:layout + Layout.stack). Se conserva la función (se llama antes de win:Finish()).
local function fitBoxes() end

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
local teleport
do -- AVOID_WAIT, avoidLogged y playerNear solo los usa teleport
local AVOID_WAIT = 20
local avoidLogged = 0
local function playerNear(pos)
	for _, p in Players:GetPlayers() do
		local hrp = p ~= player and p.Character and p.Character:FindFirstChild("HumanoidRootPart")
		if hrp and (hrp.Position - pos).Magnitude < avoid.radius then return p.Name end
	end
end

-- Devuelve false si no te movió. shortcut: teletransporte directo; si el juego te expulsa por distancia, ir por tramos
function teleport(pos, skip)
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
end

-- 1.5.2: el turno de movimiento es el recurso "move" de Ownership (mismo comportamiento: un dueño, los demás
-- esperan) y `busy` refleja quién lo tiene. Así se apuntan peticiones denegadas, liberaciones tardías (una función
-- apagada suelta el turno mientras su tarea aún sigue) y lo que queda de antes de reaparecer.
local function claimMove(name)
	local ok = ownership.acquire("move", name)
	busy = ownership.holder("move")
	return ok
end
local function releaseMove(name)
	ownership.release("move", name)
	busy = ownership.holder("move")
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
	if busy == "Escape" then return end -- 1.5.2: durante la Huida nadie te baja (antes te devolvían abajo a mitad)
	if safePart then return goSafe() end
	local hrp = getHRP()
	if cf and hrp then hrp.CFrame = cf end
end

local function merchant(name)
	local map = workspace:FindFirstChild("Map")
	local merchants = map and map:FindFirstChild("Merchants")
	return merchants and merchants:FindFirstChild(name)
end

local overOurGui
do
local function isOver(f)
	if not f.Visible then return false end
	local p, s = f.AbsolutePosition, f.AbsoluteSize
	return mouse.X >= p.X and mouse.X <= p.X + s.X and mouse.Y >= p.Y and mouse.Y <= p.Y + s.Y
end
function overOurGui()
	return isOver(main) or isOver(consoleWin)
end
end

local clickMouse
do
-- ¿Hay un botón o casilla de texto del juego debajo del ratón?
local function overMenu()
	for _, obj in player.PlayerGui:GetGuiObjectsAtPosition(mouse.X, mouse.Y) do
		if (obj:IsA("GuiButton") or obj:IsA("TextBox")) and obj.Visible then return true end
	end
	return false
end

-- Clic real donde está el ratón (el juego hace su propio proceso: animación, señales...)
function clickMouse()
	if overOurGui() or overMenu() or UIS:GetFocusedTextBox() then return end
	local pos = UIS:GetMouseLocation()
	VIM:SendMouseButtonEvent(pos.X, pos.Y, 0, true, game, 0)
	VIM:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 0)
end
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
local toggleHaki
do
local hakiRemotes, lastHakiFire = {}, {}
for _, haki in HAKIS do hakiRemotes[haki.name] = getRemote("HakiService", "RE", haki.remote) end

function toggleHaki(name)
	if os.clock() - (lastHakiFire[name] or -math.huge) < 2 then return false end
	lastHakiFire[name] = os.clock()
	local ok, err = call(hakiRemotes[name], "FireServer")
	if not ok then log(name .. ": error " .. tostring(err), "error") end
	return ok
end
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

	life.spawn(function()
		while life.alive do
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

life.spawn(function()
	while life.alive do
		task.wait(CLICK_DELAY)
		if autoClick then clickMouse() end
	end
end)

end

------------------------------------------------------------------ Auto Sam
;(function() -- función propia: sus locales no cuentan para el límite de ElHoyoHubMain
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
	local done = ownership.use("hand", "Auto Sam") -- solo observa: apunta si otra función usa la mano a la vez
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if hum and compass.Parent ~= player.Character then
		hum:EquipTool(compass)
		task.wait(0.3)
	end
	compass:Activate()
	clickMouse()
	done()
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
life.spawn(function()
	while life.alive do
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
end)()

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
life.spawn(function()
	while life.alive do
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
	if on then life.spawn(claimChallenges) end
end, L("Reclama los Challenges completados (menú Challenges del juego) cada minuto.",
	"Claims finished Challenges (the game's Challenges menu) every minute."))

life.spawn(function()
	while life.alive do
		task.wait(REWARD_EVERY)
		if autoRewards then claimRewards() end
		if autoChallenges then pcall(claimChallenges) end
	end
end)

end

------------------------------------------------------------------ Auto Pesca
;(function() -- función propia: sus locales no cuentan para el límite de ElHoyoHubMain
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
		life.spawn(function()
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

life.spawn(function()
	while life.alive do
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

end)()

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
;(function() -- función propia: sus locales no cuentan para el límite de ElHoyoHubMain
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

life.spawn(function()
	while life.alive do
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
end)()

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

life.spawn(function()
	while life.alive do
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
life.spawn(function()
	while life.alive do
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
;(function() -- función propia: sus locales no cuentan para el límite de ElHoyoHubMain
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
		life.delay(KEN_DELAY, function() call(dojoAnswer, "FireServer", data.I, data.Side) end)
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

life.spawn(function()
	while life.alive do
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
life.spawn(function()
	while life.alive do
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

end)()

local groundFruits = function() return {} end -- la rellena Frutas; la usa el ESP
------------------------------------------------------------------ Frutas
;(function() -- función propia: sus locales no cuentan para el límite de ElHoyoHubMain (1.4.0)
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

life.spawn(function()
	while life.alive do
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
	-- 1.5.1: si otra función tiene la mano (Auto Sam con el compass, la venta, Bounty), esta vuelta se salta
	local other = ownership.inUse("hand", "Auto abrir cajas")
	if other then
		ownership.event("yielded", "hand", "Auto abrir cajas", other)
		return 0
	end
	local done = ownership.use("hand", "Auto abrir cajas")
	for _, tool in myTools() do
		local rank = boxRank(tool.Name)
		if rank and config.boxRarities[rank] and hold(tool) then
			call(boxOpen, "FireServer")
			opened += 1
			log(T("Cajas: abierta ", "Boxes: opened ") .. tool.Name, "ok", true)
			task.wait(1.5) -- que llegue la fruta
		end
	end
	done()
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
	local other = ownership.inUse("hand", "Auto vender frutas")
	if other then -- 1.5.1: espera a que la mano quede libre (siguiente vuelta)
		ownership.event("yielded", "hand", "Auto vender frutas", other)
		return
	end
	if not claimMove("Sell") then return end
	local handDone = ownership.use("hand", "Auto vender frutas")
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
	handDone()
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

life.spawn(function()
	while life.alive do
		task.wait(3)
		local ok, err = pcall(function()
			if autoBoxes then openBoxes() end
			if autoSell then sellFruits() end
		end)
		if not ok then log(T("Cajas/venta: error ", "Boxes/sell: error ") .. tostring(err), "error") end
	end
end)
end)()

local NPCS -- también lo usa la pestaña GUIs
------------------------------------------------------------------ Teleports
;(function() -- función propia: sus locales no cuentan para el límite de ElHoyoHubMain (1.4.0)
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
	life.defer(layout) -- TextBounds ya calculado

	local me = Instance.new("Frame")
	me.AnchorPoint = Vector2.new(0.5, 0.5)
	me.Size = UDim2.fromOffset(8, 8)
	me.BackgroundColor3 = C.accent
	me.BorderSizePixel = 0
	me.ZIndex = 5
	me.Parent = frame
	Instance.new("UICorner", me).CornerRadius = UDim.new(1, 0)
	Instance.new("UIStroke", me).Color = C.text
	life.spawn(function()
		while life.alive and frame.Parent do
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

end)()

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
;(function() -- función propia: sus locales no cuentan para el límite de ElHoyoHubMain
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

life.spawn(function()
	while life.alive do
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
life.spawn(function()
	while life.alive do
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
end)()

------------------------------------------------------------------ Misc
;(function() -- función propia: sus locales no cuentan para el límite de ElHoyoHubMain
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
life.spawn(function()
	while life.alive do
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
		while life.alive and autoRespawn and player.Character == char and os.clock() - t0 < 30 do
			task.wait(1)
			local ok, accepted = call(respawnRemote, "InvokeServer")
			if ok and accepted then
				log(T("Auto Respawn: reapareciendo", "Auto Respawn: respawning"), "ok")
				return
			end
		end
		if life.alive and autoRespawn and player.Character == char then
			log(T("Auto Respawn: el servidor no me ha dejado reaparecer en 30 s", "Auto Respawn: the server didn't let me respawn in 30 s"), "warn")
		end
	end)
end
if player.Character then life.spawn(watchDeath, player.Character) end
table.insert(cleanup, player.CharacterAdded:Connect(watchDeath))
-- 1.5.2: personaje nuevo = epoch nuevo: lo pedido con el anterior queda marcado como referencia vieja (Diagnóstico)
table.insert(cleanup, player.CharacterAdded:Connect(function() ownership.newEpoch("reaparición") end))
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
button(pageMisc, L("Mostrar / ocultar consola", "Show / hide console"), function() setConsole(not console.shown()) end,
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

-- CONGELADA (ver CLAUDE.md > Conservación funcional): implementación de 1.3.1 sin cambios; no ampliar.
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
	for _, p in Players:GetPlayers() do life.spawn(checkAdmin, p) end
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
;(function() -- función propia: sus locales no cuentan para el límite de ElHoyoHubMain (1.4.0)
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

life.spawn(function()
	while life.alive do
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
end)()

end)()

------------------------------------------------------------------ Movilidad (pestaña Jugador)
;(function() -- función propia: sus locales no cuentan para el límite de ElHoyoHubMain
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
end)()

------------------------------------------------------------------ Huida (pestaña Jugador, Protección)
;(function() -- función propia: sus locales no cuentan para el límite de ElHoyoHubMain
-- Un god mode de verdad no se puede hacer desde el cliente: la vida la lleva el servidor. Lo más parecido: si la
-- vida baja del límite, te saca al cielo (zona segura o una plataforma temporal) hasta que te recuperas, y
-- ninguna función te mueve mientras tanto.
local LIMITS = { 20, 35, 50, 70 }
local Protection = import("Protection")
local escapeOn = false
local limit = LIMITS[tonumber(config.escapeAt) or 2] or 35
local state = { escaping = false }
local lastReading, lastReason = nil, "apagada"
local lastSources, lastChosen, lastChoice, sticky = {}, nil, "", nil
local temp

local function attrsOf(obj)
	if not obj then return nil end
	local ok, all = pcall(function() return obj:GetAttributes() end)
	return ok and all or nil
end
-- 1.5.3: todo lo que podría ser la vida, encontrado por NOMBRE (nada inventado): Humanoid, atributos del personaje,
-- del Humanoid y del jugador, y NumberValue/IntValue con "health"/"hp" en el nombre dentro del personaje o del jugador.
local function healthSnapshot()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local snap = { humanoid = hum and { Health = hum.Health, MaxHealth = hum.MaxHealth } or nil,
		attrs = { character = attrsOf(char), humanoid = attrsOf(hum), player = attrsOf(player) }, values = {} }
	for _, root in { char, player } do
		for _, d in root and root:GetDescendants() or {} do
			if (d:IsA("NumberValue") or d:IsA("IntValue")) and Protection.isHealthName(d.Name) and #snap.values < 10 then
				table.insert(snap.values, { path = d:GetFullName():gsub("^Players%.[^%.]+%.", "Player."), name = d.Name, value = d.Value })
			end
		end
	end
	return char, snap
end
hubShared.healthSnapshot = healthSnapshot

-- Subir: a la zona segura o a una plataforma temporal. El turno de movimiento se QUITA (preempt) y al acabar se
-- devuelve a quien lo tuviera (antes se ponía a nil y la función que movía se quedaba sin él).
local function startEscape()
	ownership.acquire("move", "Escape", { preempt = true })
	busy = ownership.holder("move")
	local hrp = getHRP()
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
end
local function stopEscape(why)
	if temp then temp:Destroy(); temp = nil end
	ownership.release("move", "Escape")
	busy = ownership.holder("move")
	local good = why == "recuperado"
	log((good and T("Huida: recuperado, las funciones siguen", "Escape: recovered, features carry on")
		or (T("Huida terminada: ", "Escape ended: ") .. why)), good and "info" or "warn", not good)
end
life.add(function() if state.escaping then stopEscape("hub cerrado") end end)

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
-- 1.5.3: de qué fuente sale la vida (Auto / Humanoid / atributo Health), guardado en config.healthSource
do
	local MODE_NAMES = { L("Auto (recomendado)", "Auto (recommended)"), "Humanoid", L("Atributo Health", "Health attribute") }
	combo(pagePlayer, L("Fuente de vida", "Health source"), MODE_NAMES,
		table.find(Protection.MODES, config.healthSource) or 1, function(i)
		config.healthSource = Protection.MODES[i]
		sticky = nil
		saveConfig()
	end, L("De dónde se lee tu vida. Auto usa el Humanoid salvo que otra fuente marque menos vida con el Humanoid lleno.",
		"Where your health is read from. Auto uses the Humanoid unless another source shows less health while the Humanoid is full."))
end
-- Diagnóstico de vida: TODAS las fuentes a la vez, la elegida, el umbral, el estado y por qué no salta
local function healthText()
	local out = {}
	for _, src in lastSources do
		table.insert(out, string.format("%s%s: %s%s", src == lastChosen and "▶ " or "   ", src.label,
			src.max and string.format("%g/%g", math.floor(src.value * 10) / 10, src.max) or tostring(src.value),
			src.pct and string.format(" = %d%%", math.floor(src.pct * 100 + 0.5)) or T(" (sin máximo)", " (no max)")))
	end
	if #out == 0 then table.insert(out, T("Sin fuentes de vida legibles (¿sin personaje?)", "No readable health sources (no character?)")) end
	table.insert(out, T("Fuente: ", "Source: ") .. tostring(lastChoice))
	table.insert(out, string.format(T("Umbral %d%% · Huida %s · %s", "Threshold %d%% · Escape %s · %s"), limit,
		escapeOn and "ON" or "OFF", tostring(lastReason)))
	return table.concat(out, "\n")
end
local healthLabel = note(pagePlayer, healthText, 7)
-- Grabación para la prueba real: 20 s de todas las fuentes y de los textos "N / M" de la pantalla mientras recibes
-- daño; dice cuáles cambiaron (la vida real es la que baja) y lo copia para pegarlo en el chat.
local recording = false
button(pagePlayer, L("Grabar vida 20 s (recibe daño)", "Record health 20 s (take damage)"), function()
	if recording then return end
	recording = true
	log(T("Vida: grabando 20 s; recibe algo de daño ahora", "Health: recording 20 s; take some damage now"), "info", true)
	local samples, texts, textCount = {}, {}, 0
	for _ = 1, 40 do
		local _, snap = healthSnapshot()
		local sample = {}
		for _, src in Protection.sources(snap) do sample[src.id] = src.value end
		local gui = player:FindFirstChild("PlayerGui")
		for _, d in gui and gui:GetDescendants() or {} do
			if d:IsA("TextLabel") and d.Visible then
				local a, b = tostring(d.Text):match("^%s*(%d+%.?%d*)%s*/%s*(%d+%.?%d*)%s*$")
				if a then
					local key = "texto " .. d:GetFullName():gsub("^Players%.[^%.]+%.", "")
					if texts[key] or textCount < 12 then -- como mucho 12 textos distintos
						if not texts[key] then textCount += 1 end
						texts[key] = true
						sample[key] = tonumber(a)
					end
				end
			end
		end
		table.insert(samples, sample)
		task.wait(0.5)
	end
	recording = false
	local lines = { "El Hoyo Hub " .. HUB_VERSION .. " — grabación de vida (20 s)" }
	for _, st in Protection.summarize(samples) do
		table.insert(lines, string.format("%s %s: %g -> %g (mín %g, máx %g)", st.changed and "CAMBIÓ" or "igual ", st.id, st.first, st.last, st.min, st.max))
	end
	local text = table.concat(lines, "\n")
	for _, l in lines do log(l) end
	setConsole(true)
	if setclipboard then pcall(setclipboard, text) end
	log(T("Vida: grabación copiada al portapapeles. Pégamela para elegir la fuente correcta.",
		"Health: recording copied to the clipboard. Paste it to me to pick the right source."), "ok", true)
end, L("Graba 20 s todas las fuentes de vida mientras recibes daño y dice cuál baja de verdad.",
	"Records every health source for 20 s while you take damage and tells which one really drops."))
life.spawnAs("Huida automática", function()
	local warned = false
	local lastChar
	while life.alive do
		task.wait(0.2)
		local char, snap = healthSnapshot()
		if char ~= lastChar then sticky, lastChar = nil, char end -- personaje nuevo: se vuelve a elegir la fuente
		lastSources = Protection.sources(snap)
		local chosen, choice = Protection.select(lastSources, config.healthSource or "auto", sticky)
		if chosen and chosen.id ~= "humanoid" and (config.healthSource or "auto") == "auto" then sticky = chosen.id end
		lastChosen, lastChoice = chosen, choice
		lastReading = Protection.fromSource(chosen)
		hubShared.health = lastReading -- Bounty usa la misma lectura
		if chosen and chosen.id ~= "humanoid" and not warned then
			warned = true
			log(T("Vida: se usa ", "Health: using ") .. chosen.label .. " (" .. choice .. T("). Compruébalo con \"Grabar vida 20 s\".", "). Check it with \"Record health 20 s\"."), "warn", true)
		end
		local action, why = Protection.step(state, { enabled = escapeOn, limit = limit, reading = lastReading, character = char,
			now = os.clock(), alive = life.alive })
		lastReason = why
		if action == "start" then startEscape() elseif action == "stop" then stopEscape(why) end
		local comp = comps:get("Huida automática")
		if comp and escapeOn and comp.state ~= "Error" then comp:set("Waiting", why) end
		if healthLabel and main.Visible and win.current == pagePlayer.tab then healthLabel.Text = healthText() end
	end
end)
end)()

------------------------------------------------------------------ Auto Boss
;(function() -- función propia: sus locales no cuentan para el límite de ElHoyoHubMain (1.4.0)
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
-- CONGELADA (ver CLAUDE.md > Conservación funcional): implementación de 1.3.1 sin cambios; no ampliar.
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
life.spawn(function()
	while life.alive do
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

life.spawn(function()
	while life.alive do
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
end)()

------------------------------------------------------------------ Inicio
;(function() -- función propia: sus locales no cuentan para el límite de ElHoyoHubMain
local DISCORD_URL = nil -- poner aquí la invitación cuando exista
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
life.spawn(function()
	while life.alive do
		fps, frames = frames, 0
		hubStats.fps = fps
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
		set("session", T("Sesión con el hub: ", "Session with the hub: ") .. span(os.clock() - life.startedAt))
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
end)()

------------------------------------------------------------------ Jugadores: seguir y espectar (pestaña Jugador)
;(function() -- función propia: sus locales no cuentan para el límite de ElHoyoHubMain
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

life.spawn(function()
	while life.alive do
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
end)()

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
life.spawn(function()
	while life.alive do
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

life.spawn(function()
	while life.alive do
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
life.spawn(function()
	while life.alive do
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
	"Paste a webhook URL from your Discord server to get alerts. It's stored in ElHoyoHub.json, not in presets."), true)
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
life.spawn(function()
	while life.alive do
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
			life.spawn(t.onChange, true)
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
	life.defer(function() waitingKey = false end) -- que esa misma pulsación no oculte el hub
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

------------------------------------------------------------------ Explorador del juego (sección propia)
-- Consulta el catálogo documentado (Knowledge + KnowledgeView): búsqueda, filtros agrupados (Mostrar, Estado,
-- Papel), orden, lista desplazable, ficha completa con fuentes, estado y desconocidos, y navegación por relacionadas
-- con historial ("‹ Volver"). Solo informa: no mueve ni toca nada del juego.
-- 1.5.0: sección propia (antes columna 2 de Jefes). El id de "Buscar" cambió (Profiles.ALIASES lo migra).
;(function() -- función propia: sus locales no cuentan para el límite de ElHoyoHubMain
local Knowledge = import("Knowledge")
local KnowledgeView = import("KnowledgeView")
local catalogIndex = import("CatalogIndex")
local problems = Knowledge.validate(catalogIndex)
comps:register("Knowledge", { kind = "info", state = #problems == 0 and "Ready" or "Error",
	reason = #problems == 0 and ("catálogo " .. tostring(catalogIndex.meta.version)) or (#problems .. " problemas en el catálogo") })
local page = pagesX.explorer
local view, listLabel, sheetLabel
local function tr(pair) return T(pair[1], pair[2]) end
local function refresh()
	if listLabel then listLabel.Text = view:listText(17) end
	if sheetLabel then sheetLabel.Text = table.concat(view:sheetLines(), "\n") end
end
local function options(list)
	local out = {}
	for i, p in KnowledgeView.options(list) do out[i] = L(p[1], p[2]) end
	return out
end
local explorer = comps:register(T("Explorador", "Explorer"), { kind = "info", deps = { "Knowledge" }, impl = {
	init = function() view = KnowledgeView.new(Knowledge.new(catalogIndex), tr) end,
	start = function(c) view:run(); refresh(); c.reason = #view.results .. " entidades" end,
} })

page.tab:Columns({ 1, 1.15 })
section(page, L("Búsqueda", "Search"), 1)
local controls = {}
controls.search = input(page, L("Buscar", "Search"), L("nombre, alias o id", "name, alias or id"), "", function(text)
	if view then view:set("query", text); refresh() end
end, L("Busca en todo el catálogo: islas, NPCs, jefes, misiones, eventos, objetos, frutas… por nombre, alias o id.",
	"Searches the whole catalog: islands, NPCs, bosses, quests, events, items, fruits… by name, alias or id."))
controls.group = combo(page, L("Mostrar", "Show"), options(KnowledgeView.GROUPS), 1, function(i)
	if view then view:set("group", i); refresh() end
end, L("Qué tipo de cosas ver.", "What kind of things to show."))
controls.status = combo(page, L("Estado", "Status"), options(KnowledgeView.STATUS), 1, function(i)
	if view then view:set("status", i); refresh() end
end, L("Filtra por cómo de segura es la información (confirmada en el juego, solo de la wiki, contradictoria…).",
	"Filters by how reliable the information is (confirmed in game, wiki only, contradictory…)."))
controls.role = combo(page, L("Papel", "Role"), options(KnowledgeView.ROLES), 1, function(i)
	if view then view:set("role", i); refresh() end
end, L("Jefes, élites, comerciantes o quien da misiones (según la wiki).", "Bosses, elites, merchants or quest givers (per the wiki)."))
controls.sort = combo(page, L("Orden", "Order"), options(KnowledgeView.SORTS), 1, function(i)
	if view then view:set("sort", i); refresh() end
end)
listLabel = note(page, function() return view and view:listText(17) or "" end, 18)
button(page, L("‹ Anterior", "‹ Previous"), function() if view and view:move(-1) then refresh() end end)
button(page, L("Siguiente ›", "Next ›"), function() if view and view:move(1) then refresh() end end)
button(page, L("Restablecer filtros", "Reset filters"), function()
	if not view then return end
	view:reset()
	controls.search:Set("")
	for _, key in { "group", "status", "role", "sort" } do controls[key]:Set(1, true) end
	refresh()
end, L("Vacía la búsqueda y vuelve a Todo / Cualquiera / Relevancia.", "Clears the search and goes back to All / Any / Relevance."))

section(page, L("Ficha", "Sheet"), 2)
sheetLabel = note(page, function() return view and table.concat(view:sheetLines(), "\n") or "" end, 26)
button(page, L("Relacionada siguiente", "Next related"), function()
	if view and view:nextRelated() then refresh() end
end, L("Mueve ▶ por las relacionadas de la ficha.", "Moves ▶ through the sheet's related entries."))
button(page, L("Abrir relacionada", "Open related"), function()
	if view and view:openRelated() then refresh() else log(T("Esta ficha no tiene relacionadas", "This sheet has no related entries"), "info") end
end, L("Abre la ficha de la relacionada marcada con ▶.", "Opens the sheet of the related entry marked with ▶."))
button(page, L("‹ Volver", "‹ Back"), function()
	if view and view:back() then refresh() end
end, L("Vuelve a la ficha anterior.", "Goes back to the previous sheet."))
button(page, L("Ficha completa en la consola", "Full sheet in the console"), function()
	local lines = view and view:sheetLines() or {}
	if #lines == 0 then return log(T("Elige antes un resultado", "Pick a result first"), "warn") end
	for _, l in lines do log(l) end
	setConsole(true)
end, L("Copia la ficha en la consola (la caja ya la muestra entera; esto sirve para copiarla).", "Copies the sheet to the console (the box already shows it; this is for copying)."))
note(page, L("Fuente: wiki del juego (datos.json) y lo grabado en el juego. DOCUMENTADO = lo dice la wiki, sin comprobar. ?N = datos que no se saben.",
	"Source: the game's wiki (datos.json) and what was recorded in game. DOCUMENTED = the wiki says so, unchecked. ?N = unknown data."))
explorer:start()
comps:refresh()

-- Buscador global (Ctrl+K): las entidades del catálogo también salen; elegir una abre su ficha aquí (no hace nada más)
win.searchProviders = win.searchProviders or {}
table.insert(win.searchProviders, function(q)
	if not view then return {} end
	local out = {}
	for _, e in view.k:search(q, {}, 5) do
		table.insert(out, { label = e.name, aliases = e.aliases, group = "catalog",
			path = tr(Knowledge.LABELS[e.category] or { e.category, e.category }), pick = function()
				controls.search:Set(e.name)
				view:set("query", e.name)
				refresh()
				win:selectTab(page.tab)
			end })
	end
	return out
end)
end)()

------------------------------------------------------------------ Perfiles (sección propia)
-- Centro de perfiles (1.5.0). Reglas: módulo Profiles (validar, aplicar atómico, diff, exportar sin secretos);
-- guardar, renombrar, duplicar y papelera: la librería (win.configs). Aquí solo se ordena y se enseña: no hay otra
-- forma de guardar perfiles. Las cajas de texto de esta sección no van en los perfiles.
;(function() -- función propia: sus locales no cuentan para el límite de ElHoyoHubMain
local Profiles = import("Profiles")
local configs = win.configs
local page = pagesX.profiles
Profiles.ALIASES = { ["Bosses/Game explorer/Search"] = "Explorer/Search/Search" } -- = data/ui_moves.json > ids
win.profileVersion = Profiles.VERSION
win.profileApply = function(values, controls, pending)
	local ok, problems, warnings = Profiles.apply(values, controls, pending)
	if not ok then
		log(T("Perfil NO aplicado (no se ha cambiado nada): ", "Preset NOT applied (nothing changed): ") .. table.concat(problems, "; "), "error")
	end
	for _, w in warnings do
		if w:find("secreto", 1, true) then log(T("Perfil: ", "Preset: ") .. w, "warn") end
	end
	return ok, problems
end
win.profileExport = function(cfg, values)
	local out, removed = Profiles.export(cfg, values, HUB_VERSION)
	if #removed > 0 then log(T("Exportado sin ", "Exported without ") .. #removed .. T(" secretos", " secrets"), "info") end
	return json.encode(out)
end
local profilesComp = comps:register(T("Perfiles", "Presets"), { kind = "info", state = "Ready" })

local target, pendingImport, armed = "", nil, nil
local previewText = T("Escribe un perfil y pulsa Vista previa.", "Type a preset and press Preview.")
local labels = {}
local function changed() if win.configsChanged then win.configsChanged() end end
local function findProfile(name)
	local want = tostring(name):lower():match("^%s*(.-)%s*$")
	if want == "" then return configs.selected end
	for i, cfg in configs.list do if cfg.name:lower() == want then return i end end
	for i, cfg in configs.list do if cfg.name:lower():find(want, 1, true) then return i end end
	return nil
end
local function dirtyCount()
	local okPeek, saved = pcall(configs.peek, configs.selected)
	local _, n = Profiles.dirty(okPeek and saved or {}, configs.snapshot())
	return n
end
local function statusText()
	local cfg = configs.current()
	if not cfg then return T("Sin perfil activo", "No active preset") end
	local n = dirtyCount()
	return string.format(T("● %s   (formato v%d)\n%s\nPerfiles: %d · papelera: %d", "● %s   (format v%d)\n%s\nPresets: %d · bin: %d"),
		cfg.name, Profiles.VERSION, n > 0 and string.format(T("%d cambios sin guardar", "%d unsaved changes"), n) or T("Todo guardado", "Everything saved"),
		#configs.list, #configs.trash)
end
local function listText()
	local out = {}
	local pick = findProfile(target)
	for i, cfg in configs.list do
		if i > 12 then table.insert(out, "… +" .. (#configs.list - 12)); break end
		table.insert(out, (i == configs.selected and "● " or "   ") .. cfg.name .. (i == pick and i ~= configs.selected and "   ◂ " .. T("elegido", "picked") or ""))
	end
	return table.concat(out, "\n")
end
local function refresh()
	if labels.status then labels.status.Text = statusText() end
	if labels.list then labels.list.Text = listText() end
	if labels.preview then labels.preview.Text = previewText end
end
local function picked()
	local i = findProfile(target)
	if not i then log(T("Elige antes un perfil (escribe su nombre en Perfil)", "Pick a preset first (type its name in Preset)"), "warn") end
	return i
end

page.tab:Columns({ 1, 1 })
section(page, L("Perfil activo", "Active preset"), 1)
labels.status = note(page, statusText, 3)
labels.list = note(page, listText, 13)

section(page, L("Gestionar", "Manage"), 1)
input(page, L("Perfil", "Preset"), L("nombre (vacío = el activo)", "name (empty = active)"), "", function(text)
	target = text
	local i = findProfile(text)
	log(i and (T("Perfil elegido: ", "Preset picked: ") .. configs.list[i].name) or T("No hay ningún perfil con ese nombre", "No preset with that name"), i and "info" or "warn")
	refresh()
end, L("Escribe el nombre (o parte) del perfil sobre el que actúan los botones.", "Type the name (or part) of the preset the buttons act on."), true)
button(page, L("Vista previa", "Preview"), function()
	local i = picked()
	if not i then return end
	local values = configs.peek(i) or {}
	local ok, problems = Profiles.validate({ values = values })
	local d = Profiles.diff(configs.snapshot(), values)
	local out = { string.format(T("%s: %d cambios · %d iguales · %d de controles aún sin crear", "%s: %d changes · %d unchanged · %d for controls not built yet"),
		configs.list[i].name, #d.changes, d.unchanged, #d.unknown) }
	if not ok then table.insert(out, T("NO se puede aplicar: ", "CAN'T be applied: ") .. table.concat(problems, "; ")) end
	for k, c in d.changes do
		if k > 14 then table.insert(out, "… +" .. (#d.changes - 14)); break end
		table.insert(out, c.id:match("[^/]+$") .. ": " .. Profiles.show(c.from) .. " → " .. Profiles.show(c.to))
	end
	previewText = table.concat(out, "\n")
	refresh()
end, L("Enseña qué cambiaría si aplicas ese perfil, sin aplicarlo.", "Shows what would change if you applied that preset, without applying it."))
button(page, L("Aplicar perfil", "Apply preset"), function()
	local i = picked()
	if not i then return end
	local ok = configs.load(i)
	changed()
	if ok then log(T("Perfil aplicado: ", "Preset applied: ") .. configs.list[i].name, "ok", true) end
	refresh()
end, L("Aplica el perfil entero o, si tiene datos no válidos, no cambia nada y dice por qué.", "Applies the whole preset or, if it has invalid data, changes nothing and says why."))
button(page, L("Descartar cambios sin guardar", "Discard unsaved changes"), function()
	local ok = configs.revert()
	if ok then log(T("Vuelto a lo guardado en ", "Back to what was saved in ") .. tostring(configs.current() and configs.current().name), "ok", true) end
	refresh()
end, L("Vuelve a poner el perfil activo tal y como está guardado.", "Puts the active preset back exactly as it is saved."))
input(page, L("Renombrar a", "Rename to"), L("nombre nuevo", "new name"), "", function(text)
	text = text:match("^%s*(.-)%s*$")
	if text == "" then return end
	local i = picked()
	if not i then return end
	local old = configs.list[i].name
	configs.rename(i, text)
	changed()
	log(string.format(T("Perfil renombrado: %s → %s", "Preset renamed: %s → %s"), old, configs.list[i].name), "ok", true)
	target = configs.list[i].name
	refresh()
end, L("Cambia el nombre del perfil elegido (no cambia su contenido).", "Renames the picked preset (its content stays the same)."), true)
button(page, L("Duplicar perfil", "Duplicate preset"), function()
	local i = picked()
	if not i then return end
	local copy = configs.duplicate(i)
	changed()
	log(T("Perfil duplicado: ", "Preset duplicated: ") .. copy.name, "ok", true)
	refresh()
end, L("Crea una copia del perfil elegido.", "Makes a copy of the picked preset."))
button(page, L("Enviar a la papelera", "Move to bin"), function()
	local i = picked()
	if not i then return end
	local name = configs.list[i].name
	-- confirmación: segundo clic en 4 s sobre el mismo perfil
	if not (armed and armed.name == name and os.clock() - armed.at < 4) then
		armed = { name = name, at = os.clock() }
		return log(string.format(T("¿Mandar %s a la papelera? Vuelve a pulsar en 4 s para confirmar (se puede restaurar)",
			"Move %s to the bin? Press again within 4 s to confirm (it can be restored)"), name), "warn", true)
	end
	armed = nil
	configs.remove(i)
	changed()
	log(T("Perfil en la papelera: ", "Preset moved to the bin: ") .. name, "ok", true)
	refresh()
end, L("Lo manda a la papelera (pide confirmación; desde la papelera se puede restaurar).", "Moves it to the bin (asks to confirm; it can be restored from the bin)."))
button(page, L("Restaurar de la papelera", "Restore from bin"), function()
	if #configs.trash == 0 then return log(T("La papelera está vacía", "The bin is empty"), "info") end
	local back = configs.restore(#configs.trash)
	changed()
	log(T("Perfil restaurado: ", "Preset restored: ") .. back.name, "ok", true)
	refresh()
end, L("Recupera el último perfil que mandaste a la papelera.", "Brings back the last preset you moved to the bin."))

section(page, L("Vista previa", "Preview"), 2)
labels.preview = note(page, function() return previewText end, 16)

section(page, L("Importar y exportar", "Import and export"), 2)
button(page, L("Exportar perfil (sin secretos)", "Export preset (no secrets)"), function()
	if configs.export(configs.selected) then log(T("Perfil copiado al portapapeles, sin secretos", "Preset copied to the clipboard, without secrets"), "ok", true)
	else log(T("Tu executor no deja copiar", "Your executor can't copy"), "warn") end
end, L("Copia el perfil activo sin URLs de webhook ni otros secretos.", "Copies the active preset without webhook URLs or other secrets."))
input(page, L("Importar perfil", "Import preset"), L("pega aquí el JSON exportado", "paste the exported JSON here"), "", function(text)
	if text:match("^%s*$") then pendingImport = nil; return end
	local known = configs.snapshot()
	local ok, profile, problems, warnings = Profiles.import(text, json, known)
	if not ok then
		pendingImport = nil
		previewText = T("Importación rechazada: ", "Import rejected: ") .. table.concat(problems, "; ")
		refresh()
		return log(previewText, "warn")
	end
	pendingImport = profile
	local d = Profiles.diff(known, profile.values)
	previewText = string.format(T("Perfil válido \"%s\": %d valores (%d cambiarían), %d avisos.\nPulsa \"Crear perfil importado\": no se aplica hasta que lo elijas.",
		"Valid preset \"%s\": %d values (%d would change), %d warnings.\nPress \"Create imported preset\": nothing is applied until you pick it."),
		profile.name, d.unchanged + #d.changes + #d.unknown, #d.changes, #warnings)
	refresh()
end, L("Comprueba el JSON de un perfil exportado. No aplica nada hasta que lo crees y lo cargues.", "Checks an exported preset's JSON. Nothing is applied until you create and load it."), true)
button(page, L("Crear perfil importado", "Create imported preset"), function()
	if not pendingImport then return log(T("Pega antes un perfil válido en Importar perfil", "Paste a valid preset into Import preset first"), "warn") end
	local _, cfg = configs.createFrom(pendingImport.name, pendingImport.values)
	log(T("Perfil creado (sin aplicar): ", "Preset created (not applied): ") .. cfg.name, "ok", true)
	pendingImport = nil
	refresh()
end, L("Guarda lo importado como un perfil nuevo. Para usarlo, aplícalo después.", "Saves the import as a new preset. To use it, apply it afterwards."))

-- Lo que se ve se recalcula cada 3 s con la sección abierta: tarea del componente (se cancela al cerrar)
profilesComp.impl = { start = function(c) c:spawn(function(token)
	while life.alive and token.alive() do
		if main.Visible and win.current == page.tab then refresh() end
		task.wait(3)
	end
end) end }
profilesComp:start()

-- Buscador global: los perfiles salen como resultados; elegir uno lo selecciona aquí (NO lo aplica)
win.searchProviders = win.searchProviders or {}
table.insert(win.searchProviders, function()
	local out = {}
	for i, cfg in configs.list do
		table.insert(out, { label = cfg.name, group = "profiles", path = i == configs.selected and T("activo", "active") or "", pick = function()
			target = cfg.name
			refresh()
			win:selectTab(page.tab)
		end })
	end
	return out
end)
pagesX.profilesStatus = function() return configs.current() and configs.current().name, dirtyCount() end
end)()

------------------------------------------------------------------ Diagnóstico (pestaña Ajustes)
;(function() -- función propia: sus locales no cuentan para el límite de ElHoyoHubMain
-- Estado del hub para pedir ayuda: versiones, carga, componentes, memoria, FPS, errores, recursos, config y
-- funciones del executor. "Copiar informe" lo pasa por Diagnostics.format, que quita secretos y datos
-- personales (URL del webhook, tu nombre, tu UserId, el JobId del servidor).
local Diagnostics = import("Diagnostics")
local Knowledge = import("Knowledge")
local catalogIndex = import("CatalogIndex")
local catalogStats = Knowledge.new(catalogIndex):stats()
comps:register("Diagnostics", { kind = "info", state = "Ready" })
-- Funciones del executor que usa el hub (referencias directas: getfenv desactivaría optimizaciones de Luau)
local DEPS = { writefile = writefile, readfile = readfile, listfiles = listfiles, isfolder = isfolder, makefolder = makefolder,
	setclipboard = setclipboard, request = request or http_request or (syn and syn.request), getconnections = getconnections,
	firesignal = firesignal, fireclickdetector = fireclickdetector, firetouchinterest = firetouchinterest, setfpscap = setfpscap,
	queue_on_teleport = queue_on_teleport or queueonteleport, gethui = gethui, getgenv = getgenv, identifyexecutor = identifyexecutor }

local function collect()
	local deps = {}
	for name in { writefile = 1, readfile = 1, listfiles = 1, isfolder = 1, makefolder = 1, setclipboard = 1, request = 1, getconnections = 1,
		firesignal = 1, fireclickdetector = 1, firetouchinterest = 1, setfpscap = 1, queue_on_teleport = 1, gethui = 1, getgenv = 1, identifyexecutor = 1 } do
		deps[name] = type(DEPS[name]) == "function"
	end
	local features = {}
	for name, t in toggles do
		if t.value and (not t.noSave or t.transient) then table.insert(features, name) end
	end
	table.sort(features)
	local now = os.clock()
	local errs = {}
	for _, e in life.errors:recent(10) do
		table.insert(errs, { message = e.message, count = e.count, ago = now - e.last, source = e.source, kind = e.kind })
	end
	-- tareas vivas por origen (componente)
	local tasksBySource = {}
	for _, t in life.tasks() do
		local key = t.source or "?"
		tasksBySource[key] = (tasksBySource[key] or 0) + 1
	end
	local cfgSel = win.configs and win.configs.current()
	local okPeek, saved = pcall(function() return win.configs.peek(win.configs.selected) end)
	local Profiles = import("Profiles")
	local _, dirtyN = Profiles.dirty(okPeek and saved or {}, win.configs and win.configs.snapshot() or {})
	local okMem, mem = pcall(function() return game:GetService("Stats"):GetTotalMemoryUsageMb() end)
	local okExec, exec = pcall(function() return identifyexecutor and table.concat({ identifyexecutor() }, " ") end)
	return {
		hubVersion = HUB_VERSION, build = HUB_BUILD, uiVersion = UI.Version, uiMin = UI_MIN_VERSION, stage = life.stage,
		uptime = now - life.startedAt, fps = hubStats.fps, memoryMb = okMem and mem or nil, luaKb = gcinfo(),
		executor = okExec and exec or nil, deps = deps,
		config = { file = configState.file, version = config.configVersion, target = Config.VERSION, ignored = configState.ignored,
			webhook = validWebhook(config.webhook), migrations = configState.migrations, clamped = configState.clamped,
			schema = Config.summary(config) },
		profile = { active = cfgSel and cfgSel.name or nil, format = Profiles.VERSION, unsaved = dirtyN,
			count = win.configs and #win.configs.list or 0 },
		tasksBySource = tasksBySource, lastClose = genv.ElHoyoHubLastClose, coordination = ownership.coordination(), mismatches = #comps:mismatches(),
		life = life.stats(), features = features,
		-- infraestructura e informativos siempre; funciones solo si no están apagadas (si no, la lista es enorme)
		components = (function()
			local out = {}
			for _, c in comps:snapshot() do
				if c.kind ~= "feature" or c.state ~= "Disabled" then table.insert(out, c) end
			end
			return out
		end)(),
		componentCounts = comps:counts(),
		catalog = { entities = catalogStats.total, version = catalogStats.version, schema = catalogStats.schema,
			wiki = catalogStats.wiki, contradictory = catalogStats.contradictory, invalid = catalogStats.invalid },
		errors = errs,
	}
end
local function secrets()
	return { player.Name, player.DisplayName, tostring(player.UserId), game.JobId }
end

-- 1.5.0: sección propia (antes una caja de Ajustes): esta caja y Componentes, Errores y avisos, Recursos
local dpage = pagesX.diag
section(dpage, L("Diagnóstico", "Diagnostics"), 1)
local rows = {}
for _, k in { "versions", "state", "perf", "resources", "components", "errors" } do rows[k] = note(dpage, " ") end
button(dpage, L("Copiar informe", "Copy report"), function()
	local text = Diagnostics.format(collect(), secrets())
	if setclipboard then
		setclipboard(text)
		log(T("Informe copiado (sin URL del webhook, nombre, UserId ni JobId)", "Report copied (no webhook URL, name, UserId or JobId)"), "ok", true)
	else
		log(T("Tu executor no permite copiar: el informe sale en la consola", "Your executor can't copy: the report goes to the console"), "warn")
		for l in text:gmatch("[^\n]+") do log(l) end
	end
end, L("Copia un informe del estado del hub para pedir ayuda. No incluye secretos ni tus datos.",
	"Copies a report of the hub's state to ask for help. It doesn't include secrets or your details."))
button(dpage, L("Ver errores", "Show errors"), function()
	local list = life.errors:recent(10)
	if #list == 0 then return log(T("Sin errores internos", "No internal errors"), "ok") end
	for _, e in list do log(string.format("x%d  %s", e.count, e.message), "warn") end
end, L("Escribe en la consola los últimos errores internos con cuántas veces han pasado.",
	"Writes the latest internal errors to the console with how many times they happened."))

-- Componentes: lo pedido frente a lo real y el motivo (o por qué no está disponible)
section(dpage, L("Componentes", "Components"), 2)
rows.compList = note(dpage, " ", 15)
section(dpage, L("Errores y avisos", "Errors and notices"), 2)
rows.errList = note(dpage, " ", 8)
section(dpage, L("Recursos y dependencias", "Resources and dependencies"), 1)
rows.resList = note(dpage, " ", 7)
local Notifications = import("Notifications")
local function componentLines(r)
	local out = {}
	for _, c in r.components do
		local line = string.format("%s  %s", tostring(c.state), tostring(c.name))
		if c.desiredState and c.matches == false then line ..= T("  (pedido ", "  (wanted ") .. c.desiredState .. ")" end
		if c.available == false then line ..= "  · " .. tostring(c.unavailableWhy)
		elseif c.lastError then line ..= "  · " .. tostring(c.lastError)
		elseif c.reason then line ..= "  · " .. tostring(c.reason) end
		table.insert(out, line)
	end
	return #out > 0 and table.concat(out, "\n") or "-"
end
local function errorLines(r)
	local out = {}
	for _, e in r.errors do
		table.insert(out, string.format("x%d %s%s", e.count or 1, e.source and ("[" .. tostring(e.source) .. "] ") or "", tostring(e.message)))
	end
	local logN = UI.NotificationLog
	if logN then
		for _, e in logN:history(4) do table.insert(out, Notifications.line(e, os.clock())) end
	end
	return #out > 0 and table.concat(out, "\n") or T("Sin errores ni avisos", "No errors or notices")
end
local function resourceLines(r)
	local deps, missing = {}, {}
	for name, ok in r.deps do table.insert(ok and deps or missing, name) end
	table.sort(missing)
	local tasks = {}
	for source, n in r.tasksBySource or {} do table.insert(tasks, tostring(source) .. " " .. n) end
	table.sort(tasks)
	return table.concat({
		string.format(T("Registrados %d (+%d al cerrar) · conexiones %d/%d · hilos %d", "Registered %d (+%d at close) · connections %d/%d · threads %d"),
			r.life.cleanups, r.life.finals or 0, r.life.connected, r.life.connections, r.life.threads),
		T("Tareas vivas: ", "Live tasks: ") .. (#tasks > 0 and table.concat(tasks, ", ") or "-"),
		T("Funciones del executor que faltan: ", "Missing executor functions: ") .. (#missing > 0 and table.concat(missing, ", ") or T("ninguna", "none")),
		(function()
			local c = r.coordination
			if not c then return "-" end
			local held = {}
			for res, who in c.held do table.insert(held, res .. "=" .. tostring(who)) end
			return string.format(T("Recursos: %s · denegadas %d · solapes %d · liberaciones tardías %d · referencias viejas %d", "Resources: %s · denied %d · overlaps %d · late releases %d · stale %d"),
				#held > 0 and table.concat(held, ", ") or T("libres", "free"), c.counts.denied or 0, c.counts.overlap or 0, c.counts.late_release or 0, (c.counts.stale or 0) + (c.counts.stale_use or 0))
		end)(),
		T("Cierre anterior: ", "Previous close: ") .. (r.lastClose and (#(r.lastClose.components or {}) == 0 and T("limpio", "clean") or table.concat(r.lastClose.components, ", ")) or "-"),
	}, "\n")
end
-- El refresco de la caja es una tarea del componente Diagnostics (contrato): se cancela sola al cerrar
local diagComp = comps:get("Diagnostics")
diagComp.impl = { start = function(c) c:spawn(function(token)
	while life.alive and token.alive() do
		if main.Visible then -- con la ventana oculta no se recalcula nada
			local r = collect()
			rows.versions.Text = string.format("Hub %s · UI v%s · build %s", r.hubVersion, tostring(r.uiVersion), tostring(r.build))
			rows.state.Text = T("Estado: ", "State: ") .. tostring(r.stage) .. " · config " .. tostring(r.config.file) .. " v" .. tostring(r.config.version)
			rows.perf.Text = string.format("FPS %d · %s MB · Lua %d KB", r.fps or 0, r.memoryMb and tostring(math.floor(r.memoryMb)) or "?", math.floor(r.luaKb))
			rows.resources.Text = string.format(T("Recursos %d · conexiones %d/%d · hilos %d", "Resources %d · connections %d/%d · threads %d"),
				r.life.cleanups, r.life.connected, r.life.connections, r.life.threads)
			local parts = {}
			for _, st in { "Running", "Waiting", "Ready", "Error", "Unavailable" } do
				if r.componentCounts[st] then table.insert(parts, st .. " " .. r.componentCounts[st]) end
			end
			rows.components.Text = T("Componentes: ", "Components: ") .. table.concat(parts, " · ")
			rows.errors.Text = T("Errores: ", "Errors: ") .. #r.errors .. (r.life.errorTotal > #r.errors and (" (" .. r.life.errorTotal .. T(" en total)", " in total)")) or "")
			if win.current == dpage.tab then -- las listas largas solo con la sección abierta
				rows.compList.Text = componentLines(r)
				rows.errList.Text = errorLines(r)
				rows.resList.Text = resourceLines(r)
			end
		end
		task.wait(2)
	end
end) end }
diagComp:start()
end)()

------------------------------------------------------------------ Bounty (NPCs) (FARMEO, 1.5.1)
-- Farmeo de NPCs alrededor de un punto de referencia, para un entorno de pruebas propio. SOLO NPCs del juego
-- (Workspace.Alive.NPCs): NpcFarm.pickTarget descarta cualquier personaje de jugador. Lógica en NpcFarm (probada con
-- simulaciones); aquí solo se lee el juego y se actúa. Reutiliza: equipWeapon y attack (Auto Quest), teclas como
-- Auto Boss, zona segura, turnos de Ownership ("move" y "hand"), Components (estado) y Config (persistencia).
-- Coordinación: con la zona segura activa, quien no tiene el movimiento es devuelto arriba; por eso Bounty se queda
-- el turno mientras está en el punto y lo CEDE en cuanto otra función lo pide (Auto Sam, venta…).
;(function() -- función propia: sus locales no cuentan para el límite de ElHoyoHubMain
local NpcFarm = import("NpcFarm")
local Protection = import("Protection")
local page = pagesX.bounty
local OWNER = NpcFarm.OWNER
local KEY = "Bounty: farmear NPCs" -- nombre del interruptor (y de su componente)
local enabled = false
local state = { phase = "idle" }
local last = { reason = T("apagado", "off"), target = nil, yielded = nil }
local holding = false

local function pointVec()
	local p = config.bountyPoint
	if type(p) == "table" and tonumber(p[1]) and tonumber(p[2]) and tonumber(p[3]) then return { x = p[1], y = p[2], z = p[3] } end
	return nil
end
local function candidates()
	local alive = workspace:FindFirstChild("Alive")
	local npcs = alive and alive:FindFirstChild("NPCs")
	local playersFolder = alive and alive:FindFirstChild("Players")
	local out = {}
	for _, model in npcs and npcs:GetChildren() or {} do
		local hum = model:FindFirstChildOfClass("Humanoid")
		local root = model:FindFirstChild("HumanoidRootPart")
		table.insert(out, { model = model, name = model.Name,
			isPlayer = Players:GetPlayerFromCharacter(model) ~= nil, -- nunca un jugador
			inPlayersFolder = playersFolder ~= nil and model:IsDescendantOf(playersFolder),
			health = hum and hum.Health or 0, position = root and { x = root.Position.X, y = root.Position.Y, z = root.Position.Z } or nil })
	end
	return out
end
local function take()
	-- el turno tiene que seguir siendo nuestro (la Huida puede habérselo quitado)
	if holding and ownership.holder("move") == OWNER then return true end
	holding = claimMove(OWNER)
	return holding
end
local function drop()
	if holding then releaseMove(OWNER) end
	holding = false
end
local function pressSkills()
	for _, key in NpcFarm.skills(config.bountySkills) do
		local code = Enum.KeyCode[key]
		if code then
			VIM:SendKeyEvent(true, code, false, game)
			VIM:SendKeyEvent(false, code, false, game)
			task.wait(0.15)
		end
	end
end

section(page, L("Bounty (solo NPCs)", "Bounty (NPCs only)"), 1)
toggle(page, L(KEY, "Bounty: farm NPCs"), function(on)
	enabled = on
	if not on then drop() end
	log("Bounty (NPCs) " .. (on and "ON" or "OFF"))
end, L("Ataca a los NPCs del juego cerca del punto de referencia con tu arma y las habilidades elegidas. Nunca elige jugadores. Con vida baja se retira a la zona segura y vuelve al recuperarse.",
	"Attacks the game's NPCs near the reference point with your weapon and the chosen skills. Never picks players. With low health it retreats to the safe zone and comes back after recovering."))
button(page, L("Guardar punto de referencia aquí", "Save reference point here"), function()
	local hrp = getHRP()
	if not hrp then return log(T("Sin personaje", "No character"), "warn") end
	local p = hrp.Position
	config.bountyPoint = { math.floor(p.X * 10) / 10, math.floor(p.Y * 10) / 10, math.floor(p.Z * 10) / 10 }
	saveConfig()
	log(string.format(T("Bounty: punto guardado (%d, %d, %d)", "Bounty: point saved (%d, %d, %d)"), p.X, p.Y, p.Z), "ok", true)
end, L("Se guarda en la configuración: tras reaparecer o recuperarte vuelves aquí.", "Saved in the settings: after respawning or recovering you come back here."))
button(page, L("Borrar punto de referencia", "Clear reference point"), function()
	config.bountyPoint = nil
	saveConfig()
	log(T("Bounty: punto borrado", "Bounty: point cleared"), "ok")
end)
local function statusText()
	local p = pointVec()
	local c = comps:get(KEY)
	return table.concat({
		T("Punto: ", "Point: ") .. (p and string.format("%d, %d, %d", p.x, p.y, p.z) or T("sin guardar", "not saved")),
		T("Estado: ", "State: ") .. tostring(c and c.state or "-") .. " · " .. tostring(last.reason),
		T("Objetivo: ", "Target: ") .. tostring(last.target and last.target.name or "-"),
		T("Último error: ", "Last error: ") .. tostring(c and c.lastError or "-"),
		T("Coordinación: ", "Coordination: ") .. (last.yielded and (T("cede a ", "yields to ") .. last.yielded) or
			(holding and T("tiene el movimiento", "holds movement") or T("sin turno", "no turn"))),
	}, "\n")
end
local statusLabel = note(page, statusText, 5)

section(page, L("Habilidades y vida", "Skills and health"), 2)
multi(page, L("Teclas de habilidad", "Skill keys"), NpcFarm.KEYS, config.bountySkills, function(chosen)
	local list = {}
	for i in NpcFarm.KEYS do list[i] = chosen[i] == true end
	config.bountySkills = list
	saveConfig()
end, L("Qué teclas de habilidad se pulsan (lo que hace cada una depende de tu arma o fruta). Ninguna = solo golpes.",
	"Which skill keys are pressed (what each one does depends on your weapon or fruit). None = basic hits only."))
local function choice(text, list, key, suffix, desc)
	local names = {}
	for i, v in list do names[i] = v .. suffix end
	combo(page, text, names, math.clamp(tonumber(config[key]) or 2, 1, #list), function(i)
		config[key] = i
		saveConfig()
	end, desc)
end
choice(L("Intervalo de habilidades", "Skill interval"), NpcFarm.INTERVALS, "bountyInterval", " s",
	L("Segundos entre una tanda de habilidades y la siguiente.", "Seconds between one round of skills and the next."))
choice(L("Radio de búsqueda", "Search radius"), NpcFarm.RADII, "bountyRadius", " studs",
	L("Solo NPCs a esta distancia del punto de referencia.", "Only NPCs within this distance of the reference point."))
choice(L("Retirarse con vida bajo", "Retreat below health"), NpcFarm.LOW, "bountyLow", "%",
	L("Con menos vida se va a la zona segura (tiene que estar activa en Automatización).", "Below this it goes to the safe zone (it must be on in Automation)."))
choice(L("Volver con vida", "Return at health"), NpcFarm.RECOVER, "bountyRecover", "%",
	L("Vuelve al punto cuando se recupera hasta aquí.", "Returns to the point once health is back to this."))
note(page, L("Solo para tu entorno de pruebas: el objetivo es siempre un NPC del juego (Workspace.Alive.NPCs), nunca un jugador.",
	"Only for your test environment: the target is always a game NPC (Workspace.Alive.NPCs), never a player."))

life.spawnAs(KEY, function()
	while life.alive do
		task.wait(0.25)
		local char = player.Character
		-- 1.5.3: la misma vida que la Huida (fuente elegida); si la Huida aún no ha leído, el Humanoid
		local reading = hubShared.health or Protection.read(char and char:FindFirstChildOfClass("Humanoid"), nil)
		local point = pointVec()
		local target = enabled and point and NpcFarm.pickTarget(candidates(), point, NpcFarm.pick(NpcFarm.RADII, config.bountyRadius)) or nil
		-- ceder el turno si otra función lo ha pedido hace nada (Sam, venta…): esta vuelta no se mueve
		local wants = holding and ownership.wanted("move", OWNER, 2) or nil
		if wants then drop() end
		last.yielded = wants
		local res = NpcFarm.step(state, { enabled = enabled, point = point, alive = reading.ok and reading.health > 0,
			character = char, pct = reading.pct, low = NpcFarm.pick(NpcFarm.LOW, config.bountyLow),
			recover = NpcFarm.pick(NpcFarm.RECOVER, config.bountyRecover), target = target,
			moveHolder = ownership.holder("move") ~= OWNER and busy or nil, safeZone = safePart ~= nil, now = os.clock(),
			interval = NpcFarm.pick(NpcFarm.INTERVALS, config.bountyInterval) })
		last.reason, last.target = res.reason, target
		local comp = comps:get(KEY)
		if comp and enabled and comp.state ~= "Error" then comp:set(res.state, res.reason) end
		if res.action == "stop" or (res.action == "wait" and not res.stay) then
			drop()
		elseif res.action == "retreat" or res.action == "recover" then
			drop() -- sin turno, la zona segura te mantiene arriba
			if res.action == "retreat" then goSafe() end
		elseif res.action == "return" then
			if take() then teleport(Vector3.new(point.x, point.y + 3, point.z)) end
		elseif res.action == "fight" and take() then
			local other = ownership.inUse("hand", OWNER)
			if other then
				ownership.event("yielded", "hand", OWNER, other)
			else
				local done = ownership.use("hand", OWNER)
				equipWeapon(nil)
				attack(target.model)
				if res.useSkills then pressSkills() end
				done()
			end
		end
		if main.Visible and win.current == page.tab and statusLabel then statusLabel.Text = statusText() end
	end
end)
life.add(function() drop() end)
end)()

------------------------------------------------------------------ Panel (inicio, 1.5.0)
-- Pantalla principal: estado del hub, accesos rápidos, favoritos, actividad y errores recientes. Todo sale de lo que
-- ya existe (Lifecycle, Components, perfiles, notificaciones): no se inventa ninguna cifra.
;(function() -- función propia: sus locales no cuentan para el límite de ElHoyoHubMain
local Favorites = import("Favorites")
local Notifications = import("Notifications")
local page = pagesX.dash
local labels = {}
local favSel = 1
config.favorites = Favorites.normalize(config.favorites, import("Profiles").ALIASES)

local function shown(en) -- texto de un control en el idioma actual (las traducciones las registra uiText)
	local t = UI.Translations and UI.Translations[en]
	if LANG == "es" and t and t[1] then return t[1] end
	return en
end
local function favName(key)
	local entry = win.findKey and win:findKey(key)
	if not entry then return key:match("[^/]+$") .. T("  (ya no existe)", "  (no longer exists)") end
	return shown(entry.label) .. "  ·  " .. shown(entry.tabName or "")
end

-- favoritos: el buscador los marca con ★ y los cambia con Ctrl+Enter
function win.isFavorite(key) return Favorites.has(config.favorites, key) end
function win.toggleFavorite(key)
	local _, added = Favorites.toggle(config.favorites, key)
	saveConfig()
	log((added and T("Favorito añadido: ", "Favourite added: ") or T("Favorito quitado: ", "Favourite removed: ")) .. favName(key), "ok", true)
	if labels.refresh then labels.refresh() end
end

local function statusText()
	local stats = life.stats()
	local counts = comps:counts()
	local active, unsaved = nil, 0
	if pagesX.profilesStatus then active, unsaved = pagesX.profilesStatus() end
	local okMem, mem = pcall(function() return game:GetService("Stats"):GetTotalMemoryUsageMb() end)
	local parts = {}
	for _, st in { "Running", "Waiting", "Ready", "Error", "Unavailable" } do
		if counts[st] then table.insert(parts, st .. " " .. counts[st]) end
	end
	local mismatch = #comps:mismatches()
	return table.concat({
		string.format("El Hoyo Hub %s · build %s · UI v%s", HUB_VERSION, tostring(HUB_BUILD), tostring(UI.Version)),
		string.format(T("Estado: %s · carga %s", "State: %s · load %s"), tostring(life.stage), stats.initTime and string.format("%.2f s", stats.initTime) or "…"),
		T("Perfil: ", "Preset: ") .. tostring(active or "-") .. (unsaved > 0 and string.format(T(" · %d sin guardar", " · %d unsaved"), unsaved) or ""),
		T("Componentes: ", "Components: ") .. table.concat(parts, " · ") .. (mismatch > 0 and string.format(T(" · %d distintos de lo pedido", " · %d not as requested"), mismatch) or ""),
		T("Señales del juego: ", "Game signals: ") .. (#missingRemotes == 0 and "OK" or (#missingRemotes .. T(" no encontradas", " missing"))),
		string.format("FPS %d · %s MB", hubStats.fps or 0, okMem and tostring(math.floor(mem)) or "?"),
	}, "\n")
end
local function favText()
	if #config.favorites == 0 then
		return T("Sin favoritos. Ctrl+K, busca una función y pulsa Ctrl+Enter para añadirla.",
			"No favourites. Ctrl+K, search a feature and press Ctrl+Enter to add it.")
	end
	favSel = math.clamp(favSel, 1, #config.favorites)
	local out = {}
	for i, key in config.favorites do
		if i > 8 then table.insert(out, "… +" .. (#config.favorites - 8)); break end
		table.insert(out, (i == favSel and "▶ " or "    ") .. favName(key))
	end
	return table.concat(out, "\n")
end
local function activityText()
	local logN = UI.NotificationLog
	local list = logN and logN:history(6) or {}
	if #list == 0 then return T("Sin actividad todavía", "No activity yet") end
	local out = {}
	for _, e in list do table.insert(out, Notifications.line(e, os.clock())) end
	return table.concat(out, "\n")
end
local function errorsText()
	local list = life.errors:recent(4)
	if #list == 0 then return T("Sin errores", "No errors") end
	local out = {}
	for _, e in list do table.insert(out, string.format("x%d %s%s", e.count, e.source and ("[" .. tostring(e.source) .. "] ") or "", e.message)) end
	return table.concat(out, "\n")
end
function labels.refresh()
	if labels.status then labels.status.Text = statusText() end
	if labels.fav then labels.fav.Text = favText() end
	if labels.activity then labels.activity.Text = activityText() end
	if labels.errors then labels.errors.Text = errorsText() end
end
local function go(p) win:selectTab(p.tab) end

page.tab:Columns({ 1, 1 })
section(page, L("Estado", "Status"), 1)
labels.status = note(page, statusText, 6)
section(page, L("Accesos rápidos", "Quick access"), 1)
button(page, L("Buscar (Ctrl+K)", "Search (Ctrl+K)"), function()
	if win.search then win.search.setOpen(true) end
end, L("Busca funciones, ajustes, perfiles y entidades del catálogo. Elegir un resultado solo lleva hasta él.",
	"Searches features, settings, presets and catalog entries. Picking a result only takes you there."))
button(page, L("Explorador del juego", "Game explorer"), function() go(pagesX.explorer) end)
button(page, L("Centro de perfiles", "Presets"), function() go(pagesX.profiles) end)
button(page, L("Diagnóstico", "Diagnostics"), function() go(pagesX.diag) end)
button(page, L("Ajustes", "Settings"), function() go(pageSettings) end)
button(page, L("Mostrar / ocultar consola", "Show / hide console"), function() setConsole(not console.shown()) end)

section(page, L("Favoritos", "Favourites"), 2)
labels.fav = note(page, favText, 9)
button(page, L("Ir al favorito", "Go to favourite"), function()
	local key = config.favorites[favSel]
	if not key then return log(T("No hay favoritos", "No favourites"), "info") end
	if not win:goToKey(key) then log(T("Ese control ya no existe: quítalo de favoritos", "That control no longer exists: remove it"), "warn") end
end, L("Lleva al control original (no lo pulsa).", "Takes you to the original control (it doesn't press it)."))
button(page, L("Favorito siguiente", "Next favourite"), function()
	if #config.favorites > 0 then favSel = (favSel % #config.favorites) + 1; labels.refresh() end
end)
button(page, L("Subir favorito", "Move favourite up"), function()
	local key = config.favorites[favSel]
	if key and Favorites.move(config.favorites, key, -1) then favSel -= 1; saveConfig(); labels.refresh() end
end)
button(page, L("Quitar favorito", "Remove favourite"), function()
	local key = config.favorites[favSel]
	if key then win.toggleFavorite(key) end
end)
section(page, L("Actividad reciente", "Recent activity"), 2)
labels.activity = note(page, activityText, 6)
section(page, L("Errores recientes", "Recent errors"), 2)
labels.errors = note(page, errorsText, 4)

-- refresco cada 2 s, solo con el Panel abierto y la ventana visible (tarea del componente: se cancela al cerrar)
local dash = comps:register(T("Panel", "Dashboard"), { kind = "info", impl = { start = function(c) c:spawn(function(token)
	while life.alive and token.alive() do
		if main.Visible and win.current == page.tab then labels.refresh() end
		task.wait(2)
	end
end) end } })
dash:start()

-- Punto de estado de cada interruptor = estado REAL de su componente (Waiting = encendida sin confirmar, Error…)
comps:onChange(function(c)
	if c.kind ~= "feature" then return end
	local t = toggles[c.name]
	if t and t.control and t.control.SetStatus then t.control:SetStatus(c.state) end
end)
end)()

------------------------------------------------------------------ Ocultar, cursor
-- Mostrar / ocultar con la tecla elegida (la librería no la gestiona: ToggleKey = false)
table.insert(cleanup, UIS.InputBegan:Connect(function(input)
	if waitingKey or UIS:GetFocusedTextBox() then return end
	if input.KeyCode.Name == config.key then main.Visible = not main.Visible end
	-- 1.5.0: Ctrl+K (config.searchKey) abre el buscador; Ctrl+RePág / Ctrl+AvPág cambian de sección
	if UIS:IsKeyDown(Enum.KeyCode.LeftControl) or UIS:IsKeyDown(Enum.KeyCode.RightControl) then
		if input.KeyCode.Name == (config.searchKey or "K") and win.search then
			main.Visible = true
			win.search.setOpen(true)
		elseif input.KeyCode == Enum.KeyCode.PageUp or input.KeyCode == Enum.KeyCode.PageDown then
			win:stepTab(input.KeyCode == Enum.KeyCode.PageDown and 1 or -1)
		end
	end
end))

-- Cursor: el juego a veces lo esconde. Encima del hub o la consola se fuerza a que se vea.
table.insert(cleanup, game:GetService("RunService").RenderStepped:Connect(function()
	if overOurGui() then UIS.MouseIconEnabled = true end
end))

------------------------------------------------------------------ Migraciones
-- Config.MIGRATIONS: 2 = webhooks fuera de los perfiles; 3 = funciones retiradas en 1.3.2 y .bak sin secretos.
do
	local applied = Config.migrate({ fs = diskFs, json = json, path = CONFIG_FILE, profileDirs = PROFILE_DIRS,
		config = config, notes = bootNotes })
	configState.migrations = applied -- para el Diagnóstico
	if #applied > 0 then saveConfig() end
end

------------------------------------------------------------------ Inicio
if not life.alive then return closeHub() end -- otra ejecución cerró este hub mientras cargaba: no dejar nada a medias
fitBoxes()
win:Finish() -- coloca todo y carga el último perfil usado (eso enciende sus funciones)
comps:register(T("Señales del juego", "Game signals"), { state = "Ready",
	reason = #missingRemotes == 0 and "OK" or (#missingRemotes .. T(" no encontradas: ", " missing: ") .. table.concat(missingRemotes, ", ")) })
comps:refresh()
life.stage = "ready"
life.readyAt = os.clock()
comps:get("Hub"):set("Ready", string.format("%.2f s", life.readyAt - life.startedAt))
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
	task.delay(30, function() sg:Destroy() end) -- fuera de ElHoyoHubMain: aquí no hay life
end
