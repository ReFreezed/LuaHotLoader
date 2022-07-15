--[[============================================================
--=
--=  Tests for LuaHotLoader
--=  LuaFileSystem + LÖVE
--=
--============================================================]]

io.stdout:setvbuf("no")
io.stderr:setvbuf("no")

-- Monkeypatch file system API before loading library.
local lfs         = not love and require"lfs"
local fakeModTime = 1

local function pack(...)
	return {n=select("#", ...), ...}
end

if love then
	if love.filesystem.getInfo then
		local _getInfo = love.filesystem.getInfo

		function love.filesystem.getInfo(path, ...)
			local info, err = _getInfo(path, ...)
			if not info then  return nil, err  end

			info.modtime = fakeModTime
			return info
		end

	else
		local _getLastModified = love.filesystem.getLastModified
		local _exists          = love.filesystem.exists

		function love.filesystem.getLastModified(path)  return fakeModTime  end
		function love.filesystem.exists         (path)  return true         end
	end

else
	local _attributes = lfs.attributes

	function lfs.attributes(path, requestNameOrResultTable)
		if requestNameOrResultTable == "modification" then  return fakeModTime  end

		local values = pack(_attributes(path, requestNameOrResultTable))
		if type(values[1]) == "table" then  values[1].modification = fakeModTime  end

		return unpack(values, 1, values.n)
	end
end

-- Prepare loading of library.
local thisDir        = love and love.filesystem.getSource().."/" or debug.getinfo(1, "S").source:match"^@(.+)":gsub("[^/\\]+$", "")
local hotLoaderPath  = thisDir .. "../hotLoader.lua"
local hotLoaderChunk = assert(loadfile(hotLoaderPath))

-- Do tests!
----------------------------------------------------------------

local readFile =
	love and function(path)
		return love.filesystem.read(path)
	end
	or function(path)
		local file     = assert(io.open(path, "rb"))
		local contents = file:read"*a"
		file:close()
		return contents
	end

local function newHotLoader()
	local hotLoader = hotLoaderChunk()
	hotLoader.setCheckingInterval(1) -- Check all monitored files once per second.
	assert(hotLoader.getCheckingInterval() == 1)
	return hotLoader
end

--
-- Hot-load a file.
--
do
	local hotLoader = newHotLoader()

	-- Load file (with a custom loader).
	local path  = (love and "" or thisDir) .. "test.txt"
	local loads = 0

	local text = hotLoader.load(path, function(path)
		loads = loads + 1
		return readFile(path)
	end)
	assert(hotLoader.hasLoaded(path))
	assert(loads == 1) -- The custom loader should've been used.
	assert(text == "foobar")
	assert(hotLoader.load(path) == "foobar")
	assert(loads == 1) -- The file shouldn't have loaded again.

	-- Reload file.
	hotLoader.unload(path)
	assert(not hotLoader.hasLoaded(path))
	hotLoader.unload(path) -- Should do nothing.
	hotLoader.load(path)
	assert(hotLoader.hasLoaded(path))
	assert(loads == 2)

	-- Run updates for a couple of seconds.
	for i = 1, 10 do  hotLoader.update(.2)  end
	assert(loads == 2) -- Nothing should've happened.

	-- Update the file.
	fakeModTime = fakeModTime + 1

	-- Run updates for a couple of seconds.
	for i = 1, 10 do  hotLoader.update(.2)  end
	assert(loads == 3) -- The file should've reloaded.
end

--
-- Hot-require a Lua file.
--
do
	local hotLoader = newHotLoader()

	local packagePath = package.path
	if not love then
		package.path = thisDir.."?.lua"
	end

	-- Require file.
	local moduleName = "test"
	_G.requires = 0
	assert(not hotLoader.hasRequired(moduleName))
	assert(hotLoader.require(moduleName) == "foobar")
	assert(hotLoader.hasRequired(moduleName))
	assert(requires == 1)
	hotLoader.require(moduleName)
	assert(requires == 1)

	-- Re-require file.
	hotLoader.unrequire(moduleName)
	assert(not hotLoader.hasRequired(moduleName))
	hotLoader.unrequire(moduleName) -- Should do nothing.
	hotLoader.require(moduleName)
	assert(hotLoader.hasRequired(moduleName))
	assert(requires == 2)

	-- Run updates for a couple of seconds.
	for i = 1, 10 do  hotLoader.update(.2)  end
	assert(requires == 2) -- Nothing should've happened.

	-- Update the file.
	fakeModTime = fakeModTime + 1

	-- Run updates for a couple of seconds.
	for i = 1, 10 do  hotLoader.update(.2)  end
	assert(requires == 3) -- The file should've reloaded.

	-- Clean-up.
	if not love then
		package.path = packagePath
	end
end

--
-- Preload.
--
do
	local hotLoader = newHotLoader()

	local path  = "dog"
	local loads = 0

	hotLoader.setCustomLoader(path, function(path)
		loads = loads + 1
		return "not_cat"
	end)

	hotLoader.preload(path, "not_cat")
	assert(hotLoader.hasLoaded(path))

	local text = hotLoader.load(path, function(path)
		loads = loads + 1
		return readFile(path)
	end)
	assert(loads == 0) -- The value should be preloaded.
	assert(text == "not_cat")
end

-- @Incomplete: Test prerequire().

----------------------------------------------------------------

print("All tests passed!")
os.exit()
