# Avatar Assets

Affective supports two avatar formats in a brain folder:

- A single static image: `avatar.png`, `avatar.jpg`, `portrait.png`, or `icon.png`.
- A layered avatar manifest: `avatar.json` plus the images referenced by the manifest.

When `avatar.json` is present, Affective renders it before falling back to a static image.

## Layered Manifest

`avatar.json` uses a canvas coordinate system. Each layer is sized with `width` and `height`, sorted by `z`, and positioned with `x` and `y`. New avatars saved from the editor use `anchor: "center"`, so `x` and `y` are the layer center. Legacy manifests without `anchor` are treated as top-left positioning.

Optional layer fields:

- `anchor`: `"center"` or `"topLeading"` (default when omitted).
- `color`: `#RRGGBB` or `#RRGGBBAA` hex fill for layers without `image` or `atlas` (for example a solid background).

The optional `clip` rectangle defines the final avatar frame inside that canvas; omit it to render the full canvas.

```json
{
  "canvas": {
    "width": 512,
    "height": 512
  },
  "clip": {
    "x": 0,
    "y": 64,
    "width": 512,
    "height": 384
  },
  "defaultExpression": "neutral",
  "layers": [
    {
      "id": "body",
      "image": "avatar/body.png",
      "x": 0,
      "y": 0,
      "width": 512,
      "height": 512,
      "z": 0
    },
    {
      "id": "eyes",
      "atlas": "avatar/eyes-blink.png",
      "x": 0,
      "y": 0,
      "width": 512,
      "height": 512,
      "frameX": 0,
      "frameY": 0,
      "frameWidth": 512,
      "frameHeight": 512,
      "frames": 4,
      "fps": 8,
      "z": 10
    }
  ],
  "expressions": [
    {
      "id": "neutral",
      "name": "Neutral",
      "layers": {
        "eyes": { "frame": 0 },
        "mouth": { "frame": 0 },
        "blink": { "frames": [0, 1, 2, 1], "fps": 12 }
      }
    }
  ]
}
```

## Clip Frame

Use `clip` when the final avatar should not use the full canvas or should have a non-square aspect ratio:

```json
{
  "clip": {
    "x": 120,
    "y": 40,
    "width": 720,
    "height": 960
  }
}
```

The clip frame is stored in canvas coordinates. Layers can extend outside the clip; Affective crops them at render time on macOS and iOS.

## Static Layers

Use `image` for a normal PNG or JPEG layer:

```json
{
  "id": "hat",
  "image": "avatar/hat.png",
  "anchor": "center",
  "x": 256,
  "y": 200,
  "width": 256,
  "height": 160,
  "z": 20
}
```

Use `color` instead of `image` for a solid background fill:

```json
{
  "id": "background",
  "anchor": "center",
  "x": 256,
  "y": 256,
  "width": 512,
  "height": 512,
  "color": "#1A1A2E",
  "z": 0
}
```

Omit `image` and `color` on the background layer to leave that region transparent.

## Atlas Animation

Use `atlas` for a horizontal or grid-based sprite sheet. Affective crops frames from left to right, then wraps to the next row.

Required atlas fields:

- `atlas`: relative path to the sprite sheet.
- `frameWidth`: width of one frame in pixels.
- `frameHeight`: height of one frame in pixels.
- `frames`: total number of frames to play.
- `fps`: playback speed.

Optional fields:

- `frameX`: horizontal offset where the first frame starts inside the sprite sheet.
- `frameY`: vertical offset where the first frame starts inside the sprite sheet.
- `opacity`: `0.0` to `1.0`.
- `name`: human-readable label.
- `id`: stable author-provided layer ID.
- `frame`: zero-based frame index for a static atlas sprite. Omit this when `fps` should animate through `frames`.

## Expression Mapping

Expressions map semantic avatar states to atlas frames. They are optional and backward-compatible: when no expression is active, Affective uses the layer's own `frame` or `fps` animation metadata.

```json
{
  "defaultExpression": "happy",
  "expressions": [
    {
      "id": "happy",
      "name": "Happy",
      "layers": {
        "eyes": { "frame": 1 },
        "mouth": { "frame": 3 },
        "blink": { "frames": [0, 1, 2, 1], "fps": 12 }
      }
    }
  ]
}
```

Expression layer overrides use layer IDs such as `eyes`, `mouth`, and `blink`. A static override uses `frame`; an animated override uses `frames` plus `fps`. Atlas frame order is always left-to-right, then top-to-bottom.
