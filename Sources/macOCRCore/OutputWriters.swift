import Foundation

/// Writes a dictionary to disk as JSON with deterministic key ordering.
/// - Parameters:
///   - object: The dictionary to serialize.
///   - finalOutputPath: Destination path for the JSON file.
func writeJSONObjectOrdered(_ object: [String: Any], to finalOutputPath: String) throws {
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

/// Writes OCR output as plain text, preferring paragraph transcripts when available.
/// - Parameters:
///   - object: The OCR result structure, which can represent a single image, a PDF, or batch output.
///   - finalOutputPath: Destination path for the text file.
func writeTextOutput(_ object: [String: Any], to finalOutputPath: String) throws {
    var textLines: [String] = []

    if let batchData = object as? [String: [String: Any]] {
        let sortedKeys = batchData.keys.sorted { lhs, rhs in
            lhs.localizedStandardCompare(rhs) == .orderedAscending
        }

        for filename in sortedKeys {
            guard let fileData = batchData[filename] else { continue }

            if !textLines.isEmpty {
                textLines.append("")
            }
            textLines.append("=== \(filename) ===")

            if let paragraphs = fileData["paragraphs"] as? [[String: Any]], !paragraphs.isEmpty {
                for paragraph in paragraphs {
                    if let text = paragraph["text"] as? String {
                        textLines.append(text)
                    }
                }
            } else if let observations = fileData["observations"] as? [[String: Any]] {
                for observation in observations {
                    if let text = observation["text"] as? String {
                        textLines.append(text)
                    }
                }
            }
        }
    } else if let pages = object["pages"] as? [[String: Any]] {
        for page in pages.sorted(by: { (lhs, rhs) -> Bool in
            let left = lhs["page"] as? Int ?? 0
            let right = rhs["page"] as? Int ?? 0
            return left < right
        }) {
            if let pageNumber = page["page"] as? Int {
                textLines.append("--- Page \(pageNumber) ---")
            }

            if let paragraphs = page["paragraphs"] as? [[String: Any]], !paragraphs.isEmpty {
                for paragraph in paragraphs {
                    if let text = paragraph["text"] as? String {
                        textLines.append(text)
                    }
                }
            } else if let observations = page["observations"] as? [[String: Any]] {
                for observation in observations {
                    if let text = observation["text"] as? String {
                        textLines.append(text)
                    }
                }
            }

            textLines.append("")
        }
    } else {
        if let paragraphs = object["paragraphs"] as? [[String: Any]], !paragraphs.isEmpty {
            for paragraph in paragraphs {
                if let text = paragraph["text"] as? String {
                    textLines.append(text)
                }
            }
        } else if let observations = object["observations"] as? [[String: Any]] {
            for observation in observations {
                if let text = observation["text"] as? String {
                    textLines.append(text)
                }
            }
        }
    }

    let output = textLines.joined(separator: "\n")
    try output.write(toFile: finalOutputPath, atomically: true, encoding: .utf8)
}
