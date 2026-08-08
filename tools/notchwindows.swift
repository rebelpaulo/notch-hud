import CoreGraphics
import Foundation
// Lists on-screen windows owned by Vibenotch: bounds + layer. For the safety eval.
let opts: CGWindowListOption = [.optionOnScreenOnly]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { exit(1) }
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    guard owner.contains("Vibenotch") else { continue }
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    print("owner=\(owner) layer=\(layer) x=\(b["X"] ?? -1) y=\(b["Y"] ?? -1) w=\(b["Width"] ?? -1) h=\(b["Height"] ?? -1)")
}
