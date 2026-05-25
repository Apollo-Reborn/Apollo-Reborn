#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

NSString * _Nullable ApolloImageChestPostIDFromURL(NSURL *url);
BOOL ApolloImageChestIsPostURL(NSURL *url);
BOOL ApolloImageChestIsDirectImageURL(NSURL *url);
NSDictionary * _Nullable ApolloImageChestCachedResolution(NSURL *url);
BOOL ApolloImageChestCachedFailureExists(NSURL *url);
void ApolloImageChestResolveURL(NSURL *url, void (^ _Nullable completion)(NSDictionary * _Nullable result));

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
