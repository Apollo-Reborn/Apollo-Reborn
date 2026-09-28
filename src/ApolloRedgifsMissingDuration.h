// ApolloRedgifsMissingDuration.h
//
// Plays RedGIFs videos whose API record has no duration.
//
// Apollo (1.15.11) looks each RedGIFs post up with GET
// https://api.redgifs.com/v2/gifs/<id> and decodes the response's "gif" object
// into its Swift RedGIFsVideo model (Unbox init at 0x100695178). Every field
// it reads is required: urls.hd, urls.sd and urls.thumbnail as URLs, hasAudio
// as a Bool and duration as a Double. RedGIFs sends "duration": null for some
// videos (older uploads, typically with "hls": false), so the decode throws and
// the post shows "RedGIFs error :(" / "Tap to open in browser" even though the
// lookup succeeded and the video itself plays fine.
//
// The value has to be right, not just present: Apollo shows it as the length
// label on a video with sound that isn't autoplaying (RichMediaNode's
// content-type overlay, set at 0x1005812ec, formatted by 0x1007da9c0), so a
// placeholder 0 would label a 32-second video "0:00". So the real length is
// read from the video file's own header, the mvhd box inside moov: one ranged
// request for the first 64 KB of urls.sd (the smaller mobile rendition) finds
// it when the file keeps moov up front, and otherwise the box sizes in those
// bytes give moov's offset after the media data for a second ranged request
// (14 of the 44 null-duration videos checked needed that). If neither yields a
// length, the record gets a placeholder that Apollo's formatter shows as "-:--"
// (see kApolloRedgifsUnknownDuration in the .m).
//
// Image records (type 2, whose urls.hd is a .jpg) are left untouched. Given a
// duration, Apollo decodes them as a video that never plays: a still labelled
// "GIF" in the feed and no player in the viewer. As they are, they keep the
// error card, whose "Tap to open in browser" opens the image on redgifs.com.
//
// Wired into Tweak.xm's -[NSURLSession dataTaskWithRequest:completionHandler:]
// hook, which every RedGIFsClient request goes through. The hook rebinds its
// completionHandler to the returned block before its RedGIFs branches, so any
// other handling of the same request passes the repaired response on.

#import <Foundation/Foundation.h>

// Plain Objective-C (.m, C linkage) called from Tweak.xm, which is compiled as
// Objective-C++; keep the declarations in C linkage so the symbols match.
#ifdef __cplusplus
extern "C" {
#endif

typedef void (^ApolloRedgifsLookupCompletion)(NSData *data, NSURLResponse *response, NSError *error);

// Creates a data task through the hooked session's ORIGINAL
// -dataTaskWithRequest:completionHandler: (the caller's %orig), so the header
// read runs on Apollo's RedGIFs session and its result, like the lookup's own,
// reaches Apollo on that session's delegate queue.
typedef NSURLSessionDataTask *(^ApolloRedgifsLookupTaskFactory)(NSURLRequest *request, ApolloRedgifsLookupCompletion completion);

// For Apollo's RedGIFs gif lookups (GET api.redgifs.com/v2/gifs/<id> on
// Apollo's own session): returns a completion that fills in a missing duration
// before calling `completion`. Every other request gets `completion` back
// unchanged, including ApolloHostedVideo's lookups on the shared session, which
// never read the duration.
ApolloRedgifsLookupCompletion ApolloRedgifsCompletionFillingMissingDuration(NSURLSession *session,
                                                                           NSURLRequest *request,
                                                                           ApolloRedgifsLookupCompletion completion,
                                                                           ApolloRedgifsLookupTaskFactory factory);

#ifdef __cplusplus
}
#endif
