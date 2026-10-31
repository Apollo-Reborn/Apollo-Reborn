#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// INCLUDE_PRODUCTION_INTERACTIVE_CLOSE
static NSUInteger checks;
static void Check(BOOL valid, NSString *message) {
    checks++;
    if (!valid) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static BOOL Near(CGFloat a, CGFloat b) { return fabs(a - b) < 0.0001; }
static BOOL SameRect(CGRect a, CGRect b) {
    return Near(a.origin.x, b.origin.x) && Near(a.origin.y, b.origin.y)
        && Near(a.size.width, b.size.width) && Near(a.size.height, b.size.height);
}
int main(void) {
    @autoreleasepool {
        // Phases: the flag is set from Begin until the drag has handed over
        // (commit), sprung back, or been interrupted.
        typedef ApolloDuoPostsClosePhase Phase;
        Phase idle = ApolloDuoPostsClosePhaseIdle, tracking = ApolloDuoPostsClosePhaseTracking,
              returning = ApolloDuoPostsClosePhaseReturning;
        Check(ApolloDuoPostsClosePhaseAfter(idle, ApolloDuoPostsCloseEventBegin) == tracking,
              @"phase: a drag begins from idle");
        Check(ApolloDuoPostsClosePhaseAfter(tracking, ApolloDuoPostsCloseEventBegin) == tracking
              && ApolloDuoPostsClosePhaseAfter(returning, ApolloDuoPostsCloseEventBegin) == returning,
              @"phase: Begin never replaces a drag in progress; the old one is interrupted first");
        Check(ApolloDuoPostsClosePhaseAfter(tracking, ApolloDuoPostsCloseEventCommit) == idle,
              @"phase: a commit hands over to the close and clears the flag, so the close's column sync runs");
        Check(ApolloDuoPostsClosePhaseAfter(returning, ApolloDuoPostsCloseEventCommit) == returning
              && ApolloDuoPostsClosePhaseAfter(idle, ApolloDuoPostsCloseEventCommit) == idle,
              @"phase: only a tracking drag commits (no second Back from a spring-back or no drag)");
        Check(ApolloDuoPostsClosePhaseAfter(tracking, ApolloDuoPostsCloseEventSpringBack) == returning,
              @"phase: a short release springs back with the flag still set");
        Check(ApolloDuoPostsClosePhaseAfter(idle, ApolloDuoPostsCloseEventSpringBack) == idle
              && ApolloDuoPostsClosePhaseAfter(returning, ApolloDuoPostsCloseEventSpringBack) == returning,
              @"phase: nothing to spring back unless tracking");
        Check(ApolloDuoPostsClosePhaseAfter(returning, ApolloDuoPostsCloseEventReturned) == idle,
              @"phase: the finished spring-back clears the flag");
        Check(ApolloDuoPostsClosePhaseAfter(tracking, ApolloDuoPostsCloseEventReturned) == tracking
              && ApolloDuoPostsClosePhaseAfter(idle, ApolloDuoPostsCloseEventReturned) == idle,
              @"phase: a stale spring-back completion cannot end a newer drag");
        Check(ApolloDuoPostsClosePhaseAfter(tracking, ApolloDuoPostsCloseEventInterrupt) == idle
              && ApolloDuoPostsClosePhaseAfter(returning, ApolloDuoPostsCloseEventInterrupt) == idle
              && ApolloDuoPostsClosePhaseAfter(idle, ApolloDuoPostsCloseEventInterrupt) == idle,
              @"phase: an interruption clears the flag from any phase");

        // Where the finger puts the thread: never left of the pane, never
        // further than off its trailing edge.
        Check(Near(ApolloDuoPostsCloseOffset(-20, 475), 0), @"offset: a leftward drag keeps the thread in place");
        Check(Near(ApolloDuoPostsCloseOffset(120, 475), 120), @"offset: the thread follows the finger");
        Check(Near(ApolloDuoPostsCloseOffset(900, 475), 475), @"offset: the thread stops once it is off the pane");
        Check(Near(ApolloDuoPostsCloseProgress(118.75, 475), 0.25) && Near(ApolloDuoPostsCloseProgress(900, 475), 1)
              && Near(ApolloDuoPostsCloseProgress(-5, 475), 0) && Near(ApolloDuoPostsCloseProgress(40, 0), 0),
              @"progress: offset over the pane width, clamped, zero for an empty pane");
        Check(Near(ApolloDuoPostsCloseShadowOpacity(0), 0.3) && Near(ApolloDuoPostsCloseShadowOpacity(0.5), 0.15)
              && Near(ApolloDuoPostsCloseShadowOpacity(1), 0) && Near(ApolloDuoPostsCloseShadowOpacity(-1), 0.3)
              && Near(ApolloDuoPostsCloseShadowOpacity(2), 0),
              @"shadow: Apollo's Back shadow (0.3) fades out as the thread leaves");

        // The gap the thread uncovers: [pane.minX, 0, dx, H].
        CGRect pane = CGRectMake(476, 0, 475, 900);
        Check(SameRect(ApolloDuoPostsCloseExtensionFrame(pane, 120), CGRectMake(476, 0, 120, 900)),
              @"extension: covers exactly what the thread uncovered");
        Check(SameRect(ApolloDuoPostsCloseExtensionFrame(pane, 0), CGRectMake(476, 0, 0, 900))
              && SameRect(ApolloDuoPostsCloseExtensionFrame(pane, -8), CGRectMake(476, 0, 0, 900)),
              @"extension: nothing before the thread moves");
        CGFloat travel = 475;
        Check(Near(travel * ApolloDuoPostsCloseExtensionScale(120, travel), CGRectGetWidth(ApolloDuoPostsCloseExtensionFrame(pane, 120))),
              @"extension: the full-travel view scaled from its leading edge shows the same frame");
        Check(Near(ApolloDuoPostsCloseExtensionScale(900, travel), 1) && Near(ApolloDuoPostsCloseExtensionScale(120, 0), 1),
              @"extension: at most the full travel");
        CGFloat floorScale = ApolloDuoPostsCloseExtensionScale(0, travel);
        Check(floorScale > 0 && floorScale * travel < 1,
              @"extension: at rest it stays invertible and under a point wide, hidden by the thread");

        // The smear: a 1pt column stretched between 1pt caps, taken clear of
        // the divider, the scroll indicator and right-aligned row controls.
        CGRect column = ApolloDuoPostsCloseSmearColumn(476, pane);
        Check(Near(CGRectGetWidth(column), 3) && Near(CGRectGetMinY(column), 0) && Near(CGRectGetHeight(column), 900),
              @"smear: one stretched point between two caps, the pane's height");
        Check(CGRectGetMaxX(column) <= 476 - 8 + 0.0001 && CGRectGetMaxX(column) > 476 - 20,
              @"smear: just inside the feed's trailing content margin, 8pt clear of its edge");
        Check(Near(CGRectGetMaxX(ApolloDuoPostsCloseSmearColumn(400, pane)), 392),
              @"smear: measured from the feed's own trailing edge");
        // Only the bar band is smeared; rows (the open post's highlight, a
        // more button reaching the column, separators) never reach the gap.
        CGRect band = ApolloDuoPostsCloseSmearBand(column, 140);
        Check(SameRect(band, CGRectMake(CGRectGetMinX(column), 0, 3, 140)),
              @"smear band: the column from the pane's top down to the feed's content top");
        Check(SameRect(ApolloDuoPostsCloseSmearBand(column, 2000), column),
              @"smear band: never taller than the pane");
        Check(CGRectIsNull(ApolloDuoPostsCloseSmearBand(column, 0)) && CGRectIsNull(ApolloDuoPostsCloseSmearBand(column, -10)),
              @"smear band: none when the feed has no bar above its content");
        Check(SameRect(ApolloDuoPostsCloseSmearBand(ApolloDuoPostsCloseSmearColumn(476, CGRectMake(476, 20, 475, 880)), 140),
                       CGRectMake(476 - 11, 20, 3, 120)),
              @"smear band: measured from the pane's own top");

        // The spring takes the finger's velocity per point still to travel,
        // positive toward its end, and never so fast that it overshoots.
        Check(Near(ApolloDuoPostsSpringVelocity(100, 475, 750), 2), @"spring: release velocity over the remaining slide");
        Check(Near(ApolloDuoPostsSpringVelocity(100, 0, -500), 5), @"spring: a leftward release springs back toward the pane");
        Check(Near(ApolloDuoPostsSpringVelocity(100, 0, 500), -5), @"spring: a rightward release short of the threshold first carries on");
        Check(Near(ApolloDuoPostsSpringVelocity(100, 0, -3000), kApolloDuoPostsSpringOmega),
              @"spring: springing back is capped at the critical rate, so the thread never overshoots over the feed");
        Check(Near(ApolloDuoPostsSpringVelocity(420, 475, 1500), 1500.0 / 55.0),
              @"spring: a fast flick near the end of the commit keeps its speed (an overshoot only leaves the screen)");
        Check(Near(ApolloDuoPostsSpringVelocity(200, 200.5, 900), 0), @"spring: nothing left to travel, no velocity");

        // The replay finishes the feed's widening in the slide's remaining time.
        Check(Near(ApolloDuoPostsCloseRemaining(0.1), 0.22) && Near(ApolloDuoPostsCloseRemaining(-1), kApolloDuoPostsCloseDuration),
              @"remaining: the close's 0.32s less what the slide has already run");
        Check(Near(ApolloDuoPostsCloseRemaining(0.3), 0) && Near(ApolloDuoPostsCloseRemaining(0.5), 0),
              @"remaining: too little left to replay (a long stall) skips the replay");

        // The inflated root: the feed's containers start as wide as the
        // cover, leading edge fixed, so no strip opens beyond the narrow rows.
        CGRect bounds = CGRectMake(0, 0, 476, 900), frame = CGRectMake(0, 0, 476, 900);
        CGPoint position = CGPointMake(238, 450);
        ApolloDuoPostsInflateGeometry(&bounds, &position, &frame, 0.5, 475);
        Check(Near(CGRectGetWidth(bounds), 951) && Near(CGRectGetWidth(frame), 951) && Near(CGRectGetMinX(frame), 0),
              @"inflate: bounds and surface frame widen by the expansion");
        Check(Near(position.x - CGRectGetWidth(bounds) * 0.5, 0) && Near(position.y, 450),
              @"inflate: the leading edge stays where it was");
        bounds = CGRectMake(0, 0, 476, 900); position = CGPointMake(0, 450); frame = CGRectMake(10, 0, 476, 900);
        ApolloDuoPostsInflateGeometry(&bounds, &position, &frame, 0, 100);
        Check(Near(position.x, 0) && Near(CGRectGetWidth(bounds), 576) && Near(CGRectGetMinX(frame), 10),
              @"inflate: a leading anchor does not move");

        // Which captured surfaces start at full width: those that spanned the
        // feed column (table, bar, its material, full-bleed rows), not inset ones.
        CGRect feedColumn = CGRectMake(0, 0, 476, 900);
        Check(ApolloDuoPostsSpansColumn(CGRectMake(0, 0, 476, 120), feedColumn)
              && ApolloDuoPostsSpansColumn(CGRectMake(0.4, 300, 475.8, 90), feedColumn),
              @"spans: the bar band and a full-bleed row span the column (sub-point rounding allowed)");
        Check(!ApolloDuoPostsSpansColumn(CGRectMake(16, 60, 444, 36), feedColumn)
              && !ApolloDuoPostsSpansColumn(CGRectMake(0, 300, 300, 90), feedColumn)
              && !ApolloDuoPostsSpansColumn(CGRectMake(120, 300, 356, 90), feedColumn),
              @"spans: an inset search field, a leading thumbnail strip and trailing content keep their own replay");
        Check(!ApolloDuoPostsSpansColumn(CGRectMake(0, 0, 0, 900), feedColumn)
              && !ApolloDuoPostsSpansColumn(CGRectMake(0, 0, 476, 900), CGRectZero),
              @"spans: nothing for an empty surface or column");
        // Rows that only come on screen as the feed widens start below their
        // place, following the retained row above them as it moves up.
        CGRect before[] = {CGRectMake(0, 0, 476, 120), CGRectMake(0, 120, 476, 160), CGRectMake(0, 280, 476, 140)};
        CGRect after[] = {CGRectMake(0, 0, 951, 90), CGRectMake(0, 90, 951, 100), CGRectMake(0, 190, 951, 100)};
        Check(Near(ApolloDuoPostsEnteringRowShift(before, after, 3, CGRectMake(0, 290, 951, 100)), 130),
              @"entering: the next row starts as far below as the last retained row moved up");
        Check(Near(ApolloDuoPostsEnteringRowShift(before, after, 3, CGRectMake(0, 390, 951, 80)), 130),
              @"entering: every row after it follows by the same amount, so they come in together");
        CGRect shuffled[] = {after[2], after[0], after[1]}, shuffledBefore[] = {before[2], before[0], before[1]};
        Check(Near(ApolloDuoPostsEnteringRowShift(shuffledBefore, shuffled, 3, CGRectMake(0, 290, 951, 100)), 130),
              @"entering: the nearest retained row above, whatever the order the rows are found in");
        CGRect lower[] = {CGRectMake(0, 500, 476, 100)}, lowerAfter[] = {CGRectMake(0, 300, 951, 80)};
        Check(Near(ApolloDuoPostsEnteringRowShift(lower, lowerAfter, 1, CGRectMake(0, 200, 951, 100)), 200),
              @"entering: with none above, it moves with the nearest retained row below");
        Check(Near(ApolloDuoPostsEnteringRowShift(before, after, 0, CGRectMake(0, 290, 951, 100)), 0),
              @"entering: nothing to follow, no shift");
        // The forward swipe's restore, the close mirrored: one offset, the
        // page's distance right of the thread pane's place. The close starts
        // at 0 and commits off the pane; the restore starts off the pane
        // (the screen's edge) and commits at 0.
        Check(Near(ApolloDuoPostsDragOffset(NO, 120, 475), 120) && Near(ApolloDuoPostsDragOffset(NO, -20, 475), 0),
              @"offset: the close's offset is the rightward drag, as before");
        Check(Near(ApolloDuoPostsDragOffset(YES, 0, 475), 475),
              @"restore offset: at Began the thread waits fully off screen, right of its pane");
        Check(Near(ApolloDuoPostsDragOffset(YES, -120, 475), 355),
              @"restore offset: it comes in with the leftward finger");
        Check(Near(ApolloDuoPostsDragOffset(YES, -900, 475), 0) && Near(ApolloDuoPostsDragOffset(YES, 60, 475), 475),
              @"restore offset: it stops at its pane, and never leaves past the screen's edge");
        Check(Near(ApolloDuoPostsDragTarget(NO, YES, 475), 475) && Near(ApolloDuoPostsDragTarget(NO, NO, 475), 0),
              @"target: the close commits off the pane and springs back onto it");
        Check(Near(ApolloDuoPostsDragTarget(YES, YES, 475), 0) && Near(ApolloDuoPostsDragTarget(YES, NO, 475), 475),
              @"target: the restore commits onto its pane and springs back off the screen");
        Check(Near(ApolloDuoPostsRestoreProgress(-166.25, 475), -0.35) && Near(ApolloDuoPostsRestoreProgress(30, 475), 30.0 / 475.0)
              && Near(ApolloDuoPostsRestoreProgress(-40, 0), 0),
              @"restore progress: the drag over the thread pane's width, signed like the translation");
        Check(Near(ApolloDuoPostsCloseShadowOpacity(ApolloDuoPostsCloseProgress(ApolloDuoPostsDragOffset(YES, 0, 475), 475)), 0)
              && Near(ApolloDuoPostsCloseShadowOpacity(ApolloDuoPostsCloseProgress(ApolloDuoPostsDragOffset(YES, -475, 475), 475)), 0.3),
              @"restore shadow: Apollo's Back shadow grows in as the thread arrives");
        // The spring's cap sits where an overshoot shows: over the feed, the
        // restore's commit; off the screen, the restore's spring back, uncapped.
        Check(Near(ApolloDuoPostsSpringVelocity(50, 0, -2000), kApolloDuoPostsSpringOmega),
              @"restore spring: a fast flick onto the pane never overshoots over the feed");
        Check(Near(ApolloDuoPostsSpringVelocity(300, 475, 3000), 3000.0 / 175.0),
              @"restore spring: springing back off the screen keeps the finger's speed");
        // The snapshot taken as the thread closed serves only the same canvas.
        CGSize canvas = CGSizeMake(951, 700);
        Check(ApolloDuoClosedThreadSnapshotFits(YES, canvas, CGSizeMake(951.4, 700), 475.5, 475.9),
              @"snapshot: kept for the same canvas and divider");
        Check(!ApolloDuoClosedThreadSnapshotFits(NO, canvas, canvas, 475.5, 475.5)
              && !ApolloDuoClosedThreadSnapshotFits(YES, canvas, CGSizeMake(980, 700), 475.5, 475.5)
              && !ApolloDuoClosedThreadSnapshotFits(YES, canvas, CGSizeMake(951, 690), 475.5, 475.5),
              @"snapshot: none, or another canvas, leaves the restore discrete");
        Check(!ApolloDuoClosedThreadSnapshotFits(YES, canvas, canvas, 475.5, 420),
              @"snapshot: a divider that moved since the close (a posture change) leaves the restore discrete");
        printf("OK: %lu checks\n", (unsigned long)checks);
    }
    return 0;
}
