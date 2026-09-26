import SwiftUI

enum Theme {
  static let space: CGFloat = 8
  static let radius: CGFloat = 10
}

struct EmptyState<Footer: View>: View {
  var title: String
  var systemImage: String
  @ViewBuilder var footer: () -> Footer

  var body: some View {
    VStack(spacing: Theme.space * 3) {
      Image(systemName: systemImage)
        .font(.system(size: 48, weight: .regular))
        .foregroundStyle(Color.accentColor)
        .accessibilityHidden(true)
      Text(title)
        .font(.title2.weight(.semibold))
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
        .font(.body.weight(.medium))
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
      .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
      .opacity(configuration.isPressed ? 0.7 : 1)
      .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
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
        .font(.body)
        .foregroundStyle(.secondary)
        .frame(width: 28, height: 28)
    }
    .buttonStyle(.borderless)
    .accessibilityLabel("More info")
    .popover(isPresented: $shown, arrowEdge: .trailing) {
      Text(text)
        .font(.body)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 240, alignment: .leading)
        .padding(Theme.space * 2)
    }
  }
}
