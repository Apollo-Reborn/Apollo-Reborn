#import <Foundation/Foundation.h>
#import "ApolloDuoVideoGeometry.h"
#include <assert.h>

int main(void) {
    CGRect bounds = CGRectMake(0, 0, 951, 1356);
    CGRect fold = CGRectMake(0, 670, 951, 16);
    ApolloDuoVideoGeometry layout;
    assert(ApolloDuoVideoMakeGeometry(bounds, fold, 24, 0, 34, 0, true, &layout));
    assert(CGRectGetMaxY(layout.video) < CGRectGetMinY(fold));
    assert(CGRectGetMinY(layout.controls) > CGRectGetMaxY(fold));
    assert(CGRectGetMaxY(layout.controls) <= 1356 - 34 - 80);
    assert(CGRectContainsRect(bounds, layout.video));
    assert(CGRectContainsRect(bounds, layout.controls));
    assert(!ApolloDuoVideoMakeGeometry(bounds, fold, 24, 0, 34, 0, false, &layout));
    assert(!ApolloDuoVideoMakeGeometry(bounds, CGRectNull, 0, 0, 0, 0, true, &layout));
    assert(!ApolloDuoVideoMakeGeometry(bounds, CGRectMake(470, 0, 12, 1356), 0, 0, 0, 0, true, &layout));
    assert(!ApolloDuoVideoMakeGeometry(bounds, CGRectMake(0, 30, 951, 10), 0, 0, 0, 0, true, &layout));
    assert(!ApolloDuoVideoMakeGeometry(bounds, CGRectMake(0, 1300, 951, 10), 0, 0, 0, 0, true, &layout));
    assert(!ApolloDuoVideoMakeGeometry(bounds, CGRectMake(100, 670, 400, 10), 0, 0, 0, 0, true, &layout));
    assert(!ApolloDuoVideoMakeGeometry(bounds, CGRectMake(0, NAN, 951, 10), 0, 0, 0, 0, true, &layout));
    assert(!ApolloDuoVideoMakeGeometry(bounds, CGRectMake(0, 670, 951, -10), 0, 0, 0, 0, true, &layout));
    assert(!ApolloDuoVideoMakeGeometry(bounds, fold, NAN, 0, 0, 0, true, &layout));
    assert(!ApolloDuoVideoMakeGeometry(CGRectMake(0, 0, 440, 956), fold, 0, 0, 0, 0, true, &layout));
    assert(!ApolloDuoVideoMakeGeometry(CGRectMake(0, 0, 1356, 951), fold, 0, 0, 0, 0, true, &layout));
    // Nonzero view coordinate origins and asymmetric safe areas stay local.
    bounds = CGRectMake(20, 40, 951, 1356);
    fold = CGRectMake(20, 710, 951, 0);
    assert(ApolloDuoVideoMakeGeometry(bounds, fold, 30, 12, 34, 20, true, &layout));
    assert(CGRectGetMinX(layout.video) == 48);
    assert(CGRectGetMinY(layout.video) == 70);
    assert(CGRectGetMaxX(layout.controls) == CGRectGetMaxX(bounds) - 36);
    assert(!ApolloDuoVideoMakeGeometry(bounds, fold, 0, 0, 0, 0, true, NULL));
    // Utility controls stay equal, aligned, and separate from the timeline at
    // the smallest supported panel as well as normal Duo portrait sizes.
    CGSize panels[] = {CGSizeMake(320, 240), CGSizeMake(637, 321.5), CGSizeMake(919, 540)};
    for (unsigned i = 0; i < sizeof(panels) / sizeof(panels[0]); i++) {
        ApolloDuoVideoControlGeometry controls;
        assert(ApolloDuoVideoMakeControlGeometry(panels[i], &controls));
        CGRect panel = (CGRect){CGPointZero, panels[i]};
        for (int button = 0; button < 3; button++) {
            assert(CGRectContainsRect(panel, controls.playback[button]));
            assert(controls.playback[button].size.height >= 80);
            assert(!CGRectIntersectsRect(controls.playback[button], controls.scrubber));
            assert(CGRectGetMinY(controls.playback[button]) == CGRectGetMaxY(controls.timeline) + 8);
        }
        assert(CGRectContainsRect(panel, controls.scrubber));
        assert(CGRectContainsRect(panel, controls.elapsed));
        assert(CGRectContainsRect(panel, controls.remaining));
        assert(CGRectContainsRect(panel, controls.timeline));
        assert(CGRectContainsRect(controls.timeline, controls.scrubber));
        assert(CGRectContainsRect(controls.timeline, controls.elapsed));
        assert(CGRectContainsRect(controls.timeline, controls.remaining));
        assert(!CGRectIntersectsRect(controls.elapsed, controls.scrubber));
        assert(!CGRectIntersectsRect(controls.remaining, controls.scrubber));
        assert(CGRectGetMidY(controls.elapsed) == CGRectGetMidY(controls.scrubber));
        assert(CGRectGetMidY(controls.remaining) == CGRectGetMidY(controls.scrubber));
        assert(controls.elapsed.size.width >= 58); // hour-length timestamps
        assert(controls.utilities[0].size.width == controls.utilities[1].size.width);
        assert(controls.utilities[0].origin.y == controls.utilities[1].origin.y);
        assert(!CGRectIntersectsRect(controls.utilities[0], controls.utilities[1]));
        for (int utility = 0; utility < 2; utility++) {
            assert(CGRectContainsRect(panel, controls.utilities[utility]));
            assert(controls.utilities[utility].size.height >= 44);
            assert(CGRectGetMinY(controls.utilities[utility]) == CGRectGetMaxY(controls.playback[0]) + 8);
            assert(!CGRectIntersectsRect(controls.utilities[utility], controls.scrubber));
        }
    }
    ApolloDuoVideoControlGeometry invalid;
    assert(!ApolloDuoVideoMakeControlGeometry(CGSizeMake(319, 240), &invalid));
    assert(!ApolloDuoVideoMakeControlGeometry(CGSizeMake(637, 239), &invalid));
    assert(!ApolloDuoVideoMakeControlGeometry(CGSizeMake(NAN, 300), &invalid));
    assert(!ApolloDuoVideoMakeControlGeometry(CGSizeMake(637, INFINITY), &invalid));
    assert(!ApolloDuoVideoMakeControlGeometry(CGSizeMake(637, 300), NULL));
    puts("Duo video geometry: all checks passed");
    return 0;
}
