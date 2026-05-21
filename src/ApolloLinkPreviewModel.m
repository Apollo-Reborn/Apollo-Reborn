#import "ApolloLinkPreviewModel.h"

static BOOL ApolloLinkPreviewImageURLLooksLikeFallbackIcon(NSURL *url) {
    NSString *absolute = url.absoluteString.lowercaseString ?: @"";
    return [absolute containsString:@"google.com/s2/favicons"]
        || [absolute containsString:@"wikipedia-logo-v2.png"];
}

@implementation ApolloLinkPreview

+ (instancetype)previewFromDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) return nil;

    ApolloLinkPreview *preview = [ApolloLinkPreview new];
    id siteName = dictionary[@"siteName"];
    id title = dictionary[@"title"];
    id desc = dictionary[@"desc"];
    id imageURL = dictionary[@"imageURL"];
    id previewKind = dictionary[@"previewKind"];
    id authorDisplayName = dictionary[@"authorDisplayName"];
    id authorHandle = dictionary[@"authorHandle"];
    id postText = dictionary[@"postText"];
    id avatarURL = dictionary[@"avatarURL"];
    id fetchedAt = dictionary[@"fetchedAt"];
    id noMetadata = dictionary[@"noMetadata"];
    id imageWidth = dictionary[@"imageWidth"];
    id imageHeight = dictionary[@"imageHeight"];
    id imageIsFallbackIcon = dictionary[@"imageIsFallbackIcon"];

    preview.siteName = [siteName isKindOfClass:[NSString class]] ? siteName : nil;
    preview.title = [title isKindOfClass:[NSString class]] ? title : nil;
    preview.desc = [desc isKindOfClass:[NSString class]] ? desc : nil;
    preview.imageURL = [imageURL isKindOfClass:[NSString class]] ? [NSURL URLWithString:imageURL] : nil;
    preview.previewKind = [previewKind isKindOfClass:[NSString class]] ? previewKind : nil;
    preview.authorDisplayName = [authorDisplayName isKindOfClass:[NSString class]] ? authorDisplayName : nil;
    preview.authorHandle = [authorHandle isKindOfClass:[NSString class]] ? authorHandle : nil;
    preview.postText = [postText isKindOfClass:[NSString class]] ? postText : nil;
    preview.avatarURL = [avatarURL isKindOfClass:[NSString class]] ? [NSURL URLWithString:avatarURL] : nil;
    preview.fetchedAt = [fetchedAt isKindOfClass:[NSNumber class]] ? [NSDate dateWithTimeIntervalSince1970:[fetchedAt doubleValue]] : nil;
    preview.noMetadata = [noMetadata respondsToSelector:@selector(boolValue)] ? [noMetadata boolValue] : NO;
    preview.imageIsFallbackIcon = [imageIsFallbackIcon respondsToSelector:@selector(boolValue)] ? [imageIsFallbackIcon boolValue] : ApolloLinkPreviewImageURLLooksLikeFallbackIcon(preview.imageURL);
    preview.imageSize = CGSizeMake([imageWidth respondsToSelector:@selector(doubleValue)] ? [imageWidth doubleValue] : 0.0,
                                   [imageHeight respondsToSelector:@selector(doubleValue)] ? [imageHeight doubleValue] : 0.0);

    return preview;
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    if (self.siteName.length > 0) dictionary[@"siteName"] = self.siteName;
    if (self.title.length > 0) dictionary[@"title"] = self.title;
    if (self.desc.length > 0) dictionary[@"desc"] = self.desc;
    if (self.imageURL.absoluteString.length > 0) dictionary[@"imageURL"] = self.imageURL.absoluteString;
    if (self.previewKind.length > 0) dictionary[@"previewKind"] = self.previewKind;
    if (self.authorDisplayName.length > 0) dictionary[@"authorDisplayName"] = self.authorDisplayName;
    if (self.authorHandle.length > 0) dictionary[@"authorHandle"] = self.authorHandle;
    if (self.postText.length > 0) dictionary[@"postText"] = self.postText;
    if (self.avatarURL.absoluteString.length > 0) dictionary[@"avatarURL"] = self.avatarURL.absoluteString;
    if (self.fetchedAt) dictionary[@"fetchedAt"] = @([self.fetchedAt timeIntervalSince1970]);
    dictionary[@"noMetadata"] = @(self.noMetadata);
    dictionary[@"imageIsFallbackIcon"] = @(self.imageIsFallbackIcon);
    if (self.imageSize.width > 0.0) dictionary[@"imageWidth"] = @(self.imageSize.width);
    if (self.imageSize.height > 0.0) dictionary[@"imageHeight"] = @(self.imageSize.height);
    return dictionary;
}

- (BOOL)hasUsefulMetadata {
    if (self.noMetadata) return NO;
    return self.title.length > 0 || self.imageURL.absoluteString.length > 0;
}

@end
