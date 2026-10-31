#import "ApolloLocalFilterTransfer.h"

static const NSUInteger kApolloLocalFilterMaximumImportBytes = 256 * 1024;
static const NSUInteger kApolloLocalFilterMaximumImportEntries = 4096;

static NSString *ApolloLocalFilterNormalizeImportedName(id raw) {
    if (![raw isKindOfClass:NSString.class]) return nil;
    NSString *name = [(NSString *)raw stringByTrimmingCharactersInSet:
                      NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (name.length == 0) return nil;

    NSURLComponents *components = [NSURLComponents componentsWithString:name];
    NSString *host = components.host.lowercaseString;
    if (([host isEqualToString:@"reddit.com"] || [host isEqualToString:@"www.reddit.com"])
        && [components.path.lowercaseString hasPrefix:@"/r/"]) {
        name = [components.path substringFromIndex:3];
    }

    while ([name hasPrefix:@"/"]) name = [name substringFromIndex:1];
    if ([name.lowercaseString hasPrefix:@"r/"]) name = [name substringFromIndex:2];
    while ([name hasSuffix:@"/"]) name = [name substringToIndex:name.length - 1];
    NSString *lowercase = name.lowercaseString;

    // New subreddit names use Reddit's current 3–21 character rules. Apollo
    // archives can contain older short names or hyphenated values, so accept a
    // bounded legacy alphabet and preserve those strings verbatim on transfer.
    NSCharacterSet *currentAllowed = [NSCharacterSet characterSetWithCharactersInString:
                                      @"abcdefghijklmnopqrstuvwxyz0123456789_"];
    if (lowercase.length >= 3 && lowercase.length <= 21 &&
        [lowercase rangeOfCharacterFromSet:currentAllowed.invertedSet].location == NSNotFound) {
        return lowercase;
    }
    NSCharacterSet *legacyAllowed = [NSCharacterSet characterSetWithCharactersInString:
                                     @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"];
    if (name.length >= 1 && name.length <= 64 &&
        [name rangeOfCharacterFromSet:legacyAllowed.invertedSet].location == NSNotFound) {
        return name;
    }
    return nil;
}

static NSString *ApolloLocalFilterExistingKey(id raw) {
    if (![raw isKindOfClass:NSString.class]) return nil;
    NSString *key = [(NSString *)raw stringByTrimmingCharactersInSet:
                     NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    while ([key hasPrefix:@"/"]) key = [key substringFromIndex:1];
    if ([key hasPrefix:@"r/"]) key = [key substringFromIndex:2];
    while ([key hasSuffix:@"/"]) key = [key substringToIndex:key.length - 1];
    return key.length > 0 ? key : nil;
}

NSString *ApolloLocalFilterExportText(NSArray *storedNames) {
    if (![storedNames isKindOfClass:NSArray.class]) return @"";
    NSMutableOrderedSet<NSString *> *names = [NSMutableOrderedSet orderedSet];
    for (id raw in storedNames) {
        NSString *name = ApolloLocalFilterNormalizeImportedName(raw);
        if (name.length > 0) [names addObject:name];
    }
    return [names.array componentsJoinedByString:@"\n"];
}

NSArray *ApolloLocalFilterMergeImportText(NSArray *storedNames,
                                           NSString *text,
                                           NSUInteger *addedCount,
                                           NSUInteger *invalidCount,
                                           ApolloLocalFilterImportStatus *status) {
    NSArray *existing = [storedNames isKindOfClass:NSArray.class] ? storedNames : @[];
    if (addedCount) *addedCount = 0;
    if (invalidCount) *invalidCount = 0;
    if (status) *status = ApolloLocalFilterImportStatusSuccess;

    NSString *input = [text isKindOfClass:NSString.class] ? text : @"";
    if ([input lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >
        kApolloLocalFilterMaximumImportBytes) {
        if (status) *status = ApolloLocalFilterImportStatusTooManyBytes;
        return [existing copy];
    }

    NSMutableArray *merged = [NSMutableArray arrayWithCapacity:existing.count];
    NSMutableSet<NSString *> *known = [NSMutableSet setWithCapacity:existing.count];
    for (id raw in existing) {
        // Preserve the archive's existing values byte-for-byte; only the key
        // used for import de-duplication is normalized.
        [merged addObject:raw];
        NSString *key = ApolloLocalFilterExistingKey(raw);
        if (key.length > 0) [known addObject:key];
    }

    NSUInteger added = 0;
    NSUInteger invalid = 0;
    NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@"\n\r\t ,;"];
    NSUInteger tokenCount = 0;
    BOOL insideToken = NO;
    for (NSUInteger index = 0; index < input.length; index++) {
        BOOL isSeparator = [separators characterIsMember:[input characterAtIndex:index]];
        if (isSeparator) {
            insideToken = NO;
        } else if (!insideToken) {
            insideToken = YES;
            tokenCount++;
            if (tokenCount > kApolloLocalFilterMaximumImportEntries) {
                if (status) *status = ApolloLocalFilterImportStatusTooManyEntries;
                return [existing copy];
            }
        }
    }

    NSUInteger tokenStart = NSNotFound;
    NSUInteger inputLength = input.length;
    for (NSUInteger index = 0; index <= inputLength; index++) {
        BOOL atEnd = index == inputLength;
        BOOL isSeparator = !atEnd && [separators characterIsMember:[input characterAtIndex:index]];
        if (!atEnd && !isSeparator) {
            if (tokenStart == NSNotFound) tokenStart = index;
            continue;
        }
        if (tokenStart == NSNotFound) continue;
        NSString *token = [input substringWithRange:NSMakeRange(tokenStart, index - tokenStart)];
        tokenStart = NSNotFound;
        NSString *name = ApolloLocalFilterNormalizeImportedName(token);
        if (!name) {
            invalid++;
            continue;
        }
        NSString *key = ApolloLocalFilterExistingKey(name);
        if (key.length == 0 || [known containsObject:key]) continue;
        [known addObject:key];
        [merged addObject:name];
        added++;
    }
    if (addedCount) *addedCount = added;
    if (invalidCount) *invalidCount = invalid;
    return [merged copy];
}
