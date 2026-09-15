#import <Foundation/Foundation.h>

// Pixel budget above which ApolloAsyncDisplayGuard refuses to start a node
// display (see ApolloAsyncDisplayGuard.xm). Test seam for the simulator debug
// bridge: pass 0 to restore the default.
void ApolloAsyncDisplayGuardSetMaxPixelsForTesting(double maxPixels);
double ApolloAsyncDisplayGuardMaxPixels(void);
