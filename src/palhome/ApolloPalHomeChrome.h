#import <Foundation/Foundation.h>
#import "ApolloPixelCanvas.h"
#import "ApolloPalHomeCatalog.h"

// The UI's materials follow the home style: walnut planks in the cottage,
// stone in the castle, oxblood leather and gilt in the library, brushed
// steel with cyan LEDs on the space station, barn wood in the saloon, bark
// and moss in the treehouse, driftwood and sea glass under the sea.
// Panels, buttons, catalogue slots, text colours and the name sign all
// come from here. Foundation/CoreGraphics only (host-renderable).

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(int, APMaterial) {
    APMaterialWood = 0,
    APMaterialStone,
    APMaterialMetal,
    APMaterialBark,
    APMaterialDriftwood,
};

typedef struct {
    APMaterial material;
    APRamp panel, button, toggled;
    uint32_t slot, slotEdge;
    uint32_t accent;       // selection outlines
    uint32_t text, subtext, shadow;
    uint32_t trim;         // 0 = none; gilt edge / LED strip / brass
    BOOL nails;            // nail heads on plank ends
} APChromeTheme;

APChromeTheme APChromeThemeForStyle(NSString *_Nullable styleID);

APCanvas *APChromePanel(APChromeTheme t, int w, int h);
APCanvas *APChromeTile(APChromeTheme t, int w, int h, BOOL down, BOOL toggled);
APCanvas *APChromeSlot(APChromeTheme t, int w, int h, BOOL down, BOOL toggled);
// The name plaque hanging above the room; hearts < 0 hides the heart row.
// `hearts` may be fractional: like Apollo's heart bar, a remainder of a half
// or more shows a half heart. Negative hides the row.
APCanvas *APChromeSign(APChromeTheme t, NSString *title, double hearts, int maxHearts);
// One 5×5 heart, `fill` 0 (empty), 0.5 (half) or 1 (full).
void APChromeHeart(APCanvas *c, int x, int y, float fill, uint32_t empty, uint32_t shadow);

NS_ASSUME_NONNULL_END
