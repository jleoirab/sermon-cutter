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

    func testSundaysMoveIntoTheAppsFolder() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let old = root.appendingPathComponent("Movies/SermonCutter")
        let new = root.appendingPathComponent("Library/Application Support/CCI Sermon Cutter/Work")
        try fm.createDirectory(at: old.appendingPathComponent("models"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var s = Sunday(url: "https://www.youtube.com/watch?v=iz0PPVUleUw")
        s.audioFile = old.appendingPathComponent("iz0PPVUleUw.audio.m4a").path
        s.bannerPath = "/Users/me/Documents/CCIKW/Service/banner.png"
        try Folders(work: old, service: old).save(s)
        for name in ["iz0PPVUleUw.audio.m4a", "iz0PPVUleUw.video.mp4.part", "Oct 11 test.mp4", "models/model.bin"] {
            try Data("x".utf8).write(to: old.appendingPathComponent(name))
        }
        XCTAssertEqual(Folders.moveSundays(from: old, to: new), 1)
        let moved = try XCTUnwrap(Folders(work: new, service: new).load("iz0PPVUleUw"))
        XCTAssertEqual(moved.audioFile, new.appendingPathComponent("iz0PPVUleUw.audio.m4a").path)
        XCTAssertEqual(moved.bannerPath, s.bannerPath)
        XCTAssertTrue(fm.fileExists(atPath: new.appendingPathComponent("iz0PPVUleUw.video.mp4.part").path))
        // What isn't a Sunday's stays put.
        XCTAssertTrue(fm.fileExists(atPath: old.appendingPathComponent("Oct 11 test.mp4").path))
        XCTAssertTrue(fm.fileExists(atPath: old.appendingPathComponent("models/model.bin").path))
        XCTAssertEqual(Folders.moveSundays(from: old, to: new), 0)
    }

    func testDriveLinks() {
        XCTAssertEqual(DriveLink.fileID("https://drive.google.com/file/d/1AbC_x-9/view?usp=sharing"), "1AbC_x-9")
        XCTAssertEqual(DriveLink.fileID("https://drive.google.com/open?id=1AbC"), "1AbC")
        XCTAssertNil(DriveLink.fileID("https://example.com/file/d/1AbC/view"))
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

    func testServiceTitles() {
        let t = ServiceTitle("YOUR MOUNTAIN | 1ST SERVICE | 11TH OCTOBER 2026 | CELEBRATION CHURCH INT'L")
        XCTAssertEqual(t.sermon, "Your Mountain")
        XCTAssertEqual(t.service, "1st service")
        let m = ServiceTitle("WHAT IS THE ECCLESIA?  | MDWK SERVICE | 7TH OCTOBER, 2026 | CELEBRATION CHURCH INT'L")
        XCTAssertEqual(m.sermon, "What Is the Ecclesia?")
        XCTAssertEqual(m.service, "Midweek")
        XCTAssertEqual(t.date, Naming.date(fromYYYYMMDD: "20261011"))
        XCTAssertEqual(m.date, Naming.date(fromYYYYMMDD: "20261007"))
        XCTAssertEqual(ServiceTitle("SPECIAL MDWK SERVICE WITH APOSTLE EMMANUEL IREN | 21ST OCTOBER 2026").sermon, "Special Midweek Service with Apostle Emmanuel Iren")
        XCTAssertEqual(ServiceTitle("A plain title").sermon, "A plain title")
        XCTAssertNil(ServiceTitle("A plain title").service)
    }

    func testPicksThisSunday() {
        let s = [
            StreamEntry(id: "w", title: "MIDWEEK | MDWK SERVICE", url: "", uploadDate: "20261021"),
            StreamEntry(id: "b", title: "THE TOXIC CHURCH | 2ND SERVICE", url: "", uploadDate: "20261018"),
            StreamEntry(id: "a", title: "THE TOXIC CHURCH | 1ST SERVICE", url: "", uploadDate: "20261018"),
            StreamEntry(id: "o", title: "YOUR MOUNTAIN | 1ST SERVICE", url: "", uploadDate: "20261011"),
        ]
        XCTAssertEqual(StreamPicker.thisSunday(s)?.id, "a")
        XCTAssertEqual(StreamPicker.thisSunday([s[0]])?.id, "w")
        // The channel listing often has no upload date; the title's date counts.
        let undated = [
            StreamEntry(id: "w", title: "MIDWEEK | MDWK SERVICE | 21ST OCTOBER 2026", url: ""),
            StreamEntry(id: "a", title: "THE TOXIC CHURCH | 1ST SERVICE | 18TH OCTOBER 2026", url: ""),
        ]
        XCTAssertEqual(StreamPicker.thisSunday(undated)?.id, "a")
        XCTAssertNil(StreamPicker.thisSunday([]))
    }

    func testShortTimesAndDates() {
        XCTAssertEqual(Timecode.long(10044), "2 h 47 min")
        XCTAssertEqual(Timecode.long(3289), "55 min")
        XCTAssertEqual(Timecode.long(7200), "2 h")
        let d = Naming.date(fromYYYYMMDD: "20261011")!
        XCTAssertEqual(Naming.monthDay(d), "Oct 11")
        XCTAssertEqual(Naming.display(d), "Oct 11, 2026")
        XCTAssertTrue(Naming.isSunday(d))
        XCTAssertEqual(Naming.weekday(Naming.date(fromYYYYMMDD: "20261021")!), "Wednesday")
    }

    func testTranscriptAroundTheEnd() throws {
        let json = #"{"covered":[[8900.0,9000.0]],"words":[{"start":8950.0,"end":8950.4,"text":"Please"},{"start":8950.4,"end":8950.6,"text":"be"},{"start":8950.6,"end":8951.0,"text":"seated."},{"start":8952.0,"end":8952.5,"text":"Thank"}]}"#
        let t = try JSONDecoder().decode(Transcript.self, from: Data(json.utf8))
        let a = t.around(8951.0)
        XCTAssertEqual(a.before.map(\.text), ["Please", "be", "seated."])
        XCTAssertEqual(a.after.map(\.text), ["Thank"])
    }

    func testSelfCheckInPlainWords() {
        let v = VerifyReport(passed: false, checks: [
            VerifyCheck(name: "length", passed: true, detail: "ok"),
            VerifyCheck(name: "banner at start", passed: true, detail: "ok"),
            VerifyCheck(name: "banner at end", passed: false, detail: "SSIM 0.2"),
            VerifyCheck(name: "quiet start", passed: true, detail: "ok"),
            VerifyCheck(name: "quiet end", passed: true, detail: "ok"),
        ])
        let lines = v.lines(length: 4424)
        XCTAssertEqual(lines.map(\.text), ["The right length: 1:13:44", "The banner is on at both ends", "Quiet at the very start and end"])
        XCTAssertEqual(lines.map(\.passed), [true, false, true])
        XCTAssertEqual(lines[1].detail, "SSIM 0.2")
    }
}
