import SwiftUI
import Foundation

struct ScanDebugView: View {
    let trace: ScanDebugTrace?
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            Group {
                if let trace {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            section("Summary", text: """
                            Time: \(trace.timestamp.formatted(date: .abbreviated, time: .standard))
                            Provider: \(trace.provider)
                            Narration provider: \(trace.narrationProvider ?? "n/a")
                            Image bytes: \(trace.imageBytes)
                            Location: \(trace.locationSummary)
                            Ambient dB: \(trace.ambientDecibels.map { String(format: "%.1f", $0) } ?? "n/a")
                            Place signal: \(trace.placeSignalType)
                            Place evidence: \(trace.placeSignalEvidence ?? "none")
                            Skill selected: \(trace.selectedSkill)
                            Result title: \(trace.skillResultTitle)
                            Current title seen count: \(trace.currentTitleSeenCount)
                            """)
                            
                            section("AI Output (Raw JSON Fields)", text: """
                            category: \(trace.rawAIResponse.category)
                            description: \(trace.rawAIResponse.description)
                            query: \(trace.rawAIResponse.query)
                            confidence: \(String(format: "%.3f", trace.rawAIResponse.confidence))
                            """)
                            
                            section("Routing Decision", text: """
                            original: \(trace.routingDecisionOriginal)
                            resolved: \(trace.routedAIResponse.category)
                            reason: \(trace.routingReason)
                            matched keyword: \(trace.routingKeyword ?? "none")
                            """)
                            
                            section("Narration Output", text: trace.narrationOutput ?? "No smart narration output captured")
                            section("Narration Prompt", text: trace.narrationUserPrompt ?? "Unavailable")
                            section("Narration System Prompt", text: trace.narrationSystemPrompt ?? "Unavailable")
                            section("Vision System Prompt", text: trace.visionSystemPrompt)
                            section("User Context Injected", text: trace.userContextPrompt)
                        }
                        .padding()
                    }
                } else {
                    ContentUnavailableView(
                        "No Debug Trace Yet",
                        systemImage: "ladybug",
                        description: Text("Run a scan first, then open this panel.")
                    )
                }
            }
            .navigationTitle("Scan Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
    
    private func section(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(text)
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

private extension ScanDebugTrace {
    var routingDecisionOriginal: String {
        rawAIResponse.category
    }
}
