import SwiftUI
import KatafractStyle

struct CategoryFilterBar: View {
    @Binding var selected: FileCategory

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FileCategory.allCases, id: \.self) { cat in
                    Button {
                        selected = cat
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: cat.iconName)
                                .font(.caption)
                            Text(cat.label)
                                .font(.subheadline.weight(.medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(selected == cat ? Color.kataSapphire : Color.secondary.opacity(0.15))
                        )
                        .foregroundStyle(selected == cat ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color(.systemBackground))
    }
}
