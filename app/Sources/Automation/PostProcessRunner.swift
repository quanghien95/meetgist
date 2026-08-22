// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import MeetGistKit

/// Runs user-authored Python after a meeting's canonical outputs are complete.
/// The source is intentionally local-only; output is retained with the meeting.
enum PostProcessRunner {
    static let outputFile = "postprocess-output.md"

    static func run(source: String, meeting: Meeting) throws -> String {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("meetgist-postprocess-\(UUID().uuidString).py")
        defer { try? fm.removeItem(at: temp) }
        try source.write(to: temp, atomically: true, encoding: .utf8)

        let values = placeholders(for: meeting)
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in values { environment["MEETGIST_\(key.uppercased())"] = value }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = [temp.path]
        task.environment = environment
        let stdout = Pipe(), stderr = Pipe()
        task.standardOutput = stdout; task.standardError = stderr
        try task.run()
        task.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let result = "# Post-process result\n\nExit status: \(task.terminationStatus)\n\n## stdout\n\n```text\n\(out)\n```\n\n## stderr\n\n```text\n\(err)\n```\n"
        try result.write(to: meeting.dir.appendingPathComponent(outputFile), atomically: true, encoding: .utf8)
        guard task.terminationStatus == 0 else {
            throw NSError(domain: "MeetGist.PostProcess", code: Int(task.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Post-process script exited with status \(task.terminationStatus)."])
        }
        return result
    }

    static func placeholders(for meeting: Meeting) -> [String: String] {
        let dir = meeting.dir
        let date = meeting.date?.ISO8601Format() ?? ""
        return [
            "meeting_dir": dir.path,
            "recording_path": dir.appendingPathComponent("system.m4a").path,
            "microphone_path": dir.appendingPathComponent("mic.m4a").path,
            "transcript": MeetingStore.markdown("transcript.md", in: dir) ?? "",
            "minutes": MeetingStore.markdown("polished.md", in: dir) ?? "",
            "summary": MeetingStore.markdown("summary.md", in: dir) ?? "",
            "meeting_title": meeting.title,
            "meeting_date": date,
            "meeting_id": meeting.id,
        ]
    }
}
