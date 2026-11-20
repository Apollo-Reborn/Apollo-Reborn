#import <Foundation/Foundation.h>

// Offline Mode web pages (ApolloOfflinePages.xm).
//
// Apollo opens a link post in SFSafariViewController, which runs in Safari's
// own process: the app can't hand it saved content, and offline it shows
// Safari's "not connected" page. So:
//   • during a download, each link post's page is loaded in an off-screen
//     WKWebView (up to 3 at once) and kept as a complete web archive (HTML,
//     images, styles);
//   • while the library is serving, presenting an SFSafariViewController for
//     a saved page presents a small reader for that archive instead. Pages
//     that weren't saved open in Safari's view exactly as before.

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// Loads `url` off screen and calls `done` on the main queue with a web
// archive of it, or nil after a failure or ~20 s. Up to 3 pages load at once.
void ApolloOfflineSaveWebPage(NSURL *url, void (^done)(NSData * _Nullable archive));

// Stops every page being saved or waiting (each `done` gets nil).
void ApolloOfflineCancelWebPageSaves(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
