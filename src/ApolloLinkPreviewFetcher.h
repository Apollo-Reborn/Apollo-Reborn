#import <Foundation/Foundation.h>

#import "ApolloLinkPreviewModel.h"

@interface ApolloLinkPreviewFetcher : NSObject

+ (void)requestPreviewForURL:(NSURL *)url completion:(void (^)(ApolloLinkPreview *preview))completion;
+ (BOOL)isTwitterURL:(NSURL *)url;

@end
