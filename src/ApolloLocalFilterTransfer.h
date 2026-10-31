#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// Plain-text transfer for Apollo's per-account `locallyFilteredSubreddits`.
// Names are exported one per line. Import accepts whitespace/comma-separated
// names, optional r/ or reddit.com/r/ prefixes, and merges without removing the
// account's existing entries.
typedef NS_ENUM(NSUInteger, ApolloLocalFilterImportStatus) {
    ApolloLocalFilterImportStatusSuccess = 0,
    ApolloLocalFilterImportStatusTooManyBytes,
    ApolloLocalFilterImportStatusTooManyEntries,
};

NSString *ApolloLocalFilterExportText(NSArray *storedNames);

NSArray *ApolloLocalFilterMergeImportText(NSArray *storedNames,
                                           NSString *text,
                                           NSUInteger * _Nullable addedCount,
                                           NSUInteger * _Nullable invalidCount,
                                           ApolloLocalFilterImportStatus * _Nullable status);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
