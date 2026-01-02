import XCTest
@testable import macOCRCore

final class MacOCRCoreTests: XCTestCase {
    
    // MARK: - Rounding Tests
    
    func testRound3ProducesExpectedRoundedValues() {
        XCTAssertEqual(round3(1.2), NSDecimalNumber(string: "1.200"))
        XCTAssertEqual(round3(3.14159), NSDecimalNumber(string: "3.142"))
        XCTAssertEqual(round3(0.0), NSDecimalNumber(string: "0.000"))
        XCTAssertEqual(round3(123.9999), NSDecimalNumber(string: "124.000"))
        XCTAssertEqual(round3(-5.5555), NSDecimalNumber(string: "-5.556"))
    }
    
    func testRound3HandlesSmallValues() {
        XCTAssertEqual(round3(0.001), NSDecimalNumber(string: "0.001"))
        XCTAssertEqual(round3(0.0001), NSDecimalNumber(string: "0.000"))
        XCTAssertEqual(round3(0.0005), NSDecimalNumber(string: "0.001"))
    }
    
    // MARK: - Command Line Parsing Tests
    
    func testParseCommandLineArgumentsParsesLanguagesAndOutput() {
        let arguments = ["macocr", "--language", "en, fr ,es", "--output", "results.json", "input.png"]
        let options = parseCommandLineArguments(arguments)
        XCTAssertEqual(options?.languages, ["en", "fr", "es"])
        XCTAssertEqual(options?.outputPath, "results.json")
        XCTAssertEqual(options?.inputPath, "input.png")
    }
    
    func testParseCommandLineArgumentsWithGroupFlag() {
        let arguments = ["macocr", "--group", "-l", "ar", "document.pdf"]
        let options = parseCommandLineArguments(arguments)
        XCTAssertNotNil(options)
        XCTAssertTrue(options!.groupParagraphs)
        XCTAssertEqual(options?.languages, ["ar"])
        XCTAssertEqual(options?.inputPath, "document.pdf")
    }
    
    func testParseCommandLineArgumentsWithShortGroupFlag() {
        let arguments = ["macocr", "-g", "image.jpg"]
        let options = parseCommandLineArguments(arguments)
        XCTAssertNotNil(options)
        XCTAssertTrue(options!.groupParagraphs)
    }
    
    func testParseCommandLineArgumentsDefaultsToNoGrouping() {
        let arguments = ["macocr", "image.jpg"]
        let options = parseCommandLineArguments(arguments)
        XCTAssertNotNil(options)
        XCTAssertFalse(options!.groupParagraphs)
    }

    func testParseCommandLineArgumentsRejectsInvalidPageRange() {
        let arguments = ["macocr", "--pages", "5-3", "input.png"]
        XCTAssertNil(parseCommandLineArguments(arguments))
    }
    
    func testParseCommandLineArgumentsRejectsZeroStartPage() {
        let arguments = ["macocr", "--pages", "0-3", "input.png"]
        XCTAssertNil(parseCommandLineArguments(arguments))
    }
    
    func testParseCommandLineArgumentsAcceptsValidPageRange() {
        let arguments = ["macocr", "--pages", "2-5", "input.pdf"]
        let options = parseCommandLineArguments(arguments)
        XCTAssertEqual(options?.pageRange, 2...5)
    }
    
    func testParseCommandLineArgumentsHelpFlag() {
        let arguments = ["macocr", "--help"]
        let options = parseCommandLineArguments(arguments)
        XCTAssertNotNil(options)
        XCTAssertTrue(options!.showHelp)
    }
    
    func testParseCommandLineArgumentsVersionFlag() {
        let arguments = ["macocr", "-v"]
        let options = parseCommandLineArguments(arguments)
        XCTAssertNotNil(options)
        XCTAssertTrue(options!.showVersion)
    }
    
    func testParseCommandLineArgumentsRejectsUnknownFlag() {
        let arguments = ["macocr", "--unknown-flag", "input.png"]
        XCTAssertNil(parseCommandLineArguments(arguments))
    }
    
    func testParseCommandLineArgumentsRejectsMultipleInputs() {
        let arguments = ["macocr", "input1.png", "input2.png"]
        XCTAssertNil(parseCommandLineArguments(arguments))
    }
    
    func testParseCommandLineArgumentsDefaultLanguageIsEnglish() {
        let arguments = ["macocr", "input.png"]
        let options = parseCommandLineArguments(arguments)
        XCTAssertEqual(options?.languages, ["en"])
    }
    
    // MARK: - Confidence Threshold Tests
    
    func testParseCommandLineArgumentsDefaultConfidenceThreshold() {
        let arguments = ["macocr", "input.png"]
        let options = parseCommandLineArguments(arguments)
        XCTAssertEqual(options?.confidenceThreshold, 0.3)
    }
    
    func testParseCommandLineArgumentsWithConfidenceFlag() {
        let arguments = ["macocr", "--confidence=0.5", "input.png"]
        let options = parseCommandLineArguments(arguments)
        XCTAssertEqual(options?.confidenceThreshold, 0.5)
    }
    
    func testParseCommandLineArgumentsWithShortConfidenceFlag() {
        let arguments = ["macocr", "-c=0.2", "input.png"]
        let options = parseCommandLineArguments(arguments)
        XCTAssertEqual(options?.confidenceThreshold, 0.2)
    }
    
    func testParseCommandLineArgumentsConfidenceZeroDisables() {
        let arguments = ["macocr", "--confidence=0", "input.png"]
        let options = parseCommandLineArguments(arguments)
        XCTAssertEqual(options?.confidenceThreshold, 0.0)
    }
    
    func testParseCommandLineArgumentsRejectsInvalidConfidence() {
        let arguments = ["macocr", "--confidence=1.5", "input.png"]
        XCTAssertNil(parseCommandLineArguments(arguments))
    }
    
    func testParseCommandLineArgumentsRejectsNegativeConfidence() {
        let arguments = ["macocr", "--confidence=-0.1", "input.png"]
        XCTAssertNil(parseCommandLineArguments(arguments))
    }

    // MARK: - Output Writer Tests

    func testWriteJSONObjectOrderedPreservesAllKeys() throws {
        let dictionary: [String: Any] = [
            "10": "value10",
            "2": "value2",
            "file20": "value20",
            "file3": "value3"
        ]

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try writeJSONObjectOrdered(dictionary, to: url.path)

        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        XCTAssertEqual(json?.keys.sorted(), ["10", "2", "file20", "file3"].sorted())
        
        try? FileManager.default.removeItem(at: url)
    }

    func testWriteTextOutputUsesParagraphsWhenAvailable() throws {
        let object: [String: Any] = [
            "paragraphs": [
                ["text": "Paragraph one"],
                ["text": "Paragraph two"]
            ],
            "observations": [
                ["text": "Line one"],
                ["text": "Line two"]
            ]
        ]

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try writeTextOutput(object, to: url.path)

        let output = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(output, "Paragraph one\nParagraph two")
        
        try? FileManager.default.removeItem(at: url)
    }

    func testWriteTextOutputFallsBackToObservations() throws {
        let object: [String: Any] = [
            "observations": [
                ["text": "Line one"],
                ["text": "Line two"]
            ]
        ]

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try writeTextOutput(object, to: url.path)

        let output = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(output, "Line one\nLine two")
        
        try? FileManager.default.removeItem(at: url)
    }

    func testWriteTextOutputFormatsPDFPages() throws {
        let object: [String: Any] = [
            "pages": [
                [
                    "page": 1,
                    "observations": [
                        ["text": "First page line"]
                    ]
                ],
                [
                    "page": 2,
                    "paragraphs": [
                        ["text": "Second page paragraph"]
                    ]
                ]
            ]
        ]

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try writeTextOutput(object, to: url.path)

        let output = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(output.contains("--- Page 1 ---"))
        XCTAssertTrue(output.contains("First page line"))
        XCTAssertTrue(output.contains("--- Page 2 ---"))
        XCTAssertTrue(output.contains("Second page paragraph"))
        
        try? FileManager.default.removeItem(at: url)
    }

    func testWriteTextOutputFormatsBatchOutput() throws {
        let object: [String: Any] = [
            "fileB": [
                "observations": [["text": "Second"]]
            ],
            "fileA": [
                "paragraphs": [["text": "First paragraph"]]
            ]
        ]

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try writeTextOutput(object, to: url.path)

        let output = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(output.contains("=== fileA ==="))
        XCTAssertTrue(output.contains("First paragraph"))
        XCTAssertTrue(output.contains("=== fileB ==="))
        XCTAssertTrue(output.contains("Second"))
        
        try? FileManager.default.removeItem(at: url)
    }
}
