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
    // Where your Pal lives while you browse: one place at a time.
    NSArray<NSString *> *(^places)(void) = ^NSArray<NSString *> * {
        return ApolloPalHomeStore.deviceHasDynamicIsland ? @[@"Dynamic Island", @"Tab Bar", @"Floating Bubble", @"Nowhere"]
                                                         : @[@"Tab Bar", @"Floating Bubble", @"Nowhere"];
    };
    NSInteger (^currentPlace)(void) = ^NSInteger {
        ApolloPalHomeStore *store = [ApolloPalHomeStore new];
        NSInteger offset = ApolloPalHomeStore.deviceHasDynamicIsland ? 0 : -1;
        return !store.islandEnabled ? (NSInteger)places().count - 1 : ApolloPalHomeStore.palDisplay + offset;
    };
    ApolloSettingsRow *floating =
        [ApolloSettingsRow valueRowWithID:@"floating"
                                    title:@"Show Your Pal"
                                   detail:^NSString * { return places()[MAX(0, currentPlace())]; }
                                 onSelect:^{
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            ApolloSettingsPresentPicker(strongSelf, [strongSelf cellForRowID:@"floating"], @"Show Your Pal", places(), currentPlace(), ^(NSInteger picked) {
                ApolloPalHomeStore *store = [ApolloPalHomeStore new];
                BOOL nowhere = picked == (NSInteger)places().count - 1;
                if (!nowhere) ApolloPalHomeStore.palDisplay = (APPalDisplay)(picked + (ApolloPalHomeStore.deviceHasDynamicIsland ? 0 : 1));
                store.islandEnabled = !nowhere;
                [weakSelf reloadRowWithID:@"floating"];
                if (!nowhere && ApolloPalHomeStore.palDisplayNeedsRelaunch) {
                    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Next Time You Open Apollo"
                        message:@"Moving your Pal between the Dynamic Island and the tab bar takes effect the next time Apollo starts."
                        preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                    [weakSelf presentViewController:alert animated:YES completion:nil];
                }
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
