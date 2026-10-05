#import "ApolloPalHomeSettingsViewController.h"
#import "palhome/ApolloPalHomeStore.h"
#import "palhome/ApolloPalHomeViewController.h"
#import "palhome/ApolloPalHomeChatHead.h"

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
            [weakSelf visibilityDidChange];
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
            // Opened from inside Pal Home (the Pal card's Settings): just go back.
            NSArray *stack = strongSelf.navigationController.viewControllers;
            NSUInteger index = [stack indexOfObject:strongSelf];
            if (index != NSNotFound && index > 0 && [stack[index - 1] isKindOfClass:ApolloPalHomeViewController.class]) {
                [strongSelf.navigationController popViewControllerAnimated:YES];
                return;
            }
            [strongSelf.navigationController pushViewController:[ApolloPalHomeViewController new] animated:YES];
        }];
    open.configure = ^(UITableViewCell *cell) {
        cell.textLabel.text = ApolloPalHomeStore.isPalHomeEnabled ? @"Open Pal Home" : @"Try Pal Home";
    };
    ApolloSettingsRow *floating =
        [ApolloSettingsRow switchRowWithID:@"floating"
                                     title:@"Floating Pal"
                                      isOn:^BOOL { return [NSUserDefaults.standardUserDefaults boolForKey:ApolloPalChatHeadEnabledKey]; }
                                  onToggle:^(UISwitch *sender) {
            [NSUserDefaults.standardUserDefaults setBool:sender.isOn forKey:ApolloPalChatHeadEnabledKey];
            ApolloPalChatHeadRefresh();
        }];
    floating.visible = ^BOOL { return ApolloPalHomeStore.isPalHomeEnabled; };
    ApolloSettingsSection *floatingSection = [ApolloSettingsSection sectionWithTitle:nil
        footer:@"Your island Pal floats over Apollo in a little bubble, chat-head style, and trots along as you scroll. "
                "Tap it for Pal Home. Drag it anywhere, or drop it on the cross to put it away."
        rows:@[floating]];
    floatingSection.visible = ^BOOL { return ApolloPalHomeStore.isPalHomeEnabled; };
    return @[
        [ApolloSettingsSection sectionWithTitle:nil
            footer:@"Pal Home replaces Apollo's Pixel Pals care sheet and settings with a cosy home for every Pal: "
                    "feed and play with them, decorate their rooms, adopt new friends. It uses your existing Pals, "
                    "food and hearts.\n\nTurn it off any time to get Apollo's Classic Pixel Pals back. Your homes and "
                    "adopted Pals are kept for next time. Showing your Pal on the Dynamic Island is a separate setting."
            rows:@[toggle]],
        floatingSection,
        [ApolloSettingsSection sectionWithTitle:nil footer:nil rows:@[open]],
    ];
}

@end
