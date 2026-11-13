/* FSVDialogs.m */

/* Dialogs: context menu, Properties, Change root, Help (dialog.h).
 * The Color Setup dialog lives in FSVColorSetup.m */

/* mac-fsv - macOS port of fsv
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version. */


#import "FSVApp.h"


/**** Context-sensitive right-click menu ****************/

@interface FSVContextMenuTarget : NSObject
@property (nonatomic) GNode *node;
@end

@implementation FSVContextMenuTarget

- (void)collapse:(id)sender
{
	colexp( self.node, COLEXP_COLLAPSE_RECURSIVE );
}

- (void)expand:(id)sender
{
	colexp( self.node, COLEXP_EXPAND );
}

- (void)expandRecursive:(id)sender
{
	colexp( self.node, COLEXP_EXPAND_RECURSIVE );
}

- (void)lookAt:(id)sender
{
	camera_look_at( self.node );
}

- (void)properties:(id)sender
{
	dialog_node_properties( self.node );
}

@end


void
context_menu( GNode *node )
{
	static FSVContextMenuTarget *target = nil;
	NSMenu *menu;
	NSMenuItem *item;

	if (getenv( "MACFSV_DEBUG" ))
		NSLog( @"context_menu %s current=%d", node_absname( node ), node == globals.current_node );

	/* Check for the special case in which the menu has only one item */
	if (!NODE_IS_DIR(node) && (node == globals.current_node)) {
		dialog_node_properties( node );
		return;
	}

	if (target == nil)
		target = [[FSVContextMenuTarget alloc] init];
	target.node = node;

	menu = [[NSMenu alloc] initWithTitle:@""];
	menu.autoenablesItems = NO;
	if (NODE_IS_DIR(node)) {
		if (dirtree_entry_expanded( node ))
			item = [menu addItemWithTitle:@"Collapse" action:@selector(collapse:) keyEquivalent:@""];
		else {
			item = [menu addItemWithTitle:@"Expand" action:@selector(expand:) keyEquivalent:@""];
			item.target = target;
			if (DIR_NODE_DESC(node)->subtree.counts[NODE_DIRECTORY] > 0)
				item = [menu addItemWithTitle:@"Expand all" action:@selector(expandRecursive:) keyEquivalent:@""];
		}
		item.target = target;
	}
	if (node != globals.current_node) {
		item = [menu addItemWithTitle:@"Look at" action:@selector(lookAt:) keyEquivalent:@""];
		item.target = target;
	}
	item = [menu addItemWithTitle:@"Properties" action:@selector(properties:) keyEquivalent:@""];
	item.target = target;

	[menu popUpMenuPositioningItem:nil atLocation:[NSEvent mouseLocation] inView:nil];
}


/**** File -> Change root... ****************/

void
dialog_change_root( void )
{
	NSOpenPanel *panel;
	NSString *start;

	if (FSVMain.scanning)
		return;

	panel = [NSOpenPanel openPanel];
	panel.title = @"Change Root Directory";
	panel.message = @"Choose the directory to visualize";
	panel.prompt = @"Visualize";
	panel.canChooseDirectories = YES;
	panel.canChooseFiles = NO;
	panel.allowsMultipleSelection = NO;
	panel.treatsFilePackagesAsDirectories = YES;
	if (globals.fstree != NULL)
		start = FSVString( node_absname( root_dnode ) );
	else
		start = [[NSUserDefaults standardUserDefaults] stringForKey:@"LastRoot"];
	if (start == nil)
		start = NSHomeDirectory( );
	panel.directoryURL = [NSURL fileURLWithPath:start isDirectory:YES];

	[panel beginSheetModalForWindow:FSVMain.window completionHandler:^(NSModalResponse result) {
		if (result != NSModalResponseOK)
			return;
		NSString *path = panel.URL.path;
		/* Let the sheet go away before the (long) scan begins */
		dispatch_async( dispatch_get_main_queue( ), ^{
			FSVLoadRoot( path );
		} );
	}];
}


/**** Help -> Contents... ****************/

void
dialog_help( void )
{
	NSURL *url = [[NSBundle mainBundle] URLForResource:@"fsv" withExtension:@"html" subdirectory:@"doc"];

	if (url == nil) {
		NSBeep( );
		return;
	}
	[[NSWorkspace sharedWorkspace] openURL:url];
}


/**** Properties dialog ****************/

static NSTextField *
label( NSString *text, BOOL bold, NSTextAlignment alignment )
{
	NSTextField *field = [NSTextField wrappingLabelWithString:(text != nil) ? text : @""];

	field.font = bold ? [NSFont boldSystemFontOfSize:[NSFont systemFontSize]] : [NSFont systemFontOfSize:[NSFont systemFontSize]];
	field.alignment = alignment;
	field.selectable = YES;
	field.preferredMaxLayoutWidth = 320.0;

	return field;
}


static NSTextField *
read_only_entry( NSString *text )
{
	NSTextField *field = [NSTextField textFieldWithString:(text != nil) ? text : @""];

	field.editable = NO;
	field.selectable = YES;
	field.lineBreakMode = NSLineBreakByTruncatingMiddle;
	[field.widthAnchor constraintGreaterThanOrEqualToConstant:340.0].active = YES;

	return field;
}


static NSBox *
separator( void )
{
	NSBox *box = [[NSBox alloc] init];

	box.boxType = NSBoxSeparator;

	return box;
}


static NSString *
size_text( const char *bytes, const char *abbr, int64 size )
{
	NSString *s = [NSString stringWithFormat:@"%s bytes", bytes];

	if (size >= 1024)
		s = [s stringByAppendingFormat:@" (%s)", abbr];

	return s;
}


@interface FSVPropertiesSheet : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSWindow *sheet;
@property (nonatomic) GNode *node;
@property (nonatomic) GNode *targetNode;
@end

static FSVPropertiesSheet *properties_sheet = nil;

@implementation FSVPropertiesSheet

- (NSView *)tabWithViews:(NSArray<NSView *> *)views
{
	NSStackView *stack = [NSStackView stackViewWithViews:views];

	stack.orientation = NSUserInterfaceLayoutOrientationVertical;
	stack.alignment = NSLayoutAttributeLeading;
	stack.spacing = 10.0;
	stack.edgeInsets = NSEdgeInsetsMake( 14.0, 16.0, 14.0, 16.0 );

	return stack;
}


- (NSView *)generalPage:(const struct NodeInfo *)info
{
	GNode *node = self.node;
	NSImageView *icon;
	NSGridView *grid;
	NSMutableArray<NSArray<NSView *> *> *rows = [NSMutableArray array];
	NSInteger r;

	icon = [NSImageView imageViewWithImage:FSVIcon( NODE_DESC(node)->type )];
	icon.imageScaling = NSImageScaleNone;
	[rows addObject:@[ icon, label( FSVString( info->name ), YES, NSTextAlignmentLeft ) ]];
	[rows addObject:@[ separator( ), [NSGridCell emptyContentView] ]];
	[rows addObject:@[ label( @"Type:", NO, NSTextAlignmentRight ), label( FSVString( node_type_names[NODE_DESC(node)->type] ), NO, NSTextAlignmentLeft ) ]];
	[rows addObject:@[ label( @"Location:", NO, NSTextAlignmentRight ), label( FSVString( info->prefix ), NO, NSTextAlignmentLeft ) ]];
	if (NODE_IS_DIR(node))
		[rows addObject:@[ label( @"Total size:", NO, NSTextAlignmentRight ), label( size_text( info->subtree_size, info->subtree_size_abbr, DIR_NODE_DESC(node)->subtree.size ), NO, NSTextAlignmentLeft ) ]];
	else {
		[rows addObject:@[ label( @"Size:", NO, NSTextAlignmentRight ), label( size_text( info->size, info->size_abbr, NODE_DESC(node)->size ), NO, NSTextAlignmentLeft ) ]];
		[rows addObject:@[ label( @"Allocation:", NO, NSTextAlignmentRight ), label( [NSString stringWithFormat:@"%s bytes", info->size_alloc], NO, NSTextAlignmentLeft ) ]];
	}
	[rows addObject:@[ label( @"Owner:", NO, NSTextAlignmentRight ), label( [NSString stringWithFormat:@"%@ (uid %u)", FSVString( info->user_name ), (unsigned int)NODE_DESC(node)->user_id], NO, NSTextAlignmentLeft ) ]];
	[rows addObject:@[ label( @"Group:", NO, NSTextAlignmentRight ), label( [NSString stringWithFormat:@"%@ (gid %u)", FSVString( info->group_name ), (unsigned int)NODE_DESC(node)->group_id], NO, NSTextAlignmentLeft ) ]];
	[rows addObject:@[ separator( ), [NSGridCell emptyContentView] ]];
	[rows addObject:@[ label( @"Modified:", NO, NSTextAlignmentRight ), label( FSVString( info->mtime ), NO, NSTextAlignmentLeft ) ]];
	[rows addObject:@[ label( @"AttribCh:", NO, NSTextAlignmentRight ), label( FSVString( info->ctime ), NO, NSTextAlignmentLeft ) ]];
	[rows addObject:@[ label( @"Accessed:", NO, NSTextAlignmentRight ), label( FSVString( info->atime ), NO, NSTextAlignmentLeft ) ]];

	grid = [NSGridView gridViewWithViews:rows];
	grid.rowSpacing = 6.0;
	grid.columnSpacing = 10.0;
	[grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
	for (r = 0; r < grid.numberOfRows; r++) {
		NSGridCell *cell = [grid cellAtColumnIndex:0 rowIndex:r];
		if ([cell.contentView isKindOfClass:[NSBox class]]) {
			[grid mergeCellsInHorizontalRange:NSMakeRange( 0, 2 ) verticalRange:NSMakeRange( (NSUInteger)r, 1 )];
			cell.xPlacement = NSGridCellPlacementFill;
		}
	}
	[grid cellAtColumnIndex:0 rowIndex:0].xPlacement = NSGridCellPlacementTrailing;

	return [self tabWithViews:@[ grid ]];
}


/* "This directory contains:" table */
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
	return NUM_NODE_TYPES - 1;
}


- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
	int type = (int)row + 1;
	NSTableCellView *cell = [[NSTableCellView alloc] init];
	NSTextField *text = [NSTextField labelWithString:@""];
	NSImageView *image;

	text.translatesAutoresizingMaskIntoConstraints = NO;
	[cell addSubview:text];
	cell.textField = text;
	if ([column.identifier isEqualToString:@"type"]) {
		image = [NSImageView imageViewWithImage:FSVMiniIcon( (NodeType)type )];
		image.translatesAutoresizingMaskIntoConstraints = NO;
		[cell addSubview:image];
		text.stringValue = FSVString( node_type_plural_names[type] );
		[NSLayoutConstraint activateConstraints:@[
			[image.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2.0],
			[image.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
			[text.leadingAnchor constraintEqualToAnchor:image.trailingAnchor constant:4.0],
			[text.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
		]];
	}
	else {
		text.stringValue = FSVString( i64toa( DIR_NODE_DESC(self.node)->subtree.counts[type] ) );
		text.alignment = NSTextAlignmentRight;
		[NSLayoutConstraint activateConstraints:@[
			[text.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4.0],
			[text.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
		]];
	}

	return cell;
}


- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row
{
	return NO;
}


- (NSView *)contentsPage:(const struct NodeInfo *)info
{
	NSTableView *table = [[NSTableView alloc] init];
	NSTableColumn *column;
	NSScrollView *scroll;

	column = [[NSTableColumn alloc] initWithIdentifier:@"type"];
	column.title = @"Node type";
	column.width = 150.0;
	[table addTableColumn:column];
	column = [[NSTableColumn alloc] initWithIdentifier:@"qty"];
	column.title = @"Quantity";
	column.width = 90.0;
	[table addTableColumn:column];
	table.rowHeight = 18.0;
	table.style = NSTableViewStylePlain;
	table.usesAlternatingRowBackgroundColors = YES;
	table.gridStyleMask = NSTableViewSolidVerticalGridLineMask;
	table.dataSource = self;
	table.delegate = self;

	scroll = [[NSScrollView alloc] init];
	scroll.documentView = table;
	scroll.borderType = NSBezelBorder;
	scroll.hasVerticalScroller = NO;
	[scroll.widthAnchor constraintEqualToConstant:260.0].active = YES;
	[scroll.heightAnchor constraintEqualToConstant:(NUM_NODE_TYPES - 1) * 20.0 + 28.0].active = YES;

	return [self tabWithViews:@[ label( @"This directory contains:", NO, NSTextAlignmentLeft ), scroll, separator( ), label( size_text( info->subtree_size, info->subtree_size_abbr, DIR_NODE_DESC(self.node)->subtree.size ), NO, NSTextAlignmentLeft ) ]];
}


- (NSView *)fileTypePage:(const struct NodeInfo *)info
{
	NSScrollView *scroll = [NSTextView scrollableTextView];
	NSTextView *text = scroll.documentView;

	text.editable = NO;
	text.string = FSVString( info->file_type_desc );
	text.font = [NSFont userFixedPitchFontOfSize:[NSFont smallSystemFontSize]];
	scroll.borderType = NSBezelBorder;
	[scroll.widthAnchor constraintEqualToConstant:360.0].active = YES;
	[scroll.heightAnchor constraintEqualToConstant:90.0].active = YES;

	return [self tabWithViews:@[ label( @"This file is recognized as:", NO, NSTextAlignmentLeft ), scroll ]];
}


- (NSView *)targetPage:(const struct NodeInfo *)info
{
	NSButton *button;
	NSString *abs;
	GNode *target;

	if (!strcmp( info->target, info->abstarget ))
		abs = @"(same as above)";
	else
		abs = FSVString( info->abstarget );

	/* This is NULL if target isn't in the filesystem tree */
	target = node_named( info->abstarget );

	/* The "Look at target node" feature does not work in TreeV mode if
	 * directories have to be expanded to see the target node, because
	 * unbuilt TreeV geometry does not have a definite location */
	if ((globals.fsv_mode == FSV_TREEV) && (target != NULL))
		if (NODE_IS_DIR(target->parent))
			if (!dirtree_entry_expanded( target->parent ))
				target = NULL;
	self.targetNode = target;

	button = [NSButton buttonWithTitle:@"Look at target node" target:self action:@selector(lookAtTarget:)];
	button.enabled = target != NULL;

	return [self tabWithViews:@[ label( @"This symlink points to:", NO, NSTextAlignmentLeft ), read_only_entry( FSVString( info->target ) ), label( @"Absolute name of target:", NO, NSTextAlignmentLeft ), read_only_entry( abs ), button ]];
}


- (void)lookAtTarget:(id)sender
{
	GNode *node = self.targetNode;

	[self close:nil];
	if (node == NULL)
		return;

	/* Target node may be buried inside a collapsed tree--
	 * if it is, expand it out into the open */
	if (NODE_IS_DIR(node->parent))
		if (!dirtree_entry_expanded( node->parent ))
			colexp( node->parent, COLEXP_EXPAND_ANY );

	camera_look_at( node );
}


- (void)close:(id)sender
{
	[FSVMain.window endSheet:self.sheet];
}


- (void)showForNode:(GNode *)node
{
	const struct NodeInfo *info;
	NSTabView *tabs;
	NSTabViewItem *tab;
	NSButton *close;
	NSStackView *main;
	NSView *view;

	self.node = node;

	/* Get the lowdown on the node */
	info = get_node_info( node );

	tabs = [[NSTabView alloc] init];
	tab = [[NSTabViewItem alloc] initWithIdentifier:@"general"];
	tab.label = @"General";
	tab.view = [self generalPage:info];
	[tabs addTabViewItem:tab];

	/* Node-type-specific information pages */
	view = nil;
	switch (NODE_DESC(node)->type) {
		case NODE_DIRECTORY:
		view = [self contentsPage:info];
		tab = [[NSTabViewItem alloc] initWithIdentifier:@"contents"];
		tab.label = @"Contents";
		break;

		case NODE_REGFILE:
		view = [self fileTypePage:info];
		tab = [[NSTabViewItem alloc] initWithIdentifier:@"filetype"];
		tab.label = @"File type";
		break;

		case NODE_SYMLINK:
		view = [self targetPage:info];
		tab = [[NSTabViewItem alloc] initWithIdentifier:@"target"];
		tab.label = @"Target";
		break;

		default:
		/* No additional information for this node type */
		break;
	}
	if (view != nil) {
		tab.view = view;
		[tabs addTabViewItem:tab];
	}

	close = [NSButton buttonWithTitle:@"Close" target:self action:@selector(close:)];
	close.keyEquivalent = @"\r";

	main = [NSStackView stackViewWithViews:@[ tabs, close ]];
	main.orientation = NSUserInterfaceLayoutOrientationVertical;
	main.alignment = NSLayoutAttributeCenterX;
	main.spacing = 12.0;
	main.edgeInsets = NSEdgeInsetsMake( 16.0, 16.0, 16.0, 16.0 );
	[tabs.widthAnchor constraintGreaterThanOrEqualToConstant:440.0].active = YES;

	self.sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect( 0, 0, 480, 420 ) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
	self.sheet.title = @"Properties";
	self.sheet.contentView = main;
	self.sheet.appearance = FSVMain.window.appearance;
	[self.sheet setContentSize:main.fittingSize];

	[FSVMain.window beginSheet:self.sheet completionHandler:^(NSModalResponse response) {
		properties_sheet = nil;
	}];
}

@end


void
dialog_node_properties( GNode *node )
{
	if ((properties_sheet != nil) || (FSVMain.window.attachedSheet != nil))
		return;

	properties_sheet = [[FSVPropertiesSheet alloc] init];
	[properties_sheet showForNode:node];
}


/* end FSVDialogs.m */
