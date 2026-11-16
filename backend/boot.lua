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
	util.log("Version Rollback загружен, Millennium " .. tostring(millennium.version()))
	millennium.ready()
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
