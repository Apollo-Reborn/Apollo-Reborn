#import <UIKit/UIKit.h>

// The Search tab's external-engine modes (Google, Kagi) UI (see
// ApolloGoogleSearchTab.m for how it is attached to Apollo's
// SearchViewController, and ApolloGoogleSearch.h / ApolloKagiSearch.h for the
// searches themselves).
//
//   * ApolloSearchEngineButton: the magnifier inside the search field,
//     turned into the engine switch: tap (or press and hold) for a Reddit /
//     Google / Kagi menu. The icon shows which one is active.
//   * ApolloGoogleSearchResultsViewController: the external engine's list,
//     layered over Apollo's table while Google or Kagi mode has text: live
//     suggestions while typing, then the result cards, headed by the time /
//     exact-words chips.

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ApolloSearchEngine) {
    ApolloSearchEngineReddit = 0,
    ApolloSearchEngineGoogle = 1,
    ApolloSearchEngineKagi = 2,
};

// The engine choice, persisted (the Search tab reopens on the last one used).
// Kagi reads back as Reddit while no Kagi Session Link is saved.
FOUNDATION_EXPORT ApolloSearchEngine ApolloSearchEngineCurrent(void);
FOUNDATION_EXPORT void ApolloSearchEngineSetCurrent(ApolloSearchEngine engine);
// Google and Kagi: the modes that list results in the tweak's own list.
FOUNDATION_EXPORT BOOL ApolloSearchEngineIsExternal(ApolloSearchEngine engine);
// "Reddit", "Google", "Kagi".
FOUNDATION_EXPORT NSString *ApolloSearchEngineName(ApolloSearchEngine engine);
// The search field's placeholder in an external mode ("Search Reddit with
// Kagi"); nil for Reddit (Apollo's own placeholder stays).
FOUNDATION_EXPORT NSString *_Nullable ApolloSearchEnginePlaceholder(ApolloSearchEngine engine);

@interface ApolloSearchEngineButton : UIButton
// Tint of the magnifier this button replaces, so Reddit mode looks unchanged.
@property (nonatomic, strong, nullable) UIColor *iconColor;
@property (nonatomic, copy, nullable) void (^engineChanged)(ApolloSearchEngine engine);
// Re-read the engine from defaults: icon, menu checkmark, accessibility.
// Also runs on its own when the engine or the Kagi Session Link changes.
- (void)reloadFromDefaults;
@end

@interface ApolloGoogleSearchResultsViewController : UIViewController
@property (nonatomic, readonly) UITableView *tableView;
// The query whose results are showing (nil while suggesting / idle).
@property (nonatomic, readonly, copy, nullable) NSString *submittedQuery;

// Host hooks (set by ApolloGoogleSearchTab.m).
@property (nonatomic, copy, nullable) void (^submitText)(NSString *text);        // a suggestion row was tapped
@property (nonatomic, copy, nullable) void (^willOpenResult)(void);              // dismiss the keyboard
// Page background to match the table this list covers.
@property (nonatomic, strong, nullable) UIColor *pageBackgroundColor;

- (void)showSuggestionsForText:(NSString *)text;
- (void)searchForQuery:(NSString *)query;
- (void)reset;                      // cancel everything, back to idle
- (void)scrollToTopAnimated:(BOOL)animated;
- (BOOL)isScrolledToTop;
@end

NS_ASSUME_NONNULL_END
