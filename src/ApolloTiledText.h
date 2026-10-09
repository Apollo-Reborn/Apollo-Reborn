#import <UIKit/UIKit.h>

// Draws a classic ASTextNode through a CATiledLayer sublayer instead of the
// one bitmap Texture would render for it (#1354). A long post body is a
// single MarkdownTextNode, and at large text sizes its bitmap passes
// ApolloAsyncDisplayGuard's budget (or can't be allocated at all), which
// used to leave the body blank. Tiles draw only what is on screen.
//
// Driven entirely from ApolloAsyncDisplayGuard's display hook, which owns
// -_displayBlockWithAsynchronous:isCancelledBlock:rasterizing:.

NS_ASSUME_NONNULL_BEGIN

__BEGIN_DECLS

// Main thread, from inside the node's display pass, with the bounds and scale
// that pass uses. YES = the node is drawn by its tiled sublayer (created or
// refreshed here), so the pass must produce no bitmap of its own. NO = the
// pass draws as usual, and a tiled sublayer left over from an earlier, larger
// state of the node is removed. Tiles are used when `overBudget` is set or the
// node's bitmap failed before (ApolloTiledTextNoteBitmapFailure), and never
// for a node being rasterized into an ancestor. A pass that is being waited
// on (`synchronous`: Texture's -recursivelyEnsureDisplaySynchronously:) and
// finds the tiles missing or stale also draws the node's on-screen part right
// away, so the waiter never gets it blank or out of date.
BOOL ApolloTiledTextTakeOverDisplay(id node, CGRect bounds, CGFloat scale, BOOL overBudget, BOOL rasterizing, BOOL synchronous);

// Main thread, from a display pass that has nothing to draw: removes the
// node's tiled sublayer, if it has one.
void ApolloTiledTextDropTiles(id node);

// Any thread: the node's one-bitmap display failed (UIKit couldn't allocate
// the bitmap: on Liquid Glass builds it raises, otherwise the image comes back
// empty). A text node is redrawn in tiles from its next display pass on.
void ApolloTiledTextNoteBitmapFailure(id _Nullable node);

// Simulator debug bridge: whether the node is currently drawn in tiles.
BOOL ApolloTiledTextNodeIsTiled(id node);

__END_DECLS

NS_ASSUME_NONNULL_END
