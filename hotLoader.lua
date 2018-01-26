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

	-- Initial loading of resources.
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

		-- Do the initial loading of resources.
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

	getLoader,        setLoader,        removeAllLoaders
	getCustomLoader,  setCustomLoader,  removeAllCustomLoaders
	getDefaultLoader, setDefaultLoader, disableDefaultLoader

	load,    unload
	require, unrequire

	update

--============================================================]]



local hotLoader = {
	_VERSION     = "hotLoader v0.1.1",
	_DESCRIPTION = "File hot-loading module",
	_URL         = "https://github.com/ReFreezed/LuaHotLoader",
	_LICENSE     = [[
		MIT License

		Copyright © 2018 Marcus 'ReFreezed' Thunström

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

local allowPathsOutsideLove = false



--==============================================================
--= Local Functions ============================================
--==============================================================

local fileExists
local getCurrentTime
local getFileContents, loadLuaFile
local getLastModifiedTime, getModuleLastModifiedTime
local getModuleFilePath
local getRequirePath
local indexOf, removeItem
local isLovePath
local loadModule
local loadResource
local log



-- fileExists( filePath )
function fileExists(filePath)
	if isLovePath(filePath) then
		return love.filesystem.exists(filePath)
	end

	local file = io.open(filePath, "r")
	if not file then return false end

	file:close()
	return true
end



-- time = getCurrentTime( )
getCurrentTime
	= love and function()
		return love.timer and love.timer.getTime() or os.clock()
	end
	or os.clock



-- contents, errorMessage = getFileContents( filePath )
function getFileContents(filePath)
	if isLovePath(filePath) then
		return love.filesystem.read(filePath)
	end

	local file, err = io.open(filePath, "rb")
	if not file then return nil, err end

	local contents = file:read"*a"

	file:close()

	return contents
end

-- chunk, errorMessage = loadLuaFile( filePath )
loadLuaFile = love and love.filesystem.load or _G.loadfile



-- time, errorMessage = getLastModifiedTime( filePath )
local fakeModifiedTimes = {}
local fileSizes         = {}

getLastModifiedTime

	= love and function(filePath)
		if isLovePath(filePath) then
			return love.filesystem.getLastModified(filePath)
		end

		local file, err = io.open(filePath, "r")
		if not file then
			fakeModifiedTimes[filePath] = nil
			return nil, "Could not determine file modification date."
		end

		local fileSize = file:seek("end")
		file:close()
		if not fileSize then
			fakeModifiedTimes[filePath] = nil
			return nil, "Could not determine file modification date."
		end

		local time = fakeModifiedTimes[filePath]
		if time and fileSize == fileSizes[filePath] then return time end

		fileSizes[filePath] = fileSize

		time = os.time()--getCurrentTime()
		fakeModifiedTimes[filePath] = time

		return time
	end

	or require"lfs" and function(filePath)
		return require"lfs".attributes(filePath, "modification")
	end

-- time, errorMessage = getModuleLastModifiedTime( modulePath )
function getModuleLastModifiedTime(modulePath)
	return getLastModifiedTime(getModuleFilePath(modulePath))
end



-- filePath = getModuleFilePath( modulePath )
do
	local filePaths = {}

	function getModuleFilePath(modulePath)
		local filePath = filePaths[modulePath]
		if not filePath then

			local filePathsStr = getRequirePath():gsub("?", (modulePath:gsub("%.", "/")))
			for currentFilePath in filePathsStr:gmatch"[^;]+" do
				if fileExists(currentFilePath) then
					filePath = currentFilePath
					break
				end
			end

			filePaths[modulePath] = filePath or error("[hotLoader] Cannot find module on path '"..modulePath.."'.")
		end
		return filePath
	end

end



-- filePaths:string = getRequirePath( )
getRequirePath
	= love and love.filesystem.getRequirePath
	or function()
		return package.path
	end



-- bool = isLovePath( filePath )
isLovePath
	= love and function(filePath)
		if not allowPathsOutsideLove then return true end

		return filePath:sub(1, 1) ~= "/" and filePath:find"^[%L%l]:[/\\]" == nil
	end
	or function()
		return false
	end



-- module = loadModule( modulePath, protected )
function loadModule(modulePath, protected)
	local M

	if protected then
		local ok, chunkOrErr = pcall(loadLuaFile, getModuleFilePath(modulePath))
		if not ok then
			log("ERROR: %s", chunkOrErr)
			return nil
		end
		M = chunkOrErr()

	else
		M = loadLuaFile(getModuleFilePath(modulePath))()
	end

	if M == nil then M = true end

	return M
end



-- resource, errorMessage = loadResource( filePath, protected )
function loadResource(filePath, protected)
	local loader
		=  customLoaders[filePath]
		or loaders[filePath:match"%.([^.]+)$"]
		or defaultLoader
		or getFileContents

	local res
	if protected then

		local ok, resOrErr = pcall(loader, filePath)
		if not ok then
			log("ERROR: %s", resOrErr)
			return nil, resOrErr

		elseif not resOrErr then
			local err = "Loader returned nothing for '"..filePath.."'."
			log("ERROR: %s", err)
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
function indexOf(t, targetV)
	for i, v in ipairs(t) do
		if v == targetV then return i end
	end
	return nil
end

-- index = removeItem( table, value )
function removeItem(t, v)
	local i = indexOf(t, v)
	if not i then return nil end

	table.remove(t, i)
	return i
end



-- log( formatString, value...)
function log(s, ...)
	print(("[hotLoader|%s] "..s):format(os.date"%H:%M:%S", ...))
end



--==============================================================
--= Public Functions ===========================================
--==============================================================



-- update( deltaTime )
function hotLoader.update(dt)
	time = time+dt
	if time < checkingInterval then return end
	time = 0

	-- Check modules.
	for _, modulePath in ipairs(modulePaths) do

		local modifiedTime = getModuleLastModifiedTime(modulePath)
		if modifiedTime ~= moduleModifiedTimes[modulePath] then
			log("Reloading module: %s", modulePath)

			local M = loadModule(modulePath, true)
			if M == nil then
				log("Failed reloading module: %s", modulePath)
			else
				modules[modulePath] = M
				log("Reloaded module: %s", modulePath)
			end

			moduleModifiedTimes[modulePath] = modifiedTime

		end
	end

	-- Check resources.
	for _, filePath in ipairs(resourcePaths) do

		local modifiedTime = getLastModifiedTime(filePath)
		if modifiedTime ~= resourceModifiedTimes[filePath] then
			log("Reloading resource: %s", filePath)

			local res = loadResource(filePath, true)
			if res == nil then
				log("Failed reloading resource: %s", filePath)
			else
				resources[filePath] = res
				log("Reloaded resource: %s", filePath)
			end

			resourceModifiedTimes[filePath] = modifiedTime

		end
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



-- Allow hotLoader to access files outside the default LÖVE directories. May not always work.
-- Note that absolute paths are required to access external files (e.g. "C:/Images/Duck.png").
-- This setting is ignored outside LÖVE.
-- allowExternalPaths( bool )
function hotLoader.allowExternalPaths(state)
	allowPathsOutsideLove = not not state
end



--==============================================================
--==============================================================
--==============================================================

-- Setup default loaders in LÖVE.
if love then

	hotLoader.setLoader(
		"jpg","jpeg",
		"png",
		"tga",
		love.graphics.newImage
	)

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
