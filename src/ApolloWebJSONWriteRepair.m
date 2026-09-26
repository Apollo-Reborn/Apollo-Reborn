#import "ApolloWebJSONWriteRepair.h"

#ifdef APOLLO_WEBJSON_WRITE_REPAIR_TESTING
// Foundation-only on the build host: the harness supplies the identity lookups
// and the prefetch, and logs go to NSLog.
#define ApolloLog(fmt, ...) NSLog((fmt), ##__VA_ARGS__)
NSString *ApolloActiveWebSessionUsername(void);
NSString *ApolloActiveAccountUsername(void);
#else
#import "ApolloCommon.h"
#import "ApolloAccountCredentials.h" // ApolloActiveAccountUsername() — write-fixup author for API-key actives
#import "ApolloWebSessionStore.h"    // ApolloActiveWebSessionUsername()
#endif
#import <objc/message.h>
#import <os/lock.h>

#pragma mark - Write-response shape fixup (item 4: comment edit/post re-render)

// Pull the first Reddit fullname (t1_…, t3_…) out of an old-reddit "content"
// HTML blob; it's emitted as data-fullname="t1_xxx" on the comment <div>.
static NSString *ApolloWebJSONFullnameFromLegacyContent(NSString *html) {
    if (html.length == 0) return nil;
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"data-fullname=\"(t[0-9]_[0-9a-z]+)\""
                                                       options:NSRegularExpressionCaseInsensitive error:NULL];
    });
    NSTextCheckingResult *m = [re firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
    if (m && m.numberOfRanges > 1) return [html substringWithRange:[m rangeAtIndex:1]];
    return nil;
}

// Extracts the permalink, subreddit, and link id36 from an old-reddit content
// blob's data-permalink attribute ("/r/<sub>/comments/<id36>/slug/[<cid36>/]").
static BOOL ApolloWebJSONPermalinkPartsFromLegacyContent(NSString *html, NSString **outPermalink,
                                                         NSString **outSubreddit, NSString **outLinkId36) {
    if (html.length == 0) return NO;
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"data-permalink=\"(/r/([^/\"]+)/comments/([0-9a-z]+)/[^\"]*)\""
                                                       options:NSRegularExpressionCaseInsensitive error:NULL];
    });
    NSTextCheckingResult *m = [re firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
    if (!m || m.numberOfRanges < 4) return NO;
    if (outPermalink) *outPermalink = [html substringWithRange:[m rangeAtIndex:1]];
    if (outSubreddit) *outSubreddit = [html substringWithRange:[m rangeAtIndex:2]];
    if (outLinkId36) *outLinkId36 = [html substringWithRange:[m rangeAtIndex:3]];
    return YES;
}

// Defined with the write-repair helpers below; used by the legacy synthesis too.
typedef struct {
    NSString *username;
    NSString *subreddit;
    NSString *subredditFullName;
    NSString *linkFullName;
    NSString *parentFullName;
} ApolloWebJSONWriteContext;
// Resolved from the markdown Reddit echoed back, plus any location fields the
// degraded payload happened to keep (they distinguish two overlapping writes
// whose markdown is identical), so overlapping writes can't cross-contaminate
// each other's repairs. See the pending-write store below.
static ApolloWebJSONWriteContext ApolloWebJSONWriteContextForResponse(id responseBody,
                                                                      NSString *subredditHint,
                                                                      NSString *linkHint,
                                                                      NSString *parentHint);

// Extracts the comment author from an old-reddit content blob's data-author
// attribute. Authoritative when present — it is Reddit's own record of who the
// write ran as, with the account's canonical capitalization.
static NSString *ApolloWebJSONAuthorFromLegacyContent(NSString *html) {
    if (html.length == 0) return nil;
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"data-author=\"([^\"]+)\"" options:0 error:NULL];
    });
    NSTextCheckingResult *m = [re firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
    if (!m || m.numberOfRanges < 2) return nil;
    NSString *author = [html substringWithRange:[m rangeAtIndex:1]];
    return author.length > 0 ? author : nil;
}

// Minimal HTML-escape for synthesizing a body_html when the legacy response
// carries no contentHTML. Reddit's own body_html wraps in <div class="md">.
static NSString *ApolloWebJSONEscapedBodyHTML(NSString *body) {
    NSMutableString *escaped = [body mutableCopy] ?: [NSMutableString string];
    [escaped replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, escaped.length)];
    return [NSString stringWithFormat:@"<div class=\"md\"><p>%@</p></div>", escaped];
}

// Builds a modern comment `data` dict directly from the legacy old-reddit
// response thing — no network, so it works when the serializer runs on the
// main thread (where the sync refetch is forbidden) and when info.json hasn't
// caught up with a seconds-old comment yet. The legacy dict carries the
// submitted markdown (contentText), the rendered body (contentHTML), the
// parent fullname (parent), and the link fullname (link); the author is the
// web-session account that issued the write (comment posting always happens
// as the foreground account). Optimistic fields (score 1, fresh timestamp)
// self-correct on the next thread refresh.
static NSDictionary *ApolloWebJSONSynthesizeModernThingData(NSString *fullname, NSDictionary *legacy, BOOL isEdit) {
    if (fullname.length == 0 || ![fullname hasPrefix:@"t1_"]) return nil;

    NSString *content = [legacy[@"content"] isKindOfClass:[NSString class]] ? legacy[@"content"] : nil;
    NSString *body = [legacy[@"contentText"] isKindOfClass:[NSString class]] ? legacy[@"contentText"] : nil;
    NSString *bodyHTML = [legacy[@"contentHTML"] isKindOfClass:[NSString class]] ? legacy[@"contentHTML"] : nil;
    if (body.length == 0 && bodyHTML.length == 0) return nil; // nothing renderable to show

    NSString *legacyParent = ([legacy[@"parent"] isKindOfClass:[NSString class]]
                              && [(NSString *)legacy[@"parent"] length] > 0) ? legacy[@"parent"] : nil;
    NSString *legacyLink = ([legacy[@"link"] isKindOfClass:[NSString class]]
                            && [(NSString *)legacy[@"link"] length] > 0) ? legacy[@"link"] : nil;
    NSString *permalink = nil, *subreddit = nil, *linkId36 = nil;
    ApolloWebJSONPermalinkPartsFromLegacyContent(content, &permalink, &subreddit, &linkId36);

    // The submitted markdown identifies WHICH outstanding write this response
    // belongs to, so a second comment posted while this one was in flight can't
    // lend it its author or its thread. Whatever location the legacy dict still
    // carries goes along as identity hints — they are what tells two
    // overlapping writes apart when their markdown is identical. The parent
    // hint is creates-only: an edited comment's real parent was never captured
    // (the edit context has no parentFullName), so it could only contradict
    // falsely. Resolve once and reuse below.
    NSString *linkHint = legacyLink ?: (linkId36.length > 0 ? [@"t3_" stringByAppendingString:linkId36] : nil);
    ApolloWebJSONWriteContext ctx = ApolloWebJSONWriteContextForResponse(body,
                                                                         subreddit.length > 0 ? subreddit : nil,
                                                                         linkHint,
                                                                         isEdit ? nil : legacyParent);

    // Author, in trust order: Reddit's own data-author attribute in the legacy
    // content blob, then the identity captured from the submitting RDKClient
    // (correct for non-active posting accounts), then the active web-session
    // account, then the active API-key (OAuth) account. Capitalization matters
    // because Apollo gates the Edit affordance on
    // comment.author == currentUser.username.
    NSString *author = ApolloWebJSONAuthorFromLegacyContent(content);
    if (author.length == 0) author = ctx.username;
    if (author.length == 0) author = ApolloActiveWebSessionUsername();
    if (author.length == 0) author = ApolloActiveAccountUsername();
    if (author.length == 0) return nil;

    NSMutableDictionary *modern = [NSMutableDictionary dictionary];
    modern[@"id"] = [fullname substringFromIndex:3];
    modern[@"name"] = fullname;
    modern[@"author"] = author;
    modern[@"body"] = body.length > 0 ? body : @"";
    modern[@"body_html"] = bodyHTML.length > 0 ? bodyHTML : ApolloWebJSONEscapedBodyHTML(body ?: @"");
    if (legacyParent) modern[@"parent_id"] = legacyParent;
    if (legacyLink) modern[@"link_id"] = legacyLink;

    if (permalink.length > 0) modern[@"permalink"] = permalink;
    if (subreddit.length > 0) modern[@"subreddit"] = subreddit;
    if (!modern[@"link_id"] && linkId36.length > 0) modern[@"link_id"] = [@"t3_" stringByAppendingString:linkId36];

    // Legacy blobs without a data-permalink (or with the link/parent fields
    // stripped) still need the thing's location — an empty subreddit disables
    // the own-flair backfill and the moderator shield on the inserted cell.
    // The write context captured at submit time knows it.
    if (!modern[@"subreddit"] && ctx.subreddit) modern[@"subreddit"] = ctx.subreddit;
    if (ctx.subredditFullName) modern[@"subreddit_id"] = ctx.subredditFullName;
    if (!modern[@"link_id"] && ctx.linkFullName) modern[@"link_id"] = ctx.linkFullName;
    if (!modern[@"parent_id"] && !isEdit && (ctx.parentFullName ?: ctx.linkFullName)) {
        modern[@"parent_id"] = ctx.parentFullName ?: ctx.linkFullName;
    }
    if (!modern[@"permalink"] && modern[@"subreddit"] && [modern[@"link_id"] isKindOfClass:[NSString class]]
        && [modern[@"link_id"] hasPrefix:@"t3_"]) {
        modern[@"permalink"] = [NSString stringWithFormat:@"/r/%@/comments/%@/_/%@/",
                                modern[@"subreddit"], [modern[@"link_id"] substringFromIndex:3], modern[@"id"]];
    }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    modern[@"created"] = @(now);
    modern[@"created_utc"] = @(now);
    modern[@"edited"] = isEdit ? @(now) : @NO;
    modern[@"score"] = @1;
    modern[@"ups"] = @1;
    modern[@"downs"] = @0;
    modern[@"likes"] = @YES;
    modern[@"score_hidden"] = @NO;
    modern[@"replies"] = @"";
    modern[@"gilded"] = @0;
    modern[@"all_awardings"] = @[];
    modern[@"total_awards_received"] = @0;
    modern[@"saved"] = @NO;
    modern[@"archived"] = @NO;
    modern[@"stickied"] = @NO;
    modern[@"locked"] = @NO;
    modern[@"collapsed"] = @NO;
    modern[@"controversiality"] = @0;
    modern[@"send_replies"] = @YES;
    return modern;
}

// YES for a usable non-empty string. JSON null arrives as NSNull, which must
// count as missing everywhere in the write-response repair.
static BOOL ApolloWebJSONIsNonEmptyString(id value) {
    return [value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0;
}

// The context of a comment/edit write, captured at submit time
// (ApolloWebJSONNoteCommentWriteContext, called from the identity module's
// submit hooks). The username comes from the RDKClient that issued the write —
// the ACTIVE account is the wrong answer when the composer's account chooser
// posted as someone else (temporaryPostingAccount): each account owns its own
// RDKClient, so the submitting client's currentUser IS the posting identity.
// The subreddit/link/parent fields come from the submit call's typed target
// (link or parent comment) — the wild degraded /api/comment payload observed
// on-device (2026-08, 36 keys) strips those alongside author/created/score,
// and an empty model.subreddit silently disables both the own-flair backfill
// and the moderator shield on the freshly inserted cell.
//
// These are KEYED PER WRITE, not a single global slot. Apollo lets a comment be
// submitted while an earlier one is still in flight (different thread, different
// subreddit, even a different account), and the response serializer runs well
// after submit — with one slot the second submit overwrote the first before the
// first's degraded response was repaired, so the earlier comment could be
// synthesized with the later post's subreddit/link/parent/permalink/author and
// render or navigate as if it belonged to another thread.
//
// The correlation key is the submitted markdown, which Reddit echoes back as
// `body` (modern shape) / `contentText` (legacy shape) — no plumbing through
// RedditKit's request internals required. Duplicate bodies are PRESERVED, not
// deduped: two overlapping writes can legitimately carry identical markdown
// (a "Thanks" posted in two different threads), and evicting the earlier
// capture would hand the first response the second write's context. An
// ambiguous key is resolved only by response-side identity — location fields
// the degraded payload happened to keep that positively contradict a candidate
// rule it out — and when that can't narrow the set to one, the repair uses
// only the fields every remaining candidate agrees on. The same unanimity
// fallback covers a response that can't be matched at all (body absent or
// normalized beyond recognition): a response never adopts one candidate's
// thread over another's.
@interface ApolloWebJSONPendingWrite : NSObject
@property (nonatomic, copy, nullable) NSString *username;
@property (nonatomic, copy, nullable) NSString *subreddit;
@property (nonatomic, copy, nullable) NSString *subredditFullName;
@property (nonatomic, copy, nullable) NSString *linkFullName;
@property (nonatomic, copy, nullable) NSString *parentFullName;
// Normalized submitted markdown; nil when the submit call had no usable text.
@property (nonatomic, copy, nullable) NSString *bodyKey;
@property (nonatomic) NSTimeInterval capturedAt;
// Set once this entry has repaired a response. Kept around (not deleted) for
// the rest of the TTL so a re-serialized retry of the same response still
// matches it exactly, but excluded from the ambiguity set so a finished write
// can't keep suppressing fields for a later one.
@property (nonatomic) BOOL consumed;
// Edits only: the fullname being edited, plus what can stand in for Reddit's
// modern copy of it when the response comes back degraded — the pre-edit
// model itself for a comment (everything but the body is still true after the
// edit), or the async info.json refetch for a self-text post (no model is in
// hand there). See ApolloWebJSONEditFillForFullname.
@property (nonatomic, copy, nullable) NSString *editedFullName;
@property (nonatomic, strong, nullable) id editedThing;
@property (nonatomic, copy, nullable) NSDictionary *prefetchedData;
@end

@implementation ApolloWebJSONPendingWrite
@end

// Bounded so a burst of writes can't grow this without limit; comment writes
// are user-paced, so a handful of slots is far more than enough overlap.
static NSUInteger const kApolloWebJSONMaxPendingWrites = 8;
// Comfortably covers submit -> response -> serializer.
static NSTimeInterval const kApolloWebJSONWriteContextTTL = 60.0;
static NSMutableArray<ApolloWebJSONPendingWrite *> *sApolloWebJSONPendingWrites = nil;
static os_unfair_lock sApolloWebJSONLastWriteLock = OS_UNFAIR_LOCK_INIT;

static NSString *ApolloWebJSONCopiedNonEmptyString(id value) {
    return ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) ? [value copy] : nil;
}

// Reddit round-trips the submitted markdown, but not always byte-for-byte: line
// endings come back normalized and trailing whitespace trimmed. Compare on a
// canonical form so a legitimate match isn't missed (a missed match is not
// wrong, only weaker — it drops to the unanimous-fields path).
static NSString *ApolloWebJSONWriteBodyKey(id text) {
    NSString *string = [text isKindOfClass:[NSString class]] ? (NSString *)text : nil;
    if (string.length == 0) return nil;
    NSString *normalized = [[string stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
                            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return normalized.length > 0 ? normalized : nil;
}

// Caller must hold sApolloWebJSONLastWriteLock. Drops entries past the TTL.
static void ApolloWebJSONPruneWritesLocked(void) {
    if (sApolloWebJSONPendingWrites.count == 0) return;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSIndexSet *stale = [sApolloWebJSONPendingWrites indexesOfObjectsPassingTest:
                         ^BOOL(ApolloWebJSONPendingWrite *w, NSUInteger __unused idx, BOOL * __unused stop) {
        return (now - w.capturedAt) >= kApolloWebJSONWriteContextTTL;
    }];
    if (stale.count > 0) [sApolloWebJSONPendingWrites removeObjectsAtIndexes:stale];
}

// Caller must hold sApolloWebJSONLastWriteLock. Latest entry for an edited
// fullname, if any; sole caller consumes it.
static ApolloWebJSONPendingWrite *ApolloWebJSONPendingEditLocked(NSString *fullname) {
    ApolloWebJSONPruneWritesLocked();
    for (ApolloWebJSONPendingWrite *w in sApolloWebJSONPendingWrites.reverseObjectEnumerator) {
        if (w.editedFullName && [w.editedFullName isEqualToString:fullname]) return w;
    }
    return nil;
}

static ApolloWebJSONPendingWrite *ApolloWebJSONCaptureWrite(id client, NSString *body, NSString *subreddit,
                                                            NSString *subredditFullName,
                                                            NSString *linkFullName, NSString *parentFullName) {
    NSString *name = nil;
    @try {
        id user = [client respondsToSelector:@selector(currentUser)]
            ? ((id (*)(id, SEL))objc_msgSend)(client, @selector(currentUser)) : nil;
        id value = [user respondsToSelector:@selector(username)]
            ? ((id (*)(id, SEL))objc_msgSend)(user, @selector(username)) : nil;
        name = ApolloWebJSONCopiedNonEmptyString(value);
    } @catch (__unused NSException *e) {}

    ApolloWebJSONPendingWrite *write = [ApolloWebJSONPendingWrite new];
    write.username = name;
    write.subreddit = ApolloWebJSONCopiedNonEmptyString(subreddit);
    write.subredditFullName = ApolloWebJSONCopiedNonEmptyString(subredditFullName);
    write.linkFullName = ApolloWebJSONCopiedNonEmptyString(linkFullName);
    write.parentFullName = ApolloWebJSONCopiedNonEmptyString(parentFullName);
    write.bodyKey = ApolloWebJSONWriteBodyKey(body);
    write.capturedAt = [NSDate timeIntervalSinceReferenceDate];

    os_unfair_lock_lock(&sApolloWebJSONLastWriteLock);
    if (!sApolloWebJSONPendingWrites) sApolloWebJSONPendingWrites = [NSMutableArray array];
    ApolloWebJSONPruneWritesLocked();
    // An entry with the same body may already be pending — keep BOTH. Evicting
    // it would hand the earlier write's response the newer write's context
    // whenever two overlapping writes carry identical markdown (a "Thanks"
    // posted in two different threads); the resolver treats a duplicated key
    // as ambiguous instead. The retry case the old eviction served (user
    // resubmitted a failed post) still repairs fully: identical retries carry
    // identical context, so the unanimity fallback returns every field.
    [sApolloWebJSONPendingWrites addObject:write];
    while (sApolloWebJSONPendingWrites.count > kApolloWebJSONMaxPendingWrites) {
        [sApolloWebJSONPendingWrites removeObjectAtIndex:0];
    }
    os_unfair_lock_unlock(&sApolloWebJSONLastWriteLock);
    return write;
}

void ApolloWebJSONNoteCommentWriteContext(id client, NSString *body, NSString *subreddit,
                                          NSString *subredditFullName,
                                          NSString *linkFullName, NSString *parentFullName) {
    ApolloWebJSONCaptureWrite(client, body, subreddit, subredditFullName, linkFullName, parentFullName);
}

// String-typed property read tolerant of foreign/odd objects.
static NSString *ApolloWebJSONStringProperty(id thing, SEL selector) {
    if (![thing respondsToSelector:selector]) return nil;
    id value = nil;
    @try { value = ((id (*)(id, SEL))objc_msgSend)(thing, selector); }
    @catch (__unused NSException *e) { return nil; }
    return ApolloWebJSONCopiedNonEmptyString(value);
}

void ApolloWebJSONNoteCommentEditContext(id client, NSString *body, id comment) {
    NSString *fullname = ApolloWebJSONStringProperty(comment, @selector(fullName));
    ApolloWebJSONPendingWrite *write = ApolloWebJSONCaptureWrite(client, body,
        ApolloWebJSONStringProperty(comment, @selector(subreddit)),
        ApolloWebJSONStringProperty(comment, @selector(subredditID)),
        ApolloWebJSONStringProperty(comment, @selector(linkID)), nil);
    if (fullname.length == 0) return;
    os_unfair_lock_lock(&sApolloWebJSONLastWriteLock);
    write.editedFullName = fullname;
    write.editedThing = comment;
    os_unfair_lock_unlock(&sApolloWebJSONLastWriteLock);
}

void ApolloWebJSONNoteSelfTextEditContext(id client, NSString *body, NSString *linkFullName) {
    if (![linkFullName hasPrefix:@"t3_"]) return;
    ApolloWebJSONPendingWrite *write = ApolloWebJSONCaptureWrite(client, body, nil, nil, linkFullName, nil);
    os_unfair_lock_lock(&sApolloWebJSONLastWriteLock);
    write.editedFullName = linkFullName;
    os_unfair_lock_unlock(&sApolloWebJSONLastWriteLock);
    // Runs alongside the edit request itself; whichever answer lands second
    // does the repair (the response's serializer when the prefetch is already
    // in, otherwise nothing — the serializer never waits for this).
    ApolloWebJSONPrefetchModernThingData(linkFullName, ^(NSDictionary *data) {
        os_unfair_lock_lock(&sApolloWebJSONLastWriteLock);
        write.prefetchedData = data;
        os_unfair_lock_unlock(&sApolloWebJSONLastWriteLock);
        ApolloLog(@"[WebJSON] info.json prefetch for edited %@ %@", linkFullName, data ? @"landed" : @"failed");
    });
}

#pragma mark - Pre-edit model -> modern JSON

// One JSON-representable value for a model property: plain strings/numbers
// as-is, dates as epoch seconds, URLs as strings, nested Mantle models (flair
// pieces) through their own key map, containers only when every element
// converts. nil for anything else — a field left out is filled elsewhere or
// stays missing; a field written wrong would parse as a different value.
static id ApolloWebJSONJSONValue(id value, NSUInteger depth) {
    if (!value || value == [NSNull null] || depth > 2) return nil;
    if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]]) return value;
    if ([value isKindOfClass:[NSDate class]]) return @([(NSDate *)value timeIntervalSince1970]);
    if ([value isKindOfClass:[NSURL class]]) return [(NSURL *)value absoluteString];
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *out = [NSMutableArray array];
        for (id element in (NSArray *)value) {
            id converted = ApolloWebJSONJSONValue(element, depth + 1);
            if (!converted) return nil;
            [out addObject:converted];
        }
        return out;
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        return [NSJSONSerialization isValidJSONObject:value] ? value : nil;
    }
    if ([[value class] respondsToSelector:@selector(JSONKeyPathsByPropertyKey)]) {
        NSDictionary *map = ((id (*)(id, SEL))objc_msgSend)([value class], @selector(JSONKeyPathsByPropertyKey));
        if (![map isKindOfClass:[NSDictionary class]]) return nil;
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        for (NSString *property in map) {
            NSString *key = map[property];
            if (![key isKindOfClass:[NSString class]] || [key containsString:@"."]) continue;
            id raw = nil;
            @try { raw = [value valueForKey:property]; } @catch (__unused NSException *e) { continue; }
            id converted = ApolloWebJSONJSONValue(raw, depth + 1);
            if (converted) out[key] = converted;
        }
        return out;
    }
    return nil;
}

// The modern comment JSON `data` dict for the RDKComment being edited — the
// same shape info.json would return, rebuilt from the model Apollo already
// parsed from that shape. Everything Reddit's degraded edit response drops
// (author, timestamps, score, flair, location) is still true of the comment
// after the edit; only the body changes, and the response carries that. So
// this replaces the blocking info.json refetch the serializer used to make
// for edits, with a copy that can't lag the edit and costs no request.
//
// Driven by RDKComment's own Mantle key map (+JSONKeyPathsByPropertyKey), so
// the key names can't drift from what the parser reads. The few properties
// whose forward transform isn't a plain copy are reversed explicitly below;
// awards/replies are left to the merge (no reverse mapping; an edit response
// never carries them either).
static NSDictionary *ApolloWebJSONModernDataFromEditedComment(id comment) {
    if (![[comment class] respondsToSelector:@selector(JSONKeyPathsByPropertyKey)]) return nil;
    NSDictionary *map = ((id (*)(id, SEL))objc_msgSend)([comment class], @selector(JSONKeyPathsByPropertyKey));
    if (![map isKindOfClass:[NSDictionary class]]) return nil;
    NSSet *reversedByHand = [NSSet setWithArray:@[@"createdUTC", @"edited", @"bannedAt", @"voteStatus",
                                                  @"distinguished", @"awards", @"replies", @"body", @"bodyHTML",
                                                  @"submissionContentText", @"submissionContentHTML",
                                                  @"submissionLink", @"submissionParent"]];
    NSMutableDictionary *modern = [NSMutableDictionary dictionary];
    for (NSString *property in map) {
        if ([reversedByHand containsObject:property]) continue;
        NSString *keyPath = map[property];
        if (![keyPath isKindOfClass:[NSString class]] || ![keyPath hasPrefix:@"data."]) continue;
        id raw = nil;
        @try { raw = [comment valueForKey:property]; } @catch (__unused NSException *e) { continue; }
        id converted = ApolloWebJSONJSONValue(raw, 0);
        if (converted) modern[[keyPath substringFromIndex:5]] = converted;
    }

    id created = nil;
    @try { created = [comment valueForKey:@"createdUTC"]; } @catch (__unused NSException *e) {}
    if ([created isKindOfClass:[NSDate class]] && [(NSDate *)created timeIntervalSince1970] > 0) {
        modern[@"created_utc"] = @([(NSDate *)created timeIntervalSince1970]);
        modern[@"created"] = modern[@"created_utc"];
    }
    id banned = nil;
    @try { banned = [comment valueForKey:@"bannedAt"]; } @catch (__unused NSException *e) {}
    if ([banned isKindOfClass:[NSDate class]] && [(NSDate *)banned timeIntervalSince1970] > 0) {
        modern[@"banned_at_utc"] = @([(NSDate *)banned timeIntervalSince1970]);
    }
    // RDKVoteStatus: 0 upvoted, 1 downvoted, 2 none (likes true / false / null).
    id vote = nil;
    @try { vote = [comment valueForKey:@"voteStatus"]; } @catch (__unused NSException *e) {}
    if ([vote isKindOfClass:[NSNumber class]]) {
        NSInteger status = [(NSNumber *)vote integerValue];
        if (status == 0) modern[@"likes"] = @YES;
        else if (status == 1) modern[@"likes"] = @NO;
    }
    // RDKDistinguishedStatus: 1 moderator, 2 admin, 3 special; 0 is a plain user.
    id distinguished = nil;
    @try { distinguished = [comment valueForKey:@"distinguished"]; } @catch (__unused NSException *e) {}
    if ([distinguished isKindOfClass:[NSNumber class]]) {
        NSArray *names = @[@"moderator", @"admin", @"special"];
        NSInteger status = [(NSNumber *)distinguished integerValue];
        if (status >= 1 && status <= (NSInteger)names.count) modern[@"distinguished"] = names[status - 1];
    }
    if (!ApolloWebJSONIsNonEmptyString(modern[@"id"])) return nil;
    modern[@"name"] = [@"t1_" stringByAppendingString:modern[@"id"]];
    modern[@"replies"] = @"";
    if (!modern[@"permalink"] && ApolloWebJSONIsNonEmptyString(modern[@"subreddit"])
        && [modern[@"link_id"] isKindOfClass:[NSString class]] && [modern[@"link_id"] hasPrefix:@"t3_"]) {
        modern[@"permalink"] = [NSString stringWithFormat:@"/r/%@/comments/%@/_/%@/",
                                modern[@"subreddit"], [modern[@"link_id"] substringFromIndex:3], modern[@"id"]];
    }
    return modern;
}

// What stands in for Reddit's modern copy of an edited thing: the pre-edit
// comment model, rendered to modern JSON, or the landed info.json prefetch
// for a self-text post. nil when nothing was captured for this fullname (an
// edit the identity hooks never saw) or the prefetch hasn't landed — callers
// fall back to the legacy synthesis / leave the thing untouched, never wait.
static NSDictionary *ApolloWebJSONEditFillForFullname(NSString *fullname) {
    if (fullname.length == 0) return nil;
    os_unfair_lock_lock(&sApolloWebJSONLastWriteLock);
    ApolloWebJSONPendingWrite *write = ApolloWebJSONPendingEditLocked(fullname);
    id thing = write.editedThing;
    NSDictionary *prefetched = write.prefetchedData;
    os_unfair_lock_unlock(&sApolloWebJSONLastWriteLock);
    if (thing) return ApolloWebJSONModernDataFromEditedComment(thing);
    return prefetched;
}

// The edited thing's modern JSON with the response's new text on top: body /
// body_html for a comment, selftext / selftext_html for a post. The edit
// response is the only source of the new text, and the fill is the only
// source of everything else.
static NSDictionary *ApolloWebJSONMergeEditFill(NSDictionary *fill, NSString *text, NSString *html, BOOL isLink) {
    NSMutableDictionary *merged = [fill mutableCopy];
    NSString *textKey = isLink ? @"selftext" : @"body";
    NSString *htmlKey = isLink ? @"selftext_html" : @"body_html";
    merged[textKey] = text.length > 0 ? text : @"";
    merged[htmlKey] = html.length > 0 ? html : ApolloWebJSONEscapedBodyHTML(text ?: @"");
    merged[@"edited"] = @([[NSDate date] timeIntervalSince1970]);
    return merged;
}

// Only the fields on which every candidate agrees. Two overlapping writes into
// the same subreddit still get their subreddit filled; ones that disagree leave
// the field empty, which is exactly the pre-location-fill behavior — a weaker
// repair, never a wrong one.
static ApolloWebJSONWriteContext ApolloWebJSONUnanimousContext(NSArray<ApolloWebJSONPendingWrite *> *writes) {
    ApolloWebJSONWriteContext ctx = {nil, nil, nil, nil, nil};
    if (writes.count == 0) return ctx;
    ApolloWebJSONPendingWrite *first = writes.firstObject;
    NSString *username = first.username, *subreddit = first.subreddit;
    NSString *subredditFullName = first.subredditFullName;
    NSString *linkFullName = first.linkFullName, *parentFullName = first.parentFullName;
    for (ApolloWebJSONPendingWrite *w in writes) {
        if (username && ![username isEqualToString:w.username ?: @""]) username = nil;
        if (subreddit && ![subreddit isEqualToString:w.subreddit ?: @""]) subreddit = nil;
        if (subredditFullName && ![subredditFullName isEqualToString:w.subredditFullName ?: @""]) subredditFullName = nil;
        if (linkFullName && ![linkFullName isEqualToString:w.linkFullName ?: @""]) linkFullName = nil;
        if (parentFullName && ![parentFullName isEqualToString:w.parentFullName ?: @""]) parentFullName = nil;
    }
    ctx.username = username;
    ctx.subreddit = subreddit;
    ctx.subredditFullName = subredditFullName;
    ctx.linkFullName = linkFullName;
    ctx.parentFullName = parentFullName;
    return ctx;
}

// YES when the response-side identity hints positively rule this candidate
// out: a location field the degraded payload kept that differs from what was
// captured at submit time cannot belong to this write. A nil on either side
// proves nothing and never disqualifies — silence is not evidence.
static BOOL ApolloWebJSONWriteContradictsHints(ApolloWebJSONPendingWrite *w,
                                               NSString *subredditHint,
                                               NSString *linkHint,
                                               NSString *parentHint) {
    if (subredditHint && w.subreddit
        && [subredditHint caseInsensitiveCompare:w.subreddit] != NSOrderedSame) return YES;
    if (linkHint && w.linkFullName && ![linkHint isEqualToString:w.linkFullName]) return YES;
    // What the repair itself would write as parent_id for a create: the parent
    // comment for a reply, the link itself for a top-level comment. Callers
    // pass a nil parentHint for edits — an edited comment's real parent was
    // never captured, so it could only contradict falsely.
    NSString *effectiveParent = w.parentFullName ?: w.linkFullName;
    if (parentHint && effectiveParent && ![parentHint isEqualToString:effectiveParent]) return YES;
    return NO;
}

// The write context for the response now being repaired, resolved from the
// markdown Reddit echoed back plus whatever location fields the payload kept
// (the identity hints). Zeroed struct when nothing usable is outstanding —
// callers fall back to the active account / leave fields unfilled.
static ApolloWebJSONWriteContext ApolloWebJSONWriteContextForResponse(id responseBody,
                                                                      NSString *subredditHint,
                                                                      NSString *linkHint,
                                                                      NSString *parentHint) {
    NSString *key = ApolloWebJSONWriteBodyKey(responseBody);
    ApolloWebJSONWriteContext ctx = {nil, nil, nil, nil, nil};

    os_unfair_lock_lock(&sApolloWebJSONLastWriteLock);
    ApolloWebJSONPruneWritesLocked();

    // Candidate set, narrowest first: every entry whose captured markdown
    // matches the echoed body — duplicates included, and consumed entries too,
    // so a re-serialized retry of the same response still resolves. When
    // nothing matches by body, every write still awaiting its response; when
    // all of those have already repaired something, everything outstanding
    // (most likely one of those responses being serialized again).
    NSArray<ApolloWebJSONPendingWrite *> *candidates = nil;
    BOOL matchedByBody = NO;
    if (key) {
        candidates = [sApolloWebJSONPendingWrites filteredArrayUsingPredicate:
                      [NSPredicate predicateWithBlock:^BOOL(ApolloWebJSONPendingWrite *w, NSDictionary * __unused b) {
            return w.bodyKey && [w.bodyKey isEqualToString:key];
        }]];
        matchedByBody = candidates.count > 0;
    }
    if (!matchedByBody) {
        candidates = [sApolloWebJSONPendingWrites filteredArrayUsingPredicate:
                      [NSPredicate predicateWithBlock:^BOOL(ApolloWebJSONPendingWrite *w, NSDictionary * __unused b) {
            return !w.consumed;
        }]];
        if (candidates.count == 0) candidates = [sApolloWebJSONPendingWrites copy];
    }

    // Response-side identity narrows further: drop candidates the kept
    // location fields positively contradict. This is what tells apart two
    // overlapping writes whose markdown is identical (a "Thanks" posted in two
    // different threads) when the payload retained any of its location.
    if (candidates.count > 0 && (subredditHint || linkHint || parentHint)) {
        candidates = [candidates filteredArrayUsingPredicate:
                      [NSPredicate predicateWithBlock:^BOOL(ApolloWebJSONPendingWrite *w, NSDictionary * __unused b) {
            return !ApolloWebJSONWriteContradictsHints(w, subredditHint, linkHint, parentHint);
        }]];
    }

    // Adopt a candidate's full context only when exactly one is left. Anything
    // else — an ambiguous duplicated body the hints couldn't split, or no
    // survivors at all — never picks one: only the fields every survivor
    // agrees on are used, so identical retries still repair fully and two
    // same-body writes from one account still get the right author, while the
    // fields that differ stay empty. A weaker repair, never a wrong one.
    ApolloWebJSONPendingWrite *match = candidates.count == 1 ? candidates.firstObject : nil;
    if (match) {
        match.consumed = YES;
        ctx.username = match.username;
        ctx.subreddit = match.subreddit;
        ctx.subredditFullName = match.subredditFullName;
        ctx.linkFullName = match.linkFullName;
        ctx.parentFullName = match.parentFullName;
    } else {
        ctx = ApolloWebJSONUnanimousContext(candidates);
    }
    NSUInteger outstanding = sApolloWebJSONPendingWrites.count;
    os_unfair_lock_unlock(&sApolloWebJSONLastWriteLock);

    if (outstanding > 1) {
        ApolloLog(@"[WebJSON] Write context for repair: %@ (%lu writes outstanding)",
                  match ? (matchedByBody ? @"uniquely matched by body" : @"sole surviving candidate")
                        : @"ambiguous — unanimous fields only",
                  (unsigned long)outstanding);
    }
    return ctx;
}

// A timestamp-ish numeric field that's absent, JSON-null, the wrong type, or
// non-positive counts as missing (RedditKit turns all of those into the
// epoch-1970 date the blank cell shows).
static BOOL ApolloWebJSONTimestampMissing(id value) {
    if (![value isKindOfClass:[NSNumber class]]) return YES;
    return [(NSNumber *)value doubleValue] <= 0;
}

// The milder variant of the same degraded write response: a MODERN-shaped thing
// (body present) that is missing render-critical fields — author,
// created/created_utc, score, and (in the wild 36-key payload observed
// 2026-08) the thing's location: subreddit/link_id/parent_id/permalink.
// RedditKit then parses a comment with no author/avatar, an epoch-1970
// timestamp, score 0 — and an empty subreddit, which silently disables the
// own-flair backfill and the moderator shield on the inserted cell. Fill ONLY
// the missing fields — identity/score with the same optimistic values the
// legacy synthesis uses, location from the write context captured at submit
// time; anything present is never overwritten. Returns nil when the thing is
// already complete — the overwhelmingly common case, making this a strict
// no-op for healthy responses.
static NSDictionary *ApolloWebJSONCompleteModernThingData(NSDictionary *td, BOOL isEdit, NSArray<NSString *> **outFilled) {
    NSMutableArray<NSString *> *filled = [NSMutableArray array];
    NSMutableDictionary *patched = [td mutableCopy];

    // Which outstanding write is this? The degraded payload keeps `body` (that
    // is what makes it "modern-shaped"), and body IS the submitted markdown, so
    // it identifies the write even when everything else was stripped. Any
    // location field it DID keep goes along as an identity hint — that is what
    // tells two overlapping writes apart when their markdown is identical
    // (parent hint creates-only: an edited comment's real parent was never
    // captured, so it could only contradict falsely). Resolved once here and
    // reused for both the author and the location fields — two lookups could
    // otherwise disagree if a write landed in between.
    ApolloWebJSONWriteContext ctx = ApolloWebJSONWriteContextForResponse(
        td[@"body"],
        ApolloWebJSONIsNonEmptyString(td[@"subreddit"]) ? td[@"subreddit"] : nil,
        ApolloWebJSONIsNonEmptyString(td[@"link_id"]) ? td[@"link_id"] : nil,
        (!isEdit && ApolloWebJSONIsNonEmptyString(td[@"parent_id"])) ? td[@"parent_id"] : nil);

    if (!ApolloWebJSONIsNonEmptyString(td[@"author"])) {
        // Trust order (no content HTML exists here, so no data-author): the
        // identity captured from the submitting RDKClient — correct even when
        // the composer posted as a non-active account (temporaryPostingAccount)
        // — then the active web session, then the active account. Stored
        // capitalization matters because the Edit affordance gates on
        // comment.author == currentUser.username.
        NSString *author = ctx.username;
        if (author.length == 0) author = ApolloActiveWebSessionUsername();
        if (author.length == 0) author = ApolloActiveAccountUsername();
        if (author.length > 0) {
            patched[@"author"] = author;
            [filled addObject:@"author"];
        }
    }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (ApolloWebJSONTimestampMissing(td[@"created_utc"])) {
        patched[@"created_utc"] = @(now);
        [filled addObject:@"created_utc"];
    }
    if (ApolloWebJSONTimestampMissing(td[@"created"])) {
        patched[@"created"] = @(now);
        [filled addObject:@"created"];
    }

    // A freshly created own comment always starts at score 1 with the author's
    // self-upvote, so on /api/comment a missing score — or an explicit 0 with no
    // vote state — is the degraded payload, not a real value. Edits keep an
    // explicit 0: a genuinely downvoted comment can legitimately sit there.
    id score = td[@"score"];
    BOOL scoreMissing = ![score isKindOfClass:[NSNumber class]];
    BOOL scoreZeroOnCreate = !isEdit && [score isKindOfClass:[NSNumber class]] && [(NSNumber *)score integerValue] == 0
                             && ![td[@"likes"] isKindOfClass:[NSNumber class]];
    if (scoreMissing || scoreZeroOnCreate) {
        patched[@"score"] = @1;
        [filled addObject:@"score"];
        if (![td[@"ups"] isKindOfClass:[NSNumber class]] || (!isEdit && [(NSNumber *)td[@"ups"] integerValue] == 0)) {
            patched[@"ups"] = @1;
        }
        if (!isEdit && ![td[@"likes"] isKindOfClass:[NSNumber class]]) {
            patched[@"likes"] = @YES;
        }
    }

    // Location fields, from the write context captured at submit time. An empty
    // model.subreddit is what silently kills the own-flair backfill and the
    // moderator shield on the fresh cell (both key off the comment's
    // subreddit), so this is as render-critical as author/created/score.
    if (!ApolloWebJSONIsNonEmptyString(td[@"subreddit"]) && ctx.subreddit) {
        patched[@"subreddit"] = ctx.subreddit;
        [filled addObject:@"subreddit"];
    }
    if (!ApolloWebJSONIsNonEmptyString(td[@"subreddit_id"]) && ctx.subredditFullName) {
        patched[@"subreddit_id"] = ctx.subredditFullName;
        [filled addObject:@"subreddit_id"];
    }
    if (!ApolloWebJSONIsNonEmptyString(td[@"link_id"]) && ctx.linkFullName) {
        patched[@"link_id"] = ctx.linkFullName;
        [filled addObject:@"link_id"];
    }
    // A top-level comment's parent IS the link; a reply's is the parent t1.
    // Only creates: an edit's parent is not in the context (the edited comment
    // could be nested anywhere), and edits prefer the info.json refetch anyway.
    if (!isEdit && !ApolloWebJSONIsNonEmptyString(td[@"parent_id"])) {
        NSString *parent = ctx.parentFullName ?: ctx.linkFullName;
        if (parent) {
            patched[@"parent_id"] = parent;
            [filled addObject:@"parent_id"];
        }
    }
    if (!ApolloWebJSONIsNonEmptyString(td[@"permalink"]) && ctx.subreddit && ctx.linkFullName) {
        // "/_/" is old-reddit's wildcard slug — Reddit resolves it for any post.
        NSString *link36 = [ctx.linkFullName hasPrefix:@"t3_"] ? [ctx.linkFullName substringFromIndex:3] : nil;
        NSString *own = ApolloWebJSONIsNonEmptyString(td[@"id"]) ? td[@"id"]
                      : (ApolloWebJSONIsNonEmptyString(td[@"name"]) && [td[@"name"] hasPrefix:@"t1_"]
                         ? [td[@"name"] substringFromIndex:3] : nil);
        if (link36 && own) {
            patched[@"permalink"] = [NSString stringWithFormat:@"/r/%@/comments/%@/_/%@/", ctx.subreddit, link36, own];
            [filled addObject:@"permalink"];
        }
    }

    if (filled.count == 0) return nil;
    if (outFilled) *outFilled = filled;
    return patched;
}

// Old-reddit /api/editusertext and /api/comment responses return each thing's
// `data` in the legacy shape {parent, content:"<html>"} instead of the modern
// comment JSON ({body, body_html, score, author, …}). Apollo's RedditKit maps
// only the body-ish fields from that shape (data.contentText/contentHTML), so
// the just-posted comment renders with no author/avatar/flair, score 0, and an
// epoch-1970 timestamp until the thread is reloaded. www.reddit.com always
// answers this way (Web JSON mode), and since 2026-08 oauth.reddit.com has
// intermittently served the SAME legacy shape to API-key (OAuth) clients — it
// also hit Narwhal — so this repair runs in EVERY auth mode; it is a strict
// no-op for the modern shape and on API errors. Two degraded variants are
// handled: the full legacy shape is swapped for a modern object, and a
// modern-shaped thing missing its render-critical fields gets just those fields
// filled in place (ApolloWebJSONCompleteModernThingData above). For an edit the
// modern fields come from the pre-edit model captured at submit time (or the
// info.json prefetch for a self-text post — ApolloWebJSONEditFillForFullname);
// for a new comment, and for an edit nothing was captured for, they are
// synthesized locally from the legacy fields, which always carry the submitted
// text. Nothing here touches the network: this runs inside the response
// serializer, and any wait here holds up the response the user is waiting on.
id ApolloWebJSONFixupWriteResponseObject(NSURLResponse *response, id responseObject) {
    if (![response isKindOfClass:[NSHTTPURLResponse class]]) return responseObject;

    NSString *path = [((NSHTTPURLResponse *)response).URL.path lowercaseString] ?: @"";
    if (!([path hasSuffix:@"/api/editusertext"] || [path hasSuffix:@"/api/comment"])) return responseObject;
    BOOL isEdit = [path hasSuffix:@"/api/editusertext"];

    // The serializer may hand us the parsed dict or the raw JSON data; handle both
    // and return the same form so we never change the contract for the modern path.
    BOOL wasData = NO;
    id root = responseObject;
    if ([responseObject isKindOfClass:[NSData class]]) {
        id parsed = [NSJSONSerialization JSONObjectWithData:responseObject options:0 error:NULL];
        if (![parsed isKindOfClass:[NSDictionary class]]) return responseObject;
        root = parsed; wasData = YES;
    } else if (![responseObject isKindOfClass:[NSDictionary class]]) {
        return responseObject;
    }

    NSDictionary *json = root[@"json"];
    if (![json isKindOfClass:[NSDictionary class]]) {
        ApolloLog(@"[WebJSON] %@ response has no json envelope (top-level keys: %@) — skipping write fixup",
                  path, [[(NSDictionary *)root allKeys] componentsJoinedByString:@","]);
        return responseObject;
    }
    NSArray *errors = json[@"errors"];
    if ([errors isKindOfClass:[NSArray class]] && errors.count > 0) return responseObject; // surface the error
    NSDictionary *dataDict = json[@"data"];
    NSArray *things = [dataDict isKindOfClass:[NSDictionary class]] ? dataDict[@"things"] : nil;
    if (![things isKindOfClass:[NSArray class]] || things.count == 0) {
        ApolloLog(@"[WebJSON] %@ response json.data.things missing/empty — skipping write fixup", path);
        return responseObject;
    }

    NSMutableArray *newThings = [things mutableCopy];
    BOOL changed = NO;
    for (NSUInteger i = 0; i < newThings.count; i++) {
        NSDictionary *thing = newThings[i];
        if (![thing isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *td = thing[@"data"];
        if (![td isKindOfClass:[NSDictionary class]]) continue;

        // JSON null (NSNull) counts as body-missing: a body:null + content thing
        // is the legacy shape (synthesis rebuilds the body from contentText).
        BOOL hasBody = [td[@"body"] isKindOfClass:[NSString class]];
        BOOL isLegacyShape = (!hasBody && [td[@"content"] isKindOfClass:[NSString class]]);
        if (!isLegacyShape) {
            if (!hasBody) continue; // neither shape — leave untouched
            // Modern shape: fill any missing render-critical fields in place —
            // but only on actual COMMENTS. Private-message replies also flow
            // through /api/comment as t4 things whose healthy data legitimately
            // carries score:0/likes:null, and they must stay untouched. Skip
            // only on explicit evidence of a non-comment: a degraded comment
            // payload could lose kind AND name, and missing the repair there is
            // the costlier error (skipping re-blanks the just-posted comment).
            NSString *kind = [thing[@"kind"] isKindOfClass:[NSString class]] ? thing[@"kind"] : nil;
            NSString *name = ApolloWebJSONIsNonEmptyString(td[@"name"]) ? td[@"name"] : nil;
            BOOL notComment = (kind && ![kind isEqualToString:@"t1"]) ||
                              (name && [name rangeOfString:@"_"].location != NSNotFound && ![name hasPrefix:@"t1_"]);
            if (notComment) continue;

            NSArray<NSString *> *filledKeys = nil;
            NSDictionary *completed = ApolloWebJSONCompleteModernThingData(td, isEdit, &filledKeys);
            if (!completed) continue; // already complete — the common case

            NSString *source = @"optimistic fill";
            // An edited comment already exists with a real score/created/flair
            // — its pre-edit model fills everything the payload dropped, and
            // whatever the payload did keep stays Reddit's word.
            if (isEdit) {
                NSString *fullname = name ?: (ApolloWebJSONIsNonEmptyString(td[@"id"])
                                              ? [@"t1_" stringByAppendingString:td[@"id"]] : nil);
                NSDictionary *fill = ApolloWebJSONEditFillForFullname(fullname);
                if (fill) {
                    NSMutableDictionary *merged = [fill mutableCopy];
                    for (id key in td) if (td[key] != [NSNull null]) merged[key] = td[key];
                    merged[@"edited"] = @([[NSDate date] timeIntervalSince1970]);
                    completed = ApolloWebJSONCompleteModernThingData(merged, isEdit, NULL) ?: merged;
                    source = @"pre-edit model";
                }
            }

            newThings[i] = @{ @"kind": kind ?: @"t1", @"data": completed };
            changed = YES;
            ApolloLog(@"[WebJSON] Filled missing %@ on modern %@ thing %@ via %@ (%lu keys present)",
                      [filledKeys componentsJoinedByString:@"+"], path,
                      name ?: [NSString stringWithFormat:@"(id %@)", td[@"id"] ?: @"?"],
                      source, (unsigned long)td.count);
            continue;
        }

        NSString *fullname = ApolloWebJSONFullnameFromLegacyContent(td[@"content"]);
        // The legacy dict's own "id" field is the fullname too — use it when the
        // content HTML doesn't carry a data-fullname attribute.
        if (fullname.length == 0 && [td[@"id"] isKindOfClass:[NSString class]]
            && [(NSString *)td[@"id"] hasPrefix:@"t"]
            && [(NSString *)td[@"id"] rangeOfString:@"_"].location != NSNotFound) {
            fullname = td[@"id"];
        }
        if (fullname.length == 0) {
            ApolloLog(@"[WebJSON] %@ legacy thing %lu has no extractable fullname — cannot repair", path, (unsigned long)i);
            continue;
        }

        // /api/editusertext: the thing already exists with a real score/flair
        // that synthesis would clobber with placeholders — its captured copy
        // plus the response's new text is the exact modern object.
        // Fresh /api/comment, and an edit nothing was captured for: synthesize
        // — we know everything about a comment the user just wrote, and the
        // optimistic fields are exact for a new one.
        NSDictionary *modern = nil;
        NSString *source = nil;
        if (isEdit) {
            NSDictionary *fill = ApolloWebJSONEditFillForFullname(fullname);
            if (fill) {
                NSString *text = [td[@"contentText"] isKindOfClass:[NSString class]] ? td[@"contentText"] : nil;
                NSString *html = [td[@"contentHTML"] isKindOfClass:[NSString class]] ? td[@"contentHTML"] : nil;
                modern = ApolloWebJSONMergeEditFill(fill, text, html, [fullname hasPrefix:@"t3_"]);
                source = [fullname hasPrefix:@"t3_"] ? @"info.json prefetch" : @"pre-edit model";
            }
        }
        if (![modern isKindOfClass:[NSDictionary class]]) {
            modern = ApolloWebJSONSynthesizeModernThingData(fullname, td, isEdit);
            source = isEdit ? @"local synthesis (no captured edit)" : @"local synthesis";
        }
        if (![modern isKindOfClass:[NSDictionary class]]) {
            ApolloLog(@"[WebJSON] %@ thing %@ unrepairable (nothing captured and synthesis failed)", path, fullname);
            continue;
        }

        NSString *kind = [thing[@"kind"] isKindOfClass:[NSString class]] ? thing[@"kind"]
                       : ([fullname hasPrefix:@"t1_"] ? @"t1" : @"t3");
        newThings[i] = @{ @"kind": kind, @"data": modern };
        changed = YES;
        ApolloLog(@"[WebJSON] Rebuilt %@ response thing %@ via %@ for correct in-place render", path, fullname, source);
    }
    if (!changed) return responseObject;

    NSMutableDictionary *newData = [dataDict mutableCopy];
    newData[@"things"] = newThings;
    NSMutableDictionary *newJson = [json mutableCopy];
    newJson[@"data"] = newData;
    NSMutableDictionary *newRoot = [root mutableCopy];
    newRoot[@"json"] = newJson;

    if (wasData) {
        NSData *out = [NSJSONSerialization dataWithJSONObject:newRoot options:0 error:NULL];
        return out ?: responseObject;
    }
    return newRoot;
}
