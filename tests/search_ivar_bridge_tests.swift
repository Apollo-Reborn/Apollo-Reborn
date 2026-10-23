import Foundation

private final class BridgeChecks {
    private(set) var count = 0
    private(set) var failures = 0

    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        count += 1
        if !condition() {
            failures += 1
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        }
    }
}

// Match Apollo's Array<RDKLink>: an array of concrete NSObject subclass
// references, not an Array<AnyObject> prepared for the bridge under test.
private final class FeedLink: NSObject {}
private final class WeakLink {
    weak var value: FeedLink?
    init(_ value: FeedLink) { self.value = value }
}

private func copyStrings(_ source: inout [String]?) -> UnsafeMutableRawPointer? {
    withUnsafePointer(to: &source) { ApolloSwiftCopyOptionalStringArray($0) }
}

private func copyFirstLink(_ source: inout [FeedLink]) -> UnsafeMutableRawPointer? {
    withUnsafePointer(to: &source) { ApolloSwiftCopyFirstObjectArrayElement($0) }
}

// Returning leaves the bridge's +1 as the first link's sole owner. The second
// link must deallocate, proving the bridge did not retain the complete feed.
private func retainedLinkFixture() -> (UnsafeMutableRawPointer?, UnsafeMutableRawPointer, WeakLink, WeakLink) {
    let first = FeedLink()
    let second = FeedLink()
    var source = [first, second]
    let address = Unmanaged.passUnretained(first).toOpaque()
    return (copyFirstLink(&source), address, WeakLink(first), WeakLink(second))
}

@main
private struct SearchIvarBridgeTests {
    static func main() {
        let checks = BridgeChecks()
        checks.check(Thread.isMainThread, "bridge harness runs on the main thread")
        checks.check(ApolloSwiftCopyOptionalStringArray(nil) == nil, "nil string-array storage is safe")
        checks.check(ApolloSwiftCopyFirstObjectArrayElement(nil) == nil, "nil object-array storage is safe")

        var strings: [String]? = nil
        checks.check(copyStrings(&strings) == nil, "nil optional string array stays nil")
        strings = []
        if let pointer = copyStrings(&strings) {
            let empty = Unmanaged<NSArray>.fromOpaque(pointer).takeRetainedValue()
            checks.check(empty.count == 0, "empty optional string array produces an empty snapshot")
        } else {
            checks.check(false, "empty optional string array must not become nil")
        }

        strings = ["Apple", "ApolloReborn"]
        if let pointer = copyStrings(&strings) {
            let snapshot = Unmanaged<NSArray>.fromOpaque(pointer).takeRetainedValue()
            strings?[0] = "swift"
            strings = nil
            checks.check(snapshot as? [String] == ["Apple", "ApolloReborn"],
                         "retained snapshot survives source mutation and destruction")
        } else {
            checks.check(false, "populated optional string array returns a snapshot")
        }

        var emptyLinks: [FeedLink] = []
        checks.check(copyFirstLink(&emptyLinks) == nil, "empty concrete class array has no first element")

        let fixture = autoreleasepool { retainedLinkFixture() }
        checks.check(fixture.0 == fixture.1, "first-element bridge preserves concrete object identity")
        checks.check(fixture.2.value != nil, "returned +1 keeps first link alive after source destruction")
        checks.check(fixture.3.value == nil, "bridge does not retain the rest of the source feed")
        if let pointer = fixture.0 {
            Unmanaged<FeedLink>.fromOpaque(pointer).release()
        }
        checks.check(fixture.2.value == nil, "consuming returned +1 releases the first link without leaking")

        let bridgedFirst = FeedLink()
        let foundationArray: NSArray = [bridgedFirst, FeedLink()]
        var bridgedLinks = foundationArray as! [FeedLink]
        if let pointer = copyFirstLink(&bridgedLinks) {
            let actual = Unmanaged<FeedLink>.fromOpaque(pointer).takeRetainedValue()
            checks.check(actual === bridgedFirst, "Foundation-backed class array preserves first identity")
        } else {
            checks.check(false, "Foundation-backed class array returns its first element")
        }

        print("\(checks.failures == 0 ? "OK" : "FAILED"): \(checks.count) search ivar bridge checks")
        if checks.failures != 0 { exit(1) }
    }
}
