--- Общая база версий: buildid + манифесты депо (depotid -> GID).
---
--- Зачем: история SteamRaw начинается в сентябре 2026, а SteamDB парсить нельзя.
--- Значит, историю нужно копить самим: складывать в базу то, что уже известно
--- (сборки SteamRaw, реконструированные манифесты) и то, что нашлось на
--- компьютерах пользователей (локальный сбор).
---
--- Где живёт база:
---   1) resources/versions-db.json — общая база, едет в .star (собирается
---      скриптом tools/build-versions-db.mjs из SteamRaw + steamcmd.net);
---   2) %LOCALAPPDATA%\VersionRollback\versions-db.json — локальная копия:
---      сюда попадает всё, что собрано на этой машине, и всё, что прислали
---      пользователи. Приоритет у локальной копии.
---
--- Формат:
--- {
---   "version": 1,
---   "updated": 1760000000,
---   "apps": {
---     "1091500": {
---       "name": "Cyberpunk 2077",
---       "builds": { "20000001": { "ts": 1760000000, "branch": "public",
---                                "depots": { "1091501": "3524634124112875626" } } },
---       "manifests": { "1091501:3524634124112875626": { "depotid": "1091501",
---                                "gid": "3524634124112875626", "ts": 1760000000 } }
---     }
---   }
--- }
---
--- ВАЖНО: только метаданные. Никаких ключей депо и обхода прав — скачивание
--- по-прежнему идёт через Steam и только для того, что есть на аккаунте.

local fs = require("fs")
local millennium = require("millennium")
local util = require("util")

local versiondb = {}

versiondb.PACKAGED = "resources/versions-db.json"
versiondb.USER_FILE = "versions-db.json"
versiondb.VERSION = 1

local function empty_db()
	return { version = versiondb.VERSION, updated = 0, apps = {} }
end

local function normalize_db(raw)
	if type(raw) ~= "table" then
		return nil
	end
	if type(raw.apps) ~= "table" then
		raw.apps = {}
	end
	raw.version = raw.version or versiondb.VERSION
	raw.updated = tonumber(raw.updated) or 0
	for _, app in pairs(raw.apps) do
		if type(app) == "table" then
			app.builds = type(app.builds) == "table" and app.builds or {}
			app.manifests = type(app.manifests) == "table" and app.manifests or {}
		end
	end
	return raw
end

--- Общая база из ресурсов плагина (может отсутствовать — не ошибка).
function versiondb.packaged()
	local read = millennium.assets and millennium.assets.read
	if not read then
		return nil
	end
	local ok, raw = pcall(read, versiondb.PACKAGED)
	if not ok or not raw then
		return nil
	end
	return normalize_db(util.decode_json(raw))
end

--- Путь локальной копии базы.
function versiondb.user_path()
	return fs.join(util.data_dir(), versiondb.USER_FILE)
end

--- Локальная копия базы с диска.
function versiondb.user()
	return normalize_db(util.read_json_file(versiondb.user_path()))
end

--- Сохранить локальную копию базы.
function versiondb.save_user(db)
	local normalized = normalize_db(db)
	normalized.updated = util.now()
	return util.write_json_file(versiondb.user_path(), normalized)
end

--- Слить две базы: вторая дополняет первую (по сборкам и манифестам).
--- Чистая функция — покрыта тестом.
function versiondb.merge(base, extra)
	local out = normalize_db(base) or empty_db()
	if type(extra) ~= "table" then
		return out
	end
	for appid, app in pairs(extra.apps or {}) do
		local target = out.apps[appid]
		if type(target) ~= "table" then
			target = { name = app.name, builds = {}, manifests = {} }
			out.apps[appid] = target
		end
		if app.name and not target.name then
			target.name = app.name
		end
		for buildid, build in pairs(app.builds or {}) do
			local tb = target.builds[buildid]
			if type(tb) ~= "table" then
				tb = { ts = 0, branch = "public", depots = {}, complete = build.complete ~= false }
				target.builds[buildid] = tb
			end
			tb.ts = math.max(tonumber(tb.ts) or 0, tonumber(build.ts) or 0)
			if build.branch then
				tb.branch = tostring(build.branch)
			end
			-- «неполная» сборка неполной не перестаёт быть: флаг только ухудшается.
			if build.complete == false then
				tb.complete = false
			end
			for depotid, gid in pairs(build.depots or {}) do
				local norm = util.norm_gid(gid)
				if norm and not tb.depots[depotid] then
					tb.depots[depotid] = norm
				end
			end
		end
		for key, manifest in pairs(app.manifests or {}) do
			if not target.manifests[key] then
				target.manifests[key] = manifest
			end
		end
	end
	out.updated = math.max(tonumber(out.updated) or 0, tonumber(extra.updated) or 0)
	return out
end

--- Полная база: общая (из ресурса) + локальная копия.
function versiondb.load()
	local db = versiondb.packaged() or empty_db()
	return versiondb.merge(db, versiondb.user() or {})
end

--- Сборки приложения из базы: [{ buildid, ts, branch, depots, source = "db" }]
function versiondb.builds(db, appid)
	local id = util.norm_id(appid)
	local out = {}
	local app = id and (db.apps or {})[id]
	if type(app) ~= "table" then
		return out
	end
	for buildid, build in pairs(app.builds or {}) do
		local depots = {}
		for depotid, gid in pairs(build.depots or {}) do
			depots[depotid] = tostring(gid)
		end
		out[#out + 1] = {
			buildid = tostring(buildid),
			ts = tonumber(build.ts) or 0,
			branch = tostring(build.branch or "public"),
			depots = depots,
			source = "db",
			-- complete=false: сборка старше начала истории SteamRaw, снимок манифестов неполный
			complete = build.complete ~= false,
		}
	end
	table.sort(out, function(a, b)
		if a.ts ~= b.ts then
			return a.ts > b.ts
		end
		return a.buildid > b.buildid
	end)
	return out
end

--- Есть ли такой манифест в базе (пул манифестов приложения)?
function versiondb.has_manifest(db, appid, depotid, gid)
	local id = util.norm_id(appid)
	local norm = util.norm_gid(gid)
	if not id or not norm then
		return false
	end
	local app = (db.apps or {})[id]
	if type(app) ~= "table" then
		return false
	end
	local key = tostring(depotid) .. ":" .. norm
	if app.manifests and app.manifests[key] then
		return true
	end
	for _, build in pairs(app.builds or {}) do
		if tostring((build.depots or {})[tostring(depotid)] or "") == norm then
			return true
		end
	end
	return false
end

--- Добавить манифест в пул базы (без сборки).
--- @return boolean true — манифест был новым (добавлен), false — уже был
function versiondb.add_manifest(db, appid, depotid, gid, ts)
	local id = util.norm_id(appid)
	local norm = util.norm_gid(gid)
	if not id or not norm then
		return false
	end
	local app = db.apps[id]
	if type(app) ~= "table" then
		app = { name = nil, builds = {}, manifests = {} }
		db.apps[id] = app
	end
	app.manifests = app.manifests or {}
	app.builds = app.builds or {}
	local key = tostring(depotid) .. ":" .. norm
	if app.manifests[key] then
		return false
	end
	app.manifests[key] = { depotid = tostring(depotid), gid = norm, ts = tonumber(ts) or 0 }
	return true
end

--- Есть ли такая сборка в базе.
function versiondb.has_build(db, appid, buildid)
	local id = util.norm_id(appid)
	if not id or not buildid then
		return false
	end
	local app = (db.apps or {})[id]
	if type(app) ~= "table" then
		return false
	end
	return app.builds and app.builds[tostring(buildid)] ~= nil
end

--- Добавить сборку (снимок манифестов) в базу.
--- @param complete boolean|nil false — снимок неполный (сборка старше истории)
function versiondb.add_build(db, appid, buildid, branch, ts, depots, complete)
	local id = util.norm_id(appid)
	if not id or not buildid then
		return false
	end
	local app = db.apps[id]
	if type(app) ~= "table" then
		app = { name = nil, builds = {}, manifests = {} }
		db.apps[id] = app
	end
	app.builds = app.builds or {}
	app.manifests = app.manifests or {}
	local snapshot = {}
	for depotid, gid in pairs(depots or {}) do
		local norm = util.norm_gid(gid)
		if norm then
			snapshot[tostring(depotid)] = norm
			versiondb.add_manifest(db, id, depotid, norm, ts)
		end
	end
	local existed = app.builds[tostring(buildid)]
	if type(existed) == "table" then
		for depotid, gid in pairs(snapshot) do
			existed.depots = existed.depots or {}
			existed.depots[depotid] = gid
		end
		existed.ts = math.max(tonumber(existed.ts) or 0, tonumber(ts) or 0)
		if complete == false then
			existed.complete = false
		end
	elseif next(snapshot) ~= nil then
		app.builds[tostring(buildid)] = {
			ts = tonumber(ts) or 0,
			branch = tostring(branch or "public"),
			depots = snapshot,
			complete = complete ~= false,
		}
	else
		-- Сборка без единого манифеста для отката бесполезна — не храним.
		return false
	end
	return true
end

--- Сводка по базе для приложения (для UI).
function versiondb.summary(db, appid)
	local id = util.norm_id(appid)
	local app = id and (db.apps or {})[id]
	if type(app) ~= "table" then
		return { ok = true, appid = id, in_db = false, builds = 0, manifests = 0 }
	end
	local manifests, builds = 0, 0
	for _ in pairs(app.manifests or {}) do
		manifests = manifests + 1
	end
	for _ in pairs(app.builds or {}) do
		builds = builds + 1
	end
	return {
		ok = true,
		appid = id,
		in_db = true,
		name = app.name,
		builds = builds,
		manifests = manifests,
	}
end

return versiondb
