#include "ApolloCommentSpoilerContrast.h"

#include <assert.h>
#include <stdio.h>

int main(void) {
    assert(ApolloCommentSpoilerAdjustedFillRGB(0x000000, 0x000000, true, true)
           == 0x505257);
    assert(ApolloCommentSpoilerAdjustedFillRGB(0x050505, 0x000000, true, true)
           == 0x505257);

    // The policy is scoped to Apollo's Pure Black dark appearance.
    assert(ApolloCommentSpoilerAdjustedFillRGB(0x000000, 0x000000, false, true)
           == 0x000000);
    assert(ApolloCommentSpoilerAdjustedFillRGB(0x000000, 0x000000, true, false)
           == 0x000000);
    assert(ApolloCommentSpoilerAdjustedFillRGB(0x002B36, 0x003745, true, true)
           == 0x002B36);

    // Markdown code blocks are painted in the same callback. Their native
    // dark background is already distinct and must not be mistaken for the
    // collapsed spoiler/background pair.
    assert(ApolloCommentSpoilerAdjustedFillRGB(0x282C34, 0x000000, true, true)
           == 0x282C34);

    // A fill that is already visible must not be rewritten.
    assert(ApolloCommentSpoilerContrastRatio(0x505257, 0x000000) > 1.5);
    assert(ApolloCommentSpoilerAdjustedFillRGB(0x505257, 0x000000, true, true)
           == 0x505257);

    puts("comment_spoiler_contrast_tests passed");
    return 0;
}
