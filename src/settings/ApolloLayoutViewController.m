#import "ApolloLayoutViewController.h"

#import "settings/ApolloProfileLayoutViewController.h"
#import "settings/ApolloSubredditLayoutViewController.h"
#import "ApolloState.h"

@implementation ApolloLayoutViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Layout";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    [self reloadRowWithID:@"layout.profile"];
    [self reloadRowWithID:@"layout.subreddit"];
}

- (NSString *)profileLayoutSummaryText {
    if (!sShowDetailedProfiles) {
        return @"Native";
    }

    return sProfileHeaderImmersive ? @"Immersive" : @"Compact";
}

- (NSString *)subredditLayoutSummaryText {
    NSString *layout;

    if (!sShowSubredditHeaders) {
        layout = @"Native";
    } else {
        layout = sSubredditHeaderImmersive ? @"Immersive" : @"Compact";
    }

    NSString *highlights;

    if (!sCommunityHighlights) {
        highlights = @"Off";
    } else if (sCommunityHighlightsWeb) {
        highlights = @"Full";
    } else {
        highlights = @"Partial";
    }

    return [NSString stringWithFormat:@"%@ · Highlights: %@", layout, highlights];
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak typeof(self) weakSelf = self;

    ApolloSettingsRow *profileLayout =
        [self hubDisclosureRowWithID:@"layout.profile"
                               title:@"Profile Layout"
                            subtitle:^NSString * {
        return [weakSelf profileLayoutSummaryText];
    }
                                push:^UIViewController * {
        return [[ApolloProfileLayoutViewController alloc]
            initWithStyle:UITableViewStyleInsetGrouped];
    }];

    ApolloSettingsRow *subredditLayout =
        [self hubDisclosureRowWithID:@"layout.subreddit"
                               title:@"Subreddit Layout"
                            subtitle:^NSString * {
        return [weakSelf subredditLayoutSummaryText];
    }
                                push:^UIViewController * {
        return [[ApolloSubredditLayoutViewController alloc]
            initWithStyle:UITableViewStyleInsetGrouped];
    }];

    return @[
        [ApolloSettingsSection sectionWithTitle:nil
                                         footer:nil
                                           rows:@[
            profileLayout,
            subredditLayout
        ]]
    ];
}

@end