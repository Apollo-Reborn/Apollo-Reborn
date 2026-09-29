#import "ApolloSiriSettingsViewController.h"
#import "UserDefaultConstants.h"
#import <objc/message.h>

@interface ApolloSiriSettingsViewController ()
@property (nonatomic) BOOL busy;
@property (nonatomic, copy) NSString *statusText;
@end

@implementation ApolloSiriSettingsViewController

- (void)viewDidLoad {
    self.title = @"Siri & Spotlight";
    self.statusText = @"Checking index…";
    [super viewDidLoad];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!self.busy) [self runCommand:@"contentIndexStatusWithCompletion:" enabled:NO];
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak typeof(self) weakSelf = self;
    ApolloSettingsRow *enabled = [ApolloSettingsRow switchRowWithID:@"siri.enabled" title:@"Index Apollo Content"
        isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeySiriContentIndexing]; }
        onToggle:^(UISwitch *sender) { [weakSelf runCommand:@"setContentIndexing:completion:" enabled:sender.isOn]; }];
    enabled.enabled = ^BOOL { return !weakSelf.busy; };
    ApolloSettingsRow *refresh = [ApolloSettingsRow buttonRowWithID:@"siri.refresh" title:@"Refresh Subscribed Communities"
        action:^{ [weakSelf runCommand:@"refreshSubscriptionsWithCompletion:" enabled:NO]; }];
    refresh.enabled = ^BOOL { return !weakSelf.busy && [[NSUserDefaults standardUserDefaults] boolForKey:UDKeySiriContentIndexing]; };
    ApolloSettingsRow *status = [ApolloSettingsRow customRowWithID:@"siri.status"
        cell:^UITableViewCell *(UITableView *table, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:@"ApolloSiriStatus"];
            if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"ApolloSiriStatus"];
            cell.textLabel.text = weakSelf.statusText;
            cell.textLabel.numberOfLines = 0;
            cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
            cell.textLabel.adjustsFontForContentSizeCategory = YES;
            [weakSelf apollo_applyPrimaryTextColorToCell:cell];
            return cell;
        } onSelect:nil];
    ApolloSettingsRow *check = [ApolloSettingsRow buttonRowWithID:@"siri.check" title:@"Check Index Status"
        action:^{ [weakSelf runCommand:@"contentIndexStatusWithCompletion:" enabled:NO]; }];
    check.enabled = ^BOOL { return !weakSelf.busy; };
    return @[
        [ApolloSettingsSection sectionWithTitle:@"Searchable Content"
            footer:@"Makes eligible public, non-NSFW posts loaded in Apollo and subscribed communities searchable in Spotlight and Siri. Up to 1,000 posts and 500 communities are retained for 30 days. Turning off clears this index. Private and anonymous browsing are excluded."
            rows:@[enabled, refresh]],
        [ApolloSettingsSection sectionWithTitle:@"Index Status"
            footer:@"Search Apollo opens native search. Search Apollo Posts fetches Reddit results into a Siri card; Find Indexed Apollo Posts searches this device’s catalogue. Failed hide/unsubscribe requests still remove indexed content conservatively."
            rows:@[status, check]]
    ];
}

- (void)reloadControls {
    for (NSString *identifier in @[@"siri.enabled", @"siri.refresh", @"siri.status", @"siri.check"]) {
        [self reloadRowWithID:identifier];
    }
}

- (void)runCommand:(NSString *)name enabled:(BOOL)enabled {
    if (self.busy) return;
    Class bridge = NSClassFromString(@"ApolloContentBridge");
    SEL selector = NSSelectorFromString(name);
    if (![bridge respondsToSelector:selector]) {
        self.statusText = @"Siri integration is not available in this build.";
        [self reloadControls];
        return;
    }
    self.busy = YES;
    self.statusText = @"Updating index…";
    [self reloadControls];
    __weak typeof(self) weakSelf = self;
    void (^completion)(NSString *) = ^(NSString *status) {
        // Swift bridge guarantees main-actor completion; no UIKit on workers.
        weakSelf.busy = NO;
        weakSelf.statusText = status;
        [weakSelf reloadControls];
    };
    if ([name isEqualToString:@"setContentIndexing:completion:"]) {
        ((void (*)(id, SEL, BOOL, id))objc_msgSend)(bridge, selector, enabled, completion);
    } else {
        ((void (*)(id, SEL, id))objc_msgSend)(bridge, selector, completion);
    }
}
@end
