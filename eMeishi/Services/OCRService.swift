import Foundation
import Vision
import UIKit
import CoreImage
import os

// OCR で認識した1行分のデータ（テキスト・位置・信頼度）
nonisolated enum RecognizedTextDirection: Sendable, Equatable {
    case leftToRight
    case rightToLeft
    case topToBottom
    case unknown
}

nonisolated struct RecognizedLine: Sendable {
    let text: String
    /// Vision 座標系（正規化済み。原点は画像左下、x/y は 0.0〜1.0）
    let boundingBox: CGRect
    /// Vision の認識信頼度（0.0〜1.0）
    let confidence: Float
    /// OCR が返した文字方向。縦書き名刺の後処理で使用する
    let textDirection: RecognizedTextDirection

    init(
        text: String,
        boundingBox: CGRect,
        confidence: Float,
        textDirection: RecognizedTextDirection = .unknown
    ) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.textDirection = textDirection
    }
}

// Vision Framework を使って名刺画像からテキストを抽出するサービス
actor OCRService {

    private static let ciContext = CIContext()

    // MARK: - 矩形検出 + パースペクティブ補正

    // 名刺の矩形を検出してトリミング・補正した画像を返す。
    // 矩形が見つからない場合は元画像をそのまま返す。
    func detectAndCropCard(from image: UIImage) async -> UIImage {
        // EXIF向き情報を適用した正規化済み画像を使う
        let normalized = Self.normalizeOrientation(image)
        guard let cgImage = normalized.cgImage else { return image }

        do {
            let request = Self.cardRectangleRequest()
            let observations = try await request.perform(on: cgImage)
            guard let rect = Self.bestCardRectangle(from: observations),
                  let cropped = Self.perspectiveCorrected(cgImage: cgImage, observation: rect) else {
                return normalized
            }
            return cropped
        } catch {
            AppLogger.ocr.debug("名刺矩形検出に失敗。元画像を使用: \(error)")
            return normalized
        }
    }

    static func cardRectangleRequest() -> DetectRectanglesRequest {
        var request = DetectRectanglesRequest()
        // DetectRectanglesRequest の aspect ratio は 0...1 の短辺/長辺比。旧 API の 0.4...2.5 とは範囲が違う。
        request.minimumAspectRatio = 0.32
        request.maximumAspectRatio = 1.0
        request.minimumConfidence = 0.45
        request.minimumSize = 0.04
        request.maximumObservations = 20
        return request
    }

    static func bestCardRectangle(from observations: [RectangleObservation]) -> RectangleObservation? {
        let scored = observations
            .enumerated()
            .compactMap { index, observation in
                cardRectangleScore(
                    metrics: cardRectangleMetrics(for: observation),
                    confidence: observation.confidence
                ).map { (index: index, score: $0) }
            }
        return bestScoredIndex(scored).map { observations[$0] }
    }

    static func bestCardRectIndex(candidates: [(rect: CGRect, confidence: Float)]) -> Int? {
        let scored = candidates
            .enumerated()
            .compactMap { index, candidate in
                cardRectangleScore(
                    metrics: cardRectangleMetrics(for: candidate.rect),
                    confidence: candidate.confidence
                ).map { (index: index, score: $0) }
            }
        return bestScoredIndex(scored)
    }

    /// 同点とみなすスコア差（正規化値）。この幅の中では Vision 返却順を優先する。
    private static let cardScoreTieTolerance: CGFloat = 0.01

    /// 最良候補の index を返す。Vision 返却順への依存を減点でなく
    /// タイブレークとして表現する: スコアをトレランス幅でバケット化し、
    /// 同一バケット内は Vision index 昇順（= 先に返された候補）を選ぶ。
    private static func bestScoredIndex(_ scored: [(index: Int, score: CGFloat)]) -> Int? {
        scored
            .filter { $0.score >= minimumAcceptableCardScore }
            .map { (index: $0.index, bucket: Int(($0.score / cardScoreTieTolerance).rounded())) }
            .sorted {
                if $0.bucket != $1.bucket { return $0.bucket > $1.bucket }
                return $0.index < $1.index
            }
            .first?
            .index
    }

    /// スコア各項の重み。正規化の分母 total と常に一致させるため一元管理する。
    private enum CardScoreWeight {
        static let confidence: CGFloat = 1.5
        static let aspect: CGFloat = 1.5
        static let area: CGFloat = 2.5
        static let edge: CGFloat = 1.4
        static let shape: CGFloat = 1.0
        static let centrality: CGFloat = 0.8
        /// 全項目が満点のときの重み和（= 8.7）。スコアを 0〜1 へ正規化する分母。
        static let total: CGFloat = confidence + aspect + area + edge + shape + centrality
    }

    /// 名刺外周として採用する最低スコア（正規化値）。ロゴ・QR・罫線などの局所矩形しか
    /// 検出できなかった場合は候補なし（= 元画像維持）へ倒すための下限（#187）。
    /// 旧絶対値 5.3 / 重み和 8.7 = 0.609 と同じ分割になる値。
    private static let minimumAcceptableCardScore: CGFloat = 0.61

    /// 名刺外周として意味を持つ最小面積（正規化）。これ未満はロゴ・QR 相当。
    private static let minimumCardArea: CGFloat = 0.055

    /// 画像の大部分を占める矩形はテーブル面や背景枠の可能性が高いため、
    /// この閾値を超えた面積分だけ減点を漸増させる（寄り撮影の正当な大矩形は残す）。
    private static let oversizedAreaThreshold: CGFloat = 0.70
    private static let oversizedAreaPenaltyWeight: CGFloat = 3.0

    private struct CardRectangleMetrics {
        let area: CGFloat
        let shortLongAspect: CGFloat
        let oppositeSideBalance: CGFloat
        let edgeInset: CGFloat
        let centerOffset: CGFloat
    }

    private static func cardRectangleMetrics(for observation: RectangleObservation) -> CardRectangleMetrics {
        let topLeft = observation.topLeft.cgPoint
        let topRight = observation.topRight.cgPoint
        let bottomLeft = observation.bottomLeft.cgPoint
        let bottomRight = observation.bottomRight.cgPoint

        let top = distance(topLeft, topRight)
        let bottom = distance(bottomLeft, bottomRight)
        let left = distance(topLeft, bottomLeft)
        let right = distance(topRight, bottomRight)
        let horizontal = (top + bottom) / 2
        let vertical = (left + right) / 2
        let shortLongAspect = min(horizontal, vertical) / max(horizontal, vertical, 0.001)
        let horizontalBalance = min(top, bottom) / max(top, bottom, 0.001)
        let verticalBalance = min(left, right) / max(left, right, 0.001)
        let area = polygonArea([topLeft, topRight, bottomRight, bottomLeft])
        let xs = [topLeft.x, topRight.x, bottomLeft.x, bottomRight.x]
        let ys = [topLeft.y, topRight.y, bottomLeft.y, bottomRight.y]
        let edgeInset = min(
            xs.min() ?? 0,
            ys.min() ?? 0,
            1 - (xs.max() ?? 1),
            1 - (ys.max() ?? 1)
        )

        let centroid = CGPoint(
            x: xs.reduce(0, +) / 4,
            y: ys.reduce(0, +) / 4
        )

        return CardRectangleMetrics(
            area: area,
            shortLongAspect: shortLongAspect,
            oppositeSideBalance: min(horizontalBalance, verticalBalance),
            edgeInset: max(0, edgeInset),
            centerOffset: distance(centroid, CGPoint(x: 0.5, y: 0.5))
        )
    }

    private static func cardRectangleMetrics(for rect: CGRect) -> CardRectangleMetrics {
        let shortLongAspect = min(rect.width, rect.height) / max(rect.width, rect.height, 0.001)
        return CardRectangleMetrics(
            area: rect.width * rect.height,
            shortLongAspect: shortLongAspect,
            oppositeSideBalance: 1,
            edgeInset: max(0, min(rect.minX, rect.minY, 1 - rect.maxX, 1 - rect.maxY)),
            centerOffset: distance(CGPoint(x: rect.midX, y: rect.midY), CGPoint(x: 0.5, y: 0.5))
        )
    }

    /// 名刺外周らしさの正規化スコア（0〜1）。足切り条件を満たさない候補は nil。
    private static func cardRectangleScore(
        metrics: CardRectangleMetrics,
        confidence: Float
    ) -> CGFloat? {
        let area = metrics.area
        // ロゴやQRコード程度の小矩形は候補から外す。大面積側は足切りでなく
        // 漸増ペナルティで扱う（寄り撮影では名刺が画面の大半を占めるため）。
        guard area >= minimumCardArea else { return nil }
        // 画像の外縁とほぼ一致する矩形は枠検出の誤りであり名刺ではない。
        guard !(area > 0.90 && metrics.edgeInset < 0.005) else { return nil }

        let shortLongAspect = metrics.shortLongAspect
        // 上限 0.95: 写真と名刺のアスペクトが近い構図では正規化座標上の比が
        // 1.0 へ近づくため、旧上限 0.90 では寄り撮影の正当な外周を弾いていた。
        guard (0.32...0.95).contains(shortLongAspect) else { return nil }
        guard metrics.oppositeSideBalance > 0.55 else { return nil }

        let businessCardAspect: CGFloat = 0.58
        let aspectScore = max(0, 1 - abs(shortLongAspect - businessCardAspect) / 0.35)
        // 面積の大きい外周を優先する。旧実装の hugeRectPenalty は影の外側にある
        // 正しい名刺外周を不利にしていたため廃止する。
        let areaScore = min(sqrt(area / 0.30), 1.0)
        // 名刺外周は画像端の近くまで届く。内側に浮いた矩形（ロゴ・白地パネル）ほど不利にする。
        let edgeScore = max(0, 1 - metrics.edgeInset / 0.24)
        let shapeScore = metrics.oppositeSideBalance
        // 撮影対象の名刺は画面中央を占める。中心から外れた局所矩形（QR・隅のロゴ）を減点する（#187）。
        let centralityScore = max(0, 1 - metrics.centerOffset / 0.42)
        // 占有率が低い矩形はロゴ・QR・罫線ブロックの可能性が高いため、面積スコアとは別に減点を漸増させる（#187）。
        let smallAreaPenalty = area < 0.14 ? (0.14 - area) / 0.14 * 1.8 : 0
        // 画面をほぼ覆う矩形（テーブル面・背景枠）は超過分に応じて減点する。
        let oversizedAreaPenalty = area > oversizedAreaThreshold
            ? (area - oversizedAreaThreshold) * oversizedAreaPenaltyWeight
            : 0

        let weightedSum = CGFloat(confidence) * CardScoreWeight.confidence
            + aspectScore * CardScoreWeight.aspect
            + areaScore * CardScoreWeight.area
            + edgeScore * CardScoreWeight.edge
            + shapeScore * CardScoreWeight.shape
            + centralityScore * CardScoreWeight.centrality
            - smallAreaPenalty
            - oversizedAreaPenalty
        return weightedSum / CardScoreWeight.total
    }

    private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private static func polygonArea(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 3 else { return 0 }
        let sum = points.enumerated().reduce(CGFloat.zero) { partial, item in
            let next = points[(item.offset + 1) % points.count]
            return partial + item.element.x * next.y - next.x * item.element.y
        }
        return abs(sum) / 2
    }

    // MARK: - パースペクティブ補正（CIPerspectiveCorrection）

    /// 補正後の名刺として妥当な短辺/長辺比。範囲外は補正失敗とみなし元画像へ倒す。
    /// 日本の名刺 91×55mm = 0.604、US 3.5×2in = 0.571。正方形に近い出力や
    /// 極端な細長出力は、頂点の取り違えや部分矩形の誤検出を示す。
    private static let plausibleCorrectedAspectRange: ClosedRange<CGFloat> = 0.40...0.85

    /// 補正後サイズが名刺として妥当かを判定する。
    static func isPlausibleCardAspect(_ size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        let shortLongAspect = min(size.width, size.height) / max(size.width, size.height)
        return plausibleCorrectedAspectRange.contains(shortLongAspect)
    }

    private static func perspectiveCorrected(
        cgImage: CGImage,
        observation: RectangleObservation
    ) -> UIImage? {
        let width  = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)

        // Vision の正規化座標（左下原点）→ Core Image のピクセル座標（左下原点）へ変換
        func toCI(_ point: CGPoint) -> CIVector {
            CIVector(x: point.x * width, y: point.y * height)
        }

        let ciImage = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(ciImage,                         forKey: kCIInputImageKey)
        filter.setValue(toCI(observation.topLeft.cgPoint), forKey: "inputTopLeft")
        filter.setValue(toCI(observation.topRight.cgPoint), forKey: "inputTopRight")
        filter.setValue(toCI(observation.bottomLeft.cgPoint), forKey: "inputBottomLeft")
        filter.setValue(toCI(observation.bottomRight.cgPoint), forKey: "inputBottomRight")

        guard let outputCIImage = filter.outputImage else { return nil }
        // extent は遅延評価なのでレンダリング前に検証できる。名刺として不合理な
        // 出力（頂点取り違え・部分矩形の誤検出）はここで破棄し、元画像維持へ倒す。
        let extent = outputCIImage.extent
        guard !extent.isEmpty, !extent.isInfinite, isPlausibleCardAspect(extent.size) else {
            AppLogger.ocr.debug("補正後アスペクトが名刺として不合理。元画像を使用")
            return nil
        }
        guard let outputCGImage = ciContext.createCGImage(outputCIImage, from: extent) else { return nil }
        return UIImage(cgImage: outputCGImage)
    }

    // MARK: - 向き正規化

    private static func normalizeOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    // MARK: - テキスト認識

    // 画像から RecognizedLine の配列を返す（精度優先・言語補正あり）
    // 各行のテキスト・Vision 正規化座標での位置・認識信頼度を同時に返す
    func recognizeText(from image: UIImage) async throws -> [RecognizedLine] {
        guard let cgImage = image.cgImage else {
            throw OCRError.invalidImage
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        AppLogger.ocr.info("OCR開始")

        do {
            var request = RecognizeTextRequest()
            // 精度最大・言語補正あり・日本語＋英語対応
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = [
                Locale.Language(identifier: "ja-JP"),
                Locale.Language(identifier: "en-US"),
            ]

            let observations = try await request.perform(on: cgImage)
            let rawLines: [RecognizedLine] = observations.compactMap { obs in
                let text = obs.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return RecognizedLine(
                    text: text,
                    boundingBox: obs.boundingBox.cgRect,
                    confidence: obs.confidence,
                    textDirection: Self.mapDirection(obs.textDirection)
                )
            }

            // 近接する短い断片行を統合（OCR が名前等を文字単位で分割する問題への対策）
            let lines = Self.mergeAdjacentFragments(
                rawLines,
                isVerticalCard: image.size.height > image.size.width * 1.1
            )
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            AppLogger.ocr.info("OCR完了: \(lines.count, privacy: .public)行認識 \(String(format: "%.1f", elapsed), privacy: .public)秒")
            return lines
        } catch {
            AppLogger.ocr.error("OCR失敗: \(error)")
            throw error
        }
    }

    private static func mapDirection(
        _ direction: RecognizedTextObservation.Direction?
    ) -> RecognizedTextDirection {
        switch direction {
        case .leftToRight:
            return .leftToRight
        case .rightToLeft:
            return .rightToLeft
        case .topToBottom:
            return .topToBottom
        case .some:
            return .unknown
        case nil:
            return .unknown
        }
    }

    // MARK: - 行統合

    /// Vision が等間隔文字や空白区切りで分断した行を統合する。
    ///
    /// 名刺では名前を均等配置する慣習があり、OCR が「田中」「花子」のように
    /// 1つの名前を複数の observation に分割することがある。
    /// 同一行（Y座標近接）かつ X 方向に近い短い断片を結合し、
    /// 下流の分類ロジックに安定した行を渡す。
    ///
    /// - Parameter isVerticalCard: 画像が縦長かどうかの補助情報。縦書き判定の
    ///   主役は Vision の textDirection で、この値は横書きの証拠が 1 行もない
    ///   場合のフォールバックにだけ使う。
    static func mergeAdjacentFragments(
        _ lines: [RecognizedLine],
        isVerticalCard: Bool = false
    ) -> [RecognizedLine] {
        guard lines.count > 1 else { return lines }

        // 主判定は Vision の textDirection。画像が縦長でも横書き行が検出されて
        // いれば横位置の名刺を縦向きに撮っただけであり、形状フォールバックは使わない。
        let hasHorizontalEvidence = lines.contains { $0.textDirection == .leftToRight }
        let allowsAspectFallback = isVerticalCard && !hasHorizontalEvidence

        let shouldUseVerticalMerge = lines.contains { isVerticalMergeCandidate($0, allowsAspectFallback: allowsAspectFallback) }

        guard shouldUseVerticalMerge else {
            return mergeHorizontalFragments(lines)
        }

        let verticalCandidates = lines.filter { isVerticalMergeCandidate($0, allowsAspectFallback: allowsAspectFallback) }
        let horizontalCandidates = lines.filter { !isVerticalMergeCandidate($0, allowsAspectFallback: allowsAspectFallback) }

        let mergedVertical = mergeVerticalFragments(verticalCandidates)
        let mergedHorizontal = mergeHorizontalFragments(horizontalCandidates)
        return sortForReadingOrder(mergedVertical + mergedHorizontal, preferVertical: true)
    }

    // MARK: - カラム境界推定

    /// 列境界とみなす最小の空白帯幅（正規化 X）。
    private static let minimumColumnGap: CGFloat = 0.08
    /// 列境界として意味を持つ位置の範囲。端に寄った空白は余白でしかない。
    private static let columnBoundaryRange: ClosedRange<CGFloat> = 0.30...0.70
    /// 境界の両側に最低限必要な行数。片側 1 行では列とは言えない。
    private static let minimumLinesPerColumn = 2

    /// 行群の X 区間をユニオンし、中央付近にある最大の空白帯を列境界として返す。
    /// 左右 2 カラム名刺で、別カラムの行同士が横結合されるのを防ぐ。
    static func columnBoundary(for lines: [RecognizedLine]) -> CGFloat? {
        guard lines.count >= minimumLinesPerColumn * 2 else { return nil }

        // X 区間を minX 昇順でマージし、連続グループ間のギャップを求める
        let intervals = lines
            .map { (min: $0.boundingBox.minX, max: $0.boundingBox.maxX) }
            .sorted { $0.min < $1.min }
        var mergedIntervals: [(min: CGFloat, max: CGFloat)] = []
        for interval in intervals {
            if var last = mergedIntervals.last, interval.min <= last.max {
                last.max = max(last.max, interval.max)
                mergedIntervals[mergedIntervals.count - 1] = last
            } else {
                mergedIntervals.append(interval)
            }
        }
        guard mergedIntervals.count >= 2 else { return nil }

        // 最大ギャップを列境界候補にする
        var bestBoundary: (center: CGFloat, width: CGFloat)?
        for (lhs, rhs) in zip(mergedIntervals, mergedIntervals.dropFirst()) {
            let width = rhs.min - lhs.max
            if width > (bestBoundary?.width ?? 0) {
                bestBoundary = (center: (lhs.max + rhs.min) / 2, width: width)
            }
        }
        guard let boundary = bestBoundary,
              boundary.width >= minimumColumnGap,
              columnBoundaryRange.contains(boundary.center) else { return nil }

        // 両側に列と呼べる行数があるかを確認する
        let leftCount = lines.filter { $0.boundingBox.midX < boundary.center }.count
        let rightCount = lines.count - leftCount
        guard leftCount >= minimumLinesPerColumn, rightCount >= minimumLinesPerColumn else {
            return nil
        }
        return boundary.center
    }

    private static func mergeHorizontalFragments(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        guard lines.count > 1 else { return lines }

        // インデックス管理用
        var used = Set<Int>()
        var result: [RecognizedLine] = []
        // 列境界を跨ぐ結合は別カラムのフィールド混合になるため禁止する
        let boundary = columnBoundary(for: lines)
        if let boundary {
            AppLogger.ocr.debug("列境界を検出: x=\(boundary, privacy: .public)")
        }

        // Y 座標降順（Vision座標系: 上が大きい → 名刺の上から処理）
        let indexed = lines.enumerated().sorted {
            $0.element.boundingBox.midY > $1.element.boundingBox.midY
        }

        for (i, anchor) in indexed {
            if used.contains(i) { continue }
            used.insert(i)

            // この行と同一行の断片を収集
            var group: [(index: Int, line: RecognizedLine)] = [(i, anchor)]
            let anchorH = anchor.boundingBox.height

            for (j, candidate) in indexed {
                if used.contains(j) { continue }
                let candH = candidate.boundingBox.height
                let maxH = max(anchorH, candH)

                // 同一行判定: Y 中心の差が行の高さの 60% 以内
                guard abs(candidate.boundingBox.midY - anchor.boundingBox.midY) < maxH * 0.6 else {
                    continue
                }

                // 列境界を跨ぐ候補は別カラムのフィールドとみなし結合しない
                if let boundary,
                   (anchor.boundingBox.midX < boundary) != (candidate.boundingBox.midX < boundary) {
                    continue
                }

                // X 近接判定: 既にグループに入っている行との間隔をチェック
                // グループ全体の左端〜右端を計算
                let groupMinX = group.map { $0.line.boundingBox.minX }.min()!
                let groupMaxX = group.map { $0.line.boundingBox.maxX }.max()!

                let candMinX = candidate.boundingBox.minX
                let candMaxX = candidate.boundingBox.maxX

                // 断片間のギャップ（正値＝離れている、負値＝重なっている）
                let gap: CGFloat
                if candMinX > groupMaxX {
                    gap = candMinX - groupMaxX
                } else if candMaxX < groupMinX {
                    gap = groupMinX - candMaxX
                } else {
                    gap = 0 // 重なっている
                }

                // ギャップが行の高さの 2 倍以内なら同一論理行とみなす
                // （名刺の名前は文字間を広げることがあるが、別フィールドはもっと離れる）
                if gap < maxH * 2.0 {
                    // 短い断片のみ統合（長い行同士は別フィールドの可能性が高い）
                    let anchorChars = anchor.text.trimmingCharacters(in: .whitespaces).count
                    let candChars = candidate.text.trimmingCharacters(in: .whitespaces).count
                    if anchorChars <= 4 || candChars <= 4 {
                        used.insert(j)
                        group.append((j, candidate))
                    }
                }
            }

            if group.count == 1 {
                result.append(anchor)
            } else {
                // X 座標順（左→右）にソートして結合
                let sorted = group.sorted { $0.line.boundingBox.midX < $1.line.boundingBox.midX }
                let mergedText = sorted.map { $0.line.text.trimmingCharacters(in: .whitespaces) }.joined()
                // 結合後の bounding box は全断片を包含する矩形
                let minX = sorted.map { $0.line.boundingBox.minX }.min()!
                let minY = sorted.map { $0.line.boundingBox.minY }.min()!
                let maxX = sorted.map { $0.line.boundingBox.maxX }.max()!
                let maxY = sorted.map { $0.line.boundingBox.maxY }.max()!
                let mergedBox = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                let avgConfidence = sorted.map { $0.line.confidence }.reduce(0, +) / Float(sorted.count)

                AppLogger.ocr.debug("行統合: \(sorted.map { "'\($0.line.text)'" }.joined(separator: " + "), privacy: .private) → \(mergedText, privacy: .private)")
                result.append(RecognizedLine(
                    text: mergedText,
                    boundingBox: mergedBox,
                    confidence: avgConfidence,
                    textDirection: dominantDirection(sorted.map { $0.line })
                ))
            }
        }

        // 元の Y 座標順（上から下 = Vision Y 降順）で返す
        return result.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
    }

    private static func mergeVerticalFragments(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        guard lines.count > 1 else { return lines }

        var used = Set<Int>()
        var result: [RecognizedLine] = []
        // 日本語縦書きの読み順: 右列から左列。同一列内は上から下。
        let indexed = lines.enumerated().sorted {
            if abs($0.element.boundingBox.midX - $1.element.boundingBox.midX) > 0.01 {
                return $0.element.boundingBox.midX > $1.element.boundingBox.midX
            }
            return $0.element.boundingBox.midY > $1.element.boundingBox.midY
        }

        for (i, anchor) in indexed {
            if used.contains(i) { continue }
            used.insert(i)

            var group: [(index: Int, line: RecognizedLine)] = [(i, anchor)]
            let anchorW = anchor.boundingBox.width

            for (j, candidate) in indexed {
                if used.contains(j) { continue }
                let candW = candidate.boundingBox.width
                let maxW = max(anchorW, candW)

                let groupMinX = group.map { $0.line.boundingBox.minX }.min()!
                let groupMaxX = group.map { $0.line.boundingBox.maxX }.max()!
                let groupMinY = group.map { $0.line.boundingBox.minY }.min()!
                let groupMaxY = group.map { $0.line.boundingBox.maxY }.max()!

                let xOverlap = min(groupMaxX, candidate.boundingBox.maxX) - max(groupMinX, candidate.boundingBox.minX)
                let sameColumn = abs(candidate.boundingBox.midX - anchor.boundingBox.midX) < maxW * 0.8
                    || xOverlap > min(maxW, candidate.boundingBox.width) * 0.35
                guard sameColumn else { continue }

                let gap: CGFloat
                if candidate.boundingBox.minY > groupMaxY {
                    gap = candidate.boundingBox.minY - groupMaxY
                } else if candidate.boundingBox.maxY < groupMinY {
                    gap = groupMinY - candidate.boundingBox.maxY
                } else {
                    gap = 0
                }

                if gap < maxW * 2.4 {
                    let anchorChars = anchor.text.trimmingCharacters(in: .whitespaces).count
                    let candChars = candidate.text.trimmingCharacters(in: .whitespaces).count
                    if anchorChars <= 6 || candChars <= 6 {
                        used.insert(j)
                        group.append((j, candidate))
                    }
                }
            }

            if group.count == 1 {
                result.append(anchor)
            } else {
                let sorted = group.sorted { $0.line.boundingBox.midY > $1.line.boundingBox.midY }
                let mergedText = sorted.map { $0.line.text.trimmingCharacters(in: .whitespaces) }.joined()
                let mergedBox = unionBoundingBox(sorted.map { $0.line })
                let avgConfidence = sorted.map { $0.line.confidence }.reduce(0, +) / Float(sorted.count)

                AppLogger.ocr.debug("縦書き行統合: \(sorted.map { "'\($0.line.text)'" }.joined(separator: " + "), privacy: .private) → \(mergedText, privacy: .private)")
                result.append(RecognizedLine(
                    text: mergedText,
                    boundingBox: mergedBox,
                    confidence: avgConfidence,
                    textDirection: .topToBottom
                ))
            }
        }

        return sortForReadingOrder(result, preferVertical: true)
    }

    private static func isVerticalMergeCandidate(_ line: RecognizedLine, allowsAspectFallback: Bool) -> Bool {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        guard !isContactLike(text), !isMostlyASCII(text) else { return false }
        let hasJapanese = text.unicodeScalars.contains {
            (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
        }
        guard hasJapanese else { return false }
        if line.textDirection == .topToBottom { return true }
        guard allowsAspectFallback else { return false }
        return line.boundingBox.height > line.boundingBox.width * 1.4
    }

    private static func isContactLike(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("@") || lower.contains("http") || lower.contains("www.") { return true }
        let digits = text.unicodeScalars.filter { (0x30...0x39).contains($0.value) }.count
        if digits >= 7 { return true }
        if text.range(of: #"^\+?[0-9][0-9\-()\s]{5,}$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func isMostlyASCII(_ text: String) -> Bool {
        let scalars = text.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard !scalars.isEmpty else { return false }
        let asciiCount = scalars.filter { $0.isASCII }.count
        return Double(asciiCount) / Double(scalars.count) >= 0.7
    }

    private static func unionBoundingBox(_ lines: [RecognizedLine]) -> CGRect {
        let minX = lines.map { $0.boundingBox.minX }.min() ?? 0
        let minY = lines.map { $0.boundingBox.minY }.min() ?? 0
        let maxX = lines.map { $0.boundingBox.maxX }.max() ?? 0
        let maxY = lines.map { $0.boundingBox.maxY }.max() ?? 0
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func dominantDirection(_ lines: [RecognizedLine]) -> RecognizedTextDirection {
        if lines.contains(where: { $0.textDirection == .topToBottom }) { return .topToBottom }
        if lines.contains(where: { $0.textDirection == .rightToLeft }) { return .rightToLeft }
        if lines.contains(where: { $0.textDirection == .leftToRight }) { return .leftToRight }
        return .unknown
    }

    private static func sortForReadingOrder(_ lines: [RecognizedLine], preferVertical: Bool) -> [RecognizedLine] {
        guard preferVertical else {
            return lines.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        }
        return lines.sorted {
            let maxW = max($0.boundingBox.width, $1.boundingBox.width)
            if abs($0.boundingBox.midX - $1.boundingBox.midX) > maxW * 0.6 {
                return $0.boundingBox.midX > $1.boundingBox.midX
            }
            return $0.boundingBox.midY > $1.boundingBox.midY
        }
    }

    enum OCRError: LocalizedError {
        case invalidImage

        var errorDescription: String? {
            switch self {
            case .invalidImage:
                return "画像の変換に失敗しました"
            }
        }
    }
}
