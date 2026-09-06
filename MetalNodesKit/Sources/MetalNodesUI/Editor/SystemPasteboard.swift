import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
public final class SystemPasteboard: Pasteboarding {
    public init() {}

    public func write(_ data: Data, type: String) {
        #if os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: NSPasteboard.PasteboardType(type))
        #else
        UIPasteboard.general.setData(data, forPasteboardType: type)
        #endif
    }

    public func read(type: String) -> Data? {
        #if os(macOS)
        NSPasteboard.general.data(forType: NSPasteboard.PasteboardType(type))
        #else
        UIPasteboard.general.data(forPasteboardType: type)
        #endif
    }
}
