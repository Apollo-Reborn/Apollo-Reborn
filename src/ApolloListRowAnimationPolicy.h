#ifndef ApolloListRowAnimationPolicy_h
#define ApolloListRowAnimationPolicy_h

#include <math.h>
#include <stdbool.h>
#include <stddef.h>

// Pure decisions behind the comments accordion (ApolloCommentsAccordion.m).
// Values are UITableViewRowAnimation raw values, so this stays host-testable.
//
// Apollo's ListAdapter updates a comments thread with
// UITableViewRowAnimationAutomatic for every row operation. Collapsing or
// expanding a comment replaces the comment's own row (the collapsed header
// for the full comment, or back) and removes or adds its replies, along with
// the separator rows between comments, in one batch. Left to UIKit, the
// comment's two states cross-fade (both at about half opacity over the
// replies moving past) and the replies slide on their own path. The accordion
// instead keeps the comment in place, clips it to its animating height, keeps
// the replies attached under it, and has the rows below cover (collapse) or
// uncover (expand) them.

typedef enum ApolloListRowOperation {
    ApolloListRowOperationReload = 0,
    ApolloListRowOperationInsert = 1,
    ApolloListRowOperationDelete = 2,
} ApolloListRowOperation;

enum {
    kApolloListRowAnimationTop = 3,
    kApolloListRowAnimationAutomatic = 100,
};

typedef enum ApolloListRowScope {
    // Not a comments thread: nothing changes.
    ApolloListRowScopeNone = 0,
    // A Live Update thread: ApolloLiveCommentsFollow.xm anchors the reading
    // position against the native insert animation, so the accordion stays
    // off there.
    ApolloListRowScopeDeletesOnly = 1,
    // A regular comments thread: collapse and expand become the accordion.
    ApolloListRowScopeAccordion = 2,
} ApolloListRowScope;

// The table belongs to a comments thread when the nearest controller in its
// responder chain is a CommentsViewController that owns exactly this table.
// The media pane keeps its own .none (ApolloSwipeUpComments.xm).
static inline ApolloListRowScope ApolloCommentsTableRowScope(bool foundCommentsController,
                                                             bool mediaPaneController,
                                                             bool controllerOwnsTable,
                                                             bool liveUpdateSort) {
    if (!foundCommentsController || mediaPaneController || !controllerOwnsTable) {
        return ApolloListRowScopeNone;
    }
    return liveUpdateSort ? ApolloListRowScopeDeletesOnly : ApolloListRowScopeAccordion;
}

// The animation handed to UIKit for a row operation the accordion does not
// take over. Apollo's own animations are kept, except that an automatic delete
// on a comments thread slides up (Top): on newer UIKit the outgoing children
// can otherwise travel down while the rows below close the gap upwards.
static inline long ApolloListRowAnimationForOperation(ApolloListRowOperation operation,
                                                      long requested,
                                                      ApolloListRowScope scope) {
    if (scope != ApolloListRowScopeNone && operation == ApolloListRowOperationDelete &&
        requested == kApolloListRowAnimationAutomatic) {
        return kApolloListRowAnimationTop;
    }
    return requested;
}

static inline bool ApolloAccordionRowsAreOneRun(const long *rows, size_t count, long *first) {
    if (count == 0) return false;
    long lo = rows[0], hi = rows[0];
    for (size_t i = 1; i < count; i++) {
        if (rows[i] < lo) lo = rows[i];
        if (rows[i] > hi) hi = rows[i];
    }
    *first = lo;
    return (size_t)(hi - lo + 1) == count;   // rows are distinct (UIKit rejects anything else)
}

static inline bool ApolloAccordionRowsContainRow(const long *rows, size_t count, long row) {
    for (size_t i = 0; i < count; i++) {
        if (rows[i] == row) return true;
    }
    return false;
}

// Whether a batch (row operations in one section, all of them automatic, on a
// regular comments thread, Reduce Motion off) looks like one comment
// collapsing or expanding, before it commits. The rows it removes and the rows
// it adds must each form one run starting at the same row: the comment's row
// replaced along with its replies and separators, or, when only one side
// changes, the comment's row (right above the run) reloaded. Expand All,
// Collapse All, hiding a user and the like change several runs and keep
// Apollo's own animations. Whether it really is one comment collapsing or
// expanding is confirmed from the rows on screen once it has committed.
static inline bool ApolloAccordionBatchIsCandidate(const long *reloaded, size_t reloadedCount,
                                                   const long *deleted, size_t deletedCount,
                                                   const long *inserted, size_t insertedCount) {
    if (deletedCount == insertedCount) return false;   // nothing added or removed overall
    long deletedFirst = 0, insertedFirst = 0;
    bool deletedRun = ApolloAccordionRowsAreOneRun(deleted, deletedCount, &deletedFirst);
    bool insertedRun = ApolloAccordionRowsAreOneRun(inserted, insertedCount, &insertedFirst);
    if (deletedCount > 0 && !deletedRun) return false;
    if (insertedCount > 0 && !insertedRun) return false;
    if (deletedCount > 0 && insertedCount > 0) return deletedFirst == insertedFirst;
    long first = deletedCount > 0 ? deletedFirst : insertedFirst;
    return ApolloAccordionRowsContainRow(reloaded, reloadedCount, first - 1);
}

// The row of the comment a candidate batch collapses or expands, the same
// before and after it (every row above is unchanged): the row replaced at the
// start of both runs, or the reloaded row right above the one run. -1 when the
// batch is not a candidate.
static inline long ApolloAccordionBatchCommentRow(const long *reloaded, size_t reloadedCount,
                                                  const long *deleted, size_t deletedCount,
                                                  const long *inserted, size_t insertedCount) {
    if (!ApolloAccordionBatchIsCandidate(reloaded, reloadedCount, deleted, deletedCount, inserted, insertedCount)) {
        return -1;
    }
    long first = 0;
    if (deletedCount > 0) ApolloAccordionRowsAreOneRun(deleted, deletedCount, &first);
    else ApolloAccordionRowsAreOneRun(inserted, insertedCount, &first);
    return (deletedCount > 0 && insertedCount > 0) ? first : first - 1;
}

// A comment whose top is above the visible part of the list (scrolled past,
// or under the navigation bar) as it collapses or expands. Apollo then
// scrolls the list, animated, to put the comment's top at the top of the
// visible part: in the batch's completion, when the comment row's top minus
// the controller view's top safe area is above the scroll position, it calls
// setContentOffset:animated: with that difference. The accordion makes that
// scroll part of its own motion instead of a second one after a jump: it
// moves the list there as it commits the batch and animates the list with
// the accordion's spring, so the header comes down into view while the
// comment closes or opens (Apollo then finds nothing left to scroll). Up to
// one screen of comment above the visible part is drawn for this; a comment
// that starts further up keeps Apollo's own animations.
typedef enum ApolloAccordionRevealKind {
    ApolloAccordionRevealNone = 0,     // the comment's top is visible
    ApolloAccordionRevealScroll = 1,   // scroll to `offset` with the accordion
    ApolloAccordionRevealTooFar = 2,   // more than a screen above: Apollo's animations
} ApolloAccordionRevealKind;

typedef struct ApolloAccordionReveal {
    ApolloAccordionRevealKind kind;
    double offset;
} ApolloAccordionReveal;

static inline ApolloAccordionReveal ApolloAccordionRevealFor(double commentTop, double offset,
                                                             double topInset, double screenHeight) {
    ApolloAccordionReveal reveal = {ApolloAccordionRevealNone, offset};
    double target = commentTop - topInset;
    if (!(target < offset)) return reveal;   // Apollo's own test
    reveal.kind = offset - target > screenHeight ? ApolloAccordionRevealTooFar : ApolloAccordionRevealScroll;
    reveal.offset = target;
    return reveal;
}

typedef enum ApolloAccordionKind {
    ApolloAccordionKindNone = 0,
    ApolloAccordionKindCollapse = 1,
    ApolloAccordionKindExpand = 2,
} ApolloAccordionKind;

// One row on screen, before or after the batch, in table content coordinates.
// A comment is named by its fullName in both keys (its collapsed header and
// the expanded comment are the same comment). Any other row (separator, load
// more, post header) has no stable name: `headKey` names it by kind and its
// row counted from the top, which holds for rows above the change, and
// `tailKey` by kind and its row counted from the end, which holds for rows
// below it.
typedef struct ApolloAccordionRowGeometry {
    long headKey;
    long tailKey;
    double y;
    double height;
} ApolloAccordionRowGeometry;

typedef struct ApolloAccordionLayoutChange {
    ApolloAccordionKind kind;
    size_t oldParent;      // index into the old rows
    size_t newParent;      // index into the new rows
    // The first row below the change that was on screen both before and
    // after: its top before and after. Absent when none was.
    bool hasAnchor;
    double anchorOldY;
    double anchorNewY;
} ApolloAccordionLayoutChange;

static inline bool ApolloAccordionFindKey(const ApolloAccordionRowGeometry *rows, size_t from, size_t count,
                                          bool tail, long key, size_t *index) {
    for (size_t i = from; i < count; i++) {
        if ((tail ? rows[i].tailKey : rows[i].headKey) == key) {
            if (index) *index = i;
            return true;
        }
    }
    return false;
}

// Reads one comment collapsing or expanding from the rows on screen before
// and after the batch, both ordered top to bottom: every row above the comment
// is unchanged, the comment keeps its top but changes height, and right under
// it rows disappear (collapse, it got shorter) or appear (expand, it got
// taller). Rows can also scroll in from under the screen as a comment
// collapses, or be pushed off it as one expands. Anything else is not an
// accordion.
static inline ApolloAccordionLayoutChange ApolloAccordionLayoutChangeForRows(const ApolloAccordionRowGeometry *oldRows,
                                                                             size_t oldCount,
                                                                             const ApolloAccordionRowGeometry *newRows,
                                                                             size_t newCount) {
    ApolloAccordionLayoutChange none = {ApolloAccordionKindNone, 0, 0, false, 0, 0};
    const double tolerance = 0.5;
    for (size_t i = 0; i < oldCount; i++) {
        size_t j = 0;
        if (!ApolloAccordionFindKey(newRows, 0, newCount, false, oldRows[i].headKey, &j)) return none;
        if (fabs(newRows[j].y - oldRows[i].y) > tolerance) return none;
        if (fabs(newRows[j].height - oldRows[i].height) <= tolerance) continue;

        ApolloAccordionLayoutChange change = {ApolloAccordionKindNone, i, j, false, 0, 0};
        for (size_t k = i + 1; k < oldCount; k++) {
            size_t l = 0;
            if (ApolloAccordionFindKey(newRows, j + 1, newCount, true, oldRows[k].tailKey, &l)) {
                change.hasAnchor = true;
                change.anchorOldY = oldRows[k].y;
                change.anchorNewY = newRows[l].y;
                break;
            }
        }
        bool oldNextGone = i + 1 < oldCount &&
                           !ApolloAccordionFindKey(newRows, j + 1, newCount, true, oldRows[i + 1].tailKey, NULL);
        bool newNextFresh = j + 1 < newCount &&
                            !ApolloAccordionFindKey(oldRows, i + 1, oldCount, true, newRows[j + 1].tailKey, NULL);
        if (newRows[j].height < oldRows[i].height && (oldNextGone || i + 1 == oldCount)) {
            change.kind = ApolloAccordionKindCollapse;
        } else if (newRows[j].height > oldRows[i].height && (newNextFresh || j + 1 == newCount)) {
            change.kind = ApolloAccordionKindExpand;
        } else {
            return none;
        }
        return change;
    }
    return none;
}

// Where everything moves, in table content coordinates.
typedef struct ApolloAccordionPlan {
    // Collapse: the comment as it was, clipped from `parentFrom` down to
    // `parentTo` tall. Expand: the comment, masked from `parentFrom` up to
    // `parentTo` tall.
    double parentFrom;
    double parentTo;
    // Collapse: the replies that were on screen, `repliesHeight` tall from the
    // comment's old bottom, ride under its bottom edge. Expand: the rows below
    // as they were, `belowHeight` tall from its old bottom, slide down by
    // `belowTravel`.
    double repliesHeight;
    double belowHeight;
    double belowTravel;
    // Collapse: the rows below start `rowsBelowOffset` under their place.
    // Expand: the new replies start `repliesOffset` (negative) above theirs.
    double rowsBelowOffset;
    double repliesOffset;
} ApolloAccordionPlan;

static inline ApolloAccordionPlan ApolloAccordionPlanFor(ApolloAccordionKind kind,
                                                         double top, double oldBottom, double newBottom,
                                                         bool hasAnchor, double anchorOldY, double anchorNewY,
                                                         double visibleBottom) {
    ApolloAccordionPlan plan = {0, 0, 0, 0, 0, 0, 0};
    double visibleOldBottom = oldBottom < visibleBottom ? oldBottom : visibleBottom;
    double oldHeight = visibleOldBottom - top;
    double newHeight = newBottom - top;
    double room = visibleBottom - oldBottom;   // screen under the comment's old bottom
    if (room < 0) room = 0;
    bool anchorWasOnScreen = hasAnchor && anchorOldY < visibleBottom;
    if (kind == ApolloAccordionKindCollapse) {
        plan.parentFrom = oldHeight;
        plan.parentTo = newHeight < oldHeight ? newHeight : oldHeight;
        // The rows below keep their place relative to the first one that was
        // on screen; without one they come in from just under the screen.
        double offset = anchorWasOnScreen ? anchorOldY - anchorNewY : visibleBottom - newBottom;
        if (offset < 0) offset = 0;
        plan.rowsBelowOffset = offset;
        // The replies picture fills the rest: from the comment's old bottom to
        // where the rows below start.
        double replies = newBottom + offset - oldBottom;
        if (replies > room) replies = room;
        plan.repliesHeight = replies > 0 ? replies : 0;
    } else if (kind == ApolloAccordionKindExpand) {
        plan.parentFrom = oldBottom - top;
        plan.parentTo = newHeight;
        plan.belowHeight = room;
        double travel = anchorWasOnScreen ? anchorNewY - anchorOldY : room;
        if (travel > room) travel = room;
        plan.belowTravel = travel > 0 ? travel : 0;
        plan.repliesOffset = -(newBottom - oldBottom);
    }
    return plan;
}

// Lining up the comment's two states. The collapsed row and the expanded
// comment both start with the comment's header (author, score), but the
// collapsed row can place it lower and is a little taller, and only it shows
// the reply count on the right. From grayscale renders of the two (same
// width, one byte per pixel, `rowsPerPoint` rows per point), find:
// - `offset`: rows to move the expanded comment's header down to sit on the
//   collapsed row's (collapsed(y) matches expanded(y - offset)), searched
//   within +/- `maxOffset` rows over the leading `compareColumns` columns,
//   which keeps the reply count out of the comparison;
// - `headerRows`: the expanded comment's header band, from its top to where
//   the two stop matching (its body starts);
// - `chipColumn`: where, across the header band, they start to differ on the
//   right (the reply count), or `width` when they never do.
// `confident` is false when there is no header text to line up or when the
// best alignment is not clearly better than the others; the caller then keeps
// the plain clip.
typedef struct ApolloAccordionHeaderMatch {
    bool confident;
    long offset;
    long headerRows;
    long chipColumn;
} ApolloAccordionHeaderMatch;

static inline double ApolloAccordionRowDifference(const unsigned char *a, const unsigned char *b, long columns) {
    long total = 0;
    for (long x = 0; x < columns; x++) {
        int d = (int)a[x] - (int)b[x];
        total += d < 0 ? -d : d;
    }
    return columns > 0 ? (double)total / (double)columns : 0;
}

static inline ApolloAccordionHeaderMatch ApolloAccordionMatchHeaders(const unsigned char *collapsed, long collapsedRows,
                                                                    const unsigned char *expanded, long expandedRows,
                                                                    long width, long compareColumns,
                                                                    long maxOffset, long rowsPerPoint) {
    ApolloAccordionHeaderMatch none = {false, 0, 0, width};
    if (!collapsed || !expanded || width <= 0 || collapsedRows <= 0 || expandedRows <= 0) return none;
    if (compareColumns > width) compareColumns = width;
    const double rowTolerance = 6.0;   // mean gray difference of a matching row

    // The collapsed row must carry something to line up (rows with contrast);
    // only its rows down to the end of that text are compared, so the
    // expanded comment's body below its header never counts against a match.
    long textStart = -1, textEnd = 0;
    for (long y = 0; y < collapsedRows; y++) {
        const unsigned char *row = collapsed + y * width;
        unsigned char lo = 255, hi = 0;
        for (long x = 0; x < compareColumns; x++) {
            if (row[x] < lo) lo = row[x];
            if (row[x] > hi) hi = row[x];
        }
        if (hi - lo > 48) {
            if (textStart < 0) textStart = y;
            textEnd = y + 1;
        }
    }
    if (textEnd == 0) return none;

    double best = 1e9, runnerUp = 1e9;
    long bestOffset = 0;
    double scores[2 * 512 + 1];
    if (maxOffset > 512) maxOffset = 512;
    for (long o = -maxOffset; o <= maxOffset; o++) {
        double sum = 0;
        long rows = 0;
        for (long y = 0; y < textEnd; y++) {
            long ye = y - o;
            if (ye < 0 || ye >= expandedRows) continue;
            sum += ApolloAccordionRowDifference(collapsed + y * width, expanded + ye * width, compareColumns);
            rows++;
        }
        double score = rows * 2 >= textEnd && rows > 0 ? sum / (double)rows : 1e9;
        scores[o + maxOffset] = score;
        if (score < best) {
            best = score;
            bestOffset = o;
        }
    }
    // The runner-up must be a different alignment, more than a point away.
    for (long o = -maxOffset; o <= maxOffset; o++) {
        long distance = o > bestOffset ? o - bestOffset : bestOffset - o;
        if (distance > rowsPerPoint && scores[o + maxOffset] < runnerUp) runnerUp = scores[o + maxOffset];
    }
    if (best > 6.0 || runnerUp < best * 2.0 + 2.0) return none;

    // The header band: from the top of the expanded comment down through the
    // header text and on while it keeps matching the collapsed row; it ends at
    // the first row that does not (the body) or where the collapsed row ends.
    long headerRows = 0;
    for (long ye = textStart - bestOffset; ye < expandedRows; ye++) {
        long y = ye + bestOffset;
        if (ye < 0 || y < 0) continue;
        if (y >= collapsedRows) break;
        if (ApolloAccordionRowDifference(collapsed + y * width, expanded + ye * width, compareColumns) > rowTolerance) break;
        headerRows = ye + 1;
    }
    if (headerRows < rowsPerPoint * 8) return none;   // less than a line of text matched

    // The reply count: the leftmost column, right of the compared area, where
    // the header bands differ.
    long chipColumn = width;
    for (long x = width - 1; x >= compareColumns; x--) {
        bool differs = false;
        for (long ye = 0; ye < headerRows && !differs; ye++) {
            long y = ye + bestOffset;
            if (y < 0 || y >= collapsedRows) continue;
            int d = (int)collapsed[y * width + x] - (int)expanded[ye * width + x];
            differs = (d < 0 ? -d : d) > 48;
        }
        if (differs) chipColumn = x;
    }
    ApolloAccordionHeaderMatch match = {true, bestOffset, headerRows, chipColumn};
    return match;
}

// A collapsed comment's header line sits exactly where the expanded comment's
// does. Apollo lays both headers out as one horizontal stack of items centred
// on the tallest: the collapsed row's stack also holds the reply count and the
// disclosure arrow, the expanded one the options button instead, so whichever
// is taller moves the shared items (author, score, flair) down by half the
// difference. Given the tallest shared item and the tallest item each state
// adds, returns how far to move the collapsed header line (negative: up) so it
// lands where the expanded one is; the collapsed row is shortened by a move
// up and never made taller by a move down. ApolloCommentHeaderShift.m reads
// the exact move from Texture's layout of both rows (its pixel rounding
// included) and falls back to this when a layout cannot be read.
static inline double ApolloCollapsedHeaderShift(double sharedHeight,
                                                double expandedOnlyHeight,
                                                double collapsedOnlyHeight) {
    double expandedRow = sharedHeight > expandedOnlyHeight ? sharedHeight : expandedOnlyHeight;
    double collapsedRow = sharedHeight > collapsedOnlyHeight ? sharedHeight : collapsedOnlyHeight;
    return (expandedRow - collapsedRow) / 2.0;
}

// The fresh cells of an accordion batch (the comment's row and the first new
// rows) are drawn synchronously while it commits, so they never show empty:
// Texture draws a fresh cell node asynchronously. Only a handful, and only
// rows that come on screen are drawn at all.
static const size_t kApolloListPredrawMaxRows = 4;

static inline size_t ApolloAccordionPredrawRowCount(size_t freshRows) {
    return freshRows < kApolloListPredrawMaxRows ? freshRows : kApolloListPredrawMaxRows;
}

#endif
