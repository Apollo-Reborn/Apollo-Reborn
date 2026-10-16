#import "ApolloUploadAlbumCompatibility.h"

static NSString *ApolloUploadAlbumDecode(NSString *value) {
    NSString *spaces = [value stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    return spaces.stringByRemovingPercentEncoding ?: spaces;
}

static void ApolloUploadAlbumAppendTokens(id value, NSMutableArray<NSString *> *tokens) {
    if ([value isKindOfClass:NSString.class]) {
        for (NSString *piece in [value componentsSeparatedByString:@","]) {
            NSString *token = [piece stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (token.length && ![tokens containsObject:token]) [tokens addObject:token];
        }
    } else if ([value isKindOfClass:NSArray.class]) {
        for (id item in value) ApolloUploadAlbumAppendTokens(item, tokens);
    } else if ([value isKindOfClass:NSDictionary.class]) {
        // Each image object contributes one identifier, not its id AND link.
        for (NSString *key in @[@"deletehash", @"id", @"link", @"url", @"media_id"]) {
            id token = value[key];
            if ([token isKindOfClass:NSString.class] && [token length]) {
                ApolloUploadAlbumAppendTokens(token, tokens);
                break;
            }
        }
    }
}

NSArray<NSString *> *ApolloUploadAlbumTokens(NSURLRequest *request) {
    NSData *body = request.HTTPBody;
    if (!body.length) return @[];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    NSArray *keys = @[@"deletehashes", @"ids", @"images", @"image_ids"];
    id json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    if ([json isKindOfClass:NSDictionary.class]) {
        for (NSString *key in keys) ApolloUploadAlbumAppendTokens(json[key], tokens);
        return tokens;
    }
    if ([json isKindOfClass:NSArray.class]) {
        ApolloUploadAlbumAppendTokens(json, tokens);
        return tokens;
    }
    NSString *form = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    for (NSString *pair in [form componentsSeparatedByString:@"&"]) {
        NSRange equals = [pair rangeOfString:@"="];
        if (equals.location == NSNotFound) continue;
        NSString *key = ApolloUploadAlbumDecode([pair substringToIndex:equals.location]);
        if ([key hasSuffix:@"[]"]) key = [key substringToIndex:key.length - 2];
        if (![keys containsObject:key]) continue;
        ApolloUploadAlbumAppendTokens(ApolloUploadAlbumDecode([pair substringFromIndex:equals.location + 1]), tokens);
    }
    return tokens;
}

NSArray<NSString *> *ApolloUploadAlbumResolveMembers(NSArray<NSString *> *tokens,
    NSString *(^resolve)(NSString *)) {
    if (!tokens.count) return nil;
    NSMutableArray<NSString *> *members = [NSMutableArray array];
    for (NSString *token in tokens) {
        NSString *member = resolve(token);
        if (!member.length) return nil;
        if (![members containsObject:member]) [members addObject:member];
    }
    return members;
}

NSString *ApolloUploadAlbumResolveText(NSString *text, NSString *(^replacementForAlbum)(NSString *), NSRange *selection) {
    if (!text.length || [text rangeOfString:@"imgur.com" options:NSCaseInsensitiveSearch].location == NSNotFound) return text;
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Groups 1/2 are album IDs in markdown/bare links. Match a complete ID
        // and URL boundary: an owned ID must never match a longer unrelated ID.
        NSString *url = @"https?://(?:www\\.|m\\.)?imgur\\.com/(?:a|gallery)/([A-Za-z0-9]+)(?:/)?";
        NSString *pattern = [NSString stringWithFormat:@"!?\\[[^\\]\\n]*\\]\\(%@\\)|%@(?![A-Za-z0-9/?#])", url, url];
        regex = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
    });
    NSMutableString *rewritten = [text mutableCopy];
    for (NSTextCheckingResult *match in [[regex matchesInString:text options:0 range:NSMakeRange(0, text.length)] reverseObjectEnumerator]) {
        NSRange albumRange = [match rangeAtIndex:1];
        if (albumRange.location == NSNotFound) albumRange = [match rangeAtIndex:2];
        NSString *replacement = replacementForAlbum([text substringWithRange:albumRange]);
        if (!replacement.length) continue;
        if (selection && selection->location != NSNotFound) {
            NSUInteger endpoints[] = { selection->location, NSMaxRange(*selection) };
            for (NSUInteger i = 0; i < 2; i++) {
                if (endpoints[i] >= NSMaxRange(match.range)) {
                    endpoints[i] = endpoints[i] - match.range.length + replacement.length;
                } else if (endpoints[i] > match.range.location) {
                    endpoints[i] = match.range.location + replacement.length;
                }
            }
            *selection = NSMakeRange(endpoints[0], endpoints[1] - endpoints[0]);
        }
        [rewritten replaceCharactersInRange:match.range withString:replacement];
    }
    return rewritten;
}
