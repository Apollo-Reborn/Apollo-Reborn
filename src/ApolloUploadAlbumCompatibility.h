#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

__BEGIN_DECLS
// Apollo creates an Imgur album even when the comment picker selects one image.
NSArray<NSString *> *ApolloUploadAlbumTokens(NSURLRequest *request);
// Claim an album only when EVERY member belongs to the same upload adapter.
NSArray<NSString *> * _Nullable ApolloUploadAlbumResolveMembers(NSArray<NSString *> *tokens,
    NSString * _Nullable (^resolve)(NSString *token));
// Apollo ignores data.link and rebuilds https://imgur.com/a/<data.id>/.
// Replace only adapter-owned albums, consuming the whole markdown link when
// necessary so expansion into several native images cannot nest markdown.
NSString *ApolloUploadAlbumResolveText(NSString *text,
    NSString * _Nullable (^replacementForAlbum)(NSString *albumID), NSRange * _Nullable selection);
__END_DECLS

NS_ASSUME_NONNULL_END
