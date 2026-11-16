--- Очередь загрузок депо.
---
--- Как это работает:
---   * сам Steam качает депо командой консоли download_depot;
---   * команду нельзя выполнить из Lua — она живёт в JS-контексте клиента,
---     поэтому бэкенд просит фронтенд вызвать SteamClient.Console.ExecCommand;
---   * прогресс считаем по размеру файлов на диске (Steam не отдаёт его наружу);
---   * очередь двигает фронтенд своим таймером через tick() — так бэкенд
---     никогда не блокируется ожиданием (никаких sleep в RPC).

local fs = require("fs")
local millennium = require("millennium")
local util = require("util")
local steam = require("steam")

local jobs = {}

local S = {
	batch = nil,
	queue = {},
	active = nil,
	done = {},
	failed = {},
}

local READY_RATIO = 0.995 -- считаем готовым при 99.5% ожидаемого размера
local STABLE_SEC = 25 -- или если размер не растёт столько секунд
local ZERO_TIMEOUT = 300 -- 5 минут без единого байта -> ошибка

local function exec_console(command)
	local ok, res = pcall(millennium.call_frontend_method, "execConsole", { command })
	if not ok then
		return false, tostring(res)
	end
	if res == nil then
		return false, "фронтенд не ответил (Steam UI ещё не загружен?)"
	end
	if res == false then
		return false, "SteamClient.Console.ExecCommand недоступен в этом клиенте"
	end
	return true
end

local function measure(steamapps, appid, depotid)
	local content = steam.content_dir(steamapps, appid, depotid)
	local bytes = util.dir_stats(content)
	local staging = 0
	for _, dir in ipairs(steam.staging_dirs(steamapps, appid, depotid)) do
		staging = staging + (util.dir_stats(dir))
	end
	return bytes, staging, content
end

local function start_row(row)
	local b = S.batch
	local command = string.format("download_depot %s %s %s", b.appid, row.depotid, row.gid)
	local bytes, staging, content = measure(b.steamapps, b.appid, row.depotid)
	local ok, err = exec_console(command)
	if not ok then
		row.status = "failed"
		row.error = err
		S.failed[#S.failed + 1] = row
		util.err("депо " .. row.depotid .. ": " .. tostring(err))
		return
	end
	row.status = "downloading"
	row.started = util.now()
	row.content_dir = content
	row.bytes = bytes
	row.staging = staging
	row.last_change = util.now()
	row.expected = tonumber(row.size) or 0
	S.active = row
	util.log("→ " .. command .. "  (ожидаем " .. util.fmt_bytes(row.expected) .. ")")
end

--- Запустить новую пачку загрузок по плану.
function jobs.start(p, acf, mode)
	if S.active then
		return nil, "уже идёт загрузка депо " .. tostring(S.active.depotid) .. " — дождись или отмени"
	end
	if not acf then
		return nil, "игра не установлена в этой библиотеке: не знаю, куда качать"
	end
	S.batch = {
		id = util.now(),
		appid = p.appid,
		app_name = p.app_name,
		label = p.label,
		branch = p.branch,
		mode = mode or "download",
		library = acf.library,
		steamapps = acf.steamapps,
		install_dir = acf.install_dir,
		installdir = acf.installdir,
		created = util.now(),
		total_download = p.total_download,
		total_size = p.total_size,
		depot_count = #p.depots,
	}
	S.queue, S.done, S.failed = {}, {}, {}
	for _, row in ipairs(p.depots) do
		S.queue[#S.queue + 1] = {
			depotid = row.depotid,
			gid = row.gid,
			size = row.size,
			download = row.download,
			language = row.language,
			same_as_installed = row.same_as_installed,
			status = "queued",
		}
	end
	util.log(string.format("пачка #%s: %s — %s, депо: %d, режим: %s",
		tostring(S.batch.id), tostring(p.app_name), tostring(p.label), #S.queue, S.batch.mode))
	return jobs.tick()
end

--- Двинуть очередь и померить прогресс. Вызывается фронтендом раз в ~2 сек.
function jobs.tick()
	local b = S.batch
	if not b then
		return jobs.snapshot()
	end

	local row = S.active
	if row then
		local bytes, staging, content = measure(b.steamapps, b.appid, row.depotid)
		local now = util.now()
		if bytes ~= row.bytes then
			row.last_change = now
		end
		row.bytes, row.staging, row.content_dir = bytes, staging, content
		local expected = row.expected
		local elapsed = now - (row.started or now)
		local idle = now - (row.last_change or now)

		local ready = false
		if expected > 0 and bytes >= expected * READY_RATIO then
			ready = true
		elseif bytes > 0 and staging == 0 and idle >= STABLE_SEC then
			ready = true
		end

		if ready then
			row.status = "ready"
			row.finished = now
			S.done[#S.done + 1] = row
			S.active = nil
			util.log(string.format("✓ депо %s готово (%s за %d c)", row.depotid, util.fmt_bytes(bytes), elapsed))
		elseif bytes == 0 and staging == 0 and elapsed >= ZERO_TIMEOUT then
			row.status = "failed"
			row.error = "Steam ничего не скачал за 5 минут. Частые причины: разработчик запретил старые манифесты, депо/DLC не куплен, или нет места на диске."
			row.finished = now
			S.failed[#S.failed + 1] = row
			S.active = nil
			util.err("депо " .. row.depotid .. ": " .. row.error)
		end
	end

	if not S.active and #S.queue > 0 then
		local next_row = table.remove(S.queue, 1)
		start_row(next_row)
	end

	return jobs.snapshot()
end

function jobs.snapshot()
	local b = S.batch
	if not b then
		return { active_batch = false, log = util.log_tail(40) }
	end
	local total_expected, total_bytes = 0, 0
	local rows = {}
	local function add(row)
		total_expected = total_expected + (tonumber(row.size) or 0)
		total_bytes = total_bytes + (tonumber(row.bytes) or (row.status == "ready" and tonumber(row.size) or 0) or 0)
		rows[#rows + 1] = {
			depotid = row.depotid,
			gid = row.gid,
			status = row.status,
			bytes = tonumber(row.bytes) or 0,
			expected = tonumber(row.size) or 0,
			staging = tonumber(row.staging) or 0,
			content_dir = row.content_dir,
			error = row.error,
			language = row.language,
		}
	end
	for _, r in ipairs(S.done) do add(r) end
	for _, r in ipairs(S.failed) do add(r) end
	if S.active then add(S.active) end
	for _, r in ipairs(S.queue) do add(r) end

	local finished = #S.done + #S.failed
	return {
		active_batch = true,
		batch = {
			id = b.id,
			appid = b.appid,
			app_name = b.app_name,
			label = b.label,
			branch = b.branch,
			mode = b.mode,
			library = b.library,
			steamapps = b.steamapps,
			install_dir = b.install_dir,
			content_root = fs.join(b.steamapps, "content", "app_" .. b.appid),
			depot_count = b.depot_count,
			total_download = b.total_download,
			total_size = b.total_size,
		},
		rows = rows,
		done_count = #S.done,
		failed_count = #S.failed,
		queued_count = #S.queue,
		finished_count = finished,
		all_ready = (finished == b.depot_count and #S.failed == 0 and S.active == nil and #S.queue == 0),
		is_running = (S.active ~= nil or #S.queue > 0),
		progress = total_expected > 0 and math.min(1, total_bytes / total_expected) or 0,
		total_bytes = total_bytes,
		total_expected = total_expected,
		log = util.log_tail(40),
	}
end

--- Отменить очередь. ВАЖНО: текущий депо Steam докачает сам —
--- надёжной команды отмены именно download_depot у клиента нет.
function jobs.cancel()
	local dropped = #S.queue
	S.queue = {}
	if S.active then
		S.active.status = "cancelled"
		S.failed[#S.failed + 1] = S.active
		S.active = nil
	end
	util.warn("очередь остановлена (снято депо: " .. dropped .. "); текущая загрузка в Steam может продолжиться")
	return jobs.snapshot()
end

function jobs.reset()
	S.batch, S.queue, S.active, S.done, S.failed = nil, {}, nil, {}, {}
	return jobs.snapshot()
end

--- Ручная отметка «готово» — если эвристика не сработала, а файлы на месте.
function jobs.mark_ready(depotid)
	local row = S.active
	if row and tostring(row.depotid) == tostring(depotid) then
		row.status = "ready"
		row.finished = util.now()
		S.done[#S.done + 1] = row
		S.active = nil
		util.log("депо " .. depotid .. " отмечено готовым вручную")
	end
	return jobs.snapshot()
end

function jobs.ready_depots()
	local out = {}
	for _, r in ipairs(S.done) do
		if r.status == "ready" then
			out[#out + 1] = r
		end
	end
	return out
end

function jobs.current_batch()
	return S.batch
end

return jobs
