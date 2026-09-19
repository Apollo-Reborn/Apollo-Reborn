// ApolloFavoriteConfirm
//
// Opt-in gate on the Subreddits-list star button. When Confirm Favorite Changes
// is on, tapping the star (native control or the polish star-hit proxy) shows
// an action sheet before Apollo mutates FavoriteSubreddits. Confirm re-fires
// the control so every other favoriteSubredditButtonTapped: hook still wraps
// the real mutation; Cancel leaves the list untouched.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "ApolloFavoriteConfirm.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

static BOOL sApolloFavoriteConfirmSuppressed = NO;

BOOL ApolloFavoriteConfirmShouldPrompt(void) {
    return sConfirmFavoriteToggle && !sApolloFavoriteConfirmSuppressed;
}

void ApolloFavoriteConfirmSuppressNextTap(void) {
    sApolloFavoriteConfirmSuppressed = YES;
    // Clear on the next turn even if the re-send never arrives (control gone,
    // list dismissed, etc.) so the gate cannot stick open forever.
    dispatch_async(dispatch_get_main_queue(), ^{
        sApolloFavoriteConfirmSuppressed = NO;
    });
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

static BOOL ApolloFavoriteConfirmStringLooksLikeName(NSString *string) {
    NSString *trimmed = [string stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return NO;

    static NSSet<NSString *> *blocked;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        blocked = [NSSet setWithArray:@[
            @"Home",
            @"Popular Posts",
            @"All Posts",
            @"Moderator Posts",
            @"Posts from subscriptions",
            @"Most popular posts across Reddit",
            @"Posts across all subreddits",
            @"Posts from moderated subreddits",
        ]];
    });
    return ![blocked containsObject:trimmed];
}

static NSString *ApolloFavoriteConfirmNameFromCell(UITableViewCell *cell) {
    if (!cell) return nil;

    NSString *title = [cell.textLabel.text stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (ApolloFavoriteConfirmStringLooksLikeName(title)) return title;

    UIView *root = cell.contentView ?: cell;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count > 0) {
        UIView *candidate = stack.lastObject;
        [stack removeLastObject];
        if ([candidate isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)candidate;
            NSString *text = [label.text stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (ApolloFavoriteConfirmStringLooksLikeName(text)) return text;
        }
        for (UIView *subview in candidate.subviews) {
            [stack addObject:subview];
        }
    }
    return title.length > 0 ? title : nil;
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

#pragma mark - Sheet

void ApolloFavoriteConfirmPresentForView(UIView *sourceView, dispatch_block_t confirmed) {
    if (!sourceView || !confirmed) return;

    UIViewController *host = ApolloFavoriteConfirmHostForView(sourceView);
    if (!host) {
        ApolloLog(@"[FavoriteConfirm] no host VC for source=%@",
                  NSStringFromClass([sourceView class]));
        return;
    }

    UITableViewCell *cell = ApolloFavoriteConfirmCellForView(sourceView);
    NSString *name = ApolloFavoriteConfirmNameFromCell(cell);
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

    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:title
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:actionTitle
                                              style:actionStyle
                                            handler:^(__unused UIAlertAction *action) {
        confirmed();
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
    ApolloFavoriteConfirmPresentForView(control, ^{
        UIControl *strongControl = weakControl;
        if (!strongControl) return;
        ApolloFavoriteConfirmSuppressNextTap();
        [strongControl sendActionsForControlEvents:UIControlEventTouchUpInside];
    });
}

%end
