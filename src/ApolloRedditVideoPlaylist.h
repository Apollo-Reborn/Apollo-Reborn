#import <Foundation/Foundation.h>

// Reddit-hosted video (v.redd.it) master playlist recovery.
//
// Every v.redd.it post (videos, and the silent clips Apollo labels "GIF")
// starts playback from https://v.redd.it/<id>/HLSPlaylist.m3u8. Reddit's
// origin intermittently answers that one file with an S3 "AccessDenied" 403
// (measured 2026-11-15: ~55% of fetches for an affected video, fresh signed
// URL or not, 1 of 15 sampled videos affected), and Fastly then caches the 403
// for 600 s, so every open in that window fails the same way. The
// variant playlists (CMAF_<n>.m3u8), the media files and DASHPlaylist.mpd stay
// reliable for the same video. These helpers let the network layer rebuild the
// master from the DASH manifest when the real one fails. Foundation-only so
// the .m compiles into a host-side test harness
// (tests/run_reddit_video_playlist_tests.sh).

NS_ASSUME_NONNULL_BEGIN

// The video id when `url` is exactly https://v.redd.it/<id>/HLSPlaylist.m3u8
// (any query), otherwise nil.
FOUNDATION_EXPORT NSString *_Nullable ApolloRedditVideoIDFromMasterPlaylistURL(NSURL *_Nullable url);

// DASHPlaylist.mpd next to a master playlist URL (query dropped: the manifest
// is public and unsigned).
FOUNDATION_EXPORT NSURL *_Nullable ApolloRedditVideoDASHManifestURL(NSString *videoID);

// YES when `data` is an HLS playlist (#EXTM3U first, after an optional BOM or
// whitespace). The 403 body is S3 XML or "Access denied", never a playlist.
FOUNDATION_EXPORT BOOL ApolloRedditVideoDataIsHLSPlaylist(NSData *_Nullable data);

// Builds an HLS master playlist equivalent to Reddit's from the video's
// DASHPlaylist.mpd: one EXT-X-MEDIA per audio representation and one
// EXT-X-STREAM-INF per video representation and audio group, pointing at the
// CMAF_<n>.m3u8 / CMAF_AUDIO_<n>.m3u8 variant playlists Reddit serves next to
// the MPD's CMAF_<n>.mp4 files, in Reddit's own attribute layout (Apollo's
// audio detection and the tweak's CMAF audio regex read that text). Returns nil
// for anything that is not a CMAF-named manifest (legacy DASH_/HLS_ uploads
// name their HLS variants differently, so they are never guessed at).
FOUNDATION_EXPORT NSData *_Nullable ApolloRedditVideoMasterPlaylistFromDASH(NSData *_Nullable mpdData);

NS_ASSUME_NONNULL_END
