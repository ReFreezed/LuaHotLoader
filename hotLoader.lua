--[[============================================================
--=
--=  LuaHotLoader v1.2-dev - file hot-loading library
--=  by Marcus 'ReFreezed' Thunström
--=
--=  License: MIT (see below)
--=  Website: http://refreezed.com/luahotloader/
--=  Documentation: http://refreezed.com/luahotloader/docs/
--=
--=  Dependencies: Either LuaFileSystem or LÖVE 0.10+
--=
--==============================================================

	API:

	load,    unload,    preload,    hasLoaded
	require, unrequire, prerequire, hasRequired
	monitor

	setLoader,        getLoader,        removeAllLoaders
	setCustomLoader,  getCustomLoader,  removeAllCustomLoaders
	setDefaultLoader, getDefaultLoader, disableDefaultLoader

	update
	resetCheckingState

	setCheckingInterval
	getCheckingInterval

	allowExternalPaths
	isAllowingExternalPaths

	setLogFormat
	getLogFormat
	log

----------------------------------------------------------------


	-- Usage with LuaFileSystem:

	local hotLoader     = require("hotLoader")
	local duckImagePath = "duck.jpg"

	-- Program loop.
	local lastTime = os.clock()

	while true do
		local currentTime = os.clock()

		-- Allow the library to reload module and resource files that have been updated.
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
		-- Tell the library to load .png files using love.graphics.newImage().
		hotLoader.setLoader("png", love.graphics.newImage)

		-- Note: The library automatically adds common loaders in LÖVE, including
		-- for .png files. You can call hotLoader.removeAllLoaders() to undo this.
	end

	function love.update(dt)
		-- Allow the library to reload module and resource files that have been updated.
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


--============================================================]]



local hotLoader = {
	_VERSION     = "LuaHotLoader 1.2.0-dev",
	_DESCRIPTION = "File hot-loading library",
	_URL         = "http://refreezed.com/luahotloader/",
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

if not (love or pcall(require, "lfs")) then
	error("[HotLoader] Failed detecting LuaFileSystem or LÖVE!", 0)
end



--==============================================================



local checkingInterval      = 1.00
local allowPathsOutsideLove = false

local logFormat     = "[HotLoader|%t] %m"
local logFormatHasD = false
local logFormatHasM = true
local logFormatHasT = true

local loaders       = {--[[ [fileExtension1]=loader, ... ]]}
local customLoaders = {--[[ [path1]=loader, ... ]]}
local defaultLoader = nil

local watchedModules   = {} -- watched* = { [watcher1.id]=watcher1, watcher1, ... }
local watchedResources = {} -- watcher  = see createAndRegisterWatcher()

local time              = 0.00
local lastCheckedIndex  = 0
local stateHasBeenReset = false



local DIRECTORY_SEPARATOR, TEMPLATE_SEPARATOR, SUBSTITUTION_POINT = package.config:match"^(%C)\n(%C)\n(%C)\n" -- Hopefully each line has a single character!
DIRECTORY_SEPARATOR = DIRECTORY_SEPARATOR or "/"
TEMPLATE_SEPARATOR  = TEMPLATE_SEPARATOR  or ";"
SUBSTITUTION_POINT  = SUBSTITUTION_POINT  or "?"



--==============================================================
--= Local Functions ============================================
--==============================================================



local function incLevel(level)
	return (level == 0) and 0 or 1+level
end

local function errorf(level, s, ...)
	error(("[HotLoader] "..s):format(...), incLevel(level))
end

-- logError( message )
-- logError( messageFormat, value1, ... )
local function logError(s, ...)
	if    select("#", ...) > 0
	then  hotLoader.log("Error: "..s, ...)
	else  hotLoader.log("Error: %s", s)  end
end

-- logWarning( message )
-- logWarning( messageFormat, value1, ... )
local function logWarning(s, ...)
	if    select("#", ...) > 0
	then  hotLoader.log("Warning: "..s, ...)
	else  hotLoader.log("Warning: %s", s)  end
end

-- assertarg( argumentNumber, argumentName, value, expectedValueType1, ... )
local function assertarg(argN, argName, v, ...)
	local vType = type(v)

	for i = 1, select("#", ...) do
		if vType == select(i, ...) then  return  end
	end

	local fName   = debug.getinfo(2, "n").name
	local expects = table.concat({...}, " or ")

	if fName == "" then  fName = "?"  end

	errorf(3, "Bad argument #%d (%s) to '%s'. (Expected %s, got %s)", argN, argName, fName, expects, vType)
end



local function normalizePath(path)
	return (path:gsub("\\", "/"))
end

local function isPathAbsolute(path)
	return (path:find"^~?/" or path:find"^%a:") ~= nil
end



-- bool = isLovePath( path )
local isLovePath
	= love and function(path)
		if not allowPathsOutsideLove then  return true  end -- This will result in LÖVE functions being used for external paths resulting in errors.
		return not isPathAbsolute(path)
	end
	or function()
		return false
	end



local love_getFileInfo = love and love.filesystem.getInfo

local function fileExists(path)
	if isLovePath(path) then
		if love_getFileInfo then
			return (love_getFileInfo(path, "file") ~= nil)
		else
			return love.filesystem.exists(path)
		end
	end

	local file = io.open(path, "rb")
	if not file then  return false  end

	file:close()
	return true
end



-- contents = readFile( path )
-- Returns nil and a message on error.
local function readFile(path)
	if isLovePath(path) then
		return love.filesystem.read(path)
	end

	local file, err = io.open(path, "rb")
	if not file then  return nil, err  end

	local contents = file:read"*a"
	file:close()

	return contents
end

-- chunk = loadLuaFile( path )
-- Returns nil and a message on error.
local loadLuaFile = love and love.filesystem.load or loadfile



-- templates = getRequirePath( )
-- templates = "template1;..."
local getRequirePath
	= love and function()
		return normalizePath(love.filesystem.getRequirePath())
	end
	or function()
		return normalizePath(package.path)
	end



local function escapePattern(s)
	return (s:gsub("[-+*^?$.%%()[%]]", "%%%0"))
end



-- path = getModuleFilePath( level, moduleName )
local getModuleFilePath
do
	local TEMPLATE_PATTERN           = "[^" .. escapePattern(TEMPLATE_SEPARATOR) .. "]+"
	local SUBSTITUTION_POINT_PATTERN = escapePattern(SUBSTITUTION_POINT)

	local modulePathCache         = {--[[ [moduleName1]=path, ... ]]}
	local moduleNameModifications = {["."]="/", ["%"]="%%%%"}

	--[[local]] function getModuleFilePath(level, moduleName)
		local path = modulePathCache[moduleName]
		if path then  return path  end

		local moduleNameModified = moduleName:gsub("[.%%]", moduleNameModifications) -- Change e.g. "foo.bar%1" into "foo/bar%%1".

		for template in getRequirePath():gmatch(TEMPLATE_PATTERN) do
			local currentPath = template:gsub(SUBSTITUTION_POINT_PATTERN, moduleNameModified)

			if fileExists(currentPath) then
				path = currentPath
				break
			end
		end

		modulePathCache[moduleName] = path or errorf(incLevel(level), "Cannot find module '%s'.", moduleName)
		return path
	end
end



local fakeModifiedTimes = {}
local fileSizes         = {}

-- time = getLastModifiedTime( path )
-- Returns nil and a message on error.
local getLastModifiedTime
	= love and function(path)
		if isLovePath(path) then
			if love_getFileInfo then
				-- LÖVE 11.0+
				local info = love_getFileInfo(path, "file")
				local time = info and info.modtime
				if time then  return time  end

				return nil, "Could not determine file modification time."

			else
				-- LÖVE 0.10.2-
				return love.filesystem.getLastModified(path)
			end
		end

		-- Try to at least check the file size.
		-- If the size changed then we generate a fake modification time.
		-- @Incomplete: Do this if neither LÖVE nor LuaFileSystem is available.

		local file, err = io.open(path, "rb")
		if not file then
			fakeModifiedTimes[path] = nil
			return nil, "Could not determine file modification time."
		end

		local fileSize = file:seek"end"
		file:close()
		if not fileSize then
			fakeModifiedTimes[path] = nil
			return nil, "Could not determine file modification time."
		end

		local time = fakeModifiedTimes[path]
		if time and fileSize == fileSizes[path] then  return time  end

		fileSizes[path] = fileSize

		time = os.time()
		fakeModifiedTimes[path] = time

		return time
	end

	or function(path)
		return require"lfs".attributes(path, "modification")
	end

-- time = getModuleLastModifiedTime( level, moduleName )
-- Returns nil and a message on error.
local function getModuleLastModifiedTime(level, moduleName)
	return getLastModifiedTime(getModuleFilePath(incLevel(level), moduleName))
end



-- module|nil = loadModule( level, moduleName, protectedLoad )
local function loadModule(level, moduleName, protected)
	local main_chunk, err = loadLuaFile(getModuleFilePath(incLevel(level), moduleName))
	local module

	if protected then
		if not main_chunk then  logError(err) ; return nil  end

		local ok, moduleOrErr = pcall(main_chunk, moduleName)
		if not ok then  logError(tostring(moduleOrErr)) ; return nil  end
		module = moduleOrErr

	else
		if not main_chunk then  error(err, incLevel(level))  end
		module = main_chunk(moduleName)
	end

	if module == nil then  module = true  end
	return module
end

-- resource = loadResource( level, path, protectedLoad )
-- Returns nil and a message on error (if protectedLoad is true, otherwise errors are raised).
local function loadResource(level, path, protected)
	local loader
		=  customLoaders[path]
		or loaders[(path:match"%.([^.]+)$" or ""):lower()]
		or defaultLoader
		or readFile

	local res

	if protected then
		local ok, resOrErr = pcall(loader, path)

		if not ok then
			logError(resOrErr)
			return nil, resOrErr

		elseif not resOrErr then
			local err = "Loader returned nothing for '"..path.."'."
			logError(err)
			return nil, err
		end

		res = resOrErr

	else
		res = loader(path)
		if not res then
			errorf(incLevel(level), "Loader returned nothing for '%s'.", path)
		end
	end

	return res
end



-- index|nil = indexOf( array, value )
local function indexOf(arr, targetV)
	for i, v in ipairs(arr) do
		if v == targetV then  return i  end
	end
	return nil
end

-- removedIndex|nil = removeItem( array, value )
local function removeItem(arr, v)
	local i = indexOf(arr, v)
	if not i then  return nil  end

	table.remove(arr, i)
	return i
end



-- lookupArrayInsert( lookupArray, key, value )
local function lookupArrayInsert(lookupArr, k, v)
	table.insert(lookupArr, v)
	lookupArr[k] = v
end

-- removedValue = lookupArrayRemove( lookupArray, key, index )
local function lookupArrayRemove(lookupArr, k, i)
	local v      = table.remove(lookupArr, i)
	lookupArr[k] = nil
	return v
end

-- removedIndex = lookupArrayRemoveItem( lookupArray, key, value )
local function lookupArrayRemoveItem(lookupArr, k, v)
	if removeItem(lookupArr, v) then
		lookupArr[k] = nil
	end
end



--
-- FFI stuff.
--
local ffi = jit and require"ffi" or nil
local C   = jit and ffi.C        or nil

-- Note: Returns a signed integer!
local function ffi_pointerToInt(ptr)
	return tonumber(ffi.cast("intptr_t", ffi.cast("void*", ptr)))
end



--
-- FFI Windows stuff.
--
local CODE_PAGE_UTF8 = 65001

local INVALID_HANDLE_VALUE = -1

local FILE_NOTIFY_CHANGE_FILE_NAME  = 0x001
local FILE_NOTIFY_CHANGE_DIR_NAME   = 0x002
local FILE_NOTIFY_CHANGE_ATTRIBUTES = 0x004
local FILE_NOTIFY_CHANGE_SIZE       = 0x008
local FILE_NOTIFY_CHANGE_LAST_WRITE = 0x010
local FILE_NOTIFY_CHANGE_SECURITY   = 0x100

local WAIT_OBJECT_0    = 0x00000000
local WAIT_ABANDONED_0 = 0x00000080
local WAIT_TIMEOUT     = 0x00000102
local WAIT_FAILED      = 0xffffffff

local GENERIC_ALL     = 0x10000000
local GENERIC_EXECUTE = 0x20000000
local GENERIC_WRITE   = 0x40000000
local GENERIC_READ    = 0x80000000

local FILE_SHARE_0      = 0x0
local FILE_SHARE_READ   = 0x1
local FILE_SHARE_WRITE  = 0x2
local FILE_SHARE_DELETE = 0x4

local CREATE_NEW        = 1
local CREATE_ALWAYS     = 2
local OPEN_EXISTING     = 3
local OPEN_ALWAYS       = 4
local TRUNCATE_EXISTING = 5

local FORMAT_MESSAGE_ALLOCATE_BUFFER = 0x00000100
local FORMAT_MESSAGE_IGNORE_INSERTS  = 0x00000200 -- Things like "%1".
local FORMAT_MESSAGE_FROM_SYSTEM     = 0x00001000 -- For GetLastError().

local ffiWindows                    = jit ~= nil and jit.os == "Windows"
local ffiWindows_initted            = false
local ffiWindows_watchedDirectories = {--[[ { directory=directory, watcherCount=fileWatchCount, notification=notificationHandle }, ... ]]}

local function ffiWindows_init()
	if ffiWindows_initted then  return  end
	ffiWindows_initted = true

	local ok, err = pcall(ffi.cdef, [[//C
		typedef       int           BOOL, *LPBOOL;
		typedef       unsigned int  UINT;
		typedef       uint32_t      DWORD, *LPDWORD;
		typedef       char          *PSTR, *LPSTR;
		typedef       wchar_t       *LPWSTR;
		typedef       void          *HANDLE, *HLOCAL, *LPVOID;
		typedef const char          *LPCCH;
		typedef const wchar_t       *LPCWSTR;
		typedef const void          *LPCVOID;

		typedef struct {
			DWORD  nLength;
			LPVOID lpSecurityDescriptor;
			BOOL   bInheritHandle;
		} SECURITY_ATTRIBUTES, *LPSECURITY_ATTRIBUTES;

		int MultiByteToWideChar(
			UINT    codePage,
			DWORD   dwFlags,
			LPCCH   lpMultiByteStr,
			int     cbMultiByte,
			LPCWSTR lpWideCharStr,
			int     cchWideChar
		);
		int WideCharToMultiByte(
			UINT    codePage,
			DWORD   dwFlags,
			LPCWSTR lpWideCharStr,
			int     cchWideChar,
			LPCCH   lpMultiByteStr,
			int     cbMultiByte,
			LPCCH   lpDefaultChar,
			LPBOOL  lpUsedDefaultChar
		);

		HANDLE FindFirstChangeNotificationW(
			LPCWSTR lpPathName,
			BOOL    bWatchSubtree,
			DWORD   dwNotifyFilter
		);
		BOOL FindNextChangeNotification(
			HANDLE hChangeHandle
		);
		BOOL FindCloseChangeNotification(
			HANDLE hChangeHandle
		);

		DWORD WaitForSingleObject(
			HANDLE hHandle,
			DWORD  dwMilliseconds
		);
		// DWORD WaitForMultipleObjects(
		// 	DWORD        nCount,
		// 	const HANDLE *lpHandles,
		// 	BOOL         bWaitAll,
		// 	DWORD        dwMilliseconds
		// );

		DWORD GetLastError();

		HANDLE CreateFileW(
			LPCWSTR               lpFileName,
			DWORD                 dwDesiredAccess,
			DWORD                 dwShareMode,
			LPSECURITY_ATTRIBUTES lpSecurityAttributes,
			DWORD                 dwCreationDisposition,
			DWORD                 dwFlagsAndAttributes,
			HANDLE                hTemplateFile
		);
		BOOL CloseHandle(
			HANDLE hObject
		);

		DWORD FormatMessageW(
			DWORD   dwFlags,
			LPCVOID lpSource,
			DWORD   dwMessageId,
			DWORD   dwLanguageId,
			LPWSTR  lpBuffer,
			DWORD   nSize,
			va_list *Arguments
		);

		HLOCAL LocalFree(
			HLOCAL hMem
		);
	]])
	if not ok then
		logWarning("[Windows] Failed registering declarations: %s", err)
	end
end

local function ffiWindows_stringToWide(s)
	local wlen   = C.MultiByteToWideChar(CODE_PAGE_UTF8, 0, s, #s, nil, 0)
	local buffer = ffi.new("wchar_t[?]", wlen+1) -- @Memory @Speed
	C.MultiByteToWideChar(CODE_PAGE_UTF8, 0, s, #s, buffer, wlen)
	return buffer
end

-- string = ffiWindows_wideToString( wideString [, wideLength=zeroTerminated ] )
local function ffiWindows_wideToString(wstr, wlen)
	wlen = wlen or -1

	local len = C.WideCharToMultiByte(
		--[[codePage         ]] CODE_PAGE_UTF8,
		--[[dwFlags          ]] 0,
		--[[lpWideCharStr    ]] wstr,
		--[[cchWideChar      ]] wlen,
		--[[lpMultiByteStr   ]] nil,
		--[[cbMultiByte      ]] 0,
		--[[lpDefaultChar    ]] nil,
		--[[lpUsedDefaultChar]] nil
	)
	local buffer = ffi.new("char[?]", len+1) -- @Memory @Speed

	C.WideCharToMultiByte(CODE_PAGE_UTF8, 0, wstr, wlen, buffer, len, nil, nil)

	return ffi.string(buffer, len)
end

local function ffiWindows_logLastError(funcName, infoStr)
	local errCode       = C.GetLastError()
	local errWstrHolder = ffi.new("LPWSTR[1]") -- [1] is a hack to get a pointer to a pointer working. #JustLuaJitThings

	local errWlen = C.FormatMessageW(
		FORMAT_MESSAGE_ALLOCATE_BUFFER + FORMAT_MESSAGE_FROM_SYSTEM + FORMAT_MESSAGE_IGNORE_INSERTS,
		nil,
		errCode,
		--[[LANG_NEUTRAL]]0x0 + --[[SUBLANG_NEUTRAL]]0x0*2^10, -- MAKELANGID(p, s) = (WORD(s) << 10) | WORD(p)
		ffi.cast("LPWSTR", errWstrHolder),
		0,
		nil
	)

	local errStr = (errWlen > 0) and ffiWindows_wideToString(errWstrHolder[0], errWlen):gsub("%s+$", "") or "<failed getting error message>"
	if errWlen ~= 0 then
		C.LocalFree(errWstrHolder[0]) -- FormatMessageW() allocated this for us.
	end

	hotLoader.log("[Windows] FFI error (function=%s, code=%d, info='%s'): %s", funcName, errCode, infoStr, errStr)
end

-- Note: Returns false on error.
local function ffiWindows_isWritable(fullPath)
	-- https://stackoverflow.com/questions/25227151/check-if-a-file-is-being-written-using-win32-api-or-c-c-i-do-not-have-write-a/25229839#25229839
	local wfullPath = ffiWindows_stringToWide(fullPath)
	local file      = C.CreateFileW(wfullPath, GENERIC_READ, FILE_SHARE_READ, nil, OPEN_EXISTING, 0, nil)

	-- print("isWritable", ffi_pointerToInt(file) ~= INVALID_HANDLE_VALUE, fullPath) -- DEBUG

	if ffi_pointerToInt(file) == INVALID_HANDLE_VALUE then  return false  end

	C.CloseHandle(file)
	return true
end

local function ffiWindows_unwatchDirectory(dirWatcher)
	hotLoader.log("[Windows] Unwatching directory '%s'.", dirWatcher.directory)

	lookupArrayRemoveItem(ffiWindows_watchedDirectories, dirWatcher.directory, dirWatcher)

	if C.FindCloseChangeNotification(dirWatcher.notification) == 0 then
		ffiWindows_logLastError("FindCloseChangeNotification", "directory="..dirWatcher.directory)
	end
end



-- watcher = createAndRegisterWatcher( level, watchers, id, path, value )
local function createAndRegisterWatcher(level, watchers, id, path, value)
	assert(not watchers[id], id)

	local watcher = {
		id       = id,
		value    = value,
		path     = path,
		modified = getLastModifiedTime(path),

		-- ffiWindows:
		fullPath                = "",
		watchedDirectory        = nil, -- If this is nil then we use the normal file modification time check.
		watchedDirectoryChanged = false,
	}
	lookupArrayInsert(watchers, id, watcher)

	if ffiWindows then
		ffiWindows_init()

		if isLovePath(path) then
			local baseDir, err = love.filesystem.getRealDirectory(path) -- Fails when allowPathsOutsideLove is false.
			if not baseDir then
				errorf(incLevel(level), "Could not get base directory for file '%s'. (%s)", path, err)
			end
			watcher.fullPath = baseDir .. "/" .. path

		elseif isPathAbsolute(path) then
			watcher.fullPath = path

		else
			watcher.fullPath = (love and love.filesystem.getWorkingDirectory() or assert(require"lfs".currentdir())) .. "/" .. path
		end

		local dir = watcher.fullPath:gsub("/[^/]+$", "")
		if dir == "" then  dir = "/"  end
		assert(dir ~= watcher.fullPath, dir)

		local dirWatcher = ffiWindows_watchedDirectories[dir]

		if not dirWatcher then
			local wdir = ffiWindows_stringToWide(dir)

			-- Note: FILE_NOTIFY_CHANGE_LAST_WRITE usually fire two (or more?) notifications in a row.
			-- https://devblogs.microsoft.com/oldnewthing/20140507-00/?p=1053
			local notification = C.FindFirstChangeNotificationW(wdir, false, FILE_NOTIFY_CHANGE_LAST_WRITE+FILE_NOTIFY_CHANGE_SIZE)

			if ffi_pointerToInt(notification) == INVALID_HANDLE_VALUE and false then
				ffiWindows_logLastError("FindFirstChangeNotificationW", "directory="..dir)
			else
				hotLoader.log("[Windows] Watching directory '%s'.", dir)
				dirWatcher = {directory=dir, watcherCount=0, notification=notification}
				lookupArrayInsert(ffiWindows_watchedDirectories, dir, dirWatcher)
			end
		end

		if dirWatcher then
			watcher.watchedDirectory = dir
			dirWatcher.watcherCount  = dirWatcher.watcherCount + 1
		end
	end

	return watcher
end

-- unregisterWatcher( watchers, watcher|nil )
local function unregisterWatcher(watchers, watcher)
	if not watcher then  return  end

	lookupArrayRemoveItem(watchers, watcher.id, watcher)

	if ffiWindows then
		local dir        = watcher.watchedDirectory
		local dirWatcher = ffiWindows_watchedDirectories[dir]

		if dirWatcher then
			dirWatcher.watcherCount = dirWatcher.watcherCount - 1
			if dirWatcher.watcherCount == 0 then  ffiWindows_unwatchDirectory(dirWatcher)  end
		end
	end
end



local function noDefaultLoader(path)
	errorf(1, "No loader is available for '%s' (and the default loader is disabled).", path)
end



local function reloadModuleIfModTimeChanged(watcher)
	local modTime = getLastModifiedTime(watcher.path)
	if modTime == watcher.modified then  return  end

	hotLoader.log("Reloading module: %s", watcher.id)
	local module = loadModule(1, watcher.id, true)

	if    module == nil
	then  hotLoader.log("Failed reloading module: %s", watcher.id)
	else  hotLoader.log("Reloaded module: %s"        , watcher.id) ; watcher.value = module  end

	watcher.modified = modTime -- Set this even if loading failed. We don't want to keep loading a corrupt file, for example.
end

local function reloadResourceIfModTimeChanged(level, watcher)
	local modTime = getLastModifiedTime(watcher.path)
	if modTime == watcher.modified then  return  end

	hotLoader.log("Reloading resource: %s", watcher.id)
	local res = loadResource(incLevel(level), watcher.id, true)

	if    not res
	then  hotLoader.log("Failed reloading resource: %s", watcher.id)
	else  hotLoader.log("Reloaded resource: %s"        , watcher.id) ; watcher.value = res  end

	watcher.modified = modTime -- Set this even if loading failed. We don't want to keep loading a corrupt file, for example.
end



--==============================================================
--= Public Functions ===========================================
--==============================================================



local directoryWatcherIndicesToRemove = {}

-- hotLoader.update( deltaTime )
function hotLoader.update(dt)
	local moduleCount = #watchedModules
	local pathCount   = moduleCount + #watchedResources
	if pathCount == 0 then  return  end

	time = time + dt

	local timeBetweenChecks = checkingInterval / pathCount
	local pathsToCheck      = math.min(math.floor(time/timeBetweenChecks), pathCount)
	local checkAllPaths     = pathsToCheck == pathCount

	stateHasBeenReset = false

	--
	-- Check directories.
	--
	if ffiWindows then
		for i, dirWatcher in ipairs(ffiWindows_watchedDirectories) do
			local gotSignal = false

			while true do
				local code = C.WaitForSingleObject(dirWatcher.notification, 0)

				if code == WAIT_OBJECT_0 then
					gotSignal = true

					if C.FindNextChangeNotification(dirWatcher.notification) == 0 then
						ffiWindows_logLastError("FindNextChangeNotification", "directory="..dirWatcher.directory)
						table.insert(directoryWatcherIndicesToRemove, i)
						break
					end

				elseif code == WAIT_TIMEOUT then
					break

				elseif code == WAIT_FAILED then
					ffiWindows_logLastError("WaitForSingleObject", "directory="..dirWatcher.directory)
					break

				else
					logError("[Windows] Internal error: WaitForSingleObject returned unknown code %d.", code)
					break
				end
			end

			if gotSignal then
				-- print("gotSignal!", dirWatcher.directory) -- DEBUG

				-- @Incomplete: Use ReadDirectoryChangesW() instead of FindFirstChangeNotificationW().
				-- https://qualapps.blogspot.com/2010/05/understanding-readdirectorychangesw.html
				for _, watcher in ipairs(watchedModules) do
					if watcher.watchedDirectory == dirWatcher.directory then  watcher.watchedDirectoryChanged = true  end
				end
				for _, watcher in ipairs(watchedResources) do
					if watcher.watchedDirectory == dirWatcher.directory then  watcher.watchedDirectoryChanged = true  end
				end
			end
		end--for ffiWindows_watchedDirectories

		for i = #directoryWatcherIndicesToRemove, 1, -1 do
			local dirWatcher                   = ffiWindows_watchedDirectories[directoryWatcherIndicesToRemove[i]]
			directoryWatcherIndicesToRemove[i] = nil

			ffiWindows_unwatchDirectory(dirWatcher)

			-- Relevant watchers fall back to normal checks.
			for _, watcher in ipairs(watchedModules) do
				if watcher.watchedDirectory == dirWatcher.directory then  watcher.watchedDirectory = nil  end -- Note: We leave watcher.watchedDirectoryChanged as-is.
			end
			for _, watcher in ipairs(watchedResources) do
				if watcher.watchedDirectory == dirWatcher.directory then  watcher.watchedDirectory = nil  end -- Note: We leave watcher.watchedDirectoryChanged as-is.
			end
		end
	end

	--
	-- Check files.
	--
	if ffiWindows then
		for _, watcher in ipairs(watchedModules) do
			if watcher.watchedDirectoryChanged and ffiWindows_isWritable(watcher.fullPath) then
				watcher.watchedDirectoryChanged = false
				reloadModuleIfModTimeChanged(watcher)
			end
		end
		for _, watcher in ipairs(watchedResources) do
			if watcher.watchedDirectoryChanged and ffiWindows_isWritable(watcher.fullPath) then
				watcher.watchedDirectoryChanged = false
				reloadResourceIfModTimeChanged(0, watcher)
			end
		end
	end

	while pathsToCheck > 0 and not stateHasBeenReset do
		pathsToCheck     = pathsToCheck - 1
		time             = time - timeBetweenChecks
		lastCheckedIndex = math.min(lastCheckedIndex, pathCount) % pathCount + 1

		if lastCheckedIndex <= moduleCount then
			local watcher = watchedModules[lastCheckedIndex]
			if not (watcher.watchedDirectory or watcher.watchedDirectoryChanged) then
				reloadModuleIfModTimeChanged(watcher)
			end
		else
			local watcher = watchedResources[lastCheckedIndex - moduleCount]
			if not (watcher.watchedDirectory or watcher.watchedDirectoryChanged) then
				reloadResourceIfModTimeChanged(0, watcher)
			end
		end
	end

	if checkAllPaths then
		time = 0 -- Some protection against lag.
	end
end



-- interval = hotLoader.getCheckingInterval( )
function hotLoader.getCheckingInterval()
	return checkingInterval
end

-- hotLoader.setCheckingInterval( interval )
function hotLoader.setCheckingInterval(interval)
	checkingInterval = interval
end



-- loader = hotLoader.getLoader( fileExtension )
function hotLoader.getLoader(fileExt)
	return loaders[fileExt:lower()]
end

-- hotLoader.setLoader( fileExtension, [ fileExtension2..., ] loader|nil )
-- resource = loader( path )
-- Set or remove a loader for a file extension.
function hotLoader.setLoader(...)
	local argCount = math.max(select("#", ...), 1)
	local loader   = select(argCount, ...)

	assertarg(argCount, "loader", loader, "function","nil")
	if argCount == 1 then  errorf(2, "No file extension specified.")  end

	for i = 1, argCount-1 do
		local fileExt = select(i, ...)
		assertarg(i, "fileExtension", fileExt, "string")
		loaders[fileExt:lower()] = loader
	end
end

-- hotLoader.removeAllLoaders( )
function hotLoader.removeAllLoaders()
	loaders = {}
end

-- loader|nil = hotLoader.getCustomLoader( path )
function hotLoader.getCustomLoader(path)
	return customLoaders[normalizePath(path)]
end

-- hotLoader.setCustomLoader( path, [ path2..., ] loader|nil )
-- resource = loader( path )
-- Set or remove a loader for a specific file path.
function hotLoader.setCustomLoader(...)
	local argCount = math.max(select("#", ...), 1)
	local loader   = select(argCount, ...)

	assertarg(argCount, "loader", loader, "function","nil")
	if argCount == 1 then  errorf(2, "No file path specified.")  end

	for i = 1, argCount-1 do
		local path = select(i, ...)
		assertarg(i, "path", path, "string")
		customLoaders[normalizePath(path)] = loader
	end
end

-- hotLoader.removeAllCustomLoaders( )
function hotLoader.removeAllCustomLoaders()
	customLoaders = {}
end

-- loader|nil = hotLoader.getDefaultLoader( )
function hotLoader.getDefaultLoader()
	return defaultLoader
end

-- hotLoader.setDefaultLoader( loader|nil )
-- resource = loader( path )
-- Specify a nil loader to restore the original default loader (which loads the file as a plain string).
function hotLoader.setDefaultLoader(loader)
	assertarg(1, "loader", loader, "function","nil")
	defaultLoader = loader
end

-- hotLoader.disableDefaultLoader( )
function hotLoader.disableDefaultLoader()
	defaultLoader = noDefaultLoader
end



-- resource = hotLoader.load( path [, customLoader ] )
-- resource = hotLoader.load( path [, protectedLoad=false, customLoader ] )
-- resource = customLoader( path )
-- Returns nil and a message on error (if protectedLoad is true, otherwise errors are raised).
-- If customLoader is set, it replaces the previous custom loader for path.
function hotLoader.load(path, protected, loader)
	if type(protected) == "function" then
		protected, loader = false, protected
	end

	path = normalizePath(path)

	if loader then
		hotLoader.setCustomLoader(path, loader)
	end

	local watcher = watchedResources[path]

	if not watcher then
		local res, err = loadResource(2, path, protected)
		if not res then  return nil, err  end

		watcher = createAndRegisterWatcher(2, watchedResources, path, path, res)
	end

	return watcher.value
end

-- hotLoader.unload( path )
-- Force the resource to reload at next load call.
-- Stops monitoring the file.
function hotLoader.unload(path)
	unregisterWatcher(watchedResources, watchedResources[normalizePath(path)])
end

-- hotLoader.preload( path, resource [, customLoader ] )
function hotLoader.preload(path, res, loader)
	if not res then
		logError("The resource must not be nil or false. (Maybe you meant to use hotLoader.unload()?)")
		return
	end

	path = normalizePath(path)

	if loader then
		hotLoader.setCustomLoader(path, loader)
	end

	local watcher = watchedResources[path]

	if watcher then
		watcher.value    = res
		watcher.modified = getLastModifiedTime(path) -- May be unnecessary in most cases, but we should seldom reach this line anyway.
	else
		createAndRegisterWatcher(2, watchedResources, path, path, res)
	end
end

-- bool = hotLoader.hasLoaded( path )
function hotLoader.hasLoaded(path)
	return watchedResources[normalizePath(path)] ~= nil
end



-- module = hotLoader.require( moduleName )
-- Require a module like the standard Lua require() function.
-- Note that the library's system for modules is not connected to Lua's own system.
function hotLoader.require(moduleName)
	local watcher = (
		watchedModules[moduleName]
		or createAndRegisterWatcher(2, watchedModules, moduleName, getModuleFilePath(2, moduleName), loadModule(2, moduleName, false))
	)
	return watcher.value
end

-- hotLoader.unrequire( moduleName )
-- Force the module to reload at next require call.
-- Stops monitoring the file.
function hotLoader.unrequire(moduleName)
	unregisterWatcher(watchedModules, watchedModules[moduleName])
end

-- hotLoader.prerequire( moduleName, module )
function hotLoader.prerequire(moduleName, module)
	if module == nil then
		logError("The module must not be nil. (Maybe you meant to use hotLoader.unrequire()?)")
		return
	end

	local watcher = watchedModules[moduleName]

	if watcher then
		watcher.value    = module
		watcher.modified = getModuleLastModifiedTime(2, moduleName) -- May be unnecessary in most cases, but we should seldom reach this line anyway.
	else
		createAndRegisterWatcher(2, watchedModules, moduleName, getModuleFilePath(2, moduleName), module)
	end
end

-- bool = hotLoader.hasRequired( moduleName )
function hotLoader.hasRequired(moduleName)
	return watchedModules[moduleName] ~= nil
end



-- hotLoader.monitor( path, onFileModified )
-- hotLoader.monitor( path, callbackData, onFileModified )
-- onFileModified = function( path, callbackData|nil )
function hotLoader.monitor(path, cbData, cb)
	assertarg(1, "path", path, "string")
	local callWithData = (cb ~= nil)

	if callWithData then
		assertarg(3, "onFileModified", cb, "function")
	else
		cbData, cb = nil, cbData
		assertarg(2, "onFileModified", cb, "function")
	end

	hotLoader.preload(path, true, function(path)
		if    callWithData
		then  cb(path, cbData) -- @Incomplete: Allow custom loaders to optionally receive data too.
		else  cb(path)  end
		return true
	end)
end



-- hotLoader.allowExternalPaths( bool )
-- Allow hotLoader to access files outside the default LÖVE directories. May not always work.
-- Note that absolute paths are required to access external files (e.g. "C:/Images/Duck.png").
-- This setting is not used outside LÖVE.
function hotLoader.allowExternalPaths(state)
	allowPathsOutsideLove = not not state
end

-- bool = hotLoader.isAllowingExternalPaths( )
function hotLoader.isAllowingExternalPaths(state)
	return allowPathsOutsideLove
end



-- hotLoader.resetCheckingState( )
-- Make the library start over and check the first monitored file next time hotLoader.update() is called.
-- The current update is aborted if this is called from within a loader.
function hotLoader.resetCheckingState()
	time              = 0
	lastCheckedIndex  = 0
	stateHasBeenReset = true
end



-- logFormat = hotLoader.getLogFormat( )
function hotLoader.getLogFormat()
	return logFormat
end

-- hotLoader.setLogFormat( logFormat )
-- Set message format used by hotLoader.log().
-- Use the percent sign to indicate where the values go:
--   %m = the message
--   %d = the current date (YYYY-MM-DD)
--   %t = the current time (HH:MM:SS)
--   %% = a literal percent sign
-- The default format is "[HotLoader|%t] %m"
function hotLoader.setLogFormat(s)
	local hasD = false
	local hasM = false
	local hasT = false

	for c in s:gmatch"%%(.)" do
		if     c == "d" then  hasD = true
		elseif c == "m" then  hasM = true
		elseif c == "t" then  hasT = true
		elseif c ~= "%" then  errorf(2, "Invalid option '%%%s'. (Valid options are %%d, %%m and %%t)", c)  end
	end

	logFormat     = s
	logFormatHasD = hasD
	logFormatHasM = hasM
	logFormatHasT = hasT
end



-- hotLoader.cleanup( )
-- Free up allocated OS resources. Calling this is only necessary if the library
-- module is unloaded (which probably no one does - only our test suite), and
-- currently only in LuaJIT (including LÖVE) on Windows. @Undocumented
function hotLoader.cleanup()
	for i = #watchedModules  , 1, -1 do  unregisterWatcher(watchedModules  , watchedModules  [i])  end
	for i = #watchedResources, 1, -1 do  unregisterWatcher(watchedResources, watchedResources[i])  end
end



-- hotLoader.log( formatString, value1, ...)
-- Internal function for printing messages.
-- To silence the library you can do hotLoader.log=function()end
function hotLoader.log(s, ...)
	s             = s:format(...)
	local dateStr = logFormatHasD and os.date"%Y-%m-%d"
	local timeStr = logFormatHasT and os.date"%H:%M:%S"

	print((logFormat:gsub("%%(.)", function(c)
		if     c == "m" then  return s
		elseif c == "d" then  return dateStr
		elseif c == "t" then  return timeStr
		else                  return c  end
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
		function(path)  return (love.audio.newSource(path, "static"))  end
	)
	hotLoader.setLoader(
		"mp3",
		"699","amf","ams","dbm","dmf","dsm","far","it","j2b","mdl","med",
			"mod","mt2","mtm","okt","psm","s3m","stm","ult","umx","xm",
		"abc","mid","pat",
		function(path)  return (love.audio.newSource(path, "stream"))  end
	)
end

return hotLoader
