#include "ApolloClassicBarTheme.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

static int failures = 0;

static void expect(const char *name, bool actual, bool expected) {
    if (actual == expected) return;
    fprintf(stderr, "FAIL %s: got %s, expected %s\n",
            name, actual ? "route" : "pass", expected ? "route" : "pass");
    failures++;
}

int main(void) {
    const uint32_t raisedLight = UINT32_C(0xF7EDFF);
    const uint32_t raisedDark = UINT32_C(0x2A1259);

    expect("Raised light routes",
           ApolloClassicBarShouldRouteRaisedToBars(true, false, true, 1.0,
                                                   raisedLight, raisedLight, raisedDark),
           true);
    expect("Raised dark routes",
           ApolloClassicBarShouldRouteRaisedToBars(true, false, true, 1.0,
                                                   raisedDark, raisedLight, raisedDark),
           true);
    expect("disabled runtime passes through",
           ApolloClassicBarShouldRouteRaisedToBars(false, false, true, 1.0,
                                                   raisedLight, raisedLight, raisedDark),
           false);
    expect("Liquid Glass passes through",
           ApolloClassicBarShouldRouteRaisedToBars(true, true, true, 1.0,
                                                   raisedLight, raisedLight, raisedDark),
           false);
    expect("alpha below 0.99 passes through",
           ApolloClassicBarShouldRouteRaisedToBars(true, false, true, 0.989,
                                                   raisedLight, raisedLight, raisedDark),
           false);
    expect("unrelated RGB passes through",
           ApolloClassicBarShouldRouteRaisedToBars(true, false, true, 1.0,
                                                   UINT32_C(0x123456), raisedLight, raisedDark),
           false);
    expect("exact 0.99 opacity boundary routes",
           ApolloClassicBarShouldRouteRaisedToBars(true, false, true, 0.99,
                                                   raisedDark, raisedLight, raisedDark),
           true);
    expect("unavailable color components pass through",
           ApolloClassicBarShouldRouteRaisedToBars(true, false, false, 1.0,
                                                   raisedLight, raisedLight, raisedDark),
           false);

    if (failures) return 1;
    puts("classic_bar_theme_policy_tests passed");
    return 0;
}
