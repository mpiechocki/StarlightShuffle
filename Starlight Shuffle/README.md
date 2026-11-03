# Starlight Shuffle

For coding agents and scripting guidance, read [AGENTS.md](AGENTS.md). It explains
the runtime, bindings, client/server boundaries, UI, components, and project tests.

Players gather in a **lobby**, go off together to play short multiplayer
**mini-games** one at a time, and come back to the lobby between them, earning **Starlights** that rank them on a **leaderboard** and buy
name styles, nameplates and avatar glows in the lobby's **shop**.
Open this folder in Moonbase, sign in and press **Play** (the arrow beside it sets
the client count; pick the `lobby` profile to start the way a real launch does).

## Places

Every server instance runs the same server root (`server/Root.luau`) and is one
*place*, chosen by its hosting profile in `project.json`:

| Profile | Runs | Seats |
| --- | --- | --- |
| `lobby` (initial) | `server/Lobby.luau` in the `lobby` scene. Launches land here, and everyone comes back here between mini-games. | 24 |
| `cycle` | `server/Cycle.luau`: one mini-game for a group the lobby sent, started for it. | 24 |

**Lobby.** Everyone walks around in their own outfit, as in Sky Lounge, in a pastel
arcade lounge floating on a cloud under a night sky. Tapping the **arcade** (its
doorway, the little room behind it or a cabinet; "Join mini-games" floats over it)
checks the player in for the next mini-game (see Three players and Between
mini-games). The **leaderboard**
board on the wall beside it, and the trophy button in the HUD, open the leaderboard.
Tap targets are found by id prefix: `start-…` and `leaderboard-…` (`Root.luau`).

**Lobby art.** The lobby scene places the pastel arcade lobby kit's models
(`assets/models/lobby/`; the kit's sources and notes in `art/lobby/`) exactly where
the kit's assembled lobby has them: the shop, the sofa corner, the moon rug, the
constellation walls, the leaderboard and the arcade doorway. The room behind the
doorway is built from boxes. The arcade entrance follows the renders: a cream arch
with a gold edge, a plaque behind the ARCADE lettering and a round star rug inside
(`tools/lobby_arcade.py`, laid over the kit doorway, whose own trim the scene
hides), cabinets in pairs with glowing screens and hanging stars; the sign colours
come from `tools/lobby_signs.py`. The sky is Sky Lounge's dome with a painted night sky
(`tools/lobby_sky.py`), and `tools/lobby_cloud_base.py` makes the cloud it floats
on. Lighting is baked (`scenes/lobby.lighting.bin`): a baked key and fill light plus
stationary glows at every lamp, sconce and star. After moving anything static,
bake again (**Baked lighting** in the editor, or `bake_lighting` over MCP).

**Mini-games.** The lobby picks them: `shared/Games.luau` in order (the admins'
lineup), looping. Everyone checked in goes together to a new `cycle` place of its
own, which plays that one mini-game: *intro* (its scene loads, everyone lands in
it, "Up next" shows for its `intro` seconds) → *playing* (its `duration`) →
*results* (everyone's Starlights for it, 7 s). Then everyone goes back to the
lobby they came from (any lobby with room if it has none), still checked in for
the next one unless they paused. Arrivals join the mini-game under way; once it is
over, they are sent straight back.

**Between mini-games.** The group's return starts the lobby's countdown
(`Games.BREAK`, 20 s): the lobby picks and names the next mini-game, the HUD's
head reads "Up next: …" with "Starts in 0:18 · you're in" (or "· tap the arcade")
and a draining bar, and for those checked in a big 3, 2, 1 ends it. Everyone in
the lobby can join it by tapping the arcade, or tap again to sit it out. When it
ends, everyone checked in goes, if there are at least three; if not, they stay in
the lobby, checked in, until a third checks in. So everyone in a lobby (up to 24)
plays together, and the lobby is where they meet between games.

**Three players.** No mini-game starts with fewer than `Games.MIN_PLAYERS` (3)
players. Tapping the arcade in the lobby checks you in for the next mini-game (tap
it again to check out); you stay in the lobby, chatting, and the hint above the chat
bar says how many are in ("You're in! 2 of 3 ready · waiting for 1 more player").
With no mini-game on or counting down, once three are checked in the lobby sends
them all at once (`server/Lobby`). There is no waiting room: the group goes from
the lobby straight into the mini-game, whose intro starts as the first of them
lands (4 s longer than usual, so the rest land during it; the mini-game itself is
set up once they are all there and their outfits are known); if the group is
still short when it ends, they go back to the lobby, still checked in. A mini-game
already playing plays on when someone leaves.

**While a group is playing.** Every mini-game place publishes its phase,
mini-game, player count, when its phase ends and its lobby in its instance
metadata (`Travel.publish`), and its lobby looks every 2 s (`Travel.cycles`).
While a group from this lobby is playing, the hint reads "Tap the arcade to join
the next mini-game · Lucky Shot is on now", and whoever checks in ("You're in!
You'll join the next mini-game") waits for the group to come back and goes with
it after the countdown.

**Timer.** Before and during every mini-game the middle of the HUD's head is the
cycle's timer, the same for all of them: "Starts in" through the intro, then "Time
left", with a draining bar, amber for the last 10 s (`widgets/Hud`, from
`client/Place.clock`). A mini-game whose play is not the cycle's playing phase gives
its own clock (`clock` in `client/Minigame`; Pillow Fight counts down to and through
its 60 s battle). Mini-games show no time of their own: their top panels (scores,
Star Pass's burst fuse) sit below the head, from `GameUi.HEAD`.

**Pause/Play.** In the head's right: pressing Pause marks you to sit out the next
mini-game, and the button turns into a gold **Stay**. Everyone goes back to the
lobby when the results end; you arrive there not checked in (tap the arcade to
join again). Pressing Stay before then keeps you checked in.

**Chat.** The lobby has a chat like Sky Lounge's, ported from it, and it is one
chat with every mini-game its players are off in: what anyone says in the lobby
or in any of those mini-games reaches all of them. Each place's `server/Chat`
moderates its own players' messages; an allowed one is appended to a short list
in `@moonbase/storage` named by the lobby (`server/ChatRelay`: the last 50, kept
an hour), with a hint on its channel, and the other places read what is new (on
the hint, and every 4 s besides) and deliver it to their players, blocks
included (a speaker elsewhere has their relations with everyone here asked for
first). Typing dots stay in their own place. On the client a speaker in another
place has a negative id (no avatar of theirs is here) and comes with their
account and thumbnail; the history carries over moves between places. In a
mini-game the chat is put away: a chat button beside Pause/Play, with a count of
what was said since, opens it over everything (a dimmed backdrop, the history
open, a close button where the chat button was; `widgets/LobbyChat`), and no
speech bubbles show over the players there. The chat bar along the bottom (`widgets/ChatBar`)
sends messages with the app's custom emoji (`:name:` codes, `widgets/EmojiPicker`),
and its bubble button opens the recent history; the latest lines also show along the
top left under the head (`widgets/ChatFeed`). Speech bubbles and typing dots float over
avatars, with name tags under them that stay faint until you walk up
(`widgets/PlayerLabels`, projected each frame by `client/Chat`). The chat rules show
the first time a player goes to chat on a device (`widgets/ChatRules`, kept as
`chat.rules` in the device preferences), and pressing and holding someone else's
message offers to report it in the app (`widgets/MessageMenu`). On the server
(`server/Chat`), messages reach others once the platform's moderation allows them
(`@moonbase/social`), in the order each player said them; a muted player is heard
only by themselves; a pair with a block either way never hears each other (they still
see each other's avatars, unlike Sky Lounge, where blocked players are hidden).
Nothing said is kept. Every platform call fails open, so local Play delivers chat
unmoderated. Tests: `tests/chat_test.luau`.

**Idle stop.** The host never stops idle instances, so a place stops itself once it
has been empty for 30 s (cycle) or 300 s (lobby).

## Starlights and the leaderboard

**Rewards** (`shared/Rewards.luau`, configurable there): every mini-game pays its
top three 50, 25 and 10 Starlights, and nobody else anything.

`server/Starlights.luau` keeps every player's Starlight balance in `@moonbase/storage`:
a sorted set ranks players by what they have (the shop spends from it, so the
leaderboard is by current balance), and a hash keeps the name each was last seen
with. So balances outlast sessions, places and launches. A cycle adds a mini-game's
Starlights in one storage operation when its results show, boosting each player's
take there by their booster (floor(take x highest active multiplier), once per
round) and writing it to their history; its id (instance and round) makes a retried
award count once. The cycle's results show what was given. The HUD shows your
balance in every place; the leaderboard lists the top 20 and your rank.

## The shop

Tapping the **shop stall** in the lobby ("Shop" floats over it) opens the shop
(`client/Shop`, `widgets/ShopPanel`, after the shop preview in
`starlight-games/shop`): a portrait panel at most 447 wide over the dimmed lobby,
with your Starlight and Stars balances, the tabs **Names**, **Nameplates**,
**Avatar Glow** and **Boosters**, and your look (your name and plate over your
avatar with its glow, the three slots, Reset preview). Items sort by price across
currencies; selecting one only previews it. The catalogue, prices and rules are in
`shared/Shop.luau`; how each cosmetic looks in `client/Looks.luau`, drawn by
`widgets/Cosmetics.luau` (names and plates are painted in Flutter: gradients,
stars, rosettes and ornaments; the currency icons are the supplied pixel art).

- **Currencies.** Starlight buys the static cosmetics; Stars (the player's
  Everskies currency, `primary` in `@moonbase/economy`) buy the animated ones and
  the boosters. The Stars balance shown is the app's for the signed-in account,
  less what the shop spent this session.
- **Account** (`server/Accounts.luau`, in storage against the account id):
  ownership, the equipped name, plate and glow, booster tokens with what they cost,
  the running booster and its expiry, the permanent tier, the accessibility
  settings, the last 30 history lines and a durable record of each Stars purchase.
  An account that cannot be read is never overwritten: the shop says so and buying
  stays off.
- **Starlight purchases** take the Starlight and grant the item in one storage
  operation (both or neither); a retried request counts once.
- **Stars purchases** are written down first (blocking other purchases until they
  settle), charged with the purchase's id as the platform's operation id (asking
  again never charges twice), then delivered. A refusal fails it with nothing
  taken; an unknown answer stays **pending** ("don't buy it again") and is asked
  again a little later and whenever the player arrives anywhere; a charge whose
  delivery fails is delivered again the same way.
- **Boosters.** Weekly ones buy a token, activated later (with its own
  confirmation) for seven days in a row on the datastore's clock; one runs at a
  time. Permanent ones apply at once; Eternal Radiance upgrades to Eternal
  Supernova for 6,000 Stars. Boosters never stack, purchases that would not help are
  blocked, and a permanent booster refunds (through the platform, once) the unused
  weekly tokens it makes redundant. The tab shows your multiplier, running booster
  and tokens; the other tabs don't.
- **Wearing it.** Equipping saves at once and is broadcast on your avatar's
  identity: name tags in the lobby show the name style and plate (your own too
  while you wear one; a styled tag stays at least 85% visible however far away),
  and every mini-game's figures carry the same tag (`widgets/PlayerTag`, which
  reads everyone's look from `client/Looks`): Blast Mining, Lucky Shot and
  Starcatchers name every figure near you, and Star Pass and Pillow Fight swap
  their own name pills for it when the player wears a look. Head to Head shows
  only heads on its tiles, so it has no tags; the glow is a halo of soft
  particles on a sheet just behind the avatar, turned to the camera and sized to the
  outfit's drawn bounds, so the outfit hides its middle (the `aura` child of the
  avatar prefab, placed by `client/Multiplayer`; the avatar renderer has no outline,
  so the exact silhouette glow is the shop preview's).
  Score tables and chat keep plain names.
- **Settings** (the sliders button): reduce motion (looks stand still; the device's
  own setting counts too), reduce cosmetic glow and effects, and the purchase history.

In editor Play the economy is the SDK's stand-in: Stars purchases succeed without
touching any wardrobe or balance.

**Admin test tools.** Admins (`server.startup.admins`) see a flask button in the
shop's header that opens **Test tools**; the server checks every use
(`SHOP_TEST`, `server/Accounts`) and tells nobody else they exist:

- **Balances:** +1,000 / +10,000 Starlight (an unboosted "Admin test grant" in the
  history; it counts on the leaderboard), Starlight to 0, and +20,000 test Stars,
  which exist only in editor Play and only in the shop's displayed balance: real
  Stars are never granted.
- **Rewards:** a simulated 1st place (50) or 3rd place (10) through the
  real award, boosted by your booster; "Repeat last reward" re-sends the same
  round id and must add nothing.
- **Next Stars purchase:** normal, refused (not enough Stars), an unknown answer
  (pending, settled by the retry about 20 s later) or a delivery that fails once
  (charged, delivered by the retry). The fault is used up by one purchase.
- **Boosters:** end the running weekly booster now, or in one minute.
- **Account:** reset your shop account (everything but your Starlight; refused
  while a purchase is settling).

To test refunds: buy a weekly token or two, then a permanent booster.

Local Play starts each run with an empty datastore, so totals reset between Play runs
there; within a run they carry across moves between places.

## Admins and the mini-game lineup

Admins get a lineup button (sliders icon): in the lobby next to the leaderboard (under
the Starlights pill while the lobby counts down), in a mini-game under the
Starlights pill. It opens a panel listing every mini-game in order, the one on now
and the one up next marked, each with a tick box. Lobbies pick only the ticked
mini-games, in that order, from their next pick (at least one stays ticked;
**Include all** restores them all). A game that needs
more players than are there is still skipped, unless only such games are ticked.

- **Who is an admin:** the account ids under `admins` in the server's startup settings
  (`project.json` → `server.startup`, editable in the editor's project settings). The
  platform does not expose the world testers list to game scripts, so the testers' ids
  go there by hand. It holds `22919001` (the editor account used for Play) for now.
  Nobody else sees the button, and the server ignores lineup changes from non-admins.
- **Where it lives:** `server/Lineup.luau` keeps it in `@moonbase/storage`, so one
  change reaches every lobby and mini-game. A lobby reads it again as each countdown
  starts. Nothing stored means every mini-game. Like Starlights, local
  Play starts each run with it cleared.
- **Code:** `server/Admins.luau`, `server/Lineup.luau`, `Games.pick` / `Games.included`
  in `shared/Games.luau`, the ADMIN and LINEUP messages in `shared/Net.luau`, and
  `widgets/Lineup.luau`. `tests/lineup_test.luau` covers picking, the admin list and the
  message.

## Mini-games

Each mini-game has:

- a scene, `scenes/<id>.json`, with a `player-spawn` entity and a camera;
- a server module, `assets/scripts/minigames/<id>/Server.luau`: its rules, scoring
  and awards (the contract is in `server/Minigame.luau`);
- a client module, `assets/scripts/minigames/<id>/Client.luau`: its HUD, effects
  and taps (the contract is in `client/Minigame.luau`).

They talk to each other through `context.send(...)` on either side, which arrives as
`receive(...)` on the other (the server's also names the player). The cycle owns the
scene loading, avatars, timing, results and Starlights; a mini-game only decides what
happens during play and calls `context.award(player, n)`.

A mini-game's `shared/Games.luau` row may set `intro` (seconds announced before play,
default 5) and `minPlayers`: the cycle skips that game in rounds with fewer players
(never fewer than `Games.MIN_PLAYERS`, 3, which every mini-game needs). Its client module may set `ownHud` (it draws its own status and results; the
cycle's HUD keeps only Starlights, the timer and Pause/Play), `clock` (its own
clock for the timer) and `fixedCamera` (the camera holds
the scene's authored view instead of following the avatar).

The cycle plays, in order:

- **Head to Head** (`head_to_head`, first): players race to reproduce a shared 3×3
  reference board, with avatar heads instead of colours. See below.
- **Blast Mining** (`blast_mining`, second): a 60 s timing race. Rocks, gems and bombs
  fall into each miner's strike circle, and a tap anywhere swings. See below.
- **Lucky Shot** (`lucky_shot`, third): a 45 s race to tap clouds in one shared sky
  with a slingshot. See below.
- **Star Pass** (`star_pass`, fourth): hot potato with glowing stars,
  played in waves until one player is left. See below.
- **Pillow Fight** (`pillow_fight`, fifth): a one-minute free-for-all in rooms of three
  or four, with filler bots, one winner per room. See below.
- **Starcatchers** (`starcatchers`, sixth): 60 s of throwing a small net into your own
  stream of drifting stars, dodging satellites. See below.

An empty cycle waits 3 s after its first arrival before announcing a mini-game, so a
group sent together all take part in it.

### Head to Head

Files: `minigames/head_to_head/` holds `Rules` (shared rules and wire format), `Round`
(the authoritative round; `Server` adapts the cycle's context to it), `Client` (state,
optimistic taps, reconciliation), `Board` (the screen) and `Heads` with `Library` (the
library artwork). The scene `head_to_head` is the pastel art room, seen from a fixed
camera; avatars stand behind it.

- **Players.** Everyone in the cycle when Head to Head is announced takes part, and the
  list is frozen then. Anyone who arrives later watches and plays the next mini-game.
- **Pool.** Every participant's head, plus distinct library heads until there are 8
  (none with 8 or more players), shuffled into a fixed tap cycle. Each head has its own
  outline colour. The server draws all of it and sends the same copy to everyone. Player
  heads are cropped from their outfit image. Library heads are the 8 approved images
  from the prototype, cropped to their heads, in `assets/textures/head_to_head/`. They
  ship with the scene through its `library-heads` entity.
- **Round.** A 10 s preparation (the cycle's intro) shows the instructions in the
  reference's place, with the canvas empty and disabled. The reference reaches clients
  only when 90 s of play starts.
- **Play.** The server owns every canvas. Clients send tap actions with a sequence each.
  The server applies each sequence once, in order, and only during play, before the
  deadline and on an unfinished canvas. It answers each tap with the canvas, which the
  client reconciles with taps it already showed. Nine matches complete and lock a
  canvas, with the server's elapsed time and a completion sequence for ties. Play ends
  at 90 s, or when every connected participant has finished.
- **Podium.** The three fastest completed boards win 50, 25 and 10 Starlights; incomplete
  boards never place (prizes: `shared/Rewards`). The podium shows during the cycle's results, then the cycle moves on.
- **Drops.** A participant who disconnects keeps their canvas, and any finish already
  validated. If they come back to the same cycle before the end, they carry on. The timer
  never stops. An award goes only to a finisher who is still connected.

### Blast Mining

Files: `minigames/blast_mining/` holds `Rules` (all tuning in `Rules.CONFIG`, the
schedule, scoring, ranking and wire format), `Round` (the authoritative round; `Server`
adapts the cycle's context to it), `Client` (clock sync, swing prediction and
reconciliation, audio), `Stage` (the screen), `Art` (the low-poly sprites, drawn as
cached paths) and `Assets` with `SceneAssets` (the art and audio, which ship with the
`blast_mining` scene's `cave-assets` entity).

- **Players.** Everyone in the cycle when it is announced mines, each with a stream
  numbered in that order. The list is frozen then, and later arrivals watch. Each
  client shows its own miner centred and larger, plus the next and previous connected
  miners in stream order at the sides, so neighbours don't swap as scores change.
  Avatars are the players' own outfit renders.
- **Round.** A 4 s intro (loading, the instruction, the item legend and a 3-2-1 count),
  then 60 s of play. The server draws every stream's schedule when play starts, from
  its own random numbers. It discloses each item to everyone only `LEAD` (0.35 s)
  before it starts falling. Clients animate falls from the server's spawn and strike
  times on a clock synced by pings.
- **Swings.** A client sends a swing intent with a sequence number and its estimate of
  the tap's server time. The server accepts that estimate only up to 150 ms in the past.
  It takes each sequence once, checks the phase and the 190 ms cooldown (410 ms while
  a bomb's 900 ms slowdown lasts), and hits at most one unhit item of the swinger's own
  stream within ±105 ms. Rock +1, gem +3, bomb −3 (never below zero). The client
  shatters its item at once and undoes that if the server's answer disagrees.
- **Results.** Points, then whoever reached their final score first, then player id.
  The top three get 50, 25 and 10 Starlights through the cycle. The results are sent once.
  A miner who drops keeps their stream, score and slowdown; if they come back to the
  same cycle, a snapshot restores everything without restarting.
- **Art and audio.** `assets/textures/blast_mining/cave.png` is the supplied cave.
  The work-song loop and effects in `assets/audio/blast_mining/` are original and
  synthesized by `tools/blast_mining_audio.py`; rerun it to regenerate them. Music
  plays on the app's music bus, effects on its effects bus, so the app's sound
  settings apply. Music pauses while the app is minimized and stops at the end. With
  the system's reduced-motion setting, shakes, bobbing, ripples and most particles are
  off.

`tests/blast_mining_test.luau` checks the schedule's gaps, falls and odds, bounded
disclosure, timing windows, duplicate sequences, both cooldowns and the bomb slowdown,
bounded claimed tap times, ignored forged messages, play-time limits, reconnection, and
idempotent ranked results.

### Shared mini-game pieces

- `widgets/GameUi.luau`: the theme tokens (translucent plum HUD, velvet results, lilac
  borders), the HUD panel, the pale instruction card, the large countdown and the
  results card (`wrap`, `row`, `medal`, `portrait`) and the podium built from them.
  Blast Mining, Lucky Shot, Star Pass and Pillow Fight use it.
- `client/ServerClock.luau`: the server clock on a client, synced by SYNC pings.
- `shared/Standings.luau`: the tie policy (points, then whoever reached their final
  score first, then player id) and the podium prizes (`shared/Rewards`).
- `widgets/AvatarImage.luau`: a player's full-body render or head portrait from their
  outfit, with a neutral fallback.

### Lucky Shot

Files: `minigames/lucky_shot/` holds `Rules` (versioned tuning in `Rules.CONFIG`, the
cloud field, scoring and wire format), `Round` (the authoritative round; `Server`
adapts the cycle's context to it), `Crowd` (where every competitor stands), `Client`,
`Stage`, `Art`, and `Assets` with `SceneAssets` (the meadow and audio, shipped by the
`lucky_shot` scene's `meadow-assets` entity).

- **Players.** Everyone in the cycle when it is announced competes. The roster is
  frozen then, and seats are numbered by player id and never change. Later arrivals
  watch the round and play the next mini-game.
- **Round.** A 10 s shared countdown (the cycle's intro) shows the instruction card
  and the +1/+2/−1 legend, then a large 3, 2, 1 for its last 3 s. Then 45 s of play.
  It starts automatically; there is no Start button.
- **Clouds.** One field shared by everyone, owned by the server. Four clouds at the
  start, then new ones at a pace and cap set once from the roster's size
  (`Rules.interval`, `Rules.cap`). Each is announced only 0.12 s before it shows, and
  lives 1.4 to 1.95 s, up to 0.4 s less by the end. Clouds stay in the cloud zone,
  clear of the HUD, the reload meter and the crowd.
- **Shots.** A tap on a cloud sends a shot intent with a sequence number and the tap's
  server time (taken only up to 150 ms back). The server refuses, at no cost, a shot
  at a cloud it never announced, outside play (including at or after the deadline) or
  inside the 850 ms reload. Any other shot takes the reload. Then the first claim the
  server orders takes the cloud, and later or late shots score nothing. White is +1,
  gold +2, storm −1 (scores may go below zero).
- **Feedback.** Only your own claims make a sound. Rivals' shots kick their slingshots
  and pop their clouds silently.
- **Crowd.** The whole roster stands in the meadow. You are large in front with a
  halo and marker; everyone else is in staggered rows by seat, smaller and higher
  toward the back. A mostly covered rear avatar is drawn a little see-through.
- **Results and drops.** Results use the shared podium and tie policy. Reconnecting
  restores your seat, score and reload.
- **Audio.** `tools/lucky_shot_audio.py` makes the original loop and effects.

`tests/lucky_shot_test.luau` checks the pace and cap, the cloud zone and lifetimes, crowd
layouts at 1/2/4/12/24/64 players, a two-player race for one cloud, the reload and
duplicates, storms below zero, made-up and stale clouds, the deadline and bounded tap
times, reconnection, and results sent once.

### Star Pass

Files: `minigames/star_pass/` holds `Rules` (versioned tuning, star supply, wave timing,
target choice, ranking, wire format), `Round` (the authoritative match; `Server` adapts
the cycle's context to it), `Crowd` (the survivors' formation), `Client`, `Stage`, and
`Assets` with `SceneAssets`. The approved garden and pixel star are in
`assets/textures/star_pass/`; the star is scaled to 160 px, and the originals are kept,
unshipped, in `art/star_pass/`. `tools/star_pass_audio.py` makes the tick and tock,
catch, pass, burst and a quiet loop.

- **Match.** Everyone in the cycle when it is announced competes, seated by account id;
  later arrivals watch. After the shared 10 s countdown, waves run until one player is
  left; there is no match clock (the cycle's timer shows the 300 s most it can take).
- **Waves.** Each wave gives `min(5, ceil(alive / 6), alive − 1)` stars to distinct
  survivors, chosen by a server shuffle. All of them burst at one `burstAt`:
  `max(6, 10.5 − 0.35 × wave) + random(0, 1.3)` seconds after the wave starts.
- **Bursts and recaps.** At the burst, every holder is out together. A 3.4 s recap
  ("Out this round", only that burst's players) runs to the next wave, which has fewer
  stars. After the final burst the recap runs once more, then the match ends
  (`context.finish`) and the cycle shows the podium.
- **Charge and pass.** A holder holds the button for 0.65 s, which the server checks
  from when it saw the hold begin. The holder then picks one of up to three players the
  server offers. The choices exclude other holders, and exclude the previous holder for
  1.2 s unless nobody else is free; slots stay put as eligibility changes. Every catch
  gets a new possession number, and every intent names it, so late or repeated intents
  never touch a later catch. The first valid pass in server order wins; the loser
  learns why and nothing else changes. A pass never moves the burst.
- **Field.** Survivors are stable nodes keyed by account id. They slide into a tighter
  formation after each burst (0.12 s delay, then 0.58 s); the eliminated fade up and
  are removed after 0.36 s. If you are out, the first survivor in seat order takes the
  foreground under their own name.
- **Ticking.** One shared tick tied to `burstAt`: every 0.8 / 0.52 / 0.32 / 0.17 s,
  louder while you hold a star, silent between waves.
- **Drops.** A competitor away for 20 s forfeits; their star is removed and the wave
  keeps its burst. Reconnecting before that keeps everything.
- **Results.** Survivor first, then later eliminations, then passes, then seat. 50,
  25 and 10 Starlights for the podium. If the 300 s safety timeout in its Games row
  is ever reached, survivors rank by passes, then seat.

`tests/star_pass_test.luau` checks star supply, wave length and tick pace, target choice
(returns, the two-player fallback, stable slots), waves at 2–40 players,
possession-scoped charging (early, cancelled, stale, wrong holder, duplicates), passing
(catch time, new possession, no carried charge, replays), a two-sender race for one
target, bursts and recaps, a match to one survivor with results sent once, ranking ties,
reconnects and forfeits, latecomers, and the crowd formation at 2–64 players.

`tests/head_to_head_test.luau` drives the round through a fake context: pool sizes for
3, 8 and 10 players, tap validation (preparation, duplicates, deadline), completion and
lock, ranking and ties, reconnection and latecomers.

### Pillow Fight

Files: `minigames/pillow_fight/` holds `Rules` (versioned tuning, grouping, the schedule,
the one-winner order, wire format), `Round` (the authoritative round, bots included;
`Server` adapts the cycle's context to it), `Client`, `Model`, `Stage` (arena, HUD,
controls), `Intro` (how-to examples and the group reveal), `Results`, `Pieces` (avatars,
the red !, the Throw and Dodge faces, shared by play and the examples), `Art` (the
pillow drawn from `art/pillow_fight/pillow.svg`, hearts, rings) and `Assets` with
`SceneAssets`. The bedroom backdrop and the three bot dolls are in
`assets/textures/pillow_fight/` (originals and notes in `art/pillow_fight/`).
`tools/pillow_fight_audio.py` ports the prototype's procedural audio: the music-box
lullaby, your throw's whoosh, the two-note warning ring, the hit thud and the dodge swish.

- **Schedule.** The cycle's 15 s announcement is the how-to card: three five-second
  examples ("Tap a rival to aim.", "Hold. Then release.", "Red ! means dodge."), with
  dots to review one. Then the 4 s group reveal (only with several rooms), 3, 2, 1, and
  60 s of play. With one room the round ends itself 4 s before the cycle's 67 s.
- **Rooms.** The roster freezes at the announcement. Up to 4 humans: one room of
  `max(3, H)`; more: `ceil(H / 4)` rooms of four, humans shuffled and dealt round-robin,
  then labelled bots ("Mallow · bot") fill the gaps. Every participant draws a unique
  tie-break ticket from one shuffle. Later arrivals watch room 1 and cannot act.
- **Combat.** Only Throw and Dodge. Throw: the server times the charge from when it saw
  it begin; under 0.18 s nothing is thrown, 0.9 s or more takes two hearts, past 3.5 s it
  is cancelled; 1 s cooldown, 1 s flight. Dodge: a 0.48 s window, 2.6 s cooldown. Three
  hearts; a hit stuns 0.3 s and drops a charge; a knockout respawns in 3 s with 1.2 s of
  protection. +1 per landed pillow, +3 per knockout. Impacts resolve in time order, so
  nobody is knocked out twice, and pillows landing at or after the end do nothing.
  Targets must be standing rivals in the sender's room, checked again on impact.
- **Screen.** Seats are fixed for the round: you in front, rivals at the back and sides.
  Aiming moves only the gold ring and chevron. A pillow within 0.42 s of you shows the
  red ! and lights Dodge; the warning ring plays once per pillow within 0.65 s, never for
  one your protection or dodge already covers, and never for other players.
- **Bots** run on the server through the same checks, with seeded randomness (tuning in
  `Rules.CONFIG.BOT`). They never receive Starlights.
- **Results.** Each room ranks by score, knockouts, hits, fewer knockouts suffered, then
  the draw ticket: one winner, unique places. Each room's top three, if humans still
  here, get 50, 25 and 10 Starlights (`shared/Rewards`, as in every mini-game). Your
  room shows first and in full; "Winners from other rooms" lists one winner per other
  room. A room whose humans all left, or a round the cycle ended early, is aborted and
  pays nobody.
- **Drops.** A human away 8 s forfeits: a bot takes their seat with the same hearts,
  cooldowns and draw ticket and a score of its own, and the results note who left.

`tests/pillow_fight_test.luau` checks grouping for every roster from 1 to 24 humans,
bot filling and draw tickets, the schedule, charge thresholds and cooldowns, damage,
stun, knockouts, respawn protection, dodge windows, room isolation and junk intents,
simultaneous impacts and the end cutoff, every tie-break level, results and rewards
(once, never to bots), reproducible bots, reconnects and forfeits, latecomers and
aborted rounds.

### Starcatchers

Files: `minigames/starcatchers/` holds `Rules` (versioned tuning, the star and satellite
streams, the net's physics and collisions, the lineup, wire format), `Round` (the
authoritative round; `Server` adapts the cycle's context to it), `Client`, `Stage`,
`Art` (stars, constellations, satellites, moon platforms, the hand net) and `Assets`
with `SceneAssets`. The galaxy backdrop is `assets/textures/starcatchers/galaxy.png`
(original and its art-direction notes in `art/starcatchers/`).
`tools/starcatchers_audio.py` renders the reference's celestial loop and the hook, bank
and satellite-hit sounds.

- **Your own stars.** Every participant has their own stream from the match seed and
  their seat, through an exact integer hash (server and client agree to the bit). Four
  stars a wave every 1.2 s (a low +1 star, a high +3 gold or +5 constellation, a middle
  and a mixed one), about 200 a round, 8 to 15 on screen; a satellite about every 4.5 s.
  Nobody shares or takes anyone's stars.
- **The net.** A press anywhere throws it (0.86 up, gravity 0.32); a release, the top
  of the throw or a catch brings it home (–1.65). One star per net, scored only when it
  gets home before the end: its value plus a streak bonus of `min(3, streak // 3)`. A
  satellite touching the net's actual position drops the catch, resets the streak and
  tangles the net for 1.2 s; banked points stay. A fresh press is needed for each throw.
- **Authority.** The server simulates every net in 40 ms substeps and judges each throw
  and release. Your client predicts your own net and replaces the prediction with each
  server update; points, streaks and effects come only from the server.
- **Lineup.** One shuffled, wrapping lineup per round: your two neighbours stand at the
  edges and up to six more (offsets ±2, ±3, ±4) small, faint and blurred in the
  distance. Each net update goes only to its owner and the players who show it.
- **Results.** The whole match ranks by the shared tie policy; the top three take 50, 30
  and 15 Starlights if they brought home at least one star.

`tests/starcatchers_test.luau` checks the hash, star density and wave composition,
satellite timing, the throw, top and return times, one carried star and banking, the
streak bonus, satellite hits and the tangle, independent streams, the lineup and
distant players, the update format, intent validation and visibility, results and
payouts, reconnects and latecomers.

### Adding a mini-game

1. Create its scene (**Hierarchy → scene dropdown → New scene…**) named after its id,
   with a `player-spawn` entity, a camera and a floor. Either bake a navmesh for it or
   add a `walk-area` entity with the `gameplay/WalkArea` script (see below).
2. Copy a folder under `assets/scripts/minigames/` to `minigames/<id>/` and write
   its rules and HUD.
3. Add a row for it to `shared/Games.luau` (its place in that list is its place in
   the cycle), and a line each to `server/Games.luau` and `client/Games.luau`.

`tests/net_test.luau` checks that every listed mini-game is played and that its scene
is named after its id.

## Walking

Avatars use Sky Lounge's movement: the owner walks immediately with
`@moonbase/prediction`, and the server accepts a report only if it is on the floor and
within a speed budget (`server/Arena.luau`). The floor is the scene's baked navmesh
when it has one. These scenes do not have one yet; until they do, each one's
`walk-area` entity (`gameplay/WalkArea`, a width and depth) marks a walkable rectangle,
which `shared/Floor.luau` gives both sides. Numbered `walk-block-1`, `walk-block-2`, …
entities (`gameplay/WalkBlock`) keep avatars out of smaller rectangles on it: the
lobby uses them for its furniture. Anything else on the rectangle can be walked
through. To use a real navmesh, open the scene and use **Bake navmesh**; it is then
used instead. `tests/floor_test.luau` checks the rectangle and its blocks.

## Files

- `assets/scripts/Root.luau`: the client root. It wires the controllers, the HUD and
  the lobby's tap targets (the arcade, the leaderboard and the shop stall).
- `assets/scripts/client/`: `Multiplayer` (the replicated world and every avatar in it),
  `Place` (which place you are in, the cycle's round, your Starlights, the leaderboard,
  moves between places, and routing to the current mini-game's client module),
  `Appearance`, `Roster` and the lobby chat's `Chat` (with `Emojis`, `Roles`,
  `AvatarImages` and its English `ChatText`), and the shop's `Shop` and `Looks`.
- `assets/scripts/widgets/`: `Hud` (with `Leaderboard`, `WallLabels` over the lobby's
  buttons, and the shared `Style`), `WalkControls`, and the lobby chat: `LobbyChat`
  (which shows it only in the lobby), `ChatBar`, `ChatFeed`, `ChatLine`, `ChatRules`,
  `MessageMenu`, `PlayerLabels`, the emoji widgets and their `ChatStyle`, all from
  Sky Lounge, and the shop's `ShopPanel` and `Cosmetics`.
- `assets/scripts/gameplay/`: movement, the follow camera and `WalkArea`, ported from
  Sky Lounge.
- `assets/scripts/server/`: `Root`, `Lobby`, `Chat` (the lobby's chat), `Cycle`, `Arena` (the scene and avatars;
  it swaps scenes between mini-games on one replication stream), `People` (who is here
  and how they look), `Starlights`, `Accounts` (shop accounts and purchases), `Travel` (finding, starting and moving between
  places) and the mini-game registry `Games`.
- `assets/scripts/shared/`: `Net` (the wire protocol and its validators), `Games` (the
  mini-game list), `Shop` (the shop's catalogue and rules), `Rewards`, `Floor` and `EmojiCodes`.
- `assets/prefabs/Avatar.prefab`: every player's avatar, with its movement settings and
  its `aura` (the shop's avatar glow).

Project settings and Save are in the **Moonbase** menu. **Hosting** links a
PHP-managed experience when you are ready to upload, preview or publish; it is
not needed for local Play.

## VS Code

Open this project folder and install the recommended **Luau Language Server**
extension. `.luaurc` provides strict typing and the same module aliases as the
runtime. `.vscode/settings.json` loads the Moonbase, Flutter and script globals.
No application-repository checkout or Roblox tools are needed.

Moonbase maintains the bundled type support in `.moonbase/sdk/`. Reopening the
project restores missing configuration files and updates the generated SDK while
preserving your existing VS Code settings and `.luaurc`. Commit `project.json`,
scenes, scripts and asset `.meta` files; `.moonbase/` and `build/` are generated.
