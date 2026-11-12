import SwiftUI

// Building blocks for the inspector: the icon tab bar, titled cards, value rows, keycaps and
// swatches. Plain structs with no view state (no @State without macro plugins).

/// The row of icon tabs at the top of the inspector, Screen Studio style.
struct InspectorTabBar: View {
  @ObservedObject var ui: InspectorUI

  var body: some View {
    HStack(spacing: 2) {
      ForEach(InspectorUI.Tab.allCases, id: \.self) { tab in
        let on = ui.tab == tab
        Button {
          ui.tab = tab
        } label: {
          Image(systemName: tab.icon)
            .font(Theme.glyph(14, .medium))
            .symbolRenderingMode(.hierarchical)
            .frame(width: 32, height: 28)
            .foregroundStyle(on ? Theme.accent : Color.secondary)
            .background(
              RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).fill(on ? Theme.accent.opacity(0.16) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(on ? .isSelected : [])
      }
    }
    .padding(3)
    .background(RoundedRectangle(cornerRadius: Theme.controlCorner, style: .continuous).fill(Color.primary.opacity(0.04)))
    .frame(maxWidth: .infinity)
  }
}

/// A setting with a few fixed options (five or fewer), all showing at once as equal-width cells
/// instead of a menu. A cell's `.help` is its `help` (the label when that's enough), for hover and tests.
struct ChoiceRow<Value: Hashable>: View {
  let options: [(value: Value, label: String, help: String)]
  @Binding var selection: Value

  init(_ options: [(Value, String)], selection: Binding<Value>) {
    self.options = options.map { ($0.0, $0.1, $0.1) }
    _selection = selection
  }

  init(_ options: [(Value, String, String)], selection: Binding<Value>) {
    self.options = options.map { ($0.0, $0.1, $0.2) }
    _selection = selection
  }

  var body: some View {
    HStack(spacing: Theme.Space.xs) {
      ForEach(options.indices, id: \.self) { i in
        let option = options[i], on = selection == option.value
        Button { selection = option.value } label: {
          Text(option.label)
            .font(Theme.font(.small, on ? .semibold : .regular))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity, minHeight: 28)
            .selectableTile(on: on)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(option.help)
        .accessibilityAddTraits(on ? .isSelected : [])
      }
    }
  }
}

/// A pane's title, with an optional line under it.
struct PaneTitle: View {
  let title: String
  var detail = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.title3.weight(.semibold))
      if !detail.isEmpty {
        Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A card of related controls under a small header. With `isOpen`, the header folds the card: a
/// section that rarely matters for this video can start closed.
struct InspectorSection<Content: View>: View {
  let title: String
  let detail: String
  let isOpen: Binding<Bool>?
  let content: Content

  init(_ title: String, detail: String = "", isOpen: Binding<Bool>? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.detail = detail
    self.isOpen = isOpen
    self.content = content()
  }

  var body: some View {
    let open = isOpen?.wrappedValue ?? true
    VStack(alignment: .leading, spacing: Theme.Space.m) {
      if let isOpen {
        Button {
          withAnimation(Theme.Motion.move) { isOpen.wrappedValue.toggle() }
        } label: {
          HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            header
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
              .font(Theme.glyph(10, .semibold))
              .foregroundStyle(.secondary)
              .rotationEffect(.degrees(open ? 90 : 0))
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(open ? "Hide \(title)" : "Show \(title)")
      } else {
        header
      }
      if open { content }
    }
    .card()
  }

  private var header: some View {
    Text(title).font(.subheadline.weight(.semibold)).help(detail)
  }
}

/// LabeledContent as a fixed-width secondary label and the control filling the rest, so rows line up.
struct InspectorRowStyle: LabeledContentStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: Theme.Space.m) {
      configuration.label
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(width: 78, alignment: .leading)
      HStack(spacing: Theme.Space.s) { configuration.content }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// A key drawn as a keycap.
struct Keycap: View {
  let key: String

  init(_ key: String) { self.key = key }

  var body: some View {
    Text(key)
      .font(Theme.font(.caption, .medium, design: .rounded))
      .foregroundStyle(.primary)
      .padding(.horizontal, Theme.Space.s)
      .frame(minWidth: 22, minHeight: 20)
      .background(
        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(nsColor: .controlBackgroundColor))
          .shadow(color: Color.primary.opacity(0.18), radius: 0, y: 1))
      .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
  }
}

/// A rounded square holding an item kind's symbol in its theme color.
struct KindChip: View {
  let icon: String
  let color: Color
  var size: CGFloat = 30

  var body: some View {
    Image(systemName: icon)
      .font(Theme.glyph(size * 0.47, .semibold))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
          .fill(color.gradient))
      .accessibilityHidden(true)
  }
}

/// A gradient background preset; the selected one gets an accent ring.
struct GradientSwatch: View {
  let colors: [Color]
  let selected: Bool

  var body: some View {
    RoundedRectangle(cornerRadius: Theme.controlCorner, style: .continuous)
      .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
      .overlay(RoundedRectangle(cornerRadius: Theme.controlCorner, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
      .frame(height: 34)
      .padding(3)
      .overlay(
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 2))
      .overlay(alignment: .bottomTrailing) {
        if selected {
          Image(systemName: "checkmark.circle.fill")
            .font(Theme.glyph(13))
            .foregroundStyle(.white, Theme.accent)
            .padding(Theme.Space.s)
        }
      }
      .contentShape(Rectangle())
  }
}
