# Ahrefs themes

Two Ghostty themes for Kido.app, `app/Resources/themes/ahrefs-light` and
`app/Resources/themes/ahrefs-dark`, built from the colours of
https://ahrefs.com (fetched 2026-10-25, release `20261023-bk54787`).
`mockup.html` renders both side by side. Render it with headless Chrome
at 1200x900; `#light` or `#dark` in the URL renders one theme alone.

## Source colours and their roles on the page

Taken from the page HTML (inline CSS variables on each section) and the
linked esbuild stylesheets. The page is a sequence of full-width
sections, each with its own `backgroundColor`, `textColor` and
`colorLink` variables.

| Colour | Role on the page |
|---|---|
| `#F6F5F2` | Hero section background (first section, warm off-white) |
| `#E8E5DF` | Second section background (warm light grey) |
| `#FFFFFF` | Plain white sections |
| `#1C1A14` | Text colour on the hero and the warm grey sections |
| `#000000` | Text on white sections; also three black sections |
| `rgba(0,0,0,.65)` / `rgba(0,0,0,.4)` | Secondary and tertiary body text on light sections |
| `#635F55` | `--tertiary` text on light cards |
| `#B8B4A8` | `--default` colour of pill controls (muted warm grey) |
| `#E5E5E5` | `--opaqueGray`, borders and dividers |
| `#1E1E1E`, `#272727`, `#111111` | Dark section backgrounds and a dark feature box |
| `#FFFFFF` / `rgba(255,255,255,.7)` | Primary and secondary text on dark sections |
| `#FF8D00` | `--accentPrimary`, the brand orange: buttons, logo |
| `#FF7524` | Button hover orange |
| `#F75A03` | Hover colour of links on light sections (deeper orange-red) |
| `#FFB528` | Hover colour of links on dark sections; amber headings on black |
| `#FFDBB3`, `#FFE7CD`, `#FFF4E8` | Muted orange tints: outlines and soft backgrounds |
| `#3A57FC` | `--colorLink` on light sections; six blue sections use it as background |
| `#3A75FF` | `--colorLink` on dark sections; blue CTA buttons |
| `#2592FA` | One sky-blue section background and link |
| `#6B6820`, `#9A9540`, `#C9C47A` | Olive accent family on one feature block |
| `#F9E204`, `#F6FFB8` | A yellow highlight box and a chalk-yellow tint |

The page has no red, green, magenta or cyan of its own. Those hues are
derived (see "Adjustments").

## Mapping: role -> colour -> origin

Light theme, background `#FFFFFF`, foreground `#1C1A14`.

| Entry | Role in kido | Colour | Origin |
|---|---|---|---|
| background | terminal surface | `#FFFFFF` | white sections |
| foreground | text | `#1C1A14` | hero text |
| cursor-color | cursor | `#AAAAAA` | as kido-light |
| 0 | strongest text | `#1C1A14` | hero text |
| 1 | red | `#B8321A` | `#F75A03` hue-shifted to red, darkened |
| 2 | green, status | `#2E7D3E` | derived green, darkened for 4.5:1 |
| 3 | yellow | `#A85400` | `#FF8D00` darkened until 4.5:1 |
| 4 | blue, accent | `#3A57FC` | page link colour, as is |
| 5 | magenta | `#9A3A94` | derived: mid-hue between the orange and blue, darkened |
| 6 | cyan | `#157A8E` | derived teal, darkened for 4.5:1 |
| 7 | white (light-end text) | `#635F55` | `--tertiary` text |
| 8 | muted (secondary text) | `#767269` | `#635F55` lightened toward `#B8B4A8` |
| 9 | bright red | `#D93A1A` | `#F75A03` hue-shifted to red |
| 10 | bright green | `#3F9A4C` | derived |
| 11 | bright yellow | `#FF8D00` | brand orange, as is |
| 12 | bright blue | `#3A75FF` | dark-section link colour |
| 13 | bright magenta | `#C94CBE` | derived |
| 14 | bright cyan | `#1A98B8` | derived from `#2592FA`, shifted toward cyan |
| 15 | bright white | `#A09C92` | `#B8B4A8` darkened one step |
| 16 | strongest text, fixed ramp | `#1C1A14` | same as 0 (as kido-light) |
| 17 | mid grey, fixed ramp | `#8C8880` | warm counterpart of `#8f8f8f` |
| 18 | light grey, fixed ramp | `#B8B4A8` | pill default |
| 19 | hairline, fixed ramp | `#E5E5E5` | `--opaqueGray` |
| 20 | alternate surface | `#F6F5F2` | hero background |

Dark theme, background `#1E1E1E`, foreground `#C7C7C7`.

| Entry | Role in kido | Colour | Origin |
|---|---|---|---|
| background | terminal surface | `#1E1E1E` | dark section background |
| foreground | text | `#C7C7C7` | white at 75% over `#1E1E1E`, between the page's 70% and kido-dark's `#C9C9C9` |
| cursor-color | cursor | `#999999` | as kido-dark |
| 0 | strongest text | `#F6F5F2` | hero background (light surface as text, as kido-dark uses `#EEEEEE`) |
| 1 | red | `#F0553C` | `#F75A03` hue-shifted to red |
| 2 | green, status | `#43BF6E` | derived |
| 3 | yellow | `#FF8D00` | brand orange, as is |
| 4 | blue, accent | `#5C8CFF` | `#3A75FF` lightened for 4.5:1 |
| 5 | magenta | `#CC73C2` | derived |
| 6 | cyan | `#4BB8CC` | derived |
| 7 | white | `#B8B4A8` | pill default |
| 8 | muted | `#8C8880` | warm counterpart of `#8f8f8f` |
| 9 | bright red | `#FF7A5C` | `#FF7524` hue-shifted to red |
| 10 | bright green | `#6ADB92` | derived |
| 11 | bright yellow | `#FFB528` | dark-section hover amber |
| 12 | bright blue | `#2592FA` | sky-blue section |
| 13 | bright magenta | `#E491D9` | derived |
| 14 | bright cyan | `#7FD1E3` | derived |
| 15 | bright white | `#A09C92` | `#B8B4A8` darkened one step |
| 16..19 | fixed ramp | as light | identical in both, as kido-light/kido-dark |
| 20 | alternate surface | `#272727` | the other dark section background |

Relation of 16..20 kept from the shipped themes: 16..19 are one grey
ramp shared by both themes (16 equals the light theme's palette 0), and
20 is a surface one small step away from the background, away from the
foreground (darker in light, lighter in dark).

## Contrast (WCAG 2.x, against the theme background)

Requirement: 0..7 at least 4.5:1. 8..15 are listed with a 3.0:1 mark
for information only. 16..20 are not text colours in both themes.

```
light: bg #FFFFFF fg #1C1A14 (17.40:1)
| idx | colour | ratio | ok |
|---|---|---|---|
| 0 | #1C1A14 | 17.40 | ok |
| 1 | #B8321A | 5.98 | ok |
| 2 | #2E7D3E | 5.10 | ok |
| 3 | #A85400 | 5.34 | ok |
| 4 | #3A57FC | 5.32 | ok |
| 5 | #9A3A94 | 6.16 | ok |
| 6 | #157A8E | 4.99 | ok |
| 7 | #635F55 | 6.37 | ok |
| 8 | #767269 | 4.79 | ok |
| 9 | #D93A1A | 4.59 | ok |
| 10 | #3F9A4C | 3.54 | ok |
| 11 | #FF8D00 | 2.32 | LOW |
| 12 | #3A75FF | 4.06 | ok |
| 13 | #C94CBE | 3.99 | ok |
| 14 | #1A98B8 | 3.37 | ok |
| 15 | #A09C92 | 2.74 | LOW |
| 16 | #1C1A14 | 17.40 | ok |
| 17 | #8C8880 | 3.53 | ok |
| 18 | #B8B4A8 | 2.07 | LOW |
| 19 | #E5E5E5 | 1.26 | LOW |
| 20 | #F6F5F2 | 1.09 | LOW |

dark: bg #1E1E1E fg #C7C7C7 (9.86:1)
| idx | colour | ratio | ok |
|---|---|---|---|
| 0 | #F6F5F2 | 15.29 | ok |
| 1 | #F0553C | 4.82 | ok |
| 2 | #43BF6E | 7.08 | ok |
| 3 | #FF8D00 | 7.19 | ok |
| 4 | #5C8CFF | 5.28 | ok |
| 5 | #CC73C2 | 5.40 | ok |
| 6 | #4BB8CC | 7.17 | ok |
| 7 | #B8B4A8 | 8.04 | ok |
| 8 | #8C8880 | 4.72 | ok |
| 9 | #FF7A5C | 6.50 | ok |
| 10 | #6ADB92 | 9.65 | ok |
| 11 | #FFB528 | 9.44 | ok |
| 12 | #2592FA | 5.22 | ok |
| 13 | #E491D9 | 7.42 | ok |
| 14 | #7FD1E3 | 9.63 | ok |
| 15 | #A09C92 | 6.09 | ok |
| 16 | #1C1A14 | 1.04 | LOW |
| 17 | #8C8880 | 4.72 | ok |
| 18 | #B8B4A8 | 8.04 | ok |
| 19 | #E5E5E5 | 13.23 | ok |
| 20 | #272727 | 1.12 | LOW |
```

Lowest regular-text ratio: light palette 6 (`#157A8E`) at 4.84:1;
dark palette 1 (`#F0553C`) at 4.82:1.

## Adjustments and why

- **Orange cannot be yellow/3 on the light theme as is.** `#FF8D00` is
  2.26:1 on white. Palette 3 is darkened to `#A85400` (4.90:1), and
  the brand orange moves to bright yellow/11, where kido-light also
  keeps a low-contrast `#f0da4a`. On the dark theme the brand orange is
  3 (7.19:1) and the page's amber hover `#FFB528` is 11.
- **The dark-section link blue is too dark for text on `#1E1E1E`.**
  `#3A75FF` is 3.8:1. Palette 4 is lightened to `#5C8CFF` (5.28:1).
  The page's sky blue `#2592FA` takes 12.
- **Red, green, magenta and cyan do not exist on the page.** Red is the
  link-hover orange `#F75A03` with its hue moved to red. Magenta sits
  between the orange and the blue. Green and cyan are plain derived
  hues, darkened (light) or lightened (dark) to pass 4.5:1. Green stays
  green: the olive accent `#6B6820` was not used because it reads as
  brown next to the oranges.
- **Palette 7 is a real text colour.** kido-light's 7 (`#acacac`) is
  2.3:1. To meet the 4.5:1 rule, the light theme uses the page's
  `--tertiary` `#635F55`. 15 keeps the shipped behaviour of a faint
  grey.
- **Muted/8 on light is 4.66:1.** `#767269` keeps it visibly lighter
  than 7.
- **The light background is `#FFFFFF`**, the page's white sections,
  chosen over the hero's off-white on review. The hero surface
  `#F6F5F2` became the alternate surface 20. The foreground stays the
  hero's warm near-black `#1C1A14` rather than the white sections'
  `#000000`, so text matches the warm greys of 7, 8 and 15.
- **The dark background is `#1E1E1E`**, the page's dark section, not
  the `#111111` feature box or `#000000`, to stay close to kido-dark's
  `#171717` and keep the 20 surface (`#272727`) a page colour.
