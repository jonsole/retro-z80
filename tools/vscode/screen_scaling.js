// How big the Show Screen tab draws the board's picture, and through which
// filter: the zx emulator's screen_scaling.js (PROVENANCE.md), for a picture
// whose size comes from the capture device (720x576 from the KS2) instead of
// the Spectrum's 352x312, with no border crop or scanlines. No vscode import,
// so it tests in plain Node, and layoutFor and prescaleFactor stand alone,
// because the webview gets them as source text.
//
// Sizes are worked out in DEVICE pixels first and only then turned back into
// CSS pixels: on a 150% display a "2x" picture is three device pixels a
// captured pixel, and nearest neighbour is only crisp when that is whole.

'use strict';

const FILTERS = [
  { id: 'nearest', label: 'Nearest neighbour', detail: 'Hard-edged pixels. Uneven at in-between sizes.' },
  { id: 'sharp-bilinear', label: 'Sharp bilinear',
    detail: 'Hard-edged pixels, evenly sized at any size: only their edges are blended.' },
  { id: 'bilinear', label: 'Bilinear', detail: 'Smoothed, as a television would soften it.' }
];

const SCALES = [
  { id: 'fit', label: 'Fit', detail: 'Fill the tab, keeping the shape.' },
  { id: 'fit-integer', label: 'Fit, whole multiples',
    detail: 'As large as the tab allows in whole steps: every pixel the same size.' },
  { id: '1', label: '1x', detail: 'As captured: 720 x 576 from the KS2' },
  { id: '2', label: '2x', detail: '1440 x 1152' }
];

// The canvas for a scale, in a tab availW x availH CSS pixels with dpr
// device pixels to the CSS pixel, for a picture srcW x srcH. canvasW and
// canvasH are the backing store, in device pixels; cssW and cssH what it is
// laid out at, so the browser never rescales the canvas behind the filter.
function layoutFor(scale, availW, availH, dpr, srcW, srcH) {
  const W = srcW > 0 ? srcW : 720;
  const H = srcH > 0 ? srcH : 576;
  const ratio = dpr > 0 ? dpr : 1;
  let perPixel;
  if (scale === '1' || scale === '2') {
    perPixel = Number(scale) * ratio;
  } else if (scale === 'fit-integer') {
    perPixel = Math.floor(Math.min((availW * ratio) / W, (availH * ratio) / H));
    if (!(perPixel >= 1)) {
      // Smaller than the picture: fit rather than spill out of the tab.
      perPixel = Math.min((availW * ratio) / W, (availH * ratio) / H);
    }
  } else {
    perPixel = Math.min((availW * ratio) / W, (availH * ratio) / H);
  }
  if (!(perPixel > 0)) {
    perPixel = 1;
  }
  const canvasW = Math.max(1, Math.round(W * perPixel));
  const canvasH = Math.max(1, Math.round(H * perPixel));
  return { canvasW, canvasH, cssW: canvasW / ratio, cssH: canvasH / ratio };
}

// Sharp bilinear's first pass: the whole multiple to scale up to with nearest
// neighbour before bilinear covers the rest. Never less than 1.
function prescaleFactor(canvasW, canvasH, srcW, srcH) {
  const k = Math.floor(Math.min(canvasW / (srcW > 0 ? srcW : 720), canvasH / (srcH > 0 ? srcH : 576)));
  return k >= 1 ? k : 1;
}

// Setting values as the renderer can use them: unknown ones fall back to the
// defaults, since they come from user settings.
function normaliseView(view) {
  const v = view || {};
  return {
    filter: FILTERS.some((f) => f.id === v.filter) ? v.filter : 'nearest',
    scale: SCALES.some((s) => s.id === v.scale) ? v.scale : 'fit'
  };
}

module.exports = { FILTERS, SCALES, layoutFor, prescaleFactor, normaliseView };
