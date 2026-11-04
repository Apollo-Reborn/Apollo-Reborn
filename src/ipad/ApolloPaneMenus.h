#import <UIKit/UIKit.h>
@class ApolloPaneSplitViewController;
__BEGIN_DECLS
NSArray<UIKeyCommand *> *ApolloPaneMenuKeyCommands(void);
BOOL ApolloPaneMenuOwnsAction(SEL action);
BOOL ApolloPaneMenuCanPerform(ApolloPaneSplitViewController *pane, SEL action);
void ApolloPaneMenuValidate(ApolloPaneSplitViewController *pane, UICommand *command);
__END_DECLS
