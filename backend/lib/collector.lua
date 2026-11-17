--- Сбор версий по максимуму: всё, что можно собрать на этой машине.
---
--- Что делает: обходит ВСЕ установленные игры и для каждой складывает в
--- локальную копию базы всё найденное:
---   1) локальные кэши Steam (content_log.txt, depotcache, appmanifest) —
---      манифесты, которые Steam уже видел на этой машине;
---   2) SteamRaw — сборки и восстановленные снимки манифестов по всем веткам;
---   3) SteamCounts — текущие GID по депо (перекрёстная проверка).
---
--- Зачем: SteamRaw начинает историю только с октября 2026, SteamDB парсить
--- нельзя. Поэтому историю приходится копить: из общей базы, из чужих
--- находок и из собственных локальных следов.
---
--- ВАЖНО: только метаданные (AppID, buildid, depotid, GID). Никаких ключей
--- депо, никакого обхода прав. Ничего не уходит наружу само — отчёт
--- пользователь отправляет сам (Issue на GitHub), и только по явному согласию.

local fs = require("fs")
local util = require("util")
local steam = require("steam")
local appinfo = require("appinfo")
local localcache = require("localcache")
local steamraw = require("steamraw")
local steamcounts = require("steamcounts")
local versiondb = require("versiondb")

local collector = {}

collector.REPO = "Stintik-123/steam-version-rollback"

--- Один проход по одной игре.
--- @param db table локальная база (в неё пишем)
--- @param appid string
--- @param force boolean обойти кэш сетевых источников
--- @return table сводка по игре
function collector.collect_app(db, appid, force)
	local id = util.norm_id(appid)
	local row = { appid = id, manifests = 0, builds = 0, errors = {} }
	if not id then
		row.errors[#row.errors + 1] = "некорректный AppID"
		return row
	end

	-- 1. Локальные кэши Steam.
	local ok_local, entries = pcall(localcache.scan, id)
	if ok_local then
		for _, entry in ipairs(entries) do
			if versiondb.add_manifest(db, id, entry.depotid, entry.gid, 0) then
				row.manifests = row.manifests + 1
			end
		end
	end

	-- 2. SteamRaw: сборки и снимки манифестов по каждой ветке.
	local ok_info, info = pcall(appinfo.get, id, false)
	if ok_info and info then
		local branches = info.branches or { "public" }
		for _, branch in ipairs(branches) do
			local current = {}
			for depotid, depot in pairs(info.depots or {}) do
				local manifest = depot.manifests and depot.manifests[branch]
				if manifest and manifest.gid then
					current[depotid] = manifest.gid
				end
			end
			local ok_v, versions = pcall(steamraw.versions, id, branch, current, force == true)
			if ok_v and versions then
				for _, entry in ipairs(versions) do
					if next(entry.depots or {}) ~= nil then
						local existed = versiondb.has_build(db, id, entry.buildid)
						if versiondb.add_build(db, id, entry.buildid, entry.branch, entry.ts, entry.depots, entry.complete) and not existed then
							row.builds = row.builds + 1
						end
					end
				end
			end
		end
	else
		row.errors[#row.errors + 1] = "appinfo недоступен"
	end

	-- 3. SteamCounts: текущие GID по депо.
	local ok_sc, sc = pcall(steamcounts.collect, id, force == true)
	if ok_sc and sc then
		for _, depot in pairs(sc.depots or {}) do
			if versiondb.add_manifest(db, id, depot.depotid, depot.gid, 0) then
				row.manifests = row.manifests + 1
			end
		end
	elseif not ok_sc then
		row.errors[#row.errors + 1] = "SteamCounts: " .. tostring(sc)
	end

	return row
end

--- Собрать по всем установленным играм.
--- @return table сводка { apps = [...], builds = N, manifests = N, errors = N }
function collector.collect_all(force)
	local db = versiondb.user() or { version = versiondb.VERSION, updated = 0, apps = {} }
	local apps = steam.installed_apps() or {}
	local summary = { apps = {}, builds = 0, manifests = 0, errors = 0, total_apps = #apps }

	for _, app in ipairs(apps) do
		local row = collector.collect_app(db, app.appid, force)
		row.name = app.name
		summary.apps[#summary.apps + 1] = row
		summary.builds = summary.builds + row.builds
		summary.manifests = summary.manifests + row.manifests
		summary.errors = summary.errors + #row.errors
	end

	versiondb.save_user(db)
	summary.saved_to = versiondb.user_path()
	return summary
end

--- Тело отчёта для GitHub Issue: то, что собрано на этой машине (локальная база).
--- @return string body, table stats
function collector.report()
	local db = versiondb.user() or { apps = {} }
	local body, stats = {}, { apps = 0, builds = 0, manifests = 0 }
	body[#body + 1] = "Сбор метаданных о версиях Steam (только depotid → manifest GID, без ключей депо)."
	body[#body + 1] = ""
	body[#body + 1] = "Источники: локальные кэши Steam (content_log.txt, depotcache, appmanifest), SteamRaw, SteamCounts."
	body[#body + 1] = "Собрано: " .. util.date_utc(util.now())
	body[#body + 1] = ""

	for appid, app in pairs(db.apps or {}) do
		local builds, manifests = {}, {}
		for buildid, build in pairs(app.builds or {}) do
			local depots = {}
			local count = 0
			for depotid, gid in pairs(build.depots or {}) do
				depots[#depots + 1] = { depotid = depotid, gid = gid }
				count = count + 1
			end
			if count > 0 then
				table.sort(depots, function(a, b)
					return (tonumber(a.depotid) or 0) < (tonumber(b.depotid) or 0)
				end)
				builds[#builds + 1] = {
					buildid = buildid,
					branch = build.branch or "public",
					ts = tonumber(build.ts) or 0,
					depots = depots,
				}
			end
		end
		for key, manifest in pairs(app.manifests or {}) do
			manifests[#manifests + 1] = manifest
		end
		if #builds > 0 or #manifests > 0 then
			stats.apps = stats.apps + 1
			table.sort(builds, function(a, b)
				if a.ts ~= b.ts then
					return a.ts > b.ts
				end
				return tostring(a.buildid) > tostring(b.buildid)
			end)
			table.sort(manifests, function(a, b)
				if tostring(a.depotid) ~= tostring(b.depotid) then
					return (tonumber(a.depotid) or 0) < (tonumber(b.depotid) or 0)
				end
				return tostring(a.gid) < tostring(b.gid)
			end)
			body[#body + 1] = "### " .. tostring(app.name or ("App " .. tostring(appid))) .. " (" .. tostring(appid) .. ")"
			for _, build in ipairs(builds) do
				local parts = {}
				for _, depot in ipairs(build.depots) do
					parts[#parts + 1] = depot.depotid .. "=" .. depot.gid
				end
				local date = build.ts > 0 and util.date_utc(build.ts) or "?"
				body[#body + 1] = string.format(
					"- build %s · %s · %s · %s",
					tostring(build.buildid), tostring(build.branch), date, table.concat(parts, " ")
				)
				stats.builds = stats.builds + 1
			end
			body[#body + 1] = ""
		end
	end

	return table.concat(body, "\n"), stats
end

--- Ссылка на создание Issue с готовым телом.
--- Длинные тела лучше отправлять через API по токену, поэтому здесь режем.
function collector.issue_url(body, title)
	local limit = 3000
	local text = body
	local truncated = false
	if #text > limit then
		text = text:sub(1, limit) .. "\n\n… (тело урезано; полный отчёт — в локальном файле)"
		truncated = true
	end
	local url = string.format(
		"https://github.com/%s/issues/new?title=%s&body=%s",
		collector.REPO,
		util.url_encode(title or "Сбор версий Steam"),
		util.url_encode(text)
	)
	return url, truncated
end

return collector
