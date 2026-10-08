#import <Foundation/Foundation.h>

// Nitter mirror support for opening X/Twitter links without an X account.
//
// Two jobs live here:
//
//   1. Rewriting a tapped x.com / twitter.com URL onto the Nitter instance the
//      user picked (ApolloShareLinks.xm opens the result).
//   2. Fetching the list of currently healthy public instances from the
//      status.d420.de tracker, for the instance picker in Settings > Open in
//      App. The tracker rate-limits aggressively (a second request a few
//      seconds after the first gets a 429), so this is only ever called from
//      that user-initiated picker, never in the background, and the result is
//      memoized for a while.
//
// Nothing here talks to a Nitter instance itself. As of October 2026 every
// public instance answers scripted requests with a Cloudflare / Anubis /
// access-queue challenge, so instances are only usable from a real browser
// (SFSafariViewController passes those challenges), which is why this feature
// opens links rather than fetching tweet content for inline display.
//
// Deliberately Foundation-only and free of any tweak dependency, so it compiles
// straight into a host-side harness (tests/run_nitter_instances_tests.sh).

NS_ASSUME_NONNULL_BEGIN

@interface ApolloNitterInstance : NSObject
/// Bare host as the tracker reports it, e.g. "nitter.example.org".
@property (nonatomic, copy, readonly) NSString *host;
/// The tracker's health score; the list is sorted by this, highest first.
@property (nonatomic, readonly) NSInteger points;
/// Average response time over the tracker's recent pings, or 0 when unknown.
@property (nonatomic, readonly) NSInteger averagePingMilliseconds;
@end

__BEGIN_DECLS

/// Parses the tracker's `/api/v1/instances` JSON into the healthy instances,
/// sorted by points (highest first). Malformed entries are skipped. Returns nil
/// when the payload itself isn't the expected shape.
NSArray<ApolloNitterInstance *> *_Nullable ApolloNitterParseInstanceList(NSData *_Nullable data);

/// Fetches the healthy instance list from the tracker. Must be called on the
/// main queue; the completion always runs on the main queue. Concurrent calls
/// share one request, and a successful result is reused for a few minutes so
/// reopening the picker doesn't hit the tracker again.
void ApolloNitterFetchHealthyInstances(void (^completion)(NSArray<ApolloNitterInstance *> *_Nullable instances,
                                                          NSError *_Nullable error));

/// Normalizes user input ("nitter.example.org", "https://nitter.example.org/foo",
/// "Nitter.Example.org:8443") to a lowercase "host" or "host:port", meaning
/// https. Input that explicitly says http:// keeps it, as "http://host" or
/// "http://host:port", for self-hosted instances served without TLS. Returns
/// nil for anything that isn't a plausible dotted hostname, and for X/Twitter's
/// own domains (pointing the mirror at X would loop straight back to X).
NSString *_Nullable ApolloNitterNormalizeHost(NSString *_Nullable input);

/// Rewrites an X/Twitter web URL onto `instanceHost` (as returned by
/// ApolloNitterNormalizeHost). Returns nil when the URL isn't an x.com /
/// twitter.com page link, or points at a page Nitter can't serve (the X home
/// timeline, DMs, settings, most `/i/` routes, ...), in which case the caller
/// should keep its normal routing.
NSURL *_Nullable ApolloNitterURLForTwitterURL(NSURL *_Nullable url, NSString *_Nullable instanceHost);

__END_DECLS

NS_ASSUME_NONNULL_END
