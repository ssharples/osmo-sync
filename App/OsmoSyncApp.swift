import SwiftUI

@main
struct OsmoSyncApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model, camera: model.camera)
        } label: {
            MenuBarIcon(model: model, camera: model.camera)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarIcon: View {
    @ObservedObject var model: AppModel
    @ObservedObject var camera: OsmoCamera

    var body: some View {
        if camera.isRecording {
            Image(systemName: "record.circle.fill").symbolRenderingMode(.multicolor)
        } else if camera.state.isReady {
            Image(systemName: "video.fill")
        } else {
            Image(systemName: "video.slash")
        }
    }
}
