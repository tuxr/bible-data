/// A stretch of two sequences: equal in both, or replaced, where either side may be empty.
enum Hunk<Element: Equatable>: Equatable {
    case same([Element])
    case changed(old: [Element], new: [Element])
}

/// The longest common subsequence of two sequences, as alternating same and changed hunks.
func hunks<Element: Equatable>(_ old: [Element], _ new: [Element]) -> [Hunk<Element>] {
    let prefix = zip(old, new).prefix { $0 == $1 }.count
    let oldRest = old.dropFirst(prefix), newRest = new.dropFirst(prefix)
    let suffix = zip(oldRest.reversed(), newRest.reversed()).prefix { $0 == $1 }.count
    let a = Array(oldRest.dropLast(suffix)), b = Array(newRest.dropLast(suffix))

    // lengths[i][j] is the LCS length of a[i...] and b[j...].
    var lengths = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in stride(from: a.count - 1, through: 0, by: -1) {
        for j in stride(from: b.count - 1, through: 0, by: -1) {
            lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
        }
    }

    var result: [Hunk<Element>] = []
    func appendSame(_ element: Element) {
        if case .same(let run)? = result.last { result[result.count - 1] = .same(run + [element]) } else { result.append(.same([element])) }
    }
    func appendChange(old: [Element] = [], new: [Element] = []) {
        if case .changed(let o, let n)? = result.last { result[result.count - 1] = .changed(old: o + old, new: n + new) } else {
            result.append(.changed(old: old, new: new))
        }
    }
    if prefix > 0 { result.append(.same(Array(old.prefix(prefix)))) }
    var i = 0, j = 0
    while i < a.count || j < b.count {
        if i < a.count, j < b.count, a[i] == b[j] {
            appendSame(a[i]); i += 1; j += 1
        } else if j < b.count, i == a.count || lengths[i][j + 1] >= lengths[i + 1][j] {
            appendChange(new: [b[j]]); j += 1
        } else {
            appendChange(old: [a[i]]); i += 1
        }
    }
    if suffix > 0 {
        let tail = Array(old.suffix(suffix))
        if case .same(let run)? = result.last { result[result.count - 1] = .same(run + tail) } else { result.append(.same(tail)) }
    }
    return result
}
