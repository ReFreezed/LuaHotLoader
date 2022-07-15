function love.conf(t)
    t.modules.audio    = false
    t.modules.data     = false
    t.modules.event    = false
    t.modules.font     = false
    t.modules.graphics = false
    t.modules.image    = false
    t.modules.joystick = false
    t.modules.keyboard = false
    t.modules.math     = false
    t.modules.mouse    = false
    t.modules.physics  = false
    t.modules.sound    = false
    t.modules.system   = false
    t.modules.thread   = false
    t.modules.timer    = true -- LuaHotLoader should work even if we disable the timer module, but pretty much all LÖVE programs probably do load it.
    t.modules.touch    = false
    t.modules.video    = false
    t.modules.window   = false
end
