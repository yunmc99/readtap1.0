import Foundation

// LexoRank-lite key generator for stable ordering.
enum OrderKey {
    private static let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    private static let minChar = alphabet.first!
    private static let maxChar = alphabet.last!
    private static let base = alphabet.count

    static func initial() -> String { "h" }

    static func before(_ right: String) -> String {
        between(nil, right)
    }

    static func after(_ left: String) -> String {
        between(left, nil)
    }

    static func between(_ left: String?, _ right: String?) -> String {
        if left == nil && right == nil { return initial() }
        if left == nil { return decrementKey(right!) }
        if right == nil { return incrementKey(left!) }
        return betweenKeys(left!, right!)
    }

    private static func betweenKeys(_ left: String, _ right: String) -> String {
        let leftDigits = digits(for: left)
        let rightDigits = digits(for: right)

        var result: [Int] = []
        var idx = 0
        while true {
            let leftDigit = idx < leftDigits.count ? leftDigits[idx] : 0
            let rightDigit = idx < rightDigits.count ? rightDigits[idx] : base - 1
            if rightDigit - leftDigit > 1 {
                let mid = (leftDigit + rightDigit) / 2
                result.append(mid)
                return string(from: result)
            } else {
                result.append(leftDigit)
                idx += 1
            }
        }
    }

    private static func incrementKey(_ key: String) -> String {
        var digits = digits(for: key)
        var i = digits.count - 1
        while i >= 0 {
            if digits[i] < base - 1 {
                digits[i] += 1
                return string(from: digits)
            }
            digits[i] = 0
            i -= 1
        }
        // overflow: append mid
        digits.append(base / 2)
        return string(from: digits)
    }

    private static func decrementKey(_ key: String) -> String {
        var digits = digits(for: key)
        var i = digits.count - 1
        while i >= 0 {
            if digits[i] > 0 {
                digits[i] -= 1
                // trim trailing zeros
                while digits.count > 1, digits.last == 0 {
                    digits.removeLast()
                }
                return string(from: digits)
            }
            digits[i] = base - 1
            i -= 1
        }
        // underflow: prepend mid
        digits.insert(base / 2, at: 0)
        return string(from: digits)
    }

    private static func digits(for key: String) -> [Int] {
        key.compactMap { ch in
            alphabet.firstIndex(of: ch)
        }
    }

    private static func string(from digits: [Int]) -> String {
        String(digits.map { alphabet[$0] })
    }
}
