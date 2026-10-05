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
    // Where your Pal lives while you browse: one place at a time, from what
    // this phone and build offer.
    NSArray<NSNumber *> *(^modes)(void) = ^NSArray<NSNumber *> * {
        NSMutableArray *list = [NSMutableArray array];
        if (ApolloPalHomeStore.deviceHasDynamicIsland) [list addObject:@(APPalDisplayIsland)];
        if (ApolloPalHomeStore.tabBarSupported) [list addObject:@(APPalDisplayTabBar)];
        [list addObject:@(APPalDisplayBubble)];
        [list addObject:@(-1)]; // nowhere
        return list;
    };
    NSArray<NSString *> *(^places)(void) = ^NSArray<NSString *> * {
        NSMutableArray *titles = [NSMutableArray array];
        for (NSNumber *mode in modes()) {
            NSInteger m = mode.integerValue;
            [titles addObject:m < 0 ? @"Nowhere" : @[@"Dynamic Island", @"Tab Bar", @"Floating Bubble"][m]];
        }
        return titles;
    };
    NSInteger (^currentPlace)(void) = ^NSInteger {
        NSInteger m = [ApolloPalHomeStore new].islandEnabled ? ApolloPalHomeStore.palDisplay : -1;
        NSUInteger index = [modes() indexOfObject:@(m)];
        return index == NSNotFound ? 0 : (NSInteger)index;
    };
    ApolloSettingsRow *floating =
        [ApolloSettingsRow valueRowWithID:@"floating"
                                    title:@"Show Your Pal"
                                   detail:^NSString * { return places()[currentPlace()]; }
                                 onSelect:^{
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            ApolloSettingsPresentPicker(strongSelf, [strongSelf cellForRowID:@"floating"], @"Show Your Pal", places(), currentPlace(), ^(NSInteger picked) {
                NSInteger m = modes()[picked].integerValue;
                if (m >= 0) ApolloPalHomeStore.palDisplay = (APPalDisplay)m;
                [ApolloPalHomeStore new].islandEnabled = m >= 0;
                [weakSelf reloadRowWithID:@"floating"];
            });
        }];
    ApolloSettingsSection *floatingSection = [ApolloSettingsSection sectionWithTitle:nil
        footer:@"Where your Pal lives while you browse. The floating bubble drifts over everything: drag it anywhere, "
                "tap it for Pal Home. It trots along as you scroll."
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
