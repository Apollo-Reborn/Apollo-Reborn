// On iOS 26+, Media, Link, and Text use the same inset-grouped presentation
// as Poll. The storyboard also archives pre-iOS-26 row/header metrics, so
// changing only its table style leaves the older, cramped layout in place.
#import "ApolloCommon.h"
#import "ApolloClasses.h"
#import "ApolloSwiftRuntime.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// The scope includes the synchronous storyboard decode, not viewDidLoad:
// by viewDidLoad the table's immutable style has already been chosen.
static __thread NSUInteger sApolloPostComposerLoadDepth;

// Preserve the real nib decoder and its object graph (prototype-cell nibs,
// outlets, constraints, delegate/dataSource). Only the table's two archived
// style keys change. A proxy also keeps this override out of every other
// NSCoder user; UIStyle is shared with unrelated UIKit controls.
@interface ApolloPostComposerTableCoder : NSProxy {
    NSCoder *_coder;
}
- (instancetype)initWithCoder:(NSCoder *)coder;
@end

@implementation ApolloPostComposerTableCoder

- (instancetype)initWithCoder:(NSCoder *)coder {
    _coder = coder;
    return self;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [_coder methodSignatureForSelector:selector];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    [invocation invokeWithTarget:_coder];
}

- (BOOL)respondsToSelector:(SEL)selector {
    return [_coder respondsToSelector:selector];
}

- (Class)class {
    return [_coder class];
}

- (BOOL)isKindOfClass:(Class)classObject {
    return [_coder isKindOfClass:classObject];
}

- (int64_t)styleValue:(int64_t)value forKey:(NSString *)key {
    // Both keys are present with value 1 in Apollo 1.15.11's composer nib.
    // Leave all other values/keys alone, including the prototype cell styles.
    if (value == UITableViewStyleGrouped &&
        ([key isEqualToString:@"UITableViewStyle"] || [key isEqualToString:@"UIStyle"])) {
        return UITableViewStyleInsetGrouped;
    }
    return value;
}

- (NSInteger)decodeIntegerForKey:(NSString *)key {
    return (NSInteger)[self styleValue:[_coder decodeIntegerForKey:key] forKey:key];
}

- (int)decodeIntForKey:(NSString *)key {
    return (int)[self styleValue:[_coder decodeIntForKey:key] forKey:key];
}

- (int32_t)decodeInt32ForKey:(NSString *)key {
    return (int32_t)[self styleValue:[_coder decodeInt32ForKey:key] forKey:key];
}

- (int64_t)decodeInt64ForKey:(NSString *)key {
    return [self styleValue:[_coder decodeInt64ForKey:key] forKey:key];
}

@end

static UILabel *ApolloPostComposerHeaderLabel(UIView *view) {
    if ([view isKindOfClass:UILabel.class] && ((UILabel *)view).text.length) return (UILabel *)view;
    for (UIView *child in view.subviews) {
        UILabel *label = ApolloPostComposerHeaderLabel(child);
        if (label) return label;
    }
    return nil;
}

// Apollo frames the post-type control 7pt in from each edge of a full-width
// toolbar and lets autoresizing keep those margins, so on the closed Duo its
// Poll segment ran under the status column. While the composer has a side
// inset, the control's frame comes from its safe area on every write; once the
// inset is gone (a rotation or fold), Apollo's 7pt margins come back once and
// its own frames pass through again. The result depends only on the layout,
// so repeated writes agree and never relayout the composer (the Poll page is
// constrained to the control).
static char kApolloPostComposerTypeControlKey;
static char kApolloPostComposerTypeControlInsetKey;

static const CGFloat kApolloPostComposerTypeControlMargin = 7.0;

// The composer's view, whose safe area its table follows. The toolbar's own
// differs in the open Duo's landscape form sheet, where it picks up the
// window's side inset that the sheet's content doesn't use.
static UIView *ApolloPostComposerSafeAreaView(UIView *toolbar) {
    Class composerClass = ApolloClassComposePostViewController;
    for (UIView *view = toolbar; view; view = view.superview) {
        if (composerClass && [view.nextResponder isKindOfClass:composerClass]) return view;
    }
    return toolbar;
}

static CGRect ApolloPostComposerResolveTypeControlFrame(UIView *control, CGRect frame) {
    UIView *toolbar = control.superview;
    if (!toolbar) return frame;
    UIView *safeView = ApolloPostComposerSafeAreaView(toolbar);
    UIEdgeInsets safe = safeView.safeAreaInsets;
    CGRect safeRect = [toolbar convertRect:UIEdgeInsetsInsetRect(safeView.bounds, UIEdgeInsetsMake(0.0, safe.left, 0.0, safe.right))
                                  fromView:safeView];
    CGFloat minX = MAX(0.0, CGRectGetMinX(safeRect));
    CGFloat maxX = MIN(CGRectGetWidth(toolbar.bounds), CGRectGetMaxX(safeRect));
    BOOL inset = minX > 0.5 || maxX < CGRectGetWidth(toolbar.bounds) - 0.5;
    BOOL wasInset = [objc_getAssociatedObject(control, &kApolloPostComposerTypeControlInsetKey) boolValue];
    if (!inset && !wasInset) return frame;
    CGFloat width = maxX - minX - 2.0 * kApolloPostComposerTypeControlMargin;
    if (width < 100.0) return frame;
    frame.origin.x = minX + kApolloPostComposerTypeControlMargin;
    frame.size.width = width;
    if (inset != wasInset) {
        objc_setAssociatedObject(control, &kApolloPostComposerTypeControlInsetKey, @(inset), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return frame;
}

static void ApolloPostComposerAdoptTypeControl(UIViewController *composer) {
    UIView *control = ApolloObjectIvar(composer, "postTypeSegmentedControl");
    if (![control isKindOfClass:[UISegmentedControl class]]) return;
    if (!objc_getAssociatedObject(control, &kApolloPostComposerTypeControlKey)) {
        objc_setAssociatedObject(control, &kApolloPostComposerTypeControlKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // The safe area changes without Apollo re-framing the control.
    CGRect resolved = ApolloPostComposerResolveTypeControlFrame(control, control.frame);
    if (!CGRectEqualToRect(resolved, control.frame)) control.frame = resolved;
}

%group ApolloPostComposerStyle

%hook ApolloInsetPostComposer

- (void)loadView {
    sApolloPostComposerLoadDepth++;
    @try {
        %orig;
    } @finally {
        sApolloPostComposerLoadDepth--;
    }
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    UIView *legacyHeader = %orig;
    UILabel *label = ApolloPostComposerHeaderLabel(legacyHeader);
    // Apollo uses an empty view plus a 1pt height for the first group. Nil
    // restores UIKit's normal top spacing as well as its section headers.
    if (!label) return nil;

    // Use UIKit's grouped header content and margins, as Poll does, instead
    // of Apollo's small uppercase label in a manually sized header view.
    UITableViewHeaderFooterView *header = [[UITableViewHeaderFooterView alloc] initWithReuseIdentifier:nil];
    UIListContentConfiguration *content = [UIListContentConfiguration groupedHeaderConfiguration];
    content.text = label.text.capitalizedString;
    content.textProperties.color = label.textColor;
    header.contentConfiguration = content;
    header.backgroundConfiguration = [UIBackgroundConfiguration clearConfiguration];
    return header;
}

- (void)viewWillLayoutSubviews {
    ApolloPostComposerAdoptTypeControl((UIViewController *)self);
    %orig;
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloPostComposerAdoptTypeControl((UIViewController *)self);
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return UITableViewAutomaticDimension;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    // Section zero owns the tappable subreddit/rules text view. The other
    // footers are empty: let UIKit supply its normal gap between groups.
    if (section == 0) return %orig;
    return UITableViewAutomaticDimension;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    CGFloat height = %orig;
    // Native ordinary rows (including URL, body, and media chooser) return
    // 44pt. Keep automatic title/media sizes and the media module's measured
    // combined title/body row intact; only remove the legacy fixed height.
    return height == 44.0 ? UITableViewAutomaticDimension : height;
}

- (CGFloat)tableView:(UITableView *)tableView estimatedHeightForRowAtIndexPath:(NSIndexPath *)indexPath {
    CGFloat height = %orig;
    return height == 44.0 ? UITableViewAutomaticDimension : height;
}

%end

%hook UISegmentedControl

- (void)setFrame:(CGRect)frame {
    if (objc_getAssociatedObject(self, &kApolloPostComposerTypeControlKey)) {
        frame = ApolloPostComposerResolveTypeControlFrame((UIView *)self, frame);
    }
    %orig(frame);
}

%end

%hook UITableView

- (instancetype)initWithCoder:(NSCoder *)coder {
    if (!sApolloPostComposerLoadDepth) return %orig;

    ApolloPostComposerTableCoder *tableCoder = [[ApolloPostComposerTableCoder alloc] initWithCoder:coder];
    UITableView *table = %orig((NSCoder *)tableCoder);
    // The archive fixes rows to 44pt, section headers/footers to 10pt, and
    // disables all estimates. Match a newly created inset-grouped table so
    // UIKit, rather than the old nib, supplies the current system metrics.
    UITableView *defaults = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    table.rowHeight = defaults.rowHeight;
    table.estimatedRowHeight = defaults.estimatedRowHeight;
    table.sectionHeaderHeight = defaults.sectionHeaderHeight;
    table.estimatedSectionHeaderHeight = defaults.estimatedSectionHeaderHeight;
    table.sectionFooterHeight = defaults.sectionFooterHeight;
    table.estimatedSectionFooterHeight = defaults.estimatedSectionFooterHeight;
    table.insetsContentViewsToSafeArea = defaults.insetsContentViewsToSafeArea;
    table.separatorInset = defaults.separatorInset;
    table.separatorInsetReference = defaults.separatorInsetReference;
    ApolloLog(@"[PostComposerStyle] decoded native composer table style=%ld", (long)table.style);
    return table;
}

%end

%end

%ctor {
    // This is an OS-version change, including the standard build on iOS 26.
    // Older systems retain Apollo's original table and delegate behavior.
    if (@available(iOS 26.0, *)) {
        if (ApolloClassComposePostViewController) {
            %init(ApolloPostComposerStyle, ApolloInsetPostComposer = ApolloClassComposePostViewController);
        }
    }
}
