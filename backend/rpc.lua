--- RPC-поверхность плагина: то, что фронтенд вызывает как backend.<имя>(...).
---
--- Соглашение: сложные данные ходят JSON-строками (так надёжнее всего между
--- LuaJIT и CEF: не теряются 64-битные GID, пустые таблицы и т.п.).
--- Каждый вызов завёрнут в pcall — ошибка не должна ронять бэкенд.

local millennium = require("millennium")
local fs = require("fs")
local util = require("util")
local steam = require("steam")
local appinfo = require("appinfo")
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
		return res
	end
	return util.encode_json(res or { ok = true })
end

local function cfg_get(key, default)
	local ok, value = pcall(millennium.config.get, key)
	if ok and value ~= nil and value ~= "" then
		return value
	end
	return default
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
	return json_call(function()
		return {
			ok = true,
			millennium = millennium.version(),
			steam_path = steam.path(),
			windows = util.is_windows(),
			data_dir = util.data_dir(),
		}
	end)
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
---@param appid string
---@param selection_json string
---@param options_json string
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
		return { ok = true, log = util.log_tail(120) }
	end)
end

util.log("RPC-функции зарегистрированы")
