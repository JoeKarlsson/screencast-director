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
            .font(.system(size: 14, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .frame(width: 32, height: 28)
            .foregroundStyle(on ? Theme.accent : Color.secondary)
            .background(
              RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? Theme.accent.opacity(0.16) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(on ? .isSelected : [])
      }
    }
    .padding(3)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    .frame(maxWidth: .infinity)
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

/// A card of related controls under a small header.
struct InspectorSection<Content: View>: View {
  let title: String
  let detail: String
  let content: Content

  init(_ title: String, detail: String = "", @ViewBuilder content: () -> Content) {
    self.title = title
    self.detail = detail
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.subheadline.weight(.semibold))
        if !detail.isEmpty {
          Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      content
    }
    .card()
  }
}

/// LabeledContent as a fixed-width secondary label and the control filling the rest, so rows line up.
struct InspectorRowStyle: LabeledContentStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 10) {
      configuration.label
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(width: 78, alignment: .leading)
      HStack(spacing: 8) { configuration.content }
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
      .font(.system(size: 11, weight: .medium, design: .rounded))
      .foregroundStyle(.primary)
      .padding(.horizontal, 6)
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
      .font(.system(size: size * 0.47, weight: .semibold))
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
    RoundedRectangle(cornerRadius: 8, style: .continuous)
      .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
      .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
      .frame(height: 34)
      .padding(3)
      .overlay(
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 2))
      .overlay(alignment: .bottomTrailing) {
        if selected {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 13))
            .foregroundStyle(.white, Theme.accent)
            .padding(6)
        }
      }
      .contentShape(Rectangle())
  }
}
