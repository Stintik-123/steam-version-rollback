--- Минимальный парсер Valve KeyValues (VDF/ACF).
--- Нужен для steamapps/libraryfolders.vdf и steamapps/appmanifest_<appid>.acf.
--- Чистый Lua без внешних зависимостей (кроме string/table), покрыт тестами.

local vdf = {}

local escapes = { n = "\n", t = "\t", r = "\r", ["\\"] = "\\", ['"'] = '"' }

local function skip_ws(s, i)
	local n = #s
	while i <= n do
		local c = s:sub(i, i)
		if c == " " or c == "\t" or c == "\r" or c == "\n" then
			i = i + 1
		elseif c == "/" and s:sub(i + 1, i + 1) == "/" then
			local j = s:find("\n", i + 2, true)
			i = j and (j + 1) or (n + 1)
		else
			break
		end
	end
	return i
end

local function read_quoted(s, i)
	local out, n = {}, #s
	i = i + 1
	while i <= n do
		local c = s:sub(i, i)
		if c == "\\" then
			local nx = s:sub(i + 1, i + 1)
			out[#out + 1] = escapes[nx] or nx
			i = i + 2
		elseif c == '"' then
			return table.concat(out), i + 1
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	return nil, "незакрытая кавычка"
end

local function read_token(s, i)
	local c = s:sub(i, i)
	if c == '"' then
		return read_quoted(s, i)
	end
	if c == "{" or c == "}" then
		return c, i + 1
	end
	local j, n = i, #s
	while j <= n do
		local ch = s:sub(j, j)
		if ch == " " or ch == "\t" or ch == "\r" or ch == "\n" or ch == "{" or ch == "}" or ch == '"' then
			break
		end
		j = j + 1
	end
	if j == i then
		return nil, "неожиданный символ на позиции " .. i
	end
	return s:sub(i, j - 1), j
end

local parse_object

local function parse_body(s, i)
	local obj = {}
	while true do
		i = skip_ws(s, i)
		if i > #s then
			return nil, "неожиданный конец файла (нет '}')"
		end
		local key
		key, i = read_token(s, i)
		if key == nil then
			return nil, i
		end
		if key == "}" then
			return obj, i
		end

		i = skip_ws(s, i)
		local val
		val, i = read_token(s, i)
		if val == nil then
			return nil, i
		end

		if val == "{" then
			local child
			child, i = parse_body(s, i)
			if child == nil then
				return nil, i
			end
			obj[key] = child
		else
			obj[key] = val
			-- условные суффиксы вида [$WIN32] пропускаем
			local save = i
			i = skip_ws(s, i)
			local maybe
			maybe, i = read_token(s, i)
			if type(maybe) ~= "string" or maybe:sub(1, 2) ~= "[$" then
				i = save
			end
		end
	end
end

parse_object = parse_body

--- Разобрать VDF-текст.
--- @return table|nil root, string|nil err например { libraryfolders = { ... } }
function vdf.parse(text)
	if type(text) ~= "string" or text == "" then
		return nil, "пустой VDF"
	end
	local i = skip_ws(text, 1)
	local key
	key, i = read_token(text, i)
	if key == nil then
		return nil, i
	end
	i = skip_ws(text, i)
	local brace
	brace, i = read_token(text, i)
	if brace ~= "{" then
		return nil, "ожидалась '{' после ключа " .. tostring(key)
	end
	local body, err = parse_body(text, i)
	if body == nil then
		return nil, err
	end
	return { [key] = body }
end

--- Достать ключ без учёта регистра (Steam пишет и "AppState", и "appstate").
function vdf.get(tbl, key)
	if type(tbl) ~= "table" then
		return nil
	end
	if tbl[key] ~= nil then
		return tbl[key]
	end
	local lower = tostring(key):lower()
	for k, v in pairs(tbl) do
		if tostring(k):lower() == lower then
			return v
		end
	end
	return nil
end

local function escape_str(s)
	s = tostring(s)
	s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\t", "\\t")
	return s
end

local function encode_value(key, value, indent, out)
	local pad = string.rep("\t", indent)
	if type(value) == "table" then
		out[#out + 1] = pad .. '"' .. escape_str(key) .. '"\n' .. pad .. "{\n"
		for k, v in pairs(value) do
			encode_value(k, v, indent + 1, out)
		end
		out[#out + 1] = pad .. "}\n"
	else
		out[#out + 1] = pad .. '"' .. escape_str(key) .. '"\t\t"' .. escape_str(value) .. '"\n'
	end
end

--- Собрать VDF обратно (пригодится, если решишь править ACF).
function vdf.encode(root)
	local out = {}
	for k, v in pairs(root) do
		encode_value(k, v, 0, out)
	end
	return table.concat(out)
end

return vdf
