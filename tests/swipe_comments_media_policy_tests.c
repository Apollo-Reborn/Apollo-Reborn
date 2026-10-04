#include <assert.h>
#include <stdio.h>

#include "ApolloSwipeCommentsMediaPolicy.h"

int main(void) {
    assert(ApolloSwipeCommentsMediaShouldProtect(true, true, false));
    assert(!ApolloSwipeCommentsMediaShouldProtect(false, true, false));
    assert(!ApolloSwipeCommentsMediaShouldProtect(true, false, false));
    assert(!ApolloSwipeCommentsMediaShouldProtect(true, true, true));

    assert(ApolloSwipeCommentsMediaCapturedRate(0.5f, false, false, 0.0f,
                                                false, 0.0f) == 0.5f);
    assert(ApolloSwipeCommentsMediaCapturedRate(1.5f, false, false, 0.0f,
                                                false, 0.0f) == 1.5f);
    assert(ApolloSwipeCommentsMediaCapturedRate(0.0f, true, true, 0.5f,
                                                true, 1.0f) == 0.5f);
    assert(ApolloSwipeCommentsMediaCapturedRate(0.0f, true, true, 1.5f,
                                                true, 1.0f) == 1.5f);
    assert(ApolloSwipeCommentsMediaCapturedRate(0.0f, true, false, 0.0f,
                                                true, 1.25f) == 1.25f);
    assert(ApolloSwipeCommentsMediaCapturedRate(0.0f, true, false, 0.0f,
                                                false, 0.0f) == 1.0f);
    assert(ApolloSwipeCommentsMediaCapturedRate(0.0f, false, true, 1.5f,
                                                true, 1.0f) == 0.0f);

    assert(ApolloSwipeCommentsMediaRateToRestore(true, 0.5f, 0.0f) == 0.5f);
    assert(ApolloSwipeCommentsMediaRateToRestore(true, 1.5f, 1.0f) == 1.5f);
    assert(ApolloSwipeCommentsMediaRateToRestore(true, 1.5f, 1.5f) == 0.0f);
    assert(ApolloSwipeCommentsMediaRateToRestore(true, 0.0f, 0.0f) == 0.0f);
    assert(ApolloSwipeCommentsMediaRateToRestore(false, 1.5f, 0.0f) == 0.0f);

    assert(ApolloSwipeCommentsMediaShouldRestoreLayer(true, true, false));
    assert(!ApolloSwipeCommentsMediaShouldRestoreLayer(true, false, false));
    assert(!ApolloSwipeCommentsMediaShouldRestoreLayer(true, true, true));
    assert(!ApolloSwipeCommentsMediaShouldRestoreLayer(false, true, false));

    assert(!ApolloSwipeCommentsMediaShouldInvalidateAfterDismissal(false));
    assert(ApolloSwipeCommentsMediaShouldInvalidateAfterDismissal(true));

    puts("swipe_comments_media_policy_tests passed");
    return 0;
}
