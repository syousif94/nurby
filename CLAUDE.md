# Nurby — agent notes

Nurby is an iPad/iPhone parametric CAD app: an agentic chat interface plus touch sketching,
on top of the open-source SolidCraft Rust kernel (github.com/tangency-labs/solidcraft,
MIT OR Apache-2.0).

- Design spec: https://claude.ai/artifact/MUyGvmUUCU3p2DkCwX2KCW
- Mockups (Day + Nord): https://claude.ai/artifact/8jN5mDzxMKrgy5T3rjwmUR

## Architecture (keep to this)
- `vendor/solidcraft` — SolidCraft, vendored whole as a git submodule (github.com/tangency-labs/solidcraft).
  It is the kernel, the engine (`Session::execute`, dotted command ids) and the MCP tool layer.
- `crates/nurby-core` — Rust, exported to Swift with UniFFI. `Studio` = one open design: a headless
  SolidCraft session behind SolidCraft's own in-process MCP `Server` (tools, instructions, argument
  checks, path scope = the app's Documents folder). All calls run on one worker thread (SolidCraft's
  session is single-threaded). Exposes `tools_json`, `call_tool`, `execute`, `inspect_json`, `meshes`.
  Swift never holds kernel pointers.
- `crates/uniffi-bindgen` — generates the Swift bindings (UniFFI 0.32, proc-macro style).
- `ios/` — SwiftUI app (XcodeGen spec in `ios/project.yml`, iOS 26, Liquid Glass):
  SceneKit viewport (`ViewportView`, full-bleed but extended past the left screen edge by the sidebar's width so its centre is the middle of the open area), the operations bar
  (or sketch bar) at the bottom left, and one right sidebar (`StudioView.sidebar`): the editor (drawer
  with features / parameters, undo, export; or a `FeaturePanel` with a back button, both inside one glass
  panel so only the content slides) above the agent
  panel with its composer (`AgentComposer`) built in. The gap between them drags to share the height
  (`sidebarSplit` in AppStorage); dragging it or the sidebar's left edge sideways slides the sidebar
  off, and it is pulled back from the right screen edge. There is no sheet: an upright iPhone uses the bottom dock (below), and when its panels don't fit across they page sideways (`dockPaged`: a Selected card, the editor (centred, the default page) and the agent, each up to `dockPanelMax` wide and centred with its neighbours peeking; the floating selection hides while that dock shows); on narrow screens the show-sidebar button sits above the tools. Hidden panels slide past the safe area. Composer: model menu (recent/suggested, "All models…" = Settings), image "+"
  (pen markup, snapshot of view, photos, files). Pen markup (`MarkupView`, PencilKit) freezes a
  `ViewportHandle` snapshot, draws over it, and attaches the cropped composite. Manual modelling (`SketchEditor.swift`, `FeaturePanel.swift`,
  `OperationsBar.swift`) calls the same SolidCraft engine commands (`sketch.*`, `solid.*`) through
  `DesignModel`; while a sketch is open the viewport camera goes orthographic onto its plane and a
  SwiftUI Canvas + UIKit gesture layer draw on top, in sketch mm.
- The agent (`AgentSession`) is Claude through the Claude API (`Anthropic.swift`, raw HTTP Messages API,
  Anthropic API key) or any tool-calling OpenRouter model (`OpenRouter.swift`), chosen per `Provider`
  in Settings or the composer's model menu; each provider has its own Keychain key, model and recents.
  History is kept in OpenAI chat format; `Anthropic` converts it per request and keeps Claude's raw
  content blocks (thinking included) on the assistant message as `_anthropic` to send back unchanged
  (`_`-prefixed keys are stripped for OpenRouter). The agent calls exactly SolidCraft's MCP tools. No private agent API: the UI runs the same engine commands.

## Build
- Toolchain: `rust-toolchain.toml` (Rust 1.99.1, as SolidCraft pins), iOS targets included.
- Rust tests: `cargo test -p nurby-core` (first build compiles all of SolidCraft: ~10 min, several GB).
- iOS framework + bindings: `scripts/build-xcframework.sh`
- Xcode project: `cd ios && xcodegen && open Nurby.xcodeproj`

## Conventions
- No unsaved state: every transaction is persisted as it happens; versions are named checkpoints.
- Parameters are SolidCraft's (unit-aware expressions); names are snake_case.
- Colors: system blue for actions and the agent, cyan for free geometry, green for selected faces,
  orange for selected edges, red for conflicts; selected list rows are a ~6% neutral tint. Squircle corners (`.continuous`).
- Layers rows are single-line (34 pt iPad / 40 pt iPhone) with an eye toggle, never checkboxes.

## Status
Done: SolidCraft builds for iOS and runs in-process; the agent models through its MCP tools; the
viewport shows display meshes (SceneKit); features, parameters, undo/redo and STEP/STL/3MF export work.
Designs autosave after every change to Documents/Designs/*.sc (visible in the Files app) and the last
one is offered on the start page (recent designs with thumbnails, new, import, start-with-a-prompt).
Tapping a face or edge selects it (SolidCraft `select.set`, green highlight, chip in the composer) and
the agent gets the selection with the next message.
Manual modelling: new sketch on XY/XZ/YZ or a picked face, line/rectangle/circle tools with snapping,
select, dimension (value, expression or `name = value`), delete; extrude/revolve/fillet/chamfer/shell
panels; edit/rename/delete features and add/delete parameters from the drawer. Designs can be renamed
from the start page. A parametric "Demo plate" is seeded once on first launch (an ordinary design).
The agent accepts pictures (OpenAI multipart content, JPEG ≤1568 px): pen markup of the view, view
snapshots, photos and image files, shown as thumbnails in the composer and the transcript.
Tapping a feature row opens its panel in the sidebar; while editing, the faces the feature made are
tinted blue (`DesignModel.focus` → `affected`, from topology names).
Agent chats are saved to Application Support/Chats/*.json after each turn (pictures dropped); an empty
chat lists recent chats above the input, the header has history / new chat / settings.
The last design is remembered by file name (the app container path changes on reinstall/update).
Feature editing: double-tap or "Edit…" on an extrude/revolve/fillet/chamfer/shell row loads
`timeline.inspect` (inputs `dN` → `parameters.change`; operation/direction/edges → `timeline.edit`).
Feature panels preview live: `DesignModel.beginPreview` takes an `edit.checkpoint`, each change (350 ms
debounce) rewinds to it and re-runs the edit (`preview`), and `endPreview(commit:)` rewinds and applies once
(one undo step) or just rewinds on Cancel. Fillets/chamfers (new and edited) preview too: the panel holds their
edges as points (`edgePoints`, sent as `solid.fillet/chamfer {edges}`), since each rebuild clears the selection.
Values that don't build turn the field red (`FeaturePanel.invalid`) instead of showing the kernel's error.
Rollback bar: a gripper row in the feature list at the timeline marker (`timeline.roll_to`); dragging it
previews live, rows past it dim, release commits one undoable step; "Roll back to here" in the row menu.
Versions (`Versions.swift`, `VersionsView.swift`): the design file is always the current branch's
workspace; `Designs/.<name>.versions/` holds `index.json`, version files and parked branch workspaces.
Save version, view (read-only, autosave off) / restore (saves "Before restoring" first), branch from now
or a version, switch, compare (features + parameters by expression), merge into main (main takes the
branch's design; SolidCraft can't combine timelines). The agent saves a version after each turn that
changed the design (author "Agent"). Tapping a face/edge highlights the features that made it
(parsed from `model.faces`/`model.edges` topology names, `F<id>` = timeline feature id).
The sketcher shows dimensions from `sketch.inspect` constraints (lengths, ⌀/R, distances and angles
between two items; tap to change the parameter). Select picks points (ends, centres, origin) before
curves; any two picked items get a dimension (`sketch.dimension {entities}`, SolidCraft picks the kind), H/V glyphs, and read-only grey placement labels for `fixed_by` points. The viewport
reports its real size through `SizedSCNView.onResize` so the sketch canvas and camera line up.
When the window is taller than wide (iPad / Duo upright) the editor and agent sit side by side along
the bottom under the tools (`StudioView.dock`; top edge or the tools above it drag up/down to resize (a drag that starts on a tool doesn't run it; the tools hide while the keyboard is up), `dockSplit` in AppStorage, or
down to hide); the viewport then extends past the top edge so its centre is the open area's middle.
The studio hides the status bar (iPhone Duo puts it down the side in landscape) so the sidebar runs
to the screen edge. A floating `SelectionPanel` (top left) lists what is selected with ✕ / Clear (on narrow docked screens it starts folded to a summary pill). Feature panels list the selection themselves and select what the feature applies to: a fillet/chamfer lists its edges as `StoredEdgeRow`s with ✕ (seeded from the selection or the stored edges; tapping an edge in the view adds or removes it) and tints the faces it makes; an extrude keeps its to/from faces selected (`DesignModel.selectFaces(at:)`, re-run after each preview rebuild) and lists other picks under "Selected".
The extrude panel exposes SolidCraft's extent: operation (add/cut/intersect/new), one side / flipped /
symmetric / two sides, end at distance / through all / to face (+ offset), start at sketch / offset /
from face, taper, thin wall; faces go into slots via "Pick". The shell panel lists its faces (`PickList`) with ✕. Extrude edits map extent fields to their `dN` inputs
(`parameters.change`) and set the rest via `timeline.edit` (null clears).
While a sketch or feature panel is open the agent shrinks to its composer (`AgentPanel.collapsed`; only in the stacked side sidebar, never in the bottom dock, `agentCollapsed`); feature-panel choices (operation, direction, end, start, wall side) are pop-up menu rows (`FeaturePanel.menu`); feature
panels pin Back / ✕ / ✓ in a header (`safeAreaBar` + hard scroll edge effect, so the form blurs under it) and the step's name is a field in the title (renamed with `timeline.rename` on ✓, after the change); the sketch bar has ✕ (cancel) and ✓ (finish) at opposite ends. Tapping the sidebar during a sketch asks to save or discard it.
The viewport drives its own camera (`ViewportView.Coordinator`: turntable orbit with inertia, two-finger pan, pinch zoom); `NavigationGizmo` (top right, Blender-style axes) taps to axis views, drags to orbit, holds to look square onto the selected face (or the face mid-view). In a sketch, a second finger cancels the stroke and pans.
Sketcher constraints: Select also picks line midpoints (diamonds) and the sketch's X/Y axes; the link menu offers
the constraints that fit the picks (coincident, on line / at middle, on circle / at centre, H/V, level, parallel,
perpendicular, collinear, equal, tangent, concentric, symmetric, fix) as `sketch.constraint.*`, drawn as small glyphs
(∥ ⊥ = T M ◎ ⇋). A midpoint operand is `{"midpoint": lineId}` (`"mid:lN"` for `sketch.dimension`). The dashed-square
toggle draws construction geometry (`construction:true`; circles via `sketch.construction` afterwards) and
"Make construction" flips picks. The Project tool (cube) taps a model edge/face into the sketch as construction
(`sketch.project`, purple); a 4-line face also gets a construction diagonal whose middle is the face centre.
Extrude regions: the extrude panel lists the sketch's regions (`Studio::sketch_regions` in nurby-core samples
SolidCraft's exact `Region2` boundaries; overlaps split into separate regions) and draws them on the sketch plane
in the view (`ViewportView.regionsNode`); tapping in the view or the list picks them (blue) and sends
`profiles:[i], exact_regions:true` (edits: `timeline.edit profiles {type:"indices"}`); none picked = whole sketch.
Thin walls ignore regions. Steps reorder by long-press-dragging a row onto another (`timeline.reorder`) or
Move up/down in the row menu; SolidCraft refuses moves that would break a step and the drawer shows why.
Not yet: arcs in the touch sketcher, sketch curves shown in 3D (outside the extrude panel),
voice input, a Metal/wgpu viewport, the 60 fps / 50-feature gate on an iPad.
