#import <Foundation/Foundation.h>
#import <sys/socket.h>

NS_ASSUME_NONNULL_BEGIN

// A completed download is owned by the caller. Failed and cancelled transfers
// remove every temporary file before invoking completion.
@protocol ApolloBoundedMediaTransfer <NSObject>
- (void)cancel;
@end

typedef void (^ApolloBoundedMediaDownloadCompletion)(NSURL *_Nullable fileURL,
                                                      NSHTTPURLResponse *_Nullable response,
                                                      NSError *_Nullable error);

__BEGIN_DECLS

// Public for the media parsers and focused policy tests. Host names are resolved
// before the first request; every redirect is resolved and checked again.
BOOL ApolloMediaURLHasAllowedHTTPSHost(NSURL *_Nullable URL);
BOOL ApolloMediaURLHasPublicDestination(NSURL *_Nullable URL, NSError **error);
BOOL ApolloMediaSocketAddressIsPublic(const struct sockaddr *_Nullable address);

// Pure limit predicates used by the transfer delegate and its focused tests.
BOOL ApolloMediaExpectedLengthFits(long long expectedLength, unsigned long long maximumBytes,
                                   unsigned long long availableBytes, unsigned long long reserveBytes);
BOOL ApolloMediaByteRangeFits(unsigned long long receivedBytes, unsigned long long incomingBytes,
                              unsigned long long maximumBytes);
BOOL ApolloMediaMuxOutputBudget(unsigned long long videoBytes, unsigned long long audioBytes,
                                unsigned long long availableBytes, unsigned long long reserveBytes,
                                unsigned long long *_Nullable maximumOutputBytes);
BOOL ApolloMediaMuxFilesFit(NSURL *videoURL, NSURL *audioURL, unsigned long long reserveBytes,
                            unsigned long long *_Nullable maximumOutputBytes);
BOOL ApolloMediaOutputFileFits(NSURL *_Nullable outputURL, unsigned long long maximumOutputBytes,
                               unsigned long long reserveBytes);

id<ApolloBoundedMediaTransfer> ApolloStartBoundedMediaDownload(
    NSURLRequest *request,
    unsigned long long maximumBytes,
    unsigned long long reserveBytes,
    NSString *_Nullable filenameExtension,
    dispatch_queue_t _Nullable completionQueue,
    ApolloBoundedMediaDownloadCompletion completion);

__END_DECLS

NS_ASSUME_NONNULL_END
