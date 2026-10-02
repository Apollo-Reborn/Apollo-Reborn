#import "settings/ApolloKagiSessionLinkViewController.h"

#import "ApolloCommon.h"
#import "ApolloKagiSearch.h"
#import "ApolloKagiSearchParsing.h"

static NSString *const kApolloKagiAccountSettingsURL = @"https://kagi.com/settings/user_details";

@interface ApolloKagiSessionLinkViewController () <UITextFieldDelegate>
@end

@implementation ApolloKagiSessionLinkViewController {
    UITextField *_field;
    BOOL _checking;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Kagi Session Link";
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                      target:self
                                                      action:@selector(apollo_cancel)];
    [self apollo_updateSaveButton];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [_field becomeFirstResponder];
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak __typeof(self) weakSelf = self;

    ApolloSettingsRow *link =
        [ApolloSettingsRow customRowWithID:@"kagi.link"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            return [weakSelf apollo_linkCell] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    ApolloSettingsRow *openKagi =
        [ApolloSettingsRow buttonRowWithID:@"kagi.openSettings"
                                     title:@"Open Kagi Account Settings"
                                    action:^{
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf->_field resignFirstResponder];
            ApolloPresentWebURLFromViewController(strongSelf, [NSURL URLWithString:kApolloKagiAccountSettingsURL]);
        }];

    return @[
        [ApolloSettingsSection sectionWithTitle:nil
                                         footer:@"In Kagi, open Settings → Account and copy your Session Link, then paste it here. "
                                                 "Apollo uses it to search Reddit with your Kagi account, and each page of results counts as one "
                                                 "search on your plan. The link is kept in this device's Keychain."
                                           rows:@[ link ]],
        [ApolloSettingsSection sectionWithTitle:nil
                                         footer:@"Anyone with your Session Link can search as you. You can reset it in Kagi's account settings at any time."
                                           rows:@[ openKagi ]],
    ];
}

- (UITableViewCell *)apollo_linkCell {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (!_field) {
        _field = [[UITextField alloc] init];
        _field.placeholder = @"https://kagi.com/search?token=…";
        _field.keyboardType = UIKeyboardTypeURL;
        _field.autocorrectionType = UITextAutocorrectionTypeNo;
        _field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        _field.spellCheckingType = UITextSpellCheckingTypeNo;
        _field.clearButtonMode = UITextFieldViewModeWhileEditing;
        _field.returnKeyType = UIReturnKeyDone;
        _field.adjustsFontForContentSizeCategory = YES;
        _field.delegate = self;
        [_field addTarget:self action:@selector(apollo_updateSaveButton) forControlEvents:UIControlEventEditingChanged];
    }
    _field.font = ApolloSettingsFont(UIFontTextStyleBody, self.traitCollection);
    _field.textColor = ApolloSettingsPrimaryTextColor();
    _field.translatesAutoresizingMaskIntoConstraints = NO;
    [_field removeFromSuperview];
    [cell.contentView addSubview:_field];
    UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_field.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [_field.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [_field.topAnchor constraintEqualToAnchor:margins.topAnchor],
        [_field.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
        [_field.heightAnchor constraintGreaterThanOrEqualToConstant:30],
    ]];
    return cell;
}

#pragma mark - Actions

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self apollo_save];
    return NO;
}

- (void)apollo_updateSaveButton {
    if (_checking) {
        UIActivityIndicatorView *spinner =
            [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:spinner];
        return;
    }
    UIBarButtonItem *save = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                                                                          target:self
                                                                          action:@selector(apollo_save)];
    NSString *text = [_field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    save.enabled = text.length > 0;
    self.navigationItem.rightBarButtonItem = save;
}

- (void)apollo_setChecking:(BOOL)checking {
    _checking = checking;
    _field.enabled = !checking;
    self.navigationItem.leftBarButtonItem.enabled = !checking;
    self.modalInPresentation = checking;
    [self apollo_updateSaveButton];
}

- (void)apollo_cancel {
    [_field resignFirstResponder];
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)apollo_save {
    if (_checking) return;
    NSString *token = ApolloKagiNormalizeSessionToken(_field.text);
    if (!token) {
        [self apollo_alertWithTitle:@"Not a Session Link"
                            message:@"Paste the whole Session Link from Kagi → Settings → Account. It starts with https://kagi.com/search?token="
                            actions:nil];
        return;
    }
    [_field resignFirstResponder];
    [self apollo_setChecking:YES];
    __weak __typeof(self) weakSelf = self;
    ApolloKagiCheckSessionToken(token, ^(ApolloKagiSessionCheck result, NSError *error) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf apollo_setChecking:NO];
        switch (result) {
            case ApolloKagiSessionCheckValid:
                [strongSelf apollo_store:token];
                break;
            case ApolloKagiSessionCheckRejected:
                [strongSelf apollo_alertWithTitle:@"Kagi Didn't Accept This Link"
                                          message:@"It may have expired or been reset. Copy a fresh Session Link from Kagi → Settings → Account."
                                          actions:nil];
                break;
            case ApolloKagiSessionCheckUnreachable: {
                UIAlertAction *saveAnyway = [UIAlertAction actionWithTitle:@"Save Anyway"
                                                                     style:UIAlertActionStyleDefault
                                                                   handler:^(__unused UIAlertAction *action) {
                    [weakSelf apollo_store:token];
                }];
                NSString *reason = error.localizedDescription.length ? error.localizedDescription : @"Kagi didn't respond.";
                [strongSelf apollo_alertWithTitle:@"Couldn't Reach Kagi"
                                          message:[reason stringByAppendingString:@" The link couldn't be checked."]
                                          actions:@[saveAnyway]];
                break;
            }
        }
    });
}

- (void)apollo_store:(NSString *)token {
    if (!ApolloKagiSetSessionToken(token)) {
        [self apollo_alertWithTitle:@"Couldn't Save the Link"
                            message:@"The Keychain didn't accept it. Try again, or restart Apollo if this keeps happening."
                            actions:nil];
        return;
    }
    void (^saved)(void) = self.saved;
    [self.navigationController dismissViewControllerAnimated:YES completion:^{
        if (saved) saved();
    }];
}

- (void)apollo_alertWithTitle:(NSString *)title message:(NSString *)message actions:(NSArray<UIAlertAction *> *)actions {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    for (UIAlertAction *action in actions) [alert addAction:action];
    [alert addAction:[UIAlertAction actionWithTitle:actions.count ? @"Cancel" : @"OK"
                                              style:actions.count ? UIAlertActionStyleCancel : UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

void ApolloKagiPresentSessionLinkSheet(UIViewController *presenter, void (^saved)(void)) {
    UIViewController *top = presenter;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) {
        top = top.presentedViewController;
    }
    if (!top.view.window) {
        ApolloLog(@"[KagiSearch] no window to present the Session Link sheet from");
        return;
    }
    ApolloKagiSessionLinkViewController *controller =
        [[ApolloKagiSessionLinkViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    controller.saved = saved;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:controller];
    navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    [top presentViewController:navigation animated:YES completion:nil];
}
