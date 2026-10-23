#import <UIKit/UIKit.h>

@class ApolloGalleryItem;

NS_ASSUME_NONNULL_BEGIN

// One menu session for a fixed gallery item. The owner calls menuDidEnd from
// UIKit's dismissal completion, including when it dismisses the menu itself.
@interface ApolloGalleryMediaActions : NSObject
- (instancetype)initWithItem:(ApolloGalleryItem *)item
                    presenter:(UIViewController *)presenter
                   sourceView:(nullable UIView *)sourceView NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, strong, readonly) ApolloGalleryItem *item;
// Fullscreen callers dismiss their viewer before routing the snapshotted post.
// Grid callers can leave this nil to use Apollo's normal in-app route.
@property (nonatomic, copy, nullable) dispatch_block_t openPostHandler;

- (UIMenu *)menu;
- (void)menuDidEnd;
// One selection per session, whether the handler precedes or follows dismissal.
- (void)performAfterMenu:(dispatch_block_t)action;
@end

NS_ASSUME_NONNULL_END
