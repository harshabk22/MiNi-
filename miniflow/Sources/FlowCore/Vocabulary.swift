import Foundation
import SQLite3

/// Words the speech model should expect: your own list + names from Mini's memory. Helps with names like "Rahul".
public enum Vocabulary {
    public static let home = FileManager.default.homeDirectoryForCurrentUser
    public static let folder: URL = {
        let f = home.appendingPathComponent("Library/Application Support/MiniFlow")
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }()
    public static let userFile = folder.appendingPathComponent("vocabulary.txt")
    /// Where Mini (the assistant) keeps its memory — set by install.sh (`defaults write local.miniflow.dictation
    /// miniDataPath …`). Optional: Mini Flow works without Mini.
    static var miniMemory: URL {
        let path = UserDefaults.standard.string(forKey: "miniDataPath")
            ?? home.appendingPathComponent("Documents/Mini/assistant/data").path
        return URL(fileURLWithPath: path).appendingPathComponent("memory.db")
    }

    public static func ensureUserFile() {
        guard !FileManager.default.fileExists(atPath: userFile.path) else { return }
        let starter = """
        # Mini Flow vocabulary — one word or name per line. Helps the speech model spell these right.
        # Lines starting with # are ignored.
        Mini
        """
        try? starter.write(to: userFile, atomically: true, encoding: .utf8)
    }

    public static func load() -> [String] {
        var words: [String] = []
        if let text = try? String(contentsOf: userFile, encoding: .utf8) {
            words += text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        words += namesFromMiniMemory()
        var seen = Set<String>()
        return words.filter { seen.insert($0.lowercased()).inserted }.prefix(100).map { $0 }
    }

    /// Capitalised words from Mini's memories ("User name: Alex" -> "Alex"). Read-only.
    static func namesFromMiniMemory() -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(miniMemory.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT fact FROM memories", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let skip: Set<String> = ["User", "The", "I", "My", "Name", "Mini", "Python", "JavaScript"]
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0) else { continue }
            let fact = String(cString: c)
            for w in fact.split(whereSeparator: { !$0.isLetter && $0 != "-" }) where w.first?.isUppercase == true && w.count > 2 {
                let s = String(w)
                if !skip.contains(s) { out.append(s) }
            }
        }
        return out
    }
}
