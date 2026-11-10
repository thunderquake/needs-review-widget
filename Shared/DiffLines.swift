import Foundation

/// The lines of a file's new version that a review comment can attach to:
/// the added and context lines of its patch, keyed by line number.
enum DiffLines {
    static func parse(patch: String) -> [Int: String] {
        var lines: [Int: String] = [:]
        var newLine = 0

        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix("@@") {
                // @@ -old,count +new,count @@
                guard let plus = raw.split(separator: " ").first(where: { $0.hasPrefix("+") }),
                      let start = Int(plus.dropFirst().split(separator: ",").first ?? "") else { continue }
                newLine = start
            } else if raw.hasPrefix("+") || raw.hasPrefix(" ") {
                lines[newLine] = String(raw)
                newLine += 1
            }
            // "-" lines and "\ No newline at end of file" do not exist on the new side.
        }
        return lines
    }
}
