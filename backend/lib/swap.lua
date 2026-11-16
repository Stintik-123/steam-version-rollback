--- Подмена файлов игры скачанной версией + бэкап и откат назад.
---
--- Принципы безопасности:
---   * НИЧЕГО не удаляется: старая версия просто переименовывается
---     (мгновенно, в пределах одного диска);
---   * файлы депо переносятся (rename), а не копируются — быстро и без лишнего места;
---   * перед подменой игра должна быть закрыта;
---   * Steam при следующем запуске может захотеть обновить игру обратно —
---     это ожидаемо, поэтому есть кнопка «Вернуть как было».

local fs = require("fs")
local millennium = require("millennium")
local util = require("util")
local steam = require("steam")
local jobs = require("jobs")

local swap = {}

local BACKUP_SUFFIX = ".vrbak_"
local AFTER_SUFFIX = ".after_rollback_"
local MARKER = "versionrollback.json"

local function merge_move(src, dst, stats)
	if not fs.exists(src) then
		return false, "нет папки " .. tostring(src)
	end
	if not fs.exists(dst) then
		fs.create_directories(dst)
	end
	local entries = fs.list(src)
	if not entries then
		return false, "не читается " .. tostring(src)
	end
	for _, e in pairs(entries) do
		local from = fs.join(src, e.name)
		local to = fs.join(dst, e.name)
		if e.is_directory then
			local ok, err = merge_move(from, to, stats)
			if not ok then
				return false, err
			end
		else
			if fs.exists(to) then
				fs.remove(to)
			end
			local ok = fs.rename(from, to)
			if not ok then
				-- другой том? копируем и удаляем источник
				local copied = fs.copy(from, to)
				if not copied then
					return false, "не удалось перенести " .. from
				end
				fs.remove(from)
				stats.copied = stats.copied + 1
			end
			stats.files = stats.files + 1
			stats.bytes = stats.bytes + (tonumber(e.size) or 0)
		end
	end
	-- подчищаем опустевшие папки депо (только пустые!)
	if fs.is_empty(src) then
		fs.remove(src)
	end
	return true
end

--- Список бэкапов для игры.
function swap.list_backups(appid)
	local acf = steam.read_acf(appid)
	if not acf then
		return {}
	end
	local out = {}
	local common = fs.join(acf.steamapps, "common")
	local entries = fs.list(common)
	if not entries then
		return out
	end
	local prefix = acf.installdir .. BACKUP_SUFFIX
	for _, e in pairs(entries) do
		if e.is_directory and e.name:sub(1, #prefix) == prefix then
			local marker = util.read_json_file(fs.join(e.path, MARKER)) or {}
			out[#out + 1] = {
				dirname = e.name,
				path = e.path,
				created = marker.created or tonumber(e.name:sub(#prefix + 1)) or 0,
				label = marker.label or "?",
				appid = acf.appid,
				depots = marker.depots or {},
			}
		end
	end
	table.sort(out, function(a, b)
		return (tonumber(a.created) or 0) > (tonumber(b.created) or 0)
	end)
	return out
end

--- Применить скачанную версию: бэкап текущей + перенос файлов депо.
function swap.apply(appid)
	local acf = steam.read_acf(appid)
	if not acf then
		return { ok = false, error = "игра не найдена среди установленных" }
	end
	local batch = jobs.current_batch()
	if not batch or tostring(batch.appid) ~= tostring(acf.appid) then
		return { ok = false, error = "нет активной пачки загрузок для этой игры" }
	end
	local snap = jobs.snapshot()
	if not snap.all_ready then
		return { ok = false, error = "не все депо скачаны — подмена запрещена" }
	end
	if not fs.exists(acf.install_dir) then
		return { ok = false, error = "папка игры не найдена: " .. acf.install_dir }
	end

	local ready = jobs.ready_depots()
	for _, row in ipairs(ready) do
		if not row.content_dir or not fs.exists(row.content_dir) then
			return { ok = false, error = "пропали файлы депо " .. row.depotid }
		end
	end

	local ts = util.now()
	local backup_dir = acf.install_dir .. BACKUP_SUFFIX .. ts
	local ok, err = fs.rename(acf.install_dir, backup_dir)
	if not ok then
		return { ok = false, error = "не удалось сделать бэкап (игра запущена? нет прав?): " .. tostring(err) }
	end
	util.log("бэкап текущей версии: " .. backup_dir)

	local created = fs.create_directories(acf.install_dir)
	if created == nil then
		-- откатываем переименование, чтобы не оставить игру без папки
		fs.rename(backup_dir, acf.install_dir)
		return { ok = false, error = "не удалось создать папку игры заново" }
	end

	local stats = { files = 0, bytes = 0, copied = 0 }
	local depot_meta = {}
	for _, row in ipairs(ready) do
		local moved, merr = merge_move(row.content_dir, acf.install_dir, stats)
		if not moved then
			util.err("перенос депо " .. row.depotid .. " прерван: " .. tostring(merr))
			return {
				ok = false,
				error = "перенос прерван: " .. tostring(merr) .. ". Старая версия лежит в " .. backup_dir,
				backup_dir = backup_dir,
				partial = true,
			}
		end
		depot_meta[#depot_meta + 1] = { depotid = row.depotid, gid = row.gid }
	end

	util.write_json_file(fs.join(backup_dir, MARKER), {
		appid = acf.appid,
		name = acf.name,
		label = batch.label,
		branch = batch.branch,
		created = ts,
		original_install_dir = acf.install_dir,
		depots = depot_meta,
		previous_buildid = acf.buildid,
	})

	util.log(string.format("подмена готова: %d файлов, %s (скопировано через том: %d)",
		stats.files, util.fmt_bytes(stats.bytes), stats.copied))

	return {
		ok = true,
		backup_dir = backup_dir,
		install_dir = acf.install_dir,
		files = stats.files,
		bytes = stats.bytes,
		warnings = {
			"Steam может предложить обновить игру обратно — не запускай обновление, если хочешь остаться на этой версии.",
			"Запускать лучше напрямую .exe из папки игры или в офлайн-режиме Steam.",
			"Сетевые игры/античит могут не пустить на старую версию.",
		},
	}
end

--- Вернуть предыдущую версию из бэкапа.
function swap.restore(appid, dirname)
	local acf = steam.read_acf(appid)
	if not acf then
		return { ok = false, error = "игра не найдена" }
	end
	local backups = swap.list_backups(appid)
	local target
	if dirname then
		for _, b in ipairs(backups) do
			if b.dirname == dirname then
				target = b
			end
		end
	else
		target = backups[1]
	end
	if not target then
		return { ok = false, error = "бэкап не найден" }
	end

	if fs.exists(acf.install_dir) then
		local aside = acf.install_dir .. AFTER_SUFFIX .. util.now()
		local ok, err = fs.rename(acf.install_dir, aside)
		if not ok then
			return { ok = false, error = "не удалось отложить текущую папку игры: " .. tostring(err) }
		end
		util.log("текущая (откаченная) версия отложена в " .. aside)
	end

	local ok, err = fs.rename(target.path, acf.install_dir)
	if not ok then
		return { ok = false, error = "не удалось вернуть бэкап: " .. tostring(err) }
	end
	util.log("версия возвращена из " .. target.dirname)
	return { ok = true, install_dir = acf.install_dir, restored_from = target.path }
end

--- Экспериментально: попросить клиент не спешить с обновлением.
--- Команды консоли существуют, но поведение зависит от версии клиента.
function swap.delay_updates(appid, enable)
	local id = util.norm_id(appid)
	if not id then
		return false
	end
	local cmds = {}
	if enable then
		cmds = {
			"app_delay_update " .. id .. " 31536000",
			"app_set_config " .. id .. " AutoUpdateBehavior 1",
		}
	else
		cmds = {
			"app_delay_update " .. id .. " 0",
			"app_set_config " .. id .. " AutoUpdateBehavior 0",
		}
	end
	for _, c in ipairs(cmds) do
		local ok, res = pcall(millennium.call_frontend_method, "execConsole", { c })
		util.log("консоль: " .. c .. " → " .. tostring(ok and res))
	end
	return true
end

return swap
