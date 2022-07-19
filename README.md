# LuaHotLoader

<p>
	<a href="https://github.com/ReFreezed/LuaHotLoader/releases/latest">
		<img src="https://img.shields.io/github/release/ReFreezed/LuaHotLoader.svg" alt="">
	</a>
	<a href="https://github.com/ReFreezed/LuaHotLoader/blob/master/LICENSE.txt">
		<img src="https://img.shields.io/github/license/ReFreezed/LuaHotLoader.svg" alt="">
	</a>
</p>

**LuaHotLoader** is a Lua library for hot-loading files, including modules.
Works with *LuaFileSystem* or [*LÖVE*](https://love2d.org/) 0.10+.

- [Basic usage](#basic-usage)
	- [With LuaFileSystem](#with-luafilesystem)
	- [In LÖVE](#in-lÖve)
- [Documentation](http://refreezed.com/luahotloader/docs/)
- [Help](#help)



## Basic usage


### With LuaFileSystem

```lua
local hotLoader = require("hotLoader")
local duckPath  = "duck.jpg"

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
	local duckData = hotLoader.load(duckPath)
	print("Duck is "..(#duckData).." bytes")

	lastTime = currentTime
end
```


### In LÖVE

```lua
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
```



## Documentation

- [Website](http://refreezed.com/luahotloader/docs/)
- [The source code](preprocess.lua)



## Help

Got a question?
If the [documentation](http://refreezed.com/luahotloader/docs/) doesn't have the answer,
look if someone has asked the question in the [issue tracker](https://github.com/ReFreezed/LuaHotLoader/issues?q=is%3Aissue),
or [create a new issue](https://github.com/ReFreezed/LuaHotLoader/issues/new).


