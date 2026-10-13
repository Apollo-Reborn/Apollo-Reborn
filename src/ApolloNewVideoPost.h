#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// For a native video post the tweak just submitted (bare or t3_-prefixed link
// ID): holds the submit success, and with it Apollo's "Posted! Tap to view."
// banner, until Reddit has attached the transcoded video, so tapping the banner
// opens a post that already plays. Calls `deliver` exactly once, on a background
// queue, as soon as the video is there or after 20 s at most; if Reddit is still
// processing by then, a comments screen opened on the post switches to the video
// once it's ready. Safe to call from any queue.
void ApolloNewVideoPostDeliverWhenPlayable(NSString *linkID, dispatch_block_t deliver);

#ifdef __cplusplus
}
#endif
