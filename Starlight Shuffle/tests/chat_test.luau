--!strict
-- The lobby chat (server/Chat) over a hand-driven host and platform
-- (tests/fixtures/ChatHost): moderation, order, blocks, mutes, typing and the
-- message validators (shared/Net).
local test = require("@moonbase/test")
local Net = require("@project/shared/Net")
local Chat = require("@project/server/Chat")
local ChatHost = require("@tests/fixtures/ChatHost")

-- The texts [session] heard, oldest first.
local function heard(fake: ChatHost.Fake, session: number): {string}
	local out: {string} = {}
	for _, message in fake:got(session, Net.SAY) do table.insert(out, message[4] :: string) end
	return out
end

test.unit("arrivals hear where reports go; messages reach others once allowed", function(t)
	local fake = ChatHost.new()
	fake.answer = function() return ChatHost.relations() end
	local chat = Chat.new(fake.host)
	local a, b = fake:player(1, 101), fake:player(2, 102)
	chat.added(a); chat.added(b)
	t:equal(fake:got(1, Net.CHAT)[1][2], ChatHost.EXPERIENCE)
	t:equal(chat.receive(a, Net.SAY, "  hello   there "), true)
	-- The sender sees it at once, others once moderation allows it.
	t:equal(heard(fake, 1)[1], "hello there")
	t:equal(#heard(fake, 2), 0)
	t:equal(#fake.checks, 1)
	t:equal(fake.checks[1].room.name, "Lobby")
	fake.checks[1].done(true)
	local got = fake:got(2, Net.SAY)[1]
	t:equal(got[2], 1); t:equal(got[3], "P101"); t:equal(got[4], "hello there"); t:equal(got[6], "test_1")
	-- A blocked message reaches nobody else.
	fake:advance(1)
	chat.receive(a, Net.SAY, "rude")
	fake.checks[2].done(false)
	t:equal(#heard(fake, 2), 1)
	-- Anything else is not the chat's.
	t:equal(chat.receive(a, Net.START, nil), false)
end)

test.unit("chat goes out in the order it was said, and undecided messages go out after a while", function(t)
	local fake = ChatHost.new()
	fake.answer = function() return ChatHost.relations() end
	local chat = Chat.new(fake.host)
	local a, b = fake:player(1, 101), fake:player(2, 102)
	chat.added(a); chat.added(b)
	chat.receive(a, Net.SAY, "one")
	fake:advance(1)
	chat.receive(a, Net.SAY, "two")
	-- The second is allowed first, but waits for the first.
	fake.checks[2].done(true)
	t:equal(#heard(fake, 2), 0)
	fake.checks[1].done(true)
	local texts = heard(fake, 2)
	t:equal(texts[1], "one"); t:equal(texts[2], "two")
	-- Moderation that never answers delivers anyway.
	fake:advance(1)
	chat.receive(a, Net.SAY, "three")
	fake:advance(5)
	t:equal(heard(fake, 2)[3], "three")
end)

test.unit("too soon, empty or too long messages are dropped", function(t)
	local fake = ChatHost.new(false)
	fake.answer = function() return ChatHost.relations() end
	local chat = Chat.new(fake.host)
	local a, b = fake:player(1, 101), fake:player(2, 102)
	chat.added(a); chat.added(b)
	chat.receive(a, Net.SAY, "first")
	chat.receive(a, Net.SAY, "too soon")
	fake:advance(1)
	chat.receive(a, Net.SAY, "   ")
	chat.receive(a, Net.SAY, string.rep("x", Net.MAX_CHARS + 1))
	-- Without a platform that keeps chat, it goes out at once, with no id.
	local texts = heard(fake, 2)
	t:equal(#texts, 1); t:equal(texts[1], "first")
	t:equal(fake:got(2, Net.SAY)[1][6], nil)
	t:equal(#fake:got(1, Net.CHAT)[1], 1)
end)

test.unit("a pair with a block never hears each other, and a joiner hears nobody until its relations come", function(t)
	local fake = ChatHost.new(false)
	local chat = Chat.new(fake.host)
	local a, b, c = fake:player(1, 101), fake:player(2, 102), fake:player(3, 103)
	chat.added(a) -- alone: answered at once
	chat.added(b)
	t:equal(chat.hears(1, 2), false)
	fake.asks[1].done(ChatHost.relations())
	t:equal(chat.hears(1, 2), true)
	chat.added(c)
	fake.asks[2].done(ChatHost.relations({101}))
	t:equal(chat.hears(1, 3), false); t:equal(chat.hears(2, 3), true)
	chat.receive(a, Net.SAY, "hi all")
	t:equal(#heard(fake, 2), 1); t:equal(#heard(fake, 3), 0)
	-- Relations that never come hear everyone after a while.
	local d = fake:player(4, 104)
	chat.added(d)
	fake:advance(5)
	t:equal(chat.hears(1, 4), true)
end)

test.unit("a muted player is heard only by themselves, and their typing is not shown", function(t)
	local fake = ChatHost.new()
	fake.answer = function() return ChatHost.relations() end
	local chat = Chat.new(fake.host)
	local a, b = fake:player(1, 101, {alias = "Quiet", muted = true}), fake:player(2, 102)
	chat.added(a); chat.added(b)
	chat.receive(a, Net.TYPING, true)
	chat.receive(a, Net.SAY, "anyone?")
	t:equal(heard(fake, 1)[1], "anyone?")
	t:equal(#heard(fake, 2), 0)
	t:equal(#fake:got(2, Net.TYPING), 0)
	t:equal(#fake.checks, 0)
end)

test.unit("typing shows to others, and a message ends it", function(t)
	local fake = ChatHost.new(false)
	fake.answer = function() return ChatHost.relations() end
	local chat = Chat.new(fake.host)
	local a, b = fake:player(1, 101), fake:player(2, 102)
	chat.added(a); chat.added(b)
	chat.receive(a, Net.TYPING, true)
	chat.receive(a, Net.TYPING, true) -- no change, no message
	local typing = fake:got(2, Net.TYPING)
	t:equal(#typing, 1); t:equal(typing[1][2], 1); t:equal(typing[1][3], true)
	chat.receive(a, Net.SAY, "done")
	typing = fake:got(2, Net.TYPING)
	t:equal(#typing, 2); t:equal(typing[2][3], false)
	-- Someone who arrives hears who is typing already.
	chat.receive(b, Net.TYPING, true)
	local c = fake:player(3, 103)
	chat.added(c)
	t:equal(fake:got(3, Net.TYPING)[1][2], 2)
end)

test.unit("chat validators keep one trimmed line, roles and message ids", function(t)
	t:equal(Net.text(" a\n\tb "), "a b")
	t:equal(Net.text(""), nil)
	t:equal(Net.text(5), nil)
	local roles = Net.roles({"Creator I", "Creator I", "bad  role", 7, "Moon II"})
	t:equal(#roles, 2); t:equal(roles[2], "Moon II")
	t:equal(Net.messageId("abc_1-2"), "abc_1-2")
	t:equal(Net.messageId("no spaces"), nil)
	t:equal(Net.experience("Shuffle1"), "Shuffle1")
	t:equal(Net.experience("short"), nil)
end)
