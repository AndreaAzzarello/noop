import XCTest
import WhoopProtocol
@testable import sleeppsg

/// The separation statistics, pinned by hand, and the MIT-BIH loader checked on small synthetic exports. No
/// dataset and no database is read: every file here is written to a temporary directory by the test.
final class RRStageTests: XCTestCase {

    // MARK: - Statistics

    func testAUCOnAHandComputedCase() {
        // pos [1, 2, 3] against neg [0, 2]: pairs 1>0, 1<2, 2>0, 2=2 (half), 3>0, 3>2 -> 4.5 / 6.
        XCTAssertEqual(Separation.auc([1, 2, 3], [0, 2]), 0.75, accuracy: 1e-12)
        XCTAssertEqual(Separation.auc([0, 2], [1, 2, 3]), 0.25, accuracy: 1e-12)
        XCTAssertEqual(Separation.auc([5, 6], [1, 2]), 1.0, accuracy: 1e-12)
        XCTAssertEqual(Separation.auc([1, 1], [1, 1]), 0.5, accuracy: 1e-12)
        XCTAssertTrue(Separation.auc([], [1]).isNaN)
    }

    func testCohenDOnAHandComputedCase() {
        // a = [1, 2, 3], b = [2, 3, 4]: both sample sd 1, so pooled 1, and the means differ by -1.
        XCTAssertEqual(Separation.cohenD([1, 2, 3], [2, 3, 4]), -1.0, accuracy: 1e-12)
        XCTAssertEqual(Separation.cohenD([2, 3, 4], [1, 2, 3]), 1.0, accuracy: 1e-12)
        XCTAssertTrue(Separation.cohenD([1, 1, 1], [1, 1, 1]).isNaN)
        XCTAssertTrue(Separation.cohenD([1], [1, 2]).isNaN)
    }

    func testSignTestMatchesTheBinomialTail() {
        // 5 of 5: 2 * (1 / 32) = 0.0625.  9 of 10: 2 * (1 + 10) / 1024.  A 50/50 split is p = 1.
        XCTAssertEqual(Separation.signTestP(positive: 5, negative: 0), 0.0625, accuracy: 1e-12)
        XCTAssertEqual(Separation.signTestP(positive: 1, negative: 9), 22.0 / 1024.0, accuracy: 1e-12)
        XCTAssertEqual(Separation.signTestP(positive: 4, negative: 4), 1.0, accuracy: 1e-12)
        XCTAssertEqual(Separation.signTestP(positive: 0, negative: 0), 1.0, accuracy: 1e-12)
        // 16 patients: 12 of 16 is p = 2 * 2517 / 65536 = 0.0768, so 13 of 16 (p = 0.0213) is the first split a
        // two-sided 0.05 test rejects.
        XCTAssertEqual(Separation.signTestP(positive: 12, negative: 4), 2.0 * 2517.0 / 65536.0, accuracy: 1e-12)
        XCTAssertGreaterThan(Separation.signTestP(positive: 12, negative: 4), 0.05)
        XCTAssertLessThan(Separation.signTestP(positive: 13, negative: 3), 0.05)
    }

    func testResidualsOfAPerfectLineAreZeroAndOfAnOffsetAreTheOffset() {
        let x = [0.0, 1, 2, 3, 4]
        for r in Separation.residuals(y: x.map { 2 * $0 + 1 }, x: x) { XCTAssertEqual(r, 0, accuracy: 1e-12) }
        // A constant x leaves only the mean removed.
        XCTAssertEqual(Separation.residuals(y: [1, 2, 3], x: [7, 7, 7]), [-1, 0, 1])
        XCTAssertEqual(Separation.residuals(y: [], x: []), [])
    }

    func testMultivariateResidualsRemoveAnExactLinearCombination() {
        // y = 1 + 2 x1 - 3 x2: nothing is left once both covariates are regressed out.
        let rows: [[Double]] = [[0, 1], [1, 0], [2, 3], [3, 1], [4, 5], [5, 2], [6, 7]]
        let y = rows.map { 1 + 2 * $0[0] - 3 * $0[1] }
        for r in Separation.residuals(y: y, covariates: rows) { XCTAssertEqual(r, 0, accuracy: 1e-9) }
        // Noise orthogonal to the covariates survives: x2 is regressed out, the pure x1 part remains.
        let withOffset = zip(rows, y).map { $1 + ($0[0] == 3 ? 5 : 0) }
        let res = Separation.residuals(y: withOffset, covariates: rows)
        XCTAssertGreaterThan(res.map { abs($0) }.max() ?? 0, 1)
        // A collinear pair of columns degrades to removing the mean instead of dividing by zero.
        let collinear = rows.map { [$0[0], 2 * $0[0]] }
        XCTAssertEqual(Separation.residuals(y: [1, 2, 3, 4, 5, 6, 7], covariates: collinear).reduce(0, +), 0, accuracy: 1e-9)
        XCTAssertEqual(Separation.residuals(y: [], covariates: []), [])
    }

    func testQuartilesInterpolate() {
        let q = Separation.quartiles([1, 2, 3, 4, 5])
        XCTAssertEqual(q.q1, 2, accuracy: 1e-12)
        XCTAssertEqual(q.median, 3, accuracy: 1e-12)
        XCTAssertEqual(q.q3, 4, accuracy: 1e-12)
        XCTAssertEqual(Separation.quartiles([1, 2]).median, 1.5, accuracy: 1e-12)
    }

    // MARK: - Expectation table

    func testTheRecipesExpectationsPerFeature() {
        XCTAssertEqual(SepFeature.lnRmssd.expectedHigher("deep", "rem"), "deep")
        XCTAssertEqual(SepFeature.lnLfHf.expectedHigher("deep", "rem"), "rem")
        XCTAssertEqual(SepFeature.hr.expectedHigher("deep", "rem"), "rem")
        XCTAssertEqual(SepFeature.respReg.expectedHigher("rem", "deep"), "deep")
        XCTAssertEqual(SepFeature.lnRmssd.expectedHigher("rem", "light"), "light")
        XCTAssertEqual(SepFeature.lnLfHf.expectedHigher("rem", "light"), "rem")
        // The recipe gives heart rate no push on deep or light, so it assumes nothing about that pair.
        XCTAssertNil(SepFeature.hr.expectedHigher("deep", "light"))
    }

    // MARK: - Loader

    private func writeExport(id: String, beats: String, stages: String) throws -> String {
        let dir = NSTemporaryDirectory() + "rrstage-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try beats.write(toFile: dir + "/\(id).beats.csv", atomically: true, encoding: .utf8)
        try stages.write(toFile: dir + "/\(id).stages.csv", atomically: true, encoding: .utf8)
        return dir
    }

    func testSubjectGroupsSegmentsAndKeepsTheXRecord() {
        func subject(_ id: String) -> String { SlpdbRecord(id: id, beats: [], epochs: [:]).subject }
        XCTAssertEqual(subject("slp01a"), "slp01")
        XCTAssertEqual(subject("slp01b"), "slp01")
        XCTAssertEqual(subject("slp02b"), "slp02")
        XCTAssertEqual(subject("slp03"), "slp03")
        XCTAssertEqual(subject("slp67x"), "slp67x")
    }

    func testLoaderMapsStagesAndFlagsRespiratoryEventsOnly() throws {
        let dir = try writeExport(
            id: "slpTest",
            beats: "t_s,symbol\r\n0.0000,N\r\n1.0000,N\r\n",
            stages: "epoch_start_s,stage,events\r\n0,W,\r\n30,1,OA\r\n60,2,LA\r\n90,3,\"H,LA\"\r\n120,R,\r\n150,MT,\r\n180,4,X\r\n")
        let rec = try XCTUnwrap(SlpdbRecord.load(dir: dir, id: "slpTest"))
        XCTAssertEqual(rec.beats.count, 2)
        XCTAssertEqual(rec.epochs[0]?.stage, "wake")
        XCTAssertEqual(rec.epochs[30]?.stage, "light")
        XCTAssertEqual(rec.epochs[90]?.stage, "deep")
        XCTAssertEqual(rec.epochs[120]?.stage, "rem")
        XCTAssertEqual(rec.epochs[180]?.stage, "deep")
        XCTAssertNil(rec.epochs[150]?.stage, "movement time is unscored, not wake")
        XCTAssertEqual(rec.epochs[30]?.respiratoryEvent, true)       // OA
        XCTAssertEqual(rec.epochs[60]?.respiratoryEvent, false)      // LA is a leg movement with arousal
        XCTAssertEqual(rec.epochs[90]?.respiratoryEvent, true)       // H, in a quoted field with a comma
        XCTAssertEqual(rec.epochs[120]?.respiratoryEvent, false)
        XCTAssertEqual(rec.epochs[180]?.respiratoryEvent, true)      // X
        XCTAssertEqual(SlpdbRecord.ids(in: dir), ["slpTest"])
    }

    func testRecipeStreamsKeepEveryInterval() {
        let rec = SlpdbRecord(id: "r", beats: [(0.0, "N"), (1.0, "N"), (1.8, "V"), (2.7, "N")], epochs: [:])
        let s = rec.recipeStreams()
        XCTAssertEqual(s.rr.map { $0.rrMs }, [1000, 800, 900])
        XCTAssertEqual(s.rr.map { $0.ts }, [SleepAccel.timeBase + 1, SleepAccel.timeBase + 1, SleepAccel.timeBase + 2])
        XCTAssertEqual(s.hr.map { $0.bpm }, [60, 75, 67])
    }

    // MARK: - End to end through the recipe's own extraction

    /// 20 minutes of alternating 980 / 1020 ms intervals have successive differences of exactly 40 ms, so
    /// RMSSD is 40 ms and ln RMSSD ln 40, in every epoch whose window holds enough beats. The test is that the
    /// loader's time bucketing reaches the recipe's window the way the recipe expects.
    func testFeaturesReadTheKnownRMSSD() throws {
        var t = 0.0
        var beats = "t_s,symbol\r\n"
        var i = 0
        while t < 1200 {
            beats += String(format: "%.4f,N\r\n", t)
            t += (i % 2 == 0 ? 0.98 : 1.02)
            i += 1
        }
        var stages = "epoch_start_s,stage,events\r\n"
        for e in 0..<40 { stages += "\(e * 30),\(e < 20 ? "2" : "R"),\r\n" }
        let dir = try writeExport(id: "slpSynth", beats: beats, stages: stages)
        let rec = try XCTUnwrap(SlpdbRecord.load(dir: dir, id: "slpSynth"))
        let feats = rec.features()
        XCTAssertFalse(feats.isEmpty)
        let middle = feats.filter { $0.minutes >= 5 && $0.minutes <= 15 }
        XCTAssertFalse(middle.isEmpty)
        for e in middle {
            XCTAssertEqual(try XCTUnwrap(e.lnRmssd), log(40.0), accuracy: 0.01)
            XCTAssertEqual(try XCTUnwrap(e.hr), 60.0, accuracy: 1.5)
            XCTAssertTrue(e.eventFree)
            XCTAssertEqual(e.eventEpochs, 0)
        }
        XCTAssertEqual(middle.first?.stage, "light")
        XCTAssertEqual(feats.last?.stage, "rem")
    }

    // MARK: - Contrast

    func testContrastNeedsEnoughEpochsAndOrientsToTheRecipe() {
        func epoch(_ stage: String, _ rmssd: Double, record: String = "r", minutes: Double = 0) -> RRStageEpoch {
            RRStageEpoch(subject: "s", record: record, minutes: minutes, stage: stage, eventEpochs: 0,
                         lnRmssd: rmssd, lnLfHf: nil, hr: nil, hrVar: nil, respReg: nil)
        }
        // Deep reads higher RMSSD than REM in every pair: AUC 1 in the recipe's direction.
        let eps = (0..<25).map { epoch("deep", 4.0 + Double($0) * 0.01) } + (0..<25).map { epoch("rem", 3.0 + Double($0) * 0.01) }
        let c = RRStageAnalysis.contrast(.lnRmssd, .all, "deep", "rem", subject: "s", eps)
        XCTAssertEqual(c?.auc ?? .nan, 1.0, accuracy: 1e-12)
        XCTAssertGreaterThan(c?.d ?? 0, 5)
        // LF/HF is absent in these epochs, so there is nothing to measure.
        XCTAssertNil(RRStageAnalysis.contrast(.lnLfHf, .all, "deep", "rem", subject: "s", eps))
        // Fewer than `minEpochs` on one side leaves the patient out.
        XCTAssertNil(RRStageAnalysis.contrast(.lnRmssd, .all, "deep", "rem", subject: "s", Array(eps.prefix(30))))
    }

    func testTimeDetrendingRemovesAPureClockEffect() {
        // The feature falls linearly with time; deep is early and REM is late, so the raw AUC says deep > REM
        // with certainty. Once the trend is removed nothing is left to separate them.
        func epoch(_ stage: String, _ m: Double) -> RRStageEpoch {
            RRStageEpoch(subject: "s", record: "r", minutes: m, stage: stage, eventEpochs: 0,
                         lnRmssd: 6 - 0.01 * m, lnLfHf: nil, hr: nil, hrVar: nil, respReg: nil)
        }
        let eps = (0..<30).map { epoch("deep", Double($0)) } + (0..<30).map { epoch("rem", 100 + Double($0)) }
        XCTAssertEqual(RRStageAnalysis.contrast(.lnRmssd, .all, "deep", "rem", subject: "s", eps)?.auc ?? .nan, 1.0, accuracy: 1e-12)
        let detrended = RRStageAnalysis.contrast(.lnRmssd, .timeDetrended, "deep", "rem", subject: "s", eps)
        XCTAssertEqual(detrended?.auc ?? .nan, 0.5, accuracy: 0.05)
    }
}
