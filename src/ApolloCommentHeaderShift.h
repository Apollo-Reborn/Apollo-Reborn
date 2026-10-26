#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
__BEGIN_DECLS

// A collapsed comment's header row (the horizontal ASStackLayoutSpec that
// holds the author) moved so its author line sits where the expanded
// comment's does: `countNode` and `disclosureNode` are the items only the
// collapsed row shows, `optionsNode` the one only the expanded header shows,
// and `width` the width the row is laid out in. The move is read from
// Texture's layout of the row as it is and as the expanded header has it.
// The row keeps its exact horizontal layout: it is wrapped in an inset that
// takes over the row's own stack style (stretch, flex, spacing), so the row
// still spans the full width and its spacer still pushes the reply count to
// the right edge. Returns the spec to use: `spec` itself, or the wrapper when
// the header row is the root. No-op when nothing needs to move or the row
// cannot be found.
id ApolloCommentHeaderAlignCollapsedRow(id spec, id _Nullable headerRow, id _Nullable countNode,
                                        id _Nullable disclosureNode, id _Nullable optionsNode, CGFloat width);

__END_DECLS
NS_ASSUME_NONNULL_END
