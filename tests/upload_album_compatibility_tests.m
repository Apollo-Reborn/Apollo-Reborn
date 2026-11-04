#import <Foundation/Foundation.h>
#import "ApolloUploadAlbumCompatibility.h"

static NSUInteger checks;
static void Check(BOOL passed, NSString *message) {
    checks++;
    if (!passed) { NSLog(@"FAIL: %@", message); exit(1); }
}

static NSArray *Tokens(NSString *body) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.imgur.com/3/album"]];
    request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    return ApolloUploadAlbumTokens(request);
}

int main(void) {
    @autoreleasepool {
        Check([Tokens(@"deletehashes=one") isEqual:@[@"one"]], @"single photo still makes an album");
        Check([Tokens(@"deletehashes=one,two") isEqual:@[@"one", @"two"]], @"native Apollo body order");
        Check([Tokens(@"deletehashes=one%2Ctwo&title=ignored") isEqual:@[@"one", @"two"]], @"encoded list with extra fields");
        Check([Tokens(@"deletehashes%5B%5D=one&deletehashes%5B%5D=two") isEqual:@[@"one", @"two"]], @"encoded repeated keys");
        Check([Tokens(@"ids[]=one&ids[]=one&ids[]=two") isEqual:@[@"one", @"two"]], @"deduplicated repeated keys");
        Check([Tokens(@"{\"deletehashes\":[\"one\",\"two\"]}") isEqual:@[@"one", @"two"]], @"JSON array");
        Check([Tokens(@"{\"ids\":\"one,two\"}") isEqual:@[@"one", @"two"]], @"JSON string");
        Check([Tokens(@"{\"images\":[{\"deletehash\":\"one\",\"id\":\"other\",\"link\":\"https://example.com/one\"},{\"id\":\"two\"}]}") isEqual:@[@"one", @"two"]], @"one token per JSON image");
        Check(Tokens(@"notdeletehashes=one&title=ids=two").count == 0, @"unrelated keys do not claim uploads");
        Check(Tokens(@"deletehashes=").count == 0, @"empty album passes through");
        NSDictionary *owned = @{@"one": @"asset1", @"two": @"asset2", @"one.jpg": @"asset1"};
        NSString *(^resolve)(NSString *) = ^NSString *(NSString *token) { return owned[token]; };
        Check([ApolloUploadAlbumResolveMembers(Tokens(@"deletehashes=one"), resolve) isEqual:@[@"asset1"]], @"claim a one-image Reddit album");
        Check([ApolloUploadAlbumResolveMembers(Tokens(@"deletehashes=two,one"), resolve) isEqual:@[@"asset2", @"asset1"]], @"retain picker order");
        Check([ApolloUploadAlbumResolveMembers(Tokens(@"deletehashes=one,one.jpg"), resolve) isEqual:@[@"asset1"]], @"duplicate aliases do not duplicate images");
        Check(ApolloUploadAlbumResolveMembers(Tokens(@"deletehashes=one,foreign"), resolve) == nil, @"mixed host album cannot silently lose an image");
        Check(ApolloUploadAlbumResolveMembers(@[], resolve) == nil, @"never synthesize empty album");

        NSString *native = @"https://reddit-uploaded-media.s3-accelerate.amazonaws.com/one\n\nhttps://reddit-uploaded-media.s3-accelerate.amazonaws.com/two";
        NSDictionary *albums = @{@"arg123": native, @"chest123": @"https://imgchest.com/p/chest123"};
        NSString *(^replacement)(NSString *) = ^NSString *(NSString *albumID) { return albums[albumID]; };
        Check([ApolloUploadAlbumResolveText(@"https://imgur.com/a/arg123/", replacement, NULL) isEqual:native], @"native completion's trailing slash");
        Check([ApolloUploadAlbumResolveText(@"Before [Album](https://imgur.com/a/arg123/) after", replacement, NULL) isEqual:[NSString stringWithFormat:@"Before %@ after", native]], @"expand whole markdown link without nesting");
        Check([ApolloUploadAlbumResolveText(@"![img](https://imgur.com/a/arg123)", replacement, NULL) isEqual:native], @"expand whole embed");
        Check([ApolloUploadAlbumResolveText(@"[Album](https://imgur.com/a/chest123/)", replacement, NULL) isEqual:albums[@"chest123"]], @"Image Chest public album link");
        NSString *two = @"https://imgur.com/a/chest123/ and https://imgur.com/a/arg123/";
        NSString *resolved = ApolloUploadAlbumResolveText(two, replacement, NULL);
        Check([resolved isEqual:[NSString stringWithFormat:@"%@ and %@", albums[@"chest123"], native]], @"multiple replacements do not shift ranges");
        Check([ApolloUploadAlbumResolveText(resolved, replacement, NULL) isEqual:resolved], @"idempotent across text view and submit adapters");
        NSString *link = @"https://imgur.com/a/arg123/";
        NSRange caret = NSMakeRange(link.length, 0);
        ApolloUploadAlbumResolveText(link, replacement, &caret);
        Check(NSEqualRanges(caret, NSMakeRange(native.length, 0)), @"caret follows expanded album");
        caret = NSMakeRange(0, 0);
        ApolloUploadAlbumResolveText(link, replacement, &caret);
        Check(NSEqualRanges(caret, NSMakeRange(0, 0)), @"caret before album stays in place");
        caret = NSMakeRange(0, link.length);
        ApolloUploadAlbumResolveText(link, replacement, &caret);
        Check(NSEqualRanges(caret, NSMakeRange(0, native.length)), @"selection covers expanded album");
        caret = NSMakeRange(two.length, 0);
        ApolloUploadAlbumResolveText(two, replacement, &caret);
        Check(NSEqualRanges(caret, NSMakeRange(resolved.length, 0)), @"caret follows several replacements");
        caret = NSMakeRange(10, 0);
        ApolloUploadAlbumResolveText(link, replacement, &caret);
        Check(NSEqualRanges(caret, NSMakeRange(native.length, 0)), @"caret inside an owned URL moves to its replacement end");
        for (NSString *untouched in @[@"https://imgur.com/a/realAlbum/", @"[Custom](https://imgur.com/a/realAlbum/)", @"https://imgur.com/a/arg123extra/", @"https://imgur.com/a/arg123/other", @"https://imgur.com/a/arg123?query=yes", @"https://evilimgur.com/a/arg123/", @"https://i.imgur.com/arg123.jpg", @"typed text"]) {
            Check([ApolloUploadAlbumResolveText(untouched, replacement, NULL) isEqual:untouched], @"leave unrelated/extended URLs unchanged");
        }
        printf("PASS: %lu upload album compatibility checks\n", (unsigned long)checks);
    }
    return 0;
}
