import Foundation

/// フィールド候補を名刺全体の制約で解決する。
nonisolated struct CardFieldResolver: Sendable {

    func resolve(spans: [CardTextSpan], candidates: [FieldCandidate]) -> [FieldAssignment] {
        var usedSpanIDs = Set<String>()
        var assignments: [FieldAssignment] = []

        // 連絡先はパターン一致を最優先し、意味フィールドと競合させない。
        let deterministicFields: [CardFieldKind] = [.email, .phone, .website, .address]
        for field in deterministicFields {
            let matches = candidates
                .filter { $0.field == field && $0.score >= 0.85 }
                .sorted(by: candidateOrder)
            let accepted = field == .phone ? matches : Array(matches.prefix(1))
            for candidate in accepted where candidate.spanIDs.allSatisfy({ !usedSpanIDs.contains($0) }) {
                assignments.append(makeAssignment(candidate, source: .deterministic))
                usedSpanIDs.formUnion(candidate.spanIDs)
            }
        }

        // 氏名と会社は一件。両方の候補を比較し、同じ span の二重採用を避ける。
        for field in [CardFieldKind.personName, .company, .title] {
            guard let best = candidates
                .filter({ $0.field == field && $0.spanIDs.allSatisfy { !usedSpanIDs.contains($0) } })
                .sorted(by: candidateOrder)
                .first,
                best.score >= threshold(for: field) else { continue }
            assignments.append(makeAssignment(best, source: .resolver))
            usedSpanIDs.formUnion(best.spanIDs)
        }

        // 部署は複数行を許可し、読み順で結合する。
        let departments = candidates
            .filter { $0.field == .department && $0.score >= 0.62 }
            .filter { $0.spanIDs.allSatisfy { !usedSpanIDs.contains($0) } }
            .sorted { lhs, rhs in
                readingOrder(of: lhs, spans: spans) < readingOrder(of: rhs, spans: spans)
            }
        if !departments.isEmpty {
            let values = departments.map(\.value)
            let ids = departments.flatMap(\.spanIDs)
            let score = departments.map(\.score).reduce(0, +) / Double(departments.count)
            assignments.append(FieldAssignment(
                spanIDs: ids,
                field: .department,
                value: values.joined(separator: " "),
                confidence: confidence(for: score),
                source: .resolver
            ))
        }

        return assignments
    }

    func ambiguousSpanIDs(
        candidates: [FieldCandidate],
        assignments: [FieldAssignment]
    ) -> [String] {
        let assigned = Set(assignments.flatMap(\.spanIDs))
        let semanticFields: Set<CardFieldKind> = [.personName, .company, .department, .title]
        return Dictionary(grouping: candidates.filter { semanticFields.contains($0.field) }, by: { $0.spanIDs.first ?? "" })
            .compactMap { spanID, grouped in
                guard !spanID.isEmpty, !assigned.contains(spanID) else { return nil }
                let sorted = grouped.sorted(by: candidateOrder)
                guard let first = sorted.first, first.score >= 0.25 else { return nil }
                if sorted.count == 1 || first.score - sorted[1].score >= 0.18 {
                    return first.score < threshold(for: first.field) ? spanID : nil
                }
                return spanID
            }
            .sorted()
    }

    func validate(
        decisions: [CardFieldDecision],
        request: CardFieldResolutionRequest
    ) -> [FieldAssignment] {
        let spansByID = Dictionary(uniqueKeysWithValues: request.spans.map { ($0.id, $0) })
        let candidatesByKey = Dictionary(grouping: request.candidates) { "\($0.spanIDs.first ?? ""):\($0.field.rawValue)" }
        var consumed = Set(request.assignments.flatMap(\.spanIDs))
        var result: [FieldAssignment] = []

        for decision in decisions {
            guard request.ambiguousSpanIDs.contains(decision.spanID),
                  spansByID[decision.spanID] != nil,
                  !consumed.contains(decision.spanID),
                  let candidate = candidatesByKey["\(decision.spanID):\(decision.field.rawValue)"]?.max(by: { $0.score < $1.score }) else {
                continue
            }
            result.append(FieldAssignment(
                spanIDs: candidate.spanIDs,
                field: decision.field,
                value: candidate.value,
                confidence: .medium,
                source: .aiAssisted
            ))
            consumed.formUnion(candidate.spanIDs)
        }
        return result
    }

    private func candidateOrder(_ lhs: FieldCandidate, _ rhs: FieldCandidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.spanIDs.joined() < rhs.spanIDs.joined()
    }

    private func threshold(for field: CardFieldKind) -> Double {
        switch field {
        case .personName: 0.48
        case .company: 0.55
        case .department: 0.62
        case .title: 0.58
        default: 0.85
        }
    }

    private func confidence(for score: Double) -> FieldConfidence {
        if score >= 0.82 { return .high }
        if score >= 0.55 { return .medium }
        return .low
    }

    private func makeAssignment(_ candidate: FieldCandidate, source: FieldAssignment.Source) -> FieldAssignment {
        FieldAssignment(
            spanIDs: candidate.spanIDs,
            field: candidate.field,
            value: candidate.value,
            confidence: confidence(for: candidate.score),
            source: source
        )
    }

    private func readingOrder(of candidate: FieldCandidate, spans: [CardTextSpan]) -> Int {
        let order = Dictionary(uniqueKeysWithValues: spans.map { ($0.id, $0.readingOrder) })
        return candidate.spanIDs.compactMap { order[$0] }.min() ?? .max
    }
}
