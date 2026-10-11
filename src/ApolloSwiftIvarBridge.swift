//
//  ApolloSwiftIvarBridge.swift
//  Apollo-Reborn
//
//  Tiny ABI-safe helpers for the handful of Swift stored properties that Apollo
//  does not expose to Objective-C. Objective-C code locates the ivar by name and
//  passes its storage address here; Swift performs the assignment so retain/
//  release behavior and Optional<String>'s spare-bit representation stay owned
//  by the Swift runtime instead of being reimplemented with raw memory writes.
//

import Foundation

// SafariActivity.url is a non-optional Swift URL stored inline. Its layout
// changes with Foundation; never read its first word as an NSURL in ObjC.
@_cdecl("ApolloSwiftURLSupportsSafari")
public func ApolloSwiftURLSupportsSafari(_ storage: UnsafeRawPointer?) -> Bool {
    guard let storage else { return false }
    let url = storage.assumingMemoryBound(to: URL.self).pointee
    func supportsSafari(_ candidate: URL) -> Bool {
        let scheme = candidate.scheme?.lowercased()
        return (scheme == "http" || scheme == "https") && !(candidate.host ?? "").isEmpty
    }

    // Apollo's activity factory assumes non-web strings are Reddit permalinks
    // and prefixes them with this origin. The share completion still captures
    // the ORIGINAL URL. A local GIF therefore leaves the activity holding
    // "https://reddit.comfile:///...", which looks like HTTPS to Foundation,
    // while selecting it passes file:///... to SFSafariViewController and throws.
    // Recognize an absolute URL after that exact native prefix. Ordinary Reddit
    // paths, query strings, ports, and similarly named web hosts stay untouched.
    let origin = "https://reddit.com"
    let string = url.absoluteString
    if string.hasPrefix(origin),
       let original = URL(string: String(string.dropFirst(origin.count))),
       let originalScheme = original.scheme, !originalScheme.isEmpty {
        return supportsSafari(original)
    }
    return supportsSafari(url)
}

@_cdecl("ApolloSwiftAssignOptionalString")
public func ApolloSwiftAssignOptionalString(
    _ storage: UnsafeMutableRawPointer?,
    _ utf8Value: UnsafePointer<CChar>?
) {
    guard let storage else { return }
    let value = utf8Value.map { String(cString: $0) }
    storage.assumingMemoryBound(to: Optional<String>.self).pointee = value
}

@_cdecl("ApolloSwiftAssignOptionalStringArray")
public func ApolloSwiftAssignOptionalStringArray(
    _ storage: UnsafeMutableRawPointer?,
    _ arrayObject: UnsafeRawPointer?
) {
    guard let storage else { return }
    let value: [String]?
    if let arrayObject {
        let array = Unmanaged<NSArray>.fromOpaque(arrayObject).takeUnretainedValue()
        value = array.compactMap { $0 as? String }
    } else {
        value = nil
    }
    storage.assumingMemoryBound(to: Optional<[String]>.self).pointee = value
}

// The Search landing reads Apollo's live trending model without treating a Swift
// Array as an Objective-C ivar. The caller consumes this retained NSArray.
@_cdecl("ApolloSwiftCopyOptionalStringArray")
public func ApolloSwiftCopyOptionalStringArray(_ storage: UnsafeRawPointer?) -> UnsafeMutableRawPointer? {
    guard let storage,
          let value = storage.assumingMemoryBound(to: Optional<[String]>.self).pointee else { return nil }
    return Unmanaged.passRetained(value as NSArray).toOpaque()
}

// PostsViewController.links is a non-optional Array<RDKLink>. Arrays of class
// references share Array<AnyObject>'s element representation; Swift handles its
// native/bridged storage and empty-array sentinel. Reading .first is O(1) and
// never bridges/copies the entire feed. The caller consumes the retained object
// and validates its RDKLink class before reading subreddit.
@_cdecl("ApolloSwiftCopyFirstObjectArrayElement")
public func ApolloSwiftCopyFirstObjectArrayElement(_ storage: UnsafeRawPointer?) -> UnsafeMutableRawPointer? {
    guard Thread.isMainThread, let storage,
          let first = storage.assumingMemoryBound(to: Array<AnyObject>.self).pointee.first else { return nil }
    return Unmanaged.passRetained(first).toOpaque()
}
