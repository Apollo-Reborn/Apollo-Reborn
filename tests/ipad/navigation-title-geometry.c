#include "../../src/ApolloNavigationTitleGeometry.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    // A full 700pt primary bar has 280pt hidden underneath the sidebar.
    // Centering its title in all 700pt incorrectly yields no room at all.
    CGRect physical = CGRectMake(0, 0, 700, 44);
    CGRect visible = CGRectMake(280, 0, 420, 44);
    ApolloNavigationTitleGeometry old = ApolloNavigationTitleCenteredGeometry(physical, 340, 580, 12, 8);
    ApolloNavigationTitleGeometry pane = ApolloNavigationTitleCenteredGeometry(visible, 340, 580, 12, 8);
    assert(old.maximumContentWidth == 0);
    assert(pane.center == 490);
    assert(pane.maximumContentWidth == 140);
    assert(pane.center - pane.maximumContentWidth / 2 - 12 >= 340 + 8);
    assert(pane.center + pane.maximumContentWidth / 2 + 12 <= 580 - 8);

    // Mirror the sidebar and buttons: the visible header still has 420pt.
    ApolloNavigationTitleGeometry rtl = ApolloNavigationTitleCenteredGeometry(
        CGRectMake(0, 0, 420, 44), 120, 360, 12, 8);
    assert(rtl.center == 210);
    assert(rtl.maximumContentWidth == pane.maximumContentWidth);

    // With no sidebar, using the visible bounds preserves whole-bar policy.
    ApolloNavigationTitleGeometry phone = ApolloNavigationTitleCenteredGeometry(
        CGRectMake(0, 0, 390, 44), 60, 290, 12, 8);
    assert(phone.center == 195);
    assert(phone.maximumContentWidth == 150);

    // Folded Duo's physical bar extends under an 84pt reserved strip. Its
    // title must center in the 382pt usable header, not at physical x233.
    ApolloNavigationTitleGeometry cover = ApolloNavigationTitleCenteredGeometry(
        CGRectMake(0, 0, 382, 44), 0, 382, 12, 8);
    assert(cover.center == 191);
    assert(cover.maximumContentWidth == 342);
    // A leading reservation mirrors the same usable region in RTL.
    ApolloNavigationTitleGeometry coverRTL = ApolloNavigationTitleCenteredGeometry(
        CGRectMake(84, 0, 382, 44), 84, 466, 12, 8);
    assert(coverRTL.center == 275);
    assert(coverRTL.maximumContentWidth == cover.maximumContentWidth);
    puts("Pane title geometry: sidebar occlusion, RTL and whole-bar control passed");
}
