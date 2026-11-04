# Comment photo uploads and synthetic albums

Apollo's comment picker uploads every selection through its album path, including
a single photo. The native photo-post picker and comment picker share the Imgur
network adapter, but consume its results differently.

Verified against the current Apollo binary in Hopper:

- `sub_100613e20` collects uploaded image deletehashes, then calls
  `sub_1006154dc` to create an album without a two-image minimum.
- `sub_100615918` unboxes only `data.id` and constructs
  `https://imgur.com/a/<id>/`. It ignores the response's `data.link`.
- `sub_1001bc3a8` inserts that URL with `replaceRange:withText:`, then computes
  the caret from the original URL's length and runs the toolbar's link action.
  Replacing the text synchronously inside that call leaves the caret in the
  wrong place. Resolution therefore runs on the next main-queue turn and maps
  the current selection through each replacement.

The Reddit album responder now accepts one or more recorded image uploads and
resolves the returned S3-key deletehash separately from the lease's asset ID.
It claims an album only when every member is recorded. Provider selection is
based on actual member ownership, since Comment Link Host and Auto can override
the global Media Upload Host.

The body editor expands an owned synthetic Reddit album into its staged member
URLs, in picker order. The existing comment RTJSON adapter uses their asset IDs
to submit native images. An owned Image Chest album becomes its public
`imgchest.com/p/…` URL. Ordinary Imgur albums pass through. The comment request
boundary repeats resolution for callers that bypass editor insertion; the native
photo-post picker retains its synthetic album ID for `submit_gallery`.

## Verification

`bash tests/run_upload_album_compatibility_tests.sh` checks request parsing,
single-image albums, ordering, complete ownership, link expansion, URL boundaries,
and selection mapping using the production Foundation helper.

The simulator's existing debug bridge accepts `uploadalbumtest`. It registers
fixture assets whose S3 keys differ from their lease IDs, creates one- and
two-image albums through the installed NSURLSession hook, then checks resolution
and comment RTJSON rewriting. It sends no media or comments to external services.
Results appear in the `apollofix` log and `/tmp/apollo-upload-album-{1,2}-result.txt`.

Manual service validation: attach one and two photos to a comment and a reply
using Reddit with an API key; check insertion, caret, submission and rendering.
Repeat with Imgur and Image Chest, including Comment Link Host overrides and
Auto native routing. Native image permissions still depend on the subreddit.
Verify photo posts still submit as Reddit galleries and public Imgur albums
retain their original links. Check copy/paste and saved drafts after insertion.

Issue #1394 describes an apparently Imgur-hosted dead album link. Auto routing
can send comment uploads to Reddit even with global Imgur selected; the supplied
Reddit-hosted report demonstrates the single-image failure separately. A genuine
Imgur service failure requires a real Imgur upload to distinguish it from that
synthetic-link case.
