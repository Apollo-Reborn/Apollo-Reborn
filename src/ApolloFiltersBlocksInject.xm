// ApolloFiltersBlocksInject
//
// Extends Apollo's native Filters & Blocks screen
// (_TtC6Apollo29SettingsFiltersViewController) with Reborn filtering controls.
//
// The native Keywords, Subreddits and Users sections are retained, with
// collapsible Show/Hide rows when populated. Three Reborn sections are appended:
//
//   • SUBREDDIT-SPECIFIC FILTERS — configured subreddits; tap one to manage
//     keyword and post-flair filters, plus an "Add Subreddit Filter" row.
//   • FILTER SUBREDDITS BY NAME — words or phrases matched against subreddit
//     names, plus an "Add Filter Phrase" row.
//   • TAGGED POSTS — global Cover Tagged Posts / NSFW / Spoiler controls plus
//     a "Customize by Subreddit" disclosure.
//
// Reborn cells use Apollo's effective theme colours and Settings typography;
// custom section headers and footers are self-sizing. Tagged-post enforcement
// lives in ApolloTagFilters.xm; post-filter storage lives in ApolloPostFilterStore.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "settings/ApolloSettingsTableViewController.h"
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloPostFilterStore.h"
#import "ApolloState.h"
#import "ApolloSubredditFilterDetailViewController.h"
#import "ApolloTagFilters.h"
#import "ApolloThemeRuntime.h"
#import "TagFiltersViewController.h"
#import "UserDefaultConstants.h"

// Native Filters & Blocks screen (Apollo.SettingsFiltersViewController). Declared
// for the compiler so our self-calls (the dataSource method + the %new helpers
// below) type-check; the real class is hooked/resolved at runtime.
@interface _TtC6Apollo29SettingsFiltersViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
- (NSInteger)apollo_pfNativeSectionCount:(UITableView *)tableView;
- (void)apollo_pfOpenDetailForSubreddit:(NSString *)sub fromTable:(UITableView *)tableView;
- (void)apollo_pfPromptAddSubredditFromTable:(UITableView *)tableView;
- (void)apollo_pfPromptAddNameFromTable:(UITableView *)tableView;
- (UITableViewCell *)apollo_pfSpecificSubredditsToggleCellForTable:(UITableView *)tableView showingExpanded:(BOOL)showingExpanded;
- (void)apollo_pfUpdateSpecificSubredditsToggleAccessory:(UITableView *)tableView expanded:(BOOL)expanded;
- (void)apollo_pfSetSpecificSubredditsExpanded:(BOOL)expanded table:(UITableView *)tableView;
- (UITableViewCell *)apollo_pfKeywordsToggleCellForTable:(UITableView *)tableView showingExpanded:(BOOL)showingExpanded;
- (void)apollo_pfUpdateKeywordsToggleAccessory:(UITableView *)tableView expanded:(BOOL)expanded;
- (void)apollo_pfSetKeywordsExpanded:(BOOL)expanded table:(UITableView *)tableView;
- (UITableViewCell *)apollo_pfSubredditsToggleCellForTable:(UITableView *)tableView showingExpanded:(BOOL)showingExpanded;
- (void)apollo_pfUpdateSubredditsToggleAccessory:(UITableView *)tableView expanded:(BOOL)expanded;
- (void)apollo_pfSetSubredditsExpanded:(BOOL)expanded table:(UITableView *)tableView;
- (UITableViewCell *)apollo_pfNameFiltersToggleCellForTable:(UITableView *)tableView showingExpanded:(BOOL)showingExpanded;
- (void)apollo_pfUpdateNameFiltersToggleAccessory:(UITableView *)tableView expanded:(BOOL)expanded;
- (void)apollo_pfSetNameFiltersExpanded:(BOOL)expanded table:(UITableView *)tableView;
- (UITableViewCell *)apollo_pfBlockedToggleCellForTable:(UITableView *)tableView showingExpanded:(BOOL)showingExpanded;
- (void)apollo_pfUpdateBlockedToggleAccessory:(UITableView *)tableView expanded:(BOOL)expanded;
- (void)apollo_pfSetBlockedExpanded:(BOOL)expanded table:(UITableView *)tableView;
- (UITableViewCell *)apollo_tfCellForTable:(UITableView *)tableView row:(NSInteger)row;
- (void)apollo_tfEnableChanged:(UISwitch *)sw;
- (void)apollo_tfNSFWChanged:(UISwitch *)sw;
- (void)apollo_tfSpoilerChanged:(UISwitch *)sw;
- (void)apollo_tfOpenOverrides;
@end

// Number of Reborn sections appended after the native ones.
static const NSInteger kApolloPFExtraSections = 3;

// Logical rows of the appended Tagged Posts section. NSFW/Spoiler are
// progressively disclosed only while Cover Tagged Posts is enabled.
enum {
    ApolloTFRowEnable = 0,
    ApolloTFRowNSFW,
    ApolloTFRowSpoiler,
    ApolloTFRowOverrides,
    ApolloTFRowCount,
};

// Collapsible native Keywords and Blocked Users sections. Each gets a persistent
// row 0 ("Show …" / "Hide …") with a live count; Apollo's native rows follow while
// expanded. Both start collapsed whenever the screen is opened.
static const void *kApolloPFKeywordsExpandedKey    = &kApolloPFKeywordsExpandedKey;
static const void *kApolloPFKeywordsNativeCountKey = &kApolloPFKeywordsNativeCountKey;
static const void *kApolloPFSubredditsExpandedKey    = &kApolloPFSubredditsExpandedKey;
static const void *kApolloPFSubredditsNativeCountKey = &kApolloPFSubredditsNativeCountKey;
static const void *kApolloPFSpecificSubredditsExpandedKey = &kApolloPFSpecificSubredditsExpandedKey;
static const void *kApolloPFNameFiltersExpandedKey   = &kApolloPFNameFiltersExpandedKey;
static const void *kApolloPFBlockedExpandedKey     = &kApolloPFBlockedExpandedKey;
static const void *kApolloPFBlockedNativeCountKey  = &kApolloPFBlockedNativeCountKey;
static const void *kApolloPFTableBoxKey            = &kApolloPFTableBoxKey;

// Zeroing-weak box for the controller's table view. The VC is not a
// UITableViewController and exposes no -tableView, so the only way to reach the
// table outside a data-source callback is to remember the one UIKit hands us.
// Weak (not ASSIGN) so a torn-down table can never be messaged.
@interface ApolloPFTableBox : NSObject
@property (nonatomic, weak) UITableView *table;
@end
@implementation ApolloPFTableBox
@end

static void ApolloPFRememberTable(id vc, UITableView *tableView) {
    if (![tableView isKindOfClass:[UITableView class]]) return;
    ApolloPFTableBox *box = objc_getAssociatedObject(vc, kApolloPFTableBoxKey);
    if (!box) {
        box = [ApolloPFTableBox new];
        objc_setAssociatedObject(vc, kApolloPFTableBoxKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    box.table = tableView;
}

static UITableView *ApolloPFTableView(id vc) {
    return ((ApolloPFTableBox *)objc_getAssociatedObject(vc, kApolloPFTableBoxKey)).table;
}

// Our "Blocked Users (N)" toggle is row 0 of the blocked section and Apollo's own
// rows follow at display index 1..nativeCount (so it all reads as ONE rounded group).
//
// Apollo detects its "Add User" row as `row == [tableView numberOfRowsInSection:] - 1`
// — using the TABLE's displayed (inflated, +1) count — and otherwise indexes its
// blockedUsers array by `row`. So we map each DISPLAY row to the index we feed Apollo:
// the Add row (display == nativeCount, the last) keeps its index so it stays "last"
// and Apollo's Add detection fires; every user row shifts back by 1 to line up with
// blockedUsers[]. nativeCount is Apollo's own row count (users + Add), cached below.
static inline NSInteger ApolloPFBlockedApolloRow(NSInteger displayRow, NSInteger nativeCount) {
    return (displayRow >= nativeCount) ? displayRow : (displayRow - 1);
}

static void ApolloPFApplyCellTypography(UITableViewCell *cell) {
    if (!cell) return;

    // These are ordinary Settings rows. Apply Apollo's Appearance text-size
    // setting explicitly rather than relying on the shared helper's 17 pt
    // detection heuristic.
    cell.textLabel.font =
        ApolloSettingsFont(UIFontTextStyleBody, cell.traitCollection);
    cell.textLabel.adjustsFontForContentSizeCategory = YES;

    // Preserve the normal shared handling for detail labels and descendants.
    ApolloSettingsApplyCellTypography(cell);
}


static UIView *ApolloPFNativeDisclosureAccessoryView(UITableViewCell *cell) {
    // UIKit does not expose its disclosure-indicator view publicly. Locate the
    // small trailing accessory structurally rather than naming its private class.
    UIView *candidate = nil;

    for (UIView *view in cell.subviews) {
        if (view == cell.contentView ||
            view == cell.backgroundView ||
            view == cell.selectedBackgroundView) {
            continue;
        }

        CGRect frame = view.frame;
        if (CGRectGetMidX(frame) > CGRectGetMidX(cell.bounds) &&
            CGRectGetWidth(frame) <= 30.0 &&
            CGRectGetHeight(frame) <= 30.0) {
            if (!candidate ||
                CGRectGetMaxX(frame) > CGRectGetMaxX(candidate.frame)) {
                candidate = view;
            }
        }
    }

    return candidate;
}

static void ApolloPFSetToggleChevron(UITableViewCell *cell,
                                     BOOL expanded,
                                     BOOL enabled) {
    // At count zero, remove the accessory so the count aligns to the
    // trailing edge. Otherwise, retain the native disclosure indicator.
    cell.accessoryView = nil;
    cell.accessoryType = enabled
        ? UITableViewCellAccessoryDisclosureIndicator
        : UITableViewCellAccessoryNone;

    if (!enabled) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        [cell setNeedsLayout];
        [cell layoutIfNeeded];

        UIView *accessory = ApolloPFNativeDisclosureAccessoryView(cell);
        if (!accessory) return;

        accessory.alpha = 1.0;
        accessory.transform = expanded
            ? CGAffineTransformMakeRotation((CGFloat)M_PI_2)
            : CGAffineTransformIdentity;
    });
}

static UITableViewCell *ApolloPFToggleCell(UITableView *tableView,
                                           NSString *reuseIdentifier,
                                           NSString *noun,
                                           NSInteger count,
                                           BOOL expanded) {
    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:reuseIdentifier];

    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                      reuseIdentifier:reuseIdentifier];
    }

    // Match Apollo's effective cell surface and press feedback across stock,
    // Pure Black, and Reborn custom themes.
    cell.backgroundConfiguration = nil;
    cell.backgroundColor =
        ApolloThemeCardBackgroundColor() ?: UIColor.secondarySystemGroupedBackgroundColor;
    cell.contentView.backgroundColor = UIColor.clearColor;

    UIView *selectedBackground = [[UIView alloc] init];
    selectedBackground.backgroundColor =
        ApolloThemeRowHighlightColor() ?: UIColor.systemFillColor;
    cell.selectedBackgroundView = selectedBackground;

    cell.textLabel.text =
        noun;
    cell.textLabel.textColor = UIColor.labelColor;

    cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld", (long)count];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;

    BOOL enabled = count > 0;
    cell.selectionStyle =
        enabled ? UITableViewCellSelectionStyleDefault
                : UITableViewCellSelectionStyleNone;

    ApolloPFSetToggleChevron(cell, expanded, enabled);
    ApolloPFApplyCellTypography(cell);

    // The toggle row doubles as the section heading.
    UIFont *toggleFont = cell.textLabel.font;
    cell.textLabel.font =
        [UIFont systemFontOfSize:toggleFont.pointSize
                         weight:UIFontWeightSemibold];

    return cell;
}

#pragma mark - Section header / footer views (self-sizing)

static UIView *ApolloPFSectionHeaderView(NSString *title, CGFloat topPadding) {
    UIView *container = [[UIView alloc] init];

    // Collapsible sections already display their headings in the first row.
    // Preserve the section spacing without creating an empty text label.
    if (title.length == 0) {
        [container.heightAnchor constraintEqualToConstant:topPadding + 6.0].active = YES;
        return container;
    }

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = title.uppercaseString;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    ApolloSettingsApplySectionHeaderTypography(label);
    label.textColor = [UIColor secondaryLabelColor];
    label.numberOfLines = 0;
    [container addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20.0],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-20.0],
        [label.topAnchor constraintEqualToAnchor:container.topAnchor constant:topPadding],
        [label.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-6.0],
    ]];
    return container;
}

static UIView *ApolloPFSectionFooterView(NSString *text) {
    UIView *container = [[UIView alloc] init];
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.font = ApolloSettingsFont(UIFontTextStyleFootnote, label.traitCollection);
    label.adjustsFontForContentSizeCategory = NO;
    label.textColor = [UIColor secondaryLabelColor];
    label.numberOfLines = 0;
    [container addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20.0],
        [label.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-20.0],
        [label.topAnchor constraintEqualToAnchor:container.topAnchor constant:6.0],
        [label.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-6.0],
    ]];
    return container;
}


// Measure the native Blocked Users footer before its UILabel receives a frame.
// Apollo positions the label manually, with 16pt horizontal and 6pt top insets.
static CGFloat ApolloPFNativeFooterOverflow(UITableView *tableView) {
    for (UIView *view in tableView.subviews) {
        if (![NSStringFromClass(view.class)
                containsString:@"ApolloHeaderFooterView"]) {
            continue;
        }

        CGFloat footerWidth = CGRectGetWidth(view.bounds);
        CGFloat footerHeight = CGRectGetHeight(view.bounds);
        if (footerWidth <= 32.0 || footerHeight <= 0.0) continue;

        NSMutableArray<UIView *> *pending =
            [NSMutableArray arrayWithObject:view];

        while (pending.count) {
            UIView *child = pending.lastObject;
            [pending removeLastObject];

            if ([child isKindOfClass:[UILabel class]]) {
                UILabel *label = (UILabel *)child;

                if ([label.text containsString:
                        @"Exclude posts and communication"] &&
                    label.font) {
                    CGFloat textWidth = footerWidth - 32.0;

                    CGRect bounds = [label.text boundingRectWithSize:
                        CGSizeMake(textWidth, CGFLOAT_MAX)
                        options:NSStringDrawingUsesLineFragmentOrigin |
                                NSStringDrawingUsesFontLeading
                        attributes:@{NSFontAttributeName: label.font}
                        context:nil];

                    CGFloat scale = UIScreen.mainScreen.scale;
                    CGFloat textHeight =
                        ceil(CGRectGetHeight(bounds) * scale) / scale;

                    CGFloat overflow =
                        MAX(0.0, 6.0 + textHeight - footerHeight);

                    return overflow;
                }
            }

            [pending addObjectsFromArray:child.subviews];
        }
    }

    return 0.0;
}

// Shared footer text for the three custom sections.
static NSString *ApolloPFCustomFooterText(NSInteger index) {
    switch (index) {
        case 0:
            return @"Exclude posts in these subreddits when their title, link, or post flair matches a filter. Applies on this device.";
        case 1:
            return @"Exclude subreddits containing these words or phrases in their name (e.g. 'circlejerk' hides r/carscirclejerk). Applies to feeds and search on this device.";
        default:
            return @"Cover the title and thumbnail of NSFW or spoiler posts. Tap to reveal.";
    }
}

#pragma mark - Hook




%hook _TtC6Apollo29SettingsFiltersViewController

// This helper is added by the tweak, not implemented by Apollo.
%new
- (NSInteger)apollo_pfNativeSectionCount:(UITableView *)tableView {
    return [self numberOfSectionsInTableView:tableView] - kApolloPFExtraSections;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    // Capture the table here (the first data-source callback, and one that fires on
    // every reload) so the switch handler and setEditing: below have something to
    // reload. SettingsFiltersViewController is a plain UIViewController that owns a
    // table — it has NO -tableView accessor, so asking for one raises
    // NSInvalidArgumentException (#870 "Enable Tag Filters" toggle, #876 Block list
    // Edit; both regressions from #728, which dropped this capture).
    ApolloPFRememberTable(self, tableView);

    // Keep disclosure rows interactive in Edit mode. Entering Edit does not
    // change expansion state; users can expand/collapse sections as needed.
    tableView.allowsSelectionDuringEditing = YES;

    NSInteger nativeCount = %orig;
    return nativeCount + kApolloPFExtraSections;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (section < native) {
        if (section == 0) {
            NSInteger previous =
                [objc_getAssociatedObject(self, kApolloPFKeywordsNativeCountKey) integerValue];
            NSInteger n = %orig; // Apollo's own keyword rows + Add Keyword

            // Apollo has just added the first keyword: reveal it immediately.
            // Subsequent additions preserve the user's current expansion state.
            if (previous == 1 && n > 1) {
                objc_setAssociatedObject(
                    self,
                    kApolloPFKeywordsExpandedKey,
                    @YES,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC
                );
            }

            objc_setAssociatedObject(
                self,
                kApolloPFKeywordsNativeCountKey,
                @(n),
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );

            // With no keywords, the toggle and Add Keyword rows remain visible.
            if (n <= 1) return 2;

            // Otherwise: toggle + Add Keyword stay visible while collapsed.
            return [objc_getAssociatedObject(self, kApolloPFKeywordsExpandedKey) boolValue]
                ? (n + 1)
                : 2;
        }
        if (section == 1) {
            NSInteger previous =
                [objc_getAssociatedObject(self, kApolloPFSubredditsNativeCountKey) integerValue];
            NSInteger n = %orig; // subreddit entries + Add Subreddit

            // Apollo has just added the first subreddit: reveal it immediately.
            // Subsequent additions preserve the user's current expansion state.
            if (previous == 1 && n > 1) {
                objc_setAssociatedObject(
                    self,
                    kApolloPFSubredditsExpandedKey,
                    @YES,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC
                );
            }

            objc_setAssociatedObject(
                self,
                kApolloPFSubredditsNativeCountKey,
                @(n),
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );

            // With no filtered subreddits, the toggle and Add Subreddit rows remain visible.
            if (n <= 1) return 2;

            // Otherwise: toggle + Add Subreddit stay visible while collapsed.
            return [objc_getAssociatedObject(self, kApolloPFSubredditsExpandedKey) boolValue]
                ? (n + 1)
                : 2;
        }

        if (native > 0 && section == native - 1) {
            NSInteger previous =
                [objc_getAssociatedObject(self, kApolloPFBlockedNativeCountKey) integerValue];
            NSInteger n = %orig; // Apollo's own count (blocked users + "Add User")

            // Apollo has just added the first blocked user: reveal it immediately.
            // Subsequent additions preserve the user's current expansion state.
            if (previous == 1 && n > 1) {
                objc_setAssociatedObject(
                    self,
                    kApolloPFBlockedExpandedKey,
                    @YES,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC
                );
            }

            objc_setAssociatedObject(
                self,
                kApolloPFBlockedNativeCountKey,
                @(n),
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );

            // With no blocked users, the toggle and Add User rows remain visible.
            if (n <= 1) return 2;

            // Otherwise: toggle + Add User stay visible while collapsed.
            return [objc_getAssociatedObject(self, kApolloPFBlockedExpandedKey) boolValue]
                ? (n + 1)
                : 2;
        }
        return %orig;
    }
    if (section == native) {
        NSInteger count =
            (NSInteger)[ApolloPostFilterStore allSubreddits].count;
        BOOL expanded =
            [objc_getAssociatedObject(
                self,
                kApolloPFSpecificSubredditsExpandedKey
            ) boolValue];

        // With no subreddit-specific filters, the toggle and Add rows remain visible.
        if (count == 0) return 2;

        // Otherwise: toggle + Add Subreddit Filter stay visible while collapsed.
        return expanded ? (count + 2) : 2;
    }
    if (section == native + 1) {
        NSInteger count = (NSInteger)[ApolloPostFilterStore nameSubstrings].count;
        BOOL expanded =
            [objc_getAssociatedObject(self, kApolloPFNameFiltersExpandedKey) boolValue];

        // With no filter phrases, the toggle and Add Filter Phrase rows remain visible.
        if (count == 0) return 2;

        // Otherwise: toggle + Add Filter Phrase stay visible while collapsed.
        return expanded ? (count + 2) : 2;
    }
    // Tagged Posts: keep the master and Customize by Subreddit visible;
    // progressively disclose NSFW/Spoiler while the master is enabled.
    return sTagFilterEnabled ? ApolloTFRowCount : 2;
}


- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (indexPath.section < native) {
        if (indexPath.section == 0) {
            BOOL expanded = [objc_getAssociatedObject(self, kApolloPFKeywordsExpandedKey) boolValue];
            NSInteger nativeCount =
                [objc_getAssociatedObject(self, kApolloPFKeywordsNativeCountKey) integerValue];

            // No keywords: displayed row 0 is Apollo's native Add Keyword row.
            if (nativeCount <= 1) {
                if (indexPath.row == 0) {
                    return [self apollo_pfKeywordsToggleCellForTable:tableView
                                                    showingExpanded:NO];
                }
                return %orig(tableView,
                    [NSIndexPath indexPathForRow:0 inSection:indexPath.section]);
            }

            if (indexPath.row == 0) {
                return [self apollo_pfKeywordsToggleCellForTable:tableView showingExpanded:expanded];
            }
            NSInteger apolloRow = expanded
                ? (indexPath.row - 1)
                : MAX((NSInteger)0, nativeCount - 1); // Add Keyword

            UITableViewCell *cell =
                %orig(tableView,
                      [NSIndexPath indexPathForRow:apolloRow
                                       inSection:indexPath.section]);

            // Apollo's native value cells carry their own pressed-state styling.
            // Rebuild existing values as plain inert cells, matching our Filter
            // Phrase rows. Swipe-to-delete remains handled by the table delegate.
            if (apolloRow < nativeCount - 1) {
                NSString *text = cell.textLabel.text;
                UIColor *textColor = cell.textLabel.textColor;
                UIColor *backgroundColor =
                    cell.backgroundColor ?: cell.contentView.backgroundColor;

                cell = [[UITableViewCell alloc]
                    initWithStyle:UITableViewCellStyleDefault
                  reuseIdentifier:nil];

                if (backgroundColor &&
                    CGColorGetAlpha(backgroundColor.CGColor) > 0.01) {
                    cell.backgroundColor = backgroundColor;
                }

                cell.textLabel.text = text;
                cell.textLabel.textColor = textColor ?: [UIColor labelColor];
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                ApolloPFApplyCellTypography(cell);
            }

            return cell;
        }
        if (indexPath.section == 1) {
            BOOL expanded =
                [objc_getAssociatedObject(self, kApolloPFSubredditsExpandedKey) boolValue];

            NSInteger nativeCount =
                [objc_getAssociatedObject(self, kApolloPFSubredditsNativeCountKey) integerValue];

            // No filtered subreddits: displayed row 0 is Apollo's native Add Subreddit row.
            if (nativeCount <= 1) {
                if (indexPath.row == 0) {
                    return [self apollo_pfSubredditsToggleCellForTable:tableView
                                                    showingExpanded:NO];
                }
                return %orig(tableView,
                    [NSIndexPath indexPathForRow:0 inSection:indexPath.section]);
            }

            if (indexPath.row == 0) {
                return [self apollo_pfSubredditsToggleCellForTable:tableView
                                                  showingExpanded:expanded];
            }

            NSInteger apolloRow = expanded
                ? (indexPath.row - 1)
                : MAX((NSInteger)0, nativeCount - 1); // Add Subreddit

            UITableViewCell *cell =
                %orig(
                    tableView,
                    [NSIndexPath indexPathForRow:apolloRow
                                       inSection:indexPath.section]
                );

            // Apollo's native value cells carry their own pressed-state styling.
            // Rebuild existing values as plain inert cells, matching our Filter
            // Phrase rows. Swipe-to-delete remains handled by the table delegate.
            if (apolloRow < nativeCount - 1) {
                NSString *text = cell.textLabel.text;
                UIColor *textColor = cell.textLabel.textColor;
                UIColor *backgroundColor =
                    cell.backgroundColor ?: cell.contentView.backgroundColor;

                cell = [[UITableViewCell alloc]
                    initWithStyle:UITableViewCellStyleDefault
                  reuseIdentifier:nil];

                if (backgroundColor &&
                    CGColorGetAlpha(backgroundColor.CGColor) > 0.01) {
                    cell.backgroundColor = backgroundColor;
                }

                cell.textLabel.text = text;
                cell.textLabel.textColor = textColor ?: [UIColor labelColor];
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                ApolloPFApplyCellTypography(cell);
            }

            return cell;
        }

        if (native > 0 && indexPath.section == native - 1) {
            BOOL expanded = [objc_getAssociatedObject(self, kApolloPFBlockedExpandedKey) boolValue];
            NSInteger nativeCount =
                [objc_getAssociatedObject(self, kApolloPFBlockedNativeCountKey) integerValue];

            // No blocked users: displayed row 0 is Apollo's native Add User row.
            if (nativeCount <= 1) {
                if (indexPath.row == 0) {
                    return [self apollo_pfBlockedToggleCellForTable:tableView
                                                    showingExpanded:NO];
                }
                return %orig(tableView,
                    [NSIndexPath indexPathForRow:0 inSection:indexPath.section]);
            }

            if (indexPath.row == 0) {
                return [self apollo_pfBlockedToggleCellForTable:tableView
                                               showingExpanded:expanded];
            }
            NSInteger apolloRow = expanded
                ? (indexPath.row - 1)
                : MAX((NSInteger)0, nativeCount - 1); // Add User

            UITableViewCell *cell =
                %orig(tableView,
                      [NSIndexPath indexPathForRow:apolloRow
                                       inSection:indexPath.section]);

            // Apollo's native value cells carry their own pressed-state styling.
            // Rebuild existing values as plain inert cells, matching our Filter
            // Phrase rows. Swipe-to-delete remains handled by the table delegate.
            if (apolloRow < nativeCount - 1) {
                NSString *text = cell.textLabel.text;
                UIColor *textColor = cell.textLabel.textColor;
                UIColor *backgroundColor =
                    cell.backgroundColor ?: cell.contentView.backgroundColor;

                cell = [[UITableViewCell alloc]
                    initWithStyle:UITableViewCellStyleDefault
                  reuseIdentifier:nil];

                if (backgroundColor &&
                    CGColorGetAlpha(backgroundColor.CGColor) > 0.01) {
                    cell.backgroundColor = backgroundColor;
                }

                cell.textLabel.text = text;
                cell.textLabel.textColor = textColor ?: [UIColor labelColor];
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                ApolloPFApplyCellTypography(cell);
            }

            return cell;
        }
        return %orig;
    }

    if (indexPath.section == native) {
        BOOL expanded =
            [objc_getAssociatedObject(
                self,
                kApolloPFSpecificSubredditsExpandedKey
            ) boolValue];

        NSArray<NSString *> *subs =
            [ApolloPostFilterStore allSubreddits];

        if (indexPath.row == 0) {
            return [self apollo_pfSpecificSubredditsToggleCellForTable:tableView
                                                      showingExpanded:expanded];
        }

        // At zero, displayed row 0 is Add Subreddit Filter.
        // Otherwise translate around the persistent toggle at row 0.
        NSInteger sourceRow = subs.count == 0
            ? 0
            : (expanded ? (indexPath.row - 1) : (NSInteger)subs.count);

        indexPath =
            [NSIndexPath indexPathForRow:sourceRow
                               inSection:indexPath.section];
    }

    if (indexPath.section == native + 2) {
        NSInteger logicalRow =
            (!sTagFilterEnabled && indexPath.row == 1)
                ? ApolloTFRowOverrides
                : indexPath.row;
        return [self apollo_tfCellForTable:tableView row:logicalRow];
    }

    if (indexPath.section == native + 1) {
        BOOL expanded =
            [objc_getAssociatedObject(self, kApolloPFNameFiltersExpandedKey) boolValue];

        NSArray<NSString *> *names = [ApolloPostFilterStore nameSubstrings];

        if (indexPath.row == 0) {
            return [self apollo_pfNameFiltersToggleCellForTable:tableView
                                               showingExpanded:expanded];
        }

        // At zero, displayed row 0 maps directly to the Add Filter Phrase row.
        NSInteger sourceRow = names.count == 0
            ? 0
            : (expanded ? (indexPath.row - 1) : (NSInteger)names.count);

        // Reuse the existing injected-row machinery below by translating our
        // displayed row back to its original source index.
        indexPath =
            [NSIndexPath indexPathForRow:sourceRow inSection:indexPath.section];
    }

    BOOL isSubSection = (indexPath.section == native);
    NSArray<NSString *> *items = isSubSection ? [ApolloPostFilterStore allSubreddits]
                                              : [ApolloPostFilterStore nameSubstrings];
    BOOL isAddRow = ((NSUInteger)indexPath.row >= items.count);

    // Borrow a native cell (the "Add" row of section 0) so we inherit Apollo's
    // exact theme — background, fonts, and the accent text color used for Add rows.
    // Borrow Apollo's TRUE native Add Keyword row, not our synthetic visible
    // row count (which is only 2 while Filtered Keywords is collapsed).
    NSInteger nativeRows0 =
        [objc_getAssociatedObject(self, kApolloPFKeywordsNativeCountKey) integerValue];
    NSIndexPath *borrow =
        [NSIndexPath indexPathForRow:MAX((NSInteger)0, nativeRows0 - 1)
                           inSection:0];
    UITableViewCell *cell = %orig(tableView, borrow);
    cell.imageView.image = nil;
    cell.accessoryView = nil;
    if (isAddRow) {
        cell.textLabel.text = isSubSection ? @"Add Subreddit Filter" : @"Add Filter Phrase";
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        // Keep the borrowed accent text color (this IS a native Add cell).
    } else {
        NSString *item = items[indexPath.row];
        cell.textLabel.textColor = [UIColor labelColor]; // override accent → normal item text
        if (isSubSection) {
            // Existing subreddit rows need disclosure behavior, but don't reuse
            // Apollo's native Add cell itself: it carries custom highlight styling
            // that leaves a darker patch in the accessory area when pressed.
            UIColor *backgroundColor = cell.backgroundColor ?: cell.contentView.backgroundColor;

            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:nil];
            if (backgroundColor && CGColorGetAlpha(backgroundColor.CGColor) > 0.01) {
                cell.backgroundColor = backgroundColor;
            }

            cell.textLabel.text = [NSString stringWithFormat:@"r/%@", item];
            cell.textLabel.textColor = [UIColor labelColor];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        } else {
            cell.textLabel.text = item;
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
    }


    // Borrowed Add cells already carry Apollo's native typography. Apply our
    // Appearance typography only to cells whose content we construct ourselves.
    if (!isAddRow) {
        ApolloPFApplyCellTypography(cell);
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    %orig;
    ApolloSettingsApplySectionHeaderTypography(view);
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];

    if (section < native) {
        UIView *header = %orig;
        ApolloSettingsApplySectionHeaderTypography(header);

        // The collapsible sections use their first rows as headings.
        // Preserve native header geometry while hiding its contents.
        if (section < 3) {
            for (UIView *subview in header.subviews) {
                subview.hidden = YES;
            }
        }
        return header;
    }

    NSString *title;
    if (section == native) title = @"";
    else if (section == native + 1) title = @"";
    else title = @"Tagged Posts";

    // Match Apollo's native section spacing on every iOS version.
    // The custom header contributes 6 pt below its label.
    CGRect nativeHeader = [tableView rectForHeaderInSection:1];
    CGFloat nativeHeight = CGRectGetHeight(nativeHeader);
    CGFloat topPadding = nativeHeight > 0.0
        ? nativeHeight - 6.0
        : 30.0;
    if (section == native) {
        topPadding += ApolloPFNativeFooterOverflow(tableView);
    }

    return ApolloPFSectionHeaderView(title, topPadding);
}

%new
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (section < native) return UITableViewAutomaticDimension;

    NSString *text = ApolloPFCustomFooterText(section - native);
    UIView *footer = ApolloPFSectionFooterView(text);
    UILabel *label = (UILabel *)footer.subviews.firstObject;

    // Account for the inset-grouped footer and label padding (20pt per side each).
    CGFloat width = CGRectGetWidth(tableView.bounds) - 80.0;
    if (width <= 0.0) return UITableViewAutomaticDimension;

    CGSize required = [label sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
    return ceil(required.height) + 12.0;
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (section < native) {
        // Always the native footer — collapsed AND expanded — so it never appears/
        // disappears during the toggle (which made its text flash to the left edge for
        // a frame as it re-laid-out). It just slides down as the rows expand.
        return %orig;
    }
    NSString *text = ApolloPFCustomFooterText(section - native);
    return ApolloPFSectionFooterView(text);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (indexPath.section < native) {
        if (indexPath.section == 0) {
            NSInteger nativeCount =
                [objc_getAssociatedObject(self, kApolloPFKeywordsNativeCountKey) integerValue];

            // With no keywords, row 0 is Apollo's native Add Keyword row.
            if (nativeCount <= 1) {
                if (indexPath.row == 1) {
                    %orig(tableView, indexPath);
                }
                return;
            }

            if (indexPath.row == 0) {
                [tableView deselectRowAtIndexPath:indexPath animated:YES];

                BOOL expanded = [objc_getAssociatedObject(self, kApolloPFKeywordsExpandedKey) boolValue];
                [self apollo_pfSetKeywordsExpanded:!expanded table:tableView];
                return;
            }

            // Apollo identifies Add Keyword from the last displayed row.
            // Preserve that displayed index for Add; only actual keyword rows
            // need shifting back by one to account for our toggle at row 0.
            NSInteger displayedRows = [tableView numberOfRowsInSection:indexPath.section];
            BOOL isAddRow = (indexPath.row == displayedRows - 1);
            NSInteger apolloRow = isAddRow ? indexPath.row : (indexPath.row - 1);

            %orig(tableView, [NSIndexPath indexPathForRow:apolloRow
                                                   inSection:indexPath.section]);
            return;
        }

        if (indexPath.section == 1) {
            NSInteger nativeCount =
                [objc_getAssociatedObject(self, kApolloPFSubredditsNativeCountKey) integerValue];

            // With no filtered subreddits, row 0 is Apollo's native Add Subreddit row.
            if (nativeCount <= 1) {
                if (indexPath.row == 1) {
                    %orig(tableView, indexPath);
                }
                return;
            }

            if (indexPath.row == 0) {
                [tableView deselectRowAtIndexPath:indexPath animated:YES];

                BOOL expanded =
                    [objc_getAssociatedObject(self, kApolloPFSubredditsExpandedKey) boolValue];

                [self apollo_pfSetSubredditsExpanded:!expanded table:tableView];
                return;
            }

            NSInteger displayedRows =
                [tableView numberOfRowsInSection:indexPath.section];
            BOOL isAddRow = (indexPath.row == displayedRows - 1);

            NSInteger apolloRow =
                isAddRow ? indexPath.row : (indexPath.row - 1);

            %orig(
                tableView,
                [NSIndexPath indexPathForRow:apolloRow inSection:indexPath.section]
            );
            return;
        }

        if (native > 0 && indexPath.section == native - 1) {
            NSInteger nativeCount =
                [objc_getAssociatedObject(self, kApolloPFBlockedNativeCountKey) integerValue];

            // With no blocked users, row 0 is Apollo's native Add User row.
            if (nativeCount <= 1) {
                if (indexPath.row == 1) {
                    %orig(tableView, indexPath);
                }
                return;
            }

            // Row 0 = our toggle: flip expanded/collapsed.
            if (indexPath.row == 0) {
                [tableView deselectRowAtIndexPath:indexPath animated:YES];

                BOOL expanded = [objc_getAssociatedObject(self, kApolloPFBlockedExpandedKey) boolValue];
                [self apollo_pfSetBlockedExpanded:!expanded table:tableView];
                return;
            }
            // Apollo identifies Add User from the last displayed row.
            // Preserve that displayed index for Add; only actual user rows need
            // mapping back around our persistent toggle at row 0.
            NSInteger displayedRows =
                [tableView numberOfRowsInSection:indexPath.section];
            BOOL isAddRow = (indexPath.row == displayedRows - 1);

            NSInteger apolloRow = isAddRow
                ? indexPath.row
                : ApolloPFBlockedApolloRow(indexPath.row, nativeCount);

            %orig(tableView,
                  [NSIndexPath indexPathForRow:apolloRow
                                     inSection:indexPath.section]);
            return;
        }
        %orig;
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == native) {
        NSArray<NSString *> *subs =
            [ApolloPostFilterStore allSubreddits];

        // With no filters, row 0 is Add Subreddit Filter.
        if (subs.count == 0) {
            if (indexPath.row == 1) {
                [self apollo_pfPromptAddSubredditFromTable:tableView];
            }
            return;
        }

        if (indexPath.row == 0) {
            BOOL expanded =
                [objc_getAssociatedObject(
                    self,
                    kApolloPFSpecificSubredditsExpandedKey
                ) boolValue];

            [self apollo_pfSetSpecificSubredditsExpanded:!expanded
                                                   table:tableView];
            return;
        }

        BOOL expanded =
            [objc_getAssociatedObject(
                self,
                kApolloPFSpecificSubredditsExpandedKey
            ) boolValue];

        NSInteger sourceRow =
            expanded ? (indexPath.row - 1) : (NSInteger)subs.count;

        if ((NSUInteger)sourceRow < subs.count) {
            [self apollo_pfOpenDetailForSubreddit:subs[sourceRow]
                                        fromTable:tableView];
        } else {
            [self apollo_pfPromptAddSubredditFromTable:tableView];
        }
    } else if (indexPath.section == native + 1) {
        NSArray<NSString *> *names = [ApolloPostFilterStore nameSubstrings];

        // With no filters, row 0 is Add Filter Phrase.
        if (names.count == 0) {
            if (indexPath.row == 1) {
                [self apollo_pfPromptAddNameFromTable:tableView];
            }
            return;
        }

        if (indexPath.row == 0) {
            BOOL expanded =
                [objc_getAssociatedObject(self, kApolloPFNameFiltersExpandedKey) boolValue];
            [self apollo_pfSetNameFiltersExpanded:!expanded table:tableView];
            return;
        }
        BOOL expanded =
            [objc_getAssociatedObject(self, kApolloPFNameFiltersExpandedKey) boolValue];

        NSInteger sourceRow = expanded ? (indexPath.row - 1) : (NSInteger)names.count;

        if ((NSUInteger)sourceRow >= names.count) {
            [self apollo_pfPromptAddNameFromTable:tableView];
        }
        // Existing name-filter rows: no detail; remove via swipe / Edit.
    } else if (indexPath.section == native + 2) {
        NSInteger logicalRow =
            (!sTagFilterEnabled && indexPath.row == 1)
                ? ApolloTFRowOverrides
                : indexPath.row;
        if (logicalRow == ApolloTFRowOverrides) [self apollo_tfOpenOverrides];
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];

    if (indexPath.section < native) {
        // Filtered Keywords
        if (indexPath.section == 0) {
            NSInteger nativeCount =
                [objc_getAssociatedObject(self, kApolloPFKeywordsNativeCountKey) integerValue];

            // No keywords: the only visible row is Add Keyword.
            if (nativeCount <= 1) return NO;

            // Toggle is never editable.
            if (indexPath.row == 0) return NO;

            NSInteger displayedRows =
                [tableView numberOfRowsInSection:indexPath.section];

            // Add Keyword is never editable.
            if (indexPath.row == displayedRows - 1) return NO;

            // Remaining displayed rows are real keyword rows.
            return YES;
        }

        // Filtered Subreddits
        if (indexPath.section == 1) {
            NSInteger nativeCount =
                [objc_getAssociatedObject(self, kApolloPFSubredditsNativeCountKey) integerValue];

            // No entries: the only visible row is Add Subreddit.
            if (nativeCount <= 1) return NO;

            // Toggle is never editable.
            if (indexPath.row == 0) return NO;

            NSInteger displayedRows =
                [tableView numberOfRowsInSection:indexPath.section];

            // Add Subreddit is never editable.
            if (indexPath.row == displayedRows - 1) return NO;

            // Remaining displayed rows are real subreddit entries.
            return YES;
        }

        // Blocked Users
        if (native > 0 && indexPath.section == native - 1) {
            NSInteger nativeCount =
                [objc_getAssociatedObject(self, kApolloPFBlockedNativeCountKey) integerValue];

            // No users: the only visible row is Add User.
            if (nativeCount <= 1) return NO;

            // Toggle is never editable.
            if (indexPath.row == 0) return NO;

            NSInteger displayedRows =
                [tableView numberOfRowsInSection:indexPath.section];

            // Add User is never editable.
            if (indexPath.row == displayedRows - 1) return NO;

            // Remaining displayed rows are real blocked users.
            return YES;
        }

        return %orig;
    }

    // Subreddit-Specific Filters.
    if (indexPath.section == native) {
        NSArray<NSString *> *items =
            [ApolloPostFilterStore allSubreddits];

        // At zero, the sole row is Add Subreddit Filter.
        if (items.count == 0) return NO;

        // Row 0 is our Show/Hide toggle.
        if (indexPath.row == 0) return NO;

        BOOL expanded =
            [objc_getAssociatedObject(
                self,
                kApolloPFSpecificSubredditsExpandedKey
            ) boolValue];

        // While collapsed, row 1 is Add Subreddit Filter.
        if (!expanded) return NO;

        // Expanded:
        //   row 0             = toggle
        //   rows 1...count    = actual subreddit filters
        //   row count + 1     = Add Subreddit Filter
        return indexPath.row >= 1 &&
               (NSUInteger)indexPath.row <= items.count;
    }

    // Filter Subreddits By Name.
    if (indexPath.section == native + 1) {
        NSArray<NSString *> *items = [ApolloPostFilterStore nameSubstrings];

        // At zero, the sole row is Add Filter Phrase.
        if (items.count == 0) return NO;

        // Row 0 is our Show/Hide toggle.
        if (indexPath.row == 0) return NO;

        BOOL expanded =
            [objc_getAssociatedObject(self, kApolloPFNameFiltersExpandedKey) boolValue];

        // While collapsed, row 1 is Add Filter Phrase.
        if (!expanded) return NO;

        // Expanded:
        //   row 0             = toggle
        //   rows 1...count    = actual filters
        //   row count + 1     = Add Filter Phrase
        return indexPath.row >= 1 &&
               (NSUInteger)indexPath.row <= items.count;
    }

    // Tagged Posts rows are static.
    return NO;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (indexPath.section < native) {
        if (indexPath.section == 0) {
            if (indexPath.row == 0) return NO;

            BOOL expanded =
                [objc_getAssociatedObject(self, kApolloPFKeywordsExpandedKey) boolValue];
            NSInteger nativeCount =
                [objc_getAssociatedObject(self, kApolloPFKeywordsNativeCountKey) integerValue];
            NSInteger apolloRow = expanded
                ? (indexPath.row - 1)
                : MAX((NSInteger)0, nativeCount - 1);

            return %orig(tableView, [NSIndexPath indexPathForRow:apolloRow
                                                       inSection:indexPath.section]);
        }
        if (indexPath.section == 1) {
            if (indexPath.row == 0) return NO;

            BOOL expanded =
                [objc_getAssociatedObject(self, kApolloPFSubredditsExpandedKey) boolValue];
            NSInteger nativeCount =
                [objc_getAssociatedObject(self, kApolloPFSubredditsNativeCountKey) integerValue];

            NSInteger apolloRow = expanded
                ? (indexPath.row - 1)
                : MAX((NSInteger)0, nativeCount - 1);

            return %orig(
                tableView,
                [NSIndexPath indexPathForRow:apolloRow inSection:indexPath.section]
            );
        }

        if (native > 0 && indexPath.section == native - 1) {
            if (indexPath.row == 0) return NO; // our toggle row
            NSInteger nativeCount = [objc_getAssociatedObject(self, kApolloPFBlockedNativeCountKey) integerValue];
            if (indexPath.row >= nativeCount) return NO; // Apollo's "Add User" row (last)
            return %orig(tableView, [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section]);
        }
        return %orig;
    }
    return NO;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (indexPath.section < native) {
        if (indexPath.section == 0 && indexPath.row >= 1) {
            %orig(tableView, editingStyle,
                  [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section]);
            return;
        }
        if (indexPath.section == 1 && indexPath.row >= 1) {
            BOOL expanded =
                [objc_getAssociatedObject(self, kApolloPFSubredditsExpandedKey) boolValue];

            // Only actual subreddit entries are editable; Add Subreddit remains native.
            if (expanded) {
                %orig(
                    tableView,
                    editingStyle,
                    [NSIndexPath indexPathForRow:indexPath.row - 1
                                      inSection:indexPath.section]
                );
            }
            return;
        }

        if (native > 0 && indexPath.section == native - 1 && indexPath.row >= 1) {
            // Only a user row reaches here (the Add row is non-editable); it maps to
            // Apollo's blockedUsers[] index = display row - 1.
            %orig(tableView, editingStyle, [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section]);
            // Apollo updates its model during the delete. Reload our augmented
            // section afterwards so the count — and the 1 -> 0 removal of the
            // Show/Hide row — reflects the new native row count.
            __weak UITableView *wt = tableView;
            dispatch_async(dispatch_get_main_queue(), ^{
                [wt reloadSections:[NSIndexSet indexSetWithIndex:indexPath.section]
                  withRowAnimation:UITableViewRowAnimationAutomatic];
            });
            return;
        }
        %orig;
        return;
    }
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if (indexPath.section >= native + 2) return; // Tagged Posts rows are static

    BOOL isSubSection = (indexPath.section == native);
    NSArray<NSString *> *items = isSubSection ? [ApolloPostFilterStore allSubreddits]
                                              : [ApolloPostFilterStore nameSubstrings];

    // Both appended filter-list sections have a Show/Hide toggle at displayed
    // row 0, so actual model rows are offset by one while expanded.
    NSInteger sourceRow = indexPath.row - 1;

    if (sourceRow < 0 || (NSUInteger)sourceRow >= items.count) return;

    NSString *item = items[sourceRow];

    if (isSubSection) {
        [ApolloPostFilterStore removeSubreddit:item];
    } else {
        [ApolloPostFilterStore removeNameSubstring:item];
    }

    // These sections contain synthetic disclosure/Add rows, so deleting one
    // model item can change more than one displayed row (especially 1 -> 0,
    // when the disclosure row disappears). Reload the section rather than
    // claiming to UIKit that exactly one displayed row was removed.
    [tableView reloadSections:[NSIndexSet indexSetWithIndex:indexPath.section]
             withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (indexPath.section < native) {
        if (indexPath.section == 0 && indexPath.row >= 1) {
            return %orig(tableView,
                         [NSIndexPath indexPathForRow:indexPath.row - 1
                                            inSection:indexPath.section]);
        }
        if (native > 0 && indexPath.section == native - 1 && indexPath.row >= 1) {
            return %orig(tableView, [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section]);
        }
        return %orig;
    }
    return @"Delete";
}

#pragma mark - Added actions

%new
- (void)apollo_pfOpenDetailForSubreddit:(NSString *)sub fromTable:(UITableView *)tableView {
    ApolloSubredditFilterDetailViewController *detail = [[ApolloSubredditFilterDetailViewController alloc] initWithSubreddit:sub];
    __weak UITableView *weakTable = tableView;
    detail.onChange = ^{ [weakTable reloadData]; };
    UIViewController *selfVC = (UIViewController *)self;
    if (selfVC.navigationController) {
        [selfVC.navigationController pushViewController:detail animated:YES];
    } else {
        [selfVC presentViewController:[[UINavigationController alloc] initWithRootViewController:detail] animated:YES completion:nil];
    }
}

%new
- (void)apollo_pfPromptAddSubredditFromTable:(UITableView *)tableView {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add Subreddit Filter"
                                                                  message:@"Enter the name of the subreddit you want to add filters for."
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Subreddit name";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak UIAlertController *weakAlert = alert;
    __weak __typeof__(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIAlertAction *addAction =
        [UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *sub = [ApolloPostFilterStore normalizeSubreddit:weakAlert.textFields.firstObject.text];
        if (sub.length == 0) return;

        BOOL wasEmpty =
            ([ApolloPostFilterStore allSubreddits].count == 0);

        [ApolloPostFilterStore ensureSubreddit:sub];

        // Reveal the first subreddit filter the user creates. Once populated,
        // later additions preserve the user's chosen expansion state.
        if (wasEmpty && [ApolloPostFilterStore allSubreddits].count > 0) {
            objc_setAssociatedObject(
                self,
                kApolloPFSpecificSubredditsExpandedKey,
                @YES,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );
        }

        [tableView reloadData];
        [weakSelf apollo_pfOpenDetailForSubreddit:sub fromTable:tableView];
    }];

    addAction.enabled = NO;
    [alert addAction:addAction];
    alert.preferredAction = addAction;

    UITextField *field = alert.textFields.firstObject;
    [field addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        NSString *text = ((UITextField *)action.sender).text ?: @"";
        addAction.enabled =
            [text stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]].length > 0;
    }] forControlEvents:UIControlEventEditingChanged];

    [(UIViewController *)self presentViewController:alert animated:YES completion:nil];
}

%new
- (void)apollo_pfPromptAddNameFromTable:(UITableView *)tableView {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add Filter Phrase"
                                                                  message:@"Enter a word or phrase to filter subreddit names."
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Word or phrase";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIAlertAction *addAction =
        [UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *term = [ApolloPostFilterStore normalizeTerm:weakAlert.textFields.firstObject.text];
        if (term.length == 0) return;

        BOOL wasEmpty = ([ApolloPostFilterStore nameSubstrings].count == 0);
        [ApolloPostFilterStore addNameSubstring:term];

        // Reveal the first filter the user creates. Once populated, additions
        // preserve whatever expansion state the user has chosen.
        if (wasEmpty && [ApolloPostFilterStore nameSubstrings].count > 0) {
            objc_setAssociatedObject(
                self,
                kApolloPFNameFiltersExpandedKey,
                @YES,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );
        }

        [tableView reloadData];
    }];

    addAction.enabled = NO;
    [alert addAction:addAction];
    alert.preferredAction = addAction;

    UITextField *field = alert.textFields.firstObject;
    [field addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        NSString *text = ((UITextField *)action.sender).text ?: @"";
        addAction.enabled =
            [text stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]].length > 0;
    }] forControlEvents:UIControlEventEditingChanged];

    [(UIViewController *)self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Tagged Posts section

// Switch/disclosure cells for the appended Tagged Posts section. Fresh cells per
// call (like TagFiltersViewController's own — this table reloads wholesale, no
// per-row reuse to go stale). Theming borrows the same probe row the Blocked
// Users toggle uses.
%new
- (UITableViewCell *)apollo_tfCellForTable:(UITableView *)tableView row:(NSInteger)row {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (row == ApolloTFRowOverrides) {
        cell.textLabel.text = @"Customize by Subreddit";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *sw = [[UISwitch alloc] init];
        switch (row) {
            case ApolloTFRowEnable:
                cell.textLabel.text = @"Cover Tagged Posts";
                sw.on = sTagFilterEnabled;
                [sw addTarget:self action:@selector(apollo_tfEnableChanged:) forControlEvents:UIControlEventValueChanged];
                break;
            case ApolloTFRowNSFW:
                cell.textLabel.text = @"NSFW";
                sw.on = sTagFilterNSFW;
                sw.enabled = sTagFilterEnabled;
                cell.textLabel.enabled = sTagFilterEnabled;
                [sw addTarget:self action:@selector(apollo_tfNSFWChanged:) forControlEvents:UIControlEventValueChanged];
                break;
            case ApolloTFRowSpoiler:
            default:
                cell.textLabel.text = @"Spoiler";
                sw.on = sTagFilterSpoiler;
                sw.enabled = sTagFilterEnabled;
                cell.textLabel.enabled = sTagFilterEnabled;
                [sw addTarget:self action:@selector(apollo_tfSpoilerChanged:) forControlEvents:UIControlEventValueChanged];
                break;
        }
        cell.accessoryView = sw;
    }


    @try {   // borrow the native theme (background); labels stay label-color
        UITableViewCell *probe = [self tableView:tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
        UIColor *c = probe.backgroundColor ?: probe.contentView.backgroundColor;
        if (c && CGColorGetAlpha(c.CGColor) > 0.01) cell.backgroundColor = c;
    } @catch (__unused id e) {}

    // Match Apollo's native Settings row typography.
    ApolloPFApplyCellTypography(cell);

    return cell;
}

%new
- (void)apollo_tfEnableChanged:(UISwitch *)sw {
    sTagFilterEnabled = sw.on;
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:UDKeyTagFilterEnabled];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloTagFiltersChangedNotification object:nil];
    // Progressive disclosure: NSFW/Spoiler exist only while the master is on.
    // Insert/delete just those rows so the section header, master row,
    // Customize row and footer remain in place.
    UITableView *t = ApolloPFTableView(self);
    if ([t isKindOfClass:[UITableView class]]) {
        NSInteger section = [self apollo_pfNativeSectionCount:t] + 2;
        NSArray<NSIndexPath *> *rows = @[
            [NSIndexPath indexPathForRow:ApolloTFRowNSFW inSection:section],
            [NSIndexPath indexPathForRow:ApolloTFRowSpoiler inSection:section],
        ];
        @try {
            if (sw.on) {
                [t insertRowsAtIndexPaths:rows
                         withRowAnimation:UITableViewRowAnimationFade];
            } else {
                [t deleteRowsAtIndexPaths:rows
                         withRowAnimation:UITableViewRowAnimationFade];
            }
        } @catch (__unused id e) {
            [t reloadData];
        }
    }
}

%new
- (void)apollo_tfNSFWChanged:(UISwitch *)sw {
    sTagFilterNSFW = sw.on;
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:UDKeyTagFilterNSFW];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloTagFiltersChangedNotification object:nil];
}

%new
- (void)apollo_tfSpoilerChanged:(UISwitch *)sw {
    sTagFilterSpoiler = sw.on;
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:UDKeyTagFilterSpoiler];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloTagFiltersChangedNotification object:nil];
}

%new
- (void)apollo_tfOpenOverrides {
    TagFiltersViewController *vc = [[TagFiltersViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    vc.overridesOnly = YES;
    UIViewController *selfVC = (UIViewController *)self;
    if (selfVC.navigationController) {
        [selfVC.navigationController pushViewController:vc animated:YES];
    } else {
        [selfVC presentViewController:[[UINavigationController alloc] initWithRootViewController:vc] animated:YES completion:nil];
    }
}


#pragma mark - Collapsible Subreddit-Specific Filters toggle

%new
- (UITableViewCell *)apollo_pfSpecificSubredditsToggleCellForTable:(UITableView *)tableView
                                                  showingExpanded:(BOOL)showingExpanded {
    NSInteger count =
        (NSInteger)[ApolloPostFilterStore allSubreddits].count;

    return ApolloPFToggleCell(
        tableView,
        @"ApolloPFSpecificSubredditsToggle",
        @"Subreddit-Specific Filters",
        count,
        showingExpanded
    );
}

%new
- (void)apollo_pfUpdateSpecificSubredditsToggleAccessory:(UITableView *)tableView
                                                 expanded:(BOOL)expanded {
    NSInteger native =
        [self apollo_pfNativeSectionCount:tableView];

    NSIndexPath *toggle =
        [NSIndexPath indexPathForRow:0 inSection:native];

    UITableViewCell *cell =
        [tableView cellForRowAtIndexPath:toggle];

    if (!cell) return;

    cell.textLabel.text =
        @"Subreddit-Specific Filters";

    ApolloPFSetToggleChevron(cell, expanded, [ApolloPostFilterStore allSubreddits].count > 0);
}

%new
- (void)apollo_pfSetSpecificSubredditsExpanded:(BOOL)expanded
                                         table:(UITableView *)tableView {
    BOOL was =
        [objc_getAssociatedObject(
            self,
            kApolloPFSpecificSubredditsExpandedKey
        ) boolValue];

    objc_setAssociatedObject(
        self,
        kApolloPFSpecificSubredditsExpandedKey,
        @(expanded),
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );

    if (![tableView isKindOfClass:[UITableView class]]) return;

    NSInteger native =
        [self apollo_pfNativeSectionCount:tableView];
    NSInteger section = native;
    NSInteger entryCount =
        (NSInteger)[ApolloPostFilterStore allSubreddits].count;

    if (was == expanded) return;

    NSMutableArray<NSIndexPath *> *rows =
        [NSMutableArray arrayWithCapacity:entryCount];

    // Row 0 is toggle. Existing subreddit filters occupy 1...N.
    // Add Subreddit Filter remains visible as the final row.
    for (NSInteger i = 1; i <= entryCount; i++) {
        [rows addObject:
            [NSIndexPath indexPathForRow:i inSection:section]];
    }

    @try {
        [self apollo_pfUpdateSpecificSubredditsToggleAccessory:tableView
                                                      expanded:expanded];

        if (expanded) {
            [tableView insertRowsAtIndexPaths:rows
                             withRowAnimation:UITableViewRowAnimationFade];
        } else {
            [tableView deleteRowsAtIndexPaths:rows
                             withRowAnimation:UITableViewRowAnimationFade];
        }
    } @catch (__unused id e) {
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:section]
                 withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}


#pragma mark - Collapsible Subreddit Filter Phrases toggle

%new
- (UITableViewCell *)apollo_pfNameFiltersToggleCellForTable:(UITableView *)tableView
                                           showingExpanded:(BOOL)showingExpanded {
    NSInteger count = (NSInteger)[ApolloPostFilterStore nameSubstrings].count;
    return ApolloPFToggleCell(
        tableView,
        @"ApolloPFNameFiltersToggle",
        @"Filter Subreddits by Name",
        count,
        showingExpanded
    );
}

%new
- (void)apollo_pfUpdateNameFiltersToggleAccessory:(UITableView *)tableView
                                         expanded:(BOOL)expanded {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    NSIndexPath *toggle =
        [NSIndexPath indexPathForRow:0 inSection:native + 1];

    UITableViewCell *cell = [tableView cellForRowAtIndexPath:toggle];
    if (!cell) return;

    cell.textLabel.text =
        @"Filter Subreddits by Name";

    ApolloPFSetToggleChevron(cell, expanded, [ApolloPostFilterStore nameSubstrings].count > 0);
}

%new
- (void)apollo_pfSetNameFiltersExpanded:(BOOL)expanded
                                  table:(UITableView *)tableView {
    BOOL was =
        [objc_getAssociatedObject(self, kApolloPFNameFiltersExpandedKey) boolValue];

    objc_setAssociatedObject(
        self,
        kApolloPFNameFiltersExpandedKey,
        @(expanded),
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );

    if (![tableView isKindOfClass:[UITableView class]]) return;

    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    NSInteger section = native + 1;
    NSInteger entryCount =
        (NSInteger)[ApolloPostFilterStore nameSubstrings].count;

    if (was == expanded) return;

    NSMutableArray<NSIndexPath *> *rows =
        [NSMutableArray arrayWithCapacity:entryCount];

    // Row 0 is toggle. Existing filters occupy 1...N.
    // Add Filter Phrase remains visible as the final row.
    for (NSInteger i = 1; i <= entryCount; i++) {
        [rows addObject:
            [NSIndexPath indexPathForRow:i inSection:section]];
    }

    @try {
        [self apollo_pfUpdateNameFiltersToggleAccessory:tableView
                                               expanded:expanded];

        if (expanded) {
            [tableView insertRowsAtIndexPaths:rows
                             withRowAnimation:UITableViewRowAnimationFade];
        } else {
            [tableView deleteRowsAtIndexPaths:rows
                             withRowAnimation:UITableViewRowAnimationFade];
        }
    } @catch (__unused id e) {
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:section]
                 withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}

#pragma mark - Collapsible Filtered Keywords toggle

%new
- (UITableViewCell *)apollo_pfKeywordsToggleCellForTable:(UITableView *)tableView
                                        showingExpanded:(BOOL)showingExpanded {
    NSInteger nativeRows =
        [objc_getAssociatedObject(self, kApolloPFKeywordsNativeCountKey) integerValue];
    return ApolloPFToggleCell(
        tableView,
        @"ApolloPFFilteredKeywordsToggle",
        @"Filtered Keywords",
        MAX((NSInteger)0, nativeRows - 1),
        showingExpanded
    );
}

%new
- (void)apollo_pfUpdateKeywordsToggleAccessory:(UITableView *)tableView expanded:(BOOL)expanded {
    UITableViewCell *cell =
        [tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    if (!cell) return;

    cell.textLabel.text = @"Filtered Keywords";

    ApolloPFSetToggleChevron(cell, expanded, [objc_getAssociatedObject(self, kApolloPFKeywordsNativeCountKey) integerValue] > 1);
}

%new
- (void)apollo_pfSetKeywordsExpanded:(BOOL)expanded table:(UITableView *)tableView {
    BOOL was = [objc_getAssociatedObject(self, kApolloPFKeywordsExpandedKey) boolValue];
    objc_setAssociatedObject(self, kApolloPFKeywordsExpandedKey, @(expanded), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (![tableView isKindOfClass:[UITableView class]]) return;

    NSInteger nativeCount =
        [objc_getAssociatedObject(self, kApolloPFKeywordsNativeCountKey) integerValue];

    if (was == expanded || nativeCount <= 0) {
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:0]
                 withRowAnimation:UITableViewRowAnimationAutomatic];
        return;
    }

    // The Add Keyword row is persistent. Only the existing keyword
    // entries animate in/out between the toggle and Add row.
    NSInteger entryCount = MAX((NSInteger)0, nativeCount - 1);
    NSMutableArray<NSIndexPath *> *rows =
        [NSMutableArray arrayWithCapacity:entryCount];
    for (NSInteger i = 1; i <= entryCount; i++) {
        [rows addObject:[NSIndexPath indexPathForRow:i inSection:0]];
    }

    @try {
        [self apollo_pfUpdateKeywordsToggleAccessory:tableView expanded:expanded];

        if (expanded) {
            [tableView insertRowsAtIndexPaths:rows
                             withRowAnimation:UITableViewRowAnimationFade];
        } else {
            [tableView deleteRowsAtIndexPaths:rows
                             withRowAnimation:UITableViewRowAnimationFade];
        }
    } @catch (__unused id e) {
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:0]
                 withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}


#pragma mark - Collapsible Filtered Subreddits toggle

%new
- (UITableViewCell *)apollo_pfSubredditsToggleCellForTable:(UITableView *)tableView
                                          showingExpanded:(BOOL)showingExpanded {
    NSInteger nativeRows =
        [objc_getAssociatedObject(self, kApolloPFSubredditsNativeCountKey) integerValue];
    return ApolloPFToggleCell(
        tableView,
        @"ApolloPFFilteredSubredditsToggle",
        @"Filtered Subreddits",
        MAX((NSInteger)0, nativeRows - 1),
        showingExpanded
    );
}

%new
- (void)apollo_pfUpdateSubredditsToggleAccessory:(UITableView *)tableView
                                        expanded:(BOOL)expanded {
    UITableViewCell *cell =
        [tableView cellForRowAtIndexPath:
            [NSIndexPath indexPathForRow:0 inSection:1]];

    if (!cell) return;

    cell.textLabel.text =
        @"Filtered Subreddits";

    ApolloPFSetToggleChevron(cell, expanded, [objc_getAssociatedObject(self, kApolloPFSubredditsNativeCountKey) integerValue] > 1);
}

%new
- (void)apollo_pfSetSubredditsExpanded:(BOOL)expanded
                                 table:(UITableView *)tableView {
    BOOL was =
        [objc_getAssociatedObject(self, kApolloPFSubredditsExpandedKey) boolValue];

    objc_setAssociatedObject(
        self,
        kApolloPFSubredditsExpandedKey,
        @(expanded),
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );

    if (![tableView isKindOfClass:[UITableView class]]) return;

    NSInteger nativeCount =
        [objc_getAssociatedObject(self, kApolloPFSubredditsNativeCountKey) integerValue];

    if (was == expanded || nativeCount <= 0) {
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                 withRowAnimation:UITableViewRowAnimationAutomatic];
        return;
    }

    // Add Subreddit stays visible. Only existing subreddit entries animate.
    NSInteger entryCount = MAX((NSInteger)0, nativeCount - 1);

    NSMutableArray<NSIndexPath *> *rows =
        [NSMutableArray arrayWithCapacity:entryCount];

    for (NSInteger i = 1; i <= entryCount; i++) {
        [rows addObject:[NSIndexPath indexPathForRow:i inSection:1]];
    }

    @try {
        [self apollo_pfUpdateSubredditsToggleAccessory:tableView
                                              expanded:expanded];

        if (expanded) {
            [tableView insertRowsAtIndexPaths:rows
                             withRowAnimation:UITableViewRowAnimationFade];
        } else {
            [tableView deleteRowsAtIndexPaths:rows
                             withRowAnimation:UITableViewRowAnimationFade];
        }
    } @catch (__unused id e) {
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                 withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}

#pragma mark - Collapsible Blocked Users toggle

// Row 0 of the Blocked Users section: our themed "Blocked Users (N)" toggle cell, so
// the toggle and the users below it read as ONE continuous rounded group. It is OUR
// OWN cell (dedicated reuse id) so its chevron never leaks onto Apollo's recycled
// cells. Collapsed shows a disclosure chevron (tap to expand); expanded shows a down
// chevron (tap to collapse). The count is read LIVE from Apollo's native row count.
%new
- (UITableViewCell *)apollo_pfBlockedToggleCellForTable:(UITableView *)tableView
                                       showingExpanded:(BOOL)showingExpanded {
    NSInteger nativeRows =
        [objc_getAssociatedObject(self, kApolloPFBlockedNativeCountKey) integerValue];
    return ApolloPFToggleCell(
        tableView,
        @"ApolloPFBlockedUsersToggle",
        @"Blocked Users",
        MAX((NSInteger)0, nativeRows - 1),
        showingExpanded
    );
}

%new
- (void)apollo_pfUpdateBlockedToggleAccessory:(UITableView *)tableView expanded:(BOOL)expanded {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (native <= 0) return;

    NSIndexPath *toggle = [NSIndexPath indexPathForRow:0 inSection:native - 1];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:toggle];
    if (!cell) return;

    cell.textLabel.text =
        @"Blocked Users";

    ApolloPFSetToggleChevron(cell, expanded, [objc_getAssociatedObject(self, kApolloPFBlockedNativeCountKey) integerValue] > 1);
}

%new
- (void)apollo_pfSetBlockedExpanded:(BOOL)expanded table:(UITableView *)tableView {
    BOOL was = [objc_getAssociatedObject(self, kApolloPFBlockedExpandedKey) boolValue];
    objc_setAssociatedObject(self, kApolloPFBlockedExpandedKey, @(expanded), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (![tableView isKindOfClass:[UITableView class]]) return;
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (native <= 0) return;
    NSInteger section = native - 1;
    NSInteger nativeCount = [objc_getAssociatedObject(self, kApolloPFBlockedNativeCountKey) integerValue];
    // Animate only Apollo's rows (indices 1..nativeCount) in/out — NOT a full
    // reloadSections — so the section's header/footer aren't re-laid-out (that re-layout
    // was flashing the footer text to the left edge for a frame). Row 0 (our toggle)
    // stays put; we just reload it to flip its chevron.
    if (was == expanded || nativeCount <= 0) {
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:section] withRowAnimation:UITableViewRowAnimationAutomatic];
        return;
    }
    // The Add User row is persistent. Only blocked-user entries animate
    // in/out between the toggle and Add row.
    NSInteger entryCount = MAX((NSInteger)0, nativeCount - 1);
    NSMutableArray<NSIndexPath *> *rows = [NSMutableArray arrayWithCapacity:entryCount];
    for (NSInteger i = 1; i <= entryCount; i++) {
        [rows addObject:[NSIndexPath indexPathForRow:i inSection:section]];
    }
    @try {
        if (expanded) {
            [self apollo_pfUpdateBlockedToggleAccessory:tableView expanded:YES];
            [tableView insertRowsAtIndexPaths:rows
                             withRowAnimation:UITableViewRowAnimationFade];
        } else {
            // Change the accessory immediately so the chevron transition happens
            // together with the collapsing rows. The toggle cell itself stays
            // intact, avoiding the layout jump caused by reloading it.
            [self apollo_pfUpdateBlockedToggleAccessory:tableView expanded:NO];
            [tableView deleteRowsAtIndexPaths:rows
                             withRowAnimation:UITableViewRowAnimationFade];
        }
    } @catch (__unused id e) {
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:section]
                 withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}


%end

%ctor {
    %init(_TtC6Apollo29SettingsFiltersViewController = objc_getClass("_TtC6Apollo29SettingsFiltersViewController"));
}
