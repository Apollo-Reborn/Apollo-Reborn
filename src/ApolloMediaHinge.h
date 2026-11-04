#import <UIKit/UIKit.h>

__BEGIN_DECLS
/// Publish and invalidate retained Texture geometry before a Duo column transition.
/// Call after UIKit lays out the destination, before committing Texture updates.
void ApolloDuoMediaPrepareTableForTransition(UITableView *table);
__END_DECLS
