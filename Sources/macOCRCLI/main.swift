import Foundation
import macOCRCore

let VERSION = "1.3.0"

#if canImport(Vision) && canImport(Cocoa) && canImport(PDFKit)
import Vision
import Cocoa
import PDFKit
import Dispatch

@available(macOS 15.0, *)
func runAsyncAndBlock<T>(_ operation: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<T, Error>?

    Task {
        result = Result { try await operation() }
        semaphore.signal()
    }

    semaphore.wait()

    if let outcome = result {
        return try outcome.get()
    }

    throw NSError(domain: "macOCR", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown async execution failure"])
}

@available(macOS 15.0, *)
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

@available(macOS 15.0, *)
func recognizeDocumentParagraphs(cgImage: CGImage, languages: [String]) -> [[String: Any]]? {
    guard let bitmap = NSBitmapImageRep(cgImage: cgImage),
          let imageData = bitmap.representation(using: .png, properties: [:]) else {
        fputs("Document paragraph extraction failed: unable to generate image data.\n", stderr)
        return nil
    }

    var request = RecognizeDocumentsRequest()
    request.textRecognitionOptions.recognitionLanguages = languages
    request.textRecognitionOptions.useLanguageCorrection = false
    request.textRecognitionOptions.automaticallyDetectLanguage = languages.isEmpty

    let imageWidth = CGFloat(cgImage.width)
    let imageHeight = CGFloat(cgImage.height)

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
            let rect = VNImageRectForNormalizedRect(normalizedRect, Int(imageWidth), Int(imageHeight))
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

            let lineTexts = paragraph.lines.map { $0.transcript }.filter { !$0.isEmpty }
            if !lineTexts.isEmpty {
                paragraphEntry["lines"] = lineTexts
            }

            paragraphs.append(paragraphEntry)
        }
    }

    return paragraphs
}

@available(macOS 15.0, *)
func performOCR(cgImage: CGImage, languages: [String]) -> [String: Any]? {
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

        observations.append([
            "text": candidate.string,
            "bbox": [
                "x": round3(absBox.origin.x),
                "y": round3(flippedY),
                "width": round3(absBox.size.width),
                "height": round3(absBox.size.height)
            ]
        ])
    }

    var result: [String: Any] = [
        "width": Int(imageWidth),
        "height": Int(imageHeight),
        "observations": observations
    ]

    if let paragraphs = recognizeDocumentParagraphs(cgImage: cgImage, languages: languages),
       !paragraphs.isEmpty {
        result["paragraphs"] = paragraphs
    }

    return result
}

@available(macOS 15.0, *)
func performOCR(on imagePath: String, languages: [String]) -> [String: Any]? {
    guard let img = NSImage(byReferencingFile: imagePath),
          let imgRef = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fputs("Error: failed to load or convert image '\(imagePath)'\n", stderr)
        return nil
    }

    return performOCR(cgImage: imgRef, languages: languages)
}

@available(macOS 15.0, *)
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
        return 1
    }

    let inputPath = options.inputPath
    let outputPath = options.outputPath
    let languages = options.languages
    let pageRange = options.pageRange

    var isDir: ObjCBool = false
    guard fileManager.fileExists(atPath: inputPath, isDirectory: &isDir) else {
        fputs("Error: Input path does not exist\n", stderr)
        return 1
    }

    if isDir.boolValue {
        guard let files = try? fileManager.contentsOfDirectory(atPath: inputPath) else {
            fputs("Error reading directory: \(inputPath)\n", stderr)
            return 1
        }

        var results: [String: [String: Any]] = [:]
        for file in files.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let fullPath = (inputPath as NSString).appendingPathComponent(file)
            if let image = NSImage(byReferencingFile: fullPath),
               let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                if let ocrResult = performOCR(cgImage: cgImage, languages: languages) {
                    results[file] = ocrResult
                }
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
            let endPage = pageRange?.upperBound ?? pageCount
            for index in (startPage-1)...(endPage-1) {
                print("Processing page \(index + 1) of \(pageCount)...")
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

                if let ocrResult = performOCR(cgImage: cgImg, languages: languages) {
                    var pageDict = ocrResult
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
            guard let ocrResult = performOCR(on: inputPath, languages: languages) else {
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
                    try writeTextOutput(ocrResult, to: outputFile)
                    print("✅ OCR text written to \(outputFile)")
                } else {
                    let jsonData = try JSONSerialization.data(withJSONObject: ocrResult, options: [.prettyPrinted])
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

@main
enum MacOCRCommand {
    static func main() {
        #if canImport(Vision) && canImport(Cocoa) && canImport(PDFKit)
        if #available(macOS 15.0, *) {
            exit(runCLI(args: CommandLine.arguments))
        } else {
            fputs("This tool requires macOS 15 or newer.\n", stderr)
            exit(1)
        }
        #else
        _ = runCLI(args: CommandLine.arguments)
        #endif
    }
}
