import SwiftUI

enum Theme {
  static let space: CGFloat = 8
  static let radius: CGFloat = 10
  /// The one rounded shape for cards, wells and tooltips. Pills use `Capsule()`.
  static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
  /// Background of cards, chips and the model bar.
  static let fill = AnyShapeStyle(.quaternary.opacity(0.6))
  /// Hairline around wells that hold content: code, logs, tables.
  static let border = AnyShapeStyle(.separator)
}

/// The five text sizes of the app. Change weight at the call site, never the size.
extension Font {
  /// 22 · the title of a page.
  static let pageTitle = Font.system(size: 22)
  /// 17 · the title of a section or a card.
  static let sectionTitle = Font.system(size: 17)
  /// 15 · sidebar rows and titles inside a panel.
  static let rowTitle = Font.system(size: 15)
  /// 13 · everything you read or click.
  static let text = Font.system(size: 13)
  /// 11 · notes, captions and table hints.
  static let note = Font.system(size: 11)
  /// 11 monospaced · code and logs.
  static let code = Font.system(size: 11, design: .monospaced)

  /// Symbols only: the large picture of an empty page.
  static let heroIcon = Font.system(size: 40)
  /// Symbols only: the badge of a card.
  static let badgeIcon = Font.system(size: 28)
}

extension View {
  /// A filled card with the shared shape.
  func card(padding: CGFloat = Theme.space * 2) -> some View {
    self.padding(padding).background(Theme.fill, in: Theme.shape)
  }
}

struct EmptyState<Footer: View>: View {
  var title: String
  var systemImage: String
  @ViewBuilder var footer: () -> Footer

  var body: some View {
    VStack(spacing: Theme.space * 3) {
      Image(systemName: systemImage)
        .font(.heroIcon)
        .foregroundStyle(Color.accentColor)
        .accessibilityHidden(true)
      Text(title)
        .font(.sectionTitle.weight(.semibold))
      footer()
    }
    .padding(Theme.space * 4)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct ChoiceCard: View {
  var title: String
  var systemImage: String
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .font(.text.weight(.medium))
    }
    .buttonStyle(ChoiceCardStyle())
  }
}

private struct ChoiceCardStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .frame(maxWidth: .infinity, minHeight: 64)
      .padding(.horizontal, Theme.space * 2)
      .padding(.vertical, Theme.space * 2)
      .background(Theme.fill, in: Theme.shape)
      .opacity(configuration.isPressed ? 0.7 : 1)
      .contentShape(Theme.shape)
  }
}

struct HintButton: View {
  var text: String
  @State private var shown = false

  var body: some View {
    Button {
      shown.toggle()
    } label: {
      Image(systemName: "info.circle")
        .font(.text)
        .foregroundStyle(.secondary)
        .frame(width: 28, height: 28)
    }
    .buttonStyle(.borderless)
    .accessibilityLabel("More info")
    .popover(isPresented: $shown, arrowEdge: .trailing) {
      Text(text)
        .font(.text)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 240, alignment: .leading)
        .padding(Theme.space * 2)
    }
  }
}
