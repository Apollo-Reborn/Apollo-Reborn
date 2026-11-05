#import <Foundation/Foundation.h>

// Pure, Foundation-only merge logic for the All+ r/all blend (see
// ApolloAllPlusNSFW.xm). No UI frameworks, no runtime hooks, no other repo
// headers, so it compiles and runs standalone for unit tests
// (tests/run_allplus_merge_tests.sh, checked against the shared vectors in
// tests/fixtures/allplus_conformance.json).

#ifdef __cplusplus
extern "C" {
#endif

// Reddit's public hot-ranking formula. Higher ranks earlier.
double ApolloAPHotRank(double score, double createdUtc);

// Coerce child[@"data"][key] to a finite double. Numbers and numeric strings pass through as
// their double value; anything non-numeric, missing, or non-finite (NaN,
// +/-Infinity, including strings like "inf"/"nan" that -doubleValue parses
// as such) collapses to 0.
double ApolloAPNumFromData(NSDictionary *child, NSString *key);

// Merge key for a listing child given the feed sort. Reads child[@"data"]
// ["score"] / ["created_utc"] via ApolloAPNumFromData. "top"/"controversial"
// -> score; "new" -> created_utc; everything else (hot/best/rising/unknown)
// -> hot rank.
double ApolloAPSortKey(NSDictionary *child, NSString *sort);

// Placement: the count of natives whose raw hot exceeds the candidate's
// boosted hot -- a count, not an insertion index, and robust to natives not
// being hot-ordered (measured reality of r/all).
NSUInteger ApolloAPSlotFor(NSArray<NSNumber *> *nativeHots, double candHot, double B);

#ifdef __cplusplus
}
#endif
