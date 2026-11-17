--- Тело бэкенда Version Rollback (входит в сборку backend/main.lua).
---
--- Здесь обычные require: tools/bundle-backend.mjs подставляет вместо них уже
--- загруженные модули, потому что в упакованном .star require соседних файлов
--- не работает (package.path не содержит папку backend).

local millennium = require("millennium")
local util = require("util")
local _ = require("rpc") -- регистрирует @ffi-функции для фронтенда
local patches = require("patches")

local function on_load()
	-- Ошибка внутри on_load убивает Lua-хост, поэтому ловим её сами и пишем
	-- traceback в TEMP: иначе Millennium просто теряет child-процесс.
	local function marker(name, text)
		pcall(function()
			local dir = os.getenv("TEMP") or os.getenv("TMP") or "."
			local file = io.open(dir .. "/" .. name, "w")
			if file then
				file:write(text)
				file:close()
			end
		end)
	end

	marker("vr-onload-enter.txt", tostring(os.time()))
	local ok, err = xpcall(function()
		util.log("Version Rollback загружен, Millennium " .. tostring(millennium.version()))
		millennium.ready()
	end, debug.traceback)
	marker("vr-onload-done.txt", tostring(os.time()) .. " ok=" .. tostring(ok))
	if ok then
		return
	end
	marker("vr-onload-error.txt", tostring(err))
end

local function on_frontend_loaded()
	util.log("фронтенд Steam загружен — консоль клиента доступна для download_depot")
end

local function on_unload()
	util.log("Version Rollback выгружен")
end

return {
	on_load = on_load,
	on_frontend_loaded = on_frontend_loaded,
	on_unload = on_unload,
	patches = patches.get(),
}
