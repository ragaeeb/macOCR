# AGENTS.md - macOCR Development Guide for AI Agents

This document provides context, conventions, lessons learned, and architectural decisions for AI agents working on the macOCR codebase.

## Project Intent

macOCR is a high-performance Swift command-line tool that uses Apple's Vision framework to perform OCR on images and PDF documents. The primary goals are:

1. **High Accuracy**: Leverage the latest Vision APIs (`VNRecognizeTextRequestRevision3`, `RecognizeDocumentsRequest`)
2. **Structured Output**: Provide precise bounding boxes with consistent coordinate systems
3. **Flexibility**: Support multiple input formats, languages, and output options
4. **Quality Detection**: Flag low-confidence OCR results for downstream processing

## Build & Test

```bash
# Build with Swift Package Manager
swift build

# Run tests (25 unit tests)
swift test

# Build release binary
swift build -c release
# Binary at: .build/release/macocr

# Run the tool
.build/debug/macocr --help
```

## Architecture

### Module Structure

```
Sources/
├── macOCRCore/              # Platform-neutral library (can be tested independently)
│   ├── CommandLine.swift    # CLI argument parsing
│   ├── Rounding.swift       # round3() for 3-decimal precision
│   └── OutputWriters.swift  # JSON/text file output
└── macOCRCLI/
    └── main.swift           # Vision framework integration (macOS-only)
```

### Key Design Decisions

1. **Modular Core**: `macOCRCore` contains platform-neutral code that can be unit tested without Vision framework dependencies
2. **Swift 6 Concurrency**: Uses `nonisolated`, `@Sendable`, and proper async patterns for strict concurrency compliance
3. **Opt-in Features**: New features like `--group` and `--confidence` are opt-in to maintain backward compatibility
4. **Platform Minimum in Package.swift**: The minimum is set to `.macOS(.v15)` in Package.swift, so `@available(macOS 15.0, *)` annotations are unnecessary. Only use `@available(macOS 26.0, *)` for paragraph grouping features that require the newer API.

## Coding Conventions

### Swift Style
- Swift 6.0 strict concurrency compliance
- `lowerCamelCase` for functions and variables
- `UpperCamelCase` for types
- Public APIs have documentation comments

### Naming
- CLI options have both short and long forms: `-g/--group`, `-c/--confidence=`
- Function parameters: `cgImage:languages:confidenceThreshold:`

### Output Format
- Bounding boxes use **3 decimal places** via `round3()` utility
- Y-axis is **flipped** (0,0 at top-left, not bottom-left like Vision's normalized coords)
- Coordinates in **absolute pixels**, not normalized

## Vision Framework APIs

### Standard OCR (macOS 15+)
```swift
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.revision = VNRecognizeTextRequestRevision3
request.recognitionLanguages = ["ar", "en"]  // Order matters: first = highest priority
request.usesLanguageCorrection = false  // Disabled for predictable output
```

### Paragraph Grouping (macOS 26+)
```swift
var request = RecognizeDocumentsRequest()
request.textRecognitionOptions.recognitionLanguages = languages.compactMap { Locale.Language(identifier: $0) }
// Note: revision is read-only, defaults to .revision1
```

### Coordinate Conversion
```swift
// Vision returns normalized coordinates (0.0-1.0)
// Convert to absolute pixels and flip Y-axis:
let absBox = VNImageRectForNormalizedRect(normalizedBox, Int(imageWidth), Int(imageHeight))
let flippedY = imageHeight - absBox.origin.y - absBox.size.height
```

## Challenges & Solutions

### 1. Swift 6 Strict Concurrency
**Problem**: Swift 6 requires explicit `Sendable` conformance for closures crossing task boundaries.

**Solution**:
```swift
// Use nonisolated and @Sendable for async helpers
nonisolated func runAsyncAndBlock<T: Sendable>(_ operation: @Sendable @escaping () async throws -> T) throws -> T {
    nonisolated(unsafe) var result: Result<T, Error>?
    // ...
}

// Use let (not var) for captured values in async closures
let request: RecognizeDocumentsRequest = {
    var req = RecognizeDocumentsRequest()
    // configure...
    return req
}()
```

### 2. RecognizeDocumentsRequest API Differences
**Problem**: `RecognizeDocumentsRequest` uses different types than `VNRecognizeTextRequest`:
- `boundingRegion.boundingBox` returns `NormalizedRect` (not `CGRect`)
- Languages are `Locale.Language` (not `String`)
- `revision` is read-only

**Solution**:
```swift
// Convert NormalizedRect to CGRect manually
let normalizedRect = paragraph.boundingRegion.boundingBox
let cgRect = CGRect(
    x: CGFloat(normalizedRect.origin.x),
    y: CGFloat(normalizedRect.origin.y),
    width: CGFloat(normalizedRect.width),
    height: CGFloat(normalizedRect.height)
)
let rect = VNImageRectForNormalizedRect(cgRect, Int(imageWidth), Int(imageHeight))

// Convert language strings to Locale.Language
request.textRecognitionOptions.recognitionLanguages = languages.compactMap { Locale.Language(identifier: $0) }
```

### 3. Arabic Ligature Recognition (ﷺ)
**Problem**: Vision OCR misrecognizes special Arabic ligatures like ﷺ (U+FDFA, "sallallahu alayhi wa sallam"), outputting random characters like `ل` or `كلل`.

**Solution**: Added `--confidence` flag to flag low-confidence lines:
```swift
// Lines with confidence below threshold get a "confidence" field
if confidenceThreshold > 0 && candidate.confidence < confidenceThreshold {
    entry["confidence"] = round3(Double(candidate.confidence))
}
```

**Finding**: Lines with misrecognized ligatures typically have confidence 0.3 (vs 0.5 for normal lines).

### 4. CLI Argument Parsing for `=` syntax
**Problem**: Need to support `--confidence=0.5` format (not just `--confidence 0.5`).

**Solution**: Use `hasPrefix` pattern matching:
```swift
if argument.hasPrefix("--confidence=") {
    let valueStr = String(argument.dropFirst("--confidence=".count))
    if let value = Float(valueStr), value >= 0.0 && value <= 1.0 {
        options.confidenceThreshold = value
    }
}
```

### 5. Package.swift Version for macOS 15
**Problem**: `swift-tools-version: 5.9` doesn't support `.macOS(.v15)` platform.

**Solution**: Use `swift-tools-version: 6.0` which supports macOS 15 platform specifications.

## Testing Strategy

### Unit Tests (macOCRCoreTests)
- **Rounding**: `round3()` precision, edge cases
- **CLI Parsing**: All flags, error cases, defaults
- **Output Writers**: JSON ordering, text formatting, paragraph preference

### Manual Testing
```bash
# Test standard OCR
.build/debug/macocr --language ar Tests/1.jpg

# Test paragraph grouping
.build/debug/macocr --group --language ar -p 2-2 /path/to/test.pdf

# Test confidence flagging
.build/debug/macocr -c=0.5 --language ar Tests/1.jpg
```

## Common Gotchas

1. **Language order matters**: First language in list has highest priority
2. **Confidence values are quantized**: Vision typically returns 0.3 or 0.5, not granular values
3. **`RecognizeDocumentsRequest.revision` is read-only**: Don't try to set it
4. **`NSBitmapImageRep(cgImage:)` is non-optional**: Don't use `guard let` with it
5. **PDF page indexing**: 1-based in CLI args, 0-based internally

## Future Considerations

1. **Custom words**: Vision's `customWords` property could help with domain-specific vocabulary
2. **Language correction**: Currently disabled; enabling it might improve accuracy but reduces predictability
3. **Async entry point**: The current `runAsyncAndBlock` pattern is a workaround; a fully async CLI would be cleaner

## Related Projects

- **kokokor**: Downstream library that processes macOCR output for text layout analysis
- **skalu**: Python tool for detecting horizontal lines and rectangles in PDFs (used with macOCR for document structure analysis)
