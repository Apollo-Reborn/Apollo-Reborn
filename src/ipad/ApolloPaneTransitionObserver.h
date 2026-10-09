#import <Foundation/Foundation.h>

// Event-local fallback for native transitions that reject late completion
// registration. No idle timer and no retained controller lifetime.
@interface ApolloPaneTransitionObserver : NSObject
+ (void)observeOwner:(id)owner key:(NSString *)key timeout:(NSTimeInterval)timeout
              ready:(BOOL (^)(id owner))ready
         completion:(void (^)(id owner, BOOL timedOut))completion;
+ (void)cancelOwner:(id)owner;
+ (NSUInteger)activeCountForOwner:(id)owner;
@end
