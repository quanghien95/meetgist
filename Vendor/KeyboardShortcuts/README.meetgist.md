# MeetGist copy of KeyboardShortcuts

This directory starts from [KeyboardShortcuts 2.4.0](https://github.com/sindresorhus/KeyboardShortcuts/tree/2.4.0), revision `1aef85578fdd4f9eaeeb8d53b7b4fc31bf08fe27`, under its included MIT license.

MeetGist carries two source changes so SwiftPM can compile its app with the macOS 27 Command Line Tools, which do not ship the SwiftUI macro plugins:

- `@State` uses a distinct `CompatibleState` alias for the SDK's `SwiftUI.State` property wrapper.
- `Recorder.swift` omits three Xcode canvas previews. Runtime recorder behavior is unchanged.

Update this copy from upstream deliberately, retaining these changes until Apple's Command Line Tools provide the required macro plugins.
