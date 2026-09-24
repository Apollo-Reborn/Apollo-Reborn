// ApolloFavoriteConfirm
//
// Opt-in gate on the Subreddits-list star button. When Confirm Favorite Changes
// is on, tapping the star (native control or the polish star-hit proxy) shows
// an action sheet before Apollo mutates FavoriteSubreddits. Confirm re-fires
// the control so every other favoriteSubredditButtonTapped: hook still wraps
// the real mutation; Cancel leaves the list untouched.
//
// Link-order constraint: this file MUST appear AFTER ApolloSubredditIndexPolish.xm
// and ApolloFollowingSection.xm in ApolloReborn_FILES so its
// favoriteSubredditButtonTapped: hook is the OUTERMOST one. The gate only works
// when it can intercept the tap before the polish / Following hooks run, and
// then re-enter them (with the bypass depth raised) after the user confirms.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "ApolloFavoriteConfirm.h"
#import "ApolloCommon.h"
#import "ApolloFollowingSection.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

// Depth of nested ApolloFavoriteConfirmRun perform scopes. When > 0 the hook
// skips the prompt so the confirmed re-send reaches the real mutation.
static NSInteger sApolloFavoriteConfirmBypassDepth = 0;

BOOL ApolloFavoriteConfirmShouldPrompt(void) {
    return sConfirmFavoriteToggle && sApolloFavoriteConfirmBypassDepth == 0;
}

#pragma mark - Helpers

static UITableViewCell *ApolloFavoriteConfirmCellForView(UIView *view) {
    UIView *cursor = view;
    while (cursor) {
        if ([cursor isKindOfClass:[UITableViewCell class]]) {
            return (UITableViewCell *)cursor;
        }
        cursor = cursor.superview;
    }
    return nil;
}

static UITableView *ApolloFavoriteConfirmTableForCell(UITableViewCell *cell) {
    UIView *cursor = cell.superview;
    while (cursor) {
        if ([cursor isKindOfClass:[UITableView class]]) {
            return (UITableView *)cursor;
        }
        cursor = cursor.superview;
    }
    return nil;
}

static UIViewController *ApolloFavoriteConfirmHostForView(UIView *view) {
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

static BOOL ApolloFavoriteConfirmIsFavorited(NSString *name) {
    if (name.length == 0) return NO;
    NSArray<NSString *> *favorites =
        [[NSUserDefaults standardUserDefaults] stringArrayForKey:UDKeyApolloFavoriteSubreddits];
    if (![favorites isKindOfClass:[NSArray class]]) return NO;
    for (NSString *entry in favorites) {
        if ([entry caseInsensitiveCompare:name] == NSOrderedSame) return YES;
    }
    return NO;
}

static BOOL ApolloFavoriteConfirmNamesMatch(NSString *a, NSString *b) {
    if (a.length == 0 && b.length == 0) return YES;
    if (a.length == 0 || b.length == 0) return NO;
    return [a caseInsensitiveCompare:b] == NSOrderedSame;
}

static void ApolloFavoriteConfirmPerformAfterDismiss(UIViewController *host,
                                                     NSString *promptedName,
                                                     NSString *(^nameProvider)(void),
                                                     dispatch_block_t perform) {
    NSString *freshName = nameProvider ? nameProvider() : nil;
    if (!ApolloFavoriteConfirmNamesMatch(promptedName, freshName)) {
        ApolloLog(@"[FavoriteConfirm] abort stale name prompted=%@ now=%@ presented=%@",
                  promptedName ?: @"(nil)",
                  freshName ?: @"(nil)",
                  NSStringFromClass([host.presentedViewController class]) ?: @"(none)");
        return;
    }

    ApolloLog(@"[FavoriteConfirm] perform name=%@ presented=%@",
              freshName ?: @"(unknown)",
              NSStringFromClass([host.presentedViewController class]) ?: @"(none)");

    sApolloFavoriteConfirmBypassDepth++;
    @try {
        perform();
    } @finally {
        sApolloFavoriteConfirmBypassDepth--;
    }
}

static void ApolloFavoriteConfirmWaitForDismissal(UIAlertController *sheet,
                                                  UIViewController *host,
                                                  NSString *promptedName,
                                                  NSString *(^nameProvider)(void),
                                                  dispatch_block_t perform,
                                                  CFAbsoluteTime deadline) {
    // An alert action handler may run before UIKit finishes dismissing the
    // sheet. A missing transition coordinator does not mean dismissal is done,
    // so also wait until the sheet has left the window and the host no longer
    // presents it. The short retry covers the gap before UIKit starts the
    // dismissal transition (and popovers with no coordinator).
    if (sheet.isBeingDismissed || sheet.view.window || host.presentedViewController == sheet) {
        if (CFAbsoluteTimeGetCurrent() >= deadline) {
            ApolloLog(@"[FavoriteConfirm] abort: sheet did not dismiss");
            return;
        }
        id<UIViewControllerTransitionCoordinator> coordinator = sheet.transitionCoordinator;
        if (coordinator) {
            [coordinator animateAlongsideTransition:nil
                                         completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    ApolloFavoriteConfirmWaitForDismissal(sheet, host, promptedName,
                                                          nameProvider, perform, deadline);
                });
            }];
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                ApolloFavoriteConfirmWaitForDismissal(sheet, host, promptedName,
                                                      nameProvider, perform, deadline);
            });
        }
        return;
    }

    ApolloFavoriteConfirmPerformAfterDismiss(host, promptedName, nameProvider, perform);
}

#pragma mark - Shared flow

void ApolloFavoriteConfirmRun(UIView *sourceView,
                              NSString *(^nameProvider)(void),
                              dispatch_block_t perform) {
    if (!sourceView || !perform) return;

    UIViewController *host = ApolloFavoriteConfirmHostForView(sourceView);
    if (!host) {
        ApolloLog(@"[FavoriteConfirm] no host VC for source=%@",
                  NSStringFromClass([sourceView class]));
        return;
    }

    if (host.presentedViewController) {
        ApolloLog(@"[FavoriteConfirm] skip — already presenting %@",
                  NSStringFromClass([host.presentedViewController class]));
        return;
    }

    NSString *name = nameProvider ? nameProvider() : nil;
    BOOL isFavorited = ApolloFavoriteConfirmIsFavorited(name);

    NSString *title = nil;
    NSString *actionTitle = nil;
    UIAlertActionStyle actionStyle = UIAlertActionStyleDefault;
    if (name.length > 0) {
        if (isFavorited) {
            title = [NSString stringWithFormat:@"Remove r/%@ from Favorites?", name];
            actionTitle = @"Unfavorite";
            actionStyle = UIAlertActionStyleDestructive;
        } else {
            title = [NSString stringWithFormat:@"Favorite r/%@?", name];
            actionTitle = @"Favorite";
        }
    } else {
        title = @"Change Favorite?";
        actionTitle = @"Continue";
    }

    ApolloLog(@"[FavoriteConfirm] prompt name=%@ favorited=%d",
              name ?: @"(unknown)", isFavorited ? 1 : 0);

    NSString *promptedName = [name copy];
    NSString *(^providerCopy)(void) = [nameProvider copy];
    dispatch_block_t performCopy = [perform copy];
    __weak UIViewController *weakHost = host;

    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:title
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    __weak UIAlertController *weakSheet = sheet;
    [sheet addAction:[UIAlertAction actionWithTitle:actionTitle
                                              style:actionStyle
                                            handler:^(__unused UIAlertAction *action) {
        // Wait until the sheet has fully dismissed before mutating — running
        // while UIKit is still tearing the sheet down can glitch presentation
        // / layout of the list underneath.
        UIViewController *strongHost = weakHost;
        UIAlertController *strongSheet = weakSheet;
        if (!strongHost || !strongSheet) return;
        ApolloFavoriteConfirmWaitForDismissal(strongSheet, strongHost,
                                              promptedName, providerCopy, performCopy,
                                              CFAbsoluteTimeGetCurrent() + 10.0);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = sourceView;
        sheet.popoverPresentationController.sourceRect = sourceView.bounds;
    }

    [host presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Hook

%hook _TtC6Apollo24RedditListViewController

- (void)favoriteSubredditButtonTapped:(id)sender {
    UIControl *control = [sender isKindOfClass:[UIControl class]] ? (UIControl *)sender : nil;
    if (!control || !ApolloFavoriteConfirmShouldPrompt()) {
        %orig;
        return;
    }

    __weak UIControl *weakControl = control;
    ApolloFavoriteConfirmRun(control, ^NSString * {
        UIControl *strongControl = weakControl;
        if (!strongControl) return nil;
        UITableViewCell *cell = ApolloFavoriteConfirmCellForView(strongControl);
        UITableView *tableView = ApolloFavoriteConfirmTableForCell(cell);
        if (!cell || !tableView) return nil;
        NSIndexPath *path = [tableView indexPathForCell:cell];
        return ApolloSubredditListNameAtIndexPath(tableView, path);
    }, ^{
        UIControl *strongControl = weakControl;
        if (!strongControl) return;
        [strongControl sendActionsForControlEvents:UIControlEventTouchUpInside];
    });
}

%end
