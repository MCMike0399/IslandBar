// The bits of Scripts/harness that the shell cannot do by itself. Compiled once into
// .build/harness/harness-tool (a `swift -e` per call costs seconds).
//
//   harness-tool post <notification name> [object]   post a distributed notification
//   harness-tool windows <owner name>                 on-screen windows: id x y w h layer
import AppKit
import Foundation

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "post" where args.count >= 2:
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name(args[1]),
        object: args.count >= 3 ? args[2] : nil,
        userInfo: nil,
        deliverImmediately: true
    )
case "windows" where args.count == 2:
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in list where window[kCGWindowOwnerName as String] as? String == args[1] {
        guard let id = window[kCGWindowNumber as String] as? Int,
              let b = window[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
        let layer = window[kCGWindowLayer as String] as? Int ?? 0
        print(id, Int(b["X"] ?? 0), Int(b["Y"] ?? 0), Int(b["Width"] ?? 0), Int(b["Height"] ?? 0), layer)
    }
default:
    FileHandle.standardError.write(Data("usage: harness-tool post <name> [object] | windows <owner>\n".utf8))
    exit(2)
}
