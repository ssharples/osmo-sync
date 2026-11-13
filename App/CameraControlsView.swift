import OsmoSyncCore
import SwiftUI

/// Pan, tilt and zoom for the Pocket. Drag inside the pad like a joystick: the further from
/// the middle, the faster it turns. Arrow keys work while the pad has focus.
struct CameraControlsView: View {
    @ObservedObject var camera: OsmoCamera
    @State private var knob = CGSize.zero
    @State private var keys: Set<KeyEquivalent> = []
    @State private var zoom = 1.0
    @FocusState private var focused: Bool

    private let size: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Aim").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Recentre") { camera.recentreGimbal() }
                    .font(.caption)
            }
            HStack(alignment: .center, spacing: 14) {
                pad
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "Zoom %.1f×", zoom)).font(.caption).monospacedDigit()
                    Slider(value: $zoom, in: Zoom.range, step: 0.5) { editing in
                        if !editing { camera.setZoom(zoom) }
                    }
                    HStack {
                        ForEach([1.0, 2.0, 3.0, 6.0], id: \.self) { z in
                            Button("\(Int(z))×") { zoom = z; camera.setZoom(z) }
                                .font(.caption2)
                        }
                    }
                    Text("Drag the pad or use the arrow keys")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if !camera.canControl {
                Text("Needs the camera on Wi-Fi.").font(.caption).foregroundStyle(.orange)
            }
        }
        .onAppear { zoom = camera.zoomFactor }
        .onDisappear { camera.steer(pan: 0, tilt: 0) }
    }

    private var pad: some View {
        ZStack {
            Circle().fill(.quaternary)
            Circle().stroke(focused ? Color.accentColor : .secondary.opacity(0.4), lineWidth: 1)
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.caption2).foregroundStyle(.tertiary)
            Circle().fill(Color.accentColor)
                .frame(width: 26, height: 26)
                .offset(knob)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let r = size / 2
                    var d = CGSize(width: g.location.x - r, height: g.location.y - r)
                    let len = hypot(d.width, d.height)
                    if len > r { d = CGSize(width: d.width * r / len, height: d.height * r / len) }
                    knob = d
                    camera.steer(pan: Double(d.width / r), tilt: Double(-d.height / r))
                }
                .onEnded { _ in
                    withAnimation(.spring(duration: 0.2)) { knob = .zero }
                    camera.steer(pan: 0, tilt: 0)
                }
        )
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onTapGesture { focused = true }
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow], phases: [.down, .repeat, .up]) { press in
            if press.phase == .up { keys.remove(press.key) } else { keys.insert(press.key) }
            let pan = (keys.contains(.rightArrow) ? 0.6 : 0) - (keys.contains(.leftArrow) ? 0.6 : 0)
            let tilt = (keys.contains(.upArrow) ? 0.6 : 0) - (keys.contains(.downArrow) ? 0.6 : 0)
            let r = size / 2
            knob = CGSize(width: pan * r, height: -tilt * r)
            camera.steer(pan: pan, tilt: tilt)
            return .handled
        }
    }
}
