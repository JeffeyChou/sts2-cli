# sts2-cli, RL fork

This is a fork of [wuhao21/sts2-cli](https://github.com/wuhao21/sts2-cli) (MIT, © Hao Wu), the headless Slay the
Spire 2 engine. It adds what a reinforcement-learning agent needed: a pinned game build, fidelity fixes, speed, and
a few protocol commands for search. All upstream history is kept; the fork's changes are the commits after
`084d1aa` on the `main` branch.

It was used to train and evaluate a self-taught Ironclad agent (no LLM in its decisions) that matches human
completed-run win rates on Ascension 0-5.

## Game build

The fork builds against **Slay the Spire 2 v0.107.1** (Steam stable), the build Epoch AI's SpireClimb benchmark also
froze on. Upstream moved on to v0.111; the first commit reverts the v0.111-only APIs. Game files are never part of
this repository: `./setup.sh` copies the DLLs from your own Steam install, as upstream does.

## What the fork changes

**Fidelity** (the headless engine diverged from the real game in these places)
- Events: wait for the event's `Chosen()` task after card / bundle selections and event card rewards; neutralize
  UI-node calls in event models (The Trial and others aborted on a null UI); IL-patch headless-null UI calls (debug
  audio, screen shake) that silently broke events.
- Bosses: Kaiser Crab background no-op (its moves were aborted); player choices requested during the enemy turn
  (Knowledge Demon) are surfaced instead of cancel / retry / forced game over.
- **A10 Double Boss**: after the final act's first boss, the engine goes to the map's second boss point instead of
  reporting victory (the game's `StandardActMap.SecondBossMapPoint`).
- Shops: card removal once per visit and removal bans honoured; relic purchases no longer return an error after
  succeeding; pickup-selection relics wait for their purchase task.
- Crystal Sphere auto-play, missing Godot stub members, stale prompts dropped on reset.

**Throughput**
- Many runs per process (clean-up between runs) and repeated save / load in one process (for search replays).
- Rest-site and shop tasks are awaited instead of fixed 200 ms sleeps (identical outcomes, ~1.5x throughput).
- Memory leak across runs fixed (combat card-pile subscriptions, net services, the mock file-IO call log).

**Protocol additions for RL and search**
- `perturb_rng {salt}`: advance every run / player RNG stream by a salt-dependent number of draws and shuffle the
  not-yet-visited encounter / event queues. A search can sample plausible futures without seeing the real one
  ("honest" lookahead).
- `set_player {hp, max_hp, deck, relics, potions}`: edit the player in place (deck ids ending in `+` are added
  upgraded), for controlled experiments such as deck transplants.
- `write_continue_save {path}` / `load_save`: save anywhere and reload repeatedly.
- Richer state: draw (sorted) / discard / exhaust piles, card rarity, power / relic / potion ids, shop card ids,
  `potion_slots`, Kaiser Crab facing (side / behind).

## Using it

Setup and the JSON protocol are as in the upstream README below. The agent that uses this engine lives in a separate
repository (`sts2-agent`).
