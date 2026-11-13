/* FSVMainWindow.m */

/* The main window, laid out like fsv's original GTK+ window:
 *
 *   +----------------------+---------------------------------+-+
 *   | [<-] [/] [..] [eye]  |                                 |^|
 *   | +------------------+ |                                 | |
 *   | | directory tree   | |          3D viewport            | |
 *   | +------------------+ |                                 | |
 *   | | file list        | |                                 |v|
 *   | +------------------+ +---------------------------------+-+
 *   | [status          ]   | <=============================>   |
 *   |                      | [status                         ] |
 *   +----------------------+-----------------------------------+
 *
 * It also implements the C interfaces of window.h, dirtree.h and
 * filelist.h, which replaced the corresponding GTK+ modules */

/* mac-fsv - macOS port of fsv
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version. */


#import "FSVApp.h"

#include "xmaps/back.xpm"
#include "xmaps/cd-root.xpm"
#include "xmaps/cd-up.xpm"
#include "xmaps/birdseye_view.xpm"
#include "xmaps/mini-folder-open.xpm"


/* Time for the directory tree / file list to scroll to an entry */
#define DIRTREE_SCROLL_TIME	0.5
#define FILELIST_SCROLL_TIME	0.5

#define STATUSBAR_HEIGHT	22.0
#define TOOLBAR_HEIGHT		34.0


@implementation FSVDirItem
@end


/* Outline/table subclasses that report right clicks (which, on the Mac,
 * also come from Control-clicks) */
@interface FSVOutlineView : NSOutlineView
@end

@interface FSVTableView : NSTableView
@end


/* A sunken status bar, like GTK+'s */
static NSTextField *
make_statusbar( NSRect frame )
{
	NSTextField *field = [[NSTextField alloc] initWithFrame:frame];

	field.editable = NO;
	field.selectable = NO;
	field.bezeled = YES;
	field.bezelStyle = NSTextFieldSquareBezel;
	field.drawsBackground = YES;
	field.backgroundColor = [NSColor windowBackgroundColor];
	field.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
	field.lineBreakMode = NSLineBreakByTruncatingMiddle;
	field.cell.usesSingleLineMode = YES;
	field.stringValue = @"";

	return field;
}


static NSButton *
make_tool_button( NSRect frame, char **xpm, NSString *tip, id target, SEL action, BOOL toggle )
{
	NSButton *button = [[NSButton alloc] initWithFrame:frame];

	button.image = FSVImageFromXPM( xpm );
	button.imagePosition = NSImageOnly;
	button.bezelStyle = NSBezelStyleSmallSquare;
	button.toolTip = tip;
	button.target = target;
	button.action = action;
	if (toggle)
		[button setButtonType:NSButtonTypePushOnPushOff];

	return button;
}


@implementation FSVMainWindowController {
	NSSplitView *_hsplit;
	NSSplitView *_vsplit;
	NSButton *_backButton;
	NSButton *_cdRootButton;
	NSButton *_cdUpButton;
	NSButton *_birdseyeButton;
	NSScroller *_xScroller;
	NSScroller *_yScroller;
	ScrollAdjustment _adj[2];
	NSTextField *_leftStatus;
	NSTextField *_rightStatus;

	/* Directory tree */
	NSMutableArray<FSVDirItem *> *_rootItems;
	GNode *_dirtreeCurrent;
	BOOL _suppressColexp;
	BOOL _treeDirty;
	BOOL _programmaticSelection;
	NSImage *_folderClosedIcon;
	NSImage *_folderOpenIcon;

	/* File list */
	BOOL _scanMonitorMode;
	NSArray<NSValue *> *_fileNodes;
	GNode *_filelistCurrent;
	NSMutableArray<NSArray<NSString *> *> *_monitorRows;
	double _lastUpdate;
}


- (instancetype)init
{
	NSScreen *screen = NSScreen.mainScreen;
	NSRect vis = screen ? screen.visibleFrame : NSMakeRect( 0, 0, 1280, 800 );
	CGFloat width = floor( 3.0 * vis.size.width / 4.0 );
	CGFloat height = floor( 2584.0 * width / 4181.0 );
	NSWindow *window;

	if (height > (vis.size.height - 40.0))
		height = vis.size.height - 40.0;

	window = [[NSWindow alloc] initWithContentRect:NSMakeRect( 0, 0, width, height ) styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable) backing:NSBackingStoreBuffered defer:NO];
	self = [super initWithWindow:window];
	if (self == nil)
		return nil;

	window.title = @"mac-fsv";
	window.minSize = NSMakeSize( 640, 400 );
	window.delegate = self;
	window.releasedWhenClosed = NO;
	/* The original look: GTK+ grey, whatever the system appearance */
	window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
	window.tabbingMode = NSWindowTabbingModeDisallowed;

	_rootItems = [NSMutableArray array];
	_monitorRows = [NSMutableArray array];
	_folderClosedIcon = FSVMiniIcon( NODE_DIRECTORY );
	_folderOpenIcon = FSVImageFromXPM( mini_folder_open_xpm );
	_colorMode = COLOR_BY_NODETYPE;
	_accessEnabled = YES;

	[self buildContent];
	[window center];

	return self;
}


- (void)buildContent
{
	NSView *content = self.window.contentView;
	NSRect bounds = content.bounds;
	CGFloat left_width = floor( bounds.size.width / 5.0 );
	CGFloat sw = [NSScroller scrollerWidthForControlSize:NSControlSizeRegular scrollerStyle:NSScrollerStyleLegacy];
	NSView *left, *right;
	NSBox *frame_box;
	NSScrollView *tree_scroll, *list_scroll;
	NSTableColumn *column;
	CGFloat x;

	_hsplit = [[NSSplitView alloc] initWithFrame:bounds];
	_hsplit.vertical = YES;
	_hsplit.dividerStyle = NSSplitViewDividerStyleThick;
	_hsplit.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	[content addSubview:_hsplit];

	/** Left pane **/

	left = [[NSView alloc] initWithFrame:NSMakeRect( 0, 0, left_width, bounds.size.height )];
	left.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

	/* Toolbar buttons */
	x = 4.0;
	_backButton = make_tool_button( NSMakeRect( x, bounds.size.height - TOOLBAR_HEIGHT + 2.0, 32.0, 30.0 ), back_xpm, @"Back", self, @selector(backClicked:), NO );
	x += 34.0;
	_cdRootButton = make_tool_button( NSMakeRect( x, bounds.size.height - TOOLBAR_HEIGHT + 2.0, 32.0, 30.0 ), cd_root_xpm, @"Look at root directory", self, @selector(cdRootClicked:), NO );
	x += 34.0;
	_cdUpButton = make_tool_button( NSMakeRect( x, bounds.size.height - TOOLBAR_HEIGHT + 2.0, 32.0, 30.0 ), cd_up_xpm, @"Look at parent directory", self, @selector(cdUpClicked:), NO );
	x += 34.0;
	_birdseyeButton = make_tool_button( NSMakeRect( x, bounds.size.height - TOOLBAR_HEIGHT + 2.0, 32.0, 30.0 ), birdseye_view_xpm, @"Bird's-eye view", self, @selector(birdseyeToggled:), YES );
	for (NSButton *b in @[ _backButton, _cdRootButton, _cdUpButton, _birdseyeButton ]) {
		b.autoresizingMask = NSViewMinYMargin | NSViewMaxXMargin;
		[left addSubview:b];
	}

	/* Frame around directory tree / file list */
	frame_box = [[NSBox alloc] initWithFrame:NSMakeRect( 2.0, STATUSBAR_HEIGHT + 2.0, left_width - 4.0, bounds.size.height - TOOLBAR_HEIGHT - STATUSBAR_HEIGHT - 4.0 )];
	frame_box.boxType = NSBoxCustom;
	frame_box.borderColor = [NSColor gridColor];
	frame_box.borderWidth = 1.0;
	frame_box.cornerRadius = 0.0;
	frame_box.titlePosition = NSNoTitle;
	frame_box.contentViewMargins = NSMakeSize( 0.0, 0.0 );
	frame_box.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	[left addSubview:frame_box];

	_vsplit = [[NSSplitView alloc] initWithFrame:((NSView *)frame_box.contentView).bounds];
	_vsplit.vertical = NO;
	_vsplit.dividerStyle = NSSplitViewDividerStyleThick;
	_vsplit.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	[frame_box.contentView addSubview:_vsplit];

	/* Directory tree */
	tree_scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect( 0, 0, _vsplit.bounds.size.width, floor( bounds.size.height / 3.0 ) )];
	tree_scroll.hasVerticalScroller = YES;
	tree_scroll.hasHorizontalScroller = YES;
	tree_scroll.autohidesScrollers = YES;
	tree_scroll.borderType = NSNoBorder;
	_dirTree = [[FSVOutlineView alloc] initWithFrame:tree_scroll.bounds];
	column = [[NSTableColumn alloc] initWithIdentifier:@"dir"];
	column.resizingMask = NSTableColumnAutoresizingMask;
	[_dirTree addTableColumn:column];
	_dirTree.outlineTableColumn = column;
	_dirTree.headerView = nil;
	_dirTree.rowHeight = 18.0;
	_dirTree.indentationPerLevel = 14.0;
	_dirTree.style = NSTableViewStylePlain;
	_dirTree.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
	_dirTree.autoresizesOutlineColumn = NO;
	_dirTree.dataSource = self;
	_dirTree.delegate = self;
	_dirTree.target = self;
	_dirTree.action = @selector(dirTreeClicked:);
	_dirTree.doubleAction = @selector(dirTreeDoubleClicked:);
	tree_scroll.documentView = _dirTree;
	[_vsplit addSubview:tree_scroll];
	column.width = tree_scroll.contentSize.width;
	[_dirTree sizeLastColumnToFit];

	/* File list */
	list_scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect( 0, 0, _vsplit.bounds.size.width, _vsplit.bounds.size.height - floor( bounds.size.height / 3.0 ) )];
	list_scroll.hasVerticalScroller = YES;
	list_scroll.hasHorizontalScroller = NO;
	list_scroll.autohidesScrollers = YES;
	list_scroll.borderType = NSNoBorder;
	_fileList = [[FSVTableView alloc] initWithFrame:list_scroll.bounds];
	_fileList.rowHeight = 18.0;
	_fileList.style = NSTableViewStylePlain;
	_fileList.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
	_fileList.dataSource = self;
	_fileList.delegate = self;
	_fileList.target = self;
	_fileList.action = @selector(fileListClicked:);
	_fileList.doubleAction = @selector(fileListDoubleClicked:);
	list_scroll.documentView = _fileList;
	[_vsplit addSubview:list_scroll];
	[self setFileListColumns:NO];

	/* Left statusbar */
	_leftStatus = make_statusbar( NSMakeRect( 2.0, 1.0, left_width - 4.0, STATUSBAR_HEIGHT - 2.0 ) );
	_leftStatus.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
	[left addSubview:_leftStatus];

	[_hsplit addSubview:left];

	/** Right pane **/

	right = [[NSView alloc] initWithFrame:NSMakeRect( 0, 0, bounds.size.width - left_width, bounds.size.height )];
	right.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

	_viewport = [[FSVViewport alloc] initWithFrame:NSMakeRect( 0, STATUSBAR_HEIGHT + sw, right.bounds.size.width - sw, right.bounds.size.height - STATUSBAR_HEIGHT - sw )];
	_viewport.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	[right addSubview:_viewport];

	_yScroller = [[NSScroller alloc] initWithFrame:NSMakeRect( right.bounds.size.width - sw, STATUSBAR_HEIGHT + sw, sw, right.bounds.size.height - STATUSBAR_HEIGHT - sw )];
	_yScroller.scrollerStyle = NSScrollerStyleLegacy;
	_yScroller.autoresizingMask = NSViewMinXMargin | NSViewHeightSizable;
	_yScroller.target = self;
	_yScroller.action = @selector(scrollerMoved:);
	_yScroller.enabled = NO;
	[right addSubview:_yScroller];

	_xScroller = [[NSScroller alloc] initWithFrame:NSMakeRect( 0, STATUSBAR_HEIGHT, right.bounds.size.width - sw, sw )];
	_xScroller.scrollerStyle = NSScrollerStyleLegacy;
	_xScroller.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
	_xScroller.target = self;
	_xScroller.action = @selector(scrollerMoved:);
	_xScroller.enabled = NO;
	[right addSubview:_xScroller];

	_rightStatus = make_statusbar( NSMakeRect( 0.0, 1.0, right.bounds.size.width - 2.0, STATUSBAR_HEIGHT - 2.0 ) );
	_rightStatus.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
	[right addSubview:_rightStatus];

	[_hsplit addSubview:right];

	[_hsplit adjustSubviews];
	[_hsplit setPosition:left_width ofDividerAtIndex:0];
	[_vsplit adjustSubviews];
	[_vsplit setPosition:floor( bounds.size.height / 3.0 ) ofDividerAtIndex:0];
}


- (void)windowWillClose:(NSNotification *)notification
{
	[NSApp terminate:nil];
}


/**** Window (window.h) ****/

- (void)setAccessEnabled:(BOOL)enabled
{
	_accessEnabled = enabled;
	_backButton.enabled = enabled;
	_cdRootButton.enabled = enabled;
	_cdUpButton.enabled = enabled;
	_birdseyeButton.enabled = enabled;
	_xScroller.enabled = enabled && [self scrollerUsable:CAMERA_X_SCROLLBAR];
	_yScroller.enabled = enabled && [self scrollerUsable:CAMERA_Y_SCROLLBAR];
}


- (void)setStatus:(NSString *)message right:(BOOL)right
{
	(right ? _rightStatus : _leftStatus).stringValue = (message != nil) ? message : @"";
}


- (void)birdseyeViewOff
{
	_birdseyeButton.state = NSControlStateValueOff;
}


/**** Toolbar ****/

- (void)backClicked:(id)sender
{
	camera_look_at_previous( );
}


- (void)cdRootClicked:(id)sender
{
	if (globals.fstree != NULL)
		camera_look_at( root_dnode );
}


- (void)cdUpClicked:(id)sender
{
	if ((globals.current_node != NULL) && NODE_IS_DIR(globals.current_node->parent))
		camera_look_at( globals.current_node->parent );
}


- (void)birdseyeToggled:(NSButton *)sender
{
	camera_birdseye_view( sender.state == NSControlStateValueOn );
}


/**** Viewport scrollbars ****/

- (BOOL)scrollerUsable:(int)axis
{
	const ScrollAdjustment *adj = &_adj[axis];

	return ((adj->upper - adj->lower - adj->page_size) > (1.0e-9 * MAX(1.0, ABS(adj->upper - adj->lower))));
}


- (void)updateScrollbar:(int)axis adjustment:(const ScrollAdjustment *)adj
{
	NSScroller *scroller = (axis == CAMERA_X_SCROLLBAR) ? _xScroller : _yScroller;
	double range, span;

	_adj[axis] = *adj;
	if (getenv( "MACFSV_DEBUG" ))
		NSLog( @"scrollbar %d: lower %g upper %g value %g page %g usable %d", axis, adj->lower, adj->upper, adj->value, adj->page_size, [self scrollerUsable:axis] );
	span = adj->upper - adj->lower;
	range = span - adj->page_size;
	if ([self scrollerUsable:axis] && (span > 0.0)) {
		scroller.knobProportion = CLAMP(adj->page_size / span, 0.0, 1.0);
		scroller.doubleValue = CLAMP((adj->value - adj->lower) / range, 0.0, 1.0);
		scroller.enabled = _accessEnabled;
	}
	else {
		scroller.knobProportion = 1.0;
		scroller.doubleValue = 0.0;
		scroller.enabled = NO;
	}
}


- (void)scrollerMoved:(NSScroller *)scroller
{
	int axis = (scroller == _xScroller) ? CAMERA_X_SCROLLBAR : CAMERA_Y_SCROLLBAR;
	const ScrollAdjustment *adj = camera_scrollbar_adjustment( axis );
	double range = adj->upper - adj->lower - adj->page_size;
	double value = adj->value;

	switch (scroller.hitPart) {
		case NSScrollerKnob:
		case NSScrollerKnobSlot:
		value = adj->lower + scroller.doubleValue * range;
		break;

		case NSScrollerDecrementPage:
		value -= MAX(adj->page_increment, 0.0625 * adj->page_size);
		break;

		case NSScrollerIncrementPage:
		value += MAX(adj->page_increment, 0.0625 * adj->page_size);
		break;

		default:
		return;
	}

	_adj[axis].value = value;
	camera_scrollbar_moved( axis, value );
	/* Reflect clamping done by the camera */
	[self updateScrollbar:axis adjustment:camera_scrollbar_adjustment( axis )];
}


/**** Menu actions ****/

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
	SEL action = item.action;

	if (action == @selector(changeRoot:))
		return !_scanning && (_accessEnabled || (globals.fstree == NULL));
	if (action == @selector(visMapV:)) {
		item.state = (fsv_initial_mode( ) == FSV_MAPV) ? NSControlStateValueOn : NSControlStateValueOff;
		return YES;
	}
	if (action == @selector(visTreeV:)) {
		item.state = (fsv_initial_mode( ) == FSV_TREEV) ? NSControlStateValueOn : NSControlStateValueOff;
		return YES;
	}
	if (action == @selector(colorByNodeType:)) {
		item.state = (_colorMode == COLOR_BY_NODETYPE) ? NSControlStateValueOn : NSControlStateValueOff;
		return _accessEnabled;
	}
	if (action == @selector(colorByTimestamp:)) {
		item.state = (_colorMode == COLOR_BY_TIMESTAMP) ? NSControlStateValueOn : NSControlStateValueOff;
		return _accessEnabled;
	}
	if (action == @selector(colorByWildcards:)) {
		item.state = (_colorMode == COLOR_BY_WPATTERN) ? NSControlStateValueOn : NSControlStateValueOff;
		return _accessEnabled;
	}
	if (action == @selector(colorSetup:))
		return self.window.attachedSheet == nil;
	if (action == @selector(toggleLowResolution:)) {
		item.state = _viewport.lowResolution ? NSControlStateValueOn : NSControlStateValueOff;
		return YES;
	}

	return YES;
}


- (IBAction)changeRoot:(id)sender
{
	dialog_change_root( );
}


- (IBAction)visMapV:(id)sender
{
	if (globals.fsv_mode != FSV_MAPV)
		fsv_set_mode( FSV_MAPV );
}


- (IBAction)visTreeV:(id)sender
{
	if (globals.fsv_mode != FSV_TREEV)
		fsv_set_mode( FSV_TREEV );
}


- (IBAction)colorByNodeType:(id)sender
{
	color_set_mode( COLOR_BY_NODETYPE );
	_colorMode = COLOR_BY_NODETYPE;
}


- (IBAction)colorByTimestamp:(id)sender
{
	color_set_mode( COLOR_BY_TIMESTAMP );
	_colorMode = COLOR_BY_TIMESTAMP;
}


- (IBAction)colorByWildcards:(id)sender
{
	color_set_mode( COLOR_BY_WPATTERN );
	_colorMode = COLOR_BY_WPATTERN;
}


- (IBAction)colorSetup:(id)sender
{
	if (getenv( "MACFSV_DEBUG" ))
		NSLog( @"colorSetup:" );
	dialog_color_setup( );
}


- (IBAction)helpContents:(id)sender
{
	dialog_help( );
}


- (IBAction)aboutFsv:(id)sender
{
	about( ABOUT_BEGIN );
}


- (IBAction)toggleLowResolution:(id)sender
{
	_viewport.lowResolution = !_viewport.lowResolution;
	[[NSUserDefaults standardUserDefaults] setBool:_viewport.lowResolution forKey:@"LowResolution"];
}


/**** Pending UI updates (during scans) ****/

- (void)flushPendingUpdates
{
	FSVDirItem *last;
	NSInteger row;

	if (_treeDirty) {
		_treeDirty = NO;
		_suppressColexp = YES;
		[_dirTree reloadData];
		[self syncExpansion:_rootItems];
		_suppressColexp = NO;

		/* Like the original, follow the newest visible entry */
		if (_scanning && (_rootItems.count > 0)) {
			last = _rootItems.lastObject;
			while (last.expanded && (last.children.count > 0))
				last = last.children.lastObject;
			row = [_dirTree rowForItem:last];
			if (row >= 0) {
				_programmaticSelection = YES;
				[_dirTree selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
				_programmaticSelection = NO;
				[_dirTree scrollRowToVisible:row];
			}
		}
	}
}


/**** Directory tree (dirtree.h) ****/

static FSVDirItem *
dir_item( GNode *dnode )
{
	if ((dnode == NULL) || (NODE_DESC(dnode)->type != NODE_DIRECTORY))
		return nil;
	return (__bridge FSVDirItem *)DIR_NODE_DESC(dnode)->ctnode;
}


/* Makes the outline view reflect the items' expansion flags */
- (void)syncExpansion:(NSArray<FSVDirItem *> *)items
{
	for (FSVDirItem *item in items) {
		if (item.children.count == 0)
			continue;
		if (item.expanded) {
			if (![_dirTree isItemExpanded:item])
				[_dirTree expandItem:item];
			[self syncExpansion:item.children];
		}
		else if ([_dirTree isItemExpanded:item])
			[_dirTree collapseItem:item];
	}
}


- (void)dirTreeClear
{
	[_rootItems removeAllObjects];
	[_dirTree reloadData];
	_dirtreeCurrent = NULL;
	_treeDirty = NO;
}


- (void)dirTreeAdd:(GNode *)dnode
{
	FSVDirItem *item = [[FSVDirItem alloc] init];
	FSVDirItem *parent;
	const char *name;

	item.node = dnode;
	item.children = [NSMutableArray array];
	name = NODE_DESC(dnode)->name;
	item.name = (strlen( name ) > 0) ? FSVString( name ) : @"/. (root)";
	item.expanded = g_node_depth( dnode ) <= 2;

	parent = NULL;
	if (NODE_IS_DIR(dnode->parent))
		parent = (__bridge FSVDirItem *)DIR_NODE_DESC(dnode->parent)->ctnode;
	item.parent = parent;
	if (parent != nil)
		[parent.children addObject:item];
	else
		[_rootItems addObject:item];
	/* (ownership: the parent's children array, or _rootItems) */
	DIR_NODE_DESC(dnode)->ctnode = (__bridge void *)item;

	if ((parent == nil) || parent.expanded)
		_treeDirty = YES;
}


- (void)dirTreeNoMoreEntries
{
	_treeDirty = YES;
	[self flushPendingUpdates];
}


- (void)scrollView:(NSTableView *)table toRow:(NSInteger)row duration:(double)duration
{
	NSScrollView *scroll = table.enclosingScrollView;
	NSClipView *clip = scroll.contentView;
	NSRect row_rect, doc;
	NSPoint origin;

	if (row < 0)
		row = 0;
	if (table.numberOfRows == 0)
		return;
	row = MIN(row, table.numberOfRows - 1);

	/* Center the row */
	row_rect = [table rectOfRow:row];
	doc = table.bounds;
	origin.x = clip.bounds.origin.x;
	origin.y = NSMidY( row_rect ) - 0.5 * clip.bounds.size.height;
	origin.y = CLAMP(origin.y, 0.0, MAX(0.0, doc.size.height - clip.bounds.size.height));

	if (duration > 0.0) {
		[NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
			context.duration = duration;
			context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
			clip.animator.boundsOrigin = origin;
		} completionHandler:^{
			[scroll reflectScrolledClipView:clip];
		}];
	}
	else {
		[clip setBoundsOrigin:origin];
		[scroll reflectScrolledClipView:clip];
	}
}


- (void)dirTreeShow:(GNode *)dnode
{
	FSVDirItem *item = dir_item( dnode );
	NSInteger row;

	/* Repopulate file list if directory is different */
	if (dnode != _dirtreeCurrent)
		[self fileListPopulate:dnode];

	row = (item != nil) ? [_dirTree rowForItem:item] : -1;
	_programmaticSelection = YES;
	if (row >= 0)
		[_dirTree selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
	else
		[_dirTree deselectAll:nil];
	_programmaticSelection = NO;
	[self scrollView:_dirTree toRow:MAX(0, row) duration:DIRTREE_SCROLL_TIME];

	_dirtreeCurrent = dnode;
}


- (BOOL)dirTreeExpanded:(GNode *)dnode
{
	FSVDirItem *item = dir_item( dnode );

	return (item != nil) ? item.expanded : NO;
}


static void
set_expanded_recursive( FSVDirItem *item, BOOL expanded )
{
	item.expanded = expanded;
	for (FSVDirItem *child in item.children)
		set_expanded_recursive( child, expanded );
}


- (void)dirTreeCollapseRecursive:(GNode *)dnode
{
	FSVDirItem *item = dir_item( dnode );

	if (item == nil)
		return;
	set_expanded_recursive( item, NO );
	_suppressColexp = YES;
	[_dirTree collapseItem:item collapseChildren:YES];
	_suppressColexp = NO;
}


- (void)dirTreeExpand:(GNode *)dnode
{
	NSMutableArray<FSVDirItem *> *chain = [NSMutableArray array];
	FSVDirItem *item;

	for (item = dir_item( dnode ); item != nil; item = item.parent) {
		item.expanded = YES;
		[chain insertObject:item atIndex:0];
	}
	_suppressColexp = YES;
	for (item in chain) {
		if (![_dirTree isItemExpanded:item])
			[_dirTree expandItem:item];
	}
	/* Children keep their own expansion state */
	if (chain.lastObject != nil)
		[self syncExpansion:chain.lastObject.children];
	_suppressColexp = NO;
}


- (void)dirTreeExpandRecursive:(GNode *)dnode
{
	FSVDirItem *item = dir_item( dnode );

	if (item == nil)
		return;
	set_expanded_recursive( item, YES );
	_suppressColexp = YES;
	[_dirTree expandItem:item expandChildren:YES];
	_suppressColexp = NO;
}


/* NSOutlineViewDataSource */

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item
{
	return (item == nil) ? (NSInteger)_rootItems.count : (NSInteger)((FSVDirItem *)item).children.count;
}


- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item
{
	return (item == nil) ? _rootItems[(NSUInteger)index] : ((FSVDirItem *)item).children[(NSUInteger)index];
}


- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item
{
	return ((FSVDirItem *)item).children.count > 0;
}


/* NSOutlineViewDelegate */

static NSTableCellView *
make_cell( NSTableView *table, NSString *identifier, BOOL with_image )
{
	NSTableCellView *cell = [table makeViewWithIdentifier:identifier owner:nil];
	NSTextField *text;
	NSImageView *image;

	if (cell != nil)
		return cell;

	cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect( 0, 0, 100, 18 )];
	cell.identifier = identifier;

	text = [NSTextField labelWithString:@""];
	text.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
	text.lineBreakMode = NSLineBreakByTruncatingTail;
	text.translatesAutoresizingMaskIntoConstraints = NO;
	[cell addSubview:text];
	cell.textField = text;

	if (with_image) {
		image = [[NSImageView alloc] initWithFrame:NSMakeRect( 0, 0, 16, 16 )];
		image.imageScaling = NSImageScaleNone;
		image.translatesAutoresizingMaskIntoConstraints = NO;
		[cell addSubview:image];
		cell.imageView = image;
		[NSLayoutConstraint activateConstraints:@[
			[image.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2.0],
			[image.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
			[image.widthAnchor constraintEqualToConstant:16.0],
			[image.heightAnchor constraintEqualToConstant:16.0],
			[text.leadingAnchor constraintEqualToAnchor:image.trailingAnchor constant:4.0],
		]];
	}
	else
		[text.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2.0].active = YES;
	[NSLayoutConstraint activateConstraints:@[
		[text.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-2.0],
		[text.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
	]];

	return cell;
}


- (NSView *)outlineView:(NSOutlineView *)outlineView viewForTableColumn:(NSTableColumn *)tableColumn item:(id)item
{
	FSVDirItem *dir = item;
	NSTableCellView *cell = make_cell( outlineView, @"dircell", YES );

	cell.textField.stringValue = dir.name;
	cell.imageView.image = [outlineView isItemExpanded:item] ? _folderOpenIcon : _folderClosedIcon;

	return cell;
}


- (void)refreshFolderIcon:(FSVDirItem *)item
{
	NSInteger row = [_dirTree rowForItem:item];
	NSTableCellView *cell;

	if (row < 0)
		return;
	cell = [_dirTree viewAtColumn:0 row:row makeIfNecessary:NO];
	cell.imageView.image = [_dirTree isItemExpanded:item] ? _folderOpenIcon : _folderClosedIcon;
}


- (void)outlineViewItemDidExpand:(NSNotification *)notification
{
	FSVDirItem *item = notification.userInfo[@"NSObject"];

	[self refreshFolderIcon:item];
	if (_suppressColexp)
		return;

	item.expanded = YES;
	/* Restore the expansion state of subdirectories */
	_suppressColexp = YES;
	[self syncExpansion:item.children];
	_suppressColexp = NO;

	if ((globals.fsv_mode == FSV_SPLASH) || (globals.fsv_mode == FSV_NONE))
		return;
	colexp( item.node, COLEXP_EXPAND );
}


- (void)outlineViewItemDidCollapse:(NSNotification *)notification
{
	FSVDirItem *item = notification.userInfo[@"NSObject"];

	[self refreshFolderIcon:item];
	if (_suppressColexp)
		return;

	item.expanded = NO;
	if ((globals.fsv_mode == FSV_SPLASH) || (globals.fsv_mode == FSV_NONE))
		return;
	colexp( item.node, COLEXP_COLLAPSE_RECURSIVE );
}


- (void)outlineViewSelectionDidChange:(NSNotification *)notification
{
	/* Keyboard navigation behaves like a single click */
	if (_programmaticSelection || (NSApp.currentEvent.type != NSEventTypeKeyDown))
		return;
	[self dirTreeSelectRow:_dirTree.selectedRow];
}


- (void)dirTreeSelectRow:(NSInteger)row
{
	FSVDirItem *item;
	GNode *dnode;

	/* If About presentation is up, end it */
	about( ABOUT_END );

	if ((globals.fsv_mode == FSV_SPLASH) || (globals.fsv_mode == FSV_NONE) || (row < 0))
		return;

	item = [_dirTree itemAtRow:row];
	if (item == nil)
		return;
	dnode = item.node;

	geometry_highlight_node( dnode, FALSE );
	window_statusbar( SB_RIGHT, node_absname( dnode ) );
	if (dnode != _dirtreeCurrent)
		[self fileListPopulate:dnode];
	_dirtreeCurrent = dnode;
}


/* A single click highlights the node, shows the name, and updates the
 * file list if necessary */
- (void)dirTreeClicked:(id)sender
{
	[self dirTreeSelectRow:_dirTree.clickedRow];
}


/* A double click gets the camera moving */
- (void)dirTreeDoubleClicked:(id)sender
{
	FSVDirItem *item;

	about( ABOUT_END );
	if ((globals.fsv_mode == FSV_SPLASH) || (globals.fsv_mode == FSV_NONE) || (_dirTree.clickedRow < 0))
		return;
	item = [_dirTree itemAtRow:_dirTree.clickedRow];
	if (item != nil)
		camera_look_at( item.node );
}


/* A right click selects the row, highlights the node, shows the name,
 * updates the file list if necessary, and brings up a context menu */
- (void)dirTreeRightClickedRow:(NSInteger)row
{
	FSVDirItem *item;

	about( ABOUT_END );
	if ((globals.fsv_mode == FSV_SPLASH) || (globals.fsv_mode == FSV_NONE) || (row < 0))
		return;
	item = [_dirTree itemAtRow:row];
	if (item == nil)
		return;

	_programmaticSelection = YES;
	[_dirTree selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
	_programmaticSelection = NO;
	[self dirTreeSelectRow:row];
	context_menu( item.node );
}


/**** File list (filelist.h) ****/

- (void)setFileListColumns:(BOOL)monitor
{
	NSTableColumn *column;

	while (_fileList.tableColumns.count > 0)
		[_fileList removeTableColumn:_fileList.tableColumns.lastObject];

	if (monitor) {
		column = [[NSTableColumn alloc] initWithIdentifier:@"type"];
		column.title = @"Type";
		column.width = 110.0;
		[_fileList addTableColumn:column];
		column = [[NSTableColumn alloc] initWithIdentifier:@"found"];
		column.title = @"Found";
		column.width = 60.0;
		[_fileList addTableColumn:column];
		column = [[NSTableColumn alloc] initWithIdentifier:@"bytes"];
		column.title = @"Bytes";
		column.width = 100.0;
		[_fileList addTableColumn:column];
		if (_fileList.headerView == nil)
			_fileList.headerView = [[NSTableHeaderView alloc] init];
	}
	else {
		column = [[NSTableColumn alloc] initWithIdentifier:@"name"];
		column.resizingMask = NSTableColumnAutoresizingMask;
		column.width = _fileList.enclosingScrollView.contentSize.width;
		[_fileList addTableColumn:column];
		_fileList.headerView = nil;
	}
	_scanMonitorMode = monitor;
	[_fileList sizeLastColumnToFit];
}


- (void)fileListResetAccess
{
	BOOL enabled;

	if (_filelistCurrent == NULL)
		return;
	enabled = [self dirTreeExpanded:_filelistCurrent];
	_fileList.enabled = enabled;
	_fileList.alphaValue = enabled ? 1.0 : 0.45;
	if (!enabled)
		[_fileList deselectAll:nil];
}


static int
compare_node_names( const void *a, const void *b )
{
	GNode *na = *(GNode * const *)a, *nb = *(GNode * const *)b;

	return strcmp( NODE_DESC(na)->name, NODE_DESC(nb)->name );
}


- (void)fileListPopulate:(GNode *)dnode
{
	NSMutableArray<NSValue *> *nodes = [NSMutableArray array];
	GNode **array, *node;
	int count = 0, i;

	/* Get an alphabetized list of directory's immediate children */
	for (node = dnode->children; node != NULL; node = node->next)
		++count;
	array = malloc( (size_t)MAX(count, 1) * sizeof(GNode *) );
	for (i = 0, node = dnode->children; node != NULL; node = node->next)
		array[i++] = node;
	qsort( array, (size_t)count, sizeof(GNode *), compare_node_names );
	for (i = 0; i < count; i++)
		[nodes addObject:[NSValue valueWithPointer:array[i]]];
	free( array );

	if (_scanMonitorMode)
		[self setFileListColumns:NO];
	_fileNodes = nodes;
	[_fileList reloadData];
	[_fileList scrollRowToVisible:0];

	/* Set node count message in the left statusbar */
	if (count == 0)
		window_statusbar( SB_LEFT, "" );
	else if (count == 1)
		window_statusbar( SB_LEFT, "1 node" );
	else
		[self setStatus:[NSString stringWithFormat:@"%d nodes", count] right:NO];

	_filelistCurrent = dnode;
	[self fileListResetAccess];
}


- (void)fileListShowEntry:(GNode *)node
{
	GNode *dnode = NODE_IS_DIR(node) ? node : node->parent;
	NSInteger row = -1;
	NSUInteger i;

	if (dnode != _filelistCurrent)
		[self dirTreeShow:dnode];

	for (i = 0; i < _fileNodes.count; i++) {
		if (_fileNodes[i].pointerValue == node) {
			row = (NSInteger)i;
			break;
		}
	}
	if ((row >= 0) && _fileList.enabled)
		[_fileList selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
	else
		[_fileList deselectAll:nil];
	[self scrollView:_fileList toRow:MAX(0, row) duration:FILELIST_SCROLL_TIME];
}


- (void)fileListInit
{
	[self setFileListColumns:NO];
	[self fileListPopulate:root_dnode];
	/* Do this so that directory tree gets scrolled to the top at the
	 * end of the initial camera pan (right after filesystem scan) */
	_filelistCurrent = NULL;
}


- (void)fileListScanMonitorInit
{
	int i;

	[self setFileListColumns:YES];
	_fileNodes = nil;
	_filelistCurrent = NULL;
	_fileList.enabled = YES;
	_fileList.alphaValue = 1.0;
	[_monitorRows removeAllObjects];
	for (i = 1; i <= NUM_NODE_TYPES; i++)
		[_monitorRows addObject:@[ @"", @"" ]];
	[_fileList reloadData];
}


- (void)fileListScanMonitor:(int *)nodeCounts sizes:(int64 *)sizeCounts
{
	int64 size_total = 0;
	int node_total = 0;
	int i;

	if (!_scanMonitorMode)
		return;
	for (i = 1; i <= NUM_NODE_TYPES; i++) {
		NSString *found, *bytes;
		if (i < NUM_NODE_TYPES) {
			found = FSVString( i64toa( nodeCounts[i] ) );
			bytes = FSVString( i64toa( sizeCounts[i] ) );
			node_total += nodeCounts[i];
			size_total += sizeCounts[i];
		}
		else {
			found = FSVString( i64toa( node_total ) );
			bytes = FSVString( i64toa( size_total ) );
		}
		_monitorRows[(NSUInteger)(i - 1)] = @[ found, bytes ];
	}
	[_fileList reloadData];
}


/* NSTableViewDataSource / NSTableViewDelegate (file list) */

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
	if (_scanMonitorMode)
		return NUM_NODE_TYPES;
	return (NSInteger)_fileNodes.count;
}


- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	NSTableCellView *cell;
	NSString *ident = tableColumn.identifier;
	GNode *node;
	int type;

	if (_scanMonitorMode) {
		type = (int)row + 1;
		if ([ident isEqualToString:@"type"]) {
			cell = make_cell( tableView, @"typecell", YES );
			if (type < NUM_NODE_TYPES) {
				cell.textField.stringValue = FSVString( node_type_plural_names[type] );
				cell.imageView.image = FSVMiniIcon( (NodeType)type );
			}
			else {
				cell.textField.stringValue = @"TOTAL";
				cell.imageView.image = nil;
			}
		}
		else {
			cell = make_cell( tableView, @"numcell", NO );
			cell.textField.alignment = NSTextAlignmentRight;
			cell.textField.stringValue = _monitorRows[(NSUInteger)row][[ident isEqualToString:@"found"] ? 0 : 1];
		}
		return cell;
	}

	node = _fileNodes[(NSUInteger)row].pointerValue;
	cell = make_cell( tableView, @"filecell", YES );
	cell.textField.stringValue = FSVString( NODE_DESC(node)->name );
	cell.imageView.image = FSVMiniIcon( NODE_DESC(node)->type );

	return cell;
}


- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row
{
	return !_scanMonitorMode && _fileList.enabled;
}


- (GNode *)fileNodeAtRow:(NSInteger)row
{
	if (_scanMonitorMode || (row < 0) || (row >= (NSInteger)_fileNodes.count) || !_fileList.enabled)
		return NULL;
	return _fileNodes[(NSUInteger)row].pointerValue;
}


- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
	GNode *node;

	/* Keyboard navigation behaves like a single click */
	if (NSApp.currentEvent.type != NSEventTypeKeyDown)
		return;
	node = [self fileNodeAtRow:_fileList.selectedRow];
	if ((node == NULL) || (globals.fsv_mode == FSV_SPLASH))
		return;
	geometry_highlight_node( node, FALSE );
	window_statusbar( SB_RIGHT, node_absname( node ) );
}


/* A single click highlights the node and shows the name */
- (void)fileListClicked:(id)sender
{
	GNode *node;

	about( ABOUT_END );
	if (globals.fsv_mode == FSV_SPLASH)
		return;
	node = [self fileNodeAtRow:_fileList.clickedRow];
	if (node == NULL)
		return;
	geometry_highlight_node( node, FALSE );
	window_statusbar( SB_RIGHT, node_absname( node ) );
}


/* A double click gets the camera moving */
- (void)fileListDoubleClicked:(id)sender
{
	GNode *node;

	about( ABOUT_END );
	if (globals.fsv_mode == FSV_SPLASH)
		return;
	node = [self fileNodeAtRow:_fileList.clickedRow];
	if (node != NULL)
		camera_look_at( node );
}


/* A right click selects the row, highlights the node, shows the name,
 * and pops up a context-sensitive menu */
- (void)fileListRightClickedRow:(NSInteger)row
{
	GNode *node;

	about( ABOUT_END );
	if (globals.fsv_mode == FSV_SPLASH)
		return;
	node = [self fileNodeAtRow:row];
	if (node == NULL)
		return;
	[_fileList selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
	geometry_highlight_node( node, FALSE );
	window_statusbar( SB_RIGHT, node_absname( node ) );
	context_menu( node );
}

@end


@implementation FSVOutlineView

- (void)rightMouseDown:(NSEvent *)event
{
	NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];

	[FSVMain dirTreeRightClickedRow:[self rowAtPoint:p]];
}

- (void)mouseDown:(NSEvent *)event
{
	if (event.modifierFlags & NSEventModifierFlagControl)
		[self rightMouseDown:event];
	else
		[super mouseDown:event];
}

- (NSMenu *)menuForEvent:(NSEvent *)event
{
	return nil;
}

@end


@implementation FSVTableView

- (void)rightMouseDown:(NSEvent *)event
{
	NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];

	[FSVMain fileListRightClickedRow:[self rowAtPoint:p]];
}

- (void)mouseDown:(NSEvent *)event
{
	if (event.modifierFlags & NSEventModifierFlagControl)
		[self rightMouseDown:event];
	else
		[super mouseDown:event];
}

- (NSMenu *)menuForEvent:(NSEvent *)event
{
	return nil;
}

@end


/**** C interfaces ****************/

/* window.h */

void
window_init( FsvMode fsv_mode )
{
	/* (the main window is built by the application delegate) */
}


void
window_set_access( boolean enabled )
{
	FSVMain.accessEnabled = enabled ? YES : NO;
}


void
window_set_color_mode( ColorMode mode )
{
	FSVMain.colorMode = mode;
}


void
window_birdseye_view_off( void )
{
	[FSVMain birdseyeViewOff];
}


void
window_statusbar( StatusBarID sb_id, const char *message )
{
	[FSVMain setStatus:FSVString( message ) right:(sb_id == SB_RIGHT)];
}


/* dirtree.h */

void
dirtree_clear( void )
{
	[FSVMain dirTreeClear];
}


void
dirtree_entry_new( GNode *dnode )
{
	[FSVMain dirTreeAdd:dnode];
}


void
dirtree_no_more_entries( void )
{
	[FSVMain dirTreeNoMoreEntries];
}


void
dirtree_entry_show( GNode *dnode )
{
	[FSVMain dirTreeShow:dnode];
}


boolean
dirtree_entry_expanded( GNode *dnode )
{
	return [FSVMain dirTreeExpanded:dnode] ? TRUE : FALSE;
}


void
dirtree_entry_collapse_recursive( GNode *dnode )
{
	[FSVMain dirTreeCollapseRecursive:dnode];
}


void
dirtree_entry_expand( GNode *dnode )
{
	[FSVMain dirTreeExpand:dnode];
}


void
dirtree_entry_expand_recursive( GNode *dnode )
{
	[FSVMain dirTreeExpandRecursive:dnode];
}


/* filelist.h */

void
filelist_reset_access( void )
{
	[FSVMain fileListResetAccess];
}


void
filelist_populate( GNode *dnode )
{
	[FSVMain fileListPopulate:dnode];
}


void
filelist_show_entry( GNode *node )
{
	[FSVMain fileListShowEntry:node];
}


void
filelist_init( void )
{
	[FSVMain fileListInit];
}


void
filelist_scan_monitor_init( void )
{
	[FSVMain fileListScanMonitorInit];
}


void
filelist_scan_monitor( int *node_counts, int64 *size_counts )
{
	[FSVMain fileListScanMonitor:node_counts sizes:size_counts];
}


/* end FSVMainWindow.m */
