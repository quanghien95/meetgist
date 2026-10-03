import SwiftUI

// The macOS 27 Command Line Tools omit the SwiftUIMacros host plugin.
// This name resolves to SwiftUI's compatible property wrapper instead.
typealias CompatibleState<Value> = SwiftUI.State<Value>
