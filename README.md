# New Football Star

Roblox football career game. The place's scripts live in `src/` (paths mirror the Explorer:
`ServerScriptService`, `ReplicatedStorage`, `StarterPlayer`); the rest of the place (stadium,
lighting, settings) comes from `place/NewFootballStar.base.rbxlx`.

## Build the place

```
python3 tools/place/build.py            # -> build/NewFootballStar.rbxlx
```

Open `build/NewFootballStar.rbxlx` in Roblox Studio. New `.lua` files under `src/` become new
ModuleScripts under their parent instance. `tools/place/extract.py <place.rbxlx> src` goes the other
way (after editing scripts in Studio).

Player textures: `tools/assets/build_players.py` cuts the sheets in `tools/assets/source/` into the
packed image modules in `src/ReplicatedStorage/Shared/Images/` (needs pillow, numpy, opencv).
Published games need **Game Settings → Security → Allow Mesh / Image APIs** for them to show.

## Match flow

- Between your moments the screen is the commentator's studio (`MatchHud`): live commentary,
  timeline, your stamina, effort (1–3 hearts) and focus (attack / defense).
- Stamina drains every match minute in proportion to the effort. More effort: more moments and
  more time in them; attack focus: more moments but more chances against.
- Moments (`MomentPhysics`, `MomentVisuals`) start outside the box: a teammate passes to you or you
  already have the ball. Defenders close in in slow motion; hold on the goal to shoot, drag to a
  teammate to pass, or switch on HIGH BALL to cross. The server decides everything (`MatchService`).
