--- Чистая логика: какие депо и с какими манифестами качать.
--- Никакого I/O — покрыто тестами (tests/test_lua.mjs).

local plan = {}

local function array_from_map_keys(map)
	local out = {}
	for k in pairs(map or {}) do
		out[#out + 1] = tostring(k)
	end
	table.sort(out, function(a, b)
		return (tonumber(a) or 0) < (tonumber(b) or 0)
	end)
	return out
end

local function has_language(list, lang)
	if not list or #list == 0 then
		return true
	end
	for _, l in ipairs(list) do
		if tostring(l):lower() == tostring(lang):lower() then
			return true
		end
	end
	return false
end

local function os_matches(oslist, os)
	if oslist == nil or oslist == "" then
		return true
	end
	return oslist:lower():find(os:lower(), 1, true) ~= nil
end

--- Собрать план загрузки.
--- @param info table нормализованный appinfo
--- @param acf table|nil { installed_depots = {[depotid]=gid}, language = "russian" }
--- @param selection table { branch = "2_31_old" } либо { custom = { {depotid="...", gid="..."} } }
--- @param opts table { os = "windows", include_dlc = false, languages = {"russian","english"} }
function plan.build(info, acf, selection, opts)
	opts = opts or {}
	local os = opts.os or "windows"
	local include_dlc = opts.include_dlc and true or false
	local languages = opts.languages
	local warnings, skipped, depots = {}, {}, {}

	if type(info) ~= "table" or type(info.depots) ~= "table" then
		return { ok = false, error = "нет данных о депо приложения" }
	end

	-- 1. Кандидаты: если игра установлена — берём ровно те депо, что поставил Steam
	--    (это автоматически учитывает ОС, язык озвучки и купленные DLC).
	local candidates, source
	if acf and type(acf.installed_depots) == "table" and next(acf.installed_depots) then
		candidates = array_from_map_keys(acf.installed_depots)
		source = "installed"
	else
		candidates = {}
		source = "appinfo"
		for _, depotid in ipairs(array_from_map_keys(info.depots)) do
			local d = info.depots[depotid]
			local reason
			if not os_matches(d.oslist, os) then
				reason = "другая ОС (" .. tostring(d.oslist) .. ")"
			elseif d.language ~= "" and not has_language(languages or { acf and acf.language or "english" }, d.language) then
				reason = "другой язык (" .. d.language .. ")"
			elseif (d.dlcappid or d.optionaldlc) and not include_dlc then
				reason = "DLC (не включён)"
			elseif d.lowviolence then
				reason = "low violence вариант"
			end
			if reason then
				skipped[#skipped + 1] = { depotid = depotid, reason = reason }
			else
				candidates[#candidates + 1] = depotid
			end
		end
	end

	-- 2. Манифесты
	local custom_map = {}
	if type(selection) == "table" and type(selection.custom) == "table" then
		for _, row in pairs(selection.custom) do
			if type(row) == "table" and row.depotid and row.gid then
				custom_map[tostring(row.depotid)] = tostring(row.gid)
			end
		end
	end
	local branch = selection and selection.branch or nil
	local is_custom = next(custom_map) ~= nil

	if not is_custom and not branch then
		return { ok = false, error = "не выбрана версия (ветка или manifest ID)" }
	end
	if is_custom then
		-- ручной режим: качаем только то, что явно указал пользователь
		candidates = array_from_map_keys(custom_map)
		source = "custom"
	end

	local total_size, total_download = 0, 0
	for _, depotid in ipairs(candidates) do
		local d = info.depots[depotid]
		local gid, size, download, note
		if is_custom then
			gid = custom_map[depotid]
			local m = d and d.manifests or {}
			for _, mm in pairs(m) do
				if mm.gid == gid then
					size, download = mm.size, mm.download
					break
				end
			end
			note = "указан вручную"
		else
			local m = d and d.manifests and d.manifests[branch]
			if m then
				gid, size, download = m.gid, m.size, m.download
			end
		end

		if not gid then
			skipped[#skipped + 1] = {
				depotid = depotid,
				reason = d and ("нет манифеста для ветки «" .. tostring(branch) .. "»") or "депо нет в app_info (возможно, DLC не куплен)",
			}
		else
			local installed_gid = acf and acf.installed_depots and acf.installed_depots[depotid]
			local same = installed_gid ~= nil and tostring(installed_gid) == tostring(gid)
			depots[#depots + 1] = {
				depotid = depotid,
				gid = tostring(gid), -- строка! 64 бита
				size = tonumber(size) or 0,
				download = tonumber(download) or 0,
				language = d and d.language or "",
				dlcappid = d and d.dlcappid or nil,
				same_as_installed = same,
				note = note,
			}
			total_size = total_size + (tonumber(size) or 0)
			total_download = total_download + (tonumber(download) or 0)
		end
	end

	if #depots == 0 then
		return {
			ok = false,
			error = "ни одного депо для этой версии не найдено",
			skipped = skipped,
			warnings = warnings,
		}
	end

	if total_download == 0 then
		warnings[#warnings + 1] = "размер загрузки неизвестен — прогресс будет приблизительным"
	end
	if source == "appinfo" then
		warnings[#warnings + 1] = "игра не установлена: набор депо подобран по ОС/языку, проверь список вручную"
	end
	for _, d in ipairs(depots) do
		if d.same_as_installed then
			warnings[#warnings + 1] = "депо " .. d.depotid .. " уже на этом манифесте — Steam просто проверит файлы"
		end
	end

	return {
		ok = true,
		appid = info.appid,
		app_name = info.name,
		branch = branch,
		label = is_custom and "свой манифест" or tostring(branch),
		source = source,
		depots = depots,
		skipped = skipped,
		warnings = warnings,
		total_size = total_size,
		total_download = total_download,
	}
end

return plan
