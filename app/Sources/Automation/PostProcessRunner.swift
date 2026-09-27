// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import MeetGistKit

/// Runs user-authored Python after a meeting's canonical outputs are complete.
/// The source is intentionally local-only; output is retained with the meeting.
enum PostProcessRunner {
    static let outputFile = "postprocess-output.md"
    /// Generous but bounded — a hung or runaway user script must not block the
    /// app's `.processing` state forever. See P0-4.
    static let timeoutSeconds: TimeInterval = 10 * 60

    static func run(source: String, meeting: Meeting) async throws -> String {
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

        // ChildProcess drains stdout/stderr concurrently while the process
        // runs (no waitUntilExit()-before-draining deadlock), supports Task
        // cancellation, and enforces the timeout above.
        let result = try await ChildProcess.run(task, timeout: timeoutSeconds)
        let out = String(decoding: result.stdout, as: UTF8.self)
        let err = String(decoding: result.stderr, as: UTF8.self)
        let outNote = result.stdoutTruncated ? "\n… (truncated)" : ""
        let errNote = result.stderrTruncated ? "\n… (truncated)" : ""
        var body = "# Post-process result\n\nExit status: \(result.status)\n\n## stdout\n\n```text\n\(out)\(outNote)\n```\n\n## stderr\n\n```text\n\(err)\(errNote)\n```\n"
        if result.timedOut { body += "\n_Timed out after \(Int(timeoutSeconds))s and was stopped._\n" }
        try body.write(to: meeting.dir.appendingPathComponent(outputFile), atomically: true, encoding: .utf8)
        guard !result.timedOut, result.status == 0 else {
            let message = result.timedOut
                ? "Post-process script timed out after \(Int(timeoutSeconds))s and was stopped."
                : "Post-process script exited with status \(result.status)."
            throw NSError(domain: "MeetGist.PostProcess", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: message])
        }
        return body
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
