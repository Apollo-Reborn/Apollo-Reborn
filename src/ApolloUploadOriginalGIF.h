#import <Foundation/Foundation.h>
#include <mach-o/loader.h>

// Camera-roll GIFs in comment uploads (#1663).
//
// Apollo's three photo pickers (comment/reply composer, chat, post composer) all
// run a picked photo through the same ImageIO chain before uploading it:
// CGImageSourceCreateWithURL -> CGImageSourceCreateThumbnailAtIndex(index 0) ->
// a one-image JPEG CGImageDestination. A GIF comes out as a JPEG of its first
// frame. The rebindings here (Apollo's own image only) spot that chain running on
// an animated GIF picked in a comment/reply composer and keep a copy of the
// original file, keyed by the JPEG Apollo produced. The upload hooks in
// ApolloImageUploadHost.xm look the JPEG up and upload the GIF in its place.
// Post and chat picks keep Apollo's still.

#ifdef __cplusplus
extern "C" {
#endif

/// Rebinds the three ImageIO calls in the given image (Apollo's main binary).
void ApolloUploadOriginalGIFInstallRebindings(const struct mach_header *header, intptr_t slide);

/// The original GIF behind an upload body Apollo flattened to a JPEG, or nil.
NSData *ApolloUploadOriginalGIFDataForBody(NSData *body);

/// Same for a file-backed upload: a temporary .gif file URL, or nil.
NSURL *ApolloUploadOriginalGIFFileForBodyFile(NSURL *fileURL);

/// YES when the bytes start with a GIF signature ("GIF87a" / "GIF89a").
BOOL ApolloUploadDataIsGIF(NSData *data);

#ifdef __cplusplus
}
#endif
