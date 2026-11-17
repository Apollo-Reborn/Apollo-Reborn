#ifndef APOLLO_MULTIREDDIT_EDIT_H
#define APOLLO_MULTIREDDIT_EDIT_H

#import <Foundation/Foundation.h>

// Expansion-gate bridge for ApolloFollowingSection.xm (defined in
// ApolloMultiredditEdit.xm, which owns the captured RDKMultireddit lists).
// See the implementation comment there for the resolution rules.
NSInteger ApolloMultiEditExpansionChildCounts(NSString *title, NSString *subtitle, NSInteger *outTotalChildrenForTitle);

#endif
