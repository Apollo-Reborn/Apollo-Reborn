#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Records a native video post the tweak just submitted (bare or t3_-prefixed
// link ID). Reddit creates the post before v.redd.it finishes transcoding, so
// for a few seconds it has no media.reddit_video and Apollo draws the poster as
// a still image. A comments screen for the post that opens in that window gets
// refreshed once Reddit attaches the video. Safe to call from any queue.
void ApolloNewVideoPostNoteSubmitted(NSString *linkID);

#ifdef __cplusplus
}
#endif
