---
name: macos-ui
description: >-
  UI rules for the COGL-F1 macOS app. Use when changing SwiftUI, layout,
  copy, charts, tables, the sidebar, empty states, or visual design.
---

# COGL-F1 macOS UI

Native macOS. Do not port a web design system (shadcn, Cornflower, Column, or similar) into SwiftUI. Custom-drawn controls are what this app is trying to avoid.

Stay on APIs available since macOS 14.0. Do not use `glassEffect` or `TableColumnForEach` (`TableColumnForEach` needs 14.4).

## System

Use `Theme` in `app/Sources/COGLF1/Views/Theme.swift`.

- 8pt spacing, one corner radius, the system font, semantic colors, SF Symbols.
- Primary actions use `.controlSize(.large)`.
- The model bar sits in the window toolbar. Keep those controls at regular size. A large button there is clipped on every page.
- A control's hit target is the whole control. `ChoiceCard` must use a button style whose background is inside the button. A background behind the button only makes the text clickable.
- Disclosure rows, including Advanced, open when the whole row is clicked, not only the chevron.

## Copy

The screen should be usable without reading a paragraph. If the label already says what to do, do not add a caption.

- Info buttons (`HintButton`) only where the label is not the explanation: horizon, together vs separately, compare with history, and each Advanced flag. One plain sentence. No parameter names (`use_znorm`, CPM-RevIN).
- Skip obvious rows such as "Show actuals".
- Empty forecast state: title, one Open file button, then the word Samples and three sample cards. Those cards are bundled datasets, not recent files.
- Hide the data column and the parameter inspector until a file is open, so the drop zone is centered.
- Say Apple GPU, Metal, CPU, and Unload. Not MLX, PyTorch, or Eject.
- Sidebar rows are larger than the compact system default (`title3`, min row height 48).

## Data table

Zoom, resizable columns, and reorder belong on the CSV preview. Light and dark is one button and applies only to the CSV table and the column statistics table. It must not change the rest of the page or the app. There is no System option.

## Chart

Zoom with buttons and pinch. When zoomed in, the chart scrolls sideways. The hover info box is an overlay inside the visible plot. Do not attach it with a chart annotation: a scrollable chart clips that annotation, which is why the line showed and the box did not.
