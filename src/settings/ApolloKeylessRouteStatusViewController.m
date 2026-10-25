#import "settings/ApolloKeylessRouteStatusViewController.h"

#import "ApolloCommon.h"
#import "ApolloToast.h"
#import "ApolloWebJSONRoutes.h"
#import "ApolloWebJSONRouteUpdates.h"
#import "ApolloWebSessionStore.h"
#import "ApolloState.h"

static NSString *ApolloRouteStatusAgo(NSTimeInterval at) {
    if (at <= 0) return nil;
    NSTimeInterval ago = MAX(0, [NSDate timeIntervalSinceReferenceDate] - at);
    if (ago < 60) return @"just now";
    if (ago < 3600) return [NSString stringWithFormat:@"%.0f min ago", floor(ago / 60.0)];
    return [NSString stringWithFormat:@"%.0f h ago", floor(ago / 3600.0)];
}

@implementation ApolloKeylessRouteStatusViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Routes";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self action:@selector(refresh)];
    // A report's log then shows what the user was looking at.
    ApolloLog(@"[WebJSON] %@", ApolloWebJSONRouteStatusSummary());
}

- (void)refresh {
    [self rebuildForm];
}

// A read-only cell: a title and a wrapping secondary line.
- (ApolloSettingsRow *)infoRowWithID:(NSString *)rowID title:(NSString *)title detail:(nullable NSString *)detail {
    __weak typeof(self) weakSelf = self;
    return [ApolloSettingsRow customRowWithID:rowID
                                         cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_RouteStatus_Info"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Cell_RouteStatus_Info"];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.numberOfLines = 0;
            cell.detailTextLabel.numberOfLines = 0;
            cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        }
        cell.textLabel.text = title;
        cell.detailTextLabel.text = detail;
        [weakSelf apollo_applyPrimaryTextColorToCell:cell];
        return cell;
    }
                                     onSelect:nil];
}

- (NSString *)detailForEndpoint:(NSDictionary *)endpoint {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSInteger using = [endpoint[@"using"] integerValue];
    if ([endpoint[@"allCooling"] boolValue]) {
        [lines addObject:@"Every route is blocked right now"];
    } else if (using >= 0) {
        [lines addObject:[@"Using " stringByAppendingString:ApolloWebJSONRouteName((ApolloWebJSONRoute)using)]];
    }
    for (NSDictionary *route in endpoint[@"routes"]) {
        NSString *line = [NSString stringWithFormat:@"%@: %@ ok, %@ blocked",
                          ApolloWebJSONRouteName((ApolloWebJSONRoute)[route[@"route"] integerValue]), route[@"ok"], route[@"blocked"]];
        NSTimeInterval cooling = [route[@"cooldownRemaining"] doubleValue];
        NSString *lastOk = ApolloRouteStatusAgo([route[@"lastOkAt"] doubleValue]);
        if (cooling > 0) line = [line stringByAppendingFormat:@", skipped for %.0f more min", ceil(cooling / 60.0)];
        else if (lastOk) line = [line stringByAppendingFormat:@", last ok %@", lastOk];
        [lines addObject:line];
    }
    if ([endpoint[@"remote"] boolValue]) [lines addObject:@"Order from keyless-routes.json"];
    return [lines componentsJoinedByString:@"\n"];
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    NSString *account = ApolloActiveWebSessionUsername();
    NSMutableArray<ApolloSettingsSection *> *sections = [NSMutableArray array];

    NSMutableArray<ApolloSettingsRow *> *endpointRows = [NSMutableArray array];
    for (NSDictionary *endpoint in ApolloWebJSONRouteStatusEndpoints()) {
        [endpointRows addObject:[self infoRowWithID:[@"routes.endpoint." stringByAppendingString:endpoint[@"key"]]
                                              title:endpoint[@"key"]
                                             detail:[self detailForEndpoint:endpoint]]];
    }
    NSString *who = account.length ? [NSString stringWithFormat:@"u/%@", account] : @"the active account";
    [sections addObject:
        [ApolloSettingsSection sectionWithTitle:@"Routes"
                                         footer:[NSString stringWithFormat:@"Reddit blocks these for API-key-free accounts at their usual address, so they can go by more than one. Counts are for %@ since Apollo opened. A route that's blocked 3 times in a row is skipped for an hour.", who]
                                           rows:endpointRows]];

    NSMutableArray<ApolloSettingsRow *> *blockedRows = [NSMutableArray array];
    for (NSDictionary *row in ApolloWebJSONRouteStatusBlockedPaths()) {
        NSString *lastBlocked = ApolloRouteStatusAgo([row[@"lastBlockedAt"] doubleValue]);
        [blockedRows addObject:[self infoRowWithID:[@"routes.blocked." stringByAppendingString:row[@"pattern"]]
                                             title:row[@"pattern"]
                                            detail:[NSString stringWithFormat:@"%@ blocked, %@ ok%@", row[@"blocked"], row[@"ok"],
                                                    lastBlocked ? [@", last blocked " stringByAppendingString:lastBlocked] : @""]]];
    }
    if (blockedRows.count == 0) {
        [blockedRows addObject:[self infoRowWithID:@"routes.blocked.none" title:@"None since Apollo opened" detail:nil]];
    }
    [sections addObject:
        [ApolloSettingsSection sectionWithTitle:@"Blocked Without Another Route"
                                         footer:@"Requests Reddit refused with its block page that have no other route. If one keeps failing, copy the summary into a bug report."
                                           rows:blockedRows]];

    NSDictionary *updates = ApolloWebJSONRouteUpdatesStatus();
    __weak typeof(self) weakSelf = self;
    ApolloSettingsRow *updatesState =
        [ApolloSettingsRow switchRowWithID:@"routes.updates.state"
                                     title:@"Use Route Updates"
                                      isOn:^BOOL { return sKeylessRouteUpdates; }
                                  onToggle:^(UISwitch *sender) {
            ApolloWebJSONRouteUpdatesSetEnabled(sender.isOn);
            // The result line and the routes in use change with it.
            [weakSelf rebuildForm];
        }];
    ApolloSettingsRow *updatesChecked =
        [ApolloSettingsRow valueRowWithID:@"routes.updates.checked" title:@"Last Checked"
                                   detail:^NSString *{ return updates[@"lastChecked"]; }
                                 onSelect:nil];
    ApolloSettingsRow *updatesResult =
        [self infoRowWithID:@"routes.updates.result" title:@"Result" detail:updates[@"result"]];
    [sections addObject:
        [ApolloSettingsSection sectionWithTitle:@"Route Updates"
                                         footer:@"When Reddit blocks an address API-key-free accounts use, Apollo Reborn can switch to another reddit.com address from a list kept in its GitHub repository (keyless-routes.json), checked every 15 minutes while Apollo is open. Off uses only the addresses built into this version."
                                           rows:@[ updatesState, updatesChecked, updatesResult ]]];

    ApolloSettingsRow *copy = [ApolloSettingsRow buttonRowWithID:@"routes.copy" title:@"Copy Summary" action:^{
        [weakSelf copySummary];
    }];
    [sections addObject:
        [ApolloSettingsSection sectionWithTitle:nil
                                         footer:@"Copies this screen as text to paste into a bug report. Nothing here is sent anywhere unless you send it."
                                           rows:@[ copy ]]];
    return sections;
}

- (void)copySummary {
    NSString *summary = ApolloWebJSONRouteStatusSummary();
    UIPasteboard.generalPasteboard.string = summary;
    ApolloLog(@"[WebJSON] %@", summary);
    ApolloShowToastWithStyle(@"Summary Copied", @"Paste it into a bug report", ApolloToastStyleSuccess, nil);
}

@end
