# Nook

A bar drawer for Omarchy, for when too many plugins have cluttered your bar.
Collapse the ones you rarely touch into a tray that slides out below the bar,
leaving one chevron behind. Drag widgets in and out.

The tray is a layer surface anchored to the bar's own edge, so a widget inside
it opens its panel under its own icon, the way it would on the bar.

## Install

```sh
omarchy plugin add https://github.com/Katsari/nook.git --enable
```

The installer asks which bar section to put it in, and starts on `right`.

## Usage

Hover the chevron to open the tray. Click it to pin the tray open, and click
again to put it away. Click a widget inside to use it as you would on the bar.

Drag a widget off the bar onto the chevron to file it away, drag one inside the
tray to reorder it, and drag one out to put it back on the bar. A caret marks
where it will land. A press too short to become a drag stays a click.

Every move rewrites `~/.config/omarchy/shell.json`.

## Settings

Settings live on Nook's `bar.layout` entry in `~/.config/omarchy/shell.json`.

| Key | Default | Meaning |
| --- | --- | --- |
| `items` | `[]` | The widgets inside, as layout entries |
| `trigger` | `"hover"` | `"hover"` opens on pointer-over; anything else means click-only |
| `duration` | `180` | Reveal animation, in milliseconds |

The tray's layer surface is named `nook`, for Hyprland layer rules.

Each item takes the same shape as a bar layout entry, so per-widget settings go
on the item:

```json
{
  "id": "io.github.katsari.nook",
  "trigger": "hover",
  "items": [
    { "id": "some.widget" },
    { "id": "another.widget", "format": "short" }
  ]
}
```

Editing `items` by hand needs a second step: add each widget to the top-level
`plugins[]` array as well, or it stays disabled and never renders. Dragging
does both for you.

## Commands

```bash
omarchy-shell io.github.katsari.nook toggle            # also: open, close
omarchy-shell io.github.katsari.nook absorb <id>       # move a widget in
omarchy-shell io.github.katsari.nook eject <id>        # put one back on the bar
omarchy-shell io.github.katsari.nook reorder <from> <to>
omarchy-shell io.github.katsari.nook status            # what it thinks it is doing
```

`reorder` takes positions in `items`. `to` is an insertion index measured
before the move, so `reorder 0 3` puts the first widget third.

Read `status` when a gesture misbehaves: it separates a wrong state from a
pointer that never arrived.

## Remove

```sh
omarchy plugin remove io.github.katsari.nook
```

Whatever the tray held stays in `items` on that entry, so removing Nook while
it is full leaves those widgets off your bar. Drag them out first, or `eject`
each one.

## Known limits

Built for Omarchy 4.0.1. Beyond the widget contract every plugin uses, Nook
reaches into the bar's widget registry, its slot and click-target bookkeeping,
and its drag state. No plugin API covers those, so an update can break it.

- **One Nook per bar.** A second one's writes would land in the first.
- **Bottom and right bars can misroute a bar click.** The bar matches clicks
  against every widget's own geometry without checking which window it is in,
  and on those two edges the tray overlaps the bar's coordinate range. The
  chevron is covered; other bar widgets are not.
- **Tab between panels and the bar settings UI** both read `bar.layout`, so
  neither sees the widgets inside the tray.
