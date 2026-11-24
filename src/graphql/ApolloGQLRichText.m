#import "ApolloGQLRichText.h"

// RTJSON, as seen in gql-fed.reddit.com answers (2026-11-23):
//   block elements  par, h (l = level), blockquote, list (o = ordered) of li,
//                   code (c = raw lines), table (h = header cells, c = rows),
//                   hr, and img / gif / video (id = an entry of richtextMedia)
//   inline elements text (t, f), link (t, u, f), r/ and u/ (t = name, l =
//                   written with a leading slash), spoilertext (c), br, raw (t)
//   f               format ranges over t: [[mask, start, length], …] in UTF-16
//                   units, mask bits 1 bold, 2 italic, 4 underline, 8 strike,
//                   16 subscript, 32 superscript, 64 code

static NSString *ApolloGQLRTEscape(NSString *text) {
    if (text.length == 0) return @"";
    NSMutableString *out = [NSMutableString stringWithCapacity:text.length + 16];
    NSUInteger length = text.length;
    unichar buffer[256];
    for (NSUInteger offset = 0; offset < length; offset += 256) {
        NSUInteger count = MIN((NSUInteger)256, length - offset);
        [text getCharacters:buffer range:NSMakeRange(offset, count)];
        NSUInteger runStart = 0;
        for (NSUInteger i = 0; i < count; i++) {
            NSString *entity = nil;
            switch (buffer[i]) {
                case '&': entity = @"&amp;"; break;
                case '<': entity = @"&lt;"; break;
                case '>': entity = @"&gt;"; break;
                case '"': entity = @"&quot;"; break;
                case '\'': entity = @"&#39;"; break;
                default: break;
            }
            if (!entity) continue;
            if (i > runStart) [out appendString:[NSString stringWithCharacters:buffer + runStart length:i - runStart]];
            [out appendString:entity];
            runStart = i + 1;
        }
        if (count > runStart) [out appendString:[NSString stringWithCharacters:buffer + runStart length:count - runStart]];
    }
    return out;
}

static NSString *ApolloGQLRTString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSArray *ApolloGQLRTArray(id value) {
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

// The tags for a format mask, outermost first.
static NSArray<NSString *> *ApolloGQLRTTagsForMask(NSInteger mask) {
    NSMutableArray<NSString *> *tags = [NSMutableArray array];
    if (mask & 1) [tags addObject:@"strong"];
    if (mask & 2) [tags addObject:@"em"];
    if (mask & 4) [tags addObject:@"u"];
    if (mask & 8) [tags addObject:@"del"];
    if (mask & 16) [tags addObject:@"sub"];
    if (mask & 32) [tags addObject:@"sup"];
    if (mask & 64) [tags addObject:@"code"];
    return tags;
}

// `text` with its format ranges as tags. Ranges that run past the text or
// overlap an earlier one are clipped, so a malformed list can't throw.
static NSString *ApolloGQLRTFormattedText(NSString *text, id formats) {
    NSArray *ranges = ApolloGQLRTArray(formats);
    if (text.length == 0) return @"";
    if (ranges.count == 0) return ApolloGQLRTEscape(text);
    NSMutableArray<NSArray<NSNumber *> *> *valid = [NSMutableArray array];
    for (id range in ranges) {
        NSArray *parts = ApolloGQLRTArray(range);
        if (parts.count < 3) continue;
        if (![parts[0] isKindOfClass:[NSNumber class]] || ![parts[1] isKindOfClass:[NSNumber class]] ||
            ![parts[2] isKindOfClass:[NSNumber class]]) continue;
        [valid addObject:@[ parts[0], parts[1], parts[2] ]];
    }
    [valid sortUsingComparator:^NSComparisonResult(NSArray<NSNumber *> *a, NSArray<NSNumber *> *b) {
        return [a[1] compare:b[1]];
    }];
    NSMutableString *out = [NSMutableString string];
    NSUInteger cursor = 0;
    for (NSArray<NSNumber *> *range in valid) {
        NSInteger start = range[1].integerValue, length = range[2].integerValue;
        if (start < (NSInteger)cursor) { length -= (NSInteger)cursor - start; start = (NSInteger)cursor; }
        if (length <= 0 || start >= (NSInteger)text.length) continue;
        if (start + length > (NSInteger)text.length) length = (NSInteger)text.length - start;
        if ((NSUInteger)start > cursor) [out appendString:ApolloGQLRTEscape([text substringWithRange:NSMakeRange(cursor, (NSUInteger)start - cursor)])];
        NSArray<NSString *> *tags = ApolloGQLRTTagsForMask(range[0].integerValue);
        for (NSString *tag in tags) [out appendFormat:@"<%@>", tag];
        [out appendString:ApolloGQLRTEscape([text substringWithRange:NSMakeRange((NSUInteger)start, (NSUInteger)length)])];
        for (NSString *tag in tags.reverseObjectEnumerator) [out appendFormat:@"</%@>", tag];
        cursor = (NSUInteger)(start + length);
    }
    if (cursor < text.length) [out appendString:ApolloGQLRTEscape([text substringFromIndex:cursor])];
    return out;
}

// The page of a Giphy embed ("giphy|<id>", sometimes "giphy|<id>|<variant>"), or
// nil for any other media id. The legacy API links the embed to this page, and
// the page is what Apollo recognises as an inline Giphy.
static NSString *ApolloGQLRTGiphyPage(NSString *mediaID) {
    if (![mediaID hasPrefix:@"giphy|"]) return nil;
    NSArray<NSString *> *parts = [mediaID componentsSeparatedByString:@"|"];
    return parts.count >= 2 && parts[1].length > 0 ? [@"https://giphy.com/gifs/" stringByAppendingString:parts[1]] : nil;
}

// The address of an embedded image, GIF or video: the asset's own URL when the
// answer lists it, else nil.
static NSString *ApolloGQLRTMediaURL(NSString *mediaID, NSArray *media) {
    if (mediaID.length == 0) return nil;
    for (id asset in media) {
        if (![asset isKindOfClass:[NSDictionary class]]) continue;
        if (![ApolloGQLRTString(asset[@"id"]) isEqualToString:mediaID]) continue;
        NSString *url = ApolloGQLRTString(asset[@"url"]);
        if (url.length == 0) url = ApolloGQLRTString(asset[@"dashUrl"]);
        if (url.length > 0) return url;
    }
    return nil;
}

static NSString *ApolloGQLRTInlines(NSArray *elements, NSArray *media, NSUInteger depth);

static NSString *ApolloGQLRTInline(NSDictionary *element, NSArray *media, NSUInteger depth) {
    NSString *kind = ApolloGQLRTString(element[@"e"]);
    NSString *text = ApolloGQLRTString(element[@"t"]) ?: @"";
    if ([kind isEqualToString:@"text"]) return ApolloGQLRTFormattedText(text, element[@"f"]);
    if ([kind isEqualToString:@"raw"]) return ApolloGQLRTEscape(text);
    if ([kind isEqualToString:@"br"]) return @"<br/>\n";
    if ([kind isEqualToString:@"link"]) {
        NSString *url = ApolloGQLRTString(element[@"u"]) ?: @"";
        return [NSString stringWithFormat:@"<a href=\"%@\">%@</a>", ApolloGQLRTEscape(url),
                ApolloGQLRTFormattedText(text.length ? text : url, element[@"f"])];
    }
    if ([kind isEqualToString:@"r/"] || [kind isEqualToString:@"u/"]) {
        BOOL leadingSlash = [element[@"l"] respondsToSelector:@selector(boolValue)] && [element[@"l"] boolValue];
        NSString *escaped = ApolloGQLRTEscape(text);
        return [NSString stringWithFormat:@"<a href=\"/%@%@\">%@%@%@</a>", kind, escaped, leadingSlash ? @"/" : @"", kind, escaped];
    }
    if ([kind isEqualToString:@"spoilertext"]) {
        return [NSString stringWithFormat:@"<span class=\"md-spoiler-text\">%@</span>",
                ApolloGQLRTInlines(ApolloGQLRTArray(element[@"c"]), media, depth + 1)];
    }
    if ([kind isEqualToString:@"img"] || [kind isEqualToString:@"gif"] || [kind isEqualToString:@"video"]) {
        NSString *mediaID = ApolloGQLRTString(element[@"id"]);
        NSString *giphy = ApolloGQLRTGiphyPage(mediaID);
        if (giphy) {
            NSString *escaped = ApolloGQLRTEscape(giphy);
            return [NSString stringWithFormat:@"<a href=\"%@\" target=\"_blank\">%@</a>", escaped, escaped];
        }
        NSString *url = ApolloGQLRTMediaURL(mediaID, media);
        if (url.length == 0) return @"";
        NSString *escaped = ApolloGQLRTEscape(url);
        return [NSString stringWithFormat:@"<a href=\"%@\">%@</a>", escaped, escaped];
    }
    // Something newer than this list: its children if it has any, else its text.
    NSArray *children = ApolloGQLRTArray(element[@"c"]);
    if (children.count > 0) return ApolloGQLRTInlines(children, media, depth + 1);
    return ApolloGQLRTEscape(text);
}

static NSString *ApolloGQLRTInlines(NSArray *elements, NSArray *media, NSUInteger depth) {
    if (depth > 32) return @"";
    NSMutableString *out = [NSMutableString string];
    for (id element in elements) {
        if ([element isKindOfClass:[NSDictionary class]]) [out appendString:ApolloGQLRTInline(element, media, depth)];
    }
    return out;
}

static NSString *ApolloGQLRTBlocks(NSArray *blocks, NSArray *media, NSUInteger depth);

static NSString *ApolloGQLRTCellAlign(id align) {
    NSString *a = ApolloGQLRTString(align).uppercaseString;
    if ([a isEqualToString:@"L"]) return @" align=\"left\"";
    if ([a isEqualToString:@"R"]) return @" align=\"right\"";
    if ([a isEqualToString:@"C"]) return @" align=\"center\"";
    return @"";
}

static NSString *ApolloGQLRTTable(NSDictionary *table, NSArray *media, NSUInteger depth) {
    NSArray *header = ApolloGQLRTArray(table[@"h"]);
    NSMutableString *out = [NSMutableString stringWithString:@"<table><thead>\n<tr>\n"];
    NSMutableArray<NSString *> *aligns = [NSMutableArray array];
    for (id cell in header) {
        NSDictionary *c = [cell isKindOfClass:[NSDictionary class]] ? cell : @{};
        NSString *align = ApolloGQLRTCellAlign(c[@"a"]);
        [aligns addObject:align];
        [out appendFormat:@"<th%@>%@</th>\n", align, ApolloGQLRTInlines(ApolloGQLRTArray(c[@"c"]), media, depth + 1)];
    }
    [out appendString:@"</tr>\n</thead><tbody>\n"];
    for (id row in ApolloGQLRTArray(table[@"c"])) {
        NSArray *cells = ApolloGQLRTArray(row);
        if (!cells) continue;
        [out appendString:@"<tr>\n"];
        for (NSUInteger i = 0; i < cells.count; i++) {
            NSDictionary *c = [cells[i] isKindOfClass:[NSDictionary class]] ? cells[i] : @{};
            [out appendFormat:@"<td%@>%@</td>\n", i < aligns.count ? aligns[i] : @"",
             ApolloGQLRTInlines(ApolloGQLRTArray(c[@"c"]), media, depth + 1)];
        }
        [out appendString:@"</tr>\n"];
    }
    [out appendString:@"</tbody></table>"];
    return out;
}

static NSString *ApolloGQLRTList(NSDictionary *list, NSArray *media, NSUInteger depth) {
    BOOL ordered = [list[@"o"] respondsToSelector:@selector(boolValue)] && [list[@"o"] boolValue];
    NSString *tag = ordered ? @"ol" : @"ul";
    NSMutableString *out = [NSMutableString stringWithFormat:@"<%@>\n", tag];
    for (id item in ApolloGQLRTArray(list[@"c"])) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSArray *children = ApolloGQLRTArray(item[@"c"]) ?: @[];
        // Reddit writes an item that is one paragraph, or a paragraph followed
        // by nested lists, without the <p>.
        BOOL tight = children.count > 0;
        for (NSUInteger i = 0; i < children.count && tight; i++) {
            NSString *kind = [children[i] isKindOfClass:[NSDictionary class]] ? ApolloGQLRTString(children[i][@"e"]) : nil;
            tight = i == 0 ? [kind isEqualToString:@"par"] : [kind isEqualToString:@"list"];
        }
        if (tight) {
            [out appendFormat:@"<li>%@", ApolloGQLRTInlines(ApolloGQLRTArray(children[0][@"c"]), media, depth + 1)];
            if (children.count > 1) {
                NSArray *rest = [children subarrayWithRange:NSMakeRange(1, children.count - 1)];
                [out appendFormat:@"\n\n%@", ApolloGQLRTBlocks(rest, media, depth + 1)];
            }
            [out appendString:@"</li>\n"];
        } else {
            [out appendFormat:@"<li>%@</li>\n", ApolloGQLRTBlocks(children, media, depth + 1)];
        }
    }
    [out appendFormat:@"</%@>", tag];
    return out;
}

static NSString *ApolloGQLRTBlock(NSDictionary *block, NSArray *media, NSUInteger depth) {
    NSString *kind = ApolloGQLRTString(block[@"e"]);
    NSArray *children = ApolloGQLRTArray(block[@"c"]);
    if ([kind isEqualToString:@"par"]) {
        return [NSString stringWithFormat:@"<p>%@</p>", ApolloGQLRTInlines(children, media, depth + 1)];
    }
    if ([kind isEqualToString:@"h"]) {
        NSInteger level = [block[@"l"] respondsToSelector:@selector(integerValue)] ? [block[@"l"] integerValue] : 1;
        level = MAX(1, MIN(6, level));
        return [NSString stringWithFormat:@"<h%ld>%@</h%ld>", (long)level, ApolloGQLRTInlines(children, media, depth + 1), (long)level];
    }
    if ([kind isEqualToString:@"blockquote"]) {
        return [NSString stringWithFormat:@"<blockquote>\n%@\n</blockquote>", ApolloGQLRTBlocks(children, media, depth + 1)];
    }
    if ([kind isEqualToString:@"list"]) return ApolloGQLRTList(block, media, depth);
    if ([kind isEqualToString:@"code"]) {
        NSMutableString *code = [NSMutableString string];
        for (id line in children) {
            if (![line isKindOfClass:[NSDictionary class]]) continue;
            [code appendString:ApolloGQLRTEscape(ApolloGQLRTString(line[@"t"]) ?: @"")];
            [code appendString:@"\n"];
        }
        return [NSString stringWithFormat:@"<pre><code>%@</code></pre>", code];
    }
    if ([kind isEqualToString:@"table"]) return ApolloGQLRTTable(block, media, depth);
    if ([kind isEqualToString:@"hr"]) return @"<hr/>";
    if ([kind isEqualToString:@"img"] || [kind isEqualToString:@"gif"] || [kind isEqualToString:@"video"]) {
        NSString *link = ApolloGQLRTInline(block, media, depth);
        if (link.length == 0) return nil;
        // The caption is plain text under the image.
        NSString *caption = ApolloGQLRTString(block[@"c"]);
        return caption.length > 0 ? [NSString stringWithFormat:@"<p>%@</p>\n\n<p>%@</p>", link, ApolloGQLRTEscape(caption)]
                                  : [NSString stringWithFormat:@"<p>%@</p>", link];
    }
    // Something newer than this list. Block children (they have block kinds)
    // are rendered as blocks, anything else as one paragraph.
    if (children.count > 0) {
        NSString *first = [children[0] isKindOfClass:[NSDictionary class]] ? ApolloGQLRTString(children[0][@"e"]) : nil;
        static NSSet<NSString *> *blockKinds;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            blockKinds = [NSSet setWithArray:@[ @"par", @"h", @"blockquote", @"list", @"code", @"table", @"hr" ]];
        });
        if (first && [blockKinds containsObject:first]) return ApolloGQLRTBlocks(children, media, depth + 1);
        return [NSString stringWithFormat:@"<p>%@</p>", ApolloGQLRTInlines(children, media, depth + 1)];
    }
    NSString *text = ApolloGQLRTString(block[@"t"]);
    return text.length > 0 ? [NSString stringWithFormat:@"<p>%@</p>", ApolloGQLRTEscape(text)] : nil;
}

static NSString *ApolloGQLRTBlocks(NSArray *blocks, NSArray *media, NSUInteger depth) {
    if (depth > 32) return @"";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (id block in blocks) {
        if (![block isKindOfClass:[NSDictionary class]]) continue;
        NSString *html = ApolloGQLRTBlock(block, media, depth);
        if (html.length > 0) [parts addObject:html];
    }
    return [parts componentsJoinedByString:@"\n\n"];
}

static NSString *ApolloGQLRTWrap(NSString *inner, BOOL selfPost) {
    NSString *div = [NSString stringWithFormat:@"<div class=\"md\">%@\n</div>", inner];
    return selfPost ? [NSString stringWithFormat:@"<!-- SC_OFF -->%@<!-- SC_ON -->", div] : div;
}

NSString *ApolloGQLRichTextHTML(id document, NSArray *media, BOOL selfPost) {
    id parsed = document;
    if ([document isKindOfClass:[NSString class]]) {
        NSData *data = [(NSString *)document dataUsingEncoding:NSUTF8StringEncoding];
        parsed = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    }
    if (![parsed isKindOfClass:[NSDictionary class]]) return nil;
    NSArray *blocks = ApolloGQLRTArray(((NSDictionary *)parsed)[@"document"]);
    if (blocks.count == 0) return nil;
    NSString *inner = ApolloGQLRTBlocks(blocks, [media isKindOfClass:[NSArray class]] ? media : nil, 0);
    return inner.length > 0 ? ApolloGQLRTWrap(inner, selfPost) : nil;
}

NSString *ApolloGQLPlainTextHTML(NSString *markdown, BOOL selfPost) {
    if (![markdown isKindOfClass:[NSString class]]) return nil;
    NSMutableArray<NSString *> *paragraphs = [NSMutableArray array];
    for (NSString *paragraph in [markdown componentsSeparatedByString:@"\n\n"]) {
        NSString *trimmed = [paragraph stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0) continue;
        NSString *escaped = [ApolloGQLRTEscape(trimmed) stringByReplacingOccurrencesOfString:@"\n" withString:@"<br/>\n"];
        [paragraphs addObject:[NSString stringWithFormat:@"<p>%@</p>", escaped]];
    }
    return paragraphs.count > 0 ? ApolloGQLRTWrap([paragraphs componentsJoinedByString:@"\n\n"], selfPost) : nil;
}
