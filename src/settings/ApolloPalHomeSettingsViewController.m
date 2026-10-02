#import "ApolloPalHomeSettingsViewController.h"
#import "palhome/ApolloPalHomeStore.h"
#import "palhome/ApolloPalHomeViewController.h"

@implementation ApolloPalHomeSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Pal Home";
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak __typeof(self) weakSelf = self;
    ApolloSettingsRow *toggle =
        [ApolloSettingsRow switchRowWithID:@"enabled"
                                     title:@"Use Pal Home"
                                      isOn:^BOOL { return ApolloPalHomeStore.isPalHomeEnabled; }
                                  onToggle:^(UISwitch *sender) {
            // Off runs the clean switch back (see -[ApolloPalHomeStore returnToClassic]).
            ApolloPalHomeStore.palHomeEnabled = sender.isOn;
            [weakSelf reloadRowWithID:@"open"];
        }];
    ApolloSettingsRow *open =
        [ApolloSettingsRow buttonRowWithID:@"open"
                                     title:@"Open Pal Home"
                                    action:^{
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            // Trying it is choosing it: switch on, then step inside.
            if (!ApolloPalHomeStore.isPalHomeEnabled) {
                ApolloPalHomeStore.palHomeEnabled = YES;
                [strongSelf reloadRowWithID:@"enabled"];
            }
            [strongSelf.navigationController pushViewController:[ApolloPalHomeViewController new] animated:YES];
        }];
    open.configure = ^(UITableViewCell *cell) {
        cell.textLabel.text = ApolloPalHomeStore.isPalHomeEnabled ? @"Open Pal Home" : @"Try Pal Home";
    };
    return @[
        [ApolloSettingsSection sectionWithTitle:nil
            footer:@"Pal Home replaces Apollo's Pixel Pals care sheet and settings with a cosy home for every Pal: "
                    "feed and play with them, decorate their rooms, adopt new friends. It uses your existing Pals, "
                    "food and hearts.\n\nTurn it off any time to get Apollo's Classic Pixel Pals back. Your homes and "
                    "adopted Pals are kept for next time. Showing your Pal on the Dynamic Island is a separate setting."
            rows:@[toggle]],
        [ApolloSettingsSection sectionWithTitle:nil footer:nil rows:@[open]],
    ];
}

@end
