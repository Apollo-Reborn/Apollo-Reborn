// Exercises production UI callbacks with a stub engine; never imports real credentials.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "settings/ApolloBackupDocument.h"
#import "ApolloCommon.h"
static int restoreCalls;
static const char actionKey;
static NSMutableArray *results;
static UIWindow *testWindow;
static NSURL *backup;
os_log_t ApolloFixLog(void) { return os_log_create("apollo.backup.tests", "tests"); }
NSArray *ApolloAllWindows(void) { return testWindow ? @[testWindow] : @[]; }
BOOL ApolloBackupRestoreRestoreFromZipURL(NSURL *url, NSString **title, NSString **message) {
    restoreCalls++; *title=@"Invalid Backup"; *message=@"Test engine rejected this fixture."; return NO;
}
static void Check(BOOL ok, NSString *label) {
    [results addObject:@{ @"passed":@(ok), @"check":label }];
    NSLog(@"CHECK %@: %@",ok?@"PASS":@"FAIL",label);
}
static void Later(void (^block)(void)) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),block); }
static void Act(UIAlertController *alert, NSString *title) {
    for (UIAlertAction *action in alert.actions) if ([action.title isEqualToString:title]) {
        void (^handler)(UIAlertAction *)=objc_getAssociatedObject(action,&actionKey);
        handler(action); return;
    }
    Check(NO, [@"Missing action " stringByAppendingString:title]);
}
@interface UIAlertAction (Capture)
+ (instancetype)test_actionWithTitle:(NSString *)title style:(UIAlertActionStyle)style handler:(void (^)(UIAlertAction *))handler;
@end
@implementation UIAlertAction (Capture)
+ (instancetype)test_actionWithTitle:(NSString *)title style:(UIAlertActionStyle)style handler:(void (^)(UIAlertAction *))handler {
    UIAlertAction *action=[self test_actionWithTitle:title style:style handler:handler];
    objc_setAssociatedObject(action,&actionKey,handler,OBJC_ASSOCIATION_COPY_NONATOMIC);return action;
}
@end
@interface Test : UIResponder <UIApplicationDelegate,UIWindowSceneDelegate>
@end
@implementation Test
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    results=[NSMutableArray array];
    Method a=class_getClassMethod(UIAlertAction.class,@selector(actionWithTitle:style:handler:));
    Method b=class_getClassMethod(UIAlertAction.class,@selector(test_actionWithTitle:style:handler:));
    method_exchangeImplementations(a,b);
    backup=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"Sample.apollobackup"]];
    Check(!ApolloBackupDocumentHandleURL(nil),@"Nil URL remains unhandled");
    Check(!ApolloBackupDocumentHandleURL([NSURL URLWithString:@"https://example.com/a.apollobackup"]),@"Remote URL remains unhandled");
    Check(!ApolloBackupDocumentHandleURL([NSURL fileURLWithPath:@"/tmp/ordinary.zip"]),@"Ordinary ZIP remains unhandled");
    Check(ApolloBackupDocumentHandleURL(backup),@"Cold handoff accepted before a window exists");
    Check(ApolloBackupDocumentHandleURL(backup),@"Duplicate cold handoff consumed");
    return YES;
}
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    testWindow=[[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    testWindow.rootViewController=[UIViewController new];[testWindow makeKeyAndVisible];
    Later(^{
        UIViewController *root=testWindow.rootViewController;
        UIAlertController *alert=(id)root.presentedViewController;
        Check([alert.title isEqualToString:@"Confirm Restore"],@"Cold handoff waits for UI and shows confirmation");
        Check(restoreCalls==0,@"Opening and duplicate handoff never call restore");
        Act(alert,@"Cancel");
        [alert dismissViewControllerAnimated:NO completion:^{
            Check(restoreCalls==0,@"Cancel never calls restore");
            Check(ApolloBackupDocumentHandleURL(backup),@"Warm handoff accepted after cancel");
            Later(^{
                UIAlertController *warm=(id)root.presentedViewController;
                Check([warm.title isEqualToString:@"Confirm Restore"],@"Warm handoff shows new confirmation");
                Act(warm,@"Restore");
                Later(^{
                    Check(restoreCalls==1,@"Explicit Restore invokes engine exactly once");
                    UIAlertController *error=(id)root.presentedViewController;
                    Check([error.title isEqualToString:@"Invalid Backup"],@"Validation failure displays engine error");
                    Act(error,@"OK");
                    [error dismissViewControllerAnimated:NO completion:^{
                        ApolloBackupDocumentHandleURL(backup);
                        Later(^{
                            UIAlertController *again=(id)root.presentedViewController;
                            Check([again.title isEqualToString:@"Confirm Restore"],@"Failed restore releases session for another open");
                            Act(again,@"Cancel");
                            NSString *path=[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"results.json"];
                            [[NSJSONSerialization dataWithJSONObject:results options:NSJSONWritingPrettyPrinted error:nil] writeToFile:path atomically:YES];
                            NSLog(@"TESTS COMPLETE %@",path);
                        });
                    }];
                });
            });
        }];
    });
}
@end
int main(int argc,char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(Test.class)); } }
