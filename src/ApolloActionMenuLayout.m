#import "ApolloActionMenuLayout.h"

#import "ApolloCommon.h"
#import "UserDefaultConstants.h"

ApolloActionMenuContext const ApolloActionMenuContextFeed = @"feed";
ApolloActionMenuContext const ApolloActionMenuContextPost = @"post";
ApolloActionMenuContext const ApolloActionMenuContextPostDetail = @"post-detail";
ApolloActionMenuContext const ApolloActionMenuContextComment = @"comment";
ApolloActionMenuContext const ApolloActionMenuContextModeratorSubreddit = @"moderator-subreddit";
ApolloActionMenuContext const ApolloActionMenuContextModeratorPost = @"moderator-post";
ApolloActionMenuContext const ApolloActionMenuContextModeratorComment = @"moderator-comment";

static NSString *const kApolloActionMenuLayoutOrderKey = @"order";
static NSString *const kApolloActionMenuLayoutHiddenKey = @"hidden";
static NSString *const kApolloActionMenuSpecItemPrefix = @"spec.";

NSArray<ApolloActionMenuContext> *ApolloActionMenuAllContexts(void) {
    return @[ ApolloActionMenuContextFeed, ApolloActionMenuContextPost,
              ApolloActionMenuContextPostDetail, ApolloActionMenuContextComment,
              ApolloActionMenuContextModeratorSubreddit, ApolloActionMenuContextModeratorPost,
              ApolloActionMenuContextModeratorComment ];
}

BOOL ApolloActionMenuContextIsValid(NSString *context) {
    return [context isKindOfClass:[NSString class]] && [ApolloActionMenuAllContexts() containsObject:context];
}

NSString *ApolloActionMenuContextTitle(ApolloActionMenuContext context) {
    if ([context isEqualToString:ApolloActionMenuContextFeed]) return @"Feed";
    if ([context isEqualToString:ApolloActionMenuContextPost]) return @"Post";
    if ([context isEqualToString:ApolloActionMenuContextPostDetail]) return @"Post (Comments)";
    if ([context isEqualToString:ApolloActionMenuContextComment]) return @"Comment";
    if ([context isEqualToString:ApolloActionMenuContextModeratorSubreddit]) return @"Moderator (Subreddit)";
    if ([context isEqualToString:ApolloActionMenuContextModeratorPost]) return @"Moderator (Post)";
    if ([context isEqualToString:ApolloActionMenuContextModeratorComment]) return @"Moderator (Comment)";
    return context ?: @"";
}

NSString *ApolloActionMenuContextDescription(ApolloActionMenuContext context) {
    if ([context isEqualToString:ApolloActionMenuContextFeed]) return @"The ••• button at the top of a subreddit or feed.";
    if ([context isEqualToString:ApolloActionMenuContextPost]) return @"The ••• button on a post in a feed.";
    if ([context isEqualToString:ApolloActionMenuContextPostDetail]) return @"The ••• button at the top of a post's comments.";
    if ([context isEqualToString:ApolloActionMenuContextComment]) return @"The ••• button on a comment.";
    if ([context isEqualToString:ApolloActionMenuContextModeratorSubreddit]) return @"The moderator shield at the top of a subreddit you moderate.";
    if ([context isEqualToString:ApolloActionMenuContextModeratorPost]) return @"The moderator shield on a post, the Moderator row in a post’s ••• menus, and the shield at the top of its comments.";
    if ([context isEqualToString:ApolloActionMenuContextModeratorComment]) return @"The moderator shield on a comment, and the Moderator row in its ••• menu.";
    return @"";
}

BOOL ApolloActionMenuContextIsModerator(ApolloActionMenuContext context) {
    return [context isEqualToString:ApolloActionMenuContextModeratorSubreddit]
        || [context isEqualToString:ApolloActionMenuContextModeratorPost]
        || [context isEqualToString:ApolloActionMenuContextModeratorComment];
}

ApolloActionMenuContext ApolloActionMenuModeratorContextFollowing(ApolloActionMenuContext context) {
    if ([context isEqualToString:ApolloActionMenuContextPost] ||
        [context isEqualToString:ApolloActionMenuContextPostDetail]) return ApolloActionMenuContextModeratorPost;
    if ([context isEqualToString:ApolloActionMenuContextComment]) return ApolloActionMenuContextModeratorComment;
    return nil;
}

#pragma mark - Items

@interface ApolloActionMenuItem ()
@property (nonatomic, copy, readwrite) NSString *itemID;
@property (nonatomic, copy, readwrite) NSString *title;
@property (nonatomic, copy, readwrite, nullable) NSString *assetName;
@property (nonatomic, copy, readwrite, nullable) NSString *symbolName;
@property (nonatomic, copy, readwrite) NSArray<NSNumber *> *kinds;
@property (nonatomic, copy, readwrite, nullable) NSString *specIdentifier;
@property (nonatomic, readwrite) BOOL usuallyShown;
@property (nonatomic, readwrite) BOOL locked;
@end

@implementation ApolloActionMenuItem

- (BOOL)isTweakRow {
    return self.specIdentifier.length > 0;
}

// Same visual weight the menus use (ApolloActionMenuIconBoxSide): Apollo's
// option-* assets fitted into a 24pt box, SF Symbols at a matching size.
- (UIImage *)icon {
    static const CGFloat kBox = 24.0;
    if (self.assetName.length > 0) {
        UIImage *image = [UIImage imageNamed:self.assetName];
        if (image && image.size.width > 0.0 && image.size.height > 0.0) {
            CGFloat scale = MIN(kBox / image.size.width, kBox / image.size.height);
            if (scale >= 1.0) return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            CGSize drawSize = CGSizeMake(round(image.size.width * scale), round(image.size.height * scale));
            CGRect drawRect = CGRectMake(floor((kBox - drawSize.width) / 2.0), floor((kBox - drawSize.height) / 2.0),
                                         drawSize.width, drawSize.height);
            UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
            format.opaque = NO;
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(kBox, kBox) format:format];
            UIImage *resized = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
                [[image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal] drawInRect:drawRect];
            }];
            return [resized imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        }
    }
    if (self.symbolName.length > 0) {
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:19.0 weight:UIImageSymbolWeightRegular];
        UIImage *symbol = [UIImage systemImageNamed:self.symbolName withConfiguration:configuration];
        return [symbol imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    return nil;
}

@end

// Native row: `kinds` are every Action kind that renders as this item.
static ApolloActionMenuItem *ApolloAMNative(NSString *itemID, NSString *title, NSString *assetName, NSArray<NSNumber *> *kinds) {
    ApolloActionMenuItem *item = [ApolloActionMenuItem new];
    item.itemID = itemID;
    item.title = title;
    item.assetName = assetName;
    item.kinds = kinds;
    return item;
}

// Apollo Reborn row, keyed by its ApolloActionMenuSpec identifier.
static ApolloActionMenuItem *ApolloAMTweak(NSString *specIdentifier, NSString *title, NSString *symbolName) {
    ApolloActionMenuItem *item = [ApolloActionMenuItem new];
    item.itemID = ApolloActionMenuItemIDForSpec(specIdentifier);
    item.title = title;
    item.symbolName = symbolName;
    item.kinds = @[];
    item.specIdentifier = specIdentifier;
    return item;
}

// A row the user can neither move nor hide (ApolloActionMenuItem.locked).
static ApolloActionMenuItem *ApolloAMLocked(ApolloActionMenuItem *item) {
    item.locked = YES;
    return item;
}

NSString *ApolloActionMenuItemIDForSpec(NSString *specIdentifier) {
    return [kApolloActionMenuSpecItemPrefix stringByAppendingString:specIdentifier ?: @""];
}

// The shared vocabulary. Kinds are Apollo's Action enum raw values
// (ApolloNativeActionMetadata.h — index = kind); a menu's catalogue below
// lists them in Apollo's default order for that menu, as captured from the
// sheets themselves (see the PR's verification notes).
#define K(...) @[ __VA_ARGS__ ]

static ApolloActionMenuItem *ApolloAMItemUpvote(void)      { return ApolloAMNative(@"upvote", @"Upvote", @"option-upvote", K(@3, @4)); }
static ApolloActionMenuItem *ApolloAMItemDownvote(void)    { return ApolloAMNative(@"downvote", @"Downvote", @"option-downvote", K(@5, @6)); }
static ApolloActionMenuItem *ApolloAMItemSave(void)        { return ApolloAMNative(@"save", @"Save", @"option-save", K(@7, @11)); }
static ApolloActionMenuItem *ApolloAMItemReply(void)       { return ApolloAMNative(@"reply", @"Reply", @"option-reply", K(@12)); }
static ApolloActionMenuItem *ApolloAMItemAuthor(void)      { return ApolloAMNative(@"author", @"Author", @"option-author", K(@42, @199)); }
static ApolloActionMenuItem *ApolloAMItemSubreddit(void)   { return ApolloAMNative(@"subreddit", @"Subreddit", @"option-subreddit", K(@44, @200)); }
static ApolloActionMenuItem *ApolloAMItemHide(void)        { return ApolloAMNative(@"hide", @"Hide", @"option-hide", K(@239, @240)); }
static ApolloActionMenuItem *ApolloAMItemHideAbove(void)   { return ApolloAMNative(@"hide-above", @"Hide Posts Above", @"option-hide-all-above", K(@241, @242)); }
static ApolloActionMenuItem *ApolloAMItemShare(void)       { return ApolloAMNative(@"share", @"Share", @"option-share", K(@15, @207)); }
static ApolloActionMenuItem *ApolloAMItemShareImage(void)  { return ApolloAMNative(@"share-image", @"Share as Image", @"option-share-as-image", K(@17)); }
static ApolloActionMenuItem *ApolloAMItemCrosspost(void)   { return ApolloAMNative(@"crosspost", @"Crosspost", @"option-crosspost", K(@1)); }
static ApolloActionMenuItem *ApolloAMItemAward(void)       { return ApolloAMNative(@"award", @"Give Award", @"option-gift-award", K(@122)); }
static ApolloActionMenuItem *ApolloAMItemReport(void)      { return ApolloAMNative(@"report", @"Report", @"option-report", K(@123, @186)); }
static ApolloActionMenuItem *ApolloAMItemTranslate(void)   { return ApolloAMNative(@"translate", @"Translate", @"option-translate", K(@0, @148)); }
static ApolloActionMenuItem *ApolloAMItemEdit(void)        { return ApolloAMNative(@"edit", @"Edit", @"option-edit", K(@101)); }
static ApolloActionMenuItem *ApolloAMItemDelete(void)      { return ApolloAMNative(@"delete", @"Delete", @"option-trash", K(@16)); }
static ApolloActionMenuItem *ApolloAMItemNSFW(void)        { return ApolloAMNative(@"nsfw", @"Mark NSFW", @"option-nsfw", K(@102, @103, @138, @139)); }
static ApolloActionMenuItem *ApolloAMItemSpoiler(void)     { return ApolloAMNative(@"spoiler", @"Mark Spoiler", @"option-spoiler", K(@49, @50, @140, @141)); }
static ApolloActionMenuItem *ApolloAMItemSelectText(void)  { return ApolloAMNative(@"select-text", @"Select Text", @"option-select-mode", K(@98, @147)); }
static ApolloActionMenuItem *ApolloAMItemModerator(void)   { return ApolloAMNative(@"moderator", @"Moderator", @"option-moderator", K(@124)); }
static ApolloActionMenuItem *ApolloAMItemFilterSub(void)   { return ApolloAMNative(@"filter-subreddit", @"Filter Subreddit", @"option-block", K(@227, @228)); }
static ApolloActionMenuItem *ApolloAMItemCollapseTop(void) { return ApolloAMNative(@"collapse-top", @"Collapse to Top", @"option-collapse-to-top", K(@14)); }
static ApolloActionMenuItem *ApolloAMItemViewReplies(void) { return ApolloAMNative(@"view-replies", @"View All Replies", @"option-view-all-replies", K(@43)); }
static ApolloActionMenuItem *ApolloAMItemParent(void)      { return ApolloAMNative(@"parent-comment", @"Parent Comment", @"option-view-parent", K(@45)); }
static ApolloActionMenuItem *ApolloAMItemFind(void)        { return ApolloAMNative(@"find", @"Find in Comments", @"option-search", K(@57)); }
static ApolloActionMenuItem *ApolloAMItemLive(void)        { return ApolloAMNative(@"live-activity", @"Live Activity", @"option-live-activity", K(@70, @71)); }
// Kind 2 ("Remind Me", option-remind-me-in) is deliberately NOT an item: Apollo
// keeps it in every post/comment sheet's buffer with an EMPTY title and the
// glass renderer drops empty-titled rows, so it never appears in a menu —
// listing it offered a row the user can't see. Uncatalogued, it passes through
// untouched like any unknown kind.
static ApolloActionMenuItem *ApolloAMItemCollapseKids(void){ return ApolloAMNative(@"collapse-children", @"Collapse Child Comments", @"option-collapse-child-comments", K(@120, @121)); }
static ApolloActionMenuItem *ApolloAMItemSubmit(void)      { return ApolloAMNative(@"submit", @"Submit Post", @"option-submit", K(@51)); }
static ApolloActionMenuItem *ApolloAMItemSubscribe(void)   { return ApolloAMNative(@"subscribe", @"Subscribe", @"option-subscribe", K(@38, @39)); }
static ApolloActionMenuItem *ApolloAMItemFavorite(void)    { return ApolloAMNative(@"favorite", @"Favorite", @"option-favorite", K(@40, @41)); }
static ApolloActionMenuItem *ApolloAMItemHideRead(void)    { return ApolloAMNative(@"hide-read", @"Hide Read Posts", @"option-hide-read", K(@243)); }
static ApolloActionMenuItem *ApolloAMItemSidebar(void)     { return ApolloAMNative(@"sidebar", @"Sidebar", @"option-sidebar", K(@36)); }
static ApolloActionMenuItem *ApolloAMItemRules(void)       { return ApolloAMNative(@"rules", @"Subreddit Rules", @"option-rules", K(@48)); }
static ApolloActionMenuItem *ApolloAMItemMultireddit(void) { return ApolloAMNative(@"multireddit", @"Add to Multireddit", @"option-multireddit", K(@54, @55)); }
static ApolloActionMenuItem *ApolloAMItemPostSize(void)    { return ApolloAMNative(@"post-size", @"Compact Posts", @"option-compact-thumbnails-right", K(@234, @235)); }
static ApolloActionMenuItem *ApolloAMItemUserFlair(void)   { return ApolloAMNative(@"user-flair", @"Set User Flair", @"option-set-flair", K(@46, @144)); }
static ApolloActionMenuItem *ApolloAMItemModerators(void)  { return ApolloAMNative(@"moderators", @"View Moderators", @"option-moderator", K(@37)); }
static ApolloActionMenuItem *ApolloAMItemNotifications(void){ return ApolloAMNative(@"notifications", @"Subreddit Notifications", @"option-notifications", K(@106)); }
static ApolloActionMenuItem *ApolloAMItemPostFlair(void) { return ApolloAMNative(@"post-flair", @"Set Post Flair", @"option-set-flair", K(@47, @145)); } // 47 = your own post, 145 = as a moderator
static ApolloActionMenuItem *ApolloAMItemExcludeSubscriptions(void) { return ApolloAMNative(@"exclude-subscriptions", @"Exclude Subscriptions", @"option-block", K(@222)); }
static ApolloActionMenuItem *ApolloAMItemMuteNotifs(void)  { return ApolloAMNative(@"mute-notifications", @"Mute Notifications", @"option-mute-notifications", K(@251, @252)); }

static ApolloActionMenuItem *ApolloAMItemFloatingTabs(void)    { return ApolloAMTweak(@"FloatingTabs", @"Keep in Floating Tab", @"pin.circle"); }
static ApolloActionMenuItem *ApolloAMItemDeletedComments(void) { return ApolloAMTweak(@"DeletedComments", @"Show Deleted Comments", @"eye"); }
static ApolloActionMenuItem *ApolloAMItemGalleryView(void)     { return ApolloAMTweak(@"GalleryView", @"Gallery View", @"square.grid.2x2"); }

// Moderator menus (kinds captured from the live sheets, signed in as a
// moderator of r/ApolloReborn, 2026-09-17). Toggle pairs share an item.
static ApolloActionMenuItem *ApolloAMItemModApprove(void)     { return ApolloAMNative(@"mod-approve", @"Approve", @"option-approve", K(@126, @127)); }
static ApolloActionMenuItem *ApolloAMItemModRemove(void)      { return ApolloAMNative(@"mod-remove", @"Remove", @"option-trash", K(@128)); }
static ApolloActionMenuItem *ApolloAMItemModSpam(void)        { return ApolloAMNative(@"mod-spam", @"Mark Spam", @"option-spam", K(@125)); }
static ApolloActionMenuItem *ApolloAMItemModOC(void)          { return ApolloAMNative(@"mod-oc", @"Mark OC", @"option-original-content", K(@216, @217)); }
static ApolloActionMenuItem *ApolloAMItemModSticky(void)      { return ApolloAMNative(@"mod-sticky", @"Sticky", @"option-sticky", K(@153, @154)); }
static ApolloActionMenuItem *ApolloAMItemModLock(void)        { return ApolloAMNative(@"mod-lock", @"Lock", @"option-lock", K(@142, @143, @146, @152)); }
static ApolloActionMenuItem *ApolloAMItemModIgnore(void)      { return ApolloAMNative(@"mod-ignore-reports", @"Ignore Reports", @"option-block", K(@130, @131)); }
static ApolloActionMenuItem *ApolloAMItemModViewReports(void) { return ApolloAMNative(@"mod-view-reports", @"View Reports", @"option-report", K(@129)); }
static ApolloActionMenuItem *ApolloAMItemModDistinguish(void) { return ApolloAMNative(@"mod-distinguish", @"Distinguish", @"option-moderator", K(@136, @137)); }
static ApolloActionMenuItem *ApolloAMItemModSuggested(void)   { return ApolloAMNative(@"mod-suggested-sort", @"Set Suggested Sort", @"option-set-suggested-sort", K(@132, @133)); }
static ApolloActionMenuItem *ApolloAMItemModContest(void)     { return ApolloAMNative(@"mod-contest-mode", @"Enable Contest Mode", @"option-contest-mode", K(@134, @135)); }
static ApolloActionMenuItem *ApolloAMItemModBanUser(void)     { return ApolloAMNative(@"mod-ban-user", @"Ban User", @"option-ban", K(@155)); }
static ApolloActionMenuItem *ApolloAMItemModNuke(void)        { return ApolloAMNative(@"mod-nuke", @"Comment Nuke", @"option-comment-nuke", K(@161)); }
static ApolloActionMenuItem *ApolloAMItemModCompliment(void)  { return ApolloAMNative(@"mod-compliment", @"Get Compliment", @"option-congratulate-self", K(@162)); }
static ApolloActionMenuItem *ApolloAMItemModMail(void)        { return ApolloAMNative(@"mod-mail", @"Mod Mail", @"option-mail", K(@164)); }
static ApolloActionMenuItem *ApolloAMItemModQueue(void)       { return ApolloAMNative(@"mod-queue", @"Mod Queue", @"option-mod-queue", K(@163)); }
static ApolloActionMenuItem *ApolloAMItemModLog(void)         { return ApolloAMNative(@"mod-log", @"Mod Log", @"option-mod-log", K(@166)); }
static ApolloActionMenuItem *ApolloAMItemModReports(void)     { return ApolloAMNative(@"mod-reports", @"Reports", @"option-report", K(@167)); }
static ApolloActionMenuItem *ApolloAMItemModSpamQueue(void)   { return ApolloAMNative(@"mod-spam-queue", @"Spam", @"option-spam", K(@168)); }
static ApolloActionMenuItem *ApolloAMItemModUnmoderated(void) { return ApolloAMNative(@"mod-unmoderated", @"Unmoderated", @"option-hide", K(@169)); }
static ApolloActionMenuItem *ApolloAMItemModEdited(void)      { return ApolloAMNative(@"mod-edited", @"Edited", @"option-edit", K(@178)); }
static ApolloActionMenuItem *ApolloAMItemModAllComments(void) { return ApolloAMNative(@"mod-all-comments", @"All Comments", @"option-comments", K(@203)); }
static ApolloActionMenuItem *ApolloAMItemModTraffic(void)     { return ApolloAMNative(@"mod-traffic", @"Traffic Stats", @"option-traffic-stats", K(@165)); }
static ApolloActionMenuItem *ApolloAMItemModBanUsers(void)    { return ApolloAMNative(@"mod-ban-users", @"Ban Users", @"option-ban", K(@170)); }
static ApolloActionMenuItem *ApolloAMItemModMuteUsers(void)   { return ApolloAMNative(@"mod-mute-users", @"Mute Users", @"option-mute-modmail", K(@171)); }
static ApolloActionMenuItem *ApolloAMItemModEditFlair(void)   { return ApolloAMNative(@"mod-edit-flair", @"Edit Flair", @"option-set-flair", K(@172)); }
static ApolloActionMenuItem *ApolloAMItemModRemovalReason(void){ return ApolloAMNative(@"mod-removal-reasons", @"Removal Reason", @"option-removal-reason", K(@209)); }
static ApolloActionMenuItem *ApolloAMItemModRules(void)       { return ApolloAMNative(@"mod-rules", @"Rules", @"option-rules", K(@175)); }
static ApolloActionMenuItem *ApolloAMItemModAutoMod(void)     { return ApolloAMNative(@"mod-automoderator", @"AutoModerator", @"option-automoderator", K(@210)); }
static ApolloActionMenuItem *ApolloAMItemModApproved(void)    { return ApolloAMNative(@"mod-approved-submitters", @"Approved Submitters", @"option-approved-submitters", K(@179)); }
static ApolloActionMenuItem *ApolloAMItemModModerators(void)  { return ApolloAMNative(@"mod-moderators", @"Moderators", @"option-moderator", K(@177)); }

#undef K

// Marks a menu's usual rows vs. its sometimes rows and joins them.
static NSArray<ApolloActionMenuItem *> *ApolloAMCatalogWithUsual(NSArray<ApolloActionMenuItem *> *usual,
                                                               NSArray<ApolloActionMenuItem *> *sometimes) {
    for (ApolloActionMenuItem *item in usual) item.usuallyShown = YES;
    for (ApolloActionMenuItem *item in sometimes) item.usuallyShown = NO;
    return [usual arrayByAddingObjectsFromArray:sometimes];
}

// Membership verified against each native builder’s addAction calls
// (docs/context-menu-verification.md). Never copy a kind into a second
// context just because its title sounds relevant there.
// Each menu's catalogue, in Apollo's own default order as the sheets present
// it (captured from the live menus in the simulator, signed in as a
// moderator so the mod row shows too); rows Apollo only adds sometimes (your
// own post's Edit/Delete, deeper comments' Parent Comment, …) follow, in the
// order the metadata table lists their kinds.
static NSArray<ApolloActionMenuItem *> *ApolloActionMenuBuildCatalog(ApolloActionMenuContext context) {
    if ([context isEqualToString:ApolloActionMenuContextFeed]) {
        // Subreddit: 51,39,41,243,36,48,227,55,235,46,37,15,106 (+ Gallery
        // View after Submit Post). Home/Popular/All show the subset 243,235,15.
        // Submit Post is locked: Apollo keeps it at the head of the sheet (on
        // Liquid Glass with Polls on it is the four new-post buttons), so it
        // is neither movable nor hideable — everything after it is.
        return ApolloAMCatalogWithUsual(
            @[ ApolloAMLocked(ApolloAMItemSubmit()), ApolloAMItemGalleryView(), ApolloAMItemSubscribe(), ApolloAMItemFavorite(),
               ApolloAMItemHideRead(), ApolloAMItemSidebar(), ApolloAMItemRules(), ApolloAMItemFilterSub(),
               ApolloAMItemMultireddit(), ApolloAMItemPostSize(), ApolloAMItemUserFlair(), ApolloAMItemModerators(),
               ApolloAMItemShare(), ApolloAMItemNotifications() ],
            @[ ApolloAMItemExcludeSubscriptions() ]);
    }
    if ([context isEqualToString:ApolloActionMenuContextPost]) {
        // Feed cell: (124,)4,5,7,12,42,44,239,241,15,17,1,122,123,2 (+ Keep in
        // Floating Tab appended when that feature is on).
        return ApolloAMCatalogWithUsual(
            @[ ApolloAMItemModerator(), ApolloAMItemUpvote(), ApolloAMItemDownvote(), ApolloAMItemSave(),
               ApolloAMItemReply(), ApolloAMItemAuthor(), ApolloAMItemSubreddit(), ApolloAMItemHide(),
               ApolloAMItemHideAbove(), ApolloAMItemShare(), ApolloAMItemShareImage(), ApolloAMItemCrosspost(),
               ApolloAMItemAward(), ApolloAMItemReport(), ApolloAMItemFloatingTabs() ],
            @[ ApolloAMItemTranslate(), ApolloAMItemFilterSub(), ApolloAMItemEdit(), ApolloAMItemDelete(),
               ApolloAMItemNSFW(), ApolloAMItemSpoiler(), ApolloAMItemPostFlair(), ApolloAMItemMuteNotifs() ]);
    }
    if ([context isEqualToString:ApolloActionMenuContextPostDetail]) {
        // Comments nav bar: 4,5,7,12,42,44,120,98,15,17,1,57,122,123,70,2 (+
        // Show Deleted Comments / Keep in Floating Tab appended).
        return ApolloAMCatalogWithUsual(
            @[ ApolloAMItemUpvote(), ApolloAMItemDownvote(), ApolloAMItemSave(), ApolloAMItemReply(),
               ApolloAMItemAuthor(), ApolloAMItemSubreddit(), ApolloAMItemCollapseKids(), ApolloAMItemSelectText(),
               ApolloAMItemShare(), ApolloAMItemShareImage(), ApolloAMItemCrosspost(), ApolloAMItemFind(),
               ApolloAMItemAward(), ApolloAMItemReport(), ApolloAMItemLive(),
               ApolloAMItemDeletedComments(), ApolloAMItemFloatingTabs() ],
            @[ ApolloAMItemTranslate(), ApolloAMItemEdit(), ApolloAMItemDelete(),
               ApolloAMItemNSFW(), ApolloAMItemSpoiler(), ApolloAMItemPostFlair(), ApolloAMItemMuteNotifs() ]);
    }
    if ([context isEqualToString:ApolloActionMenuContextComment]) {
        // Comment: (124,)3,5,7,12,42,98,15,17,14,122,123,2.
        return ApolloAMCatalogWithUsual(
            @[ ApolloAMItemModerator(), ApolloAMItemUpvote(), ApolloAMItemDownvote(), ApolloAMItemSave(),
               ApolloAMItemReply(), ApolloAMItemAuthor(), ApolloAMItemSelectText(), ApolloAMItemShare(),
               ApolloAMItemShareImage(), ApolloAMItemCollapseTop(), ApolloAMItemAward(), ApolloAMItemReport() ],
            @[ ApolloAMItemViewReplies(), ApolloAMItemParent(), ApolloAMItemTranslate(),
               ApolloAMItemEdit(), ApolloAMItemDelete(), ApolloAMItemMuteNotifs() ]);
    }
    if ([context isEqualToString:ApolloActionMenuContextModeratorSubreddit]) {
        // The feed nav bar's shield: 164,163,166,167,168,169,178,203,165,170,
        // 171,172,209,175,210,179,177,186,162.
        return ApolloAMCatalogWithUsual(
            @[ ApolloAMItemModMail(), ApolloAMItemModQueue(), ApolloAMItemModLog(), ApolloAMItemModReports(),
               ApolloAMItemModSpamQueue(), ApolloAMItemModUnmoderated(), ApolloAMItemModEdited(), ApolloAMItemModAllComments(),
               ApolloAMItemModTraffic(), ApolloAMItemModBanUsers(), ApolloAMItemModMuteUsers(), ApolloAMItemModEditFlair(),
               ApolloAMItemModRemovalReason(), ApolloAMItemModRules(), ApolloAMItemModAutoMod(), ApolloAMItemModApproved(),
               ApolloAMItemModModerators(), ApolloAMItemReport(), ApolloAMItemModCompliment() ],
            @[]);
    }
    if ([context isEqualToString:ApolloActionMenuContextModeratorPost]) {
        // A post's shield (cell, ••• Moderator row, comments nav bar — one
        // builder): 126,128,125,138,140,216,145,153,142,130,155,162. The rest
        // appear for your own post, a reported one, or in the comments view.
        return ApolloAMCatalogWithUsual(
            @[ ApolloAMItemModApprove(), ApolloAMItemModRemove(), ApolloAMItemModSpam(), ApolloAMItemNSFW(),
               ApolloAMItemSpoiler(), ApolloAMItemModOC(), ApolloAMItemPostFlair(), ApolloAMItemModSticky(),
               ApolloAMItemModLock(), ApolloAMItemModIgnore(), ApolloAMItemModBanUser(), ApolloAMItemModCompliment() ],
            @[ ApolloAMItemModDistinguish(), ApolloAMItemModViewReports(), ApolloAMItemModSuggested(), ApolloAMItemModContest() ]);
    }
    if ([context isEqualToString:ApolloActionMenuContextModeratorComment]) {
        // A comment's shield / ••• Moderator row: 126,128,125,130,142,161,155,162.
        return ApolloAMCatalogWithUsual(
            @[ ApolloAMItemModApprove(), ApolloAMItemModRemove(), ApolloAMItemModSpam(), ApolloAMItemModIgnore(),
               ApolloAMItemModLock(), ApolloAMItemModNuke(), ApolloAMItemModBanUser(), ApolloAMItemModCompliment() ],
            @[ ApolloAMItemModDistinguish(), ApolloAMItemModSticky(), ApolloAMItemModViewReports() ]);
    }
    return @[];
}

// Rows kept in the usual lists above for their default POSITION but not
// usually present: the Moderator row (mods only) and the tweak rows whose
// feature is off by default.
static void ApolloAMDemoteSometimesRows(NSArray<ApolloActionMenuItem *> *catalog) {
    NSSet<NSString *> *sometimes = [NSSet setWithArray:@[ @"moderator",
                                                           ApolloActionMenuItemIDForSpec(@"FloatingTabs"),
                                                           ApolloActionMenuItemIDForSpec(@"DeletedComments") ]];
    for (ApolloActionMenuItem *item in catalog) {
        if ([sometimes containsObject:item.itemID]) item.usuallyShown = NO;
    }
}

NSArray<ApolloActionMenuItem *> *ApolloActionMenuCatalog(ApolloActionMenuContext context) {
    static NSMutableDictionary<NSString *, NSArray<ApolloActionMenuItem *> *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [NSMutableDictionary dictionary]; });
    if (!ApolloActionMenuContextIsValid(context)) return @[];
    @synchronized (cache) {
        NSArray<ApolloActionMenuItem *> *catalog = cache[context];
        if (!catalog) {
            catalog = ApolloActionMenuBuildCatalog(context);
            ApolloAMDemoteSometimesRows(catalog);
            cache[context] = catalog;
        }
        return catalog;
    }
}

ApolloActionMenuItem *ApolloActionMenuCatalogItem(ApolloActionMenuContext context, NSString *itemID) {
    if (itemID.length == 0) return nil;
    for (ApolloActionMenuItem *item in ApolloActionMenuCatalog(context)) {
        if ([item.itemID isEqualToString:itemID]) return item;
    }
    return nil;
}

NSString *ApolloActionMenuItemIDForKind(ApolloActionMenuContext context, NSUInteger kind) {
    NSNumber *boxed = @(kind);
    for (ApolloActionMenuItem *item in ApolloActionMenuCatalog(context)) {
        if ([item.kinds containsObject:boxed]) return item.itemID;
    }
    return nil;
}

#pragma mark - Saved layout

static NSDictionary<NSString *, NSDictionary *> *ApolloActionMenuStoredLayouts(void) {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:UDKeyActionMenuLayouts];
    return [stored isKindOfClass:[NSDictionary class]] ? stored : @{};
}

static NSDictionary *ApolloActionMenuStoredLayout(ApolloActionMenuContext context) {
    id layout = ApolloActionMenuStoredLayouts()[context ?: @""];
    return [layout isKindOfClass:[NSDictionary class]] ? layout : nil;
}

static NSArray<NSString *> *ApolloActionMenuStringArray(id value) {
    if (![value isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray<NSString *> *strings = [NSMutableArray array];
    for (id element in (NSArray *)value) {
        if ([element isKindOfClass:[NSString class]] && ![strings containsObject:element]) [strings addObject:element];
    }
    return strings;
}

static NSArray<NSString *> *ApolloActionMenuDefaultOrder(ApolloActionMenuContext context) {
    return [ApolloActionMenuCatalog(context) valueForKey:@"itemID"];
}

// The shape every stored or derived order takes: the context's locked items
// first, in catalogue order, then `order` without them. A locked row is never
// offered for dragging, so nothing the user does can move it off the head of
// the menu — and a stored order that predates the lock is straightened here.
static NSArray<NSString *> *ApolloActionMenuLockedFirst(ApolloActionMenuContext context, NSArray<NSString *> *order) {
    NSMutableArray<NSString *> *result = [NSMutableArray arrayWithCapacity:order.count];
    for (ApolloActionMenuItem *item in ApolloActionMenuCatalog(context)) {
        if (item.locked) [result addObject:item.itemID];
    }
    for (NSString *itemID in order) {
        if (![result containsObject:itemID]) [result addObject:itemID];
    }
    return result;
}

NSArray<NSString *> *ApolloActionMenuResolvedOrder(ApolloActionMenuContext context) {
    NSArray<NSString *> *catalogOrder = ApolloActionMenuDefaultOrder(context);
    NSArray<NSString *> *stored = ApolloActionMenuStringArray(ApolloActionMenuStoredLayout(context)[kApolloActionMenuLayoutOrderKey]);
    if (stored.count == 0) {
        NSMutableArray<NSString *> *nativeOrder = [NSMutableArray array];
        for (NSString *itemID in ApolloActionMenuLastPresentedItemIDs(context)) {
            if ([catalogOrder containsObject:itemID]) [nativeOrder addObject:itemID];
        }
        for (NSString *itemID in catalogOrder) {
            if (![nativeOrder containsObject:itemID]) [nativeOrder addObject:itemID];
        }
        return ApolloActionMenuLockedFirst(context, nativeOrder);
    }

    NSMutableArray<NSString *> *order = [NSMutableArray arrayWithCapacity:catalogOrder.count];
    for (NSString *itemID in stored) {
        if ([catalogOrder containsObject:itemID]) [order addObject:itemID];
    }
    // Rows the catalogue gained after this layout was saved land where Apollo
    // puts them by default — appended, in catalogue order, never lost.
    for (NSString *itemID in catalogOrder) {
        if (![order containsObject:itemID]) [order addObject:itemID];
    }
    return ApolloActionMenuLockedFirst(context, order);
}

NSSet<NSString *> *ApolloActionMenuHiddenItemIDs(ApolloActionMenuContext context) {
    NSArray<NSString *> *hidden = ApolloActionMenuStringArray(ApolloActionMenuStoredLayout(context)[kApolloActionMenuLayoutHiddenKey]);
    NSMutableSet<NSString *> *set = [NSMutableSet set];
    for (NSString *itemID in hidden) {
        ApolloActionMenuItem *item = ApolloActionMenuCatalogItem(context, itemID);
        if (item && !item.locked) [set addObject:itemID]; // a locked row is never hidden
    }
    return set;
}

BOOL ApolloActionMenuIsItemHidden(ApolloActionMenuContext context, NSString *itemID) {
    return itemID.length > 0 && [ApolloActionMenuHiddenItemIDs(context) containsObject:itemID];
}

NSUInteger ApolloActionMenuRankForItemID(ApolloActionMenuContext context, NSString *itemID) {
    if (itemID.length == 0 || !ApolloActionMenuHasCustomOrder(context)) return NSNotFound;
    return [ApolloActionMenuResolvedOrder(context) indexOfObject:itemID];
}

BOOL ApolloActionMenuHasCustomOrder(ApolloActionMenuContext context) {
    return ApolloActionMenuStringArray(ApolloActionMenuStoredLayout(context)[kApolloActionMenuLayoutOrderKey]).count > 0;
}

BOOL ApolloActionMenuContextIsCustomized(ApolloActionMenuContext context) {
    return ApolloActionMenuHiddenItemIDs(context).count > 0 || ApolloActionMenuHasCustomOrder(context);
}

NSUInteger ApolloActionMenuCustomizedContextCount(void) {
    NSUInteger count = 0;
    for (ApolloActionMenuContext context in ApolloActionMenuAllContexts()) {
        if (ApolloActionMenuContextIsCustomized(context)) count++;
    }
    return count;
}

static void ApolloActionMenuWriteLayout(ApolloActionMenuContext context, NSDictionary *layout) {
    if (!ApolloActionMenuContextIsValid(context)) return;
    NSMutableDictionary *layouts = [ApolloActionMenuStoredLayouts() mutableCopy];
    if (layout) layouts[context] = layout;
    else [layouts removeObjectForKey:context];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (layouts.count > 0) [defaults setObject:layouts forKey:UDKeyActionMenuLayouts];
    else [defaults removeObjectForKey:UDKeyActionMenuLayouts];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloActionMenuLayoutsChangedNotification object:context];
}

void ApolloActionMenuSetOrder(ApolloActionMenuContext context, NSArray<NSString *> *order) {
    NSArray<NSString *> *catalogOrder = ApolloActionMenuDefaultOrder(context);
    NSMutableArray<NSString *> *clean = [NSMutableArray arrayWithCapacity:catalogOrder.count];
    for (NSString *itemID in ApolloActionMenuStringArray(order)) {
        if ([catalogOrder containsObject:itemID]) [clean addObject:itemID];
    }
    for (NSString *itemID in catalogOrder) {
        if (![clean containsObject:itemID]) [clean addObject:itemID];
    }
    NSArray<NSString *> *normalized = ApolloActionMenuLockedFirst(context, clean);
    NSArray<NSString *> *hidden = ApolloActionMenuHiddenItemIDs(context).allObjects;
    ApolloLog(@"[ActionMenuLayout] %@ order -> %@", context, [normalized componentsJoinedByString:@", "]);
    ApolloActionMenuWriteLayout(context, @{ kApolloActionMenuLayoutOrderKey: normalized,
                                            kApolloActionMenuLayoutHiddenKey: hidden });
}

void ApolloActionMenuSetItemHidden(ApolloActionMenuContext context, NSString *itemID, BOOL hidden) {
    ApolloActionMenuItem *item = ApolloActionMenuCatalogItem(context, itemID);
    if (!item || item.locked) return;
    NSMutableSet<NSString *> *set = [ApolloActionMenuHiddenItemIDs(context) mutableCopy];
    if (hidden) [set addObject:itemID];
    else [set removeObject:itemID];
    // Keep the stored hidden list in catalogue order so backups diff cleanly.
    NSMutableArray<NSString *> *hiddenList = [NSMutableArray array];
    for (NSString *candidate in ApolloActionMenuDefaultOrder(context)) {
        if ([set containsObject:candidate]) [hiddenList addObject:candidate];
    }
    ApolloLog(@"[ActionMenuLayout] %@ %@ -> %@", context, itemID, hidden ? @"hidden" : @"shown");
    ApolloActionMenuWriteLayout(context, @{ kApolloActionMenuLayoutOrderKey: ApolloActionMenuStringArray(ApolloActionMenuStoredLayout(context)[kApolloActionMenuLayoutOrderKey]),
                                            kApolloActionMenuLayoutHiddenKey: hiddenList });
}

void ApolloActionMenuResetContext(ApolloActionMenuContext context) {
    ApolloLog(@"[ActionMenuLayout] %@ reset to default", context);
    ApolloActionMenuWriteLayout(context, nil);
}

#pragma mark - What the menu actually offered

void ApolloActionMenuRecordPresentedItemIDs(ApolloActionMenuContext context, NSArray<NSString *> *itemIDs) {
    if (!ApolloActionMenuContextIsValid(context)) return;
    NSArray<NSString *> *clean = ApolloActionMenuStringArray(itemIDs);
    if (clean.count == 0) return; // A failed/empty read is not a new complete snapshot.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id stored = [defaults objectForKey:UDKeyActionMenuLastPresented];
    NSMutableDictionary *all = [stored isKindOfClass:[NSDictionary class]] ? [stored mutableCopy] : [NSMutableDictionary dictionary];
    if ([ApolloActionMenuStringArray(all[context]) isEqualToArray:clean]) return; // unchanged, no churn
    all[context] = clean;
    [defaults setObject:all forKey:UDKeyActionMenuLastPresented];
}

NSArray<NSString *> *ApolloActionMenuLastPresentedItemIDs(ApolloActionMenuContext context) {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:UDKeyActionMenuLastPresented];
    if (![stored isKindOfClass:[NSDictionary class]]) return nil;
    id list = ((NSDictionary *)stored)[context ?: @""];
    if (![list isKindOfClass:[NSArray class]]) return nil;
    NSArray<NSString *> *clean = ApolloActionMenuStringArray(list);
    return clean.count > 0 ? clean : nil;
}

BOOL ApolloActionMenuItemWasOffered(ApolloActionMenuContext context, NSString *itemID) {
    NSArray<NSString *> *seen = ApolloActionMenuLastPresentedItemIDs(context);
    if (seen) return [seen containsObject:itemID];
    return ApolloActionMenuCatalogItem(context, itemID).usuallyShown;
}

// Every non-hidden item, in order. Rows the menu didn't offer last time are
// kept (the preview fades them) rather than dropped: dropping them meant a
// row dragged to the top of the list vanished from the mock — a feature row
// like Keep in Floating Tab, say, when the last sheet happened not to carry it.
NSArray<ApolloActionMenuItem *> *ApolloActionMenuPreviewItems(ApolloActionMenuContext context) {
    NSSet<NSString *> *hidden = ApolloActionMenuHiddenItemIDs(context);
    NSMutableArray<ApolloActionMenuItem *> *items = [NSMutableArray array];
    for (NSString *itemID in ApolloActionMenuResolvedOrder(context)) {
        if ([hidden containsObject:itemID]) continue;
        ApolloActionMenuItem *item = ApolloActionMenuCatalogItem(context, itemID);
        if (item) [items addObject:item];
    }
    return items;
}

#pragma mark - Runtime context arming

// Apollo builds and presents a ••• sheet synchronously from its tap handler,
// so the pending context is confined to that call and cleared in @finally.
// The age check also rejects an unexpectedly slow synchronous handler.
static const NSTimeInterval kApolloActionMenuArmWindow = 2.0;
static ApolloActionMenuContext sApolloActionMenuArmedContext = nil;
static CFAbsoluteTime sApolloActionMenuArmedAt = 0;

void ApolloActionMenuArmContext(ApolloActionMenuContext context) {
    if (!NSThread.isMainThread || !ApolloActionMenuContextIsValid(context)) return;
    sApolloActionMenuArmedContext = context;
    sApolloActionMenuArmedAt = CFAbsoluteTimeGetCurrent();
}

void ApolloActionMenuDisarmContext(void) {
    if (!NSThread.isMainThread) return;
    sApolloActionMenuArmedContext = nil;
}

ApolloActionMenuContext ApolloActionMenuTakeArmedContext(void) {
    if (!NSThread.isMainThread) return nil;
    ApolloActionMenuContext context = sApolloActionMenuArmedContext;
    if (!context) return nil;
    sApolloActionMenuArmedContext = nil;
    if (CFAbsoluteTimeGetCurrent() - sApolloActionMenuArmedAt > kApolloActionMenuArmWindow) return nil;
    return context;
}
