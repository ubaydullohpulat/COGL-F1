---
name: macos-ui
description: >-
  UI rules for the Forecast Studio macOS app. Use when changing SwiftUI, layout,
  copy, charts, tables, the sidebar, empty states, or visual design.
---

# Forecast Studio macOS UI

Native macOS. Do not port a web design system (shadcn, Cornflower, Column, or similar) into SwiftUI. Custom-drawn controls are what this app is trying to avoid.

Stay on APIs available since macOS 14.0. Do not use `glassEffect` or `TableColumnForEach` (`TableColumnForEach` needs 14.4). The one exception is the model bar in `RootView.swift`: it draws its own glass capsule inside `if #available(macOS 26.0, *)`, because the system bubble cannot be moved off-centre.

## System

Use `Theme` in `app/Sources/COGLF1/Views/Theme.swift`.

- 8pt spacing, one corner radius, the system font, semantic colors, SF Symbols.
- Text has five sizes, all in `Theme.swift`: `.pageTitle` 22, `.sectionTitle` 17, `.rowTitle` 15, `.text` 13, `.note` 11. Code and logs use `.code`. Do not write `.font(.title2)`, `.font(.caption)` or `.font(.system(size:))` in a view. Change the weight at the call site, not the size.
- Symbols that act as pictures use `.heroIcon` (empty pages) or `.badgeIcon` (cards).
- One shape: `Theme.shape`. Pills use `Capsule()`. No other corner radius, except the tiny legend swatches.
- Cards, chips and the model bar are filled with `Theme.fill` and have no border or shadow. Use `.card()`.
- Wells that hold content (code, logs, tables) have a `Theme.border` hairline.
- Spacing and padding are 4, 8, 12, 16 or 24.
- Primary actions use `.controlSize(.large)`.
- The model bar sits in the window toolbar. Its controls are small with 13pt text, so the capsule leaves space above and below and the hover shapes stay inside it. A large button there is clipped on every page. No prominent button in the bar: in a toolbar it turns every label white.
- A control's hit target is the whole control. `ChoiceCard` must use a button style whose background is inside the button. A background behind the button only makes the text clickable.
- Disclosure rows, including Advanced, open when the whole row is clicked, not only the chevron.

## Window width

The window can be as narrow as 960. Nothing may be pushed out of it.

- Pages read `pageWidth` from the environment and fold their side panels when it is small. Do not raise the window minimum to make a layout fit.
- Forecast attaches the parameters column (`.inspector`) only when the page is wide enough. Even hidden, it keeps the chart area at least 588 wide. In a narrow window the Parameters button opens the same form in a popover.
- Fine-tune shows Settings and Progress as two tabs when they do not fit side by side.
- The model bar is centered over the chart or page content with `CenteredOver` and `.modelBarCenter()`. `CenteredOver` moves the toolbar item's own AppKit view and keeps it between its neighbours. Do not shift the bar with `.offset`: it is then drawn outside its item, and Load, Switch and Unload stop taking clicks. Padding in a toolbar item widens the page.

## Copy

The screen should be usable without reading a paragraph. If the label already says what to do, do not add a caption.

- Info buttons (`HintButton`) only where the label is not the explanation: horizon, together vs separately, compare with history, and each Advanced flag. One plain sentence. No parameter names (`use_znorm`, CPM-RevIN).
- Skip obvious rows such as "Show actuals".
- Empty forecast state: title, one Open file button, then Recent (up to five files opened lately, only when there are any), then the word Samples and three sample cards. The sample cards are bundled datasets and never appear under Recent.
- Hide the data column and the parameter inspector until a file is open, so the drop zone is centered.
- Say Apple GPU, Metal, CPU, and Unload. Not MLX, PyTorch, or Eject.
- Sidebar rows are larger than the compact system default (`title3`, min row height 48).

## Data table

Zoom, resizable columns, and reorder belong on the CSV preview. Light and dark is one button and applies only to the CSV table and the column statistics table. It must not change the rest of the page or the app. There is no System option.

## Chart

Zoom with buttons and pinch. When zoomed in, the chart scrolls sideways. With a mouse the system keeps the chart's scroll bar on screen and draws it just below the chart's frame; the chart leaves room for it, so it never covers the metric cards. The hover info box is an overlay inside the visible plot. Do not attach it with a chart annotation: a scrollable chart clips that annotation, which is why the line showed and the box did not.
