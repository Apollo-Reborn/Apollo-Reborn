// The native initializer consumes its URL argument; deallocate the already-destroyed
// storage afterward. Swift owns URL and Optional<[URL]> layout and ARC.
import Foundation
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
