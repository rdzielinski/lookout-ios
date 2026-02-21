import SwiftUI

struct ScanHistoryView: View {
    @ObservedObject var viewModel: LookoutViewModel
    @Environment(\.dismiss) var dismiss

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.06, green: 0.06, blue: 0.09)
                    .ignoresSafeArea()

                if viewModel.queryHistory.isEmpty {
                    emptyState
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(viewModel.queryHistory) { query in
                                HistoryCard(query: query)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 32)
                    }
                }
            }
            .navigationTitle("Scan History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Text("\(viewModel.queryHistory.count) scans")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 52, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.25))

            Text("No Scans Yet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))

            Text("Your scan history will appear here")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - History Card
struct HistoryCard: View {
    let query: LookoutQuery

    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Thumbnail
            thumbnailArea

            // Info area
            VStack(alignment: .leading, spacing: 6) {
                // Category badge
                HStack(spacing: 4) {
                    Image(systemName: category.iconName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(categoryColor)
                    Text(category.badgeName)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(categoryColor)
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(categoryColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                // Title
                Text(query.skillResult?.title ?? query.aiResponse?.description ?? "Analyzing…")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                // Subtitle / description
                if let sub = subtitleText {
                    Text(sub)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }

                // Timestamp
                HStack {
                    Spacer()
                    Text(relativeTime)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [categoryColor.opacity(0.4), Color.white.opacity(0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        )
        .shadow(color: categoryColor.opacity(0.18), radius: 12, y: 4)
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        .scaleEffect(appeared ? 1 : 0.92)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75).delay(Double.random(in: 0...0.12))) {
                appeared = true
            }
        }
    }

    // MARK: - Thumbnail
    private var thumbnailArea: some View {
        ZStack(alignment: .bottomLeading) {
            if let imageData = query.imageData, let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 110)
                    .clipped()
            } else {
                // Placeholder with category color
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [categoryColor.opacity(0.3), categoryColor.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 110)
                    .overlay(
                        Image(systemName: category.iconName)
                            .font(.system(size: 28, weight: .ultraLight))
                            .foregroundStyle(categoryColor.opacity(0.6))
                    )
            }

            // Gradient overlay at bottom for readability
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )

            // Status indicator
            Circle()
                .fill(query.status == .complete ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
                .padding(8)
        }
        .frame(height: 110)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 16,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 16
            )
        )
    }

    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.12, green: 0.12, blue: 0.16))

            RadialGradient(
                colors: [categoryColor.opacity(0.10), Color.clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 140
            )
        }
    }

    // MARK: - Helpers
    private var category: SkillCategory {
        // Fully qualify .unknown so the compiler doesn't confuse it with Color.unknown
        query.skillResult?.category
            ?? query.aiResponse?.skillCategory
            ?? SkillCategory.unknown
    }

    private var categoryColor: Color {
        category.skillColor
    }

    private var subtitleText: String? {
        let sub = query.skillResult?.subtitle.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !sub.isEmpty, sub != (query.skillResult?.title ?? "") { return sub }
        return query.aiResponse?.description
    }

    private var relativeTime: String {
        let diff = Date().timeIntervalSince(query.timestamp)
        if diff < 60 { return "just now" }
        if diff < 3600 { return "\(Int(diff / 60))m ago" }
        if diff < 86400 { return "\(Int(diff / 3600))h ago" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: query.timestamp)
    }
}
