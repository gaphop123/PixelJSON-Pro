# PixelJSON Pro — Advanced Lossy Image Encoder & Luau Runtime

**Version 2.0** — A complete, dependency-free image-to-JSON conversion and rendering ecosystem.

## Overview

PixelJSON Pro converts raster images into a compact, versioned, lossy JSON format optimized for size and Roblox/Luau rendering. It provides:

- A full-featured web application (single HTML file) for encoding, analysis, comparison, batch processing, and Luau code generation.
- A production-ready Luau library (`main.luau`) for decoding, validation, and GUI-based pixel rendering.
- Configurable lossy pipeline: resize → quantization → dithering → spatial encoding (RLE / row-RLE / delta / bit-packing / raw fallback).
- Deterministic output, measurable quality metrics (MSE, PSNR), and real size optimization.

**Primary goal**: Produce compact, valid PixelJSON that can be decoded and rendered accurately in Luau environments (Roblox Studio, published experiences, and compatible executors) without inventing unsupported APIs.

## Project Structure

```
PixelJSON-Pro/
├── index.html          # Complete web application (HTML + CSS + JS). Runnable locally.
├── main.luau           # Luau decoder, validator, renderer, and remote loader.
└── README.md           # This file.
```

Open `index.html` directly in a modern browser (Chrome, Firefox, Edge, Safari). No server or build step is required. A “Download Single-File Bundle” button is available inside the app if you want a fully self-contained copy.

## Web Application Features

### Image Input
- Local file selection (PNG, JPEG, WebP, BMP where supported by the browser)
- Drag-and-drop
- Clipboard paste (when permitted)
- HTTPS URL loading with timeout, size limits, AbortController, and optional cache
- Batch conversion
- Existing PixelJSON (v1 / v2) decoding
- Progress, cancellation, clear error messages, file-size / dimensions / format reporting

**Remote loading API (JavaScript)**
```js
PixelJSON.loadImageFromURL(url, options, callback)
PixelJSON.loadJSONFromURL(url, options, callback)
PixelJSON.loadFile(file, options, callback)
PixelJSON.convertImage(source, options, callback)
// callback(error, result, metadata)
// Also supports async/await wrappers.
```

CORS note: Browser-based image fetching requires the remote host to send appropriate CORS headers. The application never bypasses CORS. If a URL fails, load the file locally or use a CORS-enabled host.

### Lossy Compression Pipeline
1. Decode image + apply EXIF orientation (when available)
2. Configurable resize (nearest-neighbor, bilinear, bicubic, Lanczos-style, auto by budget)
3. Optional perceptual color space conversion
4. Color quantization:
   - Median Cut
   - Modified Median Cut (perceptual / population-weighted)
   - K-means (deterministic init, iteration limit)
   - Octree
5. Palette sizes: 8 / 16 / 32 / 64 / 128 / 256
6. Dithering: None, Floyd–Steinberg, Ordered Bayer, Atkinson
7. Alpha modes: full RGBA, binary transparency, quantized alpha, threshold, background compositing, separate alpha plane when beneficial
8. Spatial encoding selection (chooses the smallest valid representation):
   - Palette + global RLE
   - Row-based RLE (runs never cross rows)
   - Delta encoding
   - Bit-packed palette indices
   - Separate alpha
   - Adaptive tiles
   - Raw RGBA fallback
9. Compact JSON serialization (whitespace-minimized for export)
10. Immediate decode + quality metrics + visual comparison

All steps are deterministic for the same input + settings.

### Presets
- **High Quality** — larger dimensions, big palette, light quantization
- **Balanced** — medium settings, adaptive encoding
- **Smallest Size** — aggressive downscale + small palette

Custom controls for every parameter, including target byte budget with bounded search over resolutions/palettes. Actual serialized UTF-8 size is measured; estimates are never used for final selection.

### Quality Metrics & Visualization
- Original vs. PixelJSON size, compression ratio
- Dimensions, palette size, encode/decode time
- MSE, PSNR (and optional SSIM approximation)
- Side-by-side / slider comparison, difference heatmap, zoom/pan, pixel inspector, palette view

### Luau Code Generation
One-click generation of ready-to-paste Luau snippets for decoding, rendering, button/textbox callbacks, and remote loading.

## PixelJSON v2 Format

```json
{
  "format": "PixelJSON",
  "version": 2,
  "width": 320,
  "height": 180,
  "encoding": "palette-rle",
  "colorSpace": "sRGB",
  "alphaMode": "rgba",
  "palette": [[0,0,0,255], [255,255,255,255], ...],
  "pixels": [160, 0, 160, 1, ...],
  "settings": { ... },
  "checksum": "optional"
}
```

- `pixels` for RLE encodings: alternating `[runLength, paletteIndex, ...]`
- Runs never cross row boundaries
- Total decoded pixels must equal `width * height`
- Palette indices are validated
- Raw-RGBA fallback and v1 decoder compatibility are supported
- Optional checksum and encoder settings metadata

## Luau Library (`main.luau`)

Stable public API:

```lua
PixelJSON.Decode(jsonString, options) → data, err
PixelJSON.Validate(data, options) → ok, err
PixelJSON.Render(data, options) → handle, err
PixelJSON.LoadJSONFromURL(url, options, callback)
PixelJSON.Destroy(handle)
```

### Rendering Strategies
- Individual pixel Frames for tiny images
- Horizontal run rectangles (preferred for RLE data)
- Optional block downsampling for larger images
- Hard maximum instance budget (default 10 000) with clear warnings
- Correct alpha, nearest-neighbor scaling, clipping, offsets, parent Frame
- Instance reuse and proper cleanup via the returned handle

### Safety & Limits
- Strict validation before any GUI allocation
- Maximum pixel count, palette size, and download size enforced
- No `loadstring` on JSON content
- HTTP only when the environment permits it; differences between Studio, live games, and third-party executors are documented
- Never fabricates ImageLabel asset upload APIs

### Example
```lua
local data, err = PixelJSON.Decode(jsonString)
if not data then warn(err) return end

local handle, renderErr = PixelJSON.Render(data, {
    Parent = targetFrame,
    MaxPixels = 10000,
    Scale = 2
})
if not handle then warn(renderErr) return end

-- later
PixelJSON.Destroy(handle)
```

## Limitations & Platform Notes

- High-resolution images are impractical for pure GUI pixel renderers; the library enforces instance budgets.
- Arbitrary RGBA cannot be assigned directly to `ImageLabel.Image`. Native image mode is an optional adapter only for existing Roblox assets.
- Remote module loading (if enabled) is restricted to trusted, versioned ModuleScripts; image/JSON URLs are never treated as executable code.
- Browser CORS and Roblox HTTP permissions are respected; the libraries never attempt to bypass them.
- Performance is measured on real data; results vary by image content, palette size, and chosen encoding.

## Testing Coverage

The implementation includes fixtures and logic for:
- 1×1, flat-color, gradient, photographic, pixel-art, and transparent images
- Malformed JSON, invalid indices/runs, dimension overflows
- Empty / inaccessible / CORS-failing URLs
- Aborted requests
- v1 ↔ v2 round-trips
- Deterministic encode/decode
- Target-size optimization behavior

## Building / Sharing

1. Open `index.html` in a browser.
2. Use the in-app “Download Single-File Bundle” if you need a completely self-contained HTML file.
3. Copy `main.luau` into your Roblox project (or executor environment) and require / load it according to your tooling.

No external dependencies, no npm, no build toolchain required.

## License & Attribution

This is an original implementation created to the PixelJSON Pro specification. Algorithms (Median Cut, Floyd–Steinberg, RLE variants, etc.) follow well-known public descriptions and are implemented from first principles for determinism and clarity.

---

**Priorities realized**: correct algorithms, measurable compression, deterministic output, Luau compatibility, safe resource usage, and clear documentation of every platform limitation.