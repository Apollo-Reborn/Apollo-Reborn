// Three-state score-tap voting for comments and posts.
// Neutral → upvote → downvote → neutral.
// Posts use native voting controls; comments use Apollo's action controller.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <stdint.h>

#import "ApolloCommon.h"
#import "ApolloNativeActionMenus.h"
#import "ApolloState.h"

// Cycle score taps through no vote → upvote → downvote → no vote.
// Select the next available native action for comment voting.
static BOOL ApolloThreeStateInvokeNextAction(id actionController) {
    uint16_t action = UINT16_MAX;

    if (ApolloNativeActionMenuHasAction(actionController, 6)) {
        // Downvoted → No vote
        action = 6;
    } else if (ApolloNativeActionMenuHasAction(actionController, 4)) {
        // Upvoted → Downvoted
        action = 5;
    } else if (ApolloNativeActionMenuHasAction(actionController, 3)) {
        // No vote → Upvoted
        action = 3;
    }

    if (action == UINT16_MAX ||
        !ApolloNativeActionMenuHasAction(actionController, action)) {
        // The tap falls back to Apollo's own score tap (upvote toggle). Log it
        // so a "no downvote step" report shows whether the menu was captured
        // at all or Apollo's vote actions changed.
        ApolloLog(@"[ThreeStateVoting] No vote action to cycle to (%@), using Apollo's own score tap",
                  actionController ? @"menu captured" : @"no menu captured");
        return NO;
    }

    ApolloNativeActionMenuInvokeAction(actionController, action);
    return YES;
}

static BOOL ApolloThreeStateCycleVote(id cell, id sender, SEL menuSelector) {
    UIView *sourceView = nil;

    if ([sender respondsToSelector:@selector(view)]) {
        sourceView = ((id (*)(id, SEL))objc_msgSend)(
            sender, @selector(view));
    }

    if (!sourceView.window ||
        ![cell respondsToSelector:menuSelector]) {
        return NO;
    }

    id actionController = ApolloNativeActionMenuCaptureController(sourceView, ^{
        ((void (*)(id, SEL, id))objc_msgSend)(
            cell, menuSelector, sender);
    });

    return ApolloThreeStateInvokeNextAction(actionController);
}

// Dispatch score taps through the post's native voting controls.
static BOOL ApolloThreeStateCycleFeedVote(id cell) {
    Ivar linkIvar = class_getInstanceVariable([cell class], "link");
    id link = linkIvar ? object_getIvar(cell, linkIvar) : nil;
    if (!link) return NO;

    NSInteger status = -1;
    @try {
        status = [[link valueForKey:@"voteStatus"] integerValue];
    } @catch (__unused NSException *exception) {
        return NO;
    }

    const char *buttonName = status == 2 ? "upvoteButton" :
                             (status == 0 || status == 1)
                                 ? "downvoteButton" : NULL;
    if (!buttonName) return NO;

    id container = cell;

    Ivar optionsIvar =
        class_getInstanceVariable([cell class], "optionButtonsNode");
    if (optionsIvar) {
        id options = object_getIvar(cell, optionsIvar);
        if (options) container = options;
    }

    Ivar buttonIvar =
        class_getInstanceVariable([container class], buttonName);

    // Compact posts keep their voting controls directly on the cell.
    if (!buttonIvar && container == cell) {
        buttonName = status == 2
            ? "upvoteButtonNode" : "downvoteButtonNode";
        buttonIvar = class_getInstanceVariable([cell class], buttonName);
    }

    id button = buttonIvar ? object_getIvar(container, buttonIvar) : nil;
    SEL action = @selector(sendActionsForControlEvents:withEvent:);

    if (!button || ![button respondsToSelector:action]) return NO;

    ((void (*)(id, SEL, NSUInteger, id))objc_msgSend)(
        button, action, (NSUInteger)(1 << 4), nil);

    return YES;
}

%hook _TtC6Apollo15CommentCellNode

- (void)pointsTappedWithSender:(id)sender {
    if (!sThreeStateVoting || !ApolloThreeStateCycleVote(
            self, sender, @selector(moreOptionsTappedWithSender:))) {
        %orig;
    }
}

%end

%hook _TtC6Apollo17LargePostCellNode

- (void)pointsButtonTappedWithSender:(id)sender {
    if (!sThreeStateVoting ||
        (!ApolloThreeStateCycleFeedVote(self) &&
         !ApolloThreeStateCycleVote(
             self, sender, @selector(moreOptionsButtonTappedWithSender:)))) {
        %orig;
    }
}

%end

%hook _TtC6Apollo19CompactPostCellNode

- (void)pointsButtonTappedWithSender:(id)sender {
    if (!sThreeStateVoting ||
        (!ApolloThreeStateCycleFeedVote(self) &&
         !ApolloThreeStateCycleVote(
             self, sender, @selector(moreOptionsButtonTappedWithSender:)))) {
        %orig;
    }
}

%end

// Route post-detail score taps through the same native controls as the
// large action-bar icons, keeping Apollo's model and UI update paths unified.
static BOOL ApolloThreeStateCycleHeaderVote(id header) {
    Ivar linkIvar = class_getInstanceVariable([header class], "link");
    id link = linkIvar ? object_getIvar(header, linkIvar) : nil;
    if (!link) return NO;

    NSInteger voteStatus = -1;
    @try {
        voteStatus = [[link valueForKey:@"voteStatus"] integerValue];
    } @catch (__unused NSException *exception) {
        return NO;
    }

    Ivar barIvar = class_getInstanceVariable([header class], "quickBarNode");
    id bar = barIvar ? object_getIvar(header, barIvar) : nil;
    if (!bar) return NO;

    // 2 = neutral, 0 = upvoted, 1 = downvoted.
    const char *buttonName = voteStatus == 2 ? "upvoteButton" :
                             voteStatus == 0 || voteStatus == 1
                                 ? "downvoteButton" : NULL;
    if (!buttonName) return NO;

    Ivar buttonIvar = class_getInstanceVariable([bar class], buttonName);
    id button = buttonIvar ? object_getIvar(bar, buttonIvar) : nil;

    SEL action = @selector(sendActionsForControlEvents:withEvent:);
    if (!button || ![button respondsToSelector:action]) return NO;

    ((void (*)(id, SEL, NSUInteger, id))objc_msgSend)(
        button, action, (NSUInteger)(1 << 4), nil);

    return YES;
}

%hook _TtC6Apollo22CommentsHeaderCellNode

- (void)pointsButtonTappedWithSender:(id)sender {
    if (!sThreeStateVoting || !ApolloThreeStateCycleHeaderVote(self)) {
        %orig;
    }
}

%end
