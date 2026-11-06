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
    // Wide transport tiles, the thin timeline and the accessory row stay inside
    // the panel, and clear of each other, at the smallest supported panel and
    // normal Duo portrait sizes.
    CGSize panels[] = {CGSizeMake(320, 240), CGSizeMake(637, 321.5), CGSizeMake(919, 540)};
    for (unsigned i = 0; i < sizeof(panels) / sizeof(panels[0]); i++) {
        ApolloDuoVideoControlGeometry controls;
        assert(ApolloDuoVideoMakeControlGeometry(panels[i], 5, &controls));
        CGRect panel = (CGRect){CGPointZero, panels[i]};
        assert(controls.accessoryCount == 5);
        assert(controls.playback[1].size.width > controls.playback[0].size.width);
        assert(controls.playback[0].size.width == controls.playback[2].size.width);
        assert(controls.playback[0].size.height == controls.playback[1].size.height);
        assert(controls.playback[0].size.height >= 88);
        assert(CGRectGetMidY(controls.playback[0]) == CGRectGetMidY(controls.playback[1]));
        assert(CGRectGetMidY(controls.playback[2]) == CGRectGetMidY(controls.playback[1]));
        CGFloat gapL = CGRectGetMinX(controls.playback[1]) - CGRectGetMaxX(controls.playback[0]);
        CGFloat gapR = CGRectGetMinX(controls.playback[2]) - CGRectGetMaxX(controls.playback[1]);
        assert(fabs(gapL - gapR) < 0.5 && gapL >= 8);
        CGFloat groupMin = CGRectGetMinX(controls.playback[0]);
        CGFloat groupMax = CGRectGetMaxX(controls.playback[2]);
        assert(fabs(groupMin - (panels[i].width - groupMax)) < 0.5);
        assert(groupMax - groupMin > panels[i].width * 0.8);
        assert(controls.timeline.size.height == 34);
        assert(CGRectGetMinX(controls.timeline) == 16);
        assert(CGRectGetMinY(controls.timeline) <= CGRectGetMinY(controls.playback[0]));
        for (int button = 0; button < 3; button++) {
            assert(CGRectContainsRect(panel, controls.playback[button]));
            assert(!CGRectIntersectsRect(controls.playback[button], controls.scrubber));
            assert(CGRectGetMaxY(controls.timeline) <= CGRectGetMinY(controls.playback[button]));
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
        assert(CGRectGetMaxY(controls.timeline) <= panels[i].height);
        assert(CGRectGetMinY(controls.accessories[0]) >= CGRectGetMaxY(controls.playback[0]));
        for (int slot = 0; slot < controls.accessoryCount; slot++) {
            assert(controls.accessories[slot].size.height == 56);
            assert(controls.accessories[slot].size.width >= 44);
            assert(CGRectContainsRect(panel, controls.accessories[slot]));
            assert(!CGRectIntersectsRect(controls.accessories[slot], controls.scrubber));
            assert(!CGRectIntersectsRect(controls.accessories[slot], controls.playback[0]));
            assert(!CGRectIntersectsRect(controls.accessories[slot], controls.playback[1]));
            assert(!CGRectIntersectsRect(controls.accessories[slot], controls.playback[2]));
            if (slot > 0) {
                assert(controls.accessories[slot].origin.y == controls.accessories[0].origin.y);
                assert(CGRectGetMinX(controls.accessories[slot]) >= CGRectGetMaxX(controls.accessories[slot - 1]));
            }
        }
    }
    ApolloDuoVideoControlGeometry invalid;
    assert(!ApolloDuoVideoMakeControlGeometry(CGSizeMake(320, 240), 1, &invalid));
    assert(!ApolloDuoVideoMakeControlGeometry(CGSizeMake(320, 240), 7, &invalid));
    assert(!ApolloDuoVideoMakeControlGeometry(CGSizeMake(320, 240), 6, &invalid));
    assert(ApolloDuoVideoMakeControlGeometry(CGSizeMake(919, 540), 6, &invalid));
    assert(!ApolloDuoVideoMakeControlGeometry(CGSizeMake(319, 240), 2, &invalid));
    assert(!ApolloDuoVideoMakeControlGeometry(CGSizeMake(637, 239), 2, &invalid));
    assert(!ApolloDuoVideoMakeControlGeometry(CGSizeMake(NAN, 300), 2, &invalid));
    assert(!ApolloDuoVideoMakeControlGeometry(CGSizeMake(637, INFINITY), 2, &invalid));
    assert(!ApolloDuoVideoMakeControlGeometry(CGSizeMake(637, 300), 2, NULL));
    puts("Duo video geometry: all checks passed");
    return 0;
}
