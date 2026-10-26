#include <assert.h>
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "ApolloListRowAnimationPolicy.h"

#define COUNT(array) (sizeof(array) / sizeof((array)[0]))

static unsigned sChecks = 0;
#define CHECK(condition) do { sChecks++; assert(condition); } while (0)

static void test_scope_gate(void) {
    // Only a regular comments thread that owns the table gets the accordion.
    CHECK(ApolloCommentsTableRowScope(true, false, true, false) == ApolloListRowScopeAccordion);
    // Live Update keeps its native inserts (ApolloLiveCommentsFollow anchors
    // against them); only the upward delete applies.
    CHECK(ApolloCommentsTableRowScope(true, false, true, true) == ApolloListRowScopeDeletesOnly);
    // Every other table: another controller, the media pane, or a table the
    // comments controller does not own.
    CHECK(ApolloCommentsTableRowScope(false, false, true, false) == ApolloListRowScopeNone);
    CHECK(ApolloCommentsTableRowScope(true, true, true, false) == ApolloListRowScopeNone);
    CHECK(ApolloCommentsTableRowScope(true, true, true, true) == ApolloListRowScopeNone);
    CHECK(ApolloCommentsTableRowScope(true, false, false, false) == ApolloListRowScopeNone);
}

static void test_row_animations(void) {
    const long automatic = kApolloListRowAnimationAutomatic;
    const ApolloListRowOperation operations[] = {
        ApolloListRowOperationReload, ApolloListRowOperationInsert, ApolloListRowOperationDelete,
    };
    const ApolloListRowScope threads[] = {ApolloListRowScopeAccordion, ApolloListRowScopeDeletesOnly};
    for (unsigned s = 0; s < COUNT(threads); s++) {
        // Batches the accordion does not take over keep Apollo's animations,
        // except the upward automatic delete on a comments thread.
        CHECK(ApolloListRowAnimationForOperation(ApolloListRowOperationDelete, automatic, threads[s]) ==
               kApolloListRowAnimationTop);
        CHECK(ApolloListRowAnimationForOperation(ApolloListRowOperationReload, automatic, threads[s]) == automatic);
        CHECK(ApolloListRowAnimationForOperation(ApolloListRowOperationInsert, automatic, threads[s]) == automatic);
    }
    for (unsigned i = 0; i < COUNT(operations); i++) {
        CHECK(ApolloListRowAnimationForOperation(operations[i], automatic, ApolloListRowScopeNone) == automatic);
        for (long requested = 0; requested <= 6; requested++) {
            for (unsigned s = 0; s < COUNT(threads); s++) {
                CHECK(ApolloListRowAnimationForOperation(operations[i], requested, threads[s]) == requested);
            }
        }
    }
}

static bool candidate(const long *reloaded, size_t nr, const long *deleted, size_t nd, const long *inserted, size_t ni) {
    return ApolloAccordionBatchIsCandidate(reloaded, nr, deleted, nd, inserted, ni);
}

static void test_candidates(void) {
    const long parent[] = {5};
    const long above[] = {4};
    const long replies[] = {8, 6, 7};
    const long withParent[] = {5, 6, 7, 8};
    const long withParentAndSeparator[] = {5, 6, 7, 8, 9};
    const long parentAndSeparator[] = {5, 6};
    const long neighbours[] = {4, 10};
    // Collapse: the comment reloaded, its replies removed ...
    CHECK(candidate(parent, 1, replies, 3, NULL, 0));
    // ... or its row replaced along with its replies (and a separator) ...
    CHECK(candidate(NULL, 0, withParent, 4, parent, 1));
    CHECK(candidate(neighbours, 2, withParentAndSeparator, 5, parentAndSeparator, 2));
    // Expand, the same ways.
    CHECK(candidate(parent, 1, NULL, 0, replies, 3));
    CHECK(candidate(NULL, 0, parent, 1, withParent, 4));
    CHECK(candidate(neighbours, 2, parentAndSeparator, 2, withParentAndSeparator, 5));

    // Kept with Apollo's animations.
    const long two[] = {6, 9};
    const long split[] = {6, 7, 12, 13};
    CHECK(!candidate(parent, 1, NULL, 0, NULL, 0));            // an edit or a vote
    CHECK(!candidate(NULL, 0, replies, 3, NULL, 0));           // rows removed under an unchanged row (delete, hide)
    CHECK(!candidate(above, 1, two, 2, NULL, 0));              // not one run
    CHECK(!candidate(parent, 1, split, 4, NULL, 0));           // Collapse All: several runs
    CHECK(!candidate(parent, 1, NULL, 0, split, 4));           // Expand All
    CHECK(!candidate(NULL, 0, withParent, 4, above, 1));       // the runs start apart
    CHECK(!candidate(NULL, 0, parent, 1, parent, 1));          // nothing added or removed
    CHECK(!candidate(NULL, 0, NULL, 0, NULL, 0));
}

static long commentRow(const long *reloaded, size_t nr, const long *deleted, size_t nd, const long *inserted, size_t ni) {
    return ApolloAccordionBatchCommentRow(reloaded, nr, deleted, nd, inserted, ni);
}

static void test_comment_rows(void) {
    const long parent[] = {5};
    const long replies[] = {8, 6, 7};
    const long withParent[] = {5, 6, 7, 8};
    const long parentAndSeparator[] = {5, 6};
    const long neighbours[] = {4, 10};
    // The reloaded row right above the replies ...
    CHECK(commentRow(parent, 1, replies, 3, NULL, 0) == 5);
    CHECK(commentRow(parent, 1, NULL, 0, replies, 3) == 5);
    // ... or the row replaced at the start of both runs.
    CHECK(commentRow(NULL, 0, withParent, 4, parent, 1) == 5);
    CHECK(commentRow(neighbours, 2, parentAndSeparator, 2, withParent, 4) == 5);
    // Not a candidate: no comment.
    const long split[] = {6, 7, 12, 13};
    CHECK(commentRow(parent, 1, split, 4, NULL, 0) == -1);
    CHECK(commentRow(NULL, 0, replies, 3, NULL, 0) == -1);
    CHECK(commentRow(NULL, 0, NULL, 0, NULL, 0) == -1);
}

static void test_reveal(void) {
    // Thread scrolled to 643 under a 116 pt bar and status area, on an 874 pt
    // screen. A 505 pt comment at 480 (163 pt above the screen, 279 pt above
    // the visible part) is tapped near its bottom: Apollo scrolls to 364 to
    // show its top under the bar, and the accordion takes that scroll.
    ApolloAccordionReveal r = ApolloAccordionRevealFor(480, 643, 116, 874);
    CHECK(r.kind == ApolloAccordionRevealScroll && r.offset == 364);
    // A comment whose top is in view, or exactly at the top of the visible
    // part, scrolls nothing.
    r = ApolloAccordionRevealFor(900, 643, 116, 874);
    CHECK(r.kind == ApolloAccordionRevealNone && r.offset == 643);
    r = ApolloAccordionRevealFor(759, 643, 116, 874);
    CHECK(r.kind == ApolloAccordionRevealNone);
    // Under the bar only (on screen but not visible): scrolled into view too.
    r = ApolloAccordionRevealFor(700, 643, 116, 874);
    CHECK(r.kind == ApolloAccordionRevealScroll && r.offset == 584);
    // Up to a screen above the visible part is drawn; further up keeps
    // Apollo's animations.
    r = ApolloAccordionRevealFor(759 - 874, 643, 116, 874);
    CHECK(r.kind == ApolloAccordionRevealScroll && r.offset == 643 - 874);
    r = ApolloAccordionRevealFor(759 - 875, 643, 116, 874);
    CHECK(r.kind == ApolloAccordionRevealTooFar && r.offset == 643 - 875);
    // Apollo's test is strict: a point above the visible part scrolls.
    r = ApolloAccordionRevealFor(758, 643, 116, 874);
    CHECK(r.kind == ApolloAccordionRevealScroll && r.offset == 642);
}

typedef ApolloAccordionRowGeometry Row;

// Production keys: a comment has one key for both; any other row is keyed by
// kind and position, so it changes key when it moves (head counted from the
// top of the list, tail from the end).
#define COMMENT(id, y, h) {(id), (id), (y), (h)}
#define OTHER(head, tail, y, h) {(head), (tail), (y), (h)}

static ApolloAccordionLayoutChange change(const Row *old, size_t oldCount, const Row *now, size_t newCount) {
    return ApolloAccordionLayoutChangeForRows(old, oldCount, now, newCount);
}

static void test_layout_changes(void) {
    // Rows 0..: header (kind 900 + row), separator above, the comment 3, its
    // replies 10.., then a separator and the next comment 20. List of 40 rows
    // before, 36 after collapse (tail keys stay put below the change).
    const Row oldCollapse[] = {
        OTHER(900, 940, 0, 100), OTHER(901, 941, 100, 10), COMMENT(3, 110, 200),
        COMMENT(10, 310, 60), COMMENT(11, 370, 80), OTHER(906, 934, 450, 10), COMMENT(20, 460, 80),
    };
    const Row newCollapse[] = {
        OTHER(900, 936, 0, 100), OTHER(901, 937, 100, 10), COMMENT(3, 110, 40),
        OTHER(903, 934, 150, 10), COMMENT(20, 160, 80), COMMENT(21, 240, 80),
    };
    ApolloAccordionLayoutChange c = change(oldCollapse, COUNT(oldCollapse), newCollapse, COUNT(newCollapse));
    CHECK(c.kind == ApolloAccordionKindCollapse && c.oldParent == 2 && c.newParent == 2);
    // Anchored on the separator under the replies, which moved (new head key)
    // but kept its place from the end.
    CHECK(c.hasAnchor && c.anchorOldY == 450 && c.anchorNewY == 150);

    // Expand is the mirror.
    c = change(newCollapse, COUNT(newCollapse), oldCollapse, COUNT(oldCollapse));
    CHECK(c.kind == ApolloAccordionKindExpand && c.hasAnchor && c.anchorOldY == 150 && c.anchorNewY == 450);

    // Replies running past the screen: nothing below was on screen before.
    const Row oldLong[] = {OTHER(900, 940, 0, 100), COMMENT(3, 100, 200), COMMENT(10, 300, 300), COMMENT(11, 600, 300)};
    const Row newLong[] = {OTHER(900, 910, 0, 100), COMMENT(3, 100, 40), OTHER(902, 908, 140, 10), COMMENT(20, 150, 80)};
    c = change(oldLong, COUNT(oldLong), newLong, COUNT(newLong));
    CHECK(c.kind == ApolloAccordionKindCollapse && !c.hasAnchor);
    c = change(newLong, COUNT(newLong), oldLong, COUNT(oldLong));
    CHECK(c.kind == ApolloAccordionKindExpand && !c.hasAnchor);

    // End of a thread: only a load-more row after the subtree. It is matched
    // from the end, so it is not taken for a new row (shown twice) or a reply.
    const Row oldEnd[] = {COMMENT(3, 100, 200), COMMENT(10, 300, 60), OTHER(905, 950, 360, 44)};
    const Row newEnd[] = {COMMENT(3, 100, 40), OTHER(904, 950, 140, 44)};
    c = change(oldEnd, COUNT(oldEnd), newEnd, COUNT(newEnd));
    CHECK(c.kind == ApolloAccordionKindCollapse && c.hasAnchor && c.anchorOldY == 360 && c.anchorNewY == 140);

    // Not an accordion: a row above moved, a plain delete (no row changed
    // height), the comment moved, rows appearing under a comment that got
    // shorter, empty input.
    const Row aboveMovedOld[] = {COMMENT(1, 0, 100), COMMENT(3, 100, 200), COMMENT(10, 300, 60)};
    const Row aboveMovedNew[] = {COMMENT(1, 0, 90), COMMENT(3, 90, 40)};
    CHECK(change(aboveMovedOld, 3, aboveMovedNew, 2).kind == ApolloAccordionKindNone);
    const Row deleteOld[] = {COMMENT(1, 0, 100), COMMENT(10, 100, 60), COMMENT(20, 160, 80)};
    const Row deleteNew[] = {COMMENT(1, 0, 100), COMMENT(20, 100, 80)};
    CHECK(change(deleteOld, 3, deleteNew, 2).kind == ApolloAccordionKindNone);
    const Row movedNew[] = {COMMENT(1, 0, 100), COMMENT(3, 140, 40)};
    CHECK(change(aboveMovedOld, 3, movedNew, 2).kind == ApolloAccordionKindNone);
    const Row shorterOld[] = {COMMENT(1, 0, 100), COMMENT(3, 100, 200), COMMENT(20, 300, 60)};
    const Row shorterNew[] = {COMMENT(1, 0, 100), COMMENT(3, 100, 40), COMMENT(30, 140, 60), COMMENT(20, 200, 60)};
    CHECK(change(shorterOld, 3, shorterNew, 4).kind == ApolloAccordionKindNone);
    CHECK(change(NULL, 0, NULL, 0).kind == ApolloAccordionKindNone);
}

static void test_plans(void) {
    // Collapse 110..310 to 110..150, replies to 450, the rows below (from the
    // separator at 450) end up at 150: they start exactly where they were.
    ApolloAccordionPlan p = ApolloAccordionPlanFor(ApolloAccordionKindCollapse, 110, 310, 150, true, 450, 150, 800);
    CHECK(p.parentFrom == 200 && p.parentTo == 40);
    CHECK(p.rowsBelowOffset == 300);                 // 150 + 300 = 450, no jump
    CHECK(p.repliesHeight == 140);                   // 310..450, the old separator not included
    // Replies past the screen: the rows below come in from just under it, and
    // the replies picture fills the rest of the screen.
    p = ApolloAccordionPlanFor(ApolloAccordionKindCollapse, 110, 310, 150, false, 0, 0, 800);
    CHECK(p.rowsBelowOffset == 650 && p.repliesHeight == 490);
    // A comment taller than the screen is clipped from what was on screen.
    p = ApolloAccordionPlanFor(ApolloAccordionKindCollapse, 110, 2000, 150, false, 0, 0, 800);
    CHECK(p.parentFrom == 690 && p.parentTo == 40 && p.repliesHeight == 0);

    // Expand 110..150 to 110..310 with the rows below (anchor 150 -> 450): the
    // picture of the rows below lands exactly on them, no pop.
    p = ApolloAccordionPlanFor(ApolloAccordionKindExpand, 110, 150, 310, true, 150, 450, 800);
    CHECK(p.parentFrom == 40 && p.parentTo == 200);
    CHECK(p.belowHeight == 650 && p.belowTravel == 300 && p.repliesOffset == -160);
    // Anchor pushed off the screen: the picture leaves the screen.
    p = ApolloAccordionPlanFor(ApolloAccordionKindExpand, 110, 150, 310, true, 150, 1450, 800);
    CHECK(p.belowTravel == 650);
    p = ApolloAccordionPlanFor(ApolloAccordionKindExpand, 110, 150, 310, false, 0, 0, 800);
    CHECK(p.belowTravel == 650);
}

enum { W = 200 };

static void fill(unsigned char *image, long rows, unsigned char value) {
    memset(image, value, (size_t)(rows * W));
}

static void block(unsigned char *image, long y0, long y1, long x0, long x1, unsigned char value) {
    for (long y = y0; y < y1; y++) {
        for (long x = x0; x < x1; x++) image[y * W + x] = value;
    }
}

static void test_header_alignment(void) {
    // Two rows per point. The collapsed row (52 pt) shows the name 8 pt lower
    // than the expanded comment does, plus a reply count on the right; the
    // expanded comment has its own byline on the right and a body below.
    static unsigned char collapsed[104 * W], expanded[200 * W];
    fill(collapsed, 104, 40);
    block(collapsed, 28, 44, 10, 90, 230);     // name, 8 pt (16 rows) lower
    block(collapsed, 28, 44, 160, 190, 180);   // reply count
    fill(expanded, 200, 40);
    block(expanded, 12, 28, 10, 90, 230);      // name
    block(expanded, 12, 28, 170, 190, 150);    // byline
    block(expanded, 64, 120, 10, 180, 210);    // body
    ApolloAccordionHeaderMatch m = ApolloAccordionMatchHeaders(collapsed, 104, expanded, 200, W, 120, 48, 2);
    CHECK(m.confident && m.offset == 16);
    CHECK(m.headerRows == 64);                // through the header, up to the body
    CHECK(m.chipColumn == 160);               // the reply count area

    // A separator antialiased into the first row does not end the header band.
    expanded[0 * W + 5] = 255;
    for (long x = 0; x < W; x++) expanded[x] = 60;
    m = ApolloAccordionMatchHeaders(collapsed, 104, expanded, 200, W, 120, 48, 2);
    CHECK(m.confident && m.offset == 16 && m.headerRows == 64);

    // Nothing to line up: no text in the collapsed row.
    static unsigned char blank[104 * W];
    fill(blank, 104, 40);
    CHECK(!ApolloAccordionMatchHeaders(blank, 104, expanded, 200, W, 120, 48, 2).confident);

    // Ambiguous: evenly repeating stripes line up at several offsets.
    static unsigned char stripes[104 * W], stripesExpanded[200 * W];
    fill(stripes, 104, 40);
    fill(stripesExpanded, 200, 40);
    for (long y = 0; y < 104; y += 8) block(stripes, y, y + 4, 10, 90, 230);
    for (long y = 0; y < 200; y += 8) block(stripesExpanded, y, y + 4, 10, 90, 230);
    CHECK(!ApolloAccordionMatchHeaders(stripes, 104, stripesExpanded, 200, W, 120, 48, 2).confident);

    // Different headers (another comment) do not line up.
    static unsigned char other[200 * W];
    fill(other, 200, 40);
    block(other, 12, 28, 100, 118, 230);
    CHECK(!ApolloAccordionMatchHeaders(collapsed, 104, other, 200, W, 120, 48, 2).confident);
}

static void test_collapsed_header_shift(void) {
    // The reply count makes the collapsed header row taller than the author
    // line: the collapsed row moves its header line up by half the difference,
    // which is where the expanded row (no count) has it.
    CHECK(ApolloCollapsedHeaderShift(17, 0, 22) == -2.5);
    // The expanded row's options button is the tallest: both rows are as
    // tall, nothing moves.
    CHECK(ApolloCollapsedHeaderShift(17, 22, 22) == 0);
    // The expanded row is the taller one: the collapsed line moves down.
    CHECK(ApolloCollapsedHeaderShift(17, 24, 20) == 2);
    // Neither state adds anything taller than the shared items.
    CHECK(ApolloCollapsedHeaderShift(20, 18, 19) == 0);
}

static void test_predraw(void) {
    CHECK(ApolloAccordionPredrawRowCount(0) == 0);
    CHECK(ApolloAccordionPredrawRowCount(3) == 3);
    CHECK(ApolloAccordionPredrawRowCount(91) == kApolloListPredrawMaxRows);
    CHECK(kApolloListPredrawMaxRows == 4);
}

int main(void) {
    test_scope_gate();
    test_row_animations();
    test_candidates();
    test_comment_rows();
    test_reveal();
    test_layout_changes();
    test_plans();
    test_header_alignment();
    test_collapsed_header_shift();
    test_predraw();
    printf("list_row_animation_policy_tests passed (%u checks)\n", sChecks);
    return 0;
}
