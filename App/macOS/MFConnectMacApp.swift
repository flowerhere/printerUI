import SwiftUI

@main
struct MFConnectMacApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(model)
        } label: {
            // 有待核准工作時換成醒目的圖示
            Image(systemName: model.pendingJobs.isEmpty ? "printer" : "printer.filled.and.paper")
        }
        .menuBarExtraStyle(.window)

        Window("MFConnect 設定", id: "settings") {
            SettingsView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
