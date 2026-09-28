#import <UIKit/UIKit.h>

// The Search tab's "Google" mode UI (see ApolloGoogleSearchTab.m for how it
// is attached to Apollo's SearchViewController, and ApolloGoogleSearch.h for
// the search itself).
//
//   * ApolloSearchEngineButton — the magnifier inside the search field,
//     turned into the engine switch: tap (or press and hold) for a Reddit /
//     Google menu. The icon shows which one is active.
//   * ApolloGoogleSearchResultsViewController — the Google list, layered over
//     Apollo's table while Google mode has text: live Google suggestions while
//     typing, then the result cards, headed by the time / exact-words chips.

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ApolloSearchEngine) {
    ApolloSearchEngineReddit = 0,
    ApolloSearchEngineGoogle = 1,
};

// The engine choice, persisted (the Search tab reopens on the last one used).
FOUNDATION_EXPORT ApolloSearchEngine ApolloSearchEngineCurrent(void);
FOUNDATION_EXPORT void ApolloSearchEngineSetCurrent(ApolloSearchEngine engine);

@interface ApolloSearchEngineButton : UIButton
// Tint of the magnifier this button replaces, so Reddit mode looks unchanged.
@property (nonatomic, strong, nullable) UIColor *iconColor;
@property (nonatomic, copy, nullable) void (^engineChanged)(ApolloSearchEngine engine);
// Re-read the engine from defaults: icon, menu checkmark, accessibility.
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
