import SwiftUI
import DiggerKit

@main
struct DiggerApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Digger \(DiggerKit.version)")
                .frame(minWidth: 520, minHeight: 640)
        }
        .windowResizability(.contentSize)
    }
}
