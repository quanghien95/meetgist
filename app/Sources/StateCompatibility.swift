import SwiftUI

// SwiftUI's State property wrapper remains available in the macOS 27 SDK.
// Use a distinct name so CLT builds do not select its unavailable State macro.
typealias CompatibleState<Value> = SwiftUI.State<Value>
