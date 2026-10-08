// ApolloModeratorAvatars.xm
//
// Show each moderator's Apollo avatar in the "Mods" list screen
// (SubredditModeratorListViewController), reusing the avatar infrastructure
// Apollo's inline user-avatars feature already uses (ApolloUserProfileCache).
//
// The Mods screen is a plain UIKit UITableView. Its moderator rows are
// `Apollo.ApolloSubtitleTableViewCell` — a subtitle-style UITableViewCell
// subclass with NO custom ivars, so it uses the *standard* UITableViewCell
// `textLabel` (holds the bare username) and `imageView` (the leading icon slot,
// normally empty on this screen). So this is a simple post-process of the cell
// returned by `tableView:cellForRowAtIndexPath:`: read the username off
// textLabel, fetch the avatar, and paint a pre-circled image into imageView.
// UITableViewCell handles the leading-image layout (indents the text) for free.
//
// Gated behind the existing `sShowUserAvatars` toggle — conceptually this is
// "the avatars you already have, shown for moderators too", so it follows the
// same setting rather than adding a new one.
//
// Reuse safety: each cell is stamped with the username we're fetching for
// (associated object); every async hop re-checks the stamp before painting, so
// a recycled/scrolled cell never shows a stale face.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloUserProfileCache.h"
#import "ApolloClasses.h"

static const CGFloat kApolloModAvatarDiameter = 32.0;
static const void *kApolloModAvatarUsernameKey = &kApolloModAvatarUsernameKey; // NSString we're fetching for
static const void *kApolloModAvatarScaleRegisteredKey = &kApolloModAvatarScaleRegisteredKey; // NSNumber on the table view

#pragma mark - Small local helpers (mirror the statics in ApolloUserAvatars.xm)

static NSString *ApolloModNormalizedUsername(NSString *username) {
    if (![username isKindOfClass:[NSString class]]) return nil;
    NSString *clean = [username stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([clean hasPrefix:@"u/"] || [clean hasPrefix:@"U/"]) clean = [clean substringFromIndex:2];
    if (clean.length == 0) return nil;
    if ([clean isEqualToString:@"[deleted]"] || [clean isEqualToString:@"deleted"]) return nil;
    return clean;
}

static BOOL ApolloModCellStillShows(UITableViewCell *cell, NSString *username) {
    return [objc_getAssociatedObject(cell, kApolloModAvatarUsernameKey) isEqualToString:username];
}

// Oval-clipped, aspect-fill render of an avatar at `diameter` (transparent
// corners -> looks circular over any cell background, no view masking needed).
// Nil source -> neutral fill placeholder.
static UIImage *ApolloModCircularImage(UIImage *sourceImage, CGFloat diameter, UITraitCollection *traitCollection) {
    CGSize size = CGSizeMake(diameter, diameter);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = traitCollection.displayScale;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect rect = CGRectMake(0.0, 0.0, diameter, diameter);
        [[UIBezierPath bezierPathWithOvalInRect:rect] addClip];
        if (sourceImage) {
            CGFloat aspect = sourceImage.size.width > 0 ? sourceImage.size.height / sourceImage.size.width : 1.0;
            CGFloat w = diameter, h = diameter;
            if (aspect > 1.0) { w = diameter; h = diameter * aspect; }
            else if (aspect > 0.0) { w = diameter / aspect; h = diameter; }
            [sourceImage drawInRect:CGRectMake((diameter - w) / 2.0, (diameter - h) / 2.0, w, h)];
        } else {
            [[UIColor secondarySystemFillColor] setFill];
            UIRectFill(rect);
        }
    }];
}

#pragma mark - Avatar application

static void ApolloModAvatarApplyToCell(UITableViewCell *cell, UITraitCollection *traitCollection) {
    NSString *username = ApolloModNormalizedUsername(cell.textLabel.text);
    if (username.length == 0) {
        objc_setAssociatedObject(cell, kApolloModAvatarUsernameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        return;
    }

    objc_setAssociatedObject(cell, kApolloModAvatarUsernameKey, username, OBJC_ASSOCIATION_COPY_NONATOMIC);
    cell.imageView.image = ApolloModCircularImage(nil, kApolloModAvatarDiameter, traitCollection); // placeholder before async load
    [cell setNeedsLayout];

    ApolloUserProfileCache *cache = [ApolloUserProfileCache sharedCache];
    __weak UITableViewCell *weakCell = cell;
    [cache requestInfoForUsername:username completion:^(ApolloUserProfileInfo *info) {
        UITableViewCell *c1 = weakCell;
        if (!ApolloModCellStillShows(c1, username)) return;

        NSURL *imageURL = info.iconURL ?: info.snoovatarURL;
        if (!imageURL) return; // no avatar available — keep neutral placeholder

        [cache requestImageForURL:imageURL completion:^(UIImage *image) {
            if (!image) return;
            UIImage *circular = ApolloModCircularImage(image, kApolloModAvatarDiameter, traitCollection);
            dispatch_async(dispatch_get_main_queue(), ^{
                UITableViewCell *c2 = weakCell;
                if (!ApolloModCellStillShows(c2, username)) return;
                c2.imageView.image = circular;
                [c2 setNeedsLayout];
            });
        }];
    }];
}

#pragma mark - Hook

%hook _TtC6Apollo36SubredditModeratorListViewController

- (id)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = %orig;
    if (!sShowUserAvatars) return cell;
    Class subtitleCellClass = ApolloClassApolloSubtitleTableViewCell;
    if (!subtitleCellClass || ![cell isMemberOfClass:subtitleCellClass]) return cell;
    ApolloModAvatarApplyToCell(cell, tableView.traitCollection);
    // The avatar bitmaps above are rendered at the table's display scale and
    // cached on the cell's imageView. Register once per table view (associated
    // flag) so a display-scale change re-runs cellForRow -> re-renders them.
    if (@available(iOS 17.0, *)) {
        if (!objc_getAssociatedObject(tableView, kApolloModAvatarScaleRegisteredKey)) {
            objc_setAssociatedObject(tableView, kApolloModAvatarScaleRegisteredKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [tableView registerForTraitChanges:@[UITraitDisplayScale.class]
                                   withHandler:^(__kindof UITableView *v, __unused UITraitCollection *previous) {
                [v reloadData];
            }];
        }
    }
    return cell;
}

%end
