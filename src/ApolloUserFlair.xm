#import "ApolloCommon.h"
#import <objc/message.h>
#import <objc/runtime.h>

static char kApolloUserFlairEditorPresentedKey;
static char kApolloUserFlairCapturedOptionsKey;

static const NSUInteger kApolloUserFlairMaxLength = 64;

static __thread __unsafe_unretained UIViewController *tApolloUserFlairCaptureController = nil;
static __thread NSInteger tApolloUserFlairCaptureSection = NSNotFound;
static __thread NSInteger tApolloUserFlairCaptureRow = NSNotFound;

@interface ApolloUserFlairOptionAdapter : NSObject
@property (nonatomic, strong) id option;
+ (instancetype)adapterWithOption:(id)option;
- (NSString *)templateID;
- (NSString *)displayText;
- (BOOL)isEditableWithKnown:(BOOL *)known;
- (BOOL)setDisplayText:(NSString *)text;
@end

@interface ApolloUserFlairSelectorAdapter : NSObject
@property (nonatomic, weak) UIViewController *controller;
+ (instancetype)adapterWithController:(UIViewController *)controller;
- (BOOL)isUserFlairSelector;
- (NSString *)subredditNameUsingSource:(id)source;
- (UIViewController *)presenter;
- (BOOL)prepareForNativeUpdate;
- (BOOL)performNativeUpdate;
@end

@interface ApolloUserFlairEditSession : NSObject
@property (nonatomic, strong) ApolloUserFlairSelectorAdapter *selectorAdapter;
@property (nonatomic, strong) ApolloUserFlairOptionAdapter *optionAdapter;
@property (nonatomic, copy) NSString *subredditName;
@property (nonatomic, copy) NSString *templateID;
@property (nonatomic, copy) NSString *initialText;
+ (instancetype)sessionWithSelectorAdapter:(ApolloUserFlairSelectorAdapter *)selectorAdapter optionAdapter:(ApolloUserFlairOptionAdapter *)optionAdapter subredditName:(NSString *)subredditName templateID:(NSString *)templateID initialText:(NSString *)initialText;
@end

@interface ApolloUserFlairTextFieldObserver : NSObject
@property (nonatomic, weak) UIAlertController *alert;
@property (nonatomic, weak) UIAlertAction *saveAction;
@end

@implementation ApolloUserFlairTextFieldObserver

- (void)textFieldChanged:(UITextField *)textField {
    NSString *text = textField.text ?: @"";
    if (text.length > kApolloUserFlairMaxLength) {
        text = [text substringToIndex:kApolloUserFlairMaxLength];
        textField.text = text;
    }

    self.alert.message = [NSString stringWithFormat:@"Preview: %@\n\n%lu/%lu characters",
        text.length > 0 ? text : @"(empty)",
        (unsigned long)text.length,
        (unsigned long)kApolloUserFlairMaxLength];
    self.saveAction.enabled = text.length <= kApolloUserFlairMaxLength;
}

@end

#pragma mark - Runtime Access

static id ApolloUserFlairObjectIvar(id object, NSString *name) {
    if (!object || name.length == 0) return nil;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;
        const char *type = ivar_getTypeEncoding(ivar);
        if (!type || type[0] != '@') return nil;
        @try {
            return object_getIvar(object, ivar);
        } @catch (__unused NSException *exception) {
            return nil;
        }
    }
    return nil;
}

static NSString *ApolloUserFlairSwiftStringIvar(id object, NSString *name) {
    if (!object || name.length == 0) return nil;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;

        const char *type = ivar_getTypeEncoding(ivar);
        if (type && type[0] == '@') return nil;

        ptrdiff_t offset = ivar_getOffset(ivar);
        uint8_t *base = (uint8_t *)(__bridge void *)object + offset;
        uint64_t low = 0;
        uint64_t high = 0;
        memcpy(&low, base, sizeof(low));
        memcpy(&high, base + sizeof(low), sizeof(high));

        uint8_t discriminator = (uint8_t)(high >> 56);
        if (discriminator < 0xE0 || discriminator > 0xEF) return nil;

        NSUInteger length = discriminator - 0xE0;
        if (length == 0 || length > 15) return nil;

        char buffer[16] = {0};
        for (NSUInteger i = 0; i < length && i < 8; i++) {
            buffer[i] = (char)((low >> (i * 8)) & 0xFF);
        }
        for (NSUInteger i = 8; i < length; i++) {
            buffer[i] = (char)((high >> ((i - 8) * 8)) & 0xFF);
        }

        return [[NSString alloc] initWithBytes:buffer length:length encoding:NSUTF8StringEncoding];
    }
    return nil;
}

static BOOL ApolloUserFlairBoolIvar(id object, NSString *name, BOOL *found) {
    if (found) *found = NO;
    if (!object || name.length == 0) return NO;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;
        const char *type = ivar_getTypeEncoding(ivar);
        if (!type || (type[0] != 'B' && type[0] != 'c' && type[0] != 'C')) return NO;
        if (found) *found = YES;
        ptrdiff_t offset = ivar_getOffset(ivar);
        return *(BOOL *)((uint8_t *)(__bridge void *)object + offset);
    }
    return NO;
}

static BOOL ApolloUserFlairSetBoolIvar(id object, NSString *name, BOOL value) {
    if (!object || name.length == 0) return NO;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;
        const char *type = ivar_getTypeEncoding(ivar);
        if (!type || (type[0] != 'B' && type[0] != 'c' && type[0] != 'C')) return NO;
        ptrdiff_t offset = ivar_getOffset(ivar);
        *(BOOL *)((uint8_t *)(__bridge void *)object + offset) = value;
        return YES;
    }
    return NO;
}

static BOOL ApolloUserFlairSetByteIvar(id object, NSString *name, uint8_t value) {
    if (!object || name.length == 0) return NO;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;
        ptrdiff_t offset = ivar_getOffset(ivar);
        *((uint8_t *)(__bridge void *)object + offset) = value;
        return YES;
    }
    return NO;
}

static id ApolloUserFlairRawObjectIvar(id object, NSString *name) {
    if (!object || name.length == 0) return nil;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;
        ptrdiff_t offset = ivar_getOffset(ivar);
        void *rawValue = NULL;
        memcpy(&rawValue, (uint8_t *)(__bridge void *)object + offset, sizeof(rawValue));
        return (__bridge id)rawValue;
    }
    return nil;
}

static id ApolloUserFlairSendObject(id target, NSString *selectorName) {
    if (!target || selectorName.length == 0) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL ApolloUserFlairSendBool(id target, NSString *selectorName, BOOL *found) {
    if (found) *found = NO;
    if (!target || selectorName.length == 0) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) return NO;
    if (found) *found = YES;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (__unused NSException *exception) {
        if (found) *found = NO;
        return NO;
    }
}

static id ApolloUserFlairKVCValue(id object, NSString *key) {
    if (!object || key.length == 0) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *ApolloUserFlairStringFromValue(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSURL class]]) return [(NSURL *)value absoluteString];
    if ([value respondsToSelector:@selector(stringValue)]) {
        id stringValue = ApolloUserFlairSendObject(value, @"stringValue");
        if ([stringValue isKindOfClass:[NSString class]]) return stringValue;
    }
    return nil;
}

static NSString *ApolloUserFlairObjectString(id object, NSArray<NSString *> *names) {
    for (NSString *name in names) {
        if ([object isKindOfClass:[NSDictionary class]]) {
            NSString *string = ApolloUserFlairStringFromValue([(NSDictionary *)object objectForKey:name]);
            if (string.length > 0) return string;
        }

        NSString *string = ApolloUserFlairStringFromValue(ApolloUserFlairSendObject(object, name));
        if (string.length > 0) return string;

        string = ApolloUserFlairStringFromValue(ApolloUserFlairKVCValue(object, name));
        if (string.length > 0) return string;

        string = ApolloUserFlairStringFromValue(ApolloUserFlairObjectIvar(object, name));
        if (string.length > 0) return string;

        NSString *underscored = [@"_" stringByAppendingString:name];
        string = ApolloUserFlairStringFromValue(ApolloUserFlairObjectIvar(object, underscored));
        if (string.length > 0) return string;

        string = ApolloUserFlairSwiftStringIvar(object, name);
        if (string.length > 0) return string;

        string = ApolloUserFlairSwiftStringIvar(object, underscored);
        if (string.length > 0) return string;
    }
    return nil;
}

static NSArray *ApolloUserFlairObjectArray(id object, NSArray<NSString *> *names) {
    for (NSString *name in names) {
        id value = ApolloUserFlairSendObject(object, name);
        if ([value isKindOfClass:[NSArray class]]) return value;

        value = ApolloUserFlairKVCValue(object, name);
        if ([value isKindOfClass:[NSArray class]]) return value;

        value = ApolloUserFlairObjectIvar(object, name);
        if ([value isKindOfClass:[NSArray class]]) return value;

        value = ApolloUserFlairObjectIvar(object, [@"_" stringByAppendingString:name]);
        if ([value isKindOfClass:[NSArray class]]) return value;
    }
    return nil;
}

#pragma mark - Flair Option Adapter

static BOOL ApolloUserFlairOptionIsEditable(id option, BOOL *found) {
    BOOL localFound = NO;
    BOOL editable = ApolloUserFlairSendBool(option, @"isEditable", &localFound);
    if (localFound) {
        if (found) *found = YES;
        return editable;
    }

    editable = ApolloUserFlairSendBool(option, @"editable", &localFound);
    if (localFound) {
        if (found) *found = YES;
        return editable;
    }

    editable = ApolloUserFlairBoolIvar(option, @"isEditable", &localFound);
    if (localFound) {
        if (found) *found = YES;
        return editable;
    }

    editable = ApolloUserFlairBoolIvar(option, @"_isEditable", &localFound);
    if (localFound) {
        if (found) *found = YES;
        return editable;
    }

    if (found) *found = NO;
    return NO;
}

static NSString *ApolloUserFlairOptionIdentifier(id option) {
    return ApolloUserFlairObjectString(option, @[
        @"identifier",
        @"flairID",
        @"flairId",
        @"flairTemplateID",
        @"flairTemplateId",
        @"templateID",
        @"templateId"
    ]);
}

static NSString *ApolloUserFlairOptionText(id option) {
    NSString *text = ApolloUserFlairObjectString(option, @[
        @"textRepresentation",
        @"text",
        @"flairText",
        @"flair_text",
        @"plainText",
        @"title"
    ]);
    if (text.length > 0) return text;

    NSArray *flairs = ApolloUserFlairObjectArray(option, @[@"flairs"]);
    NSMutableString *joined = [NSMutableString string];
    for (id flair in flairs) {
        NSString *piece = ApolloUserFlairObjectString(flair, @[@"textRepresentation", @"text", @"emojiLabel"]);
        if (piece.length == 0) continue;
        [joined appendString:piece];
    }
    return joined.length > 0 ? joined : nil;
}

static BOOL ApolloUserFlairSetOptionText(id option, NSString *text) {
    SEL setter = @selector(setTextRepresentation:);
    if (!option || ![option respondsToSelector:setter]) return NO;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(option, setter, text ?: @"");
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

@implementation ApolloUserFlairOptionAdapter

+ (instancetype)adapterWithOption:(id)option {
    ApolloUserFlairOptionAdapter *adapter = [ApolloUserFlairOptionAdapter new];
    adapter.option = option;
    return adapter;
}

- (NSString *)templateID {
    return ApolloUserFlairOptionIdentifier(self.option);
}

- (NSString *)displayText {
    return ApolloUserFlairOptionText(self.option) ?: @"";
}

- (BOOL)isEditableWithKnown:(BOOL *)known {
    return ApolloUserFlairOptionIsEditable(self.option, known);
}

- (BOOL)setDisplayText:(NSString *)text {
    return ApolloUserFlairSetOptionText(self.option, text);
}

@end

#pragma mark - Flair Selector Adapter

static NSString *ApolloUserFlairSubredditNameFromObject(id object, NSUInteger depth);

static NSString *ApolloUserFlairSubredditNameFromValue(id value, NSUInteger depth) {
    if (!value || depth > 2) return nil;
    NSString *direct = ApolloUserFlairStringFromValue(value);
    if (direct.length > 0) return direct;
    return ApolloUserFlairSubredditNameFromObject(value, depth + 1);
}

static NSString *ApolloUserFlairSubredditNameFromObject(id object, NSUInteger depth) {
    if (!object || depth > 2) return nil;

    NSArray<NSString *> *names = @[
        @"subredditName",
        @"subreddit",
        @"displayName",
        @"name",
        @"subredditIdentifier",
        @"currentSubreddit"
    ];
    for (NSString *name in names) {
        NSString *value = ApolloUserFlairObjectString(object, @[name]);
        if (value.length > 0) return value;

        value = ApolloUserFlairObjectString(object, @[[@"_" stringByAppendingString:name]]);
        if (value.length > 0) return value;

        value = ApolloUserFlairSubredditNameFromValue(ApolloUserFlairSendObject(object, name), depth);
        if (value.length > 0) return value;

        value = ApolloUserFlairSubredditNameFromValue(ApolloUserFlairObjectIvar(object, name), depth);
        if (value.length > 0) return value;

        value = ApolloUserFlairSubredditNameFromValue(ApolloUserFlairObjectIvar(object, [@"_" stringByAppendingString:name]), depth);
        if (value.length > 0) return value;
    }
    return nil;
}

static NSString *ApolloUserFlairCleanSubredditName(NSString *subredditName) {
    if (subredditName.length == 0) return nil;
    NSString *clean = [subredditName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([clean hasPrefix:@"/r/"]) clean = [clean substringFromIndex:3];
    if ([clean hasPrefix:@"r/"]) clean = [clean substringFromIndex:2];
    return clean.length > 0 ? clean : nil;
}

static BOOL ApolloUserFlairControllerLooksUserScoped(UIViewController *controller) {
    NSMutableArray<NSString *> *strings = [NSMutableArray array];
    if (controller.title.length > 0) [strings addObject:controller.title];
    if (controller.navigationItem.title.length > 0) [strings addObject:controller.navigationItem.title];
    if (controller.navigationItem.prompt.length > 0) [strings addObject:controller.navigationItem.prompt];

    for (NSString *string in strings) {
        NSString *lower = string.lowercaseString;
        if ([lower containsString:@"post flair"] || [lower containsString:@"link flair"] || [lower containsString:@"crosspost"]) return NO;
    }
    return YES;
}

static UIViewController *ApolloUserFlairPresenterForController(UIViewController *controller) {
    UIViewController *presenter = controller;
    while (presenter.presentedViewController && ![presenter.presentedViewController isKindOfClass:[UIAlertController class]]) {
        presenter = presenter.presentedViewController;
    }
    return presenter ?: controller;
}

@implementation ApolloUserFlairSelectorAdapter

+ (instancetype)adapterWithController:(UIViewController *)controller {
    ApolloUserFlairSelectorAdapter *adapter = [ApolloUserFlairSelectorAdapter new];
    adapter.controller = controller;
    return adapter;
}

- (BOOL)isUserFlairSelector {
    return ApolloUserFlairControllerLooksUserScoped(self.controller);
}

- (NSString *)subredditNameUsingSource:(id)source {
    NSString *subredditName = ApolloUserFlairCleanSubredditName(ApolloUserFlairSubredditNameFromObject(source ?: self.controller, 0));
    if (subredditName.length == 0 && source != self.controller) {
        subredditName = ApolloUserFlairCleanSubredditName(ApolloUserFlairSubredditNameFromObject(self.controller, 0));
    }
    return subredditName;
}

- (UIViewController *)presenter {
    return ApolloUserFlairPresenterForController(self.controller);
}

- (BOOL)prepareForNativeUpdate {
    BOOL marked = ApolloUserFlairSetBoolIvar(self.controller, @"hasMadeChanges", YES);
    if (!marked) marked = ApolloUserFlairSetByteIvar(self.controller, @"hasMadeChanges", 1);

    id updateButton = ApolloUserFlairObjectIvar(self.controller, @"updateBarButtonItem");
    if (!updateButton) updateButton = ApolloUserFlairRawObjectIvar(self.controller, @"updateBarButtonItem");
    BOOL buttonEnabled = NO;
    if ([updateButton respondsToSelector:@selector(setEnabled:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(updateButton, @selector(setEnabled:), YES);
        buttonEnabled = YES;
    }
    ApolloLog(@"[UserFlair] prepared native update dirty=%@ updateButton=%@ buttonEnabled=%@",
        marked ? @"yes" : @"no",
        updateButton ? @"yes" : @"no",
        buttonEnabled ? @"yes" : @"no");
    return marked;
}

- (BOOL)performNativeUpdate {
    UIViewController *controller = self.controller;
    SEL updateSEL = @selector(updateBarButtonItemTappedWithSender:);
    if (!controller || ![controller respondsToSelector:updateSEL]) return NO;

    objc_setAssociatedObject(controller, &kApolloUserFlairEditorPresentedKey, nil, OBJC_ASSOCIATION_ASSIGN);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, id))objc_msgSend)(controller, updateSEL, nil);
    });
    return YES;
}

@end

#pragma mark - Edit Session

@implementation ApolloUserFlairEditSession

+ (instancetype)sessionWithSelectorAdapter:(ApolloUserFlairSelectorAdapter *)selectorAdapter optionAdapter:(ApolloUserFlairOptionAdapter *)optionAdapter subredditName:(NSString *)subredditName templateID:(NSString *)templateID initialText:(NSString *)initialText {
    ApolloUserFlairEditSession *session = [ApolloUserFlairEditSession new];
    session.selectorAdapter = selectorAdapter;
    session.optionAdapter = optionAdapter;
    session.subredditName = subredditName;
    session.templateID = templateID;
    session.initialText = initialText ?: @"";
    return session;
}

@end

static ApolloUserFlairEditSession *ApolloUserFlairBuildEditSession(UIViewController *controller, id option, id source, NSString *reason) {
    ApolloUserFlairSelectorAdapter *selectorAdapter = [ApolloUserFlairSelectorAdapter adapterWithController:controller];
    ApolloUserFlairOptionAdapter *optionAdapter = [ApolloUserFlairOptionAdapter adapterWithOption:option];

    BOOL editableKnown = NO;
    BOOL editable = [optionAdapter isEditableWithKnown:&editableKnown];
    NSString *subredditName = [selectorAdapter subredditNameUsingSource:source];
    NSString *templateID = [optionAdapter templateID];

    ApolloLog(@"[UserFlair] %@ tapped optionClass=%@ templateID=%@ editable=%@ editableKnown=%@ subreddit=%@",
        reason ?: @"selection",
        option ? NSStringFromClass([option class]) : @"(nil)",
        templateID ?: @"(nil)",
        editable ? @"yes" : @"no",
        editableKnown ? @"yes" : @"no",
        subredditName ?: @"(nil)");

    if (!option || ![selectorAdapter isUserFlairSelector] || !editableKnown || !editable || subredditName.length == 0 || templateID.length == 0) return nil;
    return [ApolloUserFlairEditSession sessionWithSelectorAdapter:selectorAdapter
                                                    optionAdapter:optionAdapter
                                                    subredditName:subredditName
                                                      templateID:templateID
                                                     initialText:[optionAdapter displayText]];
}

#pragma mark - Editor

static void ApolloUserFlairShowError(UIViewController *controller, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Error Setting Flair"
                                                                       message:message.length > 0 ? message : @"Reddit returned an error while saving your flair."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [ApolloUserFlairPresenterForController(controller) presentViewController:alert animated:YES completion:nil];
    });
}

static BOOL ApolloUserFlairCommitEditedSession(ApolloUserFlairEditSession *session, NSString *text) {
    // Apollo only saves through the native Update path when its selector is dirty.
    // Text-only edits on the checked template do not flip that flag, so update the option text,
    // mark the selector dirty, then invoke Apollo's Update handler.
    if (![session.optionAdapter setDisplayText:text]) return NO;
    if (![session.selectorAdapter prepareForNativeUpdate]) return NO;

    ApolloLog(@"[UserFlair] committing through native update subreddit=%@ templateID=%@ textLen=%lu",
        session.subredditName ?: @"(nil)",
        session.templateID ?: @"(nil)",
        (unsigned long)text.length);
    return [session.selectorAdapter performNativeUpdate];
}

static void ApolloUserFlairPresentEditor(ApolloUserFlairEditSession *session) {
    UIViewController *controller = session.selectorAdapter.controller;
    if ([objc_getAssociatedObject(controller, &kApolloUserFlairEditorPresentedKey) boolValue]) return;
    objc_setAssociatedObject(controller, &kApolloUserFlairEditorPresentedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSString *templateID = session.templateID;
    NSString *subredditName = session.subredditName;
    NSString *initialText = session.initialText ?: @"";
    if (initialText.length > kApolloUserFlairMaxLength) initialText = [initialText substringToIndex:kApolloUserFlairMaxLength];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Edit User Flair"
                                                                   message:[NSString stringWithFormat:@"Preview: %@\n\n%lu/%lu characters",
                                                                            initialText.length > 0 ? initialText : @"(empty)",
                                                                            (unsigned long)initialText.length,
                                                                            (unsigned long)kApolloUserFlairMaxLength]
                                                            preferredStyle:UIAlertControllerStyleAlert];

    __weak UIAlertController *weakAlert = alert;
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = initialText;
        textField.placeholder = @"Flair text";
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.autocorrectionType = UITextAutocorrectionTypeDefault;
        textField.returnKeyType = UIReturnKeyDone;
    }];

    __weak UIViewController *weakController = controller;
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
        UIViewController *strongController = weakController;
        if (strongController) objc_setAssociatedObject(strongController, &kApolloUserFlairEditorPresentedKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }];
    [alert addAction:cancelAction];

    UIAlertAction *saveAction = [UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        UIViewController *strongController = weakController;
        UIAlertController *strongAlert = weakAlert;
        NSString *text = strongAlert.textFields.firstObject.text ?: @"";
        if (text.length > kApolloUserFlairMaxLength) text = [text substringToIndex:kApolloUserFlairMaxLength];
        ApolloLog(@"[UserFlair] save tapped subreddit=%@ templateID=%@ textLen=%lu option=%@",
            subredditName ?: @"(nil)",
            templateID ?: @"(nil)",
            (unsigned long)text.length,
            session.optionAdapter.option ? NSStringFromClass([session.optionAdapter.option class]) : @"(nil)");

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ApolloUserFlairCommitEditedSession(session, text)) {
                if (strongController) objc_setAssociatedObject(strongController, &kApolloUserFlairEditorPresentedKey, nil, OBJC_ASSOCIATION_ASSIGN);
                ApolloUserFlairShowError(strongController, @"Apollo's native flair update action was unavailable.");
            }
        });
    }];
    [alert addAction:saveAction];

    ApolloUserFlairTextFieldObserver *observer = [ApolloUserFlairTextFieldObserver new];
    observer.alert = alert;
    observer.saveAction = saveAction;
    UITextField *textField = alert.textFields.firstObject;
    [textField addTarget:observer action:@selector(textFieldChanged:) forControlEvents:UIControlEventEditingChanged];
    objc_setAssociatedObject(alert, @selector(textFieldChanged:), observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [observer textFieldChanged:textField];

    ApolloLog(@"[UserFlair] presenting editor subreddit=%@ templateID=%@ initialLen=%lu",
        subredditName ?: @"(nil)",
        templateID ?: @"(nil)",
        (unsigned long)initialText.length);
    [[session.selectorAdapter presenter] presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Row Option Capture

static NSNumber *ApolloUserFlairRowKey(NSInteger section, NSInteger row) {
    return @((((long long)section) << 32) | ((long long)row & 0xffffffffLL));
}

static NSMutableDictionary<NSNumber *, id> *ApolloUserFlairCapturedOptions(UIViewController *controller, BOOL create) {
    if (!controller) return nil;
    @synchronized (controller) {
        NSMutableDictionary *options = objc_getAssociatedObject(controller, &kApolloUserFlairCapturedOptionsKey);
        if (!options && create) {
            options = [NSMutableDictionary dictionary];
            objc_setAssociatedObject(controller, &kApolloUserFlairCapturedOptionsKey, options, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return options;
    }
}

static void ApolloUserFlairCaptureOptionIfNeeded(id option) {
    UIViewController *controller = tApolloUserFlairCaptureController;
    if (!controller || tApolloUserFlairCaptureSection == NSNotFound || tApolloUserFlairCaptureRow == NSNotFound || !option) return;

    NSNumber *key = ApolloUserFlairRowKey(tApolloUserFlairCaptureSection, tApolloUserFlairCaptureRow);
    @synchronized (controller) {
        NSMutableDictionary *options = ApolloUserFlairCapturedOptions(controller, YES);
        options[key] = option;
    }
}

static id ApolloUserFlairCapturedOptionAtIndexPath(UIViewController *controller, NSIndexPath *indexPath) {
    if (!controller || !indexPath) return nil;
    NSNumber *key = ApolloUserFlairRowKey(indexPath.section, indexPath.row);
    @synchronized (controller) {
        return ApolloUserFlairCapturedOptions(controller, NO)[key];
    }
}

static BOOL ApolloUserFlairMaybePresentEditorForOption(UIViewController *controller, id option, id source, NSString *reason) {
    if (!controller) return NO;
    ApolloUserFlairEditSession *session = ApolloUserFlairBuildEditSession(controller, option, source, reason);
    if (!session) return NO;
    ApolloUserFlairPresentEditor(session);
    return YES;
}

#pragma mark - Hooks

%hook _TtC6Apollo27FlairSelectorViewController

- (id)tableNode:(id)tableNode nodeBlockForRowAtIndexPath:(NSIndexPath *)indexPath {
    id originalBlock = %orig;
    if (!originalBlock || indexPath.section != 1) return originalBlock;

    id copiedBlock = [originalBlock copy];
    __weak UIViewController *weakController = (UIViewController *)self;
    NSInteger section = indexPath.section;
    NSInteger row = indexPath.row;

    return [^id {
        UIViewController *strongController = weakController;
        UIViewController *previousController = tApolloUserFlairCaptureController;
        NSInteger previousSection = tApolloUserFlairCaptureSection;
        NSInteger previousRow = tApolloUserFlairCaptureRow;
        id node = nil;

        tApolloUserFlairCaptureController = strongController;
        tApolloUserFlairCaptureSection = section;
        tApolloUserFlairCaptureRow = row;
        @try {
            node = ((id (^)(void))copiedBlock)();
        } @finally {
            tApolloUserFlairCaptureController = previousController;
            tApolloUserFlairCaptureSection = previousSection;
            tApolloUserFlairCaptureRow = previousRow;
        }

        return node;
    } copy];
}

- (void)tableNode:(id)tableNode didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    id tappedOption = ApolloUserFlairCapturedOptionAtIndexPath((UIViewController *)self, indexPath);
    %orig;
    __weak UIViewController *weakController = (UIViewController *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *strongController = weakController;
        if (!strongController) return;
        ApolloUserFlairMaybePresentEditorForOption(strongController, tappedOption, strongController, @"row-select");
    });
}

%end

%hook RDKFlairOption

- (NSString *)identifier {
    NSString *identifier = %orig;
    ApolloUserFlairCaptureOptionIfNeeded(self);
    return identifier;
}

- (NSString *)textRepresentation {
    NSString *textRepresentation = %orig;
    ApolloUserFlairCaptureOptionIfNeeded(self);
    return textRepresentation;
}

- (BOOL)isEditable {
    BOOL editable = %orig;
    ApolloUserFlairCaptureOptionIfNeeded(self);
    return editable;
}

- (NSArray *)flairs {
    NSArray *flairs = %orig;
    ApolloUserFlairCaptureOptionIfNeeded(self);
    return flairs;
}

%end
