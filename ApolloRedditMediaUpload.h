#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (^ApolloRedditMediaUploadCompletion)(NSURL *mediaURL, NSString *assetID, NSString *webSocketURL, NSError *error);

BOOL ApolloIsImgurImageUploadRequest(NSURLRequest *request);
NSString *ApolloMediaMIMETypeForFilename(NSString *filename, NSString *fallbackMIMEType);
BOOL ApolloMediaMIMETypeIsVideo(NSString *mimeType);
NSData *ApolloSyntheticImgurUploadResponseData(NSURL *mediaURL, NSString *mimeType);
void ApolloUploadMediaDataToReddit(NSData *mediaData,
                                  NSString *filename,
                                  NSString *mimeType,
                                  NSString *bearerToken,
                                  NSString *userAgent,
                                  ApolloRedditMediaUploadCompletion completion);
void ApolloUploadImageDataToReddit(NSData *imageData,
                                   NSString *filename,
                                   NSString *mimeType,
                                   NSString *bearerToken,
                                   NSString *userAgent,
                                   ApolloRedditMediaUploadCompletion completion);

#ifdef __cplusplus
}
#endif
