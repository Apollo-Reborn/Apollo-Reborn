#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloUserProfileCache.h"

static NSString *const ApolloUserAvatarsToggleChangedNotification = @"ApolloUserAvatarsToggleChangedNotification";
static CGFloat const ApolloInlineAvatarDiameter = 28.0;
static CGFloat const ApolloCommentInlineAvatarDiameter = 28.0;
static CGFloat const ApolloFeedInlineAvatarDiameter = 24.0;
static CGFloat const ApolloProfileHeaderHeight = 206.0;
static CGFloat const ApolloProfileAvatarDiameter = 96.0;
static CGFloat const ApolloProfileSnoovatarWidth = 156.0;
static CGFloat const ApolloProfileSnoovatarHeight = 178.0;
static NSUInteger const ApolloInlineAvatarMaxActiveInfoRequests = 6;
static NSUInteger const ApolloInlineAvatarMaxBindAttempts = 4;
static NSUInteger const ApolloInlineAvatarLogLimit = 16;

static const void *kApolloAvatarTextNodeKey = &kApolloAvatarTextNodeKey;
static const void *kApolloAvatarOriginalAttributedTextKey = &kApolloAvatarOriginalAttributedTextKey;
static const void *kApolloAvatarUsernameKey = &kApolloAvatarUsernameKey;
static const void *kApolloAvatarAppliedTokenKey = &kApolloAvatarAppliedTokenKey;
static const void *kApolloAvatarOwnedTextNodeKey = &kApolloAvatarOwnedTextNodeKey;
static const void *kApolloAvatarInfoKey = &kApolloAvatarInfoKey;
static const void *kApolloAvatarImageKey = &kApolloAvatarImageKey;
static const void *kApolloAvatarDecoratorImageKey = &kApolloAvatarDecoratorImageKey;
static const void *kApolloAvatarDiameterKey = &kApolloAvatarDiameterKey;
static const void *kApolloAvatarApplyingTextKey = &kApolloAvatarApplyingTextKey;
static NSString *const kApolloAvatarAttachmentMarkerAttributeName = @"ApolloAvatarAttachment";
static const void *kApolloAvatarPendingFetchUsernameKey = &kApolloAvatarPendingFetchUsernameKey;
static const void *kApolloAvatarPendingLateReapplyUsernameKey = &kApolloAvatarPendingLateReapplyUsernameKey;
static const void *kApolloProfileHeaderViewKey = &kApolloProfileHeaderViewKey;
static const void *kApolloProfileWrappedHeaderKey = &kApolloProfileWrappedHeaderKey;
static const void *kApolloProfileOriginalHeaderKey = &kApolloProfileOriginalHeaderKey;
static const void *kApolloProfileUsernameKey = &kApolloProfileUsernameKey;
static const void *kApolloProfileWrapperMarkerKey = &kApolloProfileWrapperMarkerKey;

@interface ApolloProfileHeaderView : UIView
@property(nonatomic, strong) UIImageView *bannerImageView;
@property(nonatomic, strong) UIImageView *avatarImageView;
@property(nonatomic, strong) UIView *avatarBorderView;
@property(nonatomic, strong) UIImageView *snoovatarImageView;
@end

@implementation ApolloProfileHeaderView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor systemBackgroundColor];

        _bannerImageView = [[UIImageView alloc] init];
        _bannerImageView.backgroundColor = [UIColor tertiarySystemFillColor];
        _bannerImageView.contentMode = UIViewContentModeScaleAspectFill;
        _bannerImageView.clipsToBounds = YES;
        [self addSubview:_bannerImageView];

        _avatarBorderView = [[UIView alloc] init];
        _avatarBorderView.backgroundColor = [UIColor systemBackgroundColor];
        _avatarBorderView.layer.cornerRadius = (ApolloProfileAvatarDiameter + 6.0) / 2.0;
        _avatarBorderView.clipsToBounds = YES;
        [self addSubview:_avatarBorderView];

        _avatarImageView = [[UIImageView alloc] init];
        _avatarImageView.backgroundColor = [UIColor secondarySystemFillColor];
        _avatarImageView.contentMode = UIViewContentModeScaleAspectFill;
        _avatarImageView.clipsToBounds = YES;
        _avatarImageView.layer.cornerRadius = ApolloProfileAvatarDiameter / 2.0;
        [_avatarBorderView addSubview:_avatarImageView];

        _snoovatarImageView = [[UIImageView alloc] init];
        _snoovatarImageView.contentMode = UIViewContentModeScaleAspectFit;
        _snoovatarImageView.clipsToBounds = NO;
        _snoovatarImageView.hidden = YES;
        [self addSubview:_snoovatarImageView];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    CGFloat bannerHeight = 126.0;
    self.bannerImageView.frame = CGRectMake(0.0, 0.0, width, bannerHeight);

    CGFloat borderSize = ApolloProfileAvatarDiameter + 6.0;
    self.avatarBorderView.frame = CGRectMake(22.0, bannerHeight - 34.0, borderSize, borderSize);
    self.avatarBorderView.layer.cornerRadius = borderSize / 2.0;
    self.avatarImageView.frame = CGRectMake(3.0, 3.0, ApolloProfileAvatarDiameter, ApolloProfileAvatarDiameter);
    self.avatarImageView.layer.cornerRadius = ApolloProfileAvatarDiameter / 2.0;

    CGFloat snoovatarY = MAX(12.0, bannerHeight - 92.0);
    self.snoovatarImageView.frame = CGRectMake(20.0, snoovatarY, ApolloProfileSnoovatarWidth, ApolloProfileSnoovatarHeight);
}

@end

static NSString *ApolloAvatarNormalizedUsername(NSString *username) {
    if (![username isKindOfClass:[NSString class]]) return nil;
    NSString *clean = [username stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([clean hasPrefix:@"u/"] || [clean hasPrefix:@"U/"]) clean = [clean substringFromIndex:2];
    if (clean.length == 0) return nil;
    if ([clean isEqualToString:@"[deleted]"] || [clean isEqualToString:@"deleted"]) return nil;
    return clean;
}

static BOOL ApolloAvatarUsernameMatches(NSString *left, NSString *right) {
    NSString *normalizedLeft = ApolloAvatarNormalizedUsername(left);
    NSString *normalizedRight = ApolloAvatarNormalizedUsername(right);
    if (normalizedLeft.length == 0 || normalizedRight.length == 0) return NO;
    return [normalizedLeft caseInsensitiveCompare:normalizedRight] == NSOrderedSame;
}

static id ApolloObjectIvarValue(id object, NSString *name) {
    if (!object || name.length == 0) return nil;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;
        @try {
            return object_getIvar(object, ivar);
        } @catch (__unused NSException *exception) {
            return nil;
        }
    }
    return nil;
}

static NSString *ApolloUsernameFromModelObject(id object) {
    if (!object) return nil;
    SEL authorSEL = @selector(author);
    if ([object respondsToSelector:authorSEL]) {
        id (*msgSend)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id value = msgSend(object, authorSEL);
        if ([value isKindOfClass:[NSString class]]) return ApolloAvatarNormalizedUsername(value);
    }
    SEL usernameSEL = @selector(username);
    if ([object respondsToSelector:usernameSEL]) {
        id (*msgSend)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id value = msgSend(object, usernameSEL);
        if ([value isKindOfClass:[NSString class]]) return ApolloAvatarNormalizedUsername(value);
    }
    SEL nameSEL = @selector(name);
    if ([object respondsToSelector:nameSEL]) {
        id (*msgSend)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id value = msgSend(object, nameSEL);
        if ([value isKindOfClass:[NSString class]]) return ApolloAvatarNormalizedUsername(value);
    }
    return nil;
}

static NSString *ApolloUsernameFromCell(id cell, NSString *ivarName) {
    id model = ApolloObjectIvarValue(cell, ivarName);
    NSString *username = ApolloUsernameFromModelObject(model);
    if (username.length > 0) return username;

    SEL modelSEL = NSSelectorFromString(ivarName);
    if ([cell respondsToSelector:modelSEL]) {
        id (*msgSend)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        username = ApolloUsernameFromModelObject(msgSend(cell, modelSEL));
    }
    return username;
}

static NSArray *ApolloSubnodesForNode(id node) {
    if (![node respondsToSelector:@selector(subnodes)]) return nil;
    NSArray *(*msgSend)(id, SEL) = (NSArray *(*)(id, SEL))objc_msgSend;
    id subnodes = msgSend(node, @selector(subnodes));
    return [subnodes isKindOfClass:[NSArray class]] ? subnodes : nil;
}

static NSAttributedString *ApolloAttributedTextForNode(id node) {
    if (![node respondsToSelector:@selector(attributedText)]) return nil;
    NSAttributedString *(*msgSend)(id, SEL) = (NSAttributedString *(*)(id, SEL))objc_msgSend;
    id attributedText = msgSend(node, @selector(attributedText));
    return [attributedText isKindOfClass:[NSAttributedString class]] ? attributedText : nil;
}

static void ApolloSetAttributedTextForNode(id node, NSAttributedString *attributedText) {
    if (!node || !attributedText || ![node respondsToSelector:@selector(setAttributedText:)]) return;
    void (*msgSend)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
    msgSend(node, @selector(setAttributedText:), attributedText);
}

static void ApolloNodeSetNeedsLayout(id node) {
    if ([node respondsToSelector:@selector(setNeedsLayout)]) {
        void (*msgSend)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
        msgSend(node, @selector(setNeedsLayout));
    }
    SEL invalidateLayoutSEL = NSSelectorFromString(@"invalidateCalculatedLayout");
    if ([node respondsToSelector:invalidateLayoutSEL]) {
        void (*msgSend)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
        msgSend(node, invalidateLayoutSEL);
    }
}

static void ApolloCollectTextNodes(id node, NSMutableSet<NSValue *> *visited, NSMutableArray *outNodes, NSUInteger depth) {
    if (!node || depth > 8) return;
    NSValue *key = [NSValue valueWithNonretainedObject:node];
    if ([visited containsObject:key]) return;
    [visited addObject:key];

    if (ApolloAttributedTextForNode(node).length > 0) {
        [outNodes addObject:node];
    }

    for (id subnode in ApolloSubnodesForNode(node)) {
        ApolloCollectTextNodes(subnode, visited, outNodes, depth + 1);
    }
}

static BOOL ApolloNodeTreeContainsObject(id root, id target, NSMutableSet<NSValue *> *visited, NSUInteger depth) {
    if (!root || !target || depth > 8) return NO;
    if (root == target) return YES;
    NSValue *key = [NSValue valueWithNonretainedObject:root];
    if ([visited containsObject:key]) return NO;
    [visited addObject:key];

    for (id subnode in ApolloSubnodesForNode(root)) {
        if (ApolloNodeTreeContainsObject(subnode, target, visited, depth + 1)) return YES;
    }
    return NO;
}

static NSInteger ApolloAuthorTextScore(NSString *text, NSString *username) {
    if (text.length == 0 || username.length == 0) return NSIntegerMax;
    if ([text rangeOfString:@"\n"].location != NSNotFound) return NSIntegerMax;
    if (text.length > MAX((NSUInteger)120, username.length + 80)) return NSIntegerMax;

    NSString *lowerText = text.lowercaseString;
    NSString *lowerUsername = username.lowercaseString;
    NSString *prefixed = [@"u/" stringByAppendingString:lowerUsername];

    NSRange direct = [lowerText rangeOfString:lowerUsername];
    NSRange withPrefix = [lowerText rangeOfString:prefixed];
    if (direct.location == NSNotFound && withPrefix.location == NSNotFound) return NSIntegerMax;

    NSUInteger location = MIN(direct.location == NSNotFound ? NSUIntegerMax : direct.location,
                              withPrefix.location == NSNotFound ? NSUIntegerMax : withPrefix.location);
    if (location > 55) return NSIntegerMax;

    NSInteger prefixBonus = 20;
    if ([lowerText hasPrefix:lowerUsername] || [lowerText hasPrefix:prefixed]) prefixBonus = 0;
    else if (withPrefix.location != NSNotFound) prefixBonus = 8;

    return prefixBonus + (NSInteger)location + (NSInteger)(text.length / 4);
}

static id ApolloBestAuthorTextNode(id cell, NSString *username) {
    NSMutableArray *nodes = [NSMutableArray array];
    ApolloCollectTextNodes(cell, [NSMutableSet set], nodes, 0);

    id bestNode = nil;
    NSInteger bestScore = NSIntegerMax;
    for (id node in nodes) {
        NSString *text = ApolloAttributedTextForNode(node).string;
        NSInteger score = ApolloAuthorTextScore(text, username);
        if (score < bestScore) {
            bestScore = score;
            bestNode = node;
        }
    }
    return bestNode;
}

static UIBezierPath *ApolloHexagonPath(CGRect rect) {
    CGFloat minX = CGRectGetMinX(rect);
    CGFloat maxX = CGRectGetMaxX(rect);
    CGFloat minY = CGRectGetMinY(rect);
    CGFloat maxY = CGRectGetMaxY(rect);
    CGFloat midY = CGRectGetMidY(rect);
    CGFloat insetX = rect.size.width * 0.22;

    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(minX + insetX, minY)];
    [path addLineToPoint:CGPointMake(maxX - insetX, minY)];
    [path addLineToPoint:CGPointMake(maxX, midY)];
    [path addLineToPoint:CGPointMake(maxX - insetX, maxY)];
    [path addLineToPoint:CGPointMake(minX + insetX, maxY)];
    [path addLineToPoint:CGPointMake(minX, midY)];
    [path closePath];
    return path;
}

static void ApolloDrawAvatarSourceImage(UIImage *sourceImage, CGRect rect) {
    if (sourceImage) {
        CGFloat imageAspect = sourceImage.size.width > 0 ? sourceImage.size.height / sourceImage.size.width : 1.0;
        CGFloat drawWidth = rect.size.width;
        CGFloat drawHeight = rect.size.height;
        if (imageAspect > 1.0) {
            drawWidth = rect.size.width;
            drawHeight = rect.size.width * imageAspect;
        } else if (imageAspect > 0.0) {
            drawWidth = rect.size.height / imageAspect;
            drawHeight = rect.size.height;
        }
        CGRect drawRect = CGRectMake(CGRectGetMidX(rect) - drawWidth / 2.0, CGRectGetMidY(rect) - drawHeight / 2.0, drawWidth, drawHeight);
        [sourceImage drawInRect:drawRect];
    } else {
        [[UIColor secondarySystemFillColor] setFill];
        UIRectFill(rect);
    }
}

static BOOL ApolloAvatarHasFrame(ApolloUserProfileInfo *info) {
    return info.decoratorURL != nil;
}

static UIImage *ApolloClippedAvatarImage(UIImage *sourceImage, CGFloat diameter, BOOL hexagon) {
    CGSize size = CGSizeMake(diameter, diameter);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = [UIScreen mainScreen].scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect rect = CGRectMake(0.0, 0.0, diameter, diameter);
        UIBezierPath *clip = hexagon ? ApolloHexagonPath(rect) : [UIBezierPath bezierPathWithOvalInRect:rect];
        [clip addClip];

        if (sourceImage) {
            CGFloat imageAspect = sourceImage.size.width > 0 ? sourceImage.size.height / sourceImage.size.width : 1.0;
            CGFloat drawWidth = diameter;
            CGFloat drawHeight = diameter;
            if (imageAspect > 1.0) {
                drawWidth = diameter;
                drawHeight = diameter * imageAspect;
            } else if (imageAspect > 0.0) {
                drawWidth = diameter / imageAspect;
                drawHeight = diameter;
            }
            CGRect drawRect = CGRectMake((diameter - drawWidth) / 2.0, (diameter - drawHeight) / 2.0, drawWidth, drawHeight);
            [sourceImage drawInRect:drawRect];
        } else {
            [[UIColor secondarySystemFillColor] setFill];
            UIRectFill(rect);
        }
    }];
}

static UIImage *ApolloCircularAvatarImage(UIImage *sourceImage, CGFloat diameter) {
    return ApolloClippedAvatarImage(sourceImage, diameter, NO);
}

static UIImage *ApolloAvatarImageForInfo(ApolloUserProfileInfo *info, UIImage *sourceImage, UIImage *decoratorImage, CGFloat diameter) {
    BOOL hasFrame = ApolloAvatarHasFrame(info);
    BOOL polygon = info.hasSnoovatar || hasFrame;
    if (!hasFrame && !decoratorImage) {
        return ApolloClippedAvatarImage(sourceImage, diameter, polygon);
    }

    CGSize size = CGSizeMake(diameter, diameter);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = [UIScreen mainScreen].scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect rect = CGRectMake(0.0, 0.0, diameter, diameter);
        UIBezierPath *clip = polygon ? ApolloHexagonPath(rect) : [UIBezierPath bezierPathWithOvalInRect:rect];
        CGContextSaveGState(context.CGContext);
        [clip addClip];
        ApolloDrawAvatarSourceImage(sourceImage, rect);
        CGContextRestoreGState(context.CGContext);

        if (decoratorImage) {
            [decoratorImage drawInRect:rect blendMode:kCGBlendModeNormal alpha:1.0];
        }
    }];
}

static NSRange ApolloUsernameRangeInString(NSString *string, NSString *username) {
    NSRange notFound = NSMakeRange(NSNotFound, 0);
    NSString *normalized = ApolloAvatarNormalizedUsername(username);
    if (string.length == 0 || normalized.length == 0) return notFound;

    NSString *prefixed = [@"u/" stringByAppendingString:normalized];
    NSRange withPrefix = [string rangeOfString:prefixed options:NSCaseInsensitiveSearch];
    if (withPrefix.location != NSNotFound) {
        return NSMakeRange(withPrefix.location + 2, withPrefix.length - 2);
    }
    NSRange direct = [string rangeOfString:normalized options:NSCaseInsensitiveSearch];
    return direct;
}

static NSAttributedString *ApolloAttributedTextByPrependingAvatar(NSAttributedString *baseText, NSString *username, UIImage *avatarImage, UIImage *decoratorImage, ApolloUserProfileInfo *info, CGFloat diameter) {
    if (!baseText.length) return baseText;

    CGFloat preferredDiameter = diameter > 0.0 ? diameter : ApolloInlineAvatarDiameter;

    NSRange usernameRange = ApolloUsernameRangeInString(baseText.string, username);
    NSUInteger insertionPoint = (usernameRange.location != NSNotFound) ? usernameRange.location : 0;

    NSUInteger attrIndex = MIN(insertionPoint, baseText.length - 1);
    UIFont *font = [baseText attribute:NSFontAttributeName atIndex:attrIndex effectiveRange:nil];
    if (![font isKindOfClass:[UIFont class]]) font = [UIFont systemFontOfSize:13.0];

    // Scale the avatar with the surrounding font so it doesn't tower over small bylines.
    // Inline comment cells (preferred 28) get a slightly larger profile than feed/header
    // bylines, which are denser and look better with a smaller avatar near the cap height.
    CGFloat capHeight = font.capHeight > 0.0 ? font.capHeight : (font.pointSize * 0.7);
    CGFloat lineHeight = font.lineHeight > 0.0 ? font.lineHeight : (font.pointSize * 1.2);
    BOOL useLargerScaling = preferredDiameter >= 26.0;
    CGFloat capMultiplier = useLargerScaling ? 2.75 : 2.25;
    CGFloat lineHeightMultiplier = useLargerScaling ? 1.7 : 1.4;
    CGFloat minDiameter = useLargerScaling ? 24.0 : 20.0;
    CGFloat fontScaledDiameter = floor(capHeight * capMultiplier);
    CGFloat lineHeightCap = floor(lineHeight * lineHeightMultiplier);
    CGFloat avatarDiameter = MIN(preferredDiameter, MIN(lineHeightCap, MAX(minDiameter, fontScaledDiameter)));

    NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
    attachment.image = ApolloAvatarImageForInfo(info, avatarImage, decoratorImage, avatarDiameter);
    // Center the avatar on the cap-height midline of the surrounding text.
    CGFloat yOffset = (capHeight - avatarDiameter) / 2.0;
    attachment.bounds = CGRectMake(0.0, yOffset, avatarDiameter, avatarDiameter);

    NSDictionary *baseAttributes = [baseText attributesAtIndex:attrIndex effectiveRange:nil] ?: @{};

    NSMutableAttributedString *attachmentString = [[NSMutableAttributedString alloc] initWithAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
    [attachmentString addAttribute:kApolloAvatarAttachmentMarkerAttributeName value:@YES range:NSMakeRange(0, attachmentString.length)];
    NSAttributedString *spacer = [[NSAttributedString alloc] initWithString:@" " attributes:baseAttributes];

    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] initWithAttributedString:baseText];
    [result insertAttributedString:spacer atIndex:insertionPoint];
    [result insertAttributedString:attachmentString atIndex:insertionPoint];
    return result;
}

static BOOL ApolloTextLooksAvatarPrepended(NSAttributedString *text) {
    if (text.length == 0) return NO;
    __block BOOL found = NO;
    [text enumerateAttribute:kApolloAvatarAttachmentMarkerAttributeName
                     inRange:NSMakeRange(0, text.length)
                     options:0
                  usingBlock:^(id value, __unused NSRange range, BOOL *stop) {
        if (value) { found = YES; *stop = YES; }
    }];
    return found;
}

static BOOL ApolloAttributedTextContainsUsername(NSAttributedString *text, NSString *username) {
    username = ApolloAvatarNormalizedUsername(username);
    if (text.string.length == 0 || username.length == 0) return NO;
    return [text.string rangeOfString:username options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static CGFloat ApolloInlineAvatarDiameterForObject(id object) {
    NSNumber *number = objc_getAssociatedObject(object, kApolloAvatarDiameterKey);
    CGFloat diameter = [number respondsToSelector:@selector(doubleValue)] ? number.doubleValue : 0.0;
    return diameter > 0.0 ? diameter : ApolloInlineAvatarDiameter;
}

static void ApolloSetInlineAvatarDiameterForObject(id object, CGFloat diameter) {
    if (!object) return;
    CGFloat avatarDiameter = diameter > 0.0 ? diameter : ApolloInlineAvatarDiameter;
    objc_setAssociatedObject(object, kApolloAvatarDiameterKey, @(avatarDiameter), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloClearAvatarTextNodeAssociations(id textNode) {
    if (!textNode) return;
    objc_setAssociatedObject(textNode, kApolloAvatarOriginalAttributedTextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarUsernameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarAppliedTokenKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarOwnedTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarInfoKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarDecoratorImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarDiameterKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarApplyingTextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloRestoreAvatarTextNode(id textNode) {
    NSAttributedString *original = objc_getAssociatedObject(textNode, kApolloAvatarOriginalAttributedTextKey);
    ApolloClearAvatarTextNodeAssociations(textNode);
    if (original) {
        ApolloSetAttributedTextForNode(textNode, original);
        ApolloNodeSetNeedsLayout(textNode);
    }
}

static void ApolloRestoreAvatarForCell(id cell) {
    id textNode = objc_getAssociatedObject(cell, kApolloAvatarTextNodeKey);
    if (textNode) ApolloRestoreAvatarTextNode(textNode);
    objc_setAssociatedObject(cell, kApolloAvatarTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, kApolloAvatarUsernameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(cell, kApolloAvatarDiameterKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSString *ApolloAvatarTokenForInfo(ApolloUserProfileInfo *info, BOOL hasAvatarImage, BOOL hasDecoratorImage, CGFloat diameter) {
    NSString *urlToken = info.iconURL.absoluteString ?: @"placeholder";
    NSString *shapeToken = (info.hasSnoovatar || ApolloAvatarHasFrame(info)) ? @"polygon" : @"circle";
    NSString *imageToken = hasAvatarImage ? @"loaded" : @"placeholder";
    NSString *frameToken = info.avatarFrameKind ?: @"none";
    NSString *decoratorURLToken = info.decoratorURL.absoluteString ?: @"none";
    NSString *decoratorStateToken = info.decoratorURL ? (hasDecoratorImage ? @"decorator-loaded" : @"decorator-pending") : @"decorator-none";
    return [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%@|d%.1f", urlToken, shapeToken, imageToken, frameToken, decoratorURLToken, decoratorStateToken, diameter];
}

static BOOL ApolloSetAvatarImageOnTextNode(id textNode, NSString *username, UIImage *avatarImage, UIImage *decoratorImage, ApolloUserProfileInfo *info, NSString *token) {
    if (!textNode || username.length == 0) return NO;

    NSAttributedString *current = ApolloAttributedTextForNode(textNode);
    if (!current.length) return NO;

    NSString *storedUsername = objc_getAssociatedObject(textNode, kApolloAvatarUsernameKey);
    NSString *appliedToken = objc_getAssociatedObject(textNode, kApolloAvatarAppliedTokenKey);
    NSAttributedString *baseText = objc_getAssociatedObject(textNode, kApolloAvatarOriginalAttributedTextKey);

    if (![storedUsername isEqualToString:username]) {
        baseText = current;
        if (ApolloTextLooksAvatarPrepended(baseText)) {
            baseText = nil;
        }
    }
    if (!baseText) baseText = current;
    if (!ApolloAttributedTextContainsUsername(baseText, username)) return NO;
    if ([appliedToken isEqualToString:token] && ApolloTextLooksAvatarPrepended(current)) return NO;

    CGFloat diameter = ApolloInlineAvatarDiameterForObject(textNode);

    objc_setAssociatedObject(textNode, kApolloAvatarOriginalAttributedTextKey, baseText, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarUsernameKey, username, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarAppliedTokenKey, token, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarOwnedTextNodeKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarInfoKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarImageKey, avatarImage, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarDecoratorImageKey, decoratorImage, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloSetInlineAvatarDiameterForObject(textNode, diameter);

    NSAttributedString *updated = ApolloAttributedTextByPrependingAvatar(baseText, username, avatarImage, decoratorImage, info, diameter);
    objc_setAssociatedObject(textNode, kApolloAvatarApplyingTextKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
        ApolloSetAttributedTextForNode(textNode, updated);
    } @finally {
        objc_setAssociatedObject(textNode, kApolloAvatarApplyingTextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ApolloNodeSetNeedsLayout(textNode);
    return YES;
}

static BOOL ApolloTextNodeContainsUsername(id textNode, NSString *username) {
    if (!textNode || username.length == 0) return NO;
    NSAttributedString *text = ApolloAttributedTextForNode(textNode);
    if (text.string.length == 0) return NO;
    return [text.string.lowercaseString containsString:username.lowercaseString];
}

static id ApolloCurrentAuthorTextNodeForCell(id cell, NSString *username) {
    id textNode = objc_getAssociatedObject(cell, kApolloAvatarTextNodeKey);
    if (ApolloTextNodeContainsUsername(textNode, username)) return textNode;
    return ApolloBestAuthorTextNode(cell, username);
}

static BOOL ApolloApplyAvatarRenderToCell(id cell, NSString *username, ApolloUserProfileInfo *info, UIImage *avatarImage, UIImage *decoratorImage) {
    id currentTextNode = ApolloCurrentAuthorTextNodeForCell(cell, username);
    if (!ApolloTextNodeContainsUsername(currentTextNode, username)) return NO;
    CGFloat diameter = ApolloInlineAvatarDiameterForObject(cell);
    ApolloSetInlineAvatarDiameterForObject(currentTextNode, diameter);
    NSString *token = ApolloAvatarTokenForInfo(info, avatarImage != nil, decoratorImage != nil, diameter);
    return ApolloSetAvatarImageOnTextNode(currentTextNode, username, avatarImage, decoratorImage, info, token);
}

static void ApolloRequestDecoratorRefreshIfNeeded(ApolloUserProfileCache *cache, ApolloUserProfileInfo *info) {
    if (!info.decoratorURL) return;
    if ([cache cachedImageForURL:info.decoratorURL]) return;
    [cache requestImageForURL:info.decoratorURL completion:nil];
}

static NSMutableArray<void (^)(void)> *ApolloInlineAvatarInfoRequestQueue(void) {
    static NSMutableArray<void (^)(void)> *queue = nil;
    if (!queue) queue = [NSMutableArray array];
    return queue;
}

static NSUInteger sApolloInlineAvatarActiveInfoRequests = 0;
static NSUInteger sApolloInlineAvatarNoTextLogCount = 0;
static NSUInteger sApolloInlineAvatarQueuedLogCount = 0;
static NSUInteger sApolloInlineAvatarAppliedLogCount = 0;
static NSUInteger sApolloInlineAvatarGaveUpLogCount = 0;
static NSUInteger sApolloInlineAvatarLateReapplyLogCount = 0;
static NSUInteger sApolloInlineAvatarRewriteLogCount = 0;

static BOOL ApolloInlineAvatarShouldLog(NSUInteger *counter) {
    if (!counter || *counter >= ApolloInlineAvatarLogLimit) return NO;
    (*counter)++;
    return YES;
}

static BOOL ApolloPrepareAvatarRewriteForTextNode(id textNode, NSAttributedString *incomingAttributedText, NSAttributedString **swapOut) {
    if (swapOut) *swapOut = nil;
    if (!textNode || !sShowUserAvatars) return NO;
    if ([objc_getAssociatedObject(textNode, kApolloAvatarApplyingTextKey) boolValue]) return NO;
    if (![objc_getAssociatedObject(textNode, kApolloAvatarOwnedTextNodeKey) boolValue]) return NO;
    if (![incomingAttributedText isKindOfClass:[NSAttributedString class]] || incomingAttributedText.length == 0) return NO;
    if (ApolloTextLooksAvatarPrepended(incomingAttributedText)) return NO;

    NSString *username = ApolloAvatarNormalizedUsername(objc_getAssociatedObject(textNode, kApolloAvatarUsernameKey));
    if (username.length == 0) {
        ApolloClearAvatarTextNodeAssociations(textNode);
        return NO;
    }

    if (!ApolloAttributedTextContainsUsername(incomingAttributedText, username)) {
        NSString *trimmed = [incomingAttributedText.string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length > 0) ApolloClearAvatarTextNodeAssociations(textNode);
        return NO;
    }

    ApolloUserProfileInfo *info = objc_getAssociatedObject(textNode, kApolloAvatarInfoKey);
    UIImage *avatarImage = objc_getAssociatedObject(textNode, kApolloAvatarImageKey);
    UIImage *decoratorImage = objc_getAssociatedObject(textNode, kApolloAvatarDecoratorImageKey);
    if (!info || !avatarImage) {
        ApolloUserProfileCache *cache = [ApolloUserProfileCache sharedCache];
        if (!info) info = [cache cachedInfoForUsername:username];
        if (!avatarImage && info.iconURL) avatarImage = [cache cachedImageForURL:info.iconURL];
        if (!decoratorImage && info.decoratorURL) decoratorImage = [cache cachedImageForURL:info.decoratorURL];
    }
    if (!info || !avatarImage) return NO;

    CGFloat diameter = ApolloInlineAvatarDiameterForObject(textNode);
    NSString *token = ApolloAvatarTokenForInfo(info, avatarImage != nil, decoratorImage != nil, diameter);
    NSAttributedString *updated = ApolloAttributedTextByPrependingAvatar(incomingAttributedText, username, avatarImage, decoratorImage, info, diameter);
    if (!updated || updated == incomingAttributedText) return NO;

    objc_setAssociatedObject(textNode, kApolloAvatarOriginalAttributedTextKey, incomingAttributedText, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarUsernameKey, username, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarAppliedTokenKey, token, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarOwnedTextNodeKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarInfoKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarImageKey, avatarImage, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarDecoratorImageKey, decoratorImage, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloSetInlineAvatarDiameterForObject(textNode, diameter);

    if (swapOut) *swapOut = updated;
    if (ApolloInlineAvatarShouldLog(&sApolloInlineAvatarRewriteLogCount)) {
        ApolloLog(@"[UserAvatars] Inline avatar preserved after text rewrite u/%@ node=%p", username, textNode);
    }
    return YES;
}

static NSTimeInterval ApolloInlineAvatarBindDelayForAttempt(NSUInteger attempt) {
    switch (attempt) {
        case 0: return 0.05;
        case 1: return 0.45;
        case 2: return 1.0;
        default: return 2.0;
    }
}

static void ApolloDrainInlineAvatarInfoRequestQueue(void) {
    NSMutableArray<void (^)(void)> *queue = ApolloInlineAvatarInfoRequestQueue();
    while (sApolloInlineAvatarActiveInfoRequests < ApolloInlineAvatarMaxActiveInfoRequests && queue.count > 0) {
        void (^requestBlock)(void) = [queue.firstObject copy];
        [queue removeObjectAtIndex:0];
        sApolloInlineAvatarActiveInfoRequests++;
        requestBlock();
    }
}

static void ApolloEnqueueInlineAvatarInfoRequest(void (^requestBlock)(void)) {
    if (!requestBlock) return;
    [ApolloInlineAvatarInfoRequestQueue() addObject:[requestBlock copy]];
    ApolloDrainInlineAvatarInfoRequestQueue();
}

static void ApolloInlineAvatarInfoRequestDidFinish(void) {
    if (sApolloInlineAvatarActiveInfoRequests > 0) sApolloInlineAvatarActiveInfoRequests--;
    ApolloDrainInlineAvatarInfoRequestQueue();
}

static void ApolloClearPendingInlineAvatarFetch(id cell, NSString *username) {
    NSString *pendingUsername = objc_getAssociatedObject(cell, kApolloAvatarPendingFetchUsernameKey);
    if (!pendingUsername || ApolloAvatarUsernameMatches(pendingUsername, username)) {
        objc_setAssociatedObject(cell, kApolloAvatarPendingFetchUsernameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
}

static BOOL ApolloInlineAvatarCellUsernameMatches(id cell, NSString *username) {
    if (!cell || username.length == 0) return NO;
    NSString *storedUsername = objc_getAssociatedObject(cell, kApolloAvatarUsernameKey);
    return ApolloAvatarUsernameMatches(storedUsername, username);
}

static BOOL ApolloBindInlineAvatarTextNodeForCell(id cell, NSString *username) {
    if (!ApolloInlineAvatarCellUsernameMatches(cell, username)) return NO;

    CGFloat diameter = ApolloInlineAvatarDiameterForObject(cell);

    id textNode = objc_getAssociatedObject(cell, kApolloAvatarTextNodeKey);
    if (ApolloTextNodeContainsUsername(textNode, username) && ApolloNodeTreeContainsObject(cell, textNode, [NSMutableSet set], 0)) {
        ApolloSetInlineAvatarDiameterForObject(textNode, diameter);
        return YES;
    }

    textNode = ApolloBestAuthorTextNode(cell, username);
    if (!ApolloTextNodeContainsUsername(textNode, username)) return NO;
    objc_setAssociatedObject(cell, kApolloAvatarTextNodeKey, textNode, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloSetInlineAvatarDiameterForObject(textNode, diameter);
    return YES;
}

static void ApolloApplyInlineAvatarInfoToCell(id cell, NSString *username, ApolloUserProfileInfo *info);

static void ApolloScheduleInlineAvatarLateReapplyForCell(id cell, NSString *username) {
    username = ApolloAvatarNormalizedUsername(username);
    if (!cell || username.length == 0) return;

    NSString *pendingUsername = objc_getAssociatedObject(cell, kApolloAvatarPendingLateReapplyUsernameKey);
    if (ApolloAvatarUsernameMatches(pendingUsername, username)) return;
    objc_setAssociatedObject(cell, kApolloAvatarPendingLateReapplyUsernameKey, username, OBJC_ASSOCIATION_COPY_NONATOMIC);

    NSArray<NSNumber *> *delays = @[@0.6, @1.5];
    __weak id weakCell = cell;
    for (NSUInteger index = 0; index < delays.count; index++) {
        NSTimeInterval delay = delays[index].doubleValue;
        BOOL finalAttempt = (index + 1 == delays.count);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            id strongCell = weakCell;
            if (!strongCell) return;
            if (!sShowUserAvatars || !ApolloInlineAvatarCellUsernameMatches(strongCell, username)) {
                objc_setAssociatedObject(strongCell, kApolloAvatarPendingLateReapplyUsernameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
                return;
            }

            ApolloUserProfileCache *cache = [ApolloUserProfileCache sharedCache];
            ApolloUserProfileInfo *cachedInfo = [cache cachedInfoForUsername:username];
            UIImage *cachedImage = cachedInfo.iconURL ? [cache cachedImageForURL:cachedInfo.iconURL] : nil;
            if (cachedInfo.iconURL && cachedImage) {
                id previousTextNode = objc_getAssociatedObject(strongCell, kApolloAvatarTextNodeKey);
                BOOL hadAvatar = ApolloTextLooksAvatarPrepended(ApolloAttributedTextForNode(previousTextNode));
                objc_setAssociatedObject(strongCell, kApolloAvatarTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                ApolloApplyInlineAvatarInfoToCell(strongCell, username, cachedInfo);
                id currentTextNode = objc_getAssociatedObject(strongCell, kApolloAvatarTextNodeKey);
                BOOL hasAvatar = ApolloTextLooksAvatarPrepended(ApolloAttributedTextForNode(currentTextNode));
                if ((!hadAvatar || currentTextNode != previousTextNode) && hasAvatar && ApolloInlineAvatarShouldLog(&sApolloInlineAvatarLateReapplyLogCount)) {
                    ApolloLog(@"[UserAvatars] Inline avatar late reapply u/%@ cell=%p", username, strongCell);
                }
            }

            if (finalAttempt) {
                objc_setAssociatedObject(strongCell, kApolloAvatarPendingLateReapplyUsernameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
            }
        });
    }
}

static void ApolloApplyInlineAvatarInfoToCell(id cell, NSString *username, ApolloUserProfileInfo *info) {
    username = ApolloAvatarNormalizedUsername(username);
    if (!cell || username.length == 0 || !sShowUserAvatars || !info.iconURL) return;
    if (!ApolloBindInlineAvatarTextNodeForCell(cell, username)) return;

    ApolloUserProfileCache *cache = [ApolloUserProfileCache sharedCache];
    UIImage *cachedImage = [cache cachedImageForURL:info.iconURL];
    UIImage *cachedDecoratorImage = info.decoratorURL ? [cache cachedImageForURL:info.decoratorURL] : nil;
    if (cachedImage) {
        BOOL applied = ApolloApplyAvatarRenderToCell(cell, username, info, cachedImage, cachedDecoratorImage);
        if (applied && ApolloInlineAvatarShouldLog(&sApolloInlineAvatarAppliedLogCount)) {
            ApolloLog(@"[UserAvatars] Inline avatar applied from cache u/%@ cell=%p", username, cell);
        }
        if (applied) ApolloScheduleInlineAvatarLateReapplyForCell(cell, username);
        ApolloRequestDecoratorRefreshIfNeeded(cache, info);
        return;
    }

    __weak id weakCell = cell;
    [cache requestImageForURL:info.iconURL completion:^(UIImage *loadedImage) {
        id cellNow = weakCell;
        if (!cellNow || !sShowUserAvatars || !loadedImage) return;
        if (!ApolloBindInlineAvatarTextNodeForCell(cellNow, username)) return;
        UIImage *loadedDecoratorImage = info.decoratorURL ? [cache cachedImageForURL:info.decoratorURL] : nil;
        BOOL applied = ApolloApplyAvatarRenderToCell(cellNow, username, info, loadedImage, loadedDecoratorImage);
        if (applied && ApolloInlineAvatarShouldLog(&sApolloInlineAvatarAppliedLogCount)) {
            ApolloLog(@"[UserAvatars] Inline avatar applied after image load u/%@ cell=%p", username, cellNow);
        }
        if (applied) ApolloScheduleInlineAvatarLateReapplyForCell(cellNow, username);
        ApolloRequestDecoratorRefreshIfNeeded(cache, info);
    }];
}

static void ApolloScheduleInlineAvatarInfoFetchAttempt(id cell, NSString *username, NSUInteger attempt) {
    __weak id weakCell = cell;
    NSTimeInterval delay = ApolloInlineAvatarBindDelayForAttempt(attempt);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id strongCell = weakCell;
        if (!strongCell) return;
        if (!sShowUserAvatars) {
            ApolloClearPendingInlineAvatarFetch(strongCell, username);
            return;
        }
        if (!ApolloInlineAvatarCellUsernameMatches(strongCell, username)) {
            ApolloClearPendingInlineAvatarFetch(strongCell, username);
            return;
        }
        if (!ApolloBindInlineAvatarTextNodeForCell(strongCell, username)) {
            if (ApolloInlineAvatarShouldLog(&sApolloInlineAvatarNoTextLogCount)) {
                ApolloLog(@"[UserAvatars] Inline avatar waiting for author text u/%@ attempt=%lu cell=%p", username, (unsigned long)(attempt + 1), strongCell);
            }
            if (attempt + 1 < ApolloInlineAvatarMaxBindAttempts) {
                ApolloScheduleInlineAvatarInfoFetchAttempt(strongCell, username, attempt + 1);
            } else {
                if (ApolloInlineAvatarShouldLog(&sApolloInlineAvatarGaveUpLogCount)) {
                    ApolloLog(@"[UserAvatars] Inline avatar gave up waiting for author text u/%@ cell=%p", username, strongCell);
                }
                ApolloClearPendingInlineAvatarFetch(strongCell, username);
            }
            return;
        }

        ApolloUserProfileCache *cache = [ApolloUserProfileCache sharedCache];
        ApolloUserProfileInfo *cachedInfo = [cache cachedInfoForUsername:username];
        if (cachedInfo.iconURL) {
            ApolloClearPendingInlineAvatarFetch(strongCell, username);
            ApolloApplyInlineAvatarInfoToCell(strongCell, username, cachedInfo);
            return;
        }

        if (ApolloInlineAvatarShouldLog(&sApolloInlineAvatarQueuedLogCount)) {
            ApolloLog(@"[UserAvatars] Inline avatar queued metadata fetch u/%@ cell=%p", username, strongCell);
        }
        ApolloEnqueueInlineAvatarInfoRequest(^{
            id requestCell = weakCell;
            if (!requestCell) {
                ApolloInlineAvatarInfoRequestDidFinish();
                return;
            }
            if (!sShowUserAvatars) {
                ApolloClearPendingInlineAvatarFetch(requestCell, username);
                ApolloInlineAvatarInfoRequestDidFinish();
                return;
            }
            if (!ApolloInlineAvatarCellUsernameMatches(requestCell, username) || !ApolloBindInlineAvatarTextNodeForCell(requestCell, username)) {
                ApolloClearPendingInlineAvatarFetch(requestCell, username);
                ApolloInlineAvatarInfoRequestDidFinish();
                return;
            }

            __block BOOL releasedSlot = NO;
            void (^releaseSlot)(void) = ^{
                if (releasedSlot) return;
                releasedSlot = YES;
                ApolloInlineAvatarInfoRequestDidFinish();
            };

            [cache requestInfoForUsername:username completion:^(ApolloUserProfileInfo *info) {
                releaseSlot();
                id cellNow = weakCell;
                if (!cellNow) return;
                ApolloClearPendingInlineAvatarFetch(cellNow, username);
                if (!sShowUserAvatars || !info.iconURL) return;
                ApolloApplyInlineAvatarInfoToCell(cellNow, username, info);
            }];
        });
    });
}

static void ApolloScheduleInlineAvatarInfoFetchForCell(id cell, NSString *username) {
    username = ApolloAvatarNormalizedUsername(username);
    if (!cell || username.length == 0) return;

    NSString *pendingUsername = objc_getAssociatedObject(cell, kApolloAvatarPendingFetchUsernameKey);
    if (ApolloAvatarUsernameMatches(pendingUsername, username)) return;
    objc_setAssociatedObject(cell, kApolloAvatarPendingFetchUsernameKey, username, OBJC_ASSOCIATION_COPY_NONATOMIC);
    ApolloScheduleInlineAvatarInfoFetchAttempt(cell, username, 0);
}

static void ApolloApplyAvatarToCellWithDiameter(id cell, NSString *username, CGFloat diameter) {
    username = ApolloAvatarNormalizedUsername(username);
    if (!cell || username.length == 0) {
        ApolloRestoreAvatarForCell(cell);
        return;
    }

    if (!sShowUserAvatars) {
        ApolloRestoreAvatarForCell(cell);
        return;
    }

    ApolloSetInlineAvatarDiameterForObject(cell, diameter);
    objc_setAssociatedObject(cell, kApolloAvatarUsernameKey, username, OBJC_ASSOCIATION_COPY_NONATOMIC);
    id textNode = ApolloBestAuthorTextNode(cell, username);
    if (textNode) {
        objc_setAssociatedObject(cell, kApolloAvatarTextNodeKey, textNode, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloSetInlineAvatarDiameterForObject(textNode, diameter);
    }

    ApolloUserProfileCache *cache = [ApolloUserProfileCache sharedCache];
    ApolloUserProfileInfo *cachedInfo = [cache cachedInfoForUsername:username];
    if (cachedInfo.iconURL && ApolloBindInlineAvatarTextNodeForCell(cell, username)) ApolloApplyInlineAvatarInfoToCell(cell, username, cachedInfo);
    else ApolloScheduleInlineAvatarInfoFetchForCell(cell, username);
}

static UIView *ApolloFindSubviewOfClass(UIView *root, Class cls) {
    if (!root || !cls) return nil;
    if ([root isKindOfClass:cls]) return root;
    for (UIView *subview in root.subviews) {
        UIView *match = ApolloFindSubviewOfClass(subview, cls);
        if (match) return match;
    }
    return nil;
}

static UITableView *ApolloFindTableView(UIViewController *viewController) {
    if ([viewController respondsToSelector:@selector(tableView)]) {
        UITableView *(*msgSend)(id, SEL) = (UITableView *(*)(id, SEL))objc_msgSend;
        id tableView = msgSend(viewController, @selector(tableView));
        if ([tableView isKindOfClass:[UITableView class]]) return tableView;
    }
    return (UITableView *)ApolloFindSubviewOfClass(viewController.view, [UITableView class]);
}

static NSString *ApolloUsernameFromProfileViewController(UIViewController *viewController) {
    NSArray<NSString *> *preferredIvars = @[@"username", @"userName", @"_username", @"account", @"user", @"profile", @"viewModel"];
    for (NSString *ivarName in preferredIvars) {
        id value = ApolloObjectIvarValue(viewController, ivarName);
        if ([value isKindOfClass:[NSString class]]) {
            NSString *username = ApolloAvatarNormalizedUsername(value);
            if (username.length > 0) return username;
        }
        NSString *username = ApolloUsernameFromModelObject(value);
        if (username.length > 0) return username;
    }

    NSString *title = viewController.navigationItem.title ?: viewController.title;
    title = ApolloAvatarNormalizedUsername(title);
    NSSet<NSString *> *blockedTitles = [NSSet setWithObjects:@"accounts", @"account", @"profile", @"settings", @"overview", nil];
    if ([blockedTitles containsObject:title.lowercaseString]) return nil;
    if (title.length > 0 && ![title containsString:@" "] && title.length <= 32) return title;
    return nil;
}

static UIImage *ApolloProfilePlaceholderAvatar(void) {
    return ApolloCircularAvatarImage(nil, ApolloProfileAvatarDiameter);
}

static void ApolloProfileSetSnoovatarMode(ApolloProfileHeaderView *header, BOOL showSnoovatar) {
    header.snoovatarImageView.hidden = !showSnoovatar;
    header.avatarBorderView.hidden = showSnoovatar;
    header.avatarImageView.hidden = showSnoovatar;
    [header setNeedsLayout];
}

static ApolloProfileHeaderView *ApolloProfileCreateHeader(CGFloat width) {
    ApolloProfileHeaderView *header = [[ApolloProfileHeaderView alloc] initWithFrame:CGRectMake(0.0, 0.0, width, ApolloProfileHeaderHeight)];
    header.avatarImageView.image = ApolloProfilePlaceholderAvatar();
    ApolloProfileSetSnoovatarMode(header, NO);
    return header;
}

static void ApolloProfileLoadImages(ApolloProfileHeaderView *header, NSString *username) {
    if (!header || username.length == 0) return;
    ApolloUserProfileCache *cache = [ApolloUserProfileCache sharedCache];
    ApolloUserProfileInfo *cachedInfo = [cache cachedInfoForUsername:username];

    void (^applyInfo)(ApolloUserProfileInfo *) = ^(ApolloUserProfileInfo *info) {
        if (!info) return;
        BOOL showSnoovatar = info.hasSnoovatar && info.snoovatarURL != nil;
        ApolloProfileSetSnoovatarMode(header, showSnoovatar);

        NSURL *profileImageURL = showSnoovatar ? info.snoovatarURL : info.iconURL;
        if (profileImageURL) {
            UIImage *image = [cache cachedImageForURL:profileImageURL];
            if (image) {
                if (showSnoovatar) header.snoovatarImageView.image = image;
                else header.avatarImageView.image = image;
            } else {
                [cache requestImageForURL:profileImageURL completion:^(UIImage *loadedImage) {
                    if (!loadedImage) return;
                    if (showSnoovatar) header.snoovatarImageView.image = loadedImage;
                    else header.avatarImageView.image = loadedImage;
                }];
            }
        }
        if (info.bannerURL) {
            UIImage *banner = [cache cachedImageForURL:info.bannerURL];
            if (banner) {
                header.bannerImageView.image = banner;
            } else {
                [cache requestImageForURL:info.bannerURL completion:^(UIImage *loadedImage) {
                    if (loadedImage) header.bannerImageView.image = loadedImage;
                }];
            }
        }
    };

    if (cachedInfo) applyInfo(cachedInfo);
    [cache requestInfoForUsername:username completion:applyInfo];
}

static BOOL ApolloViewControllerLooksProfileRelated(UIViewController *viewController) {
    NSString *className = NSStringFromClass([viewController class]);
    return [className containsString:@"ProfileViewController"] ||
        [className containsString:@"AccountManagerViewController"];
}

static void ApolloProfileInstallOrUpdateHeader(id viewControllerObject) {
    if (![viewControllerObject isKindOfClass:[UIViewController class]]) return;
    UIViewController *viewController = (UIViewController *)viewControllerObject;
    UITableView *tableView = ApolloFindTableView(viewController);
    NSString *className = NSStringFromClass([viewController class]);
    if (!tableView) {
        if (ApolloViewControllerLooksProfileRelated(viewController)) {
            ApolloLog(@"[UserAvatars] Profile header skipped class=%@ vc=%p reason=no-table", className, viewControllerObject);
        }
        return;
    }

    ApolloProfileHeaderView *header = objc_getAssociatedObject(viewControllerObject, kApolloProfileHeaderViewKey);
    UIView *wrappedHeader = objc_getAssociatedObject(viewControllerObject, kApolloProfileWrappedHeaderKey);
    UIView *originalHeader = objc_getAssociatedObject(viewControllerObject, kApolloProfileOriginalHeaderKey);

    if (!sShowUserAvatars) {
        if (wrappedHeader && tableView.tableHeaderView == wrappedHeader) {
            tableView.tableHeaderView = originalHeader;
            ApolloLog(@"[UserAvatars] Profile header restored native header class=%@ vc=%p", className, viewControllerObject);
        }
        objc_setAssociatedObject(viewControllerObject, kApolloProfileHeaderViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(viewControllerObject, kApolloProfileWrappedHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(viewControllerObject, kApolloProfileOriginalHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    NSString *username = ApolloUsernameFromProfileViewController(viewController);
    if (username.length == 0) {
        if (ApolloViewControllerLooksProfileRelated(viewController)) {
            ApolloLog(@"[UserAvatars] Profile header skipped class=%@ vc=%p table=%p reason=no-username title=%@", className, viewControllerObject, tableView, viewController.navigationItem.title ?: viewController.title ?: @"nil");
        }
        return;
    }

    CGFloat width = tableView.bounds.size.width > 0 ? tableView.bounds.size.width : UIScreen.mainScreen.bounds.size.width;
    if (!header) {
        header = ApolloProfileCreateHeader(width);
        objc_setAssociatedObject(viewControllerObject, kApolloProfileHeaderViewKey, header, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIView *currentTableHeader = tableView.tableHeaderView;
    if (currentTableHeader && objc_getAssociatedObject(currentTableHeader, kApolloProfileWrapperMarkerKey)) {
        wrappedHeader = currentTableHeader;
        header = objc_getAssociatedObject(currentTableHeader, kApolloProfileHeaderViewKey) ?: header;
        originalHeader = objc_getAssociatedObject(currentTableHeader, kApolloProfileOriginalHeaderKey);
        objc_setAssociatedObject(viewControllerObject, kApolloProfileHeaderViewKey, header, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(viewControllerObject, kApolloProfileWrappedHeaderKey, wrappedHeader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(viewControllerObject, kApolloProfileOriginalHeaderKey, originalHeader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (!wrappedHeader || tableView.tableHeaderView != wrappedHeader) {
        originalHeader = currentTableHeader;
        CGFloat originalHeight = originalHeader ? originalHeader.frame.size.height : 0.0;
        wrappedHeader = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, width, ApolloProfileHeaderHeight + originalHeight)];
        wrappedHeader.backgroundColor = [UIColor systemBackgroundColor];
        header.frame = CGRectMake(0.0, 0.0, width, ApolloProfileHeaderHeight);
        [wrappedHeader addSubview:header];
        if (originalHeader) {
            originalHeader.frame = CGRectMake(0.0, ApolloProfileHeaderHeight, width, originalHeight);
            [wrappedHeader addSubview:originalHeader];
        }
        objc_setAssociatedObject(wrappedHeader, kApolloProfileWrapperMarkerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(wrappedHeader, kApolloProfileHeaderViewKey, header, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(wrappedHeader, kApolloProfileOriginalHeaderKey, originalHeader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(viewControllerObject, kApolloProfileWrappedHeaderKey, wrappedHeader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(viewControllerObject, kApolloProfileOriginalHeaderKey, originalHeader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        tableView.tableHeaderView = wrappedHeader;
        ApolloLog(@"[UserAvatars] Installed profile header class=%@ vc=%p table=%p username=%@ nativeHeader=%@", className, viewControllerObject, tableView, username, originalHeader ? NSStringFromClass([originalHeader class]) : @"nil");
    } else {
        CGFloat originalHeight = originalHeader ? originalHeader.frame.size.height : 0.0;
        CGRect desiredFrame = CGRectMake(0.0, 0.0, width, ApolloProfileHeaderHeight + originalHeight);
        if (!CGRectEqualToRect(wrappedHeader.frame, desiredFrame)) {
            wrappedHeader.frame = desiredFrame;
            header.frame = CGRectMake(0.0, 0.0, width, ApolloProfileHeaderHeight);
            originalHeader.frame = CGRectMake(0.0, ApolloProfileHeaderHeight, width, originalHeight);
            tableView.tableHeaderView = wrappedHeader;
            ApolloLog(@"[UserAvatars] Resized profile header class=%@ vc=%p username=%@ width=%.1f", className, viewControllerObject, username, width);
        }
    }

    NSString *storedUsername = objc_getAssociatedObject(viewControllerObject, kApolloProfileUsernameKey);
    if (![storedUsername isEqualToString:username]) {
        objc_setAssociatedObject(viewControllerObject, kApolloProfileUsernameKey, username, OBJC_ASSOCIATION_COPY_NONATOMIC);
        header.avatarImageView.image = ApolloProfilePlaceholderAvatar();
        header.snoovatarImageView.image = nil;
        header.bannerImageView.image = nil;
        ApolloProfileSetSnoovatarMode(header, NO);
        ApolloProfileLoadImages(header, username);
        ApolloLog(@"[UserAvatars] Loading profile header images class=%@ vc=%p username=%@", className, viewControllerObject, username);
    }
}

static void ApolloProfileRefreshViewControllersInTree(UIViewController *viewController, NSString *username, NSHashTable *visited, NSUInteger *refreshCount) {
    if (!viewController || [visited containsObject:viewController]) return;
    [visited addObject:viewController];

    NSString *storedUsername = objc_getAssociatedObject(viewController, kApolloProfileUsernameKey);
    NSString *currentUsername = ApolloUsernameFromProfileViewController(viewController);
    BOOL profileRelated = ApolloViewControllerLooksProfileRelated(viewController);
    BOOL usernameMatches = username.length == 0 || ApolloAvatarUsernameMatches(storedUsername, username) || ApolloAvatarUsernameMatches(currentUsername, username);
    if ((profileRelated || storedUsername.length > 0) && usernameMatches) {
        if (username.length > 0) {
            objc_setAssociatedObject(viewController, kApolloProfileUsernameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        ApolloProfileInstallOrUpdateHeader(viewController);
        if (refreshCount) (*refreshCount)++;
    }

    for (UIViewController *child in viewController.childViewControllers) {
        ApolloProfileRefreshViewControllersInTree(child, username, visited, refreshCount);
    }
    if (viewController.presentedViewController) {
        ApolloProfileRefreshViewControllersInTree(viewController.presentedViewController, username, visited, refreshCount);
    }
}

static void ApolloProfileRefreshControllersForUsername(NSString *username) {
    username = ApolloAvatarNormalizedUsername(username);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:128];
        NSUInteger refreshCount = 0;
        for (UIWindow *window in [UIApplication sharedApplication].windows) {
            ApolloProfileRefreshViewControllersInTree(window.rootViewController, username, visited, &refreshCount);
        }
        if (username.length > 0 || refreshCount > 0) {
            ApolloLog(@"[UserAvatars] Refreshed %lu profile controllers after profile update for u/%@", (unsigned long)refreshCount, username ?: @"all");
        }
    });
}

%hook ASTextNode

- (void)setAttributedText:(NSAttributedString *)attributedText {
    if ([objc_getAssociatedObject(self, kApolloAvatarApplyingTextKey) boolValue]) {
        %orig;
        return;
    }

    NSAttributedString *swap = nil;
    if (ApolloPrepareAvatarRewriteForTextNode(self, attributedText, &swap)) {
        objc_setAssociatedObject(self, kApolloAvatarApplyingTextKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @try {
            %orig(swap);
        } @catch (__unused NSException *exception) {
        } @finally {
            objc_setAssociatedObject(self, kApolloAvatarApplyingTextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    %orig;
}

%end

%hook ASTextNode2

- (void)setAttributedText:(NSAttributedString *)attributedText {
    if ([objc_getAssociatedObject(self, kApolloAvatarApplyingTextKey) boolValue]) {
        %orig;
        return;
    }

    NSAttributedString *swap = nil;
    if (ApolloPrepareAvatarRewriteForTextNode(self, attributedText, &swap)) {
        objc_setAssociatedObject(self, kApolloAvatarApplyingTextKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @try {
            %orig(swap);
        } @catch (__unused NSException *exception) {
        } @finally {
            objc_setAssociatedObject(self, kApolloAvatarApplyingTextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    %orig;
}

%end

%hook _TtC6Apollo15CommentCellNode

- (void)didLoad {
    %orig;
    ApolloApplyAvatarToCellWithDiameter(self, ApolloUsernameFromCell(self, @"comment"), ApolloCommentInlineAvatarDiameter);
}

%end

%hook _TtC6Apollo17LargePostCellNode

- (void)didLoad {
    %orig;
    ApolloApplyAvatarToCellWithDiameter(self, ApolloUsernameFromCell(self, @"link"), ApolloFeedInlineAvatarDiameter);
}

%end

%hook _TtC6Apollo22CommentsHeaderCellNode

- (void)didLoad {
    %orig;
    ApolloApplyAvatarToCellWithDiameter(self, ApolloUsernameFromCell(self, @"link"), ApolloFeedInlineAvatarDiameter);
}

%end

%hook _TtC6Apollo19CompactPostCellNode

- (void)didLoad {
    %orig;
    ApolloApplyAvatarToCellWithDiameter(self, ApolloUsernameFromCell(self, @"link"), ApolloFeedInlineAvatarDiameter);
}

%end

%hook _TtC6Apollo21ProfileViewController

- (void)viewDidLoad {
    %orig;
    ApolloProfileInstallOrUpdateHeader(self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    ApolloProfileInstallOrUpdateHeader(self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloProfileInstallOrUpdateHeader(self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloProfileInstallOrUpdateHeader(self);
}

%end

%hook _TtC6Apollo28AccountManagerViewController

- (void)viewDidLoad {
    %orig;
    ApolloProfileInstallOrUpdateHeader(self);
    ApolloProfileRefreshControllersForUsername(nil);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    ApolloProfileInstallOrUpdateHeader(self);
    ApolloProfileRefreshControllersForUsername(nil);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloProfileInstallOrUpdateHeader(self);
    ApolloProfileRefreshControllersForUsername(nil);
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloProfileInstallOrUpdateHeader(self);
}

%end

%ctor {
    %init;
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloUserAvatarsToggleChangedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ApolloProfileRefreshControllersForUsername(nil);
    }];
}