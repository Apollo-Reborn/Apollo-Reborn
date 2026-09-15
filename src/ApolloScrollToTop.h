#import <Foundation/Foundation.h>

__BEGIN_DECLS
// The Return Button setting (UDKeyScrollReturnButton / sScrollReturnButton)
// changed. Off: every live screen drops its return button and navigation-bar
// tap right away; the saved position stays, so a second status-bar tap still
// returns. On: the button reappears with the next status-bar tap.
void ApolloScrollReturnButtonSettingChanged(void);
__END_DECLS
