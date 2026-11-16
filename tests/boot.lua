--- Проверка собранного backend/main.lua: он должен загрузиться и вызвать ready().
--- Именно этот сценарий падал на живой установке ("module 'util' not found").

install_stubs()

local chunk, err = load(ENTRY_SOURCE, "@backend/main.lua")
assert(chunk, "load: " .. tostring(err))

local mod = chunk()
assert(type(mod) == "table", "backend/main.lua должен вернуть таблицу")
assert(type(mod.on_load) == "function", "нет on_load")
assert(type(mod.on_unload) == "function", "нет on_unload")
assert(type(mod.patches) == "table", "patches должен быть таблицей")

mod.on_load()
assert(READY_CALLED == true, "on_load не вызвал millennium.ready()")

mod.on_unload()
mod.on_frontend_loaded()

return "BOOT OK"
