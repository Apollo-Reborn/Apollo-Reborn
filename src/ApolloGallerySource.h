#import <UIKit/UIKit.h>

@class ApolloGalleryFeed;

NS_ASSUME_NONNULL_BEGIN
__BEGIN_DECLS

// Snapshot the source feed while its menu is opening and warm only the first
// screenful of gallery thumbnails. No listing request is made here.
void ApolloGalleryPrepareSource(UIViewController *sourceViewController);

// Immutable source value used to validate a prepared gallery at selection.
// Includes the current cursor, sort and live NSFW/spoiler flags; nil means the
// source cannot safely seed a gallery.
NSDictionary * _Nullable ApolloGallerySourcePreparationState(UIViewController *sourceViewController);

// Called after applying the source sort, before pushing the gallery. Returns
// NO when source state cannot be copied completely and safely; the gallery's
// ordinary initial request then remains responsible for loading the listing.
BOOL ApolloGallerySeedFeedFromSource(ApolloGalleryFeed *feed, UIViewController *sourceViewController);

__END_DECLS
NS_ASSUME_NONNULL_END
