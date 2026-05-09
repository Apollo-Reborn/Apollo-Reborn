#import "ApolloRedditMediaUpload.h"
#import "ApolloCommon.h"

static NSString *const ApolloRedditUploadErrorDomain = @"ApolloRedditMediaUpload";

static NSError *ApolloRedditUploadError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:ApolloRedditUploadErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Reddit media upload failed"}];
}

BOOL ApolloIsImgurImageUploadRequest(NSURLRequest *request) {
    NSURL *url = request.URL;
    if (!url) return NO;

    BOOL imgurHost = [url.host isEqualToString:@"imgur-apiv3.p.rapidapi.com"] || [url.host isEqualToString:@"api.imgur.com"];
    return imgurHost && [url.path isEqualToString:@"/3/image"];
}

NSString *ApolloMediaMIMETypeForFilename(NSString *filename, NSString *fallbackMIMEType) {
    NSString *extension = filename.pathExtension.lowercaseString;
    NSDictionary<NSString *, NSString *> *types = @{
        @"jpg": @"image/jpeg",
        @"jpeg": @"image/jpeg",
        @"png": @"image/png",
        @"gif": @"image/gif",
        @"mp4": @"video/mp4",
        @"mov": @"video/quicktime",
    };

    NSString *type = types[extension];
    if (type.length > 0) return type;
    if (fallbackMIMEType.length > 0 && ![fallbackMIMEType hasPrefix:@"multipart/"]) return fallbackMIMEType;
    return @"image/jpeg";
}

static NSString *ApolloDefaultExtensionForMIMEType(NSString *mimeType) {
    if ([mimeType isEqualToString:@"image/png"]) return @"png";
    if ([mimeType isEqualToString:@"image/gif"]) return @"gif";
    if ([mimeType isEqualToString:@"video/mp4"]) return @"mp4";
    if ([mimeType isEqualToString:@"video/quicktime"]) return @"mov";
    return @"jpg";
}

static NSString *ApolloNormalizedFilename(NSString *filename, NSString *mimeType) {
    NSString *clean = filename.lastPathComponent;
    if (clean.length == 0) {
        clean = [@"apollo-upload" stringByAppendingPathExtension:ApolloDefaultExtensionForMIMEType(mimeType)];
    } else if (clean.pathExtension.length == 0) {
        clean = [clean stringByAppendingPathExtension:ApolloDefaultExtensionForMIMEType(mimeType)];
    }
    return clean;
}

static void ApolloAppendMultipartField(NSMutableData *body, NSString *boundary, NSString *name, NSString *value) {
    if (name.length == 0) return;
    if (!value) value = @"";

    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"\r\n\r\n", name] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[value dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
}

static void ApolloAppendMultipartFile(NSMutableData *body, NSString *boundary, NSString *fieldName, NSString *filename, NSString *mimeType, NSData *fileData) {
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"; filename=\"%@\"\r\n", fieldName, filename] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"Content-Type: %@\r\n\r\n", mimeType] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:fileData];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
}

static NSData *ApolloMultipartBodyForFields(NSDictionary<NSString *, NSString *> *fields,
                                            NSData *fileData,
                                            NSString *filename,
                                            NSString *mimeType,
                                            NSString *boundary,
                                            BOOL includeFile) {
    NSMutableData *body = [NSMutableData data];
    for (NSString *key in fields) {
        ApolloAppendMultipartField(body, boundary, key, fields[key]);
    }
    if (includeFile) {
        ApolloAppendMultipartFile(body, boundary, @"file", filename, mimeType, fileData);
    }
    [body appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    return body;
}

static NSString *ApolloBoundary(void) {
    return [@"ApolloBoundary-" stringByAppendingString:[NSUUID UUID].UUIDString];
}

@interface ApolloRedditS3XMLParser : NSObject <NSXMLParserDelegate>
@property (nonatomic, copy) NSString *currentElement;
@property (nonatomic, strong) NSMutableString *currentText;
@property (nonatomic, copy) NSString *location;
@property (nonatomic, copy) NSString *errorCode;
@property (nonatomic, copy) NSString *errorMessage;
@end

@implementation ApolloRedditS3XMLParser
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary<NSString *, NSString *> *)attributeDict {
    if ([elementName isEqualToString:@"Location"] || [elementName isEqualToString:@"Code"] || [elementName isEqualToString:@"Message"]) {
        self.currentElement = elementName;
        self.currentText = [NSMutableString string];
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    if (self.currentText) {
        [self.currentText appendString:string];
    }
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName {
    if (![elementName isEqualToString:self.currentElement]) return;

    NSString *value = [self.currentText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([elementName isEqualToString:@"Location"]) {
        self.location = value;
    } else if ([elementName isEqualToString:@"Code"]) {
        self.errorCode = value;
    } else if ([elementName isEqualToString:@"Message"]) {
        self.errorMessage = value;
    }
    self.currentElement = nil;
    self.currentText = nil;
}
@end

static NSURL *ApolloLocationURLFromS3Response(NSData *data, NSError **error) {
    ApolloRedditS3XMLParser *delegate = [ApolloRedditS3XMLParser new];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    parser.delegate = delegate;

    if (![parser parse]) {
        if (error) *error = parser.parserError ?: ApolloRedditUploadError(40, @"Could not parse Reddit upload response");
        return nil;
    }

    if (delegate.location.length == 0) {
        NSString *message = delegate.errorMessage.length > 0 ? delegate.errorMessage : @"Reddit upload response did not include a media URL";
        if (delegate.errorCode.length > 0) {
            message = [NSString stringWithFormat:@"%@: %@", delegate.errorCode, message];
        }
        if (error) *error = ApolloRedditUploadError(41, message);
        return nil;
    }

    NSString *decoded = delegate.location.stringByRemovingPercentEncoding ?: delegate.location;
    return [NSURL URLWithString:decoded];
}

NSData *ApolloSyntheticImgurUploadResponseData(NSURL *imageURL, NSString *mimeType) {
    NSString *imageID = imageURL.lastPathComponent.length > 0 ? imageURL.lastPathComponent : [NSUUID UUID].UUIDString;
    NSDictionary *syntheticResponse = @{
        @"status": @200,
        @"success": @YES,
        @"data": @{
            @"id": imageID,
            @"deletehash": @"",
            @"account_id": [NSNull null],
            @"account_url": [NSNull null],
            @"ad_type": [NSNull null],
            @"ad_url": [NSNull null],
            @"title": [NSNull null],
            @"description": [NSNull null],
            @"name": @"",
            @"type": mimeType ?: @"image/jpeg",
            @"width": @0,
            @"height": @0,
            @"size": @0,
            @"views": @0,
            @"section": [NSNull null],
            @"vote": [NSNull null],
            @"bandwidth": @0,
            @"animated": @NO,
            @"favorite": @NO,
            @"in_gallery": @NO,
            @"in_most_viral": @NO,
            @"has_sound": @NO,
            @"is_ad": @NO,
            @"nsfw": [NSNull null],
            @"link": imageURL.absoluteString ?: @"",
            @"tags": @[],
            @"datetime": @0,
            @"mp4": @"",
            @"hls": @""
        }
    };
    return [NSJSONSerialization dataWithJSONObject:syntheticResponse options:0 error:nil];
}

static void ApolloRequestRedditMediaAsset(NSData *imageData,
                                          NSString *filename,
                                          NSString *mimeType,
                                          NSString *bearerToken,
                                          NSString *userAgent,
                                          ApolloRedditMediaUploadCompletion completion) {
    NSURL *url = [NSURL URLWithString:@"https://oauth.reddit.com/api/media/asset.json"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:[@"Bearer " stringByAppendingString:bearerToken] forHTTPHeaderField:@"Authorization"];
    [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];

    NSString *boundary = ApolloBoundary();
    [request setValue:[@"multipart/form-data; boundary=" stringByAppendingString:boundary] forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = ApolloMultipartBodyForFields(@{@"filepath": filename, @"mimetype": mimeType}, nil, filename, mimeType, boundary, NO);

    ApolloLog(@"[RedditUpload] Requesting media asset for %@ (%@, %lu bytes)", filename, mimeType, (unsigned long)imageData.length);

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, nil, nil, error);
            return;
        }

        NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
        if (![response isKindOfClass:[NSHTTPURLResponse class]] || statusCode < 200 || statusCode >= 300 || data.length == 0) {
            completion(nil, nil, nil, ApolloRedditUploadError(statusCode ?: 20, @"Reddit did not provide upload fields"));
            return;
        }

        NSError *jsonError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (![json isKindOfClass:[NSDictionary class]]) {
            completion(nil, nil, nil, jsonError ?: ApolloRedditUploadError(21, @"Reddit upload field response was not JSON"));
            return;
        }

        NSDictionary *args = [json[@"args"] isKindOfClass:[NSDictionary class]] ? json[@"args"] : nil;
        NSString *action = [args[@"action"] isKindOfClass:[NSString class]] ? args[@"action"] : nil;
        NSArray *fieldArray = [args[@"fields"] isKindOfClass:[NSArray class]] ? args[@"fields"] : nil;
        NSDictionary *asset = [json[@"asset"] isKindOfClass:[NSDictionary class]] ? json[@"asset"] : nil;
        NSString *assetID = [asset[@"asset_id"] isKindOfClass:[NSString class]] ? asset[@"asset_id"] : nil;
        NSString *webSocketURL = [asset[@"websocket_url"] isKindOfClass:[NSString class]] ? asset[@"websocket_url"] : nil;

        if (assetID.length == 0) {
            completion(nil, nil, webSocketURL, ApolloRedditUploadError(25, @"Reddit upload field response did not include an asset ID"));
            return;
        }

        if (action.length == 0 || fieldArray.count == 0) {
            completion(nil, nil, webSocketURL, ApolloRedditUploadError(22, @"Reddit upload field response was incomplete"));
            return;
        }

        NSMutableDictionary<NSString *, NSString *> *fields = [NSMutableDictionary dictionary];
        for (id item in fieldArray) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSString *name = [item[@"name"] isKindOfClass:[NSString class]] ? item[@"name"] : nil;
            NSString *value = [item[@"value"] isKindOfClass:[NSString class]] ? item[@"value"] : nil;
            if (name.length > 0 && value) fields[name] = value;
        }

        if (fields.count == 0) {
            completion(nil, nil, webSocketURL, ApolloRedditUploadError(23, @"Reddit upload field response had no usable fields"));
            return;
        }

        NSString *actionURLString = [action hasPrefix:@"//"] ? [@"https:" stringByAppendingString:action] : action;
        NSURL *actionURL = [NSURL URLWithString:actionURLString];
        if (!actionURL) {
            completion(nil, nil, webSocketURL, ApolloRedditUploadError(24, @"Reddit upload field response had an invalid upload URL"));
            return;
        }

        NSString *s3Boundary = ApolloBoundary();
        NSMutableURLRequest *s3Request = [NSMutableURLRequest requestWithURL:actionURL];
        s3Request.HTTPMethod = @"POST";
        [s3Request setValue:[@"multipart/form-data; boundary=" stringByAppendingString:s3Boundary] forHTTPHeaderField:@"Content-Type"];
        s3Request.HTTPBody = ApolloMultipartBodyForFields(fields, imageData, filename, mimeType, s3Boundary, YES);

        ApolloLog(@"[RedditUpload] Uploading %@ to Reddit media storage", filename);

        NSURLSessionDataTask *s3Task = [[NSURLSession sharedSession] dataTaskWithRequest:s3Request completionHandler:^(NSData *s3Data, NSURLResponse *s3Response, NSError *s3Error) {
            if (s3Error) {
                completion(nil, assetID, webSocketURL, s3Error);
                return;
            }

            NSInteger s3StatusCode = [(NSHTTPURLResponse *)s3Response statusCode];
            if (![s3Response isKindOfClass:[NSHTTPURLResponse class]] || s3StatusCode < 200 || s3StatusCode >= 300 || s3Data.length == 0) {
                completion(nil, assetID, webSocketURL, ApolloRedditUploadError(s3StatusCode ?: 30, @"Reddit media storage upload failed"));
                return;
            }

            NSError *xmlError = nil;
            NSURL *imageURL = ApolloLocationURLFromS3Response(s3Data, &xmlError);
            if (!imageURL) {
                completion(nil, assetID, webSocketURL, xmlError);
                return;
            }

            ApolloLog(@"[RedditUpload] Uploaded media: %@ assetID=%@", imageURL.absoluteString, assetID);
            completion(imageURL, assetID, webSocketURL, nil);
        }];
        [s3Task resume];
    }];
    [task resume];
}

void ApolloUploadImageDataToReddit(NSData *imageData,
                                   NSString *filename,
                                   NSString *mimeType,
                                   NSString *bearerToken,
                                   NSString *userAgent,
                                   ApolloRedditMediaUploadCompletion completion) {
    if (imageData.length == 0) {
        completion(nil, nil, nil, ApolloRedditUploadError(1, @"Image data was empty"));
        return;
    }
    if (bearerToken.length == 0) {
        completion(nil, nil, nil, ApolloRedditUploadError(2, @"Apollo has not captured a Reddit bearer token yet"));
        return;
    }

    NSString *resolvedMIMEType = ApolloMediaMIMETypeForFilename(filename, mimeType);
    NSString *resolvedFilename = ApolloNormalizedFilename(filename, resolvedMIMEType);
    NSString *resolvedUserAgent = userAgent.length > 0 ? userAgent : @"Apollo-ImprovedCustomApi/RedditMediaUpload";

    ApolloRequestRedditMediaAsset(imageData, resolvedFilename, resolvedMIMEType, bearerToken, resolvedUserAgent, completion);
}
