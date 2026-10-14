#import <UIKit/UIKit.h>

@class ApolloCrashAttachment;

// In-app host for report.apolloreborn.app. The web form remains the single
// submission implementation; this controller supplies native environment data
// and the current session's privacy-friendly Apollo Reborn diagnostics.
// Bug reports need a log, so a plain report attaches that log as soon as the
// form opens; if the user removes it, "Attach Logs" puts it back.
//
// The crash-recovery flow (src/crash/) initializes it with pre-sanitized
// attachments; the local KSCrash report is deleted only after the site
// confirms a submission that still included the crash attachment.
@interface ApolloReportViewController : UIViewController

- (instancetype)initWithCrashAttachments:(NSArray<ApolloCrashAttachment *> *)attachments
                               reportIDs:(NSArray<NSNumber *> *)reportIDs;

@end
