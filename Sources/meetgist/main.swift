// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation
import AppKit
import MeetGistKit

let args = CommandLine.arguments

guard args.count >= 2, args[1] == "record" else {
    print("usage: meetgist record")
    exit(1)
}

// Phase-1 dual-file sync: earliest host-time anchor for the whole session.
let recordCommandStartHostNs = DispatchTime.now().uptimeNanoseconds

let fm = FileManager.default
let env = ProcessInfo.processInfo.environment

func nonEmpty(_ s: String?) -> String? {
    guard let s = s, !s.isEmpty else { return nil }
    return s
}

// Where recordings + transcripts are written. Set MEETGIST_OUTPUT_DIR to choose
// the location (meetgist-toggle.sh reads it from scripts/.env and exports it for
// us, because Shortcuts.app does not always set $HOME). Defaults to
// ~/Documents/meetgist.
let outputPath = nonEmpty(env["MEETGIST_OUTPUT_DIR"])
    ?? (NSHomeDirectory() as NSString).appendingPathComponent("Documents/meetgist")
let meetingsDir = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
try? fm.createDirectory(at: meetingsDir, withIntermediateDirectories: true)

let df = DateFormatter()
df.dateFormat = "yyyy-MM-dd-HHmm"
let stamp = df.string(from: Date())
let title = detectMeetingTitle()
let dirName = title.map { "\(stamp)-\($0)" } ?? stamp
let sessionDir = meetingsDir.appendingPathComponent(dirName)
try fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)

let systemURL = sessionDir.appendingPathComponent("system.m4a")
let micURL = sessionDir.appendingPathComponent("mic.m4a")

let systemRec = SystemAudioRecorder()
let micRec = MicRecorder()
var signalSources: [DispatchSourceSignal] = []

// Kick off recorders
Task {
    do {
        try await systemRec.start(outputURL: systemURL)
        try micRec.start(outputURL: micURL)
        FileHandle.standardOutput.write(Data("recording -> \(sessionDir.path)\n".utf8))
        await verifyCaptureOrExit()
    } catch {
        FileHandle.standardError.write(Data("start failed: \(error)\n".utf8))
        exit(2)
    }
}

// Signal handling: SIGINT or SIGTERM -> stop, postprocess, exit
var stopping = false
let stopLock = NSLock()

func handleStop() {
    stopLock.lock()
    if stopping { stopLock.unlock(); return }
    stopping = true
    stopLock.unlock()

    Task {
        let stopRequestedHostNs = DispatchTime.now().uptimeNanoseconds
        FileHandle.standardOutput.write(Data("stopping...\n".utf8))
        try? await systemRec.stop()
        micRec.stop()
        let stopCompletedHostNs = DispatchTime.now().uptimeNanoseconds

        // Write the Phase-1 dual-file sync sidecar before postprocess. A metadata
        // failure must never abort the recording — log and continue.
        let systemTiming = await systemRec.timing()
        let micTiming = micRec.timing()
        writeCaptureTiming(sessionDir: sessionDir,
                           recordStart: recordCommandStartHostNs,
                           stopRequested: stopRequestedHostNs,
                           stopCompleted: stopCompletedHostNs,
                           system: systemTiming, mic: micTiming)

        // Sanity-check file sizes and warn
        for (label, url) in [("system", systemURL), ("mic", micURL)] {
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size < 4096 {
                let msg = "warning: \(label).m4a is tiny (\(size) bytes) — likely a permission issue. " +
                          "Grant Screen Recording + Microphone to Terminal (or the binary) in System Settings.\n"
                FileHandle.standardError.write(Data(msg.utf8))
            }
        }

        launchPostprocess(sessionDir: sessionDir)
        exit(0)
    }
}

for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { handleStop() }
    src.resume()
    // Keep source alive via strong reference in global
    signalSources.append(src)
}

// Fail fast: confirm capture is actually flowing within the first few seconds,
// so a missing permission surfaces immediately instead of after a whole meeting
// is recorded silent. Only the system track hard-fails: a SCStream audio buffer
// arrives on a steady cadence the moment capture works (even during silence), so
// "no buffer" means a dead pipeline (Screen Recording denied), not a quiet room.
// A silent mic is legitimate (listen-only meeting), so it is a warning, not an exit.
func verifyCaptureOrExit() async {
    let deadlineSeconds = 4.0
    let stepNanos: UInt64 = 250_000_000
    var elapsed = 0.0
    var systemOK = false
    var micEverLive = false

    while elapsed < deadlineSeconds {
        try? await Task.sleep(nanoseconds: stepNanos)
        elapsed += 0.25
        if !systemOK { systemOK = await systemRec.hasReceivedAudio() }
        if micRec.peakLevel() > -100 { micEverLive = true }
        if systemOK && micEverLive { break }
    }

    // If the user already stopped within the window, don't second-guess it.
    if isStopping() { return }

    if !systemOK {
        let msg = "meetgist: no system audio after \(Int(deadlineSeconds))s — stopping. " +
                  "Grant Screen Recording to your terminal in System Settings > " +
                  "Privacy & Security > Screen Recording, then start again.\n"
        FileHandle.standardError.write(Data(msg.utf8))
        notify("Recording failed: no system audio. Enable Screen Recording permission, then retry.")
        exit(3)
    }

    if !micEverLive {
        let msg = "meetgist: warning — microphone level is at the floor (silent). " +
                  "If you expected your voice recorded, check Microphone permission or mute. " +
                  "Continuing; system audio is being captured.\n"
        FileHandle.standardError.write(Data(msg.utf8))
        notify("Mic looks silent — check Microphone permission. Still recording system audio.")
    }
}

func isStopping() -> Bool {
    stopLock.lock(); defer { stopLock.unlock() }
    return stopping
}

func notify(_ message: String) {
    let safe = message.replacingOccurrences(of: "\"", with: "'")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", "display notification \"\(safe)\" with title \"meetgist\""]
    try? task.run()
}

func resolveScriptsDir() -> String {
    // Explicit override wins (meetgist-toggle.sh sets this).
    if let s = nonEmpty(env["MEETGIST_SCRIPTS_DIR"]) { return s }
    // Otherwise derive from the running binary: <project>/.build/release/meetgist
    let exe = URL(fileURLWithPath: CommandLine.arguments[0])
    if exe.path.hasPrefix("/") {
        let root = exe.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidate = root.appendingPathComponent("scripts")
        if fm.fileExists(atPath: candidate.appendingPathComponent("postprocess.py").path) {
            return candidate.path
        }
    }
    // Last resort: scripts/ under the current working directory.
    return fm.currentDirectoryPath + "/scripts"
}

func launchPostprocess(sessionDir: URL) {
    let scriptsDir = resolveScriptsDir()
    let script = scriptsDir + "/postprocess.py"
    let venvPython = scriptsDir + "/.venv/bin/python3"
    let python = fm.fileExists(atPath: venvPython) ? venvPython : "/usr/bin/env python3"
    let log = sessionDir.path + "/postprocess.log"
    let cmd = "nohup \(python) \(shellQuote(script)) \(shellQuote(sessionDir.path)) > \(shellQuote(log)) 2>&1 &"
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", cmd]
    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        FileHandle.standardError.write(Data("postprocess launch failed: \(error)\n".utf8))
    }
}

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// Phase-1 dual-file sync: write capture_timing.json (schema in
// dual-file-sync-engineering-plan.md). Best-effort; never fails the recording.
func writeCaptureTiming(sessionDir: URL,
                        recordStart: UInt64,
                        stopRequested: UInt64,
                        stopCompleted: UInt64,
                        system: [String: Any],
                        mic: [String: Any]) {
    let payload: [String: Any] = [
        "schema_version": 1,
        "created_by": "meetgist",
        "session": [
            "session_dir": sessionDir.path,
            "record_command_start_host_ns": recordStart,
            "stop_requested_host_ns": stopRequested,
            "stop_completed_host_ns": stopCompleted,
        ],
        "system": system,
        "mic": mic,
    ]
    let url = sessionDir.appendingPathComponent("capture_timing.json")
    do {
        let data = try JSONSerialization.data(withJSONObject: payload,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    } catch {
        FileHandle.standardError.write(
            Data("warning: capture_timing.json not written: \(error)\n".utf8))
    }
}

dispatchMain()
