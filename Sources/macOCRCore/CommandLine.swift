import Foundation

/// Configuration structure for command-line options
public struct CommandLineOptions: Equatable, Sendable {
    /// Path to input file or directory
    public var inputPath: String = ""
    /// Optional output path for results
    public var outputPath: String? = nil
    /// Array of language codes for OCR recognition
    public var languages: [String] = ["en"]
    /// Optional page range for PDF processing (1-indexed)
    public var pageRange: ClosedRange<Int>? = nil
    /// Flag to show help message
    public var showHelp: Bool = false
    /// Flag to show version number
    public var showVersion: Bool = false
    /// Flag to show supported languages
    public var showSupportedLanguages: Bool = false
    /// Flag to enable paragraph grouping via RecognizeDocumentsRequest
    public var groupParagraphs: Bool = false
    /// Confidence threshold for including confidence in output (0.0 to disable, default 0.3)
    public var confidenceThreshold: Float = 0.3
    
    public init() {}
}

/// Parses the provided command-line arguments into a `CommandLineOptions` value.
/// Returns `nil` if argument validation fails.
public func parseCommandLineArguments(_ args: [String]) -> CommandLineOptions? {
    var options = CommandLineOptions()
    var index = 1 // Skip program name

    while index < args.count {
        let argument = args[index]

        switch argument {
        case "-h", "--help":
            options.showHelp = true
            return options

        case "-v", "--version":
            options.showVersion = true
            return options

        case "--supported-languages":
            options.showSupportedLanguages = true
            return options
            
        case "-g", "--group":
            options.groupParagraphs = true

        case "-l", "--language", "--languages":
            guard index + 1 < args.count else {
                fputs("Error: \(argument) requires a value\n", stderr)
                return nil
            }
            index += 1
            options.languages = args[index]
                .split(separator: ",")
                .map { String($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
            if options.languages.isEmpty {
                options.languages = ["en"]
            }

        case "-o", "--output":
            guard index + 1 < args.count else {
                fputs("Error: \(argument) requires a value\n", stderr)
                return nil
            }
            index += 1
            options.outputPath = args[index]

        case "-p", "--pages":
            guard index + 1 < args.count else {
                fputs("Error: \(argument) requires a value\n", stderr)
                return nil
            }
            index += 1
            let componentStr = args[index]
            let components = componentStr
                .split(separator: "-")
                .compactMap { Int($0) }
            
            if components.count == 2,
               components[0] > 0,
               components[1] >= components[0] {
                options.pageRange = components[0]...components[1]
            } else if components.count == 1, let singlePage = Int(componentStr), singlePage > 0 {
                // Support single page "--pages 5" as "5-5"
                options.pageRange = singlePage...singlePage
            } else {
                fputs("Error: Invalid page range format. Use format like '2-5' or '5'\n", stderr)
                return nil
            }

        case "-c", "--confidence":
            guard index + 1 < args.count else {
                fputs("Error: \(argument) requires a value\n", stderr)
                return nil
            }
            index += 1
            let valStr = args[index]
            if let value = Float(valStr), value >= 0.0 && value <= 1.0 {
                options.confidenceThreshold = value
            } else {
                 fputs("Error: --confidence requires a value between 0.0 and 1.0\n", stderr)
                 return nil
            }

        default:
            // Handle --confidence=VALUE format
            if argument.hasPrefix("--confidence=") {
                let valueStr = String(argument.dropFirst("--confidence=".count))
                if let value = Float(valueStr), value >= 0.0 && value <= 1.0 {
                    options.confidenceThreshold = value
                } else {
                    fputs("Error: --confidence requires a value between 0.0 and 1.0\n", stderr)
                    return nil
                }
            } else if argument.hasPrefix("-c=") {
                let valueStr = String(argument.dropFirst("-c=".count))
                if let value = Float(valueStr), value >= 0.0 && value <= 1.0 {
                    options.confidenceThreshold = value
                } else {
                    fputs("Error: -c requires a value between 0.0 and 1.0\n", stderr)
                    return nil
                }
            } else if argument.hasPrefix("-") {
                fputs("Error: Unknown option '\(argument)'\n", stderr)
                return nil
            } else if options.inputPath.isEmpty {
                options.inputPath = argument
            } else {
                fputs("Error: Multiple input paths specified\n", stderr)
                return nil
            }
        }

        index += 1
    }

    return options
}

/// Prints version information
public func printVersion(_ version: String) {
    print("macOCR version \(version)")
}

/// Prints comprehensive usage information
public func printUsage() {
    print("""
    macOCR - OCR tool for images and PDFs using macOS Vision framework

    DESCRIPTION:
        A high-accuracy OCR command-line tool that leverages Apple's Vision framework
        to extract text from images and PDF documents. Outputs structured JSON with
        text content and precise bounding box coordinates, or plain text format.

    USAGE:
        macOCR [OPTIONS] <input_path>

    OPTIONS:
        -l, --language <languages>      Comma-separated list of language codes for OCR
                                        recognition (default: en)
                                        Order matters: first language has highest priority.
                                        Examples: en, en,es, ar,en,fr

        -o, --output <path>             Output file or directory path
                                        - If path ends with .json: JSON format output
                                        - If path ends with .txt: Plain text output
                                        - If path is directory: Files saved within

        -p, --pages <range>             Page range for PDF processing (1-indexed)
                                        Format: start-end (e.g., 1-5) or single page (e.g., 5)
                                        Only processes specified pages

        -g, --group                     Enable paragraph grouping (macOS 26+)
                                        Groups text lines into paragraphs using
                                        Apple's RecognizeDocumentsRequest API.
                                        Output uses 'paragraphs' instead of 'observations'.
                                        Each paragraph includes its lines with bounding boxes
                                        and 'isTitle' flag for title lines.

        -c, --confidence <val>          Include confidence score in output when below
                                        threshold value (default: 0.3)
                                        - Lines with confidence below threshold get a
                                          "confidence" field in the output
                                        - Set to 0 to disable confidence reporting
                                        - Useful for detecting OCR quality issues
                                        Examples: -c 0.5, --confidence=0.5, -c=0

        -h, --help                      Show this comprehensive help message

        --supported-languages           List all supported OCR language codes
                                        Output in JSON format

    INPUT FORMATS:
        Images:     .jpg, .jpeg, .png
        Documents:  .pdf (with optional page range)
        Batch:      Directory containing supported image files

    OUTPUT FORMATS:
        JSON (.json):
            - Full OCR data with bounding boxes and metadata
            - Coordinates use top-left origin with flipped Y-axis
            - Precision: 3 decimal places for all measurements

        Text (.txt):
            - Plain text content only, no coordinates
            - Preserves reading order and line breaks

    EXAMPLES:
        Basic image OCR:
            macOCR image.jpg
            → Creates image.json in same directory

        Multi-language with custom output:
            macOCR --language en,es,fr --output results.json document.pdf
            → OCR with English, Spanish, French; save as results.json

        PDF with paragraph grouping:
            macOCR --group --language ar --pages 1-5 document.pdf
            → Process pages 1-5 with paragraph grouping

        Batch directory processing:
            macOCR --language en,ar images_directory/ --output ocr_results/
            → Process all images with English+Arabic, save batch_output.json

    SYSTEM REQUIREMENTS:
        - macOS 15.0 or later (macOS 26+ for --group)
        - Apple Silicon or Intel Mac
        - Vision framework availability
    """)
}
