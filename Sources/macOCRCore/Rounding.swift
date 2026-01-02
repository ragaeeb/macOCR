import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Rounds a Double value to exactly three decimal places using decimal arithmetic.
/// - Parameter value: The double value to round.
/// - Returns: An NSDecimalNumber containing the rounded value.
@inlinable
public func round3(_ value: Double) -> NSDecimalNumber {
    var decimalValue = Decimal(value)
    var rounded = Decimal()
    NSDecimalRound(&rounded, &decimalValue, 3, .plain)

    var stringRepresentation = NSDecimalNumber(decimal: rounded).stringValue
    if let dotIndex = stringRepresentation.firstIndex(of: ".") {
        let fraction = stringRepresentation[stringRepresentation.index(after: dotIndex)...]
        if fraction.count < 3 {
            stringRepresentation += String(repeating: "0", count: 3 - fraction.count)
        } else if fraction.count > 3 {
            let integerPart = stringRepresentation[..<dotIndex]
            let truncatedFraction = fraction.prefix(3)
            stringRepresentation = String(integerPart) + "." + String(truncatedFraction)
        }
    } else {
        stringRepresentation += ".000"
    }

    return NSDecimalNumber(string: stringRepresentation)
}

#if canImport(CoreGraphics)
/// Convenience overload to round a CGFloat value to three decimal places.
/// - Parameter value: The CGFloat value to round.
/// - Returns: An NSDecimalNumber rounded to three decimal places.
@inlinable
public func round3(_ value: CGFloat) -> NSDecimalNumber {
    round3(Double(value))
}
#endif
