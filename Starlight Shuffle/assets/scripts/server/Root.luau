--!strict
--@server
local server = require('@moonbase/server')
local Protocol = require('../shared/Protocol')

-- Server code owns gameplay decisions. The Go host owns networking and instances.
server.onMessage(function(player: server.Player, kind: unknown)
    if kind == Protocol.hello then
        server.notifyPlayers({player}, Protocol.welcome, 'Hello from your world server!')
    end
end)

return server.defineScript({})
