#import <Foundation/Foundation.h>

// PRODUCTION_PARSER

static void Require(BOOL condition, NSString *message) {
    if (condition) return;
    NSLog(@"FAIL: %@", message);
    exit(1);
}

static NSData *JSONData(id object) {
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
}

int main(void) {
    @autoreleasepool {
        Require(ApolloUserFlairTemplateRecordsFromJSONData(nil) == nil,
                @"missing data is not a definitive template response");
        Require(ApolloUserFlairTemplateRecordsFromJSONData([@"<html>blocked</html>"
            dataUsingEncoding:NSUTF8StringEncoding]) == nil,
                @"HTML block pages are rejected");
        Require(ApolloUserFlairTemplateRecordsFromJSONData(JSONData(@{ @"id": @"not-an-array" })) == nil,
                @"non-array JSON roots are rejected");

        NSArray *empty = ApolloUserFlairTemplateRecordsFromJSONData(JSONData(@[]));
        Require(empty != nil && empty.count == 0, @"an empty template array is definitive");

        NSArray *raw = @[
            @{
                @"id": @"template-rich",
                @"text": @"Hello :wave:",
                @"css_class": @"legacy-blue",
                @"text_editable": @YES,
                @"richtext": @[
                    @{ @"e": @"text", @"t": @"Hello " },
                    @{ @"e": @"emoji", @"a": @":wave:", @"u": @"https://emoji.redditmedia.com/wave.png" },
                    @{ @"e": @"unsupported", @"t": @"ignored" },
                ],
            },
            @{
                @"id": @"template-defaults",
                @"text_editable": @"not-a-number",
                @"richtext": @[
                    @{ @"e": @"emoji", @"a": @":missing-url:" },
                    @{ @"e": @"text", @"t": @"" },
                ],
            },
            @{ @"id": @"", @"text": @"skip empty identifier" },
            @{ @"text": @"skip missing identifier" },
            @"skip non-dictionary",
        ];
        NSArray<NSDictionary *> *records = ApolloUserFlairTemplateRecordsFromJSONData(JSONData(raw));
        Require(records.count == 2, @"only valid template dictionaries are retained");

        NSDictionary *rich = records[0];
        Require([rich[@"identifier"] isEqualToString:@"template-rich"], @"identifier is preserved");
        Require([rich[@"text"] isEqualToString:@"Hello :wave:"], @"plain text is preserved");
        Require([rich[@"cssClass"] isEqualToString:@"legacy-blue"], @"CSS class is preserved");
        Require([rich[@"editable"] isEqual:@YES], @"editability is preserved");
        Require([rich[@"emojiURLs"][@"wave"] isEqualToString:@"https://emoji.redditmedia.com/wave.png"],
                @"emoji aliases are normalized and URLs retained");
        NSArray *pieces = rich[@"pieces"];
        Require(pieces.count == 2, @"supported rich-text pieces are retained in order");
        Require([pieces[0][@"kind"] isEqualToString:@"text"] &&
                [pieces[0][@"text"] isEqualToString:@"Hello "], @"text piece is normalized");
        Require([pieces[1][@"kind"] isEqualToString:@"emoji"] &&
                [pieces[1][@"name"] isEqualToString:@"wave"], @"emoji piece is normalized");

        NSDictionary *defaults = records[1];
        Require([defaults[@"text"] isEqualToString:@""], @"missing text defaults empty");
        Require([defaults[@"cssClass"] isEqualToString:@""], @"missing CSS class defaults empty");
        Require([defaults[@"editable"] isEqual:@NO], @"non-boolean editability defaults false");
        Require([defaults[@"pieces"] count] == 0 && [defaults[@"emojiURLs"] count] == 0,
                @"malformed rich-text pieces fail closed");

        NSLog(@"user flair template parser tests passed");
    }
    return 0;
}
