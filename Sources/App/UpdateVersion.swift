import Foundation

// Use the updater's numeric version rules for the saved release, including optional v and omitted zero parts.
func availableUpdate(_ stored: Any?, current: String) -> String? {
    let pattern = "^v?[0-9]+(\\.[0-9]+){0,2}$"
    guard let stored = stored as? String,
          stored.range(of: pattern, options: .regularExpression) != nil,
          current.range(of: pattern, options: .regularExpression) != nil else { return nil }
    let version = stored.hasPrefix("v") ? String(stored.dropFirst()) : stored
    let running = current.hasPrefix("v") ? String(current.dropFirst()) : current
    let left = version.split(separator: ".").map(String.init)
    let right = running.split(separator: ".").map(String.init)
    for index in 0..<3 {
        let result = (index < left.count ? left[index] : "0").compare(index < right.count ? right[index] : "0", options: .numeric)
        if result != .orderedSame { return result == .orderedDescending ? version : nil }
    }
    return nil
}
