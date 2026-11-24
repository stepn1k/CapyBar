import Foundation

/// Filters the panel by what the user types: case, accents and width are ignored, and
/// better matches come first.
public enum PanelSearch {

    /// Indices into `titles` that match `query`, best first; ties keep the panel's order.
    /// An empty query matches everything in order.
    ///
    /// Ranking: the title starts with the query, then a word starts with it, then the
    /// initials do ("im" for "iStat Menus"), then it appears anywhere. A query of several
    /// words matches a title that contains every one of them.
    public static func matches(_ query: String, in titles: [String]) -> [Int] {
        let needle = normalize(query)
        guard !needle.isEmpty else { return Array(titles.indices) }
        let tokens = needle.split(separator: " ").map(String.init)
        let scored = titles.enumerated().compactMap { index, title -> (score: Int, index: Int)? in
            score(normalize(title), needle: needle, tokens: tokens).map { ($0, index) }
        }
        return scored.sorted { ($0.score, $0.index) < ($1.score, $1.index) }.map(\.index)
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func score(_ title: String, needle: String, tokens: [String]) -> Int? {
        if title.hasPrefix(needle) { return 0 }
        let words = title.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if tokens.count == 1, words.contains(where: { $0.hasPrefix(needle) }) { return 1 }
        if tokens.count == 1, String(words.compactMap(\.first)).hasPrefix(needle), needle.count > 1 { return 2 }
        if tokens.allSatisfy({ title.contains($0) }) { return 3 }
        return nil
    }
}
