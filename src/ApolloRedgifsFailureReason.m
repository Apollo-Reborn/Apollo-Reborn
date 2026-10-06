// ApolloRedgifsFailureReason.m — see ApolloRedgifsFailureReason.h.

#import "ApolloRedgifsFailureReason.h"

static ApolloRedgifsFailure ApolloRedgifsMakeFailure(ApolloRedgifsFailureKind kind, NSInteger httpStatus) {
    ApolloRedgifsFailure failure = { kind, httpStatus };
    return failure;
}

static ApolloRedgifsFailure ApolloRedgifsFailureForHTTPStatus(NSInteger status) {
    switch (status) {
        case 404: return ApolloRedgifsMakeFailure(ApolloRedgifsFailureKindNotFound, status);
        case 410: return ApolloRedgifsMakeFailure(ApolloRedgifsFailureKindDeleted, status);
        case 451: return ApolloRedgifsMakeFailure(ApolloRedgifsFailureKindRegion, status);
        default:
            return ApolloRedgifsMakeFailure(status >= 400 ? ApolloRedgifsFailureKindHTTPStatus : ApolloRedgifsFailureKindNone,
                                            status);
    }
}

// The request never got an HTTP answer from RedGIFs: no route, DNS, a refused
// or dropped connection, a TLS failure (a network filter intercepting it), or
// no network at all. Cancellation is not one: Apollo cancels lookups for cells
// that went away.
static BOOL ApolloRedgifsIsTransportError(NSError *error) {
    if (![error.domain isEqualToString:NSURLErrorDomain]) return NO;
    switch (error.code) {
        case NSURLErrorTimedOut:
        case NSURLErrorCannotFindHost:
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorNetworkConnectionLost:
        case NSURLErrorDNSLookupFailed:
        case NSURLErrorNotConnectedToInternet:
        case NSURLErrorInternationalRoamingOff:
        case NSURLErrorCallIsActive:
        case NSURLErrorDataNotAllowed:
        case NSURLErrorSecureConnectionFailed:
        case NSURLErrorServerCertificateHasBadDate:
        case NSURLErrorServerCertificateUntrusted:
        case NSURLErrorServerCertificateHasUnknownRoot:
        case NSURLErrorServerCertificateNotYetValid:
        case NSURLErrorClientCertificateRejected:
        case NSURLErrorClientCertificateRequired:
        case NSURLErrorCannotLoadFromNetwork:
            return YES;
        default:
            return NO;
    }
}

static id ApolloRedgifsJSONObject(NSData *data) {
    if (data.length == 0) return nil;
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

// RedGIFs' error body: {"error":{"code":"GifDeleted","description":"..."}}.
static NSString *ApolloRedgifsErrorCode(NSData *data) {
    id json = ApolloRedgifsJSONObject(data);
    id error = [json isKindOfClass:[NSDictionary class]] ? json[@"error"] : nil;
    id code = [error isKindOfClass:[NSDictionary class]] ? error[@"code"] : nil;
    return [code isKindOfClass:[NSString class]] ? code : nil;
}

// A lookup answer for an image (type 2): Apollo's RedGIFsVideo model needs a
// duration images don't have, so it fails to decode them.
static BOOL ApolloRedgifsIsImageRecord(NSData *data) {
    id json = ApolloRedgifsJSONObject(data);
    id gif = [json isKindOfClass:[NSDictionary class]] ? json[@"gif"] : nil;
    id type = [gif isKindOfClass:[NSDictionary class]] ? gif[@"type"] : nil;
    return [type isKindOfClass:[NSNumber class]] && [type integerValue] == 2;
}

ApolloRedgifsFailure ApolloRedgifsFailureForAPIResult(NSData *data, NSURLResponse *response, NSError *error) {
    NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
    if (status == 0) {
        return ApolloRedgifsMakeFailure(ApolloRedgifsIsTransportError(error) ? ApolloRedgifsFailureKindUnreachable
                                                                             : ApolloRedgifsFailureKindNone, 0);
    }
    if (status >= 400) {
        // RedGIFs' own code says the same as the status; prefer it in case the
        // two ever disagree.
        NSString *code = ApolloRedgifsErrorCode(data);
        if ([code isEqualToString:@"GifDeleted"]) return ApolloRedgifsMakeFailure(ApolloRedgifsFailureKindDeleted, status);
        if ([code isEqualToString:@"GifNotFound"]) return ApolloRedgifsMakeFailure(ApolloRedgifsFailureKindNotFound, status);
        return ApolloRedgifsFailureForHTTPStatus(status);
    }
    if (status >= 200 && status < 300 && ApolloRedgifsIsImageRecord(data)) {
        return ApolloRedgifsMakeFailure(ApolloRedgifsFailureKindImage, status);
    }
    return ApolloRedgifsMakeFailure(ApolloRedgifsFailureKindNone, status);
}

// The HTTP status a CoreMedia error carries, or 0. CoreMedia has its own codes
// for a few statuses (403 arrives as a bare OSStatus with no text) and reports
// the rest as "... (CoreMediaErrorDomain error -16845 - HTTP 451: (unhandled))".
static NSInteger ApolloRedgifsHTTPStatusInMediaError(NSError *error) {
    BOOL coreMedia = [error.domain isEqualToString:@"CoreMediaErrorDomain"]
                  || [error.domain isEqualToString:NSOSStatusErrorDomain];
    if (!coreMedia) return 0;
    switch (error.code) {
        case -12938: return 404;
        case -12668: return 410;
        case -12660: return 403;
        default: break;
    }
    NSString *text = error.userInfo[@"NSDescription"];
    if (![text isKindOfClass:[NSString class]]) text = error.localizedDescription;
    NSRange marker = [text rangeOfString:@"HTTP "];
    if (marker.location == NSNotFound || NSMaxRange(marker) + 3 > text.length) return 0;
    NSString *digits = [text substringWithRange:NSMakeRange(NSMaxRange(marker), 3)];
    NSInteger status = 0;
    NSScanner *scanner = [NSScanner scannerWithString:digits];
    if (![scanner scanInteger:&status] || !scanner.isAtEnd) return 0;
    return status >= 100 && status <= 599 ? status : 0;
}

ApolloRedgifsFailure ApolloRedgifsFailureForMediaError(NSError *error) {
    NSInteger status = 0;
    BOOL transport = NO;
    NSError *current = error;
    for (NSUInteger depth = 0; current && depth < 8; depth++) {
        if (ApolloRedgifsIsTransportError(current)) transport = YES;
        if (status == 0) status = ApolloRedgifsHTTPStatusInMediaError(current);
        id underlying = current.userInfo[NSUnderlyingErrorKey];
        current = [underlying isKindOfClass:[NSError class]] ? underlying : nil;
    }
    if (status >= 400) return ApolloRedgifsFailureForHTTPStatus(status);
    if (transport) return ApolloRedgifsMakeFailure(ApolloRedgifsFailureKindUnreachable, 0);
    // AVFoundation's own NSURLErrorDomain reading of the status, for when no
    // underlying CoreMedia error carries it.
    if ([error.domain isEqualToString:NSURLErrorDomain]) {
        if (error.code == NSURLErrorFileDoesNotExist) return ApolloRedgifsFailureForHTTPStatus(404);
        if (error.code == NSURLErrorNoPermissionsToReadFile) return ApolloRedgifsFailureForHTTPStatus(403);
    }
    return ApolloRedgifsMakeFailure(ApolloRedgifsFailureKindNone, 0);
}

NSString *ApolloRedgifsCardTitleForFailure(ApolloRedgifsFailure failure) {
    switch (failure.kind) {
        case ApolloRedgifsFailureKindDeleted:
            return @"Removed from RedGIFs";
        case ApolloRedgifsFailureKindNotFound:
            return @"Not found on RedGIFs";
        case ApolloRedgifsFailureKindRegion:
            return @"RedGIFs isn't available in your region";
        case ApolloRedgifsFailureKindUnreachable:
            return @"Can't reach RedGIFs";
        case ApolloRedgifsFailureKindImage:
            return @"Can't show RedGIFs images";
        case ApolloRedgifsFailureKindHTTPStatus:
            return failure.httpStatus > 0 ? [NSString stringWithFormat:@"RedGIFs error (HTTP %ld)", (long)failure.httpStatus] : nil;
        case ApolloRedgifsFailureKindNone:
            return nil;
    }
    return nil;
}

static BOOL ApolloRedgifsIsWordCharacter(unichar c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

static BOOL ApolloRedgifsIsWord(NSString *string) {
    if (string.length == 0) return NO;
    for (NSUInteger i = 0; i < string.length; i++) {
        if (!ApolloRedgifsIsWordCharacter([string characterAtIndex:i])) return NO;
    }
    return YES;
}

NSString *ApolloRedgifsIDFromPostURL(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"http"]) return nil;
    NSString *host = url.host.lowercaseString;
    if (![host isEqualToString:@"redgifs.com"] && ![host hasSuffix:@".redgifs.com"]) return nil;

    // "/", then the segments. Apollo's pattern allows one optional prefix
    // segment (watch, ifr, gifs/detail, or a two-letter language code) as long
    // as something follows it.
    NSArray<NSString *> *parts = url.pathComponents;
    NSUInteger index = 1;
    if (parts.count > index + 1) {
        NSString *first = parts[index].lowercaseString;
        if ([first isEqualToString:@"watch"] || [first isEqualToString:@"ifr"]
            || (first.length == 2 && ApolloRedgifsIsWord(first))) {
            index += 1;
        } else if ([first isEqualToString:@"gifs"] && parts.count > index + 2
                   && [parts[index + 1].lowercaseString isEqualToString:@"detail"]) {
            index += 2;
        }
    }
    if (parts.count <= index) return nil;

    // The id is the segment's leading word characters ("<id>-some-title").
    NSString *segment = parts[index];
    NSUInteger length = 0;
    while (length < segment.length && ApolloRedgifsIsWordCharacter([segment characterAtIndex:length])) length++;
    return length > 0 ? [segment substringToIndex:length].lowercaseString : nil;
}

NSString *ApolloRedgifsIDFromLookupURL(NSURL *url) {
    if (![url.host.lowercaseString isEqualToString:@"api.redgifs.com"]) return nil;
    // "/", "v2", "gifs", "<id>": a single gif, not /v2/gifs/search.
    NSArray<NSString *> *parts = url.pathComponents;
    if (parts.count != 4 || ![parts[1] isEqualToString:@"v2"] || ![parts[2] isEqualToString:@"gifs"]) return nil;
    NSString *gifID = parts[3].lowercaseString;
    return ApolloRedgifsIsWord(gifID) && ![gifID isEqualToString:@"search"] ? gifID : nil;
}
