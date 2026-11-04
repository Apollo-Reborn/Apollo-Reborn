#import <UIKit/UIKit.h>
__BEGIN_DECLS

// Gallery is a full-width destination within the selected iPad tab. Its own
// navigation leaves both list/reader stacks intact for the return to Posts.
BOOL ApolloPanePresentGallery(UIViewController *controller, UINavigationController *source);
void ApolloPaneDismissGalleryForController(UIViewController *controller);
BOOL ApolloPaneGalleryIsPresented(UIViewController *controller);
__END_DECLS
