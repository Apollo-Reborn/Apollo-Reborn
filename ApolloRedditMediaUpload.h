#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (^ApolloRedditMediaUploadCompletion)(NSURL *imageURL, NSString *assetID, NSString *webSocketURL, NSError *error);

BOOL ApolloIsImgurImageUploadRequest(NSURLRequest *request);
NSString *ApolloMediaMIMETypeForFilename(NSString *filename, NSString *fallbackMIMEType);
NSData *ApolloSyntheticImgurUploadResponseData(NSURL *imageURL, NSString *mimeType);
void ApolloUploadImageDataToReddit(NSData *imageData,
                                   NSString *filename,
                                   NSString *mimeType,
                                   NSString *bearerToken,
                                   NSString *userAgent,
                                   ApolloRedditMediaUploadCompletion completion);

#ifdef __cplusplus
}
#endif
