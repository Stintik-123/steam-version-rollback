--- RPC-поверхность плагина: то, что фронтенд вызывает как backend.<имя>(...).
---
--- Соглашение: сложные данные ходят JSON-строками (так надёжнее всего между
--- LuaJIT и CEF: не теряются 64-битные GID, пустые таблицы и т.п.).
--- Каждый вызов завёрнут в pcall — ошибка не должна ронять бэкенд.

local millennium = require("millennium")
local fs = require("fs")
local http = require("http")
local util = require("util")
local steam = require("steam")
local appinfo = require("appinfo")
local steamraw = require("steamraw")
local steamcounts = require("steamcounts")
local appdb = require("appdb")
local localcache = require("localcache")
local versiondb = require("versiondb")
local collector = require("collector")
local plan = require("plan")
local jobs = require("jobs")
local swap = require("swap")

local function json_call(fn)
	local ok, res = pcall(fn)
	if not ok then
		util.err("RPC: " .. tostring(res))
		return util.encode_json({ ok = false, error = tostring(res) })
	end
	if type(res) == "string" then
		-- строки приходят уже готовым JSON: режем и их, если вдруг огромные
		local capped, truncated = util.cap_string(res)
		if truncated then
			util.err("RPC: строковый ответ превысил лимит IPC — отправлена заглушка")
			return util.encode_json({ ok = false, truncated = true, error = "ответ слишком большой для IPC" })
		end
		return capped
	end
	return util.encode_json_capped(res or { ok = true })
end

local function cfg_get(key, default)
	local ok, value = pcall(millennium.config.get, key)
	if ok and value ~= nil and value ~= "" then
		return value
	end
	return default
end

--- Согласие пользователя на сбор данных. Три состояния:
--- "yes" — собираем, "no" — не собираем, "" (пусто) — ещё не спрашивали.
local function consent_state()
	local value = cfg_get("collect_consent", "")
	if value == true then
		return "yes"
	end
	if value == false then
		return "no"
	end
	value = tostring(value)
	if value == "yes" or value == "no" then
		return value
	end
	return ""
end

--- Локальный сбор метаданных — только по явному согласию пользователя.
local function local_collect_allowed()
	return consent_state() == "yes"
end

--- Подписи веток: сначала пользовательский файл в data_dir, потом ресурс плагина.
local function labels_table()
	local override = util.read_json_file(fs.join(util.data_dir(), "labels.json"))
	if type(override) == "table" then
		return override
	end
	local read = millennium.assets and millennium.assets.read
	local raw = read and read("resources/labels.json")
	if not raw then
		return {}
	end
	return util.decode_json(raw) or {}
end

local function branch_label(appid, branch, labels)
	local per_app = labels[tostring(appid)] or {}
	if per_app[branch] then
		return per_app[branch]
	end
	local generic = labels._generic or {}
	if generic[branch] then
		return generic[branch]
	end
	if branch == "public" then
		return "Текущая (public)"
	end
	return branch
end

local function options_from(json)
	local opts = util.decode_json(json or "{}") or {}
	local languages = opts.languages
	if type(languages) ~= "table" then
		local csv = cfg_get("languages", "english,russian")
		languages = {}
		for word in tostring(csv):gmatch("[^,%s]+") do
			languages[#languages + 1] = word
		end
	end
	-- Явный false/true из UI важнее сохранённой настройки: opts.include_dlc ~= nil решает.
	local include_dlc
	if opts.include_dlc ~= nil then
		include_dlc = opts.include_dlc == true
	else
		include_dlc = cfg_get("include_dlc", false) == true
	end
	return {
		os = opts.os or (util.is_windows() and "windows" or "linux"),
		include_dlc = include_dlc,
		languages = languages,
	}
end

local function selection_from(json)
	local sel = util.decode_json(json or "{}") or {}
	if type(sel.custom) == "table" then
		local rows = {}
		for _, row in pairs(sel.custom) do
			if type(row) == "table" then
				local depotid = util.norm_id(row.depotid)
				local gid = util.norm_gid(row.gid)
				if depotid and gid then
					rows[#rows + 1] = { depotid = depotid, gid = gid }
				end
			end
		end
		if #rows > 0 then
			return { custom = rows }
		end
	end
	if sel.branch and sel.branch ~= "" then
		return { branch = tostring(sel.branch) }
	end
	return nil
end

---@ffi
---@return string JSON
function ping()
	-- Намеренно без cjson: проверяем, не в нём ли причина падения хоста.
	return '{"ok":true,"probe":"raw"}'
end

---@ffi
---@return string JSON { apps, libraries, config }
function get_state()
	return json_call(function()
		return {
			ok = true,
			steam_path = steam.path(),
			libraries = steam.libraries(),
			apps = steam.installed_apps(),
			config = {
				mode = cfg_get("mode", "download"),
				include_dlc = cfg_get("include_dlc", false),
				languages = cfg_get("languages", "english,russian"),
				delay_updates = cfg_get("delay_updates", false),
				local_collect = local_collect_allowed(),
				collect_consent = consent_state(),
				consent_shown_for = cfg_get("consent_shown_for", ""),
				github_token_set = (cfg_get("github_token", "") ~= ""),
				last_appid = cfg_get("last_appid", ""),
			},
		}
	end)
end

---@ffi
---@param appid string
---@param force boolean
---@return string JSON { info, acf, branches }
function get_app(appid, force)
	return json_call(function()
		local id = util.norm_id(appid)
		if not id then
			return { ok = false, error = "некорректный AppID" }
		end
		local info, err = appinfo.get(id, force == true)
		local acf = steam.read_acf(id)
		if not info then
			return { ok = false, error = err, acf = acf }
		end
		local labels = labels_table()
		local branches = {}
		for _, b in ipairs(info.branches) do
			local count, size, download = 0, 0, 0
			for _, d in pairs(info.depots) do
				local m = d.manifests[b]
				if m then
					count = count + 1
					size = size + m.size
					download = download + m.download
				end
			end
			branches[#branches + 1] = {
				branch = b,
				label = branch_label(id, b, labels),
				depot_count = count,
				total_size = size,
				total_download = download,
				is_current = (acf and acf.beta_key == b) or false,
			}
		end
		pcall(millennium.config.set, "last_appid", id)
		return { ok = true, info = info, acf = acf, branches = branches, backups = swap.list_backups(id) }
	end)
end

---@ffi
---@param text string
---@return string JSON
function debug_note(text)
	return json_call(function()
		local dir = util.data_dir()
		local path = require("fs").join(dir, "frontend-debug.txt")
		local line = util.cap_string(tostring(text), 400)
		local ok = require("utils").append_file(path, tostring(util.now()) .. " " .. line .. "\n")
		return { ok = ok ~= nil, path = path }
	end)
end

---@ffi
---@param appid string
---@param branch string
---@param force boolean
---@return string JSON { versions = [{ buildid, ts, branch, depots, complete, source }] }
function get_versions(appid, branch, force)
	return json_call(function()
		local id = util.norm_id(appid)
		if not id then
			return { ok = false, error = "некорректный AppID" }
		end
		local info, err = appinfo.get(id, false)
		if not info then
			return { ok = false, error = err }
		end
		local b = (branch ~= nil and branch ~= "") and tostring(branch) or "public"
		-- текущие манифесты ветки — точка отсчёта для обратной прокрутки истории
		local current = {}
		for depotid, depot in pairs(info.depots) do
			local manifest = depot.manifests and depot.manifests[b]
			if manifest and manifest.gid then
				current[depotid] = manifest.gid
			end
		end

		-- Сборки из общей+локальной базы (то, что накопили раньше).
		local db = versiondb.load()
		local merged, order = {}, {}
		local function put(entry)
			local existing = merged[entry.buildid]
			if existing then
				for depotid, gid in pairs(entry.depots or {}) do
					if not existing.depots[depotid] then
						existing.depots[depotid] = gid
					end
				end
				existing.ts = math.max(existing.ts or 0, entry.ts or 0)
				existing.source = tostring(existing.source) .. "+" .. tostring(entry.source)
				existing.complete = existing.complete and entry.complete
			else
				merged[entry.buildid] = entry
				order[#order + 1] = entry.buildid
			end
		end

		for _, entry in ipairs(versiondb.builds(db, id)) do
			put(entry)
		end

		local versions, verr = steamraw.versions(id, b, current, force == true)
		if versions then
			for _, entry in ipairs(versions) do
				entry.source = "steamraw"
				put(entry)
			end
		else
			versions = {}
		end

		local out = {}
		for _, buildid in ipairs(order) do
			out[#out + 1] = merged[buildid]
		end
		-- IPC-потолок: сотни сборок в одном ответе роняли хост в 0.5.x
		local capped_out, truncated_list = util.cap_list(out, 120)
		out = capped_out
		table.sort(out, function(a, b2)
			if (a.ts or 0) ~= (b2.ts or 0) then
				return (a.ts or 0) > (b2.ts or 0)
			end
			return tostring(a.buildid) > tostring(b2.buildid)
		end)

		return {
			ok = true,
			appid = id,
			app_name = info.name,
			branch = b,
			versions = out,
			truncated = truncated_list or nil,
			db = versiondb.summary(db, id),
			warning = (not versions) and verr or nil,
		}
	end)
end

--- Состояние согласия на сбор: yes / no / "" и факт, что вопрос уже задавали.
---@ffi
---@return string JSON { consent, asked, shown_for, github_token_set }
function get_consent()
	return json_call(function()
		local consent = consent_state()
		local shown = tostring(cfg_get("consent_shown_for", ""))
		return {
			ok = true,
			consent = consent,
			asked = (consent ~= "") or (shown ~= ""),
			shown_for = shown,
			github_token_set = (cfg_get("github_token", "") ~= ""),
		}
	end)
end

--- Зафиксировать ответ пользователя на вопрос о сборе.
---@ffi
---@param value string "yes" | "no"
---@return string JSON
function set_consent(value)
	return json_call(function()
		local v = tostring(value)
		if v ~= "yes" and v ~= "no" then
			return { ok = false, error = "ожидается yes или no" }
		end
		pcall(millennium.config.set, "collect_consent", v)
		pcall(millennium.config.set, "consent_shown_for", "scope-1")
		util.log("согласие на сбор: " .. v)
		return { ok = true, consent = v }
	end)
end

--- Есть ли игра в общей базе версий. Дёшево: без сети, кэш базы на 60 с.
---@ffi
---@param appid string
---@return string JSON { known, in_db, builds, manifests }
function app_known(appid)
	return json_call(function()
		local id = util.norm_id(appid)
		if not id then
			return { ok = false, error = "некорректный AppID" }
		end
		local summary = versiondb.summary(versiondb.cached(60), id)
		return {
			ok = true,
			appid = id,
			known = summary.in_db == true,
			in_db = summary.in_db,
			builds = summary.builds or 0,
			manifests = summary.manifests or 0,
		}
	end)
end

--- Сбор по одной игре + оформление Issue: с токеном создаётся автоматически,
--- без токена возвращаем предзаполненную ссылку (отправляет пользователь).
---@ffi
---@param appid string
---@return string JSON { number?, url?, truncated?, stats? }
function submit_app_issue(appid)
	return json_call(function()
		if not local_collect_allowed() then
			return { ok = false, error = "сбор не разрешён: сначала ответьте на вопрос в библиотеке" }
		end
		local id = util.norm_id(appid)
		if not id then
			return { ok = false, error = "некорректный AppID" }
		end
		-- убедимся, что по игре что-то собрано (локально, без принудительной сети)
		local db = versiondb.user() or { version = versiondb.VERSION, updated = 0, apps = {} }
		local row = collector.collect_app(db, id, false)
		versiondb.save_user(db)

		local body, stats = collector.report(id)
		local title = string.format("Версия %s: %s сборок, %s манифестов (локальный сбор)", id, tostring(stats.builds), tostring(stats.manifests))
		-- Ссылку на Issue отдаём ВСЕГДА: даже если локально ничего не нашлось,
		-- пользователь всё равно должен получить предзаполненную форму.
		local url, truncated = collector.issue_url(body, title)
		local token = tostring(cfg_get("github_token", ""))
		if token ~= "" then
			local payload = util.encode_json({ title = title, body = body, labels = { "version-data" } })
			local headers = {
				["Authorization"] = "Bearer " .. token,
				["Accept"] = "application/vnd.github+json",
				["Content-Type"] = "application/json",
				["User-Agent"] = "VersionRollback/0.6 (Millennium plugin)",
			}
			local ok, res = pcall(function()
				if http.post then
					return http.post("https://api.github.com/repos/" .. collector.REPO .. "/issues", {
						headers = headers,
						body = payload,
						timeout = 25,
					})
				end
				return http.request("https://api.github.com/repos/" .. collector.REPO .. "/issues", {
					method = "POST",
					headers = headers,
					body = payload,
					timeout = 25,
				})
			end)
			if ok and res and (res.status == 201 or res.status == 200) then
				local decoded = util.decode_json(res.body or "")
				util.log("Issue создан: " .. tostring(decoded and decoded.html_url))
				return { ok = true, number = decoded and decoded.number, url = decoded and decoded.html_url, stats = stats, auto = true }
			end
			util.warn("GitHub API не принял Issue: " .. tostring(res and res.status))
			-- падаем в ссылочный путь: пользователь отправит сам
		end
		return { ok = true, url = url, truncated = truncated, stats = stats, auto = false, errors = row.errors, empty = stats.apps == 0 }
	end)
end

---@ffi
---@param appid string
---@return string JSON сводка по базе версий
function get_db_summary(appid)
	return json_call(function()
		local db = versiondb.load()
		return versiondb.summary(db, util.norm_id(appid))
	end)
end

--- Собрать локальные находки: что Steam уже видел на этой машине и чего нет в базе.
---@ffi
---@param appid string
---@return string JSON { known = [], missing = [], build = {...} }
function collect_local(appid)
	return json_call(function()
		local id = util.norm_id(appid)
		if not id then
			return { ok = false, error = "некорректный AppID" }
		end
		if not local_collect_allowed() then
			return { ok = false, error = "локальный сбор не включён — разрешите его в блоке «Локальный сбор данных»" }
		end
		local db = versiondb.load()
		local entries = localcache.scan(id)
		local known, missing = {}, {}
		local seen = {}
		for _, entry in ipairs(entries) do
			local key = entry.depotid .. ":" .. entry.gid
			if not seen[key] then
				seen[key] = true
				local row = { depotid = entry.depotid, gid = entry.gid, source = entry.source }
				if versiondb.has_manifest(db, id, entry.depotid, entry.gid) then
					known[#known + 1] = row
				else
					missing[#missing + 1] = row
				end
			end
		end

		-- Установленная сейчас версия — тоже находка: у неё есть buildid.
		local acf = steam.read_acf(id)
		local build = nil
		if acf and acf.buildid and next(acf.installed_depots or {}) ~= nil then
			local depots = {}
			for depotid, gid in pairs(acf.installed_depots) do
				depots[depotid] = gid
			end
			build = {
				buildid = tostring(acf.buildid),
				branch = acf.beta_key or "public",
				ts = acf.last_updated or 0,
				depots = depots,
				in_db = false,
			}
			for _, entry in ipairs(versiondb.builds(db, id)) do
				if entry.buildid == build.buildid then
					build.in_db = true
					break
				end
			end
		end

		return {
			ok = true,
			appid = id,
			known = known,
			missing = missing,
			build = build,
			total = #known + #missing,
		}
	end)
end

--- Сохранить локальные находки в локальную копию базы.
---@ffi
---@param appid string
---@return string JSON
function save_local_db(appid)
	return json_call(function()
		local id = util.norm_id(appid)
		if not id then
			return { ok = false, error = "некорректный AppID" }
		end
		if not local_collect_allowed() then
			return { ok = false, error = "локальный сбор не включён" }
		end
		local db = versiondb.user() or { version = versiondb.VERSION, updated = 0, apps = {} }
		local entries = localcache.scan(id)
		local added = 0
		for _, entry in ipairs(entries) do
			if versiondb.add_manifest(db, id, entry.depotid, entry.gid, 0) then
				added = added + 1
			end
		end
		local acf = steam.read_acf(id)
		if acf and acf.buildid then
			local depots = {}
			for depotid, gid in pairs(acf.installed_depots or {}) do
				depots[depotid] = gid
			end
			if versiondb.add_build(db, id, tostring(acf.buildid), acf.beta_key, acf.last_updated, depots) then
				added = added + 1
			end
		end
		local ok = versiondb.save_user(db)
		return { ok = ok == true, appid = id, added = added, path = versiondb.user_path() }
	end)
end

--- Добавить текущие манифесты SteamCounts в локальный пул базы.
---@ffi
---@param appid string
---@return string JSON
function add_steamcounts_db(appid)
	return json_call(function()
		local id = util.norm_id(appid)
		if not id then
			return { ok = false, error = "некорректный AppID" }
		end
		if not local_collect_allowed() then
			return { ok = false, error = "локальный сбор не включён" }
		end
		local data, err = steamcounts.collect(id, false)
		if not data then
			return { ok = false, error = err }
		end
		local db = versiondb.user() or { version = versiondb.VERSION, updated = 0, apps = {} }
		local added = 0
		for _, row in pairs(data.depots or {}) do
			if versiondb.add_manifest(db, id, row.depotid, row.gid, 0) then
				added = added + 1
			end
		end
		local ok = versiondb.save_user(db)
		return { ok = ok == true, appid = id, added = added, path = versiondb.user_path() }
	end)
end

--- Выгрузить локальные находки в файл (для отправки в репозиторий).
---@ffi
---@param appid string
---@return string JSON { path, count }
function export_local(appid)
	return json_call(function()
		local id = util.norm_id(appid)
		if not id then
			return { ok = false, error = "некорректный AppID" }
		end
		if not local_collect_allowed() then
			return { ok = false, error = "локальный сбор не включён" }
		end
		local db = versiondb.load()
		local entries = localcache.scan(id)
		local missing = {}
		for _, entry in ipairs(entries) do
			if not versiondb.has_manifest(db, id, entry.depotid, entry.gid) then
				missing[#missing + 1] = { depotid = entry.depotid, gid = entry.gid, source = entry.source }
			end
		end
		local report = {
			appid = id,
			collected_at = util.now(),
			source = "local Steam cache (content_log.txt, depotcache, appmanifest)",
			note = "только метаданные: depotid и manifest GID. Ключей депо здесь нет.",
			manifests = missing,
		}
		local acf = steam.read_acf(id)
		if acf and acf.buildid then
			local depots = {}
			for depotid, gid in pairs(acf.installed_depots or {}) do
				depots[depotid] = gid
			end
			report.build = { buildid = tostring(acf.buildid), branch = acf.beta_key, ts = acf.last_updated, depots = depots }
		end
		local path = fs.join(util.data_dir(), "local-versions-" .. id .. ".json")
		local ok = util.write_json_file(path, report)
		return { ok = ok == true, path = path, count = #missing }
	end)
end

---@ffi
---@param appid string
---@param text string
---@return string JSON { rows = [{depotid, gid}], problems = [] }
function import_manifests(appid, text)
	return json_call(function()
		local rows, problems = localcache.parse_manifest_text(text)
		return {
			ok = #problems == 0 or #rows > 0,
			appid = util.norm_id(appid),
			rows = rows,
			problems = problems,
			error = (#rows == 0 and #problems > 0) and "не разобралось ни одной строки" or nil,
		}
	end)
end

---@ffi
---@param appid string
---@return string JSON { depots = [{depotid, gids}], entry_count }
function get_local_cache(appid)
	return json_call(function()
		return localcache.report(appid)
	end)
end

--- Каталог AppID из открытой базы steam-appdb: поиск игры по названию.
---@ffi
---@param query string
---@param force boolean
---@return string JSON { ok, source, results = [{ appid, name }] }
function appdb_search(query, force)
	return json_call(function()
		local results, err = appdb.search(query, force == true)
		if err then
			return { ok = false, error = err }
		end
		return {
			ok = true,
			source = appdb.URL,
			query = tostring(query or ""),
			results = results,
		}
	end)
end

--- Второй источник истории: SteamCounts (депо с GID + датированные обновления).
---@ffi
---@param appid string
---@param force boolean
---@return string JSON { depots = [{depotid, gid, size, os}], updates = [...] }
function get_steamcounts(appid, force)
	return json_call(function()
		local id = util.norm_id(appid)
		if not id then
			return { ok = false, error = "некорректный AppID" }
		end
		local data, err = steamcounts.collect(id, force == true)
		if not data then
			return { ok = false, error = err }
		end
		local depots = {}
		for _, row in pairs(data.depots or {}) do
			depots[#depots + 1] = row
		end
		table.sort(depots, function(a, b)
			return (tonumber(a.depotid) or 0) < (tonumber(b.depotid) or 0)
		end)
		return {
			ok = true,
			appid = id,
			depots = depots,
			updates = data.updates or {},
			source = "steamcounts.info",
		}
	end)
end

--- Живая проверка источников из подборки: что отвечает, что требует ключа.
---@ffi
---@return string JSON { results = [{name, status, kind, note}] }
function probe_sources()
	return json_call(function()
		local sources = {
			{ name = "SteamRaw (api)", url = "https://steamraw.com/api/app/1091500", kind = "json" },
			{ name = "SteamCMD API", url = "https://api.steamcmd.net/v1/info/1091500", kind = "json" },
			{ name = "SteamCounts", url = "https://steamcounts.info/app/1091500", kind = "html" },
			{ name = "SteamDB", url = "https://steamdb.info/app/1091500/depots/", kind = "html" },
			{ name = "HubcapDB", url = "https://hubcapmanifest.com/", kind = "html" },
			{ name = "SMD", url = "https://smd.mcbabel.de", kind = "html" },
			{ name = "Ryuu Manifests", url = "https://manifest-api.ryuu.space/", kind = "json" },
			{ name = "Open-SteamDB", url = "https://opensteamdb.net/", kind = "html" },
			{ name = "Steam AppDB", url = "https://steamappdb.net/", kind = "html" },
		}
		local results = {}
		for _, source in ipairs(sources) do
			local ok, res = pcall(http.get, source.url, {
				timeout = 8,
				user_agent = "VersionRollback/0.1 (probe)",
				headers = { ["Accept"] = source.kind == "json" and "application/json" or "text/html" },
			})
			local status, kind = 0, "dead"
			if ok and res then
				status = res.status or 0
				local body = res.body or ""
				if status == 401 or status == 403 then
					kind = "need-auth"
				elseif status >= 400 or status == 0 then
					kind = "dead"
				elseif body:find("^%s*[{%[]") then
					kind = "json"
				else
					kind = "html"
				end
			end
			results[#results + 1] = { name = source.name, url = source.url, status = status, kind = kind }
		end
		return { ok = true, results = results }
	end)
end

--- Собрать по одной игре (короткий вызов — чтобы не упереться в таймаут RPC).
---@ffi
---@param appid string
---@param force boolean
---@return string JSON сводка по игре
function collect_app(appid, force)
	return json_call(function()
		if not local_collect_allowed() then
			return { ok = false, error = "сбор не разрешён: сначала согласись в карточке обновления" }
		end
		local id = util.norm_id(appid)
		if not id then
			return { ok = false, error = "некорректный AppID" }
		end
		local db = versiondb.user() or { version = versiondb.VERSION, updated = 0, apps = {} }
		local row = collector.collect_app(db, id, force == true)
		versiondb.save_user(db)
		return {
			ok = true,
			appid = id,
			builds = row.builds,
			manifests = row.manifests,
			errors = row.errors,
		}
	end)
end

--- Собрать по ВСЕМ установленным играм: локальные кэши + SteamRaw + SteamCounts.
---@ffi
---@param force boolean
---@return string JSON сводка
function collect_all(force)
	return json_call(function()
		if not local_collect_allowed() then
			return { ok = false, error = "сбор не разрешён: сначала согласись в карточке обновления" }
		end
		local summary = collector.collect_all(force == true)
		summary.ok = true
		return summary
	end)
end

--- Отчёт о собранном + ссылка на создание Issue на GitHub.
---@ffi
---@return string JSON { body, url, stats }
function get_collection_report()
	return json_call(function()
		if not local_collect_allowed() then
			return { ok = false, error = "сбор не разрешён" }
		end
		local body, stats = collector.report()
		body = util.cap_string(body, 50000)
		local url, truncated = collector.issue_url(body, "Сбор версий Steam: " .. tostring(stats.apps) .. " игр")
		return {
			ok = true,
			body = body,
			url = url,
			truncated = truncated,
			stats = stats,
		}
	end)
end

--- Создать Issue на GitHub через API (нужен личный токен в настройках).
---@ffi
---@return string JSON
function post_github_issue()
	return json_call(function()
		if not local_collect_allowed() then
			return { ok = false, error = "сбор не разрешён" }
		end
		local token = tostring(cfg_get("github_token", ""))
		if token == "" then
			return { ok = false, error = "не задан токен GitHub — используйте кнопку «Открыть Issue»" }
		end
		local body, stats = collector.report()
		local title = "Сбор версий Steam: " .. tostring(stats.apps) .. " игр, " .. tostring(stats.builds) .. " сборок"
		local payload = util.encode_json({
			title = title,
			body = body,
			labels = { "version-data" },
		})
		local url = "https://api.github.com/repos/" .. collector.REPO .. "/issues"
		local headers = {
			["Authorization"] = "Bearer " .. token,
			["Accept"] = "application/vnd.github+json",
			["Content-Type"] = "application/json",
			["User-Agent"] = "VersionRollback/0.3 (Millennium plugin)",
		}
		local ok, res = pcall(function()
			if http.post then
				return http.post(url, { headers = headers, body = payload, timeout = 25 })
			end
			return http.request(url, { method = "POST", headers = headers, body = payload, timeout = 25 })
		end)
		if not ok or not res then
			return { ok = false, error = "GitHub API: " .. tostring(res) }
		end
		if res.status ~= 201 and res.status ~= 200 then
			return { ok = false, error = "GitHub API вернул HTTP " .. tostring(res.status) .. ": " .. tostring(res.body or "") }
		end
		local decoded = util.decode_json(res.body or "")
		return {
			ok = true,
			number = decoded and decoded.number,
			url = decoded and decoded.html_url,
			stats = stats,
		}
	end)
end

--- Сохранить токен GitHub (нужен только для автосоздания Issue).
---@ffi
---@param token string
---@return string JSON
function set_github_token(token)
	return json_call(function()
		local value = tostring(token or ""):gsub("%s", "")
		if value == "" then
			pcall(millennium.config.set, "github_token", "")
			return { ok = true, saved = false }
		end
		pcall(millennium.config.set, "github_token", value)
		return { ok = true, saved = true, hint = "токен сохранён в настройках Millennium" }
	end)
end

---@ffi
---@param appid string
---@return string JSON plan
function get_plan(appid, selection_json, options_json)
	return json_call(function()
		local id = util.norm_id(appid)
		local info, err = appinfo.get(id, false)
		if not info then
			return { ok = false, error = err }
		end
		local sel = selection_from(selection_json)
		if not sel then
			return { ok = false, error = "выбери ветку или укажи manifest ID" }
		end
		local acf = steam.read_acf(id)
		return plan.build(info, acf, sel, options_from(options_json))
	end)
end

---@ffi
---@param appid string
---@param selection_json string
---@param options_json string
---@param mode string "download" | "swap"
---@return string JSON snapshot
function start_download(appid, selection_json, options_json, mode)
	return json_call(function()
		local id = util.norm_id(appid)
		local info, err = appinfo.get(id, false)
		if not info then
			return { ok = false, error = err }
		end
		local sel = selection_from(selection_json)
		if not sel then
			return { ok = false, error = "выбери ветку или укажи manifest ID" }
		end
		local acf = steam.read_acf(id)
		local p = plan.build(info, acf, sel, options_from(options_json))
		if not p.ok then
			return p
		end

		-- Игра может быть не установлена: download_depot работает по лицензии, а не по
		-- наличию файлов. Тогда качаем в библиотеку с максимумом свободного места,
		-- и только в режиме «только скачать» — подменять нечего.
		local final_mode = mode or "download"
		local target = acf
		if not target then
			local lib, free = steam.best_library(p.total_size)
			if not lib then
				return { ok = false, error = "не нашёл ни одной библиотеки Steam (libraryfolders.vdf)" }
			end
			if p.total_size > 0 and tonumber(free) and tonumber(free) < p.total_size then
				return {
					ok = false,
					error = "недостаточно места: нужно ~" .. util.fmt_bytes(p.total_size)
						.. ", свободно " .. util.fmt_bytes(free),
				}
			end
			target = {
				appid = id,
				name = info.name,
				library = lib.path,
				steamapps = lib.steamapps,
				install_dir = nil,
				installdir = nil,
				language = "english",
				beta_key = nil,
				buildid = nil,
			}
			final_mode = "download"
		else
			local space = require("fs").space_info(acf.library)
			if space and p.total_size > 0 and tonumber(space.available) and tonumber(space.available) < p.total_size then
				return {
					ok = false,
					error = "недостаточно места: нужно ~" .. util.fmt_bytes(p.total_size)
						.. ", свободно " .. util.fmt_bytes(space.available),
				}
			end
		end

		pcall(millennium.config.set, "mode", final_mode)
		local snap, serr = jobs.start(p, target, final_mode)
		if not snap then
			return { ok = false, error = serr }
		end
		snap.ok = true
		snap.plan = p
		return snap
	end)
end

---@ffi
---@return string JSON snapshot
function tick()
	return json_call(function()
		local snap = jobs.tick()
		snap.ok = true
		return snap
	end)
end

---@ffi
---@return string JSON
function cancel_download()
	return json_call(function()
		local snap = jobs.cancel()
		snap.ok = true
		return snap
	end)
end

---@ffi
---@return string JSON
function reset_batch()
	return json_call(function()
		local snap = jobs.reset()
		snap.ok = true
		return snap
	end)
end

---@ffi
---@param depotid string
---@return string JSON
function mark_ready(depotid)
	return json_call(function()
		local snap = jobs.mark_ready(tostring(depotid))
		snap.ok = true
		return snap
	end)
end

---@ffi
---@param appid string
---@return string JSON
function apply_swap(appid)
	return json_call(function()
		return swap.apply(util.norm_id(appid))
	end)
end

---@ffi
---@param appid string
---@param dirname string
---@return string JSON
function restore_backup(appid, dirname)
	return json_call(function()
		return swap.restore(util.norm_id(appid), dirname ~= "" and dirname or nil)
	end)
end

---@ffi
---@param appid string
---@return string JSON
function list_backups(appid)
	return json_call(function()
		return { ok = true, backups = swap.list_backups(util.norm_id(appid)) }
	end)
end

---@ffi
---@param appid string
---@param enable boolean
---@return string JSON
function delay_updates(appid, enable)
	return json_call(function()
		swap.delay_updates(util.norm_id(appid), enable == true)
		pcall(millennium.config.set, "delay_updates", enable == true)
		return { ok = true }
	end)
end

---@ffi
---@param path string
---@return string JSON
function open_folder(path)
	return json_call(function()
		local ok, err = steam.open_folder(path)
		return { ok = ok, error = not ok and err or nil }
	end)
end

---@ffi
---@param appid string
---@return string JSON
function open_content_folder(appid)
	return json_call(function()
		local id = util.norm_id(appid)
		local acf = steam.read_acf(id)
		if not acf then
			return { ok = false, error = "игра не установлена" }
		end
		local dir = require("fs").join(acf.steamapps, "content", "app_" .. id)
		local ok, err = steam.open_folder(dir)
		return { ok = ok, path = dir, error = not ok and err or nil }
	end)
end

---@ffi
---@param key string
---@param value string
---@return string JSON
function set_setting(key, value)
	return json_call(function()
		local v = value
		if value == "true" then
			v = true
		elseif value == "false" then
			v = false
		end
		pcall(millennium.config.set, key, v)
		return { ok = true, key = key, value = v }
	end)
end

---@ffi
---@return string JSON
function get_log()
	return json_call(function()
		local rows = util.log_tail(80)
		for _, row in ipairs(rows) do
			row.msg = util.cap_string(tostring(row.msg), 240)
		end
		return { ok = true, log = rows }
	end)
end

util.log("RPC-функции зарегистрированы")

