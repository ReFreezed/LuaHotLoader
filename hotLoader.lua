--[[============================================================
--=
--=  File Hot-Loading Module
--=  - Written by Marcus 'ReFreezed' Thunström
--=  - MIT License
--=
--=  Dependencies:
--=  - either LuaFileSystem or LÖVE 0.10+
--=
--==============================================================



	-- Usage with LuaFileSystem:

	local hotLoader     = require("hotLoader")
	local duckImagePath = "duck.jpg"

	-- Initial loading of resources (optional).
	hotLoader.load(duckImagePath)

	-- Program loop.
	local lastTime = os.clock()

	while true do
		local currentTime = os.clock()

		-- Allow hotLoader to reload module and resource files that have been updated.
		hotLoader.update(currentTime-lastTime)

		-- Show if debug mode is enabled.
		local settings = hotLoader.require("appSettings")
		if settings.enableDebug then
			print("DEBUG")
		end

		-- Show size of duck image.
		local duckImageData = hotLoader.load(duckImagePath)
		print("Duck is "..(#duckImageData).." bytes")

		lastTime = currentTime
	end



	-- Usage in LÖVE:

	local hotLoader = require("hotLoader")
	local player = {
		x = 100, y = 50,
		imagePath = "player.png",
	}

	function love.load()

		-- Tell hotLoader to load .png files using love.graphics.newImage().
		hotLoader.setLoader("png", love.graphics.newImage)

		-- Note: hotLoader automatically adds common loaders in LÖVE, including
		-- for .png files. You can call hotLoader.removeAllLoaders() to undo this.

		-- Do the initial loading of resources (optional).
		hotLoader.load(player.imagePath)
	end

	function love.update(dt)

		-- Allow hotLoader to reload module and resource files that have been updated.
		hotLoader.update(dt)
	end

	function love.draw()

		-- Show if debug mode is enabled.
		local settings = hotLoader.require("gameSettings")
		if settings.enableDebug then
			love.graphics.print("DEBUG", 5, 5)
		end

		-- Draw player image.
		local playerImage = hotLoader.load(player.imagePath)
		love.graphics.draw(playerImage, player.x, player.y)
	end



--==============================================================

	API:

	allowExternalPaths

	getCheckingInterval
	setCheckingInterval

	getLogFormat
	setLogFormat

	getLoader,        setLoader,        removeAllLoaders
	getCustomLoader,  setCustomLoader,  removeAllCustomLoaders
	getDefaultLoader, setDefaultLoader, disableDefaultLoader

	load,    unload,    preload,    hasLoaded
	require, unrequire, prerequire, hasRequired

	update
	resetCheckingState

--============================================================]]



local hotLoader = {
	_VERSION     = "LuaHotLoader 1.2.0",
	_DESCRIPTION = "File hot-loading module",
	_URL         = "https://github.com/ReFreezed/LuaHotLoader",
	_LICENSE     = [[
		MIT License

		Copyright © 2018-2022 Marcus 'ReFreezed' Thunström

		Permission is hereby granted, free of charge, to any person obtaining a copy
		of this software and associated documentation files (the "Software"), to deal
		in the Software without restriction, including without limitation the rights
		to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
		copies of the Software, and to permit persons to whom the Software is
		furnished to do so, subject to the following conditions:

		The above copyright notice and this permission notice shall be included
		in all copies or substantial portions of the Software.

		THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
		IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
		FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
		AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
		WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
		IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
	]]
}



--==============================================================



local checkingInterval      = 1.00
local allowPathsOutsideLove = false

local logFormat             = "[hotLoader|%t] %m"
local logFormatHasD         = false
local logFormatHasM         = true
local logFormatHasT         = true

local loaders               = {}
local customLoaders         = {}
local defaultLoader         = nil

local modules               = {}
local modulePaths           = {}
local moduleModifiedTimes   = {}

local resources             = {}
local resourcePaths         = {}
local resourceModifiedTimes = {}

local time                  = 0.00
local lastCheckedIndex      = 0
local stateHasBeenReset     = false



local love_getFileInfo = love and love.filesystem.getInfo



--==============================================================
--= Local Functions ============================================
--==============================================================



-- bool = isLovePath( filePath )
local isLovePath
	= love and function(filePath)
		if not allowPathsOutsideLove then  return true  end

		return filePath:sub(1, 1) ~= "/" and filePath:find"^[%L%l]:[/\\]" == nil
	end
	or function()
		return false
	end



-- bool = fileExists( filePath )
local function fileExists(filePath)
	if isLovePath(filePath) then
		if love_getFileInfo then
			return (love_getFileInfo(filePath, "file") ~= nil)
		else
			return love.filesystem.exists(filePath)
		end
	end

	local file = io.open(filePath, "r")
	if not file then  return false  end

	file:close()
	return true
end



-- time = getCurrentClock( )
-- Warning: os.clock() isn't guaranteed to be in seconds.
local getCurrentClock
	= love and function()
		return love.timer and love.timer.getTime() or os.clock()
	end
	or os.clock



-- contents, errorMessage = getFileContents( filePath )
local function getFileContents(filePath)
	if isLovePath(filePath) then
		return love.filesystem.read(filePath)
	end

	local file, err = io.open(filePath, "rb")
	if not file then  return nil, err  end

	local contents = file:read"*a"
	file:close()

	return contents
end

-- chunk, errorMessage = loadLuaFile( filePath )
local loadLuaFile = love and love.filesystem.load or _G.loadfile



-- filePaths = getRequirePath( )
-- filePaths = "filePath1;..."
local getRequirePath
	= love and love.filesystem.getRequirePath
	or function()
		return package.path
	end



-- filePath = getModuleFilePath( modulePath )
local getModuleFilePath
do
	local moduleFilePaths = {}

	--[[local]] function getModuleFilePath(modulePath)
		local filePath = moduleFilePaths[modulePath]
		if filePath then  return filePath  end

		local filePathsStr = getRequirePath():gsub("?", (modulePath:gsub("%.", "/")))

		for currentFilePath in filePathsStr:gmatch"[^;]+" do
			if fileExists(currentFilePath) then
				filePath = currentFilePath
				break
			end
		end

		moduleFilePaths[modulePath] = filePath or error("[hotLoader] Cannot find module on path '"..modulePath.."'.")
		return filePath
	end
end



-- time, errorMessage = getLastModifiedTime( filePath )
local fakeModifiedTimes = {}
local fileSizes         = {}

local getLastModifiedTime

	= love and function(filePath)
		if isLovePath(filePath) then
			if love_getFileInfo then
				-- LÖVE 11.0+
				local info = love_getFileInfo(filePath, "file")
				local time = info and info.modtime
				if time then  return time  end

				return nil, "Could not determine file modification time."

			else
				-- LÖVE 0.10.2-
				return love.filesystem.getLastModified(filePath)
			end
		end

		-- Try to at least check the file size.
		-- If the size changed then we generate a fake modification time.
		-- @Incomplete: Do this if neither LÖVE nor LuaFileSystem is available.

		local file, err = io.open(filePath, "r")
		if not file then
			fakeModifiedTimes[filePath] = nil
			return nil, "Could not determine file modification time."
		end

		local fileSize = file:seek"end"
		file:close()
		if not fileSize then
			fakeModifiedTimes[filePath] = nil
			return nil, "Could not determine file modification time."
		end

		local time = fakeModifiedTimes[filePath]
		if time and fileSize == fileSizes[filePath] then  return time  end

		fileSizes[filePath] = fileSize

		time = os.time()--getCurrentClock()
		fakeModifiedTimes[filePath] = time

		return time
	end

	or require"lfs" and function(filePath)
		return require"lfs".attributes(filePath, "modification")
	end

-- time, errorMessage = getModuleLastModifiedTime( modulePath )
local function getModuleLastModifiedTime(modulePath)
	return getLastModifiedTime(getModuleFilePath(modulePath))
end



-- module = loadModule( modulePath, protected )
local function loadModule(modulePath, protected)
	local M

	if protected then
		local ok, chunkOrErr = pcall(loadLuaFile, getModuleFilePath(modulePath))
		if not ok then
			hotLoader.log("ERROR: %s", chunkOrErr)
			return nil
		end
		M = chunkOrErr()

	else
		M = loadLuaFile(getModuleFilePath(modulePath))()
	end

	if M == nil then  M = true  end
	return M
end



-- resource, errorMessage = loadResource( filePath, protected )
local function loadResource(filePath, protected)
	local loader
		=  customLoaders[filePath]
		or loaders[filePath:match"%.([^.]+)$"]
		or defaultLoader
		or getFileContents

	local res
	if protected then

		local ok, resOrErr = pcall(loader, filePath)
		if not ok then
			hotLoader.log("ERROR: %s", resOrErr)
			return nil, resOrErr

		elseif not resOrErr then
			local err = "Loader returned nothing for '"..filePath.."'."
			hotLoader.log("ERROR: %s", err)
			return nil, err
		end

		res = resOrErr

	else
		res = loader(filePath)
		if not res then
			error("[hotLoader] Loader returned nothing for '"..filePath.."'.")
		end
	end

	return res
end



-- index = indexOf( table, value )
local function indexOf(t, targetV)
	for i, v in ipairs(t) do
		if v == targetV then  return i  end
	end
	return nil
end

-- index = removeItem( table, value )
local function removeItem(t, v)
	local i = indexOf(t, v)
	if not i then  return nil  end

	table.remove(t, i)
	return i
end



--==============================================================
--= Public Functions ===========================================
--==============================================================



-- update( deltaTime )
function hotLoader.update(dt)
	local moduleCount = #modulePaths
	local pathCount   = moduleCount+#resourcePaths
	if pathCount == 0 then  return  end

	time = time+dt

	local timeBetweenChecks = checkingInterval/pathCount
	local pathsToCheck      = math.min(math.floor(time/timeBetweenChecks), pathCount)
	local checkAllPaths     = (pathsToCheck == pathCount)

	stateHasBeenReset = false

	while pathsToCheck > 0 and not stateHasBeenReset do
		pathsToCheck = pathsToCheck-1
		time = time-timeBetweenChecks

		lastCheckedIndex = math.min(lastCheckedIndex, pathCount)%pathCount+1

		-- Check next module.
		if lastCheckedIndex <= moduleCount then
			local modulePath   = modulePaths[lastCheckedIndex]
			local modifiedTime = getModuleLastModifiedTime(modulePath)

			if modifiedTime ~= moduleModifiedTimes[modulePath] then
				hotLoader.log("Reloading module: %s", modulePath)

				local M = loadModule(modulePath, true)
				if M == nil then
					hotLoader.log("Failed reloading module: %s", modulePath)
				else
					modules[modulePath] = M
					hotLoader.log("Reloaded module: %s", modulePath)
				end

				moduleModifiedTimes[modulePath] = modifiedTime

			end

		-- Check next resource.
		else
			local filePath     = resourcePaths[lastCheckedIndex-moduleCount]
			local modifiedTime = getLastModifiedTime(filePath)

			if modifiedTime ~= resourceModifiedTimes[filePath] then
				hotLoader.log("Reloading resource: %s", filePath)

				local res = loadResource(filePath, true)
				if res == nil then
					hotLoader.log("Failed reloading resource: %s", filePath)
				else
					resources[filePath] = res
					hotLoader.log("Reloaded resource: %s", filePath)
				end

				resourceModifiedTimes[filePath] = modifiedTime

			end
		end

	end

	if checkAllPaths then
		time = 0 -- Some protection against lag.
	end

end



-- interval = getCheckingInterval( )
function hotLoader.getCheckingInterval()
	return checkingInterval
end

-- setCheckingInterval( interval )
function hotLoader.setCheckingInterval(interval)
	checkingInterval = interval
end



-- loader = getLoader( fileExtension )
function hotLoader.getLoader(fileExt)
	return loaders[fileExt]
end

-- Sets a loader for a file extension.
-- setLoader( fileExtension, [ fileExtension2..., ] loader )
-- loader: function( fileContents, filePath )
function hotLoader.setLoader(...)
	local argCount = select("#", ...)
	local loader = select(argCount, ...)
	for i = 1, argCount-1 do
		loaders[select(i, ...)] = loader
	end
end

-- removeAllLoaders( )
function hotLoader.removeAllLoaders()
	loaders = {}
end

-- loader = getCustomLoader( filePath )
function hotLoader.getCustomLoader(filePath)
	return customLoaders[filePath]
end

-- Sets a loader for a specific file path.
-- setCustomLoader( filePath, [ filePath2..., ] loader )
-- loader: function( fileContents, filePath )
function hotLoader.setCustomLoader(...)
	local argCount = select("#", ...)
	local loader = select(argCount, ...)
	for i = 1, argCount-1 do
		customLoaders[select(i, ...)] = loader
	end
end

-- removeAllCustomLoaders( )
function hotLoader.removeAllCustomLoaders()
	customLoaders = {}
end

-- loader = getDefaultLoader( )
function hotLoader.getDefaultLoader()
	return defaultLoader
end

-- setDefaultLoader( loader )
-- loader: Specify nil to restore original default loader (which loads the file as a plain string).
function hotLoader.setDefaultLoader(loader)
	defaultLoader = loader
end

-- disableDefaultLoader( )
function hotLoader.disableDefaultLoader()
	defaultLoader = function(filePath)
		error("[hotLoader] No loader is available for '"..filePath.."' (and the default loader is disabled).")
	end
end



-- resource, errorMessage = load( filePath [, protectedLoad=false ] [, customLoader ] )
-- customLoader: If set, replaces the previous custom loader for filePath.
function hotLoader.load(filePath, protected, loader)
	if type(protected) == "function" then
		protected, loader = false, protected
	end

	if loader then
		hotLoader.setCustomLoader(filePath, loader)
	end

	local res = resources[filePath]
	if res == nil then
		local err
		res, err = loadResource(filePath, (protected or false))

		if not res then
			if not indexOf(resourcePaths, filePath) then
				table.insert(resourcePaths, filePath)
			end
			return nil, err
		end

		resources[filePath] = res
		resourceModifiedTimes[filePath] = getLastModifiedTime(filePath)

		table.insert(resourcePaths, filePath)
	end

	return res
end

-- Forces the resource to reload at next load call.
-- unload( filePath )
function hotLoader.unload(filePath)
	resources[filePath] = nil
	removeItem(resourcePaths, filePath)
end

-- preload( filePath, resource [, customLoader ] )
function hotLoader.preload(filePath, res, loader)
	if res == nil then
		hotLoader.log("ERROR: The resource must not be nil. (Maybe you meant to use hotLoader.unload()?)")
		return
	end

	if loader then
		hotLoader.setCustomLoader(filePath, loader)
	end

	if resources[filePath] == nil then
		table.insert(resourcePaths, filePath)
	end

	resources[filePath] = res
	resourceModifiedTimes[filePath] = getLastModifiedTime(filePath)
end

-- bool = hasLoaded( filePath )
function hotLoader.hasLoaded(filePath)
	return resources[filePath] ~= nil
end



-- Requires a module just like the standard Lua require() function.
-- module = require( modulePath )
function hotLoader.require(modulePath)

	local M = modules[modulePath]
	if M == nil then
		M = loadModule(modulePath, false)

		modules[modulePath] = M
		moduleModifiedTimes[modulePath] = getModuleLastModifiedTime(modulePath)

		table.insert(modulePaths, modulePath)
	end

	return M
end

-- Forces the module to reload at next require call.
-- unrequire( modulePath )
function hotLoader.unrequire(modulePath)
	modules[modulePath] = nil
	removeItem(modulePaths, modulePath)
end

-- prerequire( modulePath, module )
function hotLoader.prerequire(modulePath, M)
	if M == nil then
		hotLoader.log("ERROR: The module must not be nil. (Maybe you meant to use hotLoader.unrequire()?)")
		return
	end

	if modules[modulePath] == nil then
		table.insert(modulePaths, modulePath)
	end

	modules[modulePath] = M
	moduleModifiedTimes[modulePath] = getModuleLastModifiedTime(modulePath)
end

-- bool = hasRequired( modulePath )
function hotLoader.hasRequired(modulePath)
	return modules[modulePath] ~= nil
end



-- Allow hotLoader to access files outside the default LÖVE directories. May not always work.
-- Note that absolute paths are required to access external files (e.g. "C:/Images/Duck.png").
-- This setting is ignored outside LÖVE.
-- allowExternalPaths( bool )
function hotLoader.allowExternalPaths(state)
	allowPathsOutsideLove = not not state
end



-- Make hotLoader start over and check the first monitored file next time hotLoader.update() is called.
-- The current update is aborted if this is called from within a loader.
-- resetCheckingState( )
function hotLoader.resetCheckingState()
	time              = 0
	lastCheckedIndex  = 0
	stateHasBeenReset = true
end



function hotLoader.getLogFormat(s)
	return logFormat
end

-- Set message format used by hotLoader.log().
-- Use the percent sign to indicate where the values go:
--     %d = date (YYYY-MM-DD)
--     %m = message
--     %t = time (HH:MM:SS)
--     %% = a literal percent sign
-- Default format is "[hotLoader|%t] %m"
function hotLoader.setLogFormat(s)
	local hasD = false
	local hasM = false
	local hasT = false

	for c in s:gmatch"%%(.)" do
		if     c == "d" then  hasD = true
		elseif c == "m" then  hasM = true
		elseif c == "t" then  hasT = true
		elseif c ~= "%" then  error("Invalid option '%"..c.."'. (Valid options are '%d', '%m' and '%t')", 2)  end
	end

	logFormat     = s
	logFormatHasD = hasD
	logFormatHasM = hasM
	logFormatHasT = hasT
end



--==============================================================



-- To silence hotLoader you can do hotLoader.log=function()end
-- log( formatString, value... )
function hotLoader.log(s, ...)
	s             = s:format(...)
	local dateStr = logFormatHasD and os.date"%Y-%m-%d"
	local timeStr = logFormatHasT and os.date"%H:%M:%S"

	print((logFormat:gsub("(%%(.))", function(match, c)
		if c == "m" then
			return s
		elseif c == "d" then
			return dateStr
		elseif c == "t" then
			return timeStr
		else
			return match
		end
	end)))
end



--==============================================================
--==============================================================
--==============================================================

-- Setup default loaders in LÖVE.
-- (Call hotLoader.removeAllLoaders() the first thing you do to undo this.)
if love and love.graphics then
	hotLoader.setLoader(
		"jpg","jpeg",
		"png",
		"tga",
		love.graphics.newImage
	)
end
if love and love.audio then
	hotLoader.setLoader(
		"wav",
		"ogg","oga","ogv",
		function(filePath)
			return love.audio.newSource(filePath, "static")
		end
	)
	hotLoader.setLoader(
		"mp3",
		"699","amf","ams","dbm","dmf","dsm","far","it","j2b","mdl","med",
			"mod","mt2","mtm","okt","psm","s3m","stm","ult","umx","xm",
		"abc","mid","pat",
		function(filePath)
			return love.audio.newSource(filePath, "stream")
		end
	)
end

return hotLoader
