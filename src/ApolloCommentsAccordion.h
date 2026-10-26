#import <UIKit/UIKit.h>

#import "ApolloListRowAnimationPolicy.h"

// The comments accordion: a comment collapsing or expanding is committed
// without UIKit's row animations and animated as one piece instead.
//
// Collapse: the comment as it was stays on top, in place, and is clipped from
// the bottom up to its header while that header glides onto the collapsed
// row's (measured per batch from the two renders), which takes over at the
// end; its replies ride under that edge, and the rows below rise over them and
// cover them. Expand is the mirror: the live expanded comment, on top, is
// revealed from its header band down, gliding from the collapsed header's
// place to its own while the reply count fades; its replies ride under that
// edge, and the rows below (as they were) slide down beneath it and uncover
// them. Nothing is drawn translucent over other content, the
// replies never slip behind a short row, and no gap opens, because the rows
// below are what close it.
//
// The hooks in ApolloCommentsCollapse.xm feed every Texture batch through
// these calls. A batch that looks like one comment collapsing or expanding
// (ApolloAccordionBatchIsCandidate) on a regular comments thread is committed
// in one step; the rows on screen before and after are then matched by
// identity, which holds however Apollo's diff encodes the change, and the
// comment that changed height gets the accordion
// (ApolloAccordionLayoutChangeForRows). When the comment's top is above the
// visible part of the list, the scroll Apollo makes to bring it into view
// is made part of the same motion (ApolloAccordionRevealFor). Every other
// batch commits with Apollo's own animations
// (ApolloListRowAnimationForOperation). UIKit only.
// Main-thread only; the state is process-wide, so a second comments table
// (iPad, Duo) starting an accordion lands a running one at its end.

NS_ASSUME_NONNULL_BEGIN
__BEGIN_DECLS

// [super beginUpdates] of a Texture table.
void ApolloAccordionTableWillBeginUpdates(UITableView *tableView);

// Every row operation, before UIKit sees it. `scope` is the table's scope when
// `requested` is automatic (ApolloListRowScopeNone otherwise). Returns the
// animation to hand UIKit.
UITableViewRowAnimation ApolloAccordionAnimationForRows(UITableView *tableView,
                                                        ApolloListRowOperation operation,
                                                        NSArray<NSIndexPath *> *indexPaths,
                                                        UITableViewRowAnimation requested,
                                                        ApolloListRowScope scope);

// A section operation or a row move inside a batch: that batch is left alone.
void ApolloAccordionTableDidChangeSectionsOrMoveRows(UITableView *tableView);

// What a row shows, so the rows on screen before and after a batch can be
// matched: a comment's fullName, or for any other row its kind prefixed with
// "~" (such rows are then told apart by position). nil to ignore the row.
typedef NSString *_Nullable (^ApolloAccordionRowIdentity)(UITableViewCell *cell);

// [super endUpdates] of a table. `commit` runs UIKit's -endUpdates exactly once.
// With Reduce Motion on, the batch keeps Apollo's own animations.
void ApolloAccordionTableEndUpdates(UITableView *tableView,
                                    ApolloAccordionRowIdentity identity,
                                    NS_NOESCAPE dispatch_block_t commit);

// -tableView:willDisplayCell:forRowAtIndexPath: of a Texture table.
void ApolloAccordionTableWillDisplayCell(UITableView *tableView, UITableViewCell *cell, NSIndexPath *indexPath);

__END_DECLS
NS_ASSUME_NONNULL_END
