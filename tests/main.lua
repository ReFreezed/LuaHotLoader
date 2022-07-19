--[[============================================================
--=
--=  Tests for LuaHotLoader
--=  LuaFileSystem + LÖVE
--=
--============================================================]]

io.stdout:setvbuf("no")
io.stderr:setvbuf("no")

-- Monkeypatch modules before loading library.
local lfs          = not love and require"lfs"
local fakeModTimes = {}

local function pack(...)
	return {n=select("#", ...), ...}
end

if love then
	if love.filesystem.getInfo then
		local _getInfo = love.filesystem.getInfo

		function love.filesystem.getInfo(path, ...)
			local info, err = _getInfo(path, ...)
			if not info then  return nil, err  end

			info.modtime = fakeModTimes[path] or 1
			return info
		end

	else
		local _getLastModified = love.filesystem.getLastModified
		local _exists          = love.filesystem.exists

		function love.filesystem.getLastModified(path)  return fakeModTimes[path] or 1  end
		function love.filesystem.exists         (path)  return true                     end
	end

else
	local _attributes = lfs.attributes

	function lfs.attributes(path, requestNameOrResultTable)
		if requestNameOrResultTable == "modification" then  return fakeModTimes[path] or 1  end

		local values = pack(_attributes(path, requestNameOrResultTable))
		if type(values[1]) == "table" then  values[1].modification = fakeModTimes[path] or 1  end

		return unpack(values, 1, values.n)
	end
end

local jit = jit
_G.jit    = nil -- Don't let the library know about LuaJIT+FFI!

-- local function assert(...)  return ...  end -- DEBUG

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
	local path1         = (love and "" or thisDir) .. "test1.txt"
	local loads         = 0
	fakeModTimes[path1] = 1

	local text = hotLoader.load(path1, function(path)
		loads = loads + 1
		return readFile(path)
	end)
	assert(hotLoader.hasLoaded(path1))
	assert(loads == 1) -- The custom loader should've been used.
	assert(text == "foobar1")
	assert(hotLoader.load(path1) == "foobar1")
	assert(loads == 1) -- The file shouldn't have loaded again.

	-- Reload file.
	hotLoader.unload(path1)
	assert(not hotLoader.hasLoaded(path1))
	hotLoader.unload(path1) -- Should do nothing.
	hotLoader.load(path1)
	assert(hotLoader.hasLoaded(path1))
	assert(loads == 2)

	-- Run updates for a couple of seconds.
	for i = 1, 10 do  hotLoader.update(.2)  end
	assert(loads == 2) -- Nothing should've happened.

	-- Update the file.
	fakeModTimes[path1] = fakeModTimes[path1] + 1

	-- Run updates for a couple of seconds.
	print("Should reload.")
	for i = 1, 10 do  hotLoader.update(.2)  end
	assert(loads == 3) -- The file should've reloaded.

	-- Monitor the file (which replaces the custom loader).
	local path2         = (love and "" or thisDir) .. "test2.txt"
	local monitors      = 0
	fakeModTimes[path2] = 1
	hotLoader.monitor(path2, function(path, ...)
		monitors = monitors + 1
		assert(select("#", ...) == 0)
	end)
	assert(monitors == 0)

	-- Run updates for a couple of seconds.
	for i = 1, 10 do  hotLoader.update(.2)  end
	assert(monitors == 0)

	-- Update the file.
	fakeModTimes[path2] = fakeModTimes[path2] + 1

	-- Run updates for a couple of seconds.
	print("Should reload.")
	for i = 1, 10 do  hotLoader.update(.2)  end
	assert(monitors == 1)
	assert(loads    == 3) -- Make sure the previous file didn't reload.

	-- Monitor with data.
	hotLoader.monitor(path2, "testdata", function(path, data)
		monitors = monitors + 1
		assert(data == "testdata")
	end)
	assert(monitors == 1)
	fakeModTimes[path2] = fakeModTimes[path2] + 1
	print("Should reload.")
	for i = 1, 10 do  hotLoader.update(.2)  end
	assert(monitors == 2)
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
	local moduleName         = "test"
	local modulePath         = (love and "" or thisDir) .. "test.lua"
	fakeModTimes[modulePath] = 1
	_G.requires              = 0
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
	fakeModTimes[modulePath] = fakeModTimes[modulePath] + 1

	-- Run updates for a couple of seconds.
	print("Should reload.")
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
