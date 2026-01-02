import Foundation

/// Writes a dictionary to disk as JSON with deterministic key ordering.
/// - Parameters:
///   - object: The dictionary to serialize.
///   - finalOutputPath: Destination path for the JSON file.
public func writeJSONObjectOrdered(_ object: [String: Any], to finalOutputPath: String) throws {
    let keys = object.keys.sorted { lhs, rhs in
        if let leftInt = Int(lhs), let rightInt = Int(rhs) {
            return leftInt < rightInt
        }
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    let ordered = NSMutableDictionary()
    for key in keys {
        ordered[key] = object[key]
    }

    let jsonData = try JSONSerialization.data(withJSONObject: ordered, options: [.prettyPrinted])
    try jsonData.write(to: URL(fileURLWithPath: finalOutputPath))
}

/// Resolves the final output path based on user input and defaults.
/// - Parameters:
///   - userOutputPath: The optional output path provided by the user.
///   - defaultDirectory: The default directory to use if no output path is provided.
///   - defaultFilename: The default filename to use.
/// - Returns: The resolved absolute output path.
public func resolveOutputPath(userOutputPath: String?, defaultDirectory: String, defaultFilename: String) -> String {
    if let userPath = userOutputPath {
        let lower = userPath.lowercased()
        if lower.hasSuffix(".json") || lower.hasSuffix(".txt") {
            return userPath
        }
        return (userPath as NSString).appendingPathComponent(defaultFilename)
    }
    return (defaultDirectory as NSString).appendingPathComponent(defaultFilename)
}

/// Writes OCR output as plain text, preferring paragraph transcripts when available.
/// - Parameters:
///   - object: The OCR result structure (single image, PDF, or batch output).
///   - finalOutputPath: Destination path for the text file.
public func writeTextOutput(_ object: [String: Any], to finalOutputPath: String) throws {
    var textLines: [String] = []

    // Batch processing output (dictionary of filenames to results)
    if let batchData = object as? [String: [String: Any]] {
        let sortedKeys = batchData.keys.sorted { lhs, rhs in
            lhs.localizedStandardCompare(rhs) == .orderedAscending
        }

        for filename in sortedKeys {
            guard let fileData = batchData[filename] else { continue }

            if !textLines.isEmpty {
                textLines.append("") // Blank line between files
            }
            textLines.append("=== \(filename) ===")

            appendTextFromResult(fileData, to: &textLines)
        }
    }
    // PDF output (pages array)
    else if let pages = object["pages"] as? [[String: Any]] {
        for page in pages.sorted(by: { (lhs, rhs) -> Bool in
            let left = lhs["page"] as? Int ?? 0
            let right = rhs["page"] as? Int ?? 0
            return left < right
        }) {
            if let pageNumber = page["page"] as? Int {
                if !textLines.isEmpty {
                    textLines.append("") // Blank line between pages
                }
                textLines.append("--- Page \(pageNumber) ---")
            }

            appendTextFromResult(page, to: &textLines)
        }
    }
    // Single image output
    else {
        appendTextFromResult(object, to: &textLines)
    }

    let output = textLines.joined(separator: "\n")
    try output.write(toFile: finalOutputPath, atomically: true, encoding: .utf8)
}

/// Helper to extract text from result dictionary, preferring paragraphs over observations
private func appendTextFromResult(_ result: [String: Any], to textLines: inout [String]) {
    // Prefer paragraphs if available
    if let paragraphs = result["paragraphs"] as? [[String: Any]], !paragraphs.isEmpty {
        for paragraph in paragraphs {
            if let text = paragraph["text"] as? String {
                textLines.append(text)
            }
        }
    }
    // Fall back to observations
    else if let observations = result["observations"] as? [[String: Any]] {
        for observation in observations {
            if let text = observation["text"] as? String {
                textLines.append(text)
            }
        }
    }
}
