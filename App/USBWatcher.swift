import Foundation
import IOKit
import IOKit.usb
import OsmoSyncCore

/// Calls `onPocket` when an Osmo Pocket is plugged into the Mac over USB.
@MainActor
final class USBWatcher {
    var onPocket: ((String) -> Void)?
    private var port: IONotificationPortRef?
    private var iterator: io_iterator_t = 0

    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let match = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        match["idVendor"] = PocketUSB.djiVendorID
        let me = Unmanaged.passUnretained(self).toOpaque()
        let added: IOServiceMatchingCallback = { ctx, it in
            guard let ctx else { return }
            let watcher = Unmanaged<USBWatcher>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.drain(it, announce: true) }
        }
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, match, added, me, &iterator)
        // Empty the iterator to arm it. Devices already plugged in at launch aren't news.
        drain(iterator, announce: false)
    }

    private func drain(_ it: io_iterator_t, announce: Bool) {
        while true {
            let device = IOIteratorNext(it)
            guard device != 0 else { break }
            defer { IOObjectRelease(device) }
            let name = IORegistryEntryCreateCFProperty(device, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            if announce, PocketUSB.isPocket(vendorID: PocketUSB.djiVendorID, productName: name) { onPocket?(name ?? "Osmo Pocket") }
        }
    }
}
