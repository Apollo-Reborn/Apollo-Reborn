#import "settings/ApolloRateLimitSettingsViewController.h"

#import "settings/ApolloBudgetPauseCell.h"
#import "ApolloRateLimitMeter.h"
#import "ApolloReduceRateLimiting.h"
#import "ApolloState.h"
#import "ApolloWebJSONBudget.h"
#import "ApolloWebSessionStore.h"
#import "UserDefaultConstants.h"

static NSString *const kApolloRateLimitRowReduce = @"rateLimit.reduce";
static NSString *const kApolloRateLimitRowPauseAt = @"rateLimit.pauseAt";

// Reddit's budget for the account the slider is about: the active
// API-Key-Free one. 100 until Reddit has reported on it.
static double ApolloRateLimitSettingsLimit(void) {
    ApolloWebJSONBudgetState state = ApolloWebJSONBudgetCurrent(ApolloActiveWebSessionUsername());
    return state.known && state.limit > 0 ? state.limit : 100.0;
}

@implementation ApolloRateLimitSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Rate Limit";
    // The one-time offer can switch Reduce Rate Limiting on from its alert
    // while this screen is up (it presents wherever the user is), so follow
    // the setting directly.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(apollo_reduceRateLimitingDidChange:)
                                                 name:ApolloReduceRateLimitingDidChangeNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)apollo_reduceRateLimitingDidChange:(NSNotification *)notification {
    (void)notification;
    // Move the switch in place when the change came from somewhere else: a
    // reload would cut its own animation short when it came from a tap on it.
    UISwitch *toggle = (UISwitch *)[self cellForRowID:kApolloRateLimitRowReduce].accessoryView;
    if ([toggle isKindOfClass:[UISwitch class]] && toggle.isOn != sReduceRateLimiting) {
        [toggle setOn:sReduceRateLimiting animated:YES];
    }
    // The Pause Extras At slider only exists while the switch is on.
    [self visibilityDidChange];
}

- (UITableViewCell *)pauseExtrasCellForTableView:(UITableView *)tableView {
    static NSString *const identifier = @"Cell_RateLimit_PauseExtrasAt";
    ApolloBudgetPauseCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[ApolloBudgetPauseCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    cell.valueText = ^NSString *(NSInteger stop) {
        if (stop >= ApolloReduceRateLimitingPauseAtMaximum) return @"Only at the limit";
        double limit = ApolloRateLimitSettingsLimit();
        return [NSString stringWithFormat:@"%ld of %ld", lround(limit * (double)stop / 100.0), lround(limit)];
    };
    cell.statusText = ^NSString *{
        // The row is only up while the switch is on, so "not active" here
        // means the account in use isn't an API-Key-Free one.
        if (!ApolloReduceRateLimitingActive()) return @"Now: this account uses an API key, so nothing is paused";
        NSString *status = ApolloWebJSONBudgetStatusText(ApolloActiveWebSessionUsername());
        return status ? [@"Now: " stringByAppendingString:status] : @"Now: nothing reported in this 10 minutes yet";
    };
    cell.onCommit = ^(NSInteger stop) {
        ApolloReduceRateLimitingSetPauseAt(stop);
    };
    [cell configureWithTitle:@"Pause Extras At"
                      detail:@"Once this many of Reddit's 100 requests are used, profile pictures, link previews, subreddit headers and icons, and Community Highlights stop loading until the 10 minutes reset. Posts and comments keep loading."
                        stop:sReduceRateLimitingPauseAt
                     minimum:ApolloReduceRateLimitingPauseAtMinimum
                     maximum:ApolloReduceRateLimitingPauseAtMaximum
                        step:ApolloReduceRateLimitingPauseAtStep
                      accent:[self apollo_themeAccentColor]];
    return cell;
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak typeof(self) weakSelf = self;

    // Reddit gives API-key-free accounts a much smaller request budget, so this
    // trades a little polish for fewer requests while one is active (see
    // ApolloReduceRateLimiting.h). Offered once at the first API-key-free
    // sign-in. Its change notification (observed above) shows or hides the
    // slider, whoever flipped it.
    ApolloSettingsRow *reduce =
        [ApolloSettingsRow switchRowWithID:kApolloRateLimitRowReduce
                                     title:@"Reduce Rate Limiting"
                                      isOn:^BOOL { return sReduceRateLimiting; }
                                  onToggle:^(UISwitch *sender) {
            ApolloReduceRateLimitingSetEnabled(sender.isOn);
        }];

    // How much of the ten-minute budget may be used before the optional
    // lookups stop for the rest of it (ApolloWebJSONOptionalReadPause).
    ApolloSettingsRow *pauseAt =
        [ApolloSettingsRow customRowWithID:kApolloRateLimitRowPauseAt
                                      cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
            return [weakSelf pauseExtrasCellForTableView:tableView]
                ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];
    pauseAt.visible = ^BOOL { return sReduceRateLimiting; };

    // Two optional ways to watch the same budget (ApolloRateLimitMeter.h).
    // Neither depends on Reduce Rate Limiting being on.
    ApolloSettingsRow *warnings =
        [ApolloSettingsRow switchRowWithID:@"rateLimit.warnings"
                                     title:@"Rate Limit Warnings"
                                      isOn:^BOOL { return sRateLimitWarnings; }
                                  onToggle:^(UISwitch *sender) {
            sRateLimitWarnings = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sRateLimitWarnings forKey:UDKeyRateLimitWarnings];
            ApolloRateLimitMeterSettingsChanged();
        }];

    ApolloSettingsRow *meter =
        [ApolloSettingsRow switchRowWithID:@"rateLimit.meter"
                                     title:@"Rate Limit Meter"
                                      isOn:^BOOL { return sRateLimitMeter; }
                                  onToggle:^(UISwitch *sender) {
            sRateLimitMeter = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sRateLimitMeter forKey:UDKeyRateLimitMeter];
            // Up or gone at once: the meter never outlives its switch.
            ApolloRateLimitMeterSettingsChanged();
        }];

    return @[
        [ApolloSettingsSection sectionWithTitle:nil
                                         footer:@"Reddit limits API-key-free accounts more tightly. This uses fewer requests: profile pictures load in batches (without frames), Community Highlights refresh every 30 minutes, and your sign-in is checked less often."
                                           rows:@[ reduce, pauseAt ]],
        [ApolloSettingsSection sectionWithTitle:nil
                                         footer:@"Shows a notice when you've used 50, 75 and 90 of Reddit's 100 requests, and when extras pause."
                                           rows:@[ warnings ]],
        [ApolloSettingsSection sectionWithTitle:nil
                                         footer:@"A small floating gauge with the live count, green to red. Drag it anywhere; tap it for the time left.\n\nAll of this is for accounts signed in without an API key. An account with its own key has a far larger allowance, so nothing here applies while you're using one."
                                           rows:@[ meter ]],
    ];
}

@end
