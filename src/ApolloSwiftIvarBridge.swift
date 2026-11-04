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
#if canImport(UIKit)
import SwiftUI
import UIKit
#endif

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

/// ApolloNavigationController keeps its forward history in a Swift
/// `[UIViewController]` stored ivar. Objective-C can locate that ivar, but it
/// must not treat the one-word Swift Array value as an NSArray object or write
/// `_swiftEmptyArrayStorage` by hand. Keeping the assignment here makes Swift
/// own the array ABI and its retain/release operations.
@_cdecl("ApolloSwiftClearViewControllerArray")
public func ApolloSwiftClearViewControllerArray(
    _ storage: UnsafeMutableRawPointer?
) {
    guard let storage else { return }
    storage.assumingMemoryBound(to: [UIViewController].self).pointee.removeAll(
        keepingCapacity: false
    )
}

/// Diagnostic companion for the clear helper. This is intentionally a count,
/// not an NSArray bridge: no Objective-C caller should ever take ownership of
/// Apollo's private Swift-array storage.
@_cdecl("ApolloSwiftViewControllerArrayCount")
public func ApolloSwiftViewControllerArrayCount(
    _ storage: UnsafeRawPointer?
) -> UInt {
    guard let storage else { return 0 }
    return UInt(storage.assumingMemoryBound(to: [UIViewController].self).pointee.count)
}

// Process-local wrapper around the exact AnyHashable identity Apollo's
// ListAdapter uses for diffing. Objective-C must never decode Swift Array,
// Dictionary, AnyHashable, or Foundation.IndexPath storage itself; these two C
// entry points keep every collection operation on the Swift side of the ABI.
private final class ApolloListAdapterIdentityToken: NSObject, NSCopying {
    let key: AnyHashable

    init(key: AnyHashable) {
        self.key = key
        super.init()
    }

    override var description: String { "<ApolloListAdapterIdentityToken>" }
    override var debugDescription: String { description }

    func copy(with zone: NSZone? = nil) -> Any { self }
}

@_cdecl("ApolloSwiftListAdapterModelIdentifier")
public func ApolloSwiftListAdapterModelIdentifier(
    _ objectsStorage: UnsafeRawPointer?,
    _ section: Int,
    _ row: Int
) -> UnsafeMutableRawPointer? {
    guard Thread.isMainThread, let objectsStorage, section == 0, row >= 0 else { return nil }
    let objects = objectsStorage.assumingMemoryBound(to: [AnyHashable].self).pointee
    guard row < objects.count else { return nil }
    let token = ApolloListAdapterIdentityToken(key: objects[row])
    return Unmanaged.passRetained(token).toOpaque()
}

@_cdecl("ApolloSwiftListAdapterIndexPathForModelIdentifier")
public func ApolloSwiftListAdapterIndexPathForModelIdentifier(
    _ mappingStorage: UnsafeRawPointer?,
    _ tokenObject: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard Thread.isMainThread, let mappingStorage, let tokenObject else { return nil }
    let object = Unmanaged<AnyObject>.fromOpaque(tokenObject).takeUnretainedValue()
    guard let token = object as? ApolloListAdapterIdentityToken else { return nil }
    let mapping = mappingStorage.assumingMemoryBound(
        to: [AnyHashable: IndexPath].self
    ).pointee
    guard let path = mapping[token.key] else { return nil }
    return Unmanaged.passRetained(path as NSIndexPath).toOpaque()
}

/// The native ListAdapter inserts a SectionController before returning its
/// asynchronous node factory. Both dictionary values are class references;
/// retain the returned object without exposing Swift Dictionary storage to ObjC.
@_cdecl("ApolloSwiftListAdapterSectionController")
public func ApolloSwiftListAdapterSectionController(
    _ storage: UnsafeRawPointer?, _ indexPathObject: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let storage, let indexPathObject else { return nil }
    let indexPath = Unmanaged<NSIndexPath>.fromOpaque(indexPathObject).takeUnretainedValue() as IndexPath
    let mapping = storage.assumingMemoryBound(to: [IndexPath: NSObject].self).pointee
    guard let section = mapping[indexPath] else { return nil }
    return Unmanaged.passRetained(section).toOpaque()
}

@_cdecl("ApolloSwiftAssignInteractiveTransition")
public func ApolloSwiftAssignInteractiveTransition(
    _ storage: UnsafeMutableRawPointer?, _ object: UnsafeRawPointer?
) {
    guard let storage else { return }
    let transition = object.map {
        Unmanaged<UIPercentDrivenInteractiveTransition>.fromOpaque($0).takeUnretainedValue()
    }
    storage.assumingMemoryBound(to: Optional<UIPercentDrivenInteractiveTransition>.self).pointee = transition
}

// Apollo 1.15.11 PostsType's metadata records this exact case/payload order.
// Its frozen in-module representation is two Strings plus a discriminator
// (33 bytes, 40-byte stride). ObjC validates the surrounding ivars first.
private enum ApolloPaneNativePostsType {
    case subreddit(String), multireddit(String, String), upvoted(String)
    case downvoted(String), submissions(String), random(Bool), home, hidden
}

@_cdecl("ApolloSwiftPanePostsScope")
public func ApolloSwiftPanePostsScope(_ storage: UnsafeRawPointer?) -> UnsafeMutableRawPointer? {
    guard Thread.isMainThread, let storage,
          MemoryLayout<ApolloPaneNativePostsType>.size == 33 else { return nil }
    let tag = storage.load(fromByteOffset: 32, as: UInt8.self)
    guard tag <= 6 else { return nil }
    if tag >= 5 && storage.load(as: UInt8.self) > 1 { return nil }
    let value = storage.assumingMemoryBound(to: ApolloPaneNativePostsType.self).pointee
    let scope: String
    switch value {
    case .subreddit(let name): scope = "subreddit:" + name.lowercased()
    case .multireddit(let name, let user): scope = "multi:" + user.lowercased() + "/" + name.lowercased()
    case .upvoted(let user): scope = "upvoted:" + user.lowercased()
    case .downvoted(let user): scope = "downvoted:" + user.lowercased()
    case .submissions(let user): scope = "submissions:" + user.lowercased()
    case .random(let nsfw): scope = nsfw ? "random:nsfw" : "random:safe"
    case .home: scope = "home"
    case .hidden: scope = "hidden"
    }
    return Unmanaged.passRetained(scope as NSString).toOpaque()
}

// AppDelegate.tabBarController is a strong Swift Optional, not an ObjC ivar
// with an @ type encoding. Its native destructor releases one pointer slot.
@_cdecl("ApolloSwiftExchangePaneTabs")
public func ApolloSwiftExchangePaneTabs(_ storage: UnsafeMutableRawPointer?, _ object: UnsafeRawPointer?) -> UnsafeMutableRawPointer? {
    guard let storage else { return nil }
    let slot = storage.assumingMemoryBound(to: Optional<UITabBarController>.self)
    let previous = slot.pointee
    slot.pointee = object.map { Unmanaged<UITabBarController>.fromOpaque($0).takeUnretainedValue() }
    return previous.map { Unmanaged.passRetained($0).toOpaque() }
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

#if canImport(UIKit)
// Apollo's native menu hosts a SwiftUI type that the tweak cannot name. A
// protocol conformance on the generic hosting controller provides access to
// its public sizing API without casting that unknown content to AnyView.
@MainActor private protocol ApolloHostingPreferredSizeReporting {
    func apolloEnablePreferredSizeReporting()
}

extension UIHostingController: ApolloHostingPreferredSizeReporting {
    fileprivate func apolloEnablePreferredSizeReporting() {
        if #available(iOS 16.0, *) {
            sizingOptions.insert(.preferredContentSize)
        }
    }
}

// Main-thread only. The pointer is an unretained UIViewController. Its parent
// receives preferredContentSizeDidChangeForChildContentContainer: when the
// SwiftUI menu changes state; that callback should refit at the actual viewport
// width rather than directly adopt this unconstrained preferred size.
@MainActor @_cdecl("ApolloSwiftEnableHostingPreferredContentSize")
public func ApolloSwiftEnableHostingPreferredContentSize(_ controller: UnsafeRawPointer?) -> Bool {
    guard #available(iOS 16.0, *), let controller else { return false }
    let object = Unmanaged<AnyObject>.fromOpaque(controller).takeUnretainedValue()
    guard let hosting = object as? any ApolloHostingPreferredSizeReporting else { return false }
    hosting.apolloEnablePreferredSizeReporting()
    return true
}

#endif
