#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloClasses.h"

// MARK: - Crosspost: start the title as the original post's title
//
// Crossposting opens Apollo's `CrosspostPerformViewController` card. Its title
// field (`textEntryNode`, an ASEditableTextNode with a "Title" placeholder)
// starts empty, and Submit stays greyed out until something is typed: the
// submit-state helper Apollo runs on every edit (sub_100499fc0, reached from
// -editableTextNodeDidUpdateText:) only enables it once `selectedSubreddit` is
// set AND the field is non-empty. reddit.com's crosspost form starts the title
// as the original post's title instead, so a plain crosspost there is just
// "pick a community, Post".
//
// Fix: when the card loads, fill the field with `crosspostParent.title` (the
// post being crossposted, the same RDKLink its preview shows) and put a clear
// (x) button at the trailing end of the field, so writing your own title is
// one tap away.
//
// Apollo draws that field one line tall (viewDidLoad sets
// maximumLinesToDisplay = 1), so any title wider than the field wrapped with
// the top of its second line peeking out of the bottom padding. Nearly every
// prefilled title is that long, so the field now grows to show up to
// kApolloCrosspostTitleMaxLines lines, and the card is re-measured when an
// edit changes its line count.
//
// Apollo's close button (-closeButtonNodeTappedWithSender: -> sub_1004a227c)
// and the tap outside the card (-[CrosspostPerformPresentationController
// tappedDarkOverlayViewWithTapGestureRecognizer:] -> sub_10049a810) both ask
// "Dismiss Without Crossposting?" when a flair or subreddit is picked or the
// title field has ANY text, and dismiss straight away otherwise (verified in
// Hopper). A prefilled title isn't something the user typed, so while those
// two checks run the field reads as empty if, and only if, it still holds the
// untouched original title. Picking a subreddit/flair or editing the title
// still prompts exactly as before.
//
// ASEditableTextNode is only used by this card in Apollo 1.15.11 (it is the
// one class in the class dump holding one), and each hook below still returns
// %orig first for any other instance.

@interface _TtC6Apollo30CrosspostPerformViewController : UIViewController
- (void)editableTextNodeDidUpdateText:(id)editableTextNode;
@end

@interface _TtC6Apollo38CrosspostPerformPresentationController : UIPresentationController
@end

// Only what this file calls; resolved at runtime against Apollo's bundled
// Texture (the ASEditableTextNode members are all implemented on that class).
@interface ASDisplayNode : NSObject
- (UIView *)view;
- (BOOL)isNodeLoaded;
- (void)setNeedsLayout;
- (CGSize)calculateSizeThatFits:(CGSize)constrainedSize;
@end

@interface ASEditableTextNode : ASDisplayNode
@property (nonatomic, copy) NSAttributedString *attributedText;
@property (nonatomic, copy) NSAttributedString *attributedPlaceholderText;
@property (nonatomic, copy) NSDictionary<NSAttributedStringKey, id> *typingAttributes;
@property (nonatomic) UIEdgeInsets textContainerInset;
@property (nonatomic) NSUInteger maximumLinesToDisplay;
@property (nonatomic, readonly) UITextView *textView;
- (BOOL)becomeFirstResponder;
@end

@interface RDKLink : NSObject
@property (nonatomic, copy) NSString *title;
@end

static char kApolloCrosspostTitleClearButtonKey;   // on the title node: our clear (x) button (marks the node as ours)
static char kApolloCrosspostTitlePrefilledKey;     // on the controller: the exact title we filled in

// The title node whose text reads as empty while Apollo runs one of its
// dismiss checks (see the header). Only set on the main thread, only across
// those two synchronous calls, and cleared in @finally. A read from another
// thread only compares against it and can never match.
static void *sApolloCrosspostMaskedTitleNode = NULL;

// Enough for most titles; a longer one scrolls inside the field.
static const NSUInteger kApolloCrosspostTitleMaxLines = 5;

// Apollo's field is a rounded box with textContainerInset {10, 13, 10, 13}. The
// button spans the first line at the trailing end, and the text stops short
// of it.
static const CGFloat kApolloCrosspostClearButtonWidth = 34.0;
static const CGFloat kApolloCrosspostClearButtonTextGap = 2.0;

static ASEditableTextNode *ApolloCrosspostTitleNode(id controller) {
    Class controllerClass = ApolloClassCrosspostPerformViewController;
    if (!controllerClass || ![controller isKindOfClass:controllerClass]) return nil;
    id node = ApolloReadObjectIvar(controller, "textEntryNode");
    Class nodeClass = ApolloClassASEditableTextNode;
    return (nodeClass && [node isKindOfClass:nodeClass]) ? node : nil;
}

// The title node, but only while it still holds exactly what we filled in.
static ASEditableTextNode *ApolloCrosspostUntouchedTitleNode(id controller) {
    ASEditableTextNode *node = ApolloCrosspostTitleNode(controller);
    NSString *prefilled = node ? objc_getAssociatedObject(controller, &kApolloCrosspostTitlePrefilledKey) : nil;
    if (prefilled.length == 0) return nil;
    return [node.attributedText.string isEqualToString:prefilled] ? node : nil;
}

// Same colour Apollo's theme gives the "Title" placeholder, so the button sits
// in the field like UIKit's own clear button in any theme.
static UIColor *ApolloCrosspostClearButtonTint(ASEditableTextNode *node) {
    NSAttributedString *placeholder = node.attributedPlaceholderText;
    UIColor *color = placeholder.length > 0
        ? [placeholder attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL]
        : nil;
    if ([color isKindOfClass:[UIColor class]]) return color;
    UIColor *textColor = node.typingAttributes[NSForegroundColorAttributeName];
    if ([textColor isKindOfClass:[UIColor class]]) return [textColor colorWithAlphaComponent:0.45];
    return [UIColor tertiaryLabelColor];
}

// Pins the button to the trailing end of the field's first line. Runs from the
// field's own -layout (below): Texture sizes the field by setting its layer's
// bounds directly, so UIKit autoresizing never fires for views we add to it,
// and -layout is where Texture itself frames the field's text views. It only
// frames our own button, so nothing it writes feeds back into the layout.
static void ApolloCrosspostLayoutClearButton(ASEditableTextNode *node, UIButton *button) {
    CGRect bounds = node.view.bounds;
    UIEdgeInsets insets = node.textContainerInset;
    UIFont *font = node.typingAttributes[NSFontAttributeName];
    CGFloat lineHeight = [font isKindOfClass:[UIFont class]] ? font.lineHeight : 22.0;
    CGFloat height = MIN(CGRectGetHeight(bounds), ceil(insets.top + lineHeight + insets.bottom));
    button.frame = CGRectMake(CGRectGetWidth(bounds) - kApolloCrosspostClearButtonWidth, 0.0,
                              kApolloCrosspostClearButtonWidth, height);
}

// Apollo only measures the card when its presentation controller lays out
// (appearing, keyboard changes, rotation); with a one-line title field nothing
// inside the card ever changed height. When an edit changes the title's line
// count, invalidate the card's layout and have the presentation controller
// measure it again.
static void ApolloCrosspostRelayoutIfTitleHeightChanged(UIViewController *controller, ASEditableTextNode *node) {
    if (!controller.viewIfLoaded.window || !node.isNodeLoaded) return;   // before presentation, the first measure covers it
    CGRect bounds = node.view.bounds;
    if (CGRectGetWidth(bounds) <= 0.0) return;
    CGFloat wanted = [node calculateSizeThatFits:CGSizeMake(CGRectGetWidth(bounds), CGFLOAT_MAX)].height;
    if (fabs(wanted - CGRectGetHeight(bounds)) < 0.5) return;

    ApolloLog(@"[CrosspostTitle] title field height %.0f -> %.0f, re-measuring the card",
              CGRectGetHeight(bounds), wanted);
    [node setNeedsLayout];
    [(ASDisplayNode *)ApolloReadObjectIvar(controller, "rootNode") setNeedsLayout];
    UIView *container = controller.presentationController.containerView;
    [UIView animateWithDuration:0.2
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        [container setNeedsLayout];
        [container layoutIfNeeded];
    }
                     completion:nil];
}

@interface ApolloCrosspostTitleClearButton : UIButton
@property (nonatomic, weak) UIViewController *crosspostController;
// The field only exposes its text view to VoiceOver, so clearing is offered
// there as a custom action while the field has text.
@property (nonatomic, strong) UIAccessibilityCustomAction *clearAction;
- (void)apollo_clearTitle;
@end

static void ApolloCrosspostRefreshClearButton(ASEditableTextNode *node) {
    ApolloCrosspostTitleClearButton *button = objc_getAssociatedObject(node, &kApolloCrosspostTitleClearButtonKey);
    if (!button) return;
    BOOL hasText = node.attributedText.length > 0;
    button.hidden = !hasText;
    button.tintColor = ApolloCrosspostClearButtonTint(node);

    UITextView *textView = node.textView;
    NSMutableArray *actions = [NSMutableArray arrayWithArray:textView.accessibilityCustomActions];
    [actions removeObject:button.clearAction];
    if (hasText && button.clearAction) [actions addObject:button.clearAction];
    textView.accessibilityCustomActions = actions.count > 0 ? actions : nil;
}

@implementation ApolloCrosspostTitleClearButton

- (void)apollo_clearTitle {
    UIViewController *controller = self.crosspostController;
    ASEditableTextNode *node = ApolloCrosspostTitleNode(controller);
    if (!node) return;
    node.attributedText = [[NSAttributedString alloc] initWithString:@"" attributes:node.typingAttributes];
    // Programmatic text changes never reach the node's delegate, so announce
    // this one the way an edit would: Apollo greys Submit out again, and the
    // hook below hides this button and shrinks the field back to one line.
    [(_TtC6Apollo30CrosspostPerformViewController *)controller editableTextNodeDidUpdateText:node];
    // Like UIKit's clear button: the caret lands in the empty field.
    [node becomeFirstResponder];
    ApolloLog(@"[CrosspostTitle] cleared the title");
}

@end

static void ApolloCrosspostAttachClearButton(UIViewController *controller, ASEditableTextNode *node) {
    if (objc_getAssociatedObject(node, &kApolloCrosspostTitleClearButtonKey)) return;
    UIView *field = node.view;
    if (!field) return;

    ApolloCrosspostTitleClearButton *button = [ApolloCrosspostTitleClearButton buttonWithType:UIButtonTypeSystem];
    button.crosspostController = controller;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:16.0
                                                                                        weight:UIImageSymbolWeightRegular];
    [button setImage:[UIImage systemImageNamed:@"xmark.circle.fill" withConfiguration:config]
            forState:UIControlStateNormal];
    button.accessibilityLabel = @"Clear title";
    [button addTarget:button action:@selector(apollo_clearTitle) forControlEvents:UIControlEventTouchUpInside];
    __weak ApolloCrosspostTitleClearButton *weakButton = button;
    button.clearAction = [[UIAccessibilityCustomAction alloc] initWithName:@"Clear title"
                                                             actionHandler:^BOOL(__unused UIAccessibilityCustomAction *action) {
        ApolloCrosspostTitleClearButton *strongButton = weakButton;
        [strongButton apollo_clearTitle];
        return strongButton != nil;
    }];
    [field addSubview:button];
    objc_setAssociatedObject(node, &kApolloCrosspostTitleClearButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloCrosspostLayoutClearButton(node, button);

    // Keep the title from running underneath the button.
    UIEdgeInsets insets = node.textContainerInset;
    CGFloat trailing = kApolloCrosspostClearButtonWidth + kApolloCrosspostClearButtonTextGap;
    if (insets.right < trailing) {
        insets.right = trailing;
        node.textContainerInset = insets;
    }
    ApolloCrosspostRefreshClearButton(node);
}

static void ApolloCrosspostSetUpTitle(UIViewController *controller) {
    ASEditableTextNode *node = ApolloCrosspostTitleNode(controller);
    if (!node) {
        ApolloLog(@"[CrosspostTitle] no textEntryNode on %@, leaving the card alone", NSStringFromClass([controller class]));
        return;
    }
    ApolloCrosspostAttachClearButton(controller, node);
    if (node.maximumLinesToDisplay < kApolloCrosspostTitleMaxLines) node.maximumLinesToDisplay = kApolloCrosspostTitleMaxLines;

    // The card is a scroll view that the presentation controller caps at 80%
    // of the screen. While it slides in, UIKit's automatic safe-area insets
    // change and shift its content offset; once the content is taller than
    // the card (easy with a multi-line title above an image preview) it
    // opened scrolled to the bottom, with the header, the close button and
    // this title field out of view. The card always settles inside the safe
    // area, so it has no use for automatic insets.
    UIScrollView *card = (UIScrollView *)controller.view;
    if ([card isKindOfClass:[UIScrollView class]]) {
        card.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }

    // viewDidLoad runs once per card, so the field is empty here; the check
    // just makes sure nothing typed is ever replaced.
    if (node.attributedText.length > 0) return;
    RDKLink *link = ApolloReadObjectIvar(controller, "crosspostParent");
    NSString *title = [link respondsToSelector:@selector(title)] ? link.title : nil;
    if (![title isKindOfClass:[NSString class]] || title.length == 0) {
        ApolloLog(@"[CrosspostTitle] original post has no title, leaving the field empty");
        return;
    }
    // Apollo's theming has set the field's typing attributes (font, colour) by
    // now; without them the text would draw unstyled, so leave it empty.
    NSDictionary *attributes = node.typingAttributes;
    if (attributes.count == 0) {
        ApolloLog(@"[CrosspostTitle] title field has no typing attributes yet, leaving it empty");
        return;
    }

    node.attributedText = [[NSAttributedString alloc] initWithString:title attributes:attributes];
    objc_setAssociatedObject(controller, &kApolloCrosspostTitlePrefilledKey, title, OBJC_ASSOCIATION_COPY_NONATOMIC);
    // Same reason as the clear button: let Apollo re-run its Submit check and
    // show the clear button, as if the title had been typed.
    [(_TtC6Apollo30CrosspostPerformViewController *)controller editableTextNodeDidUpdateText:node];
    ApolloLog(@"[CrosspostTitle] prefilled the title from the original post (%lu characters)",
              (unsigned long)title.length);
}

%hook _TtC6Apollo30CrosspostPerformViewController

- (void)viewDidLoad {
    %orig;
    ApolloCrosspostSetUpTitle((UIViewController *)self);
}

// ASEditableTextNode calls this on the main queue after every edit (and we
// call it after our own programmatic changes).
- (void)editableTextNodeDidUpdateText:(id)editableTextNode {
    %orig;
    ASEditableTextNode *node = ApolloCrosspostTitleNode(self);
    if (!node) return;
    ApolloCrosspostRefreshClearButton(node);
    ApolloCrosspostRelayoutIfTitleHeightChanged((UIViewController *)self, node);
}

- (void)closeButtonNodeTappedWithSender:(id)sender {
    sApolloCrosspostMaskedTitleNode = (__bridge void *)ApolloCrosspostUntouchedTitleNode(self);
    @try {
        %orig;
    } @finally {
        sApolloCrosspostMaskedTitleNode = NULL;
    }
}

%end

%hook _TtC6Apollo38CrosspostPerformPresentationController

- (void)tappedDarkOverlayViewWithTapGestureRecognizer:(id)recognizer {
    UIViewController *presented = ((UIPresentationController *)self).presentedViewController;
    sApolloCrosspostMaskedTitleNode = (__bridge void *)ApolloCrosspostUntouchedTitleNode(presented);
    @try {
        %orig;
    } @finally {
        sApolloCrosspostMaskedTitleNode = NULL;
    }
}

%end

%hook ASEditableTextNode

- (NSAttributedString *)attributedText {
    if ((__bridge void *)self != sApolloCrosspostMaskedTitleNode) return %orig;
    return nil;   // ASEditableTextNode's own "nothing typed" value
}

// Texture measures the field's text at the node's full width and only then
// adds textContainerInset, but UITextView lays the text out inside the insets.
// With one line (stock) that never mattered; with several, a title that wraps
// only inside the insets was measured a line short and clipped. Measure the
// crosspost title at the width it is drawn at; the width reported stays
// stock.
- (CGSize)calculateSizeThatFits:(CGSize)constrainedSize {
    if (!objc_getAssociatedObject(self, &kApolloCrosspostTitleClearButtonKey)) return %orig;
    CGSize size = %orig;
    UIEdgeInsets insets = self.textContainerInset;
    CGFloat horizontal = insets.left + insets.right;
    if (constrainedSize.width <= horizontal) return size;
    CGSize textSize = %orig(CGSizeMake(constrainedSize.width - horizontal, constrainedSize.height));
    size.height = textSize.height;
    return size;
}

- (void)layout {
    %orig;
    UIButton *button = objc_getAssociatedObject(self, &kApolloCrosspostTitleClearButtonKey);
    if (!button) return;
    ApolloCrosspostLayoutClearButton(self, button);
}

%end

%ctor {
    %init;
    BOOL found = objc_getClass("_TtC6Apollo30CrosspostPerformViewController")
        && objc_getClass("_TtC6Apollo38CrosspostPerformPresentationController")
        && objc_getClass("ASEditableTextNode");
    ApolloLog(@"[CrosspostTitle] hook installed (crosspost title starts as the original post's title)%@",
              found ? @"" : @", but a crosspost class is MISSING");
}
