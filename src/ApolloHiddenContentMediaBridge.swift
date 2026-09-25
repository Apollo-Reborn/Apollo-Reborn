// The native initializer consumes its URL argument; deallocate the already-destroyed
// storage afterward. Swift owns URL and Optional<[URL]> layout and ARC.
import Foundation
import UIKit
@_cdecl("ApolloHiddenMediaPrepareURL")
public func prepare(_ object: UnsafeRawPointer) -> UnsafeMutableRawPointer {
    let url = Unmanaged<NSURL>.fromOpaque(object).takeUnretainedValue() as URL
    let ptr = UnsafeMutablePointer<URL>.allocate(capacity: 1)
    ptr.initialize(to: url)
    return UnsafeMutableRawPointer(ptr)
}
@_cdecl("ApolloHiddenMediaFreeURL")
public func freeURL(_ ptr: UnsafeMutableRawPointer) { ptr.assumingMemoryBound(to: URL.self).deallocate() }
@_cdecl("ApolloHiddenMediaAssignURLs")
public func assign(_ ptr: UnsafeMutableRawPointer, _ array: UnsafeRawPointer) {
    let urls = Unmanaged<NSArray>.fromOpaque(array).takeUnretainedValue() as! [URL]
    ptr.assumingMemoryBound(to: Optional<[URL]>.self).pointee = urls
}

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
