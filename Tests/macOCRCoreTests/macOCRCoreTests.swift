import XCTest
@testable import macOCRCore

final class MacOCRCoreTests: XCTestCase {
    func testRound3ProducesExpectedRoundedValues() {
        XCTAssertEqual(round3(1.2), NSDecimalNumber(string: "1.2"))
        XCTAssertEqual(round3(3.14159), NSDecimalNumber(string: "3.142"))
        XCTAssertEqual(round3(0), NSDecimalNumber.zero)
        XCTAssertEqual(round3(123.9999), NSDecimalNumber(string: "124"))
    }

    func testParseCommandLineArgumentsParsesLanguagesAndOutput() {
        let arguments = ["macocr", "--language", "en, fr ,es", "--output", "results.json", "input.png"]
        let options = parseCommandLineArguments(arguments)
        XCTAssertEqual(options?.languages, ["en", "fr", "es"])
        XCTAssertEqual(options?.outputPath, "results.json")
        XCTAssertEqual(options?.inputPath, "input.png")
    }

    func testParseCommandLineArgumentsRejectsInvalidPageRange() {
        let arguments = ["macocr", "--pages", "5-3", "input.png"]
        XCTAssertNil(parseCommandLineArguments(arguments))
    }

    func testWriteJSONObjectOrderedPreservesAllKeys() throws {
        let dictionary: [String: Any] = [
            "10": "value10",
            "2": "value2",
            "file20": "value20",
            "file3": "value3"
        ]

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try writeJSONObjectOrdered(dictionary, to: url.path)

        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        XCTAssertEqual(json?.keys.sorted(), ["10", "2", "file20", "file3"].sorted())
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

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try writeTextOutput(object, to: url.path)

        let output = try String(contentsOf: url)
        XCTAssertEqual(output, "Paragraph one\nParagraph two")
    }

    func testWriteTextOutputFallsBackToObservationsForPageResults() throws {
        let object: [String: Any] = [
            "pages": [
                [
                    "page": 1,
                    "observations": [
                        ["text": "First page line"],
                        ["text": "Second page line"]
                    ]
                ]
            ]
        ]

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try writeTextOutput(object, to: url.path)

        let output = try String(contentsOf: url)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "--- Page 1 ---\nFirst page line\nSecond page line")
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

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try writeTextOutput(object, to: url.path)

        let output = try String(contentsOf: url)
        XCTAssertEqual(output, "=== fileA ===\nFirst paragraph\n\n=== fileB ===\nSecond")
    }
}
