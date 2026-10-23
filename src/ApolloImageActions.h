#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

__BEGIN_DECLS

// Call on the main thread after menu dismissal. Exports the original image bytes.
void ApolloCopyOrShareImage(NSURL *URL, UIViewController *presenter, UIView * _Nullable sourceView, BOOL share);

__END_DECLS

NS_ASSUME_NONNULL_END
