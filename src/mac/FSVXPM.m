/* FSVXPM.m */

/* Converts fsv's original XPM icons into NSImages, pixel for pixel */

/* mac-fsv - macOS port of fsv
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version. */


#import "FSVApp.h"


static int
hex_value( const char *s, int n )
{
	int v = 0, i, c;

	for (i = 0; i < n; i++) {
		c = s[i];
		v <<= 4;
		if ((c >= '0') && (c <= '9'))
			v |= c - '0';
		else if ((c >= 'a') && (c <= 'f'))
			v |= 10 + c - 'a';
		else if ((c >= 'A') && (c <= 'F'))
			v |= 10 + c - 'A';
	}

	return v;
}


/* Parses an XPM color specification ("None", "#RGB", "#RRGGBB",
 * "#RRRRGGGGBBBB", "black", "white") into RGBA */
static void
parse_xpm_color( const char *spec, uint8_t rgba[4] )
{
	size_t len;
	int n;

	rgba[0] = rgba[1] = rgba[2] = 0;
	rgba[3] = 255;

	if (!strcasecmp( spec, "None" )) {
		rgba[3] = 0;
		return;
	}
	if (!strcasecmp( spec, "white" )) {
		rgba[0] = rgba[1] = rgba[2] = 255;
		return;
	}
	if (spec[0] != '#')
		return; /* black */

	len = strlen( spec + 1 );
	n = (int)(len / 3);
	if (n < 1)
		return;
	rgba[0] = (uint8_t)(hex_value( spec + 1, n ) * 255 / ((1 << (4 * n)) - 1));
	rgba[1] = (uint8_t)(hex_value( spec + 1 + n, n ) * 255 / ((1 << (4 * n)) - 1));
	rgba[2] = (uint8_t)(hex_value( spec + 1 + 2 * n, n ) * 255 / ((1 << (4 * n)) - 1));
}


NSBitmapImageRep *
FSVBitmapFromXPM( char **xpm, int scale )
{
	NSBitmapImageRep *rep;
	uint8_t (*colors)[4];
	char (*keys)[4];
	unsigned char *pixels;
	int width, height, ncolors, cpp;
	int i, j, x, y, sx, sy;

	if ((xpm == NULL) || (sscanf( xpm[0], "%d %d %d %d", &width, &height, &ncolors, &cpp ) != 4))
		return nil;
	if ((cpp < 1) || (cpp > 3) || (scale < 1))
		return nil;

	colors = calloc( (size_t)ncolors, sizeof(*colors) );
	keys = calloc( (size_t)ncolors, sizeof(*keys) );
	for (i = 0; i < ncolors; i++) {
		const char *line = xpm[1 + i];
		char buf[256], *tok, *save = NULL;
		const char *spec = "None";

		memcpy( keys[i], line, (size_t)cpp );
		strncpy( buf, line + cpp, sizeof(buf) - 1 );
		buf[sizeof(buf) - 1] = '\0';
		for (tok = strtok_r( buf, " \t", &save ); tok != NULL; tok = strtok_r( NULL, " \t", &save )) {
			if (!strcmp( tok, "c" )) {
				tok = strtok_r( NULL, " \t", &save );
				if (tok != NULL)
					spec = tok;
				break;
			}
		}
		parse_xpm_color( spec, colors[i] );
	}

	rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width * scale pixelsHigh:height * scale bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bitmapFormat:NSBitmapFormatAlphaNonpremultiplied bytesPerRow:width * scale * 4 bitsPerPixel:32];
	pixels = rep.bitmapData;
	memset( pixels, 0, (size_t)(width * scale * height * scale * 4) );

	for (y = 0; y < height; y++) {
		const char *row = xpm[1 + ncolors + y];
		for (x = 0; x < width; x++) {
			const char *key = row + x * cpp;
			for (j = 0; j < ncolors; j++)
				if (!memcmp( keys[j], key, (size_t)cpp ))
					break;
			if (j == ncolors)
				continue;
			/* Nearest-neighbor magnification keeps the pixel art crisp */
			for (sy = 0; sy < scale; sy++)
				for (sx = 0; sx < scale; sx++)
					memcpy( pixels + (((y * scale + sy) * width * scale) + (x * scale + sx)) * 4, colors[j], 4 );
		}
	}

	free( colors );
	free( keys );

	return rep;
}


NSImage *
FSVImageFromXPM( char **xpm )
{
	NSBitmapImageRep *rep1, *rep2;
	NSImage *image;

	rep1 = FSVBitmapFromXPM( xpm, 1 );
	if (rep1 == nil)
		return nil;
	rep2 = FSVBitmapFromXPM( xpm, 2 );

	image = [[NSImage alloc] initWithSize:NSMakeSize( rep1.pixelsWide, rep1.pixelsHigh )];
	rep1.size = image.size;
	[image addRepresentation:rep1];
	if (rep2 != nil) {
		/* Pixel-doubled version for Retina displays */
		rep2.size = image.size;
		[image addRepresentation:rep2];
	}

	return image;
}


/* end FSVXPM.m */
