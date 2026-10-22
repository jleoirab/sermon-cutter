import XCTest
@testable import SermonCutterCore

final class CoreTests: XCTestCase {
    func testNamesMatchTheServiceFolder() {
        let d = Naming.date(fromYYYYMMDD: "20260913")!
        XCTAssertEqual(Naming.folderName(d), "Sept 13th 2026")
        XCTAssertEqual(Naming.fileName(Naming.date(fromYYYYMMDD: "20261011")!), "Oct 11th Sermon.mp4")
        XCTAssertEqual(Naming.ordinal(1), "1st")
        XCTAssertEqual(Naming.ordinal(22), "22nd")
        XCTAssertEqual(Naming.ordinal(13), "13th")
    }

    func testVideoIDs() {
        XCTAssertEqual(Sunday.videoID(from: "https://www.youtube.com/watch?v=iz0PPVUleUw"), "iz0PPVUleUw")
        XCTAssertEqual(Sunday.videoID(from: "https://youtu.be/iz0PPVUleUw?t=4"), "iz0PPVUleUw")
        XCTAssertEqual(Sunday.videoID(from: "https://www.youtube.com/live/iz0PPVUleUw"), "iz0PPVUleUw")
        XCTAssertNil(Sunday.videoID(from: "hello"))
    }

    func testDecodesEngineResults() throws {
        let find = #"{"event":"result","step":"find","data":{"in":4296.0,"in_tc":"1:11:36.000","out":8959.18,"out_tc":"2:29:19.180","lead_in":360.0,"preacher_starts":4658,"preacher_starts_tc":"1:17:38.000","start_confidence":"high","out_confidence":"medium","out_method":"seat_cue","out_cue":{"at":8953.7,"out":8959.18,"context":"God bless you. Please be seated. Thank you Jesus.","after_prayer":true,"before_offering":false,"before_next_part":true},"cues":[],"speech_run_ends":10044,"speech_run_ends_tc":"2:47:24.000","speech_seconds":4000,"dead_air_seconds":0,"heard":[6158.0,9158.0],"stream_seconds":10044.0,"runs":[{"start":0,"end":60,"kind":"music"}]}}"#
        let run = EngineRun(results: ["find": Data(find.utf8)])
        let f = try run.result("find", as: FindResult.self)
        XCTAssertEqual(f.cutIn, 4296)
        XCTAssertEqual(f.outCue?.afterPrayer, true)
        XCTAssertEqual(f.runs.first?.kind, "music")

        let check = #"{"event":"result","step":"check","data":{"verdict":"not_usable","headline":"Not usable: use a different stream","reasons":["x"],"cut_in":5174.0,"cut_out":9963.0,"sound_lost":991.0,"picture_lost":764.0,"video_checked":true,"issues":[{"kind":"dead_air","what":"no sound","start":6352.0,"end":6383.0,"len":31.0,"into_cut":1178.0,"into_cut_tc":"19:38","stream_tc":"1:45:52"}],"minutes":["good","bad"],"note":"Heads up","in_tc":"1:26:14.000","out_tc":"2:46:03.000"}}"#
        let q = try EngineRun(results: ["check": Data(check.utf8)]).result("check", as: QualityReport.self)
        XCTAssertEqual(q.issues.first?.intoCutTc, "19:38")
        XCTAssertTrue(q.issues.first!.isSound)
    }

    func testEventLines() throws {
        let e = try Engine.decoder.decode(EngineEvent.self, from: Data(#"{"event":"progress","step":"render","fraction":0.42,"eta_s":51.2}"#.utf8))
        XCTAssertEqual(e.etaS, 51.2)
        XCTAssertEqual(Engine.number(8.0), "8")
        XCTAssertEqual(Engine.number(0.5), "0.5")
    }
}
