#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloDeletedCommentsData.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "Tweak.h"

static const void *kApolloDeletedCommentsFlairContainerKey = &kApolloDeletedCommentsFlairContainerKey;
static const void *kApolloDeletedCommentsFlairOriginalBackgroundKey = &kApolloDeletedCommentsFlairOriginalBackgroundKey;
static const void *kApolloDeletedCommentsHiddenOriginalTextKey = &kApolloDeletedCommentsHiddenOriginalTextKey;
static const void *kApolloDeletedCommentsHiddenFullNameKey = &kApolloDeletedCommentsHiddenFullNameKey;
static const void *kApolloDeletedCommentsHiddenTextNodeKey = &kApolloDeletedCommentsHiddenTextNodeKey;
static const void *kApolloDeletedCommentsSuppressNextCollapseKey = &kApolloDeletedCommentsSuppressNextCollapseKey;
static const void *kApolloDeletedCommentsRevealFadeTimerKey = &kApolloDeletedCommentsRevealFadeTimerKey;
static const void *kApolloDeletedCommentsRevealFadeStartKey = &kApolloDeletedCommentsRevealFadeStartKey;
static const void *kApolloDeletedCommentsRevealFadeBaseTextKey = &kApolloDeletedCommentsRevealFadeBaseTextKey;
static const void *kApolloDeletedCommentsRevealFadeAccentKey = &kApolloDeletedCommentsRevealFadeAccentKey;
static const void *kApolloDeletedCommentsInternalTextUpdateKey = &kApolloDeletedCommentsInternalTextUpdateKey;

static const NSTimeInterval kApolloDeletedCommentsRevealFadeDuration = 10.0;
static const NSTimeInterval kApolloDeletedCommentsRevealFadeTickInterval = 0.15;
static const CGFloat kApolloDeletedCommentsRevealFadePeakAlpha = 0.25;
static const CGFloat kApolloDeletedCommentsSpoilerFillAlpha = 0.25;

static NSString *const ApolloDeletedCommentsTapPlaceholderText = @"SHOW";
static NSString *const ApolloDeletedCommentsRevealURLString = @"apollo-deleted-comments://reveal";
static NSString *const ApolloDeletedCommentsRevealAttributeName = @"ApolloDeletedCommentsRevealAttribute";

static id ApolloDeletedCommentsCommentCellNodeForTextNode(id textNode);
static BOOL ApolloDeletedCommentsTextNodeBelongsToRecoveredComment(id textNode);
static BOOL ApolloDeletedCommentsAttributedTextIsRevealPlaceholder(NSAttributedString *attributedText);

static NSString *ApolloDeletedCommentsTrimmedString(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return nil;
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL ApolloDeletedCommentsIsRecoveredFlairText(NSAttributedString *attributedText) {
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) return NO;
    NSString *text = ApolloDeletedCommentsTrimmedString(attributedText.string);
    NSString *lower = [text lowercaseString];
    return [lower isEqualToString:@"deleted"] ||
           [lower isEqualToString:@"user deleted"] ||
           [lower isEqualToString:@"removed by mod"];
}

static UIColor *ApolloDeletedCommentsBadgeRed(void) {
    if (@available(iOS 13.0, *)) {
        return [UIColor systemRedColor];
    }
    return [UIColor redColor];
}

static NSAttributedString *ApolloDeletedCommentsStyledFlairText(NSAttributedString *attributedText) {
    if (!ApolloDeletedCommentsIsRecoveredFlairText(attributedText)) return attributedText;

    NSMutableAttributedString *styled = [attributedText mutableCopy];
    NSRange fullRange = NSMakeRange(0, styled.length);
    [styled addAttribute:NSForegroundColorAttributeName value:ApolloDeletedCommentsBadgeRed() range:fullRange];
    [styled removeAttribute:NSBackgroundColorAttributeName range:fullRange];
    return styled;
}

static id ApolloDeletedCommentsFlairContainerForTextNode(id textNode) {
    if (!textNode || ![textNode respondsToSelector:@selector(supernode)]) return nil;

    id current = nil;
    @try {
        current = ((id (*)(id, SEL))objc_msgSend)(textNode, @selector(supernode));
    } @catch (__unused NSException *e) {
        current = nil;
    }

    for (NSUInteger i = 0; current && i < 3; i++) {
        const char *className = class_getName(object_getClass(current));
        if (className && strstr(className, "CommentCellNode")) return nil;
        if ([current respondsToSelector:@selector(setBackgroundColor:)]) return current;
        if (![current respondsToSelector:@selector(supernode)]) break;
        @try {
            current = ((id (*)(id, SEL))objc_msgSend)(current, @selector(supernode));
        } @catch (__unused NSException *e) {
            break;
        }
    }
    return nil;
}

static void ApolloDeletedCommentsRestoreFlairContainer(id textNode) {
    id container = objc_getAssociatedObject(textNode, kApolloDeletedCommentsFlairContainerKey);
    if (!container) return;

    UIColor *original = objc_getAssociatedObject(textNode, kApolloDeletedCommentsFlairOriginalBackgroundKey);
    if ([container respondsToSelector:@selector(setBackgroundColor:)]) {
        @try {
            ((void (*)(id, SEL, UIColor *))objc_msgSend)(container, @selector(setBackgroundColor:), original);
        } @catch (__unused NSException *e) {}
    }

    objc_setAssociatedObject(textNode, kApolloDeletedCommentsFlairContainerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsFlairOriginalBackgroundKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloDeletedCommentsApplyFlairContainerStyle(id textNode, NSAttributedString *attributedText) {
    if (!sShowDeletedComments || !ApolloDeletedCommentsIsRecoveredFlairText(attributedText)) {
        ApolloDeletedCommentsRestoreFlairContainer(textNode);
        return;
    }

    id container = ApolloDeletedCommentsFlairContainerForTextNode(textNode);
    if (!container) return;

    id previous = objc_getAssociatedObject(textNode, kApolloDeletedCommentsFlairContainerKey);
    if (previous && previous != container) ApolloDeletedCommentsRestoreFlairContainer(textNode);
    if (!objc_getAssociatedObject(textNode, kApolloDeletedCommentsFlairContainerKey)) {
        UIColor *original = nil;
        if ([container respondsToSelector:@selector(backgroundColor)]) {
            @try {
                original = ((UIColor *(*)(id, SEL))objc_msgSend)(container, @selector(backgroundColor));
            } @catch (__unused NSException *e) {
                original = nil;
            }
        }
        objc_setAssociatedObject(textNode, kApolloDeletedCommentsFlairContainerKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (original) objc_setAssociatedObject(textNode, kApolloDeletedCommentsFlairOriginalBackgroundKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIColor *background = [ApolloDeletedCommentsBadgeRed() colorWithAlphaComponent:0.24];
    @try {
        ((void (*)(id, SEL, UIColor *))objc_msgSend)(container, @selector(setBackgroundColor:), background);
    } @catch (__unused NSException *e) {}
}

static NSString *ApolloDeletedCommentsNormalizeCommentFullName(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return nil;
    if ([value hasPrefix:@"t1_"]) return value;
    if ([value rangeOfString:@"_"].location != NSNotFound) return nil;
    return [@"t1_" stringByAppendingString:value];
}

static NSString *ApolloDeletedCommentsFullNameForComment(RDKComment *comment) {
    if (!comment) return nil;
    SEL selectors[] = {
        @selector(name),
        NSSelectorFromString(@"fullName"),
        NSSelectorFromString(@"identifier"),
        NSSelectorFromString(@"id"),
    };
    for (size_t i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        SEL sel = selectors[i];
        if (![(id)comment respondsToSelector:sel]) continue;
        id value = nil;
        @try {
            value = ((id (*)(id, SEL))objc_msgSend)((id)comment, sel);
        } @catch (__unused NSException *e) {
            value = nil;
        }
        NSString *fullName = ApolloDeletedCommentsNormalizeCommentFullName([value isKindOfClass:[NSString class]] ? value : nil);
        if (fullName.length > 0) return fullName;
    }

    static const char *ivarNames[] = {
        "name",
        "_name",
        "fullName",
        "_fullName",
        "identifier",
        "_identifier",
        "commentID",
        "_commentID",
        "id",
        "_id",
        NULL,
    };
    for (Class cls = [(id)comment class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        for (size_t i = 0; ivarNames[i]; i++) {
            Ivar ivar = class_getInstanceVariable(cls, ivarNames[i]);
            if (!ivar) continue;
            const char *type = ivar_getTypeEncoding(ivar);
            if (!type || type[0] != '@') continue;
            id value = nil;
            @try {
                value = object_getIvar(comment, ivar);
            } @catch (__unused NSException *e) {
                value = nil;
            }
            NSString *fullName = ApolloDeletedCommentsNormalizeCommentFullName([value isKindOfClass:[NSString class]] ? value : nil);
            if (fullName.length > 0) return fullName;
        }
    }
    return nil;
}

static RDKComment *ApolloDeletedCommentsCommentFromCellNode(id commentCellNode) {
    if (!commentCellNode) return nil;
    Ivar commentIvar = class_getInstanceVariable([commentCellNode class], "comment");
    if (!commentIvar) return nil;
    id comment = nil;
    @try {
        comment = object_getIvar(commentCellNode, commentIvar);
    } @catch (__unused NSException *e) {
        comment = nil;
    }
    Class rdkCommentClass = NSClassFromString(@"RDKComment");
    if (!rdkCommentClass || ![comment isKindOfClass:rdkCommentClass]) return nil;
    return (RDKComment *)comment;
}

static id ApolloDeletedCommentsKnownBodyTextNode(id commentCellNode) {
    if (!commentCellNode) return nil;
    static const char *candidateNames[] = {
        "bodyTextNode",
        "commentTextNode",
        "commentBodyNode",
        "bodyNode",
        "markdownNode",
        "commentMarkdownNode",
        "attributedTextNode",
        "textNode",
        "commentBodyTextNode",
        "bodyMarkdownNode",
        NULL,
    };
    for (Class cls = [commentCellNode class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        for (size_t i = 0; candidateNames[i]; i++) {
            Ivar ivar = class_getInstanceVariable(cls, candidateNames[i]);
            if (!ivar) continue;
            const char *type = ivar_getTypeEncoding(ivar);
            if (!type || type[0] != '@') continue;
            id node = nil;
            @try {
                node = object_getIvar(commentCellNode, ivar);
            } @catch (__unused NSException *e) {
                node = nil;
            }
            if (node && [node respondsToSelector:@selector(attributedText)] && [node respondsToSelector:@selector(setAttributedText:)]) {
                return node;
            }
        }
    }
    return nil;
}

static void ApolloDeletedCommentsRelayoutCellAndTextNode(id cellNode, id textNode) {
    SEL selectors[] = {
        @selector(setNeedsLayout),
        @selector(setNeedsDisplay),
    };
    for (size_t i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        SEL sel = selectors[i];
        if ([textNode respondsToSelector:sel]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(textNode, sel); } @catch (__unused NSException *e) {}
        }
        if ([cellNode respondsToSelector:sel]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(cellNode, sel); } @catch (__unused NSException *e) {}
        }
    }
}

static UIView *ApolloDeletedCommentsViewForTextNode(id textNode) {
    if (!textNode || ![textNode respondsToSelector:@selector(view)]) return nil;
    @try {
        UIView *view = ((UIView *(*)(id, SEL))objc_msgSend)(textNode, @selector(view));
        return [view isKindOfClass:[UIView class]] ? view : nil;
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static UIColor *ApolloDeletedCommentsThemeAccent(id textNode) {
    return ApolloThemeAccentFromView(ApolloDeletedCommentsViewForTextNode(textNode));
}

static UIColor *ApolloDeletedCommentsContrastingTextColorForAccent(UIColor *accent) {
    if (![accent isKindOfClass:[UIColor class]]) return [UIColor whiteColor];
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    if (![accent getRed:&red green:&green blue:&blue alpha:&alpha]) return [UIColor whiteColor];
    CGFloat luminance = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue);
    return luminance > 0.62 ? [UIColor blackColor] : [UIColor whiteColor];
}

static BOOL ApolloDeletedCommentsIsGreySpoilerFillColor(UIColor *color) {
    if (![color isKindOfClass:[UIColor class]]) return NO;
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    if ([color getRed:&red green:&green blue:&blue alpha:&alpha]) {
        BOOL isNeutral = (fabs(red - green) < 0.08 && fabs(green - blue) < 0.08);
        BOOL isLightGrey = isNeutral && red > 0.65 && red < 0.95;
        BOOL isDarkGrey = isNeutral && red > 0.15 && red < 0.55;
        return (isLightGrey || isDarkGrey) && alpha > 0.08;
    }
    CGFloat white = 0.0;
    if ([color getWhite:&white alpha:&alpha]) {
        return white > 0.15 && white < 0.95 && alpha > 0.08;
    }
    return NO;
}

static BOOL ApolloDeletedCommentsAttributedTextHasSpoilerPillAttachment(NSAttributedString *attributedText) {
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) return NO;
    __block BOOL found = NO;
    [attributedText enumerateAttribute:NSAttachmentAttributeName
                               inRange:NSMakeRange(0, attributedText.length)
                               options:0
                            usingBlock:^(id value, NSRange range, BOOL *stop) {
        if (![value isKindOfClass:[NSTextAttachment class]]) return;
        NSTextAttachment *attachment = (NSTextAttachment *)value;
        if (![attachment.image isKindOfClass:[UIImage class]]) return;
        if (range.length >= attributedText.length || attributedText.length <= 12) {
            found = YES;
            *stop = YES;
        }
    }];
    return found;
}

static BOOL ApolloDeletedCommentsIsInlineSpoilerPillAttributedText(NSAttributedString *attributedText) {
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) return NO;
    NSString *trimmed = ApolloDeletedCommentsTrimmedString(attributedText.string);
    if (![trimmed isEqualToString:@"SPOILER"] && ![trimmed isEqualToString:@"Spoiler"]) return NO;
    if (ApolloDeletedCommentsAttributedTextHasSpoilerPillAttachment(attributedText)) return YES;

    __block BOOL hasSpoilerBackground = NO;
    [attributedText enumerateAttribute:NSBackgroundColorAttributeName
                               inRange:NSMakeRange(0, attributedText.length)
                               options:0
                            usingBlock:^(id value, NSRange range, BOOL *stop) {
        if (ApolloDeletedCommentsIsGreySpoilerFillColor((UIColor *)value)) {
            hasSpoilerBackground = YES;
            *stop = YES;
        }
    }];
    return hasSpoilerBackground;
}

static UIFont *ApolloDeletedCommentsSpoilerFontFromAttributes(NSDictionary *attributes) {
    UIFont *font = attributes[NSFontAttributeName];
    if (![font isKindOfClass:[UIFont class]]) {
        return [UIFont boldSystemFontOfSize:15.0];
    }
    return [UIFont boldSystemFontOfSize:MAX(12.0, font.pointSize - 2.5)];
}

static UIImage *ApolloDeletedCommentsSpoilerStyleImage(NSString *text, UIFont *font, UIColor *accentColor) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return nil;
    if (![font isKindOfClass:[UIFont class]]) font = [UIFont boldSystemFontOfSize:15.0];
    if (![accentColor isKindOfClass:[UIColor class]]) accentColor = [UIColor systemBlueColor];

    UIColor *fillColor = [accentColor colorWithAlphaComponent:kApolloDeletedCommentsSpoilerFillAlpha];
    UIColor *textColor = ApolloDeletedCommentsContrastingTextColorForAccent(accentColor);
    NSDictionary *attributes = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: textColor,
    };
    CGSize textSize = [text sizeWithAttributes:attributes];
    CGFloat horizontalPadding = 4.0;
    CGFloat verticalPadding = 0.5;
    CGSize imageSize = CGSizeMake(ceil(textSize.width + horizontalPadding * 2.0),
                                  ceil(textSize.height + verticalPadding * 2.0));

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    format.scale = UIScreen.mainScreen.scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:imageSize format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect bounds = CGRectMake(0.0, 0.0, imageSize.width, imageSize.height);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:6.0];
        [fillColor setFill];
        [path fill];

        CGRect textRect = CGRectMake(horizontalPadding,
                                     floor((imageSize.height - textSize.height) / 2.0),
                                     textSize.width,
                                     textSize.height);
        [text drawInRect:textRect withAttributes:attributes];
    }];
}

static NSAttributedString *ApolloDeletedCommentsThemeSpoilerChipAttributedText(id textNode,
                                                                               NSString *pillText,
                                                                               NSAttributedString *reference,
                                                                               BOOL includeRevealLink) {
    NSDictionary *attributes = @{};
    if ([reference isKindOfClass:[NSAttributedString class]] && reference.length > 0) {
        attributes = [reference attributesAtIndex:0 effectiveRange:NULL] ?: @{};
    }
    UIFont *font = ApolloDeletedCommentsSpoilerFontFromAttributes(attributes);
    UIColor *accent = ApolloDeletedCommentsThemeAccent(textNode);

    NSMutableParagraphStyle *paragraphStyle = [NSMutableParagraphStyle new];
    paragraphStyle.lineSpacing = 0.0;
    paragraphStyle.paragraphSpacing = 0.0;
    paragraphStyle.minimumLineHeight = ceil(font.lineHeight + 2.0);
    paragraphStyle.maximumLineHeight = ceil(font.lineHeight + 2.0);

    UIImage *image = ApolloDeletedCommentsSpoilerStyleImage(pillText, font, accent);
    if (![image isKindOfClass:[UIImage class]]) {
        NSMutableDictionary *fallbackAttributes = [attributes mutableCopy] ?: [NSMutableDictionary dictionary];
        fallbackAttributes[NSFontAttributeName] = font;
        fallbackAttributes[NSForegroundColorAttributeName] = ApolloDeletedCommentsContrastingTextColorForAccent(accent);
        fallbackAttributes[NSBackgroundColorAttributeName] = [accent colorWithAlphaComponent:kApolloDeletedCommentsSpoilerFillAlpha];
        fallbackAttributes[NSParagraphStyleAttributeName] = paragraphStyle;
        if (includeRevealLink) {
            fallbackAttributes[ApolloDeletedCommentsRevealAttributeName] = ApolloDeletedCommentsRevealURLString;
        }
        return [[NSAttributedString alloc] initWithString:pillText attributes:fallbackAttributes];
    }

    NSTextAttachment *attachment = [NSTextAttachment new];
    attachment.image = image;
    attachment.bounds = CGRectMake(0.0, -1.0, image.size.width, image.size.height);
    NSMutableAttributedString *result = [[NSAttributedString attributedStringWithAttachment:attachment] mutableCopy];
    [result addAttribute:NSParagraphStyleAttributeName value:paragraphStyle range:NSMakeRange(0, result.length)];
    if (includeRevealLink) {
        [result addAttribute:ApolloDeletedCommentsRevealAttributeName
                       value:ApolloDeletedCommentsRevealURLString
                       range:NSMakeRange(0, result.length)];
    }
    return result;
}

static void ApolloDeletedCommentsSetAttributedTextPreservingFade(id textNode, NSAttributedString *attributedText) {
    if (!textNode || ![textNode respondsToSelector:@selector(setAttributedText:)]) return;
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsInternalTextUpdateKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
        ((void (*)(id, SEL, NSAttributedString *))objc_msgSend)(textNode, @selector(setAttributedText:), attributedText);
    } @catch (__unused NSException *e) {}
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsInternalTextUpdateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloDeletedCommentsCancelRevealFade(id textNode) {
    if (!textNode) return;
    NSTimer *timer = objc_getAssociatedObject(textNode, kApolloDeletedCommentsRevealFadeTimerKey);
    [timer invalidate];
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsRevealFadeTimerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsRevealFadeStartKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsRevealFadeBaseTextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsRevealFadeAccentKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloDeletedCommentsRevealFadeTimerFired(id textNode) {
    if (!textNode) return;

    NSDate *startDate = objc_getAssociatedObject(textNode, kApolloDeletedCommentsRevealFadeStartKey);
    NSAttributedString *baseText = objc_getAssociatedObject(textNode, kApolloDeletedCommentsRevealFadeBaseTextKey);
    UIColor *accent = objc_getAssociatedObject(textNode, kApolloDeletedCommentsRevealFadeAccentKey);
    if (![startDate isKindOfClass:[NSDate class]] ||
        ![baseText isKindOfClass:[NSAttributedString class]] ||
        ![accent isKindOfClass:[UIColor class]]) {
        ApolloDeletedCommentsCancelRevealFade(textNode);
        return;
    }

    NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:startDate];
    if (elapsed >= kApolloDeletedCommentsRevealFadeDuration) {
        ApolloDeletedCommentsCancelRevealFade(textNode);
        ApolloDeletedCommentsSetAttributedTextPreservingFade(textNode, baseText);
        id cellNode = ApolloDeletedCommentsCommentCellNodeForTextNode(textNode);
        ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, textNode);
        return;
    }

    CGFloat progress = (CGFloat)(elapsed / kApolloDeletedCommentsRevealFadeDuration);
    CGFloat alpha = kApolloDeletedCommentsRevealFadePeakAlpha * (1.0 - progress);
    NSMutableAttributedString *faded = [baseText mutableCopy];
    if (alpha > 0.001) {
        [faded addAttribute:NSBackgroundColorAttributeName
                      value:[accent colorWithAlphaComponent:alpha]
                      range:NSMakeRange(0, faded.length)];
    } else {
        [faded removeAttribute:NSBackgroundColorAttributeName range:NSMakeRange(0, faded.length)];
    }
    ApolloDeletedCommentsSetAttributedTextPreservingFade(textNode, faded);
    id cellNode = ApolloDeletedCommentsCommentCellNodeForTextNode(textNode);
    ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, textNode);
}

static void ApolloDeletedCommentsStartRevealFade(id cellNode, id textNode, NSAttributedString *revealedText) {
    if (!textNode || ![revealedText isKindOfClass:[NSAttributedString class]] || revealedText.length == 0) return;

    ApolloDeletedCommentsCancelRevealFade(textNode);
    UIColor *accent = ApolloDeletedCommentsThemeAccent(textNode);
    NSAttributedString *baseText = [revealedText copy];
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsRevealFadeBaseTextKey, baseText, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsRevealFadeAccentKey, accent, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsRevealFadeStartKey, [NSDate date], OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSMutableAttributedString *highlighted = [baseText mutableCopy];
    [highlighted addAttribute:NSBackgroundColorAttributeName
                        value:[accent colorWithAlphaComponent:kApolloDeletedCommentsRevealFadePeakAlpha]
                        range:NSMakeRange(0, highlighted.length)];
    ApolloDeletedCommentsSetAttributedTextPreservingFade(textNode, highlighted);
    ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, textNode);

    __weak id weakTextNode = textNode;
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:kApolloDeletedCommentsRevealFadeTickInterval
                                                     repeats:YES
                                                       block:^(NSTimer *activeTimer) {
        id strongTextNode = weakTextNode;
        if (!strongTextNode) {
            [activeTimer invalidate];
            return;
        }
        ApolloDeletedCommentsRevealFadeTimerFired(strongTextNode);
    }];
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsRevealFadeTimerKey, timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSAttributedString *ApolloDeletedCommentsPlaceholderAttributedText(id textNode, NSAttributedString *original) {
    return ApolloDeletedCommentsThemeSpoilerChipAttributedText(textNode,
                                                             ApolloDeletedCommentsTapPlaceholderText,
                                                             original,
                                                             YES);
}

static BOOL ApolloDeletedCommentsAttributedTextIsRevealPlaceholder(NSAttributedString *attributedText) {
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) return NO;
    if ([attributedText.string isEqualToString:ApolloDeletedCommentsTapPlaceholderText]) return YES;

    __block BOOL hasRevealLink = NO;
    [attributedText enumerateAttribute:NSLinkAttributeName
                               inRange:NSMakeRange(0, attributedText.length)
                               options:0
                            usingBlock:^(id value, NSRange range, BOOL *stop) {
        NSString *urlString = nil;
        if ([value isKindOfClass:[NSURL class]]) {
            urlString = [(NSURL *)value absoluteString];
        } else if ([value isKindOfClass:[NSString class]]) {
            urlString = value;
        }
        if ([urlString isEqualToString:ApolloDeletedCommentsRevealURLString]) {
            hasRevealLink = YES;
            *stop = YES;
        }
    }];
    if (hasRevealLink) return YES;

    [attributedText enumerateAttribute:ApolloDeletedCommentsRevealAttributeName
                               inRange:NSMakeRange(0, attributedText.length)
                               options:0
                            usingBlock:^(id value, NSRange range, BOOL *stop) {
        if ([value isEqual:ApolloDeletedCommentsRevealURLString]) {
            hasRevealLink = YES;
            *stop = YES;
        }
    }];
    return hasRevealLink;
}

static NSString *ApolloDeletedCommentsNormalizeTextForCompare(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return @"";
    NSString *trimmed = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
    return [regex stringByReplacingMatchesInString:trimmed options:0 range:NSMakeRange(0, trimmed.length) withTemplate:@" "];
}

static BOOL ApolloDeletedCommentsTextQualifiesAsBodyCandidate(NSString *candidate, NSString *body) {
    NSString *candidateNorm = ApolloDeletedCommentsNormalizeTextForCompare(candidate);
    NSString *bodyNorm = ApolloDeletedCommentsNormalizeTextForCompare(body);
    if (candidateNorm.length == 0 || bodyNorm.length == 0) return NO;
    if ([candidateNorm isEqualToString:bodyNorm]) return YES;
    NSUInteger minLen = MIN(candidateNorm.length, bodyNorm.length);
    if (minLen < 24) return NO;
    NSString *candidatePrefix = [candidateNorm substringToIndex:minLen];
    NSString *bodyPrefix = [bodyNorm substringToIndex:minLen];
    return [candidatePrefix isEqualToString:bodyPrefix];
}

static void ApolloDeletedCommentsCollectAttributedTextNodes(id object, NSInteger depth, NSHashTable *visited, NSMutableArray *nodes) {
    if (!object || depth < 0 || [visited containsObject:object]) return;
    [visited addObject:object];

    @try {
        if ([object respondsToSelector:@selector(attributedText)] && [object respondsToSelector:@selector(setAttributedText:)]) {
            NSAttributedString *text = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(object, @selector(attributedText));
            if ([text isKindOfClass:[NSAttributedString class]] && text.length > 0) {
                [nodes addObject:object];
            }
        }

        if ([object respondsToSelector:@selector(subnodes)]) {
            NSArray *subnodes = ((NSArray *(*)(id, SEL))objc_msgSend)(object, @selector(subnodes));
            if ([subnodes isKindOfClass:[NSArray class]]) {
                for (id subnode in subnodes) ApolloDeletedCommentsCollectAttributedTextNodes(subnode, depth - 1, visited, nodes);
            }
        }
    } @catch (__unused NSException *e) {}
}

static id ApolloDeletedCommentsBestBodyTextNode(id cellNode, RDKComment *comment) {
    NSString *body = comment.body;
    id known = ApolloDeletedCommentsKnownBodyTextNode(cellNode);
    if (known) {
        NSAttributedString *text = nil;
        @try {
            text = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(known, @selector(attributedText));
        } @catch (__unused NSException *e) {
            text = nil;
        }
        if (ApolloDeletedCommentsTextQualifiesAsBodyCandidate(text.string, body)) return known;
    }

    NSMutableArray *candidates = [NSMutableArray array];
    NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:64];
    ApolloDeletedCommentsCollectAttributedTextNodes(cellNode, 6, visited, candidates);

    id bestNode = nil;
    NSUInteger bestLength = 0;
    for (id candidate in candidates) {
        NSAttributedString *text = nil;
        @try {
            text = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(candidate, @selector(attributedText));
        } @catch (__unused NSException *e) {
            text = nil;
        }
        if (!ApolloDeletedCommentsTextQualifiesAsBodyCandidate(text.string, body)) continue;
        if (text.length > bestLength) {
            bestLength = text.length;
            bestNode = candidate;
        }
    }
    return bestNode;
}

static void ApolloDeletedCommentsRestoreHiddenBodyIfNeeded(id cellNode, id textNode) {
    ApolloDeletedCommentsCancelRevealFade(textNode);

    NSAttributedString *original = objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey);
    if (![original isKindOfClass:[NSAttributedString class]]) return;

    NSAttributedString *current = nil;
    @try {
        current = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(textNode, @selector(attributedText));
    } @catch (__unused NSException *e) {
        current = nil;
    }
    if (![current isKindOfClass:[NSAttributedString class]] ||
        ApolloDeletedCommentsAttributedTextIsRevealPlaceholder(current)) {
        @try {
            ((void (*)(id, SEL, NSAttributedString *))objc_msgSend)(textNode, @selector(setAttributedText:), original);
        } @catch (__unused NSException *e) {}
    }
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenFullNameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (objc_getAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey) == textNode) {
        objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, textNode);
}

static void ApolloDeletedCommentsEnsureRevealAttributeIsTappable(id textNode) {
    if (!textNode) return;

    if ([textNode respondsToSelector:@selector(setUserInteractionEnabled:)]) {
        @try {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(textNode, @selector(setUserInteractionEnabled:), YES);
        } @catch (__unused NSException *e) {}
    }

    if ([textNode respondsToSelector:@selector(view)]) {
        @try {
            UIView *view = ((UIView *(*)(id, SEL))objc_msgSend)(textNode, @selector(view));
            if ([view isKindOfClass:[UIView class]]) view.userInteractionEnabled = YES;
        } @catch (__unused NSException *e) {}
    }

    if (![textNode respondsToSelector:@selector(setLinkAttributeNames:)]) return;

    NSMutableSet *names = [NSMutableSet setWithObjects:NSLinkAttributeName, ApolloDeletedCommentsRevealAttributeName, nil];
    if ([textNode respondsToSelector:@selector(linkAttributeNames)]) {
        @try {
            id existing = ((id (*)(id, SEL))objc_msgSend)(textNode, @selector(linkAttributeNames));
            if ([existing isKindOfClass:[NSArray class]]) {
                [names addObjectsFromArray:(NSArray *)existing];
            } else if ([existing isKindOfClass:[NSSet class]]) {
                [names unionSet:(NSSet *)existing];
            }
        } @catch (__unused NSException *e) {}
    }

    NSArray *orderedNames = names.allObjects;
    @try {
        ((void (*)(id, SEL, NSArray *))objc_msgSend)(textNode, @selector(setLinkAttributeNames:), orderedNames);
    } @catch (__unused NSException *e) {}
}

static void __attribute__((unused)) ApolloDeletedCommentsApplyTapToRevealIfNeeded(id cellNode) {
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    NSString *author = comment.author;
    NSString *body = comment.body;
    id textNode = ApolloDeletedCommentsBestBodyTextNode(cellNode, comment);
    if (!textNode) return;

    BOOL recovered = ApolloDeletedCommentsIsRecoveredComment(fullName) ||
                     ApolloDeletedCommentsIsRecoveredCommentBody(author, body);
    BOOL revealed = ApolloDeletedCommentsIsCommentRevealed(fullName) ||
                    ApolloDeletedCommentsIsCommentBodyRevealed(author, body);
    BOOL shouldHide = sShowDeletedComments &&
                      sTapToRevealDeletedComments &&
                      recovered &&
                      !revealed;
    if (!shouldHide) {
        ApolloDeletedCommentsRestoreHiddenBodyIfNeeded(cellNode, textNode);
        return;
    }

    NSAttributedString *existingOriginal = objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey);
    NSAttributedString *existingCurrent = nil;
    @try {
        existingCurrent = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(textNode, @selector(attributedText));
    } @catch (__unused NSException *e) {
        existingCurrent = nil;
    }
    if ([existingOriginal isKindOfClass:[NSAttributedString class]] &&
        ApolloDeletedCommentsAttributedTextIsRevealPlaceholder(existingCurrent)) {
        ApolloDeletedCommentsEnsureRevealAttributeIsTappable(textNode);
        return;
    }

    NSString *hiddenFullName = objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenFullNameKey);
    if ([hiddenFullName isEqualToString:fullName]) {
        ApolloDeletedCommentsEnsureRevealAttributeIsTappable(textNode);
        return;
    }

    ApolloDeletedCommentsRestoreHiddenBodyIfNeeded(cellNode, textNode);

    NSAttributedString *current = nil;
    @try {
        current = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(textNode, @selector(attributedText));
    } @catch (__unused NSException *e) {
        current = nil;
    }
    if (![current isKindOfClass:[NSAttributedString class]] || current.length == 0) return;
    if (ApolloDeletedCommentsAttributedTextIsRevealPlaceholder(current)) return;

    objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey, [current copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenFullNameKey, fullName, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey, textNode, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSAttributedString *placeholder = ApolloDeletedCommentsPlaceholderAttributedText(textNode, current);
    @try {
        ((void (*)(id, SEL, NSAttributedString *))objc_msgSend)(textNode, @selector(setAttributedText:), placeholder);
    } @catch (__unused NSException *e) {}
    ApolloDeletedCommentsEnsureRevealAttributeIsTappable(textNode);
    ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, textNode);
}

static BOOL ApolloDeletedCommentsTouchHitsTextNode(id textNode, UITouch *touch) {
    if (!textNode || !touch || ![textNode respondsToSelector:@selector(view)]) return NO;
    UIView *nodeView = nil;
    @try {
        nodeView = ((UIView *(*)(id, SEL))objc_msgSend)(textNode, @selector(view));
    } @catch (__unused NSException *e) {
        nodeView = nil;
    }
    if (![nodeView isKindOfClass:[UIView class]] || nodeView.hidden || nodeView.alpha < 0.01) return NO;
    CGPoint point = [touch locationInView:nodeView];
    return CGRectContainsPoint(CGRectInset(nodeView.bounds, -8.0, -8.0), point);
}

static void ApolloDeletedCommentsForceCommentExpanded(RDKComment *comment, id cellNode) {
    if (!comment) return;

    if ([(id)comment respondsToSelector:@selector(setCollapsed:)]) {
        @try {
            ((void (*)(id, SEL, BOOL))objc_msgSend)((id)comment, @selector(setCollapsed:), NO);
        } @catch (__unused NSException *e) {}
    }

    Ivar collapsedIvar = class_getInstanceVariable([(id)comment class], "_collapsed");
    if (collapsedIvar) {
        @try {
            ptrdiff_t offset = ivar_getOffset(collapsedIvar);
            if (offset > 0) {
                BOOL *slot = (BOOL *)((uint8_t *)(__bridge void *)comment + offset);
                *slot = NO;
            }
        } @catch (__unused NSException *e) {}
    }

    SEL selectors[] = {
        @selector(setNeedsLayout),
        @selector(setNeedsDisplay),
    };
    for (size_t i = 0; i < 2; i++) {
        SEL sel = selectors[i];
        if ([cellNode respondsToSelector:sel]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(cellNode, sel); } @catch (__unused NSException *e) {}
        }
    }
}

static void ApolloDeletedCommentsScheduleForceExpanded(RDKComment *comment, id cellNode) {
    if (!comment) return;
    NSArray<NSNumber *> *delays = @[@0.0, @0.03, @0.12, @0.30];
    for (NSNumber *delayNumber in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayNumber.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ApolloDeletedCommentsForceCommentExpanded(comment, cellNode);
        });
    }
}

static BOOL __attribute__((unused)) ApolloDeletedCommentsTouchHitsHiddenBody(id cellNode, UITouch *touch) {
    id textNode = objc_getAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey);
    if (!objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey)) return NO;
    return ApolloDeletedCommentsTouchHitsTextNode(textNode, touch);
}

static void ApolloDeletedCommentsRevealHiddenBodyForCell(id cellNode) {
    id textNode = objc_getAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey);
    NSAttributedString *original = objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey);
    if (![original isKindOfClass:[NSAttributedString class]]) return;

    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    ApolloDeletedCommentsMarkCommentRevealed(fullName);
    ApolloDeletedCommentsMarkCommentBodyRevealed(comment.author, comment.body);
    objc_setAssociatedObject(comment, kApolloDeletedCommentsSuppressNextCollapseKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenFullNameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (objc_getAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey) == textNode) {
        objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    ApolloDeletedCommentsStartRevealFade(cellNode, textNode, original);
    ApolloDeletedCommentsScheduleForceExpanded(comment, cellNode);
}

static id ApolloDeletedCommentsCommentCellNodeForTextNode(id textNode) {
    if (!textNode || ![textNode respondsToSelector:@selector(supernode)]) return nil;
    id current = textNode;
    for (NSUInteger i = 0; current && i < 10; i++) {
        const char *className = class_getName(object_getClass(current));
        if (className && strstr(className, "CommentCellNode")) return current;
        if (![current respondsToSelector:@selector(supernode)]) break;
        @try {
            current = ((id (*)(id, SEL))objc_msgSend)(current, @selector(supernode));
        } @catch (__unused NSException *e) {
            break;
        }
    }
    return nil;
}

static BOOL ApolloDeletedCommentsTextNodeBelongsToRecoveredComment(id textNode) {
    id cellNode = ApolloDeletedCommentsCommentCellNodeForTextNode(textNode);
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    if (!comment) return NO;
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    return ApolloDeletedCommentsIsRecoveredComment(fullName) ||
           ApolloDeletedCommentsIsRecoveredCommentBody(comment.author, comment.body);
}

static BOOL ApolloDeletedCommentsIsRevealLink(id attribute, id value) {
    if ([attribute isKindOfClass:[NSString class]] &&
        [(NSString *)attribute isEqualToString:ApolloDeletedCommentsRevealAttributeName]) {
        return YES;
    }

    NSString *urlString = nil;
    if ([value isKindOfClass:[NSURL class]]) {
        urlString = [(NSURL *)value absoluteString];
    } else if ([value isKindOfClass:[NSString class]]) {
        urlString = value;
    }
    return [urlString isEqualToString:ApolloDeletedCommentsRevealURLString];
}

static NSAttributedString *ApolloDeletedCommentsApplyThemeSpoilerStyling(id textNode, NSAttributedString *attributedText) {
    if (ApolloDeletedCommentsAttributedTextIsRevealPlaceholder(attributedText)) return attributedText;
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) return attributedText;

    NSString *trimmed = ApolloDeletedCommentsTrimmedString(attributedText.string);
    if ([trimmed isEqualToString:@"SPOILER"] &&
        sShowDeletedComments &&
        sTapToRevealDeletedComments &&
        ApolloDeletedCommentsTextNodeBelongsToRecoveredComment(textNode)) {
        return ApolloDeletedCommentsThemeSpoilerChipAttributedText(textNode, @"SHOW", attributedText, NO);
    }

    if (ApolloDeletedCommentsIsInlineSpoilerPillAttributedText(attributedText)) {
        NSString *pillText = [trimmed isEqualToString:@"Spoiler"] ? @"Spoiler" : @"SPOILER";
        return ApolloDeletedCommentsThemeSpoilerChipAttributedText(textNode, pillText, attributedText, NO);
    }

    return attributedText;
}

static NSAttributedString *ApolloDeletedCommentsProcessAttributedText(id textNode, NSAttributedString *attributedText) {
    NSAttributedString *processed = ApolloDeletedCommentsApplyThemeSpoilerStyling(textNode, attributedText);
    return ApolloDeletedCommentsStyledFlairText(processed);
}

%hook ASTextNode

- (void)setAttributedText:(NSAttributedString *)attributedText {
    if (!objc_getAssociatedObject((id)self, kApolloDeletedCommentsInternalTextUpdateKey)) {
        ApolloDeletedCommentsCancelRevealFade((id)self);
    }
    NSAttributedString *styledAttributedText = ApolloDeletedCommentsProcessAttributedText((id)self, attributedText);
    %orig(styledAttributedText);
    ApolloDeletedCommentsApplyFlairContainerStyle((id)self, styledAttributedText);
}

- (void)didEnterDisplayState {
    %orig;
    NSAttributedString *attributedText = nil;
    @try {
        attributedText = ((NSAttributedString *(*)(id, SEL))objc_msgSend)((id)self, @selector(attributedText));
    } @catch (__unused NSException *e) {
        attributedText = nil;
    }
    NSAttributedString *styledAttributedText = ApolloDeletedCommentsProcessAttributedText((id)self, attributedText);
    if (styledAttributedText != attributedText) {
        @try {
            ApolloDeletedCommentsSetAttributedTextPreservingFade((id)self, styledAttributedText);
            attributedText = styledAttributedText;
        } @catch (__unused NSException *e) {}
    }
    ApolloDeletedCommentsApplyFlairContainerStyle((id)self, attributedText);
}

- (void)didExitDisplayState {
    ApolloDeletedCommentsCancelRevealFade((id)self);
    ApolloDeletedCommentsRestoreFlairContainer((id)self);
    %orig;
}

%end

@interface _TtC6Apollo15CommentCellNode
- (void)didLoad;
- (void)didEnterDisplayState;
- (void)layout;
@end

%hook _TtC6Apollo15CommentCellNode

- (void)didLoad {
    %orig;
}

- (void)didEnterDisplayState {
    %orig;
}

- (void)layout {
    %orig;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return %orig;
}

%end

%hook RDKComment

- (void)setCollapsed:(BOOL)collapsed {
    if (collapsed && [objc_getAssociatedObject((id)self, kApolloDeletedCommentsSuppressNextCollapseKey) boolValue]) {
        objc_setAssociatedObject((id)self, kApolloDeletedCommentsSuppressNextCollapseKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    %orig;
}

%end

%hook _TtC6Apollo12MarkdownNode

- (BOOL)textNode:(id)textNode shouldHighlightLinkAttribute:(id)attribute value:(id)value atPoint:(CGPoint)point {
    if (ApolloDeletedCommentsIsRevealLink(attribute, value) &&
        objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey)) {
        return YES;
    }
    return %orig(textNode, attribute, value, point);
}

- (BOOL)textNode:(id)textNode shouldLongPressLinkAttribute:(id)attribute value:(id)value atPoint:(CGPoint)point {
    if (ApolloDeletedCommentsIsRevealLink(attribute, value)) {
        return NO;
    }
    return %orig(textNode, attribute, value, point);
}

- (void)textNode:(id)textNode tappedLinkAttribute:(id)attribute value:(id)value atPoint:(CGPoint)point textRange:(NSRange)range {
    if (ApolloDeletedCommentsIsRevealLink(attribute, value) &&
        objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey)) {
        id cellNode = ApolloDeletedCommentsCommentCellNodeForTextNode(textNode);
        ApolloDeletedCommentsRevealHiddenBodyForCell(cellNode);
        return;
    }
    %orig(textNode, attribute, value, point, range);
}

%end
