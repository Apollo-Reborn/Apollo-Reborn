// ApolloSettingsGeneralTable — feature-neutral owner of Apollo's native
// Settings > General table geometry (_TtC6Apollo29SettingsGeneralViewController).
//
// Exactly ONE module may remap that screen's index paths (two independent hook
// stacks disagree about index-path spaces the moment one of them shifts rows —
// the PR #570 class of bug). This module is that owner. Feature modules never
// touch the table; they register WHAT they mean at %ctor time:
//   - ApolloGeneralTableHideRows():  hide native rows (omitted from display space)
//   - ApolloGeneralTableInjectRow(): add one tweak-owned row under a native anchor
// The registry is consulted lazily when the screen loads, so registration order —
// and Makefile link order — is irrelevant.
//
// The same owner also serves General > Mark Read / Hiding Posts
// (_TtC6Apollo41SettingsMarkReadHidingPostsViewController). Unlike General, that
// form changes at runtime: "Disable Marking Posts Read" hides every other row and
// the whole Auto Hide section through Eureka hidden conditions, which update the
// table with native index paths. So nothing is spliced or hidden there; the one
// supported change is a row APPENDED after the last native row of a section
// (ApolloNativeSettingsAppendRow). Native index paths stay identical, so
// Eureka's own inserts/deletes stay valid, and the appended row comes and goes in
// its own table update (ApolloNativeSettingsRefreshAppendedRow).
//
// See ApolloSettingsGeneralTable.xm for the display<->native row map and the
// delegate/dataSource proxy, and docs/settings-general-table-refactor-plan.md for
// the full design and its verified assumptions.

#import <UIKit/UIKit.h>

// extern "C" so the ObjC++ (.xm) callers and definitions agree on linkage
// (same convention as ApolloState.h).
#ifdef __cplusplus
extern "C" {
#endif

// The native Eureka screens this owner serves.
typedef NS_ENUM(NSInteger, ApolloNativeSettingsScreen) {
    ApolloNativeSettingsScreenGeneral = 0,
    ApolloNativeSettingsScreenMarkReadHidingPosts = 1,
};

// Register a matcher that hides every native row whose built cell it matches.
// Hidden rows are OMITTED from display space (not zero-heighted): no separator
// hairlines, no estimated-vs-actual height mismatch, no selection to swallow.
// Matchers run once per screen instance, during the viewDidLoad scan.
void ApolloGeneralTableHideRows(BOOL (^cellMatcher)(UITableViewCell *cell));

// Register a tweak-owned row injected directly below a native anchor row. The
// anchor is the row titled anchorTitle inside the section that also contains a
// row titled sectionMarkerTitle (pass nil when anchorTitle is unique on the
// screen). factory is called on every dequeue of the injected display slot with
// the live donor (anchor) cell for theming; it should cache its cell per vc and
// re-read its state from defaults each call. Fail-soft: when no anchor matches
// (relabeled rows, future binary), nothing is injected and the native screen is
// untouched.
void ApolloGeneralTableInjectRow(NSString *anchorTitle,
                                 NSString *sectionMarkerTitle,
                                 UITableViewCell *(^factory)(UIViewController *vc,
                                                             UITableViewCell *donor));

// Like ApolloGeneralTableInjectRow, but the injected row is tappable:
// onSelect runs on selection (vc = the live General screen, for pushing), and
// the row highlights like a native disclosure row. Rows registered with the
// plain function stay inert (their switch is the control).
void ApolloGeneralTableInjectSelectableRow(NSString *anchorTitle,
                                           NSString *sectionMarkerTitle,
                                           UITableViewCell *(^factory)(UIViewController *vc,
                                                                       UITableViewCell *donor),
                                           void (^onSelect)(UIViewController *vc));

// Reconfigure a native row whenever Eureka supplies its cell. This leaves the
// native form and index-path geometry untouched; it is intended for small
// cross-feature state adjustments such as disabling a redundant switch. The
// title is matched with ApolloGeneralTableCellHasTitle().
void ApolloGeneralTableConfigureNativeRow(NSString *title,
                                          void (^configure)(UIViewController *vc,
                                                            UITableViewCell *cell));

// ApolloGeneralTableConfigureNativeRow for any screen this owner serves (the
// General form calls this with ApolloNativeSettingsScreenGeneral).
void ApolloNativeSettingsConfigureNativeRow(ApolloNativeSettingsScreen screen,
                                            NSString *title,
                                            void (^configure)(UIViewController *vc,
                                                              UITableViewCell *cell));

// Append one tweak-owned, inert (switch) row after the last native row of the
// section that contains a row titled sectionTitle. One appended row per screen;
// Mark Read / Hiding Posts only (General keeps its splice map). visible is asked
// when the screen loads and on every ApolloNativeSettingsRefreshAppendedRow; the
// factory gets the section's first native cell as the theming donor. Fail-soft:
// no section with that title (or no hooks) leaves the screen native.
void ApolloNativeSettingsAppendRow(ApolloNativeSettingsScreen screen,
                                   NSString *sectionTitle,
                                   BOOL (^visible)(void),
                                   UITableViewCell *(^factory)(UIViewController *vc,
                                                               UITableViewCell *donor));

// Re-ask the appended row's visible block for this screen instance and insert or
// delete the row in its own table update when the answer changed. Call it AFTER
// the native change it depends on has finished updating the table (e.g. from a
// valueChanged target added after Eureka's own).
void ApolloNativeSettingsRefreshAppendedRow(UIViewController *vc);

// Re-run all registered native-row configurators for the currently visible
// General cells. Off-screen rows are configured the next time Eureka supplies
// their cell.
void ApolloGeneralTableRefreshNativeRowConfigurations(void);

// The live General-screen instance, if any (weak-backed; nil once it's gone).
UIViewController *ApolloGeneralTableActiveVC(void);

// The on-screen cell of a native row found by title (nil when off-screen or
// absent). For cross-feature interaction with native rows — e.g. the per-post
// sort exclusivity cross-flip reaching the native "Remember Subreddit Sort"
// switch to flip it the way a user tap would.
UITableViewCell *ApolloGeneralTableVisibleCellForTitle(UIViewController *vc, NSString *title);

// Shared title matcher: trimmed exact match against cell.textLabel or any UILabel
// in the cell's content tree (Eureka rows often put the title on a custom label).
BOOL ApolloGeneralTableCellHasTitle(UITableViewCell *cell, NSString *title);

#ifdef __cplusplus
}
#endif
