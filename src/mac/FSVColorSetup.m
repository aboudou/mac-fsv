/* FSVColorSetup.m */

/* Colors -> Setup... dialog (formerly in dialog.c) */

/* mac-fsv - macOS port of fsv
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version. */


#import "FSVApp.h"

#include "xmaps/button_ok.xpm"
#include "xmaps/button_cancel.xpm"


#define WPROW_PASTEBOARD_TYPE	@"io.github.mac-fsv.wprow"


/* Types of rows in the wildcard pattern list */
enum {
	WPLIST_HEADER_ROW,
	WPLIST_WPATTERN_ROW,
	WPLIST_NEW_WPATTERN_ROW,
	WPLIST_DEFAULT_HEADER_ROW,
	WPLIST_DEFAULT_ROW
};


@interface FSVWPRow : NSObject
@property (nonatomic) int rowType;
@property (nonatomic) struct WPatternGroup *wpgroup;
@property (nonatomic) char *wpattern;
@end

@implementation FSVWPRow
@end


/* Draws a solid color (wildcard list color bars) */
@interface FSVSwatchView : NSView
@property (nonatomic, strong) NSColor *color;
@end

@implementation FSVSwatchView

- (void)drawRect:(NSRect)rect
{
	[(self.color != nil) ? self.color : [NSColor clearColor] setFill];
	NSRectFill( self.bounds );
}

@end


/* Spectrum preview for the "By date/time" page */
@interface FSVSpectrumView : NSView
@property (nonatomic) struct ColorConfig *config;
@end

@implementation FSVSpectrumView

- (void)drawRect:(NSRect)rect
{
	struct ColorConfig *ccfg = self.config;
	RGBcolor *boundary_colors[2];
	RGBcolor color;
	void *data = NULL;
	NSInteger x, width = (NSInteger)self.bounds.size.width;

	if (ccfg == NULL)
		return;
	if (ccfg->by_timestamp.spectrum_type == SPECTRUM_GRADIENT) {
		boundary_colors[0] = &ccfg->by_timestamp.old_color;
		boundary_colors[1] = &ccfg->by_timestamp.new_color;
		data = boundary_colors;
	}

	for (x = 0; x < width; x++) {
		color = color_spectrum_color( ccfg->by_timestamp.spectrum_type, (double)x / (double)MAX(1, width - 1), data );
		[FSVColorFromRGB( &color ) setFill];
		NSRectFill( NSMakeRect( (CGFloat)x, 0.0, 1.0, self.bounds.size.height ) );
	}
}

@end


@interface FSVColorSetup : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@end

static FSVColorSetup *color_setup = nil;


@implementation FSVColorSetup {
	/* Scratch copy of color configuration */
	struct ColorConfig _ccfg;
	NSWindow *_sheet;
	NSTabView *_tabs;

	/* Date/time page */
	NSDatePicker *_oldDate;
	NSDatePicker *_newDate;
	NSPopUpButton *_timestampMenu;
	NSPopUpButton *_spectrumMenu;
	FSVSpectrumView *_spectrum;
	NSColorWell *_oldColorWell;
	NSColorWell *_newColorWell;

	/* Wildcard page */
	NSTableView *_wpTable;
	NSMutableArray<FSVWPRow *> *_wpRows;
	NSButton *_newColorButton;
	NSButton *_editPatternButton;
	NSButton *_deleteButton;
}


- (void)dealloc
{
	color_config_destroy( &_ccfg );
}


/**** "By node type" page ****/

- (void)nodeTypeColorChanged:(NSColorWell *)well
{
	_ccfg.by_nodetype.colors[well.tag] = FSVRGBFromColor( well.color );
}


- (NSView *)nodeTypePage
{
	NSMutableArray<NSArray<NSView *> *> *rows = [NSMutableArray array];
	NSMutableArray<NSView *> *cells = [NSMutableArray array];
	NSGridView *grid;
	NSStackView *page;
	int i;

	/* Two-column listing of node type colors */
	for (i = 1; i < NUM_NODE_TYPES; i++) {
		NSColorWell *well = [NSColorWell colorWellWithStyle:NSColorWellStyleDefault];
		NSImageView *icon = [NSImageView imageViewWithImage:FSVIcon( (NodeType)i )];
		NSTextField *text = [NSTextField labelWithString:FSVString( node_type_names[i] )];
		NSStackView *cell;

		well.color = FSVColorFromRGB( &_ccfg.by_nodetype.colors[i] );
		well.tag = i;
		well.target = self;
		well.action = @selector(nodeTypeColorChanged:);
		[well.widthAnchor constraintEqualToConstant:44.0].active = YES;
		icon.imageScaling = NSImageScaleNone;
		[icon.widthAnchor constraintEqualToConstant:32.0].active = YES;
		[icon.heightAnchor constraintEqualToConstant:32.0].active = YES;

		cell = [NSStackView stackViewWithViews:@[ well, icon, text ]];
		cell.spacing = 10.0;
		[cells addObject:cell];
		if (cells.count == 2) {
			[rows addObject:[cells copy]];
			[cells removeAllObjects];
		}
	}
	if (cells.count > 0) {
		[cells addObject:[NSGridCell emptyContentView]];
		[rows addObject:cells];
	}

	grid = [NSGridView gridViewWithViews:rows];
	grid.rowSpacing = 14.0;
	grid.columnSpacing = 40.0;
	[grid columnAtIndex:0].width = 220.0;
	[grid columnAtIndex:1].width = 220.0;

	page = [[NSStackView alloc] init];
	page.orientation = NSUserInterfaceLayoutOrientationVertical;
	page.edgeInsets = NSEdgeInsetsMake( 20.0, 20.0, 20.0, 20.0 );
	[page addView:grid inGravity:NSStackViewGravityTop];

	return page;
}


/**** "By date/time" page ****/

- (void)timeEdited:(NSDatePicker *)picker
{
	time_t old_time, new_time, cur_time;

	old_time = (time_t)_oldDate.dateValue.timeIntervalSince1970;
	new_time = (time_t)_newDate.dateValue.timeIntervalSince1970;
	cur_time = time( NULL );

	/* Check that neither time is in the future */
	if (difftime( cur_time, new_time ) < 0.0)
		new_time = cur_time;
	if (difftime( cur_time, old_time ) < 0.0)
		old_time = cur_time;

	/* Check that old time is at least one minute before new time */
	if (difftime( new_time, old_time ) < 60.0) {
		if (picker == _oldDate)
			new_time = old_time + (time_t)60;
		else
			old_time = new_time - (time_t)60;
	}

	_oldDate.dateValue = [NSDate dateWithTimeIntervalSince1970:old_time];
	_newDate.dateValue = [NSDate dateWithTimeIntervalSince1970:new_time];
	_ccfg.by_timestamp.old_time = old_time;
	_ccfg.by_timestamp.new_time = new_time;
}


- (void)timestampTypeChanged:(NSPopUpButton *)popup
{
	_ccfg.by_timestamp.timestamp_type = (TimeStampType)popup.indexOfSelectedItem;
}


/* Color pickers are accessible only for gradient spectrums */
- (void)updateGradientWells
{
	BOOL enabled = _ccfg.by_timestamp.spectrum_type == SPECTRUM_GRADIENT;

	_oldColorWell.enabled = enabled;
	_newColorWell.enabled = enabled;
	/* Change the color pickers' colors, as simply enabling/disabling
	 * them isn't enough to make the state change obvious */
	if (enabled) {
		_oldColorWell.color = FSVColorFromRGB( &_ccfg.by_timestamp.old_color );
		_newColorWell.color = FSVColorFromRGB( &_ccfg.by_timestamp.new_color );
	}
	else {
		[_oldColorWell deactivate];
		[_newColorWell deactivate];
		_oldColorWell.color = [NSColor windowBackgroundColor];
		_newColorWell.color = [NSColor windowBackgroundColor];
	}
}


- (void)spectrumTypeChanged:(NSPopUpButton *)popup
{
	_ccfg.by_timestamp.spectrum_type = (SpectrumType)popup.indexOfSelectedItem;
	[self updateGradientWells];
	_spectrum.needsDisplay = YES;
}


- (void)gradientColorChanged:(NSColorWell *)well
{
	if (_ccfg.by_timestamp.spectrum_type != SPECTRUM_GRADIENT)
		return;
	if (well == _oldColorWell)
		_ccfg.by_timestamp.old_color = FSVRGBFromColor( well.color );
	else
		_ccfg.by_timestamp.new_color = FSVRGBFromColor( well.color );
	_spectrum.needsDisplay = YES;
}


- (NSDatePicker *)datePicker:(time_t)t
{
	NSDatePicker *picker = [[NSDatePicker alloc] init];

	picker.datePickerStyle = NSDatePickerStyleTextFieldAndStepper;
	picker.datePickerElements = NSDatePickerElementFlagYearMonthDay | NSDatePickerElementFlagHourMinuteSecond;
	picker.dateValue = [NSDate dateWithTimeIntervalSince1970:t];
	picker.target = self;
	picker.action = @selector(timeEdited:);

	return picker;
}


- (NSView *)timePage
{
	NSGridView *grid;
	NSStackView *page, *bottom;
	NSBox *frame;

	_oldDate = [self datePicker:_ccfg.by_timestamp.old_time];
	_newDate = [self datePicker:_ccfg.by_timestamp.new_time];

	_timestampMenu = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	[_timestampMenu addItemsWithTitles:@[ @"Time of last access", @"Time of last modification", @"Time of last attribute change" ]];
	[_timestampMenu selectItemAtIndex:_ccfg.by_timestamp.timestamp_type];
	_timestampMenu.target = self;
	_timestampMenu.action = @selector(timestampTypeChanged:);

	grid = [NSGridView gridViewWithViews:@[
		@[ [NSTextField labelWithString:@"Oldest:"], _oldDate ],
		@[ [NSTextField labelWithString:@"Newest:"], _newDate ],
		@[ [NSTextField labelWithString:@"Color by:"], _timestampMenu ],
	]];
	grid.rowSpacing = 8.0;
	grid.columnSpacing = 8.0;
	[grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
	grid.rowAlignment = NSGridRowAlignmentFirstBaseline;

	/* Time spectrum */
	_spectrum = [[FSVSpectrumView alloc] init];
	_spectrum.config = &_ccfg;
	[_spectrum.heightAnchor constraintEqualToConstant:24.0].active = YES;
	frame = [[NSBox alloc] init];
	frame.titlePosition = NSNoTitle;
	frame.boxType = NSBoxCustom;
	frame.borderColor = [NSColor grayColor];
	frame.borderWidth = 1.0;
	frame.contentViewMargins = NSMakeSize( 1.0, 1.0 );
	frame.contentView = _spectrum;
	[frame.widthAnchor constraintEqualToConstant:440.0].active = YES;

	/* Spectrum color pickers and menu */
	_oldColorWell = [NSColorWell colorWellWithStyle:NSColorWellStyleDefault];
	_oldColorWell.target = self;
	_oldColorWell.action = @selector(gradientColorChanged:);
	[_oldColorWell.widthAnchor constraintEqualToConstant:44.0].active = YES;
	_newColorWell = [NSColorWell colorWellWithStyle:NSColorWellStyleDefault];
	_newColorWell.target = self;
	_newColorWell.action = @selector(gradientColorChanged:);
	[_newColorWell.widthAnchor constraintEqualToConstant:44.0].active = YES;

	_spectrumMenu = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	[_spectrumMenu addItemsWithTitles:@[ @"Rainbow", @"Heat", @"Gradient" ]];
	[_spectrumMenu selectItemAtIndex:_ccfg.by_timestamp.spectrum_type];
	_spectrumMenu.target = self;
	_spectrumMenu.action = @selector(spectrumTypeChanged:);

	bottom = [NSStackView stackViewWithViews:@[ _oldColorWell, [NSTextField labelWithString:@"Older"], _spectrumMenu, [NSTextField labelWithString:@"Newer"], _newColorWell ]];
	bottom.distribution = NSStackViewDistributionEqualCentering;
	[bottom.widthAnchor constraintEqualToConstant:440.0].active = YES;
	[self updateGradientWells];

	page = [[NSStackView alloc] init];
	page.orientation = NSUserInterfaceLayoutOrientationVertical;
	page.spacing = 14.0;
	page.edgeInsets = NSEdgeInsetsMake( 14.0, 14.0, 14.0, 14.0 );
	[page addView:grid inGravity:NSStackViewGravityTop];
	[page addView:frame inGravity:NSStackViewGravityTop];
	[page addView:bottom inGravity:NSStackViewGravityTop];

	return page;
}


/**** "By wildcards" page ****/

- (void)addRow:(int)type group:(struct WPatternGroup *)wpgroup pattern:(char *)wpattern
{
	FSVWPRow *row = [[FSVWPRow alloc] init];

	row.rowType = type;
	row.wpgroup = wpgroup;
	row.wpattern = wpattern;
	[_wpRows addObject:row];
}


/* Updates the wildcard pattern list with the scratch configuration */
- (void)populateWildcards
{
	struct WPatternGroup *wpgroup;
	GList *wpgroup_llink, *wp_llink;

	[_wpRows removeAllObjects];

	/* Iterate through all the wildcard pattern color groups */
	for (wpgroup_llink = _ccfg.by_wpattern.wpgroup_list; wpgroup_llink != NULL; wpgroup_llink = wpgroup_llink->next) {
		wpgroup = (struct WPatternGroup *)wpgroup_llink->data;
		[self addRow:WPLIST_HEADER_ROW group:wpgroup pattern:NULL];
		for (wp_llink = wpgroup->wp_list; wp_llink != NULL; wp_llink = wp_llink->next)
			[self addRow:WPLIST_WPATTERN_ROW group:wpgroup pattern:(char *)wp_llink->data];
		/* A "New pattern" row for adding new patterns to this group */
		[self addRow:WPLIST_NEW_WPATTERN_ROW group:wpgroup pattern:NULL];
	}

	/* Default color */
	[self addRow:WPLIST_DEFAULT_HEADER_ROW group:NULL pattern:NULL];
	[self addRow:WPLIST_DEFAULT_ROW group:NULL pattern:NULL];

	[_wpTable reloadData];
	[self updateWildcardButtons];
}


- (RGBcolor *)colorOfRow:(FSVWPRow *)row
{
	if (row.wpgroup != NULL)
		return &row.wpgroup->color;
	return &_ccfg.by_wpattern.default_color;
}


- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
	return (NSInteger)_wpRows.count;
}


- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)index
{
	FSVWPRow *row = _wpRows[(NSUInteger)index];
	BOOL header = (row.rowType == WPLIST_HEADER_ROW) || (row.rowType == WPLIST_DEFAULT_HEADER_ROW);
	NSTableCellView *cell;
	NSTextField *text;
	FSVSwatchView *swatch;

	if ([column.identifier isEqualToString:@"color"]) {
		if (header) {
			/* Clicking a group's color bar changes the color */
			NSColorWell *well = [NSColorWell colorWellWithStyle:NSColorWellStyleMinimal];
			well.color = FSVColorFromRGB( [self colorOfRow:row] );
			well.target = self;
			well.action = @selector(groupColorChanged:);
			well.toolTip = (row.rowType == WPLIST_HEADER_ROW) ? @"Group color" : @"Default color";
			return well;
		}
		swatch = [[FSVSwatchView alloc] init];
		swatch.color = FSVColorFromRGB( [self colorOfRow:row] );
		return swatch;
	}

	if (header) {
		swatch = [[FSVSwatchView alloc] init];
		swatch.color = FSVColorFromRGB( [self colorOfRow:row] );
		return swatch;
	}

	cell = [[NSTableCellView alloc] init];
	text = [NSTextField labelWithString:@""];
	text.translatesAutoresizingMaskIntoConstraints = NO;
	[cell addSubview:text];
	cell.textField = text;
	[NSLayoutConstraint activateConstraints:@[
		[text.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4.0],
		[text.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4.0],
		[text.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
	]];
	switch (row.rowType) {
		case WPLIST_WPATTERN_ROW:
		text.stringValue = FSVString( row.wpattern );
		break;

		case WPLIST_NEW_WPATTERN_ROW:
		text.stringValue = @"(New pattern)";
		text.textColor = [NSColor secondaryLabelColor];
		break;

		default:
		text.stringValue = @"(Default color)";
		text.textColor = [NSColor secondaryLabelColor];
		break;
	}

	return cell;
}


- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)index
{
	FSVWPRow *row = _wpRows[(NSUInteger)index];

	return (row.rowType != WPLIST_HEADER_ROW) && (row.rowType != WPLIST_DEFAULT_HEADER_ROW);
}


- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
	[self updateWildcardButtons];
}


- (void)updateWildcardButtons
{
	FSVWPRow *row = nil;
	BOOL newwp_row = NO, defcolor_row = NO, empty_wpgroup = NO, row_selected;

	row_selected = _wpTable.selectedRow >= 0;
	if (row_selected) {
		row = _wpRows[(NSUInteger)_wpTable.selectedRow];
		newwp_row = row.rowType == WPLIST_NEW_WPATTERN_ROW;
		defcolor_row = (row.rowType == WPLIST_DEFAULT_ROW) || (row.rowType == WPLIST_DEFAULT_HEADER_ROW);
		if (!defcolor_row)
			empty_wpgroup = row.wpgroup->wp_list == NULL;
	}

	/* Decide which actions are allowable */
	_newColorButton.enabled = !row_selected || !defcolor_row;
	_editPatternButton.enabled = row_selected && !defcolor_row;
	_deleteButton.enabled = row_selected && !defcolor_row && (!newwp_row || empty_wpgroup);
}


- (void)groupColorChanged:(NSColorWell *)well
{
	NSInteger index = [_wpTable rowForView:well];
	NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
	FSVWPRow *row;
	RGBcolor *color;
	NSUInteger i;

	if (index < 0)
		return;
	row = _wpRows[(NSUInteger)index];
	color = [self colorOfRow:row];
	*color = FSVRGBFromColor( well.color );

	/* Refresh the color bars of the group (but not the well itself,
	 * which is being edited) */
	for (i = 0; i < _wpRows.count; i++) {
		if ([self colorOfRow:_wpRows[i]] == color)
			[rows addIndex:i];
	}
	[_wpTable reloadDataForRowIndexes:rows columnIndexes:[NSIndexSet indexSetWithIndex:1]];
	[rows removeIndex:(NSUInteger)index];
	[_wpTable reloadDataForRowIndexes:rows columnIndexes:[NSIndexSet indexSetWithIndex:0]];
}


- (FSVWPRow *)selectedRow
{
	if (_wpTable.selectedRow < 0)
		return nil;
	return _wpRows[(NSUInteger)_wpTable.selectedRow];
}


- (void)newColor:(id)sender
{
	struct WPatternGroup *wpgroup;
	RGBcolor default_new_color = { 0.0, 0.0, 0.75 }; /* I like blue */
	FSVWPRow *row = [self selectedRow];
	NSUInteger i;

	/* Create new group */
	wpgroup = NEW(struct WPatternGroup);
	wpgroup->color = ((row != nil) && (row.wpgroup != NULL)) ? row.wpgroup->color : default_new_color;
	wpgroup->wp_list = NULL;

	/* If a row in an existing group was selected, the new group goes
	 * immediately before it */
	if ((row != nil) && (row.wpgroup != NULL))
		G_LIST_INSERT_BEFORE(_ccfg.by_wpattern.wpgroup_list, row.wpgroup, wpgroup);
	else
		G_LIST_APPEND(_ccfg.by_wpattern.wpgroup_list, wpgroup);

	[self populateWildcards];

	/* Select the new group's "New pattern" row, and bring up the color
	 * panel for the group */
	for (i = 0; i < _wpRows.count; i++) {
		if ((_wpRows[i].wpgroup == wpgroup) && (_wpRows[i].rowType == WPLIST_HEADER_ROW)) {
			[_wpTable selectRowIndexes:[NSIndexSet indexSetWithIndex:i + 1] byExtendingSelection:NO];
			[_wpTable scrollRowToVisible:(NSInteger)i + 1];
			NSView *well = [_wpTable viewAtColumn:0 row:(NSInteger)i makeIfNecessary:YES];
			if ([well isKindOfClass:[NSColorWell class]])
				[(NSColorWell *)well activate:YES];
			break;
		}
	}
}


- (void)applyPattern:(NSString *)input toRow:(FSVWPRow *)row
{
	char *wpattern;
	GList *l;

	/* Trim leading/trailing whitespace in input */
	wpattern = xstrstrip( xstrdup( input.UTF8String ) );

	if (strlen( wpattern ) == 0) {
		/* Ignore empty input */
		xfree( wpattern );
		return;
	}

	/* Check for duplicate pattern in group */
	if (g_list_find_custom( row.wpgroup->wp_list, wpattern, (GCompareFunc)strcmp ) != NULL) {
		xfree( wpattern );
		return;
	}

	if (row.rowType == WPLIST_WPATTERN_ROW) {
		/* Update existing pattern */
		l = g_list_replace( row.wpgroup->wp_list, row.wpattern, wpattern );
		g_assert( l != NULL );
		xfree( row.wpattern );
	}
	else {
		/* Add new pattern */
		G_LIST_APPEND(row.wpgroup->wp_list, wpattern);
	}

	[self populateWildcards];
}


- (void)editPattern:(id)sender
{
	FSVWPRow *row = [self selectedRow];
	NSAlert *alert;
	NSTextField *field;

	if ((row == nil) || (row.wpgroup == NULL))
		return;

	alert = [[NSAlert alloc] init];
	alert.messageText = (row.rowType == WPLIST_WPATTERN_ROW) ? @"Edit Wildcard Pattern" : @"New Wildcard Pattern";
	alert.informativeText = @"Shell wildcards, e.g. *.c or [Mm]akefile*";
	[alert addButtonWithTitle:@"OK"];
	[alert addButtonWithTitle:@"Cancel"];
	field = [[NSTextField alloc] initWithFrame:NSMakeRect( 0, 0, 260, 24 )];
	field.stringValue = (row.wpattern != NULL) ? FSVString( row.wpattern ) : @"";
	alert.accessoryView = field;
	alert.window.initialFirstResponder = field;

	[alert beginSheetModalForWindow:_sheet completionHandler:^(NSModalResponse response) {
		if (response == NSAlertFirstButtonReturn)
			[self applyPattern:field.stringValue toRow:row];
	}];
}


- (void)deleteRow:(id)sender
{
	FSVWPRow *row = [self selectedRow];
	NSInteger index = _wpTable.selectedRow;

	if ((row == nil) || (row.wpgroup == NULL))
		return;

	if (row.rowType == WPLIST_WPATTERN_ROW) {
		/* Delete pattern */
		G_LIST_REMOVE(row.wpgroup->wp_list, row.wpattern);
		xfree( row.wpattern );
		[self populateWildcards];
		/* As a courtesy to the user, leave the next row selected */
		if (index < (NSInteger)_wpRows.count)
			[_wpTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)index] byExtendingSelection:NO];
	}
	else if (row.rowType == WPLIST_NEW_WPATTERN_ROW) {
		/* Delete color group ONLY if group is empty */
		if (row.wpgroup->wp_list != NULL)
			return;
		G_LIST_REMOVE(_ccfg.by_wpattern.wpgroup_list, row.wpgroup);
		xfree( row.wpgroup );
		[self populateWildcards];
	}
}


/* Drag and drop reordering of groups and patterns */

- (id<NSPasteboardWriting>)tableView:(NSTableView *)tableView pasteboardWriterForRow:(NSInteger)index
{
	FSVWPRow *row = _wpRows[(NSUInteger)index];
	NSPasteboardItem *item;

	/* Only groups (by their header) and patterns may be moved */
	if ((row.rowType != WPLIST_HEADER_ROW) && (row.rowType != WPLIST_WPATTERN_ROW))
		return nil;
	item = [[NSPasteboardItem alloc] init];
	[item setString:[NSString stringWithFormat:@"%ld", (long)index] forType:WPROW_PASTEBOARD_TYPE];

	return item;
}


- (NSInteger)draggedRow:(id<NSDraggingInfo>)info
{
	NSString *s = [info.draggingPasteboard stringForType:WPROW_PASTEBOARD_TYPE];

	return (s != nil) ? s.integerValue : -1;
}


/* The row that the dropped row would push down, or nil if illegal */
- (FSVWPRow *)destinationForDrop:(NSInteger)source above:(NSInteger)dest
{
	FSVWPRow *src, *dst;

	if ((source < 0) || (source >= (NSInteger)_wpRows.count) || (dest < 0) || (dest >= (NSInteger)_wpRows.count))
		return nil;
	if ((dest == source) || (dest == (source + 1)))
		return nil;
	src = _wpRows[(NSUInteger)source];
	dst = _wpRows[(NSUInteger)dest];

	switch (src.rowType) {
		case WPLIST_HEADER_ROW:
		/* A header row (along with the group beneath it) can only be
		 * moved to a position occupied by another header row */
		if ((dst.rowType != WPLIST_HEADER_ROW) && (dst.rowType != WPLIST_DEFAULT_HEADER_ROW))
			return nil;
		if (dst.wpgroup == src.wpgroup)
			return nil;
		return dst;

		case WPLIST_WPATTERN_ROW:
		/* A pattern row can only take the place of another pattern,
		 * or of a "New pattern" row */
		if ((dst.rowType != WPLIST_WPATTERN_ROW) && (dst.rowType != WPLIST_NEW_WPATTERN_ROW))
			return nil;
		return dst;

		default:
		return nil;
	}
}


- (NSDragOperation)tableView:(NSTableView *)tableView validateDrop:(id<NSDraggingInfo>)info proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)operation
{
	if (operation != NSTableViewDropAbove)
		return NSDragOperationNone;
	return ([self destinationForDrop:[self draggedRow:info] above:row] != nil) ? NSDragOperationMove : NSDragOperationNone;
}


- (BOOL)tableView:(NSTableView *)tableView acceptDrop:(id<NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)operation
{
	NSInteger source = [self draggedRow:info];
	FSVWPRow *src, *dst;

	dst = [self destinationForDrop:source above:row];
	if (dst == nil)
		return NO;
	src = _wpRows[(NSUInteger)source];

	if (src.rowType == WPLIST_HEADER_ROW) {
		/* Move color group to new position */
		G_LIST_REMOVE(_ccfg.by_wpattern.wpgroup_list, src.wpgroup);
		G_LIST_INSERT_BEFORE(_ccfg.by_wpattern.wpgroup_list, dst.wpgroup, src.wpgroup);
	}
	else {
		/* Update official location of wildcard pattern */
		G_LIST_REMOVE(src.wpgroup->wp_list, src.wpattern);
		G_LIST_INSERT_BEFORE(dst.wpgroup->wp_list, dst.wpattern, src.wpattern);
	}
	[self populateWildcards];

	return YES;
}


- (NSView *)wildcardPage
{
	NSScrollView *scroll;
	NSTableColumn *column;
	NSStackView *buttons, *page;

	_wpRows = [NSMutableArray array];

	_wpTable = [[NSTableView alloc] init];
	column = [[NSTableColumn alloc] initWithIdentifier:@"color"];
	column.title = @"Color";
	column.width = 60.0;
	column.resizingMask = NSTableColumnNoResizing;
	[_wpTable addTableColumn:column];
	column = [[NSTableColumn alloc] initWithIdentifier:@"pattern"];
	column.title = @"Wildcard pattern";
	column.width = 240.0;
	[_wpTable addTableColumn:column];
	_wpTable.rowHeight = 20.0;
	_wpTable.style = NSTableViewStylePlain;
	_wpTable.intercellSpacing = NSMakeSize( 0.0, 0.0 );
	_wpTable.dataSource = self;
	_wpTable.delegate = self;
	_wpTable.doubleAction = @selector(editPattern:);
	_wpTable.target = self;
	[_wpTable registerForDraggedTypes:@[ WPROW_PASTEBOARD_TYPE ]];
	[_wpTable setDraggingSourceOperationMask:NSDragOperationMove forLocal:YES];

	scroll = [[NSScrollView alloc] init];
	scroll.documentView = _wpTable;
	scroll.hasVerticalScroller = YES;
	scroll.borderType = NSBezelBorder;
	[scroll.widthAnchor constraintEqualToConstant:320.0].active = YES;
	[scroll.heightAnchor constraintEqualToConstant:230.0].active = YES;

	_newColorButton = [NSButton buttonWithTitle:@"New color" target:self action:@selector(newColor:)];
	_editPatternButton = [NSButton buttonWithTitle:@"Edit pattern" target:self action:@selector(editPattern:)];
	_deleteButton = [NSButton buttonWithTitle:@"Delete" target:self action:@selector(deleteRow:)];
	buttons = [NSStackView stackViewWithViews:@[ _newColorButton, [self separator], _editPatternButton, [self separator], _deleteButton ]];
	buttons.orientation = NSUserInterfaceLayoutOrientationVertical;
	buttons.alignment = NSLayoutAttributeWidth;
	buttons.spacing = 8.0;

	page = [NSStackView stackViewWithViews:@[ scroll, buttons ]];
	page.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	page.alignment = NSLayoutAttributeTop;
	page.spacing = 10.0;
	page.edgeInsets = NSEdgeInsetsMake( 14.0, 14.0, 14.0, 14.0 );

	[self populateWildcards];

	return page;
}


- (NSBox *)separator
{
	NSBox *box = [[NSBox alloc] init];

	box.boxType = NSBoxSeparator;

	return box;
}


/**** Dialog ****/

- (void)ok:(id)sender
{
	ColorMode mode;

	/* Commit new color configuration, and set color mode to match
	 * current notebook page */
	mode = (ColorMode)[_tabs indexOfTabViewItem:_tabs.selectedTabViewItem];
	color_set_config( &_ccfg, mode );

	/* Update menu to reflect current color mode */
	window_set_color_mode( mode );

	[self close];
}


- (void)cancel:(id)sender
{
	[self close];
}


- (void)close
{
	[[NSColorPanel sharedColorPanel] orderOut:nil];
	[FSVMain.window endSheet:_sheet];
}


- (NSButton *)button:(NSString *)title xpm:(char **)xpm action:(SEL)action
{
	NSButton *button = [NSButton buttonWithTitle:title image:FSVImageFromXPM( xpm ) target:self action:action];

	button.imagePosition = NSImageLeading;
	[button.widthAnchor constraintGreaterThanOrEqualToConstant:110.0].active = YES;

	return button;
}


- (void)show
{
	NSTabViewItem *tab;
	NSStackView *main, *buttons;
	NSButton *ok, *cancel;
	ColorMode color_mode;

	/* Get current color mode/configuration */
	color_mode = color_get_mode( );
	color_get_config( &_ccfg );

	_tabs = [[NSTabView alloc] init];
	tab = [[NSTabViewItem alloc] initWithIdentifier:@"nodetype"];
	tab.label = @"By node type";
	tab.view = [self nodeTypePage];
	[_tabs addTabViewItem:tab];
	tab = [[NSTabViewItem alloc] initWithIdentifier:@"time"];
	tab.label = @"By date/time";
	tab.view = [self timePage];
	[_tabs addTabViewItem:tab];
	tab = [[NSTabViewItem alloc] initWithIdentifier:@"wildcards"];
	tab.label = @"By wildcards";
	tab.view = [self wildcardPage];
	[_tabs addTabViewItem:tab];

	/* Set page to current color mode */
	if ((color_mode >= COLOR_BY_NODETYPE) && (color_mode <= COLOR_BY_WPATTERN))
		[_tabs selectTabViewItemAtIndex:color_mode];

	ok = [self button:@"OK" xpm:button_ok_xpm action:@selector(ok:)];
	ok.keyEquivalent = @"\r";
	cancel = [self button:@"Cancel" xpm:button_cancel_xpm action:@selector(cancel:)];
	cancel.keyEquivalent = @"\033";
	buttons = [NSStackView stackViewWithViews:@[ ok, cancel ]];
	buttons.spacing = 40.0;

	main = [NSStackView stackViewWithViews:@[ _tabs, buttons ]];
	main.orientation = NSUserInterfaceLayoutOrientationVertical;
	main.alignment = NSLayoutAttributeCenterX;
	main.spacing = 14.0;
	main.edgeInsets = NSEdgeInsetsMake( 16.0, 16.0, 16.0, 16.0 );
	[_tabs.widthAnchor constraintGreaterThanOrEqualToConstant:500.0].active = YES;
	[_tabs.heightAnchor constraintGreaterThanOrEqualToConstant:300.0].active = YES;

	_sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect( 0, 0, 540, 420 ) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
	_sheet.title = @"Color Setup";
	_sheet.contentView = main;
	_sheet.appearance = FSVMain.window.appearance;
	[_sheet setContentSize:main.fittingSize];

	[FSVMain.window beginSheet:_sheet completionHandler:^(NSModalResponse response) {
		/* (color_config_destroy( ) happens in -dealloc) */
		color_setup = nil;
	}];
}

@end


void
dialog_color_setup( void )
{
	if ((color_setup != nil) || (FSVMain.window.attachedSheet != nil))
		return;

	color_setup = [[FSVColorSetup alloc] init];
	@try {
		[color_setup show];
	}
	@catch (NSException *e) {
		NSLog( @"color setup: %@ %@", e, e.callStackSymbols );
		color_setup = nil;
	}
}


/* end FSVColorSetup.m */
