import SwiftUI

/// OCR結果から確定できなかった読み候補を、根拠を添えてユーザーに選ばせる。
struct ReadingCandidatePicker: View {
    let candidates: [ReadingCandidate]
    let selectedReading: String
    let onSelect: (ReadingCandidate) -> Void

    var body: some View {
        if !candidates.isEmpty {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
                Text("読み候補")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(candidates) { candidate in
                    Button {
                        onSelect(candidate)
                    } label: {
                        HStack(spacing: AppTheme.Spacing.small) {
                            Image(systemName: selectedReading == candidate.reading ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedReading == candidate.reading ? Color.accentColor : Color.secondary)
                            Text(candidate.reading)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("\(candidate.source.displayName)・\(confidenceLabel(candidate.confidence))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(candidate.reading)、\(candidate.source.displayName)からの候補")
                }
            }
            .padding(.vertical, AppTheme.Spacing.xSmall)
        }
    }

    private func confidenceLabel(_ confidence: FieldConfidence) -> String {
        switch confidence {
        case .high: "確度高"
        case .medium: "要確認"
        case .low: "参考"
        }
    }
}
