import Foundation

// Separation — the per-subject statistics the offline benches use to ask "does this feature tell stage A from
// stage B, and does a change help more subjects than it hurts". Plain functions over arrays, so every one is
// pinned by a hand-computed test and none needs a dataset.
//
// Two conventions worth stating once:
//  - Everything here is a PER-SUBJECT statistic followed by a count across subjects. Consecutive 30 s epochs
//    of one night are far from independent (a centred 5-minute window shares 90 % of its beats with the next
//    epoch's), so an epoch-level p-value would be an artefact of the overlap. The sign test over subjects is
//    the only inferential statement made.
//  - A sign test over a handful of subjects is weak by construction: with 16 subjects the two-sided p stays above
//    0.05 unless 13 of 16 go the same way (12 of 16 is p = 0.077). "Not significant" here means "cannot tell",
//    not "equal".

enum Separation {

    /// Area under the ROC curve for "a `pos` value exceeds a `neg` value" — the Mann-Whitney U statistic over
    /// n1 x n2, with a tie counting one half. 0.5 is no separation, 1.0 is perfect, below 0.5 is the opposite
    /// direction to the one named. NaN when either side is empty.
    static func auc(_ pos: [Double], _ neg: [Double]) -> Double {
        guard !pos.isEmpty, !neg.isEmpty else { return .nan }
        let all = (pos.map { ($0, true) } + neg.map { ($0, false) }).sorted { $0.0 < $1.0 }
        var rankSumPos = 0.0
        var i = 0
        while i < all.count {
            var j = i
            while j + 1 < all.count && all[j + 1].0 == all[i].0 { j += 1 }
            let averageRank = Double(i + j) / 2 + 1
            for k in i...j where all[k].1 { rankSumPos += averageRank }
            i = j + 1
        }
        let n1 = Double(pos.count), n2 = Double(neg.count)
        return (rankSumPos - n1 * (n1 + 1) / 2) / (n1 * n2)
    }

    /// Cohen's d, `(mean a - mean b)` over the pooled sample standard deviation. NaN for fewer than two values
    /// on a side or a zero spread.
    static func cohenD(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count > 1, b.count > 1 else { return .nan }
        let va = sd(a), vb = sd(b)
        let pooledVariance = (Double(a.count - 1) * va * va + Double(b.count - 1) * vb * vb)
            / Double(a.count + b.count - 2)
        let pooled = pooledVariance.squareRoot()
        return pooled > 0 ? (mean(a) - mean(b)) / pooled : .nan
    }

    /// Exact two-sided binomial sign test over `positive` and `negative` counts (ties dropped by the caller):
    /// p = min(1, 2 * P(X >= max(positive, negative))), X ~ Binomial(positive + negative, 1/2). Same definition
    /// as `Tools/SleepBench`'s, so a p-value quoted from either bench means the same thing.
    static func signTestP(positive: Int, negative: Int) -> Double {
        let n = positive + negative
        guard n > 0 else { return 1 }
        let k = max(positive, negative)
        var tail = 0.0
        var coefficient = 1.0                       // C(n, 0)
        for i in 0...n {
            if i >= k { tail += coefficient }
            coefficient = coefficient * Double(n - i) / Double(i + 1)
        }
        return min(1, 2 * tail / pow(2, Double(n)))
    }

    /// Residuals of an ordinary-least-squares line `y = a + b x`. A zero-variance `x` leaves only the mean
    /// removed.
    static func residuals(y: [Double], x: [Double]) -> [Double] {
        precondition(y.count == x.count, "residuals: y and x must pair up")
        guard !y.isEmpty else { return [] }
        let mx = mean(x), my = mean(y)
        var sxy = 0.0, sxx = 0.0
        for i in y.indices { sxy += (x[i] - mx) * (y[i] - my); sxx += (x[i] - mx) * (x[i] - mx) }
        let slope = sxx > 0 ? sxy / sxx : 0
        return y.indices.map { y[$0] - (my + slope * (x[$0] - mx)) }
    }

    /// Residuals of an ordinary-least-squares fit of `y` on several covariates plus an intercept; `covariates[i]`
    /// is observation i's row. The normal equations are solved on centred columns by Gaussian elimination with
    /// partial pivoting; a singular system (a constant or collinear column) falls back to removing the mean.
    static func residuals(y: [Double], covariates: [[Double]]) -> [Double] {
        precondition(y.count == covariates.count, "residuals: y and covariates must pair up")
        guard !y.isEmpty else { return [] }
        let p = covariates[0].count
        let my = mean(y)
        guard p > 0 else { return y.map { $0 - my } }
        let means = (0..<p).map { j in covariates.reduce(0.0) { $0 + $1[j] } / Double(y.count) }
        // Augmented normal equations A | b over centred covariates and centred y.
        var m = [[Double]](repeating: [Double](repeating: 0, count: p + 1), count: p)
        for (row, yi) in zip(covariates, y) {
            for a in 0..<p {
                let xa = row[a] - means[a]
                for b in 0..<p { m[a][b] += xa * (row[b] - means[b]) }
                m[a][p] += xa * (yi - my)
            }
        }
        for col in 0..<p {
            var pivot = col
            for r in (col + 1)..<max(col + 1, p) where abs(m[r][col]) > abs(m[pivot][col]) { pivot = r }
            guard abs(m[pivot][col]) > 1e-12 else { return y.map { $0 - my } }
            m.swapAt(col, pivot)
            for r in 0..<p where r != col {
                let factor = m[r][col] / m[col][col]
                for c in col...p { m[r][c] -= factor * m[col][c] }
            }
        }
        let beta = (0..<p).map { m[$0][p] / m[$0][$0] }
        return zip(covariates, y).map { row, yi in
            yi - my - (0..<p).reduce(0.0) { $0 + beta[$1] * (row[$1] - means[$1]) }
        }
    }

    /// The 25th, 50th and 75th percentiles by linear interpolation between order statistics. NaNs for an
    /// empty input.
    static func quartiles(_ v: [Double]) -> (q1: Double, median: Double, q3: Double) {
        guard !v.isEmpty else { return (.nan, .nan, .nan) }
        let s = v.sorted()
        func at(_ p: Double) -> Double {
            let pos = p * Double(s.count - 1)
            let lo = Int(pos.rounded(.down)), hi = min(s.count - 1, lo + 1)
            return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
        }
        return (at(0.25), at(0.5), at(0.75))
    }
}
