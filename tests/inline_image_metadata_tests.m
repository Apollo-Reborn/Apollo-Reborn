#import <Foundation/Foundation.h>
#import "ApolloInlineImageMetadata.h"

#import <dispatch/dispatch.h>
#import <math.h>
#import <stdatomic.h>

static _Atomic NSUInteger checks;

static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static void CheckRatio(double actual, double expected, NSString *message) {
    Check(fabs(actual - expected) < 0.000001,
          [NSString stringWithFormat:@"%@ (actual %.6f, expected %.6f)",
                                     message, actual, expected]);
}

int main(void) {
    @autoreleasepool {
        NSDictionary *nativeImage = @{
            @"asset": @{
                @"status": @"valid",
                @"e": @"Image",
                @"s": @{
                    @"x": @1200,
                    @"y": @900,
                    @"u": @"https://i.redd.it/asset.jpeg",
                },
            },
        };
        CheckRatio(ApolloInlineImageAspectRatioFromMediaMetadata(
                       [NSURL URLWithString:@"https://preview.redd.it/asset.jpeg?width=640&crop=smart"],
                       nativeImage),
                   0.75,
                   @"asset ID match uses source dimensions before download");

        NSDictionary *opaqueKey = @{
            @"different-key": @{
                @"status": @"valid",
                @"e": @"Image",
                @"s": @{
                    @"x": @800,
                    @"y": @1200,
                    @"u": @"https://i.redd.it/path-match.png?foo=1&amp;bar=2",
                },
            },
        };
        CheckRatio(ApolloInlineImageAspectRatioFromMediaMetadata(
                       [NSURL URLWithString:@"https://i.redd.it/path-match.png?bar=changed"],
                       opaqueKey),
                   1.5,
                   @"matching Reddit source path can identify an opaque metadata key");

        NSDictionary *previewOnly = @{
            @"preview-only": @{
                @"status": @"valid",
                @"e": @"Image",
                @"s": @{ @"u": @"https://i.redd.it/preview-only.jpg" },
                @"p": @[
                    @{ @"x": @108, @"y": @72,
                       @"u": @"https://preview.redd.it/preview-only.jpg?width=108" },
                    @{ @"x": @432, @"y": @288,
                       @"u": @"https://preview.redd.it/preview-only.jpg?width=432" },
                ],
            },
        };
        CheckRatio(ApolloInlineImageAspectRatioFromMediaMetadata(
                       [NSURL URLWithString:@"https://preview.redd.it/preview-only.jpg?width=432"],
                       previewOnly),
                   2.0 / 3.0,
                   @"largest valid preview dimensions backstop a source without dimensions");

        NSDictionary *unrelated = @{
            @"other": @{
                @"status": @"valid",
                @"e": @"Image",
                @"s": @{ @"x": @100, @"y": @400,
                          @"u": @"https://i.redd.it/other.jpg" },
            },
        };
        CheckRatio(ApolloInlineImageAspectRatioFromMediaMetadata(
                       [NSURL URLWithString:@"https://i.redd.it/wanted.jpg"], unrelated),
                   0.0,
                   @"unrelated metadata cannot size a Reddit image");

        NSDictionary *ambiguous = @{
            @"one": @{
                @"status": @"valid", @"e": @"Image",
                @"s": @{ @"x": @100, @"y": @100,
                          @"u": @"https://i.redd.it/shared.jpg" },
            },
            @"two": @{
                @"status": @"valid", @"e": @"Image",
                @"s": @{ @"x": @100, @"y": @200,
                          @"u": @"https://preview.redd.it/shared.jpg" },
            },
        };
        CheckRatio(ApolloInlineImageAspectRatioFromMediaMetadata(
                       [NSURL URLWithString:@"https://i.redd.it/shared.jpg"], ambiguous),
                   0.0,
                   @"ambiguous metadata does not guess a first-layout size");

        NSDictionary *externalExactMatch = @{
            @"external": @{
                @"status": @"valid",
                @"e": @"Image",
                @"s": @{ @"x": @300, @"y": @600,
                          @"u": @"https://images.example.com/external.jpg" },
            },
        };
        CheckRatio(ApolloInlineImageAspectRatioFromMediaMetadata(
                       [NSURL URLWithString:@"https://images.example.com/external.jpg"],
                       externalExactMatch),
                   0.0,
                   @"external images retain the existing load-then-layout behavior");

        NSDictionary *invalid = @{
            @"bad": @{
                @"status": @"failed",
                @"e": @"Image",
                @"s": @{ @"x": @300, @"y": @600,
                          @"u": @"https://i.redd.it/bad.jpg" },
            },
        };
        CheckRatio(ApolloInlineImageAspectRatioFromMediaMetadata(
                       [NSURL URLWithString:@"https://i.redd.it/bad.jpg"], invalid),
                   0.0,
                   @"failed metadata is not trusted for first layout");

        ApolloInlineImageRegisterMediaMetadata(nativeImage);
        ApolloInlineImageRegisterMediaMetadata(invalid);
        CheckRatio(ApolloInlineImageAspectRatioFromRegisteredMetadata(
                       [NSURL URLWithString:@"https://preview.redd.it/asset.jpeg?width=640&crop=smart"]),
                   0.75,
                   @"registered parse-time metadata sizes an image without a reachable host");
        CheckRatio(ApolloInlineImageAspectRatioFromRegisteredMetadata(
                       [NSURL URLWithString:@"https://i.redd.it/bad.jpg"]),
                   0.0,
                   @"failed metadata is never registered");
        CheckRatio(ApolloInlineImageAspectRatioFromRegisteredMetadata(
                       [NSURL URLWithString:@"https://i.redd.it/never-registered.jpg"]),
                   0.0,
                   @"unregistered assets keep the load-then-layout behavior");
        CheckRatio(ApolloInlineImageAspectRatioFromRegisteredMetadata(
                       [NSURL URLWithString:@"https://images.example.com/asset.jpeg"]),
                   0.0,
                   @"registered asset IDs never size external hosts");

        NSDictionary *replacement = @{
            @"asset": @{
                @"status": @"valid",
                @"e": @"Image",
                @"s": @{ @"x": @400, @"y": @800 },
            },
        };
        ApolloInlineImageRegisterMediaMetadata(replacement);
        CheckRatio(ApolloInlineImageAspectRatioFromRegisteredMetadata(
                       [NSURL URLWithString:@"https://i.redd.it/asset.png"]),
                   2.0,
                   @"a later valid parse deterministically replaces stale dimensions");

        NSDictionary *invalidReplacement = @{
            @"asset": @{
                @"status": @"failed",
                @"e": @"Image",
                @"s": @{ @"x": @100, @"y": @100 },
            },
        };
        ApolloInlineImageRegisterMediaMetadata(invalidReplacement);
        CheckRatio(ApolloInlineImageAspectRatioFromRegisteredMetadata(
                       [NSURL URLWithString:@"https://i.redd.it/asset.png"]),
                   2.0,
                   @"invalid later metadata cannot erase or replace a known ratio");

        // Model parsing and Texture layout both occur off-main. Exercise the
        // public registry concurrently with unique asset IDs so the test does
        // not depend on scheduling order while still covering read/write races.
        dispatch_apply(64, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
                       ^(size_t index) {
            NSString *assetID = [NSString stringWithFormat:@"concurrent-%zu", index];
            ApolloInlineImageRegisterMediaMetadata(@{
                assetID: @{
                    @"status": @"valid",
                    @"e": @"Image",
                    @"s": @{ @"x": @200, @"y": @(100 + index) },
                },
            });
            NSURL *url = [NSURL URLWithString:
                [NSString stringWithFormat:@"https://i.redd.it/%@.jpg", assetID]];
            double expected = (100.0 + (double)index) / 200.0;
            CheckRatio(ApolloInlineImageAspectRatioFromRegisteredMetadata(url),
                       expected,
                       @"concurrent registration is immediately visible to lookup");
        });

        NSLog(@"PASS: %lu inline image metadata checks",
              (unsigned long)atomic_load(&checks));
    }
    return 0;
}
