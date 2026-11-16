--- Заглушки C-модулей Millennium для тестов.
--- Устанавливаются один раз в общий Lua-state (тесты и boot-проверка грузятся
--- из JS-раннера в один и тот же state).

READY_CALLED = false

local function stub(name, mod)
	package.preload[name] = function()
		return mod
	end
end

local json_stub = {
	safe = {
		encode = function()
			return "{}"
		end,
		decode = function()
			return nil, "заглушка"
		end,
	},
	encode = function()
		return "{}"
	end,
	decode = function()
		return nil, "заглушка"
	end,
}

function install_stubs()
	stub("json", json_stub)
	stub("cjson", json_stub)
	stub("millennium", {
		steam_path = function()
			return "C:/Steam"
		end,
		version = function()
			return "v3.6.3"
		end,
		ready = function()
			READY_CALLED = true
			return true
		end,
		config = {
			get = function()
				return nil
			end,
			set = function() end,
		},
		assets = {
			read = function()
				return nil
			end,
		},
	})
	stub("fs", {
		join = function(...)
			return table.concat({ ... }, "/")
		end,
		exists = function()
			return true
		end,
		create_directories = function()
			return true
		end,
		list_recursive = function()
			return {}
		end,
		list = function()
			return {}
		end,
		parent_path = function(p)
			return p
		end,
		space_info = function()
			return { capacity = 1, free = 1, available = 1 }
		end,
	})
	stub("utils", {
		getenv = function()
			return "Windows_NT"
		end,
		time = function()
			return 1760000000
		end,
		read_file = function()
			return nil
		end,
		write_file = function()
			return true
		end,
		exec = function()
			return "", 0
		end,
		get_backend_path = function()
			return ""
		end,
	})
	stub("http", {
		get = function()
			return nil, "заглушка"
		end,
		request = function()
			return nil, "заглушка"
		end,
	})
	stub("logger", {
		info = function() end,
		warn = function() end,
		error = function() end,
	})
end
