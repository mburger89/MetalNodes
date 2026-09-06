# MetalNodes

A node-based Metal shader editor for macOS, in the spirit of Blender's shader editor and Houdini's network view. Wire nodes together on a canvas, watch the shader render live, and export it as a SwiftUI `[[stitchable]]` effect.

Swift 6 · SwiftUI · Metal · macOS 26 (iPadOS 27 planned)

> Screenshot placeholder — `docs/screenshot.png`

## Features

- **Live preview.** Parameters live in a uniform buffer, so scrubbing a value never recompiles. Only topology changes go through the Metal compiler, off the main actor, with a pipeline cache.
- **40 builtin nodes in 8 categories** — input, math, vector, SDF, noise, color, utility, output — covering every socket type (`float`…`float4`, `color`, `int`, `bool`) with implicit conversions and generic nodes.
- **Node groups.** Group a selection (⌘G), dive in, edit the definition and every instance updates. Expose sockets by wiring into `+`, rename or remove them from the inspector, make an instance unique, ungroup. Each definition compiles to one real MSL function called once per instance. Nesting is allowed; recursion is refused.
- **Viewer flag.** Preview any socket, including one inside a group definition, without rewiring the output.
- **Two output targets.** A fullscreen fragment shader (uv, time, resolution, mouse → color) and SwiftUI `colorEffect` / `distortionEffect` / `layerEffect` stitchable functions, with a `.metal` + Swift snippet export.
- **Editor essentials.** Palette with search and drag-in, ⇧A search popover, marquee and modifier selection, re-drag wiring, copy/paste that carries group definitions, snapshot undo with named steps, inspector, breadcrumb navigation, error outlines mapped from compiler diagnostics.
- **Dracula theme** throughout, via tokens.

## Requirements

- macOS 26, Xcode 27 (Swift 6.4, strict concurrency)
- A Metal-capable GPU for the preview and the render tests
- Optional: the Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`) to compile exported `.metal` files outside the app

## Build and run

```bash
git clone git@github.com:mburger89/MetalNodes.git
cd MetalNodes
open MetalNodes.xcodeproj        # scheme "MetalNodes", destination My Mac
```

Or from the command line:

```bash
xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build
```

## Tests

The package tests cover the document model, type system, codegen goldens, group operations, clipboard merge, the editor model, and GPU compilation of every generated program shape.

```bash
swift test --package-path MetalNodesKit
```

## Project layout

```
MetalNodes/               App target (macOS)
MetalNodesKit/            SwiftPM package
  Sources/MetalNodesCore/   Document model, type system, node registry, codegen — no AppKit/UIKit
  Sources/MetalNodesRender/ Compile actor, pipeline cache, uniform image, renderer
  Sources/MetalNodesUI/     Canvas, palette, inspector, editor model, theme
  Tests/                    Swift Testing suites per target
docs/superpowers/specs/   Design spec (the binding document) and the handoff record
docs/superpowers/plans/   One implementation plan per milestone
```

`MetalNodesCore` is pure value types, which is what makes the codegen and the group algebra testable without a GPU or a window.

## Keyboard reference

| Action | Keys |
|---|---|
| Add node | ⇧A (search popover) or drag from the palette |
| Group / Ungroup | ⌘G / ⌘⇧G |
| Edit group / Exit group | ⌘↓ or double-click the header / ⌘↑ |
| Duplicate | ⌘D |
| Frame all / selection | Home / F |
| Paste at cursor | ⌘⇧V |
| Export | ⌘E |
| View a socket | click the ◉ badge |

## Roadmap

| Milestone | Status |
|---|---|
| M0–M1 Foundation, codegen, first pixels | done |
| M2 Canvas interaction, undo, clipboard, inspector | done |
| M3 Full node library, viewer, stitchable target, export | done |
| M4 Node groups | done |
| M5 Package persistence with textures, comment frames and stickies, generated-code panel, minimap, `.metal` export, cross-document paste | next |
| M6 iPadOS UI layer | planned |

## Development notes

The design lives in `docs/superpowers/specs/2026-09-04-metalnodes-design.md`; each milestone has a plan under `docs/superpowers/plans/` and an execution record (rulings, deferred items) in the handoff document. Work happens on feature branches, one PR per milestone.
