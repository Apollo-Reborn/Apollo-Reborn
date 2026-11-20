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

// Replace the dictionary with page -> placeholder entries ([NSNumber: UIImage]).
// Entries of any other type are skipped.
@_cdecl("ApolloMediaAssignThumbnails")
public func assignThumbnails(_ ptr: UnsafeMutableRawPointer, _ object: UnsafeRawPointer) {
    let map = Unmanaged<NSDictionary>.fromOpaque(object).takeUnretainedValue()
    var thumbnails = [Int: UIImage]()
    for (key, value) in map {
        guard let index = (key as? NSNumber)?.intValue, let image = value as? UIImage else { continue }
        thumbnails[index] = image
    }
    ptr.assumingMemoryBound(to: [Int: UIImage].self).pointee = thumbnails
}
