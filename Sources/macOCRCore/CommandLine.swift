import Foundation

struct CommandLineOptions: Equatable {
    var inputPath: String = ""
    var outputPath: String? = nil
    var languages: [String] = ["en"]
    var pageRange: ClosedRange<Int>? = nil
    var showHelp: Bool = false
    var showVersion: Bool = false
    var showSupportedLanguages: Bool = false
}

/// Parses the provided command-line arguments into a `CommandLineOptions` value.
/// Returns `nil` if argument validation fails.
func parseCommandLineArguments(_ args: [String]) -> CommandLineOptions? {
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
            let components = args[index]
                .split(separator: "-")
                .compactMap { Int($0) }
            if components.count == 2,
               components[0] > 0,
               components[1] >= components[0] {
                options.pageRange = components[0]...components[1]
            } else {
                fputs("Error: Invalid page range format. Use format like '2-5'\n", stderr)
                return nil
            }

        default:
            if argument.hasPrefix("-") {
                fputs("Error: Unknown option '\(argument)'\n", stderr)
                return nil
            }
            if options.inputPath.isEmpty {
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

func printVersion(_ version: String) {
    print("macOCR version \(version)")
}

func printUsage() {
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
                                        Examples: en, en,es, ar,en,fr

        -o, --output <path>             Output file or directory path
                                        - If path ends with .json: JSON format output
                                        - If path ends with .txt: Plain text output
                                        - If path is directory: Files saved within

        -p, --pages <range>             Page range for PDF processing (1-indexed)
                                        Format: start-end (e.g., 1-5, 3-10)
                                        Only processes specified pages

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

        PDF page range processing:
            macOCR --language en --pages 1-3 --output output/ document.pdf
            → Process first 3 pages, save in output/ directory

        Batch directory processing:
            macOCR --language en,ar images_directory/ --output ocr_results/
            → Process all images with English+Arabic, save batch_output.json

        Text-only output:
            macOCR --output results.txt image.jpg
            → Extract text content only, no bounding boxes

        List supported languages:
            macOCR --supported-languages
            → Display JSON array of all available language codes

    OUTPUT STRUCTURE:
        Single Image JSON:
        {
            "width": 1200,
            "height": 800,
            "observations": [
                {
                    "text": "Detected text content",
                    "bbox": {
                        "x": 123.456,
                        "y": 78.901,
                        "width": 234.567,
                        "height": 45.678
                    }
                }
            ]
        }

        PDF JSON:
        {
            "pages": [
                {
                    "page": 1,
                    "width": 1200,
                    "height": 800,
                    "observations": [...]
                }
            ],
            "dpi": { "x": 144.000, "y": 144.000 }
        }

        Batch Processing JSON:
        {
            "image1.jpg": { ... },
            "image2.png": { ... }
        }

    TECHNICAL DETAILS:
        - Uses VNRecognizeTextRequestRevision3 for maximum accuracy
        - Supports RTL languages (Arabic, Hebrew, etc.)
        - Bounding boxes use absolute pixel coordinates
        - Y-coordinates flipped to match standard top-down origin
        - Natural sorting for batch processing (10.jpg after 2.jpg)
        - PDF rendering at 2x scale for improved text recognition

    SYSTEM REQUIREMENTS:
        - macOS 15.0 or later
        - Apple Silicon or Intel Mac
        - Vision framework availability

    LANGUAGE SUPPORT:
        Use --supported-languages to see all available codes.
        Common codes: en (English), es (Spanish), fr (French),
        de (German), zh (Chinese), ja (Japanese), ar (Arabic), etc.

    EXIT CODES:
        0    Success
        1    Error (invalid arguments, file not found, OCR failure, etc.)
    """)
}
