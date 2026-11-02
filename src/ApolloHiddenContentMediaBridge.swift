import Foundation
import UIKit

// Replace an already-initialized Swift dictionary so ARC releases its old
// storage correctly; never synthesize a Dictionary's raw reference-count bits.
@_cdecl("ApolloHiddenMediaAssignThumbnail")
public func assignThumbnail(_ ptr: UnsafeMutableRawPointer, _ index: Int, _ object: UnsafeRawPointer) {
    let image = Unmanaged<UIImage>.fromOpaque(object).takeUnretainedValue()
    // Apollo constructs its first child at zero before the caller synchronizes
    // its index. Seed both keys so opening a later album page never flashes
    // black during that initial child construction.
    var thumbnails = [0: image]
    thumbnails[index] = image
    ptr.assumingMemoryBound(to: [Int: UIImage].self).pointee = thumbnails
}
