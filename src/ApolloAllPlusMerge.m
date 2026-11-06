#import "ApolloAllPlusMerge.h"
#import <math.h>

double ApolloAPHotRank(double score, double createdUtc) {
    double order = log10(MAX(fabs(score), 1.0));
    double sign = score > 0 ? 1.0 : (score < 0 ? -1.0 : 0.0);
    double seconds = createdUtc - 1134028003.0;
    return order + sign * seconds / 45000.0;
}

// Numbers and numeric strings coerce to their finite double value; anything
// else -- non-numeric strings, null, a missing key, or a string -doubleValue
// happens to parse as +/-Infinity or NaN (e.g. "inf", "nan") -- clamps to 0.
// -doubleValue alone is NOT enough: it parses "inf"/"nan" strings into
// non-finite doubles, which would produce a NaN sort key downstream. See the
// "num" section of tests/fixtures/allplus_conformance.json.
double ApolloAPNumFromData(NSDictionary *child, NSString *key) {
    id data = [child objectForKey:@"data"];
    id v = [data isKindOfClass:[NSDictionary class]] ? [data objectForKey:key] : nil;
    double n = [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0.0;
    return isfinite(n) ? n : 0.0;
}

double ApolloAPSortKey(NSDictionary *child, NSString *sort) {
    if ([sort isEqualToString:@"top"] || [sort isEqualToString:@"controversial"]) {
        return ApolloAPNumFromData(child, @"score");
    }
    if ([sort isEqualToString:@"new"]) {
        return ApolloAPNumFromData(child, @"created_utc");
    }
    return ApolloAPHotRank(ApolloAPNumFromData(child, @"score"), ApolloAPNumFromData(child, @"created_utc"));
}

// Only NaN maps to 0 -- any other value (including +/-Infinity) passes
// through unchanged.
static double NumOr0(double x) { return isnan(x) ? 0.0 : x; }

NSUInteger ApolloAPSlotFor(NSArray<NSNumber *> *nativeHots, double candHot, double B) {
    double h = candHot + NumOr0(B);
    NSUInteger n = 0;
    for (NSNumber *nh in (nativeHots ?: @[])) {
        if ([nh doubleValue] > h) { n++; }
    }
    return n;
}
