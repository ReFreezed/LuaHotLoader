# LuaHotLoader

![version 1.0.1](https://img.shields.io/badge/version-1.0.1-green.svg)

Hot-load any file, including Lua files. Works with *LuaFileSystem* or [*LÖVE*](https://love2d.org/) (including 11.0 and 0.10).

- [Usage with LuaFileSystem](#usage-with-luafilesystem)
- [Usage in LÖVE](#usage-in-lÖve)
- [API](#api)



## Usage with LuaFileSystem

```lua
local hotLoader     = require("hotLoader")
local duckImagePath = "duck.jpg"

-- Initial loading of resources.
hotLoader.load(duckImagePath)

-- Program loop.
local lastTime = os.time()
while true do
	local currentTime = os.time()

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
```

## Usage in LÖVE

```lua
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
```



## API

Check the [source code](hotLoader.lua) for more info.

```lua
hotLoader.allowExternalPaths()
hotLoader.disableDefaultLoader()
hotLoader.getCheckingInterval()
hotLoader.getCustomLoader()
hotLoader.getDefaultLoader()
hotLoader.getLoader()
hotLoader.load()
hotLoader.preload()
hotLoader.prerequire()
hotLoader.removeAllCustomLoaders()
hotLoader.removeAllLoaders()
hotLoader.require()
hotLoader.setCheckingInterval()
hotLoader.setCustomLoader()
hotLoader.setDefaultLoader()
hotLoader.setLoader()
hotLoader.unload()
hotLoader.unrequire()
hotLoader.update()
```
