# Figures for the programmer's guide

The guide's drawings are plain SVG, so they stay small, diff well and show inline on GitHub. Figures drawn to scale are made by the scripts in `tools/guide_figures/` (`python timing.py`, `python playfields.py`; the sprite figures by `sprites/*.py`, each given its output file), so a changed number means a changed script, not a redrawn picture. Others may be written by hand. Small byte and bit layouts stay as ASCII in the chapter itself.

## Names

`<chapter>-<number>-<slug>.svg`, for example `timing-A-3-line.svg` or `playfields-3-1-beam.svg`. The number is the figure number in the chapter.

## Style

| Item | Rule |
|------|------|
| Background | A white rectangle over the whole drawing (GitHub's dark theme would otherwise show black text on black) |
| Size | `width`, `height` and `viewBox` all set, in pixels; at most 760 wide |
| Font | `font-family="Helvetica, Arial, sans-serif"`, 13 px for labels, 11 px for small numbers, 15 px bold for headings inside a figure. No web fonts |
| Text colour | `#1a1a1a`; secondary text `#555` |
| Lines | `#333`, 1 px; dimension lines and ticks `#777`; dashed (`stroke-dasharray="4 3"`) for "not shown" or "optional" |
| Fills | Blanking and border `#d9d9d9`; the picture `#cfe2f3`; CPU `#b6d7a8`; display fetch `#f9cb9c`; free pool, copper, DMA `#ffe599`; sprites `#d5a6bd`; highlight `#f4b183`; memory not shown `#f3f3f3` |
| Numbers | Beam coordinates and T-states as in the text: decimal, with `0x` for hexadecimal |
| Captions | Not in the SVG. The chapter gives the caption under the image |

Draw to scale where the figure is about sizes or times, and say so in the caption when it is not to scale.

## In a chapter

```markdown
![The screen and the beam](img/playfields-3-1-beam.svg)

*Figure 3-1: The Screen and the Beam*
```

## Checking a figure

Open the SVG in a browser, or render it with headless Edge or Chrome:

```sh
msedge --headless=new --window-size=W,H --screenshot=out.png file:///C:/path/figure.svg
```
