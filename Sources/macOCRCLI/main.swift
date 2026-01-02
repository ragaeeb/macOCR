import Foundation
import macOCRCore

let VERSION = "1.3.0"

#if canImport(Vision) && canImport(Cocoa) && canImport(PDFKit)
import Vision
import Cocoa
import PDFKit
import Dispatch

// MARK: - Async Helper

nonisolated func runAsyncAndBlock<T: Sendable>(_ operation: @Sendable @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, Error>?

    Task {
        do {
            let value = try await operation()
            result = .success(value)
        } catch {
            result = .failure(error)
        }
        semaphore.signal()
    }

    semaphore.wait()

    if let outcome = result {
        return try outcome.get()
    }

    throw NSError(domain: "macOCR", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown async execution failure"])
}

// MARK: - Language Support

func printSupportedLanguages() {
    let request = VNRecognizeTextRequest()
    request.revision = VNRecognizeTextRequestRevision3
    request.recognitionLevel = .accurate
    let langs = (try? request.supportedRecognitionLanguages()) ?? []

    if let data = try? JSONSerialization.data(withJSONObject: langs, options: []),
       let langsJson = String(data: data, encoding: .utf8) {
        print("Supported recognition languages:")
        print(langsJson)
    } else {
        print("Error: Could not retrieve supported languages")
    }
}

// MARK: - Standard OCR (observations)

func performOCR(cgImage: CGImage, languages: [String], confidenceThreshold: Float) -> [String: Any]? {
    let imageWidth = CGFloat(cgImage.width)
    let imageHeight = CGFloat(cgImage.height)

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.revision = VNRecognizeTextRequestRevision3
    request.recognitionLanguages = languages

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

    do {
        try handler.perform([request])
    } catch {
        fputs("OCR execution failed for image: \(error.localizedDescription)\n", stderr)
        return nil
    }

    guard let results = request.results else {
        fputs("No text results for image.\n", stderr)
        return nil
    }

    var observations: [[String: Any]] = []

    for observation in results {
        guard let candidate = observation.topCandidates(1).first else { continue }

        let range = candidate.string.startIndex..<candidate.string.endIndex
        let box = (try? candidate.boundingBox(for: range)?.boundingBox) ?? observation.boundingBox

        let absBox = VNImageRectForNormalizedRect(box, Int(imageWidth), Int(imageHeight))
        let flippedY = imageHeight - absBox.origin.y - absBox.size.height

        var entry: [String: Any] = [
            "text": candidate.string,
            "bbox": [
                "x": round3(absBox.origin.x),
                "y": round3(flippedY),
                "width": round3(absBox.size.width),
                "height": round3(absBox.size.height)
            ]
        ]
        
        // Include confidence when below threshold (and threshold > 0)
        if confidenceThreshold > 0 && candidate.confidence < confidenceThreshold {
            entry["confidence"] = round3(Double(candidate.confidence))
        }
        
        observations.append(entry)
    }

    return [
        "width": Int(imageWidth),
        "height": Int(imageHeight),
        "observations": observations
    ]
}

func performOCR(on imagePath: String, languages: [String], confidenceThreshold: Float) -> [String: Any]? {
    guard let img = NSImage(byReferencingFile: imagePath),
          let imgRef = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fputs("Error: failed to load or convert image '\(imagePath)'\n", stderr)
        return nil
    }

    return performOCR(cgImage: imgRef, languages: languages, confidenceThreshold: confidenceThreshold)
}

// MARK: - Document OCR with Paragraph Grouping (macOS 26+)

@available(macOS 26.0, *)
struct DocumentOCR {
    static func perform(cgImage: CGImage, languages: [String], confidenceThreshold: Float) -> [String: Any]? {
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let imageData = bitmap.representation(using: .png, properties: [:]) else {
            fputs("Document paragraph extraction failed: unable to generate image data.\n", stderr)
            return nil
        }

        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)

        // Build request configuration - must be let for Sendable closure capture
        let request: RecognizeDocumentsRequest = {
            var req = RecognizeDocumentsRequest()
            req.textRecognitionOptions.recognitionLanguages = languages.compactMap { Locale.Language(identifier: $0) }
            req.textRecognitionOptions.useLanguageCorrection = false
            req.textRecognitionOptions.automaticallyDetectLanguage = languages.isEmpty
            return req
        }()

        let observations: [DocumentObservation]
        do {
            observations = try runAsyncAndBlock {
                try await request.perform(on: imageData)
            }
        } catch {
            fputs("Document paragraph extraction failed: \(error.localizedDescription)\n", stderr)
            return nil
        }

        var paragraphs: [[String: Any]] = []

        for observation in observations {
            for paragraph in observation.document.paragraphs {
                let normalizedRect = paragraph.boundingRegion.boundingBox
                let cgRect = CGRect(x: CGFloat(normalizedRect.origin.x), y: CGFloat(normalizedRect.origin.y),
                                    width: CGFloat(normalizedRect.width), height: CGFloat(normalizedRect.height))
                let rect = VNImageRectForNormalizedRect(cgRect, Int(imageWidth), Int(imageHeight))
                let flippedY = imageHeight - rect.origin.y - rect.size.height

                var paragraphEntry: [String: Any] = [
                    "text": paragraph.transcript,
                    "bbox": [
                        "x": round3(rect.origin.x),
                        "y": round3(flippedY),
                        "width": round3(rect.size.width),
                        "height": round3(rect.size.height)
                    ]
                ]

                var lines: [[String: Any]] = []
                for line in paragraph.lines {
                    let lineNormRect = line.boundingRegion.boundingBox
                    let lineCgRect = CGRect(x: CGFloat(lineNormRect.origin.x), y: CGFloat(lineNormRect.origin.y),
                                            width: CGFloat(lineNormRect.width), height: CGFloat(lineNormRect.height))
                    let absLineRect = VNImageRectForNormalizedRect(lineCgRect, Int(imageWidth), Int(imageHeight))
                    let lineFlippedY = imageHeight - absLineRect.origin.y - absLineRect.size.height
                    
                    var lineEntry: [String: Any] = [
                        "text": line.transcript,
                        "bbox": [
                            "x": round3(absLineRect.origin.x),
                            "y": round3(lineFlippedY),
                            "width": round3(absLineRect.size.width),
                            "height": round3(absLineRect.size.height)
                        ]
                    ]
                    
                    if line.isTitle {
                        lineEntry["isTitle"] = true
                    }
                    
                    // Include confidence when below threshold (and threshold > 0)
                    // Assuming 'confidence' property exists on the line object similar to VNRecognizedText
                    if confidenceThreshold > 0 && line.confidence < confidenceThreshold {
                        lineEntry["confidence"] = round3(Double(line.confidence))
                    }
                    
                    lines.append(lineEntry)
                }
                
                if !lines.isEmpty {
                    paragraphEntry["lines"] = lines
                }

                paragraphs.append(paragraphEntry)
            }
        }

        return [
            "width": Int(imageWidth),
            "height": Int(imageHeight),
            "paragraphs": paragraphs
        ]
    }

    static func perform(on imagePath: String, languages: [String], confidenceThreshold: Float) -> [String: Any]? {
        guard let img = NSImage(byReferencingFile: imagePath),
              let imgRef = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            fputs("Error: failed to load or convert image '\(imagePath)'\n", stderr)
            return nil
        }

        return perform(cgImage: imgRef, languages: languages, confidenceThreshold: confidenceThreshold)
    }
}

// MARK: - OCR Wrappers with Version Handling

func performOCRWithSettings(on imagePath: String, languages: [String], group: Bool, threshold: Float) -> [String: Any]? {
    if group {
        if #available(macOS 26.0, *) {
            return DocumentOCR.perform(on: imagePath, languages: languages, confidenceThreshold: threshold)
        } else {
            fputs("Warning: --group requires macOS 26.0+. Falling back to standard OCR.\n", stderr)
        }
    }
    return performOCR(on: imagePath, languages: languages, confidenceThreshold: threshold)
}

func performOCRWithSettings(cgImage: CGImage, languages: [String], group: Bool, threshold: Float) -> [String: Any]? {
    if group {
        if #available(macOS 26.0, *) {
            return DocumentOCR.perform(cgImage: cgImage, languages: languages, confidenceThreshold: threshold)
        } else {
            fputs("Warning: --group requires macOS 26.0+. Falling back to standard OCR.\n", stderr)
        }
    }
    return performOCR(cgImage: cgImage, languages: languages, confidenceThreshold: threshold)
}

// MARK: - Main CLI Logic

func runCLI(args: [String]) -> Int32 {
    guard let options = parseCommandLineArguments(args) else {
        return 1
    }

    if options.showHelp {
        printUsage()
        return 0
    }

    if options.showVersion {
        printVersion(VERSION)
        return 0
    }

    if options.showSupportedLanguages {
        printSupportedLanguages()
        return 0
    }

    let fileManager = FileManager.default

    guard !options.inputPath.isEmpty else {
        fputs("Error: No input path provided\n", stderr)
        printUsage()
        return 1
    }

    let inputPath = options.inputPath
    let outputPath = options.outputPath
    let languages = options.languages
    let pageRange = options.pageRange
    let groupParagraphs = options.groupParagraphs
    let confidenceThreshold = options.confidenceThreshold

    var isDir: ObjCBool = false
    guard fileManager.fileExists(atPath: inputPath, isDirectory: &isDir) else {
        fputs("Error: Input path does not exist: \(inputPath)\n", stderr)
        return 1
    }

    if isDir.boolValue {
        // Directory batch processing
        guard let files = try? fileManager.contentsOfDirectory(atPath: inputPath) else {
            fputs("Error reading directory: \(inputPath)\n", stderr)
            return 1
        }

        let imageFiles = files.filter {
            let lc = $0.lowercased()
            return lc.hasSuffix(".jpg") || lc.hasSuffix(".jpeg") || lc.hasSuffix(".png")
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        var results: [String: [String: Any]] = [:]
        for file in imageFiles {
            let fullPath = (inputPath as NSString).appendingPathComponent(file)
            let ocrResult = performOCRWithSettings(on: fullPath, languages: languages, group: groupParagraphs, threshold: confidenceThreshold)
            
            if let result = ocrResult {
                results[file] = result
            }
        }

        guard !results.isEmpty else {
            fputs("Error: No images processed in directory.\n", stderr)
            return 1
        }

        let finalOutputPath: String
        if let out = outputPath {
            if out.lowercased().hasSuffix(".json") || out.lowercased().hasSuffix(".txt") {
                finalOutputPath = out
            } else {
                finalOutputPath = (out as NSString).appendingPathComponent("batch_output.json")
            }
        } else {
            finalOutputPath = (inputPath as NSString).appendingPathComponent("batch_output.json")
        }

        do {
            if finalOutputPath.lowercased().hasSuffix(".txt") {
                try writeTextOutput(results, to: finalOutputPath)
                print("✅ Batch OCR text written to \(finalOutputPath)")
            } else {
                try writeJSONObjectOrdered(results, to: finalOutputPath)
                print("✅ Batch OCR data written to \(finalOutputPath)")
            }
        } catch {
            fputs("Error writing batch output: \(error.localizedDescription)\n", stderr)
            return 1
        }
    } else {
        // Single file processing
        let inputURL = URL(fileURLWithPath: inputPath)
        let pathExt = inputURL.pathExtension.lowercased()
        
        if pathExt == "pdf" {
            guard let pdf = PDFDocument(url: inputURL) else {
                fputs("Error opening PDF: \(inputPath)\n", stderr)
                return 1
            }

            var pagesArray: [[String: Any]] = []
            let pageCount = pdf.pageCount

            var dpiX: NSDecimalNumber = .zero
            var dpiY: NSDecimalNumber = .zero

            let startPage = pageRange?.lowerBound ?? 1
            let endPage = min(pageRange?.upperBound ?? pageCount, pageCount)
            
            for index in (startPage-1)...(endPage-1) {
                let modeText = groupParagraphs ? " (with paragraph grouping)" : ""
                print("Processing page \(index + 1) of \(pageCount)\(modeText)...")
                
                guard let page = pdf.page(at: index) else { continue }
                let pageBounds = page.bounds(for: .cropBox)
                let effectiveBounds = pageBounds.isEmpty ? page.bounds(for: .mediaBox) : pageBounds

                let scale: CGFloat = 2.0
                let renderSize = CGSize(
                    width: max(1, effectiveBounds.width * scale),
                    height: max(1, effectiveBounds.height * scale)
                )
                let thumb = page.thumbnail(of: renderSize, for: .cropBox)
                guard let cgImg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    fputs("Failed to render page \(index + 1) of PDF.\n", stderr)
                    continue
                }

                if index == (startPage-1) {
                    let rawDpiX = Double(cgImg.width) / (Double(effectiveBounds.width) / 72.0)
                    let rawDpiY = Double(cgImg.height) / (Double(effectiveBounds.height) / 72.0)
                    dpiX = round3(rawDpiX)
                    dpiY = round3(rawDpiY)
                }

                let ocrResult = performOCRWithSettings(cgImage: cgImg, languages: languages, group: groupParagraphs, threshold: confidenceThreshold)
                
                if var pageDict = ocrResult {
                    pageDict["page"] = index + 1
                    pagesArray.append(pageDict)
                }
            }

            let pdfOutput: [String: Any] = [
                "pages": pagesArray,
                "dpi": ["x": dpiX, "y": dpiY]
            ]

            let finalOutputPath: String
            if let out = outputPath {
                if out.lowercased().hasSuffix(".json") || out.lowercased().hasSuffix(".txt") {
                    finalOutputPath = out
                } else {
                    finalOutputPath = (out as NSString).appendingPathComponent(inputURL.deletingPathExtension().lastPathComponent + "_pdf_output.json")
                }
            } else {
                finalOutputPath = inputURL.deletingPathExtension().path + "_pdf_output.json"
            }

            do {
                if finalOutputPath.lowercased().hasSuffix(".txt") {
                    try writeTextOutput(pdfOutput, to: finalOutputPath)
                    print("✅ PDF OCR text written to \(finalOutputPath)")
                } else {
                    let jsonData = try JSONSerialization.data(withJSONObject: pdfOutput, options: [.prettyPrinted])
                    try jsonData.write(to: URL(fileURLWithPath: finalOutputPath))
                    print("✅ PDF OCR data written to \(finalOutputPath)")
                }
            } catch {
                fputs("Error writing PDF output: \(error.localizedDescription)\n", stderr)
                return 1
            }
        } else {
            // Single image
            let ocrResult = performOCRWithSettings(on: inputPath, languages: languages, group: groupParagraphs, threshold: confidenceThreshold)
            
            guard let result = ocrResult else {
                return 1
            }

            let filename = inputURL.deletingPathExtension().lastPathComponent
            let outputFile: String
            if let out = outputPath {
                if out.lowercased().hasSuffix(".json") || out.lowercased().hasSuffix(".txt") {
                    outputFile = out
                } else {
                    outputFile = (out as NSString).appendingPathComponent(filename + ".json")
                }
            } else {
                outputFile = (inputURL.deletingLastPathComponent().path as NSString).appendingPathComponent(filename + ".json")
            }

            do {
                if outputFile.lowercased().hasSuffix(".txt") {
                    try writeTextOutput(result, to: outputFile)
                    print("✅ OCR text written to \(outputFile)")
                } else {
                    let jsonData = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted])
                    try jsonData.write(to: URL(fileURLWithPath: outputFile))
                    print("✅ OCR data written to \(outputFile)")
                }
            } catch {
                fputs("Error writing output for \(inputPath): \(error.localizedDescription)\n", stderr)
                return 1
            }
        }
    }

    return 0
}

#else
func runCLI(args: [String]) -> Int32 {
    fputs("macOCR requires macOS 15 or newer with the Vision framework.\n", stderr)
    return 1
}
#endif

// MARK: - Entry Point

@main
enum MacOCRCommand {
    static func main() {
        #if canImport(Vision) && canImport(Cocoa) && canImport(PDFKit)
        exit(runCLI(args: CommandLine.arguments))
        #else
        fputs("This tool requires macOS with Vision, Cocoa, and PDFKit frameworks.\n", stderr)
        exit(1)
        #endif
    }
}
