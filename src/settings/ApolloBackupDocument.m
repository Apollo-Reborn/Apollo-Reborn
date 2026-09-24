#import "settings/ApolloBackupDocument.h"
#import "settings/ApolloBackupRestore.h"
#import "ApolloCommon.h"
#import <stdlib.h>

void ApolloBackupPresentRestoreConfirmation(UIViewController *presenter, NSURL *url,
                                           void (^completion)(void)) {
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Confirm Restore"
        message:[NSString stringWithFormat:@"%@\n\nThis will replace all existing settings and logged-in accounts with the backup. This cannot be undone.", url.lastPathComponent]
        preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel
        handler:^(__unused UIAlertAction *action) { if (completion) completion(); }]];
    __weak UIAlertController *weakConfirm = confirm;
    [confirm addAction:[UIAlertAction actionWithTitle:@"Restore" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            NSString *errorTitle = nil, *errorMessage = nil;
            BOOL restored = ApolloBackupRestoreRestoreFromZipURL(url, &errorTitle, &errorMessage);
            ApolloLog(@"[BackupDocument] User-confirmed restore %@", restored ? @"completed" : @"failed validation or import");
            // Finish dismissing the confirmation before presenting its result.
            [weakConfirm dismissViewControllerAnimated:YES completion:^{
                UIAlertController *result = [UIAlertController alertControllerWithTitle:
                    restored ? @"Restore Complete" : (errorTitle ?: @"Restore Failed")
                    message:restored ? @"Settings successfully restored. Apollo needs to restart to apply changes."
                        : (errorMessage ?: @"Could not restore backup.")
                    preferredStyle:UIAlertControllerStyleAlert];
                [result addAction:[UIAlertAction actionWithTitle:restored ? @"Close App" : @"OK"
                    style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *resultAction) {
                        if (completion) completion();
                        if (restored) exit(0);
                    }]];
                [presenter presentViewController:result animated:YES completion:nil];
            }];
        }]];
    [presenter presentViewController:confirm animated:YES completion:nil];
}

// AppDelegate and SceneDelegate can both report the same handoff. Keep a single
// import prompt alive, and hold provider access through cold-launch UI startup
// and user confirmation. File contents/paths are never written to diagnostics.
@interface ApolloBackupDocumentAccess : NSObject
@property (nonatomic, strong) NSURL *url;
@property (nonatomic) BOOL scoped;
- (void)finish;
@end

@implementation ApolloBackupDocumentAccess
- (void)finish {
    if (self.scoped) [self.url stopAccessingSecurityScopedResource];
    self.scoped = NO;
    self.url = nil;
}
- (void)dealloc { [self finish]; }
@end

// The retry block and then the alert's callbacks own access. If another route
// dismisses the alert without choosing an action, releasing it also releases
// provider access and clears this weak reference; future opens are not blocked.
static __weak ApolloBackupDocumentAccess *sPendingBackupAccess;

static UIViewController *ApolloBackupDocumentPresenter(void) {
    for (UIWindow *window in ApolloAllWindows()) {
        if (!window.isKeyWindow || window.hidden ||
            window.windowScene.activationState != UISceneActivationStateForegroundActive) continue;
        UIViewController *controller = window.rootViewController;
        while (controller) {
            if (controller.isBeingDismissed || controller.isBeingPresented || controller.transitionCoordinator) return nil;
            if (controller.presentedViewController) controller = controller.presentedViewController;
            else if ([controller isKindOfClass:UINavigationController.class]) controller = [(UINavigationController *)controller visibleViewController];
            else if ([controller isKindOfClass:UITabBarController.class]) controller = [(UITabBarController *)controller selectedViewController];
            else break;
        }
        // Do not stack a restore prompt over another alert or a document picker.
        if ([controller isKindOfClass:UIAlertController.class] ||
            [controller isKindOfClass:UIDocumentPickerViewController.class]) return nil;
        if (controller.viewIfLoaded.window) return controller;
    }
    return nil;
}

static void ApolloBackupDocumentPresentWhenReady(ApolloBackupDocumentAccess *access, NSUInteger attempt) {
    UIViewController *presenter = ApolloBackupDocumentPresenter();
    if (presenter) {
        ApolloLog(@"[BackupDocument] Presenting Files restore confirmation");
        ApolloBackupPresentRestoreConfirmation(presenter, access.url, ^{ [access finish]; });
        return;
    }
    if (attempt >= 40) {
        ApolloLog(@"[BackupDocument] No available presenter for Files backup; use Restore Settings");
        [access finish];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApolloBackupDocumentPresentWhenReady(access, attempt + 1);
    });
}

BOOL ApolloBackupDocumentHandleURL(NSURL *url) {
    if (![url isKindOfClass:NSURL.class] || !url.isFileURL || ![url.pathExtension.lowercaseString isEqualToString:@"apollobackup"]) return NO;
    // UIKit's URL delegate entry points run on main, as does all session state.
    if (sPendingBackupAccess.url) {
        ApolloLog(@"[BackupDocument] Ignoring another handoff while restore confirmation is pending");
        return YES;
    }
    ApolloBackupDocumentAccess *access = [ApolloBackupDocumentAccess new];
    access.url = url;
    access.scoped = [url startAccessingSecurityScopedResource];
    sPendingBackupAccess = access;
    dispatch_async(dispatch_get_main_queue(), ^{ ApolloBackupDocumentPresentWhenReady(access, 0); });
    return YES;
}
