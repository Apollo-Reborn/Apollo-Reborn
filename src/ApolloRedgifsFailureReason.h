// ApolloRedgifsFailureReason.h
//
// Names the reason a RedGIFs post failed to load, for the card Apollo shows in
// its place (see ApolloRedgifsErrorCards.xm). Foundation only, so the .m also
// builds into the host-side test in tests/run_redgifs_failure_reason_tests.sh.
//
// Apollo (1.15.11) labels every RedGIFs failure "RedGIFs error :(" (the API
// lookup failed) or "Redgifs error :(" (the video file failed to load), so a
// video RedGIFs deleted, a region block and a network that can't reach RedGIFs
// all look the same, and read like an app bug. What each one looks like on the
// wire, checked against the live API and in the simulator:
//   * GET api.redgifs.com/v2/gifs/<id>: 410 {"error":{"code":"GifDeleted"}} for
//     a deleted video, 404 {"error":{"code":"GifNotFound"}} for an unknown id,
//     401 for a token minted on another IP address, 451 for a region RedGIFs
//     blocks (UK, several US states), an NSURLErrorDomain transport error when
//     the network can't reach RedGIFs. A 200 whose "gif" is type 2 is an image,
//     which Apollo's video model can't decode.
//   * The video file from media.redgifs.com fails in AVFoundation with an
//     NSURLErrorDomain error whose underlying CoreMedia error carries the HTTP
//     status: 404 -> CoreMediaErrorDomain -12938 "HTTP 404: File Not Found",
//     410 -> -12668 "HTTP 410: Gone", 451 -> -16845 "HTTP 451: (unhandled)",
//     500 -> -16847, 403 -> NSOSStatusErrorDomain -12660 (no status text).
//     Transport failures are NSURLErrorDomain codes (-1003 when DNS can't find
//     the host, etc.).

#import <Foundation/Foundation.h>

// Plain Objective-C (.m, C linkage) called from Objective-C++ (.xm); keep the
// declarations in C linkage so the symbols match.
#ifdef __cplusplus
extern "C" {
#endif

typedef NS_ENUM(NSInteger, ApolloRedgifsFailureKind) {
    // Nothing nameable: success, or a failure this file doesn't recognise.
    // The card keeps Apollo's own text.
    ApolloRedgifsFailureKindNone = 0,
    ApolloRedgifsFailureKindDeleted,      // HTTP 410 / "GifDeleted"
    ApolloRedgifsFailureKindNotFound,     // HTTP 404 / "GifNotFound"
    ApolloRedgifsFailureKindRegion,       // HTTP 451
    ApolloRedgifsFailureKindUnreachable,  // DNS, connection, TLS, timeout, offline
    ApolloRedgifsFailureKindImage,        // an image record Apollo can't show inline
    ApolloRedgifsFailureKindHTTPStatus,   // any other HTTP error status
};

typedef struct {
    ApolloRedgifsFailureKind kind;
    NSInteger httpStatus;  // set for HTTPStatus (and whenever a status was seen)
} ApolloRedgifsFailure;

// A /v2/gifs/<id> lookup or /v2/auth/temporary token result, as Apollo receives
// it. Kind None for a usable answer (or one that can't be named).
ApolloRedgifsFailure ApolloRedgifsFailureForAPIResult(NSData *data, NSURLResponse *response, NSError *error);

// The error AVFoundation hands RichMediaNode when a RedGIFs video file fails to
// load (-videoNode:didFailToLoadValueForKey:asset:error:).
ApolloRedgifsFailure ApolloRedgifsFailureForMediaError(NSError *error);

// The card title for a failure, or nil for kind None (keep Apollo's text).
NSString *ApolloRedgifsCardTitleForFailure(ApolloRedgifsFailure failure);

// The lowercased gif id in a RedGIFs post URL (redgifs.com/watch/<id>,
// v3.redgifs.com/watch/<id>-title, redgifs.com/ifr/<id>, ...), or nil when the
// URL isn't a RedGIFs post. Mirrors the capture group of Apollo's RedGIFs host
// pattern: the first path segment after an optional watch/ifr/gifs/detail or
// two-letter language prefix, up to its first non-word character.
NSString *ApolloRedgifsIDFromPostURL(NSURL *url);

// The lowercased gif id in an api.redgifs.com/v2/gifs/<id> lookup URL, or nil.
NSString *ApolloRedgifsIDFromLookupURL(NSURL *url);

// YES for a video file on Reddit's own media hosts (v.redd.it, preview.redd.it,
// *.reddit.com, *.redditmedia.com). When a RedGIFs lookup fails Apollo plays
// the post's Reddit copy in the same node, so that file failing says nothing
// about RedGIFs.
BOOL ApolloRedgifsMediaURLIsRedditCopy(NSURL *url);

#ifdef __cplusplus
}
#endif
