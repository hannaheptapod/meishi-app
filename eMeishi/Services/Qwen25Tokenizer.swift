import Foundation

/// Qwen2.5 BPEトークナイザー
/// HuggingFace の tokenizer.json（BPE形式）から語彙とマージルールを読み込み、
/// テキスト ↔ トークンID の変換を行う。
final class Qwen25Tokenizer {

    // MARK: - 特殊トークンID

    enum SpecialToken {
        static let imStart = 151644  // <|im_start|>
        static let imEnd   = 151645  // <|im_end|>
        static let eot     = 151643  // <|endoftext|>
    }

    // MARK: - 内部テーブル

    private let vocab:       [String: Int]    // Unicodeシンボル列 → tokenID
    private let decoder:     [Int: String]    // tokenID → Unicodeシンボル列
    private let bpeRanks:    [BPEPair: Int]   // マージペア → 優先度（小さいほど優先）
    private let byteEncoder: [UInt8: String]  // byte → Unicodeシンボル1文字
    private let byteDecoder: [String: UInt8]  // Unicodeシンボル1文字 → byte

    // 特殊トークン文字列 → ID（エンコード時に先に処理する）
    private static let specialTokenMap: [(String, Int)] = [
        ("<|im_start|>",   SpecialToken.imStart),
        ("<|im_end|>",     SpecialToken.imEnd),
        ("<|endoftext|>",  SpecialToken.eot),
    ]

    // MARK: - 初期化

    init(url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            print("[Tokenizer] ファイル読み込み失敗: \(url.path) - \(error)")
            throw Err.invalidFormat
        }
        print("[Tokenizer] ファイル読み込み完了: \(data.count) bytes from \(url.lastPathComponent)")

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? "non-utf8"
            print("[Tokenizer] JSONパース失敗。先頭200B: \(preview)")
            throw Err.invalidFormat
        }
        print("[Tokenizer] ルートキー: \(Array(root.keys).sorted())")

        guard let model = root["model"] as? [String: Any] else {
            print("[Tokenizer] 'model'キーが見つからない")
            throw Err.invalidFormat
        }
        print("[Tokenizer] modelキー: \(Array(model.keys).sorted())")

        // vocab: [String: Int] — NSNumber→Int ブリッジ失敗に備えて手動変換も試みる
        let rawVocab: [String: Int]
        if let v = model["vocab"] as? [String: Int] {
            rawVocab = v
        } else if let v = model["vocab"] as? [String: NSNumber] {
            print("[Tokenizer] vocab を NSNumber→Int で変換")
            rawVocab = v.mapValues { $0.intValue }
        } else {
            if let v = model["vocab"] {
                print("[Tokenizer] vocab の型が不正: \(type(of: v))")
            } else {
                print("[Tokenizer] vocab キーが存在しない")
            }
            throw Err.invalidFormat
        }
        print("[Tokenizer] vocab エントリ数: \(rawVocab.count)")

        // merges: 2つの形式に対応
        //   形式A（Qwen2.5）: ["tok1 tok2", ...] — スペース区切り文字列の配列
        //   形式B（Qwen3）:   [["tok1", "tok2"], ...] — 2要素配列の配列
        let rawMerges: [String]
        if let m = model["merges"] as? [String] {
            rawMerges = m
            print("[Tokenizer] merges 形式A (文字列配列): \(m.count)件")
        } else if let m = model["merges"] as? [[String]] {
            rawMerges = m.compactMap { pair in
                pair.count == 2 ? "\(pair[0]) \(pair[1])" : nil
            }
            print("[Tokenizer] merges 形式B (配列の配列→変換): \(rawMerges.count)件")
        } else {
            if let m = model["merges"] {
                print("[Tokenizer] merges の型が不正: \(type(of: m))")
            } else {
                print("[Tokenizer] merges キーが存在しない")
            }
            throw Err.invalidFormat
        }

        // added_tokens（特殊トークン）を vocab に追加
        var v = rawVocab
        if let added = root["added_tokens"] as? [[String: Any]] {
            for tok in added {
                if let content = tok["content"] as? String, let id = tok["id"] as? Int {
                    v[content] = id
                }
            }
        }
        vocab   = v
        decoder = Dictionary(uniqueKeysWithValues: v.map { ($1, $0) })

        // BPE マージルールを優先度付きで保存
        var ranks = [BPEPair: Int]()
        ranks.reserveCapacity(rawMerges.count)
        for (i, merge) in rawMerges.enumerated() {
            // "tokenA tokenB" 形式をスペースで分割
            if let spaceIdx = merge.firstIndex(of: " ") {
                let right = merge.index(after: spaceIdx)
                if right < merge.endIndex {
                    ranks[BPEPair(String(merge[..<spaceIdx]),
                                  String(merge[right...]))] = i
                }
            }
        }
        bpeRanks = ranks

        // GPT-2方式 bytes_to_unicode 対応表
        let (enc, dec) = Self.buildByteMapping()
        byteEncoder = enc
        byteDecoder = dec
    }

    // MARK: - エンコード（特殊トークン対応）

    /// テキストをトークンIDの配列に変換する。
    /// <|im_start|> などの特殊トークンも正しく処理する。
    func encode(_ text: String) -> [Int] {
        var result = [Int]()
        var remaining = text

        while !remaining.isEmpty {
            // 先頭が特殊トークンかチェック
            var matched = false
            for (tok, id) in Self.specialTokenMap {
                if remaining.hasPrefix(tok) {
                    result.append(id)
                    remaining = String(remaining.dropFirst(tok.count))
                    matched = true
                    break
                }
            }
            if matched { continue }

            // 次の特殊トークンが出現するまでの部分を BPE エンコード
            var cutIdx = remaining.endIndex
            for (tok, _) in Self.specialTokenMap {
                if let r = remaining.range(of: tok), r.lowerBound < cutIdx {
                    cutIdx = r.lowerBound
                }
            }
            let chunk = String(remaining[..<cutIdx])
            remaining  = String(remaining[cutIdx...])
            if !chunk.isEmpty {
                result.append(contentsOf: encodePlain(chunk))
            }
        }
        return result
    }

    // MARK: - デコード

    /// トークンIDの配列をテキストに変換する。
    func decode(_ ids: [Int]) -> String {
        var bytes = [UInt8]()
        for id in ids {
            guard let token = decoder[id] else { continue }
            // <|...|> 形式の特殊トークンはスキップ
            if token.hasPrefix("<|") && token.hasSuffix("|>") { continue }
            for scalar in token.unicodeScalars {
                let key = String(scalar)
                if let b = byteDecoder[key] { bytes.append(b) }
            }
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    // MARK: - Private: 通常テキストのエンコード

    private func encodePlain(_ text: String) -> [Int] {
        preTokenize(text).flatMap { encodeSingle($0) }
    }

    /// GPT-2スタイルの正規表現でプレトークナイズ
    private func preTokenize(_ text: String) -> [String] {
        // 収縮形 / 文字 / 数字 / 空白付き非文字 / 改行 / 空白 の順に分割
        let pattern = "(?i:'s|'t|'re|'ve|'m|'ll|'d)"
            + "|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+"
            + "|\\p{N}+"
            + "| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*"
            + "|\\s*[\\r\\n]+"
            + "|\\s+(?!\\S)"
            + "|\\s+"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [text] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    /// 単一プレトークンを BPE でエンコードしてトークンIDを返す
    private func encodeSingle(_ text: String) -> [Int] {
        // 1. UTF-8バイト列 → Unicodeシンボル列（byteEncoder 経由）
        let bytes = Array(text.utf8)
        var symbols = bytes.map { byteEncoder[$0] ?? String(format: "<0x%02X>", $0) }

        if symbols.count == 1 {
            return [vocab[symbols[0]] ?? 0]
        }

        // 2. BPE マージ適用
        symbols = applyBPE(symbols)

        // 3. Unicodeシンボル列 → tokenID
        return symbols.compactMap { vocab[$0] }
    }

    /// BPE マージアルゴリズム
    /// 最もランクの低い（優先度が高い）ペアを繰り返しマージする
    private func applyBPE(_ tokens: [String]) -> [String] {
        var t = tokens
        while t.count > 1 {
            // 全隣接ペアの中で最小ランクを探す
            var bestRank = Int.max
            var bestIdx  = -1
            for i in 0 ..< (t.count - 1) {
                let rank = bpeRanks[BPEPair(t[i], t[i + 1])] ?? Int.max
                if rank < bestRank {
                    bestRank = rank
                    bestIdx  = i
                }
            }
            guard bestIdx >= 0, bestRank < Int.max else { break }

            // マージ実行
            var next = [String]()
            next.reserveCapacity(t.count - 1)
            var i = 0
            while i < t.count {
                if i == bestIdx {
                    next.append(t[i] + t[i + 1])
                    i += 2
                } else {
                    next.append(t[i])
                    i += 1
                }
            }
            t = next
        }
        return t
    }

    // MARK: - GPT-2 bytes_to_unicode 対応表

    static func buildByteMapping() -> ([UInt8: String], [String: UInt8]) {
        // 印字可能な ASCII 範囲と Latin-1 補足の一部はコードポイントそのまま
        var bs = (33...126).map { UInt8($0) }
        bs += (161...172).map { UInt8($0) }
        bs += (174...255).map { UInt8($0) }

        var cs = bs.map { UInt32($0) }
        var n: UInt32 = 0
        // 上記以外のバイト（0x00〜0x20、0x7F〜0xA0、0xAD）は
        // U+0100 以降の連番に割り当て（GPT-2方式）
        for b: UInt8 in 0...255 where !bs.contains(b) {
            bs.append(b)
            cs.append(256 + n)
            n += 1
        }

        var enc = [UInt8: String]()
        var dec = [String: UInt8]()
        for (b, cp) in zip(bs, cs) {
            if let scalar = Unicode.Scalar(cp) {
                let s = String(scalar)
                enc[b] = s
                dec[s] = b
            }
        }
        return (enc, dec)
    }

    // MARK: - エラー型
    enum Err: Error { case invalidFormat }
}

// MARK: - BPE ペア（Hashable キー）

struct BPEPair: Hashable, Sendable {
    let first: String
    let second: String
    init(_ first: String, _ second: String) {
        self.first  = first
        self.second = second
    }
}
