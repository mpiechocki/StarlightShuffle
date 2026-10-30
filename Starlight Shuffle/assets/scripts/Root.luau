--!strict
--@client
local engine = require('@moonbase/engine')
local game = require('@moonbase/game')
local client = require('@moonbase/client')
local runtime = require('@flutter_luau/runtime')
local w = require('@flutter/widgets')
local p = require('@flutter/painting')
local ui = require('@dart/ui')
local fonts = require('@fonts/app')
local Protocol = require('./shared/Protocol')

--@property
local title: string = "Starlight Shuffle"
local cancelMessages: (() -> ())? = nil

return engine.defineScript({
    onStart = function()
        cancelMessages = client.onMessage(function(kind: unknown, message: unknown)
            if kind == Protocol.welcome then print(message) end
        end)
        -- This view renders the active scene. Add Flutter widgets to the overlay.
        runtime.runView(w.Stack({children = {
            game.GameView(),
            w.SafeArea({child = w.Align({alignment = p.Alignment.bottomCenter,
                child = w.Padding({padding = p.EdgeInsets.all(24),
                    child = w.Container({padding = p.EdgeInsets.all(20),
                        decoration = p.BoxDecoration({
                            color = ui.Color({value = 0xee202939}),
                            borderRadius = p.BorderRadius.circular(16),
                        }),
                        child = w.Column({mainAxisSize = w.MainAxisSize.min, children = {
                            w.Text({data = title, style = p.TextStyle({fontFamily = fonts.lato,
                                fontSize = 22, fontWeight = ui.FontWeight.w700,
                                color = ui.Color({value = 0xfff3f5fa})})}),
                            w.SizedBox({height = 8}),
                            w.Text({data = 'Your world starts here.',
                                style = p.TextStyle({fontFamily = fonts.lato, fontSize = 14,
                                    color = ui.Color({value = 0xffb4c1d6})})}),
                            w.SizedBox({height = 16}),
                            w.GestureDetector({onTap = function()
                                client.notifyServer(Protocol.hello)
                            end, child = w.Container({
                                padding = p.EdgeInsets.symmetric({horizontal = 20, vertical = 10}),
                                decoration = p.BoxDecoration({color = ui.Color({value = 0xff79b4dd}),
                                    borderRadius = p.BorderRadius.circular(24)}),
                                child = w.Text({data = 'Say hello', style = p.TextStyle({
                                    fontFamily = fonts.lato, fontSize = 14, fontWeight = ui.FontWeight.w700,
                                    color = ui.Color({value = 0xff142538})})}),
                            })}),
                        }}),
                    }),
                }),
            })}),
        }}))
        game.loadScene(game.entryScene):andThen(function(_scene: engine.Scene)
            print('Scene ready: ' .. game.entryScene)
        end)
    end,
    onDestroy = function()
        if cancelMessages then cancelMessages(); cancelMessages = nil end
    end,
})
