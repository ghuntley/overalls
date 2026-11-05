import Foundation

/// Validates the lowercase DNS host grammar shared by native Apple boundaries.
///
/// A host may be a single label (for example, `localhost` in a fixture), but
/// every label is bounded and uses only lowercase ASCII letters, digits and
/// hyphens. This matches the Rust hostname grammar and rejects ambiguous
/// Unicode, uppercase and underscore forms before they reach transport code.
public enum MilaHostValidation {
    public static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard !label.isEmpty, label.utf8.count <= 63,
                  label.utf8.first != 45, label.utf8.last != 45 else {
                return false
            }
            return label.utf8.allSatisfy { byte in
                (byte >= 97 && byte <= 122) ||
                    (byte >= 48 && byte <= 57) ||
                    byte == 45
            }
        }
    }
}
