#import "ApolloAppIcon.h"
#import "ApolloCommon.h"
#import <objc/message.h>

// iOS 26 Icon Composer alternates (Apollo's glass builds) are asset-catalog icon stacks
// named by CFBundleIconName, with no CFBundleIconFiles and no flat image to load. The
// system's own renderer returns the icon as currently shown, so ask it when we have no file.
static UIImage *ApolloSystemRenderedAppIcon(void) {
    SEL selector = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (![UIImage respondsToSelector:selector]) return nil;
    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
    if (bundleID.length == 0) return nil;
    // Format 2 is the 60pt home-screen icon.
    UIImage *(*send)(id, SEL, NSString *, int, CGFloat) = (UIImage *(*)(id, SEL, NSString *, int, CGFloat))objc_msgSend;
    return send([UIImage class], selector, bundleID, 2, [UIScreen mainScreen].scale);
}

static ApolloAppIconProvider sProvider;

void ApolloAppIconSetProvider(ApolloAppIconProvider provider) {
    sProvider = provider;
}

UIImage *ApolloCurrentAppIcon(void) {
    UIImage *picked = sProvider ? sProvider() : nil;
    if (picked) {
        ApolloLog(@"[appicon] using the icon picker's applied icon");
        return picked;
    }

    NSDictionary *icons = [NSBundle mainBundle].infoDictionary[@"CFBundleIcons"];
    if (![icons isKindOfClass:[NSDictionary class]]) return nil;

    NSArray<NSString *> *iconFiles = nil;
    NSString *alternateName = [UIApplication sharedApplication].alternateIconName;
    if (alternateName.length > 0) {
        NSDictionary *alternates = icons[@"CFBundleAlternateIcons"];
        NSDictionary *iconInfo = [alternates isKindOfClass:[NSDictionary class]] ? alternates[alternateName] : nil;
        iconFiles = [iconInfo[@"CFBundleIconFiles"] isKindOfClass:[NSArray class]] ? iconInfo[@"CFBundleIconFiles"] : nil;
        if (iconFiles.count == 0) {
            // A picked alternate with no files: the primary file would be the wrong icon.
            UIImage *rendered = ApolloSystemRenderedAppIcon();
            ApolloLog(@"[appicon] alternate '%@' has no icon files; system-rendered icon %@", alternateName, rendered ? @"found" : @"missing, using primary");
            if (rendered) return rendered;
        }
    }
    if (iconFiles.count == 0) {
        NSDictionary *primary = icons[@"CFBundlePrimaryIcon"];
        iconFiles = [primary[@"CFBundleIconFiles"] isKindOfClass:[NSArray class]] ? primary[@"CFBundleIconFiles"] : nil;
    }

    NSString *iconName = iconFiles.lastObject;
    return iconName.length > 0 ? [UIImage imageNamed:iconName] : nil;
}

UIImage *ApolloAppIconPreview(NSString *iconID, NSString *variant) {
    if (iconID.length == 0 || variant.length == 0) return nil;
    NSString *name = [NSString stringWithFormat:@"lg-preview-%@-%@", iconID, variant];
    UIImage *image = [UIImage imageNamed:name inBundle:NSBundle.mainBundle compatibleWithTraitCollection:nil];
    if (image) return image;
    // Standard builds lack the extended app catalog; selected previews ship with the tweak.
    NSString *path = ApolloBundledResourcePath(name, @"png");
    return path ? [UIImage imageWithContentsOfFile:path] : nil;
}
