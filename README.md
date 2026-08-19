# Importality

[![en](https://img.shields.io/badge/lang-en-red.svg)](README.md)
[![ru](https://img.shields.io/badge/lang-ru-green.svg)](README.ru.md)

**Importality is a Godot add-on for turning layered graphics authored in external tools into reusable Godot resources.**

This repository is a maintained fork of [nklbdev/godot-4-importality](https://github.com/nklbdev/godot-4-importality). The fork keeps the upstream architecture and importers while adding a first-class **Krita Layers** intermediate format for projects that need semantic layered artwork rather than a single flattened image.

## Goals

The fork is intended to keep the boundary between **authoring**, **import**, and **runtime consumers** clean:

```text
Krita / another authoring tool
        |
        |  export
        v
  .kritalayers
        |
        |  Importality
        v
  Godot resource
        |
        +--> B42
        +--> Dialogic 2
        +--> another game/project
        +--> custom runtime code
```

Importality does not depend on B42, Dialogic, or any particular game architecture. B42 is one consumer of the imported data, not part of the importer.

The long-term design is intentionally flexible: an artwork source may contain one asset or many, and the export definition is intended to describe how the source maps to logical slots and variants without forcing every project into the same character/portrait layout. The current v2 authoring path uses the explicit `@export` convention described below.

## Krita Layers v2

The new `importality.krita.layers/v2` bundle is a ZIP-based intermediate format containing:

- `manifest.json` describing the canvas, slots, variants, playback and integrity metadata;
- full-canvas PNG frames;
- optional source metadata, including Visibility Rules imported from the Krita Sprite Visibility Rules plugin.

Each exported slot is a direct child of a top-level `@export` group. The current convention is intentionally small:

```text
@export
├── BODY
│   └── *base
├── FACE
│   ├── *neutral
│   ├── smile
│   └── tired
├── HAIR
│   ├── *normal
│   └── disheveled
└── +DETAILS
    ├── *none
    └── cut_face
```

`*` marks a default variant. `+` marks an additive slot. Names are semantic identifiers; the importer preserves the authored names in the generated `SpriteFrames` animations.

Every frame is protected by SHA-256 metadata and the importer validates archive paths, canvas dimensions, logical-name collisions, playback data and frame hashes before creating the Godot resource.

### Visibility Rules

When the source `.kra` contains the public annotation used by [Krita Sprite Visibility Rules](https://github.com/EvelynLimaB/krita-sprite-visibility-rules), the Krita exporter carries the rules into the `.kritalayers` manifest.

Importality treats them as **generic source metadata**. The imported resource stores the data under:

```text
importality.krita.layers.visibility_rules
```

A runtime consumer can choose to interpret that metadata. This keeps the Importality core independent from the rule engine and avoids coupling the extension to B42.

The integration preserves the rule schema and source node identifiers rather than copying the Krita plugin's implementation.

## Installation

### Godot

Install the add-on from this repository by copying the contents of `addons/` into your Godot project's `addons/` directory, or install the published upstream Importality and use this fork when you need the Krita Layers extension.

Enable **Importality** in `Project > Project Settings > Plugins`.

### Krita

Install the contents of:

```text
 tools/krita_plugin/
```

as a Krita Python plugin, then restart Krita.

The plugin adds:

```text
Tools
→ Scripts
→ Importality: Export .kritalayers
```

Save the `.kra` before exporting. When the source document is inside a Godot project, the default destination is:

```text
assets/importality/<source-name>.kritalayers
```

The export is written atomically so a failed export does not replace a previously valid bundle.

## Godot usage

Once a `.kritalayers` file is inside the project, Importality exposes it through its normal importer pipeline. For the `SpriteFrames` target, the resulting resource can be loaded normally:

```gdscript
var frames: SpriteFrames = load("res://assets/importality/belle.kritalayers")
```

The same imported resource can be consumed by a custom layered-asset controller, a visual-novel portrait, an `AnimatedSprite2D`, or another system. Importality itself does not decide what the slots mean at runtime.

## B42 and Dialogic 2

B42's `B42LayeredPortrait` is one consumer of this extension. It resolves B42-specific semantic states and slot behavior on top of the generic `SpriteFrames` resource.

Dialogic 2 can continue to use a custom portrait scene and pass state/extra data to B42. Dialogic is therefore an optional integration layer, not an Importality dependency.

This separation makes the same `.kritalayers` asset reusable in other Godot projects that do not use B42 or Dialogic.

## CI and validation

The B42 development branch established the original real pipeline:

```text
Krita 5.x
  -> real .kra
  -> real .kritalayers v2
  -> Godot Importality importer
  -> SpriteFrames
  -> B42 semantic resolution
```

The generic portion now lives in this Importality fork as a regression suite. It deliberately stops at the generic resource boundary; B42 remains responsible for consumer-specific behavior.

The fork's CI is split into three layers:

```text
1. Contract tests
   synthetic bundles
   schema / path / SHA-256 / naming / metadata checks

2. Real Krita exporter
   Windows self-hosted
   real Krita
   real Importality Krita plugin
   real .kra -> .kritalayers artifact

3. Real Godot importer
   Linux self-hosted
   real .kritalayers artifact
   real Importality importer
   SpriteFrames assertions
   Visibility Rules metadata
   persistence / reload
```

The B42 project keeps the downstream checks instead:

```text
Importality asset
  -> B42LayeredPortrait
  -> semantic state resolution
  -> Dialogic integration
```

The real Windows and Linux jobs intentionally use self-hosted runners because Krita is a desktop application and the exporter test needs an interactive Krita session. The disposable Linux project copies the add-on into a tiny Godot project so the test exercises the actual Importality plugin rather than a mocked importer.

## Current scope and next evolution

The v2 exporter currently uses the explicit `@export` convention and exports one logical asset bundle per source document. The format and importer are deliberately structured so a future export-definition layer can support arbitrary source organization and multiple logical assets from a single `.kra` without changing the Godot-side resource contract.

That future definition layer is where projects can choose between:

- one source file per asset;
- many assets in one source file;
- characters, creatures, items, backgrounds, UI and other layered graphics in the same project.

The importer is not intended to force a portrait-specific hierarchy.

## Upstream

This fork follows the upstream Importality project:

```text
upstream: https://github.com/nklbdev/godot-4-importality
fork:     https://github.com/eveorgr/godot-4-importality
```

Changes that are generally useful to Importality can be proposed upstream; B42-specific behavior should remain in the B42 consumer.

## License

Importality remains distributed under the upstream project's license. This fork adds the Krita Layers extension and its supporting tooling while keeping the upstream attribution.
