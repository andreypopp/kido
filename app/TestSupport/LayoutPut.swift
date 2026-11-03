import Foundation

// The ko arguments that replace the server's layout with `document`, which they read from a file in `dir`.
func layoutPut(_ document: String, dir: String) throws -> [String] {
    let draft = dir + "/draft.json"
    try document.write(toFile: draft, atomically: true, encoding: .utf8)
    return ["api", "-X", "PUT", "--input", draft, "/layout"]
}
