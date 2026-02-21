import SwiftUI

struct ResultCardView: View {
    let query: LookoutQuery
    let onDismiss: () -> Void
    let onOpenSource: (URL) -> Void

    @State private var glowOpacity: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            if query.status == .complete, let result = query.skillResult {
                completedResultView(result: result)
            } else if query.status == .error {
                errorView
            } else {
                loadingView
            }
        }
        .background(cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        // Category-tinted border — stronger than before
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            categoryColor.opacity(0.5),
                            Color.white.opacity(0.18),
                            categoryColor.opacity(0.25)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        // Outer glow halo — fades in on appear
        .shadow(color: categoryColor.opacity(glowOpacity * 0.45), radius: 24, x: 0, y: 0)
        .shadow(color: .black.opacity(0.28), radius: 16, y: 8)
        .frame(maxWidth: 360)
        .padding(.horizontal, 22)
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) { glowOpacity = 1 }
        }
        .onChange(of: query.skillResult?.category) { _, _ in
            glowOpacity = 0
            withAnimation(.easeOut(duration: 0.6)) { glowOpacity = 1 }
        }
    }

    // MARK: - Completed Result
    private func completedResultView(result: SkillResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                if let imageData = query.imageData, let uiImage = UIImage(data: imageData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(categoryColor.opacity(0.4), lineWidth: 1)
                        )
                }

                VStack(alignment: .leading, spacing: 4) {
                    // Skill badge
                    HStack(spacing: 6) {
                        Image(systemName: result.category.iconName)
                            .font(.caption2)
                            .foregroundStyle(categoryColor)
                        Text(result.category.badgeName)
                            .font(.caption2.weight(.bold))
                            .fontDesign(.rounded)
                            .foregroundStyle(categoryColor)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    // Slightly stronger badge background
                    .background(categoryColor.opacity(0.22), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(categoryColor.opacity(0.3), lineWidth: 0.6)
                    )

                    Text(result.title)
                        .font(.headline.weight(.semibold))
                        .lineLimit(2)

                    if let summary = summaryText(for: result) {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            let details = essentialDetails(for: result)
            if !details.isEmpty {
                HStack(spacing: 6) {
                    ForEach(details) { detail in detailChip(detail) }
                }
            }

            HStack(spacing: 8) {
                if !result.sourceApp.isEmpty {
                    Label(result.sourceApp, systemImage: "link")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }

                if let aiResponse = query.aiResponse {
                    // Confidence pill — tinted to category
                    Text("\(Int(aiResponse.confidence * 100))%")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .foregroundStyle(categoryColor)
                        .background(categoryColor.opacity(0.15), in: Capsule())
                        .overlay(Capsule().stroke(categoryColor.opacity(0.25), lineWidth: 0.6))
                }

                Spacer(minLength: 0)

                if let url = result.deepLinkURL {
                    Button(action: { onOpenSource(url) }) {
                        Label("Open", systemImage: "arrow.up.right.square")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(categoryColor)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private func detailChip(_ detail: SkillResult.DetailItem) -> some View {
        HStack(spacing: 4) {
            if let icon = detail.iconName {
                Image(systemName: icon).font(.caption2).foregroundStyle(categoryColor)
            }
            Text("\(detail.label): \(detail.value)")
                .font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
                )
        )
    }

    private func summaryText(for result: SkillResult) -> String? {
        let trimmedSubtitle = result.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSubtitle.isEmpty, trimmedSubtitle != result.title { return trimmedSubtitle }
        let description = query.aiResponse?.description.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !description.isEmpty { return description }
        return nil
    }

    private func essentialDetails(for result: SkillResult) -> [SkillResult.DetailItem] {
        let excludedLabels: Set<String> = ["Tip", "Note", "Summary", "Description"]
        return Array(
            result.details.filter { detail in
                let value = detail.value.trimmingCharacters(in: .whitespacesAndNewlines)
                return !value.isEmpty && !excludedLabels.contains(detail.label)
            }
            .prefix(2)
        )
    }

    // MARK: - Loading
    private var loadingView: some View {
        HStack(spacing: 12) {
            if let imageData = query.imageData, let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.white.opacity(0.24), lineWidth: 1)
                    )
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(query.status.rawValue).font(.subheadline.weight(.medium))
                ShimmerProgressBar(tint: categoryColor)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    // MARK: - Error
    private var errorView: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title3).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Scan Failed").font(.subheadline.weight(.medium))
                Text(query.errorMessage ?? "Something went wrong")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            Button("Retry", action: onDismiss).buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    // MARK: - Card Surface (boosted radial accent)
    private var cardSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)

            // Directional sheen
            LinearGradient(
                colors: [
                    Color.white.opacity(0.14),
                    Color.white.opacity(0.04),
                    Color.black.opacity(0.15)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Category radial — boosted from 0.16 → 0.22
            RadialGradient(
                colors: [categoryColor.opacity(0.22), Color.clear],
                center: .topLeading,
                startRadius: 8,
                endRadius: 240
            )

            // Subtle bottom fade
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.08)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
    }

    // MARK: - Category Color
    private var categoryColor: Color {
        (query.skillResult?.category ?? query.aiResponse?.skillCategory ?? SkillCategory.unknown).skillColor
    }
}

// MARK: - Shimmer Progress Bar
struct ShimmerProgressBar: View {
    let tint: Color
    @State private var shimmerOffset: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(tint.opacity(0.15))
                    .frame(height: 4)

                RoundedRectangle(cornerRadius: 3)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.1), tint.opacity(0.9), tint.opacity(0.1)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * 0.4, height: 4)
                    .offset(x: geo.size.width * (shimmerOffset + 0.5))
                    .clipped()
            }
        }
        .frame(height: 4)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                shimmerOffset = 1
            }
        }
    }
}
