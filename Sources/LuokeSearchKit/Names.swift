import Foundation

/// A file's name as the user reads it.
public enum Names {
    /// A name kept with its characters percent-encoded (what some downloaders keep of a URL:
    /// 「%E9%A6%99%E6%B8%AF.pdf」) shown decoded, when that gives valid UTF-8 of printable characters without a slash;
    /// else the name as it is. Only for showing: the index, matching, the path and opening keep the name as the file
    /// system has it. (The same rule as luoke-scan's display names.)
    public static func display(_ name: String) -> String {
        guard name.contains("%"), let decoded = name.removingPercentEncoding, decoded != name,
              !decoded.contains("/"), decoded.unicodeScalars.allSatisfy(isPrintable) else { return name }
        return decoded
    }

    /// Letters, marks, numbers, punctuation, symbols and the ASCII space: Go's `unicode.IsPrint`.
    static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == " " { return true }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark,
             .decimalNumber, .letterNumber, .otherNumber,
             .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
             .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }
}
