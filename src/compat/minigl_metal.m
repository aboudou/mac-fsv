/* minigl_metal.m */

/* Metal back end for minigl: reproduces fsv's fixed-function OpenGL
 * pipeline (headlight lighting with flat shading, wide and stippled
 * lines, alpha-tested intensity textures, linear fog, polygon offset) */

/* mac-fsv - macOS port of fsv
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version. */


#import "minigl_metal.h"
#import <simd/simd.h>

#include "GL/gl.h"
#include "minigl_internal.h"


typedef struct {
	simd_float4x4	mvp;
	simd_float4x4	mv;
	simd_float4	nm0;
	simd_float4	nm1;
	simd_float4	nm2;
	simd_float2	viewport;
	float		line_width;
	uint32_t	flags;
	float		alpha_ref;
	uint32_t	alpha_func;
	float		fog_start;
	float		fog_end;
	uint32_t	stipple_factor;
	uint32_t	stipple_pattern;
	uint32_t	pad0;
	uint32_t	pad1;
} MGLUniforms;

enum {
	U_LIGHTING	= 1 << 0,
	U_LIGHT0	= 1 << 1,
	U_TEXTURE	= 1 << 2,
	U_ALPHA_TEST	= 1 << 3,
	U_FOG		= 1 << 4,
	U_STIPPLE	= 1 << 5,
	U_FLAT		= 1 << 6
};


static NSString *const shader_source = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"\n"
"struct TriVertex { packed_float3 pos; char4 nrm; uchar4 col; ushort2 tex; };\n"
"struct LineSeg { packed_float3 a; packed_float3 b; char4 nrm; uchar4 col; };\n"
"\n"
"struct Uniforms {\n"
"	float4x4 mvp;\n"
"	float4x4 mv;\n"
"	float4 nm0;\n"
"	float4 nm1;\n"
"	float4 nm2;\n"
"	float2 viewport;\n"
"	float line_width;\n"
"	uint flags;\n"
"	float alpha_ref;\n"
"	uint alpha_func;\n"
"	float fog_start;\n"
"	float fog_end;\n"
"	uint stipple_factor;\n"
"	uint stipple_pattern;\n"
"	uint pad0;\n"
"	uint pad1;\n"
"};\n"
"\n"
"struct VOut {\n"
"	float4 position [[position]];\n"
"	float4 color;\n"
"	float2 tex;\n"
"	float fog;\n"
"	float2 lstart;\n"
"	float2 ldir;\n"
"};\n"
"\n"
"/* GL fixed-function lighting as configured by fsv: global ambient 0.2,\n"
" * LIGHT0 at the eye (ambient 0.2, diffuse 0.5), color material for\n"
" * ambient and diffuse, no effective specular term */\n"
"static float4 lighting( float3 objpos, char4 pn, uchar4 pc, constant Uniforms &u )\n"
"{\n"
"	float4 c = float4( pc ) / 255.0;\n"
"	if ((u.flags & 1u) == 0u)\n"
"		return c;\n"
"	float3 n = float3( pn.xyz ) / 127.0;\n"
"	float3 en = float3( dot( u.nm0.xyz, n ), dot( u.nm1.xyz, n ), dot( u.nm2.xyz, n ) );\n"
"	float len = length( en );\n"
"	en = (len > 1.0e-6) ? (en / len) : float3( 0.0, 0.0, 1.0 );\n"
"	float3 rgb = 0.2 * c.rgb;\n"
"	if ((u.flags & 2u) != 0u) {\n"
"		float3 ec = (u.mv * float4( objpos, 1.0 )).xyz;\n"
"		float3 l = normalize( -ec );\n"
"		rgb += 0.2 * c.rgb + 0.5 * c.rgb * max( dot( en, l ), 0.0 );\n"
"	}\n"
"	return float4( clamp( rgb, 0.0, 1.0 ), c.a );\n"
"}\n"
"\n"
"static float fog_factor( float3 objpos, constant Uniforms &u )\n"
"{\n"
"	if ((u.flags & 16u) == 0u)\n"
"		return 1.0;\n"
"	float z = abs( (u.mv * float4( objpos, 1.0 )).z );\n"
"	return clamp( (u.fog_end - z) / (u.fog_end - u.fog_start), 0.0, 1.0 );\n"
"}\n"
"\n"
"vertex VOut tri_vs( uint vid [[vertex_id]], const device TriVertex *v [[buffer(0)]], constant Uniforms &u [[buffer(1)]] )\n"
"{\n"
"	TriVertex tv = v[vid];\n"
"	/* Flat shading: lighting computed once, at the provoking vertex\n"
"	 * (always the first vertex of each triangle) */\n"
"	uint pv = ((u.flags & 64u) != 0u) ? (vid - (vid % 3u)) : vid;\n"
"	TriVertex lv = v[pv];\n"
"	float3 p = float3( tv.pos );\n"
"	float4 clip = u.mvp * float4( p, 1.0 );\n"
"	VOut o;\n"
"	o.position = float4( clip.x, clip.y, 0.5 * (clip.z + clip.w), clip.w );\n"
"	o.color = lighting( float3( lv.pos ), lv.nrm, lv.col, u );\n"
"	o.tex = float2( tv.tex ) / 65535.0;\n"
"	o.fog = fog_factor( p, u );\n"
"	o.lstart = float2( 0.0 );\n"
"	o.ldir = float2( 1.0, 0.0 );\n"
"	return o;\n"
"}\n"
"\n"
"constant float corner_t[6] = { 0.0, 1.0, 1.0, 0.0, 1.0, 0.0 };\n"
"constant float corner_side[6] = { -1.0, -1.0, 1.0, -1.0, 1.0, 1.0 };\n"
"\n"
"/* Each line segment is expanded into a screen-aligned quad (6 vertices) */\n"
"vertex VOut line_vs( uint vid [[vertex_id]], const device LineSeg *s [[buffer(0)]], constant Uniforms &u [[buffer(1)]] )\n"
"{\n"
"	LineSeg seg = s[vid / 6u];\n"
"	uint corner = vid % 6u;\n"
"	float3 pa = float3( seg.a );\n"
"	float3 pb = float3( seg.b );\n"
"	float4 ca = u.mvp * float4( pa, 1.0 );\n"
"	float4 cb = u.mvp * float4( pb, 1.0 );\n"
"	VOut o;\n"
"	o.color = lighting( pb, seg.nrm, seg.col, u );\n"
"	o.tex = float2( 0.0 );\n"
"	/* Clip against the near plane before going to screen space */\n"
"	float da = ca.z + ca.w;\n"
"	float db = cb.z + cb.w;\n"
"	if ((da < 0.0) && (db < 0.0)) {\n"
"		o.position = float4( 2.0, 2.0, 2.0, 1.0 );\n"
"		o.fog = 1.0;\n"
"		o.lstart = float2( 0.0 );\n"
"		o.ldir = float2( 1.0, 0.0 );\n"
"		return o;\n"
"	}\n"
"	if (da < 0.0)\n"
"		ca = mix( ca, cb, da / (da - db) );\n"
"	else if (db < 0.0)\n"
"		cb = mix( cb, ca, db / (db - da) );\n"
"	float2 sa = (0.5 * ca.xy / ca.w + 0.5) * u.viewport;\n"
"	float2 sb = (0.5 * cb.xy / cb.w + 0.5) * u.viewport;\n"
"	float2 d = sb - sa;\n"
"	float len = length( d );\n"
"	float2 dir = (len > 1.0e-6) ? (d / len) : float2( 1.0, 0.0 );\n"
"	float2 perp = float2( -dir.y, dir.x );\n"
"	float t = corner_t[corner];\n"
"	float4 cp = (t > 0.5) ? cb : ca;\n"
"	float2 ofs = perp * corner_side[corner] * (0.5 * u.line_width);\n"
"	cp.xy += (2.0 * ofs / u.viewport) * cp.w;\n"
"	o.position = float4( cp.x, cp.y, 0.5 * (cp.z + cp.w), cp.w );\n"
"	o.fog = fog_factor( (t > 0.5) ? pb : pa, u );\n"
"	/* Stipple reference, in framebuffer coordinates (y down) */\n"
"	o.lstart = float2( sa.x, u.viewport.y - sa.y );\n"
"	o.ldir = float2( dir.x, -dir.y );\n"
"	return o;\n"
"}\n"
"\n"
"fragment float4 fsv_fs( VOut in [[stage_in]], constant Uniforms &u [[buffer(1)]], texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]] )\n"
"{\n"
"	float4 c = in.color;\n"
"	if ((u.flags & 32u) != 0u) {\n"
"		float s = max( dot( in.position.xy - in.lstart, in.ldir ), 0.0 );\n"
"		uint bit = uint( floor( s / float( u.stipple_factor ) ) ) % 16u;\n"
"		if (((u.stipple_pattern >> bit) & 1u) == 0u)\n"
"			discard_fragment( );\n"
"	}\n"
"	if ((u.flags & 4u) != 0u) {\n"
"		/* GL_INTENSITY texture, GL_MODULATE environment */\n"
"		float i = tex.sample( smp, in.tex ).r;\n"
"		c *= i;\n"
"	}\n"
"	if ((u.flags & 16u) != 0u)\n"
"		c.rgb *= in.fog;\n"
"	if ((u.flags & 8u) != 0u) {\n"
"		bool pass = true;\n"
"		switch (u.alpha_func) {\n"
"			case 0x0200u: pass = false; break;\n"
"			case 0x0201u: pass = c.a < u.alpha_ref; break;\n"
"			case 0x0202u: pass = c.a == u.alpha_ref; break;\n"
"			case 0x0203u: pass = c.a <= u.alpha_ref; break;\n"
"			case 0x0204u: pass = c.a > u.alpha_ref; break;\n"
"			case 0x0205u: pass = c.a != u.alpha_ref; break;\n"
"			case 0x0206u: pass = c.a >= u.alpha_ref; break;\n"
"			default: break;\n"
"		}\n"
"		if (!pass)\n"
"			discard_fragment( );\n"
"	}\n"
"	return c;\n"
"}\n";


static MTKView *mgl_view = nil;
static id<MTLDevice> mgl_device = nil;
static id<MTLCommandQueue> mgl_queue = nil;
static id<MTLRenderPipelineState> mgl_pipelines[2][2]; /* [kind][blend] */
static NSMutableDictionary<NSNumber *, id<MTLDepthStencilState>> *mgl_depth_states = nil;
static NSMutableDictionary<NSNumber *, id<MTLTexture>> *mgl_textures = nil;
static id<MTLTexture> mgl_dummy_texture = nil;
static id<MTLSamplerState> mgl_sampler = nil;
static float mgl_line_scale = 1.0f;


void
mglb_set_line_scale( float scale )
{
	mgl_line_scale = (scale > 0.0f) ? scale : 1.0f;
}


void
mglb_init( MTKView *view )
{
	NSError *error = nil;
	id<MTLLibrary> library;
	MTLRenderPipelineDescriptor *desc;
	MTLSamplerDescriptor *sdesc;
	MTLTextureDescriptor *tdesc;
	uint8_t white = 255;
	int kind, blend;

	mgl_view = view;
	mgl_device = view.device;
	mgl_queue = [mgl_device newCommandQueue];
	mgl_depth_states = [NSMutableDictionary dictionary];
	mgl_textures = [NSMutableDictionary dictionary];

	library = [mgl_device newLibraryWithSource:shader_source options:nil error:&error];
	if (library == nil) {
		NSLog( @"mac-fsv: cannot compile Metal shaders: %@", error );
		abort( );
	}

	for (kind = 0; kind < 2; kind++) {
		for (blend = 0; blend < 2; blend++) {
			desc = [[MTLRenderPipelineDescriptor alloc] init];
			desc.vertexFunction = [library newFunctionWithName:(kind == MGL_DRAW_TRIS) ? @"tri_vs" : @"line_vs"];
			desc.fragmentFunction = [library newFunctionWithName:@"fsv_fs"];
			desc.colorAttachments[0].pixelFormat = view.colorPixelFormat;
			desc.depthAttachmentPixelFormat = view.depthStencilPixelFormat;
			if (blend) {
				desc.colorAttachments[0].blendingEnabled = YES;
				desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
				desc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
				desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
				desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
				desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
				desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
			}
			mgl_pipelines[kind][blend] = [mgl_device newRenderPipelineStateWithDescriptor:desc error:&error];
			if (mgl_pipelines[kind][blend] == nil) {
				NSLog( @"mac-fsv: cannot create pipeline: %@", error );
				abort( );
			}
		}
	}

	/* Font texture sampling: GL_NEAREST_MIPMAP_LINEAR / GL_NEAREST */
	sdesc = [[MTLSamplerDescriptor alloc] init];
	sdesc.minFilter = MTLSamplerMinMagFilterNearest;
	sdesc.magFilter = MTLSamplerMinMagFilterNearest;
	sdesc.mipFilter = MTLSamplerMipFilterLinear;
	sdesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
	sdesc.tAddressMode = MTLSamplerAddressModeClampToEdge;
	mgl_sampler = [mgl_device newSamplerStateWithDescriptor:sdesc];

	tdesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:1 height:1 mipmapped:NO];
	mgl_dummy_texture = [mgl_device newTextureWithDescriptor:tdesc];
	[mgl_dummy_texture replaceRegion:MTLRegionMake2D( 0, 0, 1, 1 ) mipmapLevel:0 withBytes:&white bytesPerRow:1];
}


void *
mglb_buffer_create( const void *bytes, size_t length, void **contents )
{
	id<MTLBuffer> buffer;

	if ((mgl_device == nil) || (length == 0))
		return NULL;

	buffer = [mgl_device newBufferWithBytes:bytes length:length options:MTLResourceStorageModeShared];
	if (buffer == nil)
		return NULL;
	if (contents != NULL)
		*contents = buffer.contents;

	return (__bridge_retained void *)buffer;
}


void
mglb_buffer_release( void *buffer )
{
	if (buffer == NULL)
		return;
	CFRelease( buffer );
}


/* Builds the texture like gluBuild2DMipmaps( ) would: box-filtered
 * mipmaps down to 1x1, optionally quantized to 4 bits (GL_INTENSITY4) */
void
mglb_texture_create( unsigned int tex_id, int width, int height, const uint8_t *luminance, int mipmapped, int quantize4 )
{
	MTLTextureDescriptor *desc;
	id<MTLTexture> texture;
	uint8_t *level, *next;
	int w = width, h = height, nw, nh, x, y, l, levels = 1;
	int i;

	if ((mgl_device == nil) || (width <= 0) || (height <= 0))
		return;

	if (mipmapped) {
		while ((w > 1) || (h > 1)) {
			w = (w > 1) ? (w / 2) : 1;
			h = (h > 1) ? (h / 2) : 1;
			++levels;
		}
	}

	desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:(NSUInteger)width height:(NSUInteger)height mipmapped:(levels > 1)];
	desc.mipmapLevelCount = (NSUInteger)levels;
	texture = [mgl_device newTextureWithDescriptor:desc];

	w = width;
	h = height;
	level = malloc( (size_t)(w * h) );
	memcpy( level, luminance, (size_t)(w * h) );
	for (l = 0; l < levels; l++) {
		if (quantize4) {
			uint8_t *q = malloc( (size_t)(w * h) );
			for (i = 0; i < (w * h); i++)
				q[i] = (uint8_t)(17 * ((level[i] * 15 + 127) / 255));
			[texture replaceRegion:MTLRegionMake2D( 0, 0, (NSUInteger)w, (NSUInteger)h ) mipmapLevel:(NSUInteger)l withBytes:q bytesPerRow:(NSUInteger)w];
			free( q );
		}
		else
			[texture replaceRegion:MTLRegionMake2D( 0, 0, (NSUInteger)w, (NSUInteger)h ) mipmapLevel:(NSUInteger)l withBytes:level bytesPerRow:(NSUInteger)w];

		if ((l + 1) == levels)
			break;

		/* Next mipmap level (2x2 box filter) */
		nw = (w > 1) ? (w / 2) : 1;
		nh = (h > 1) ? (h / 2) : 1;
		next = malloc( (size_t)(nw * nh) );
		for (y = 0; y < nh; y++) {
			for (x = 0; x < nw; x++) {
				int x0 = MIN( 2 * x, w - 1 ), x1 = MIN( 2 * x + 1, w - 1 );
				int y0 = MIN( 2 * y, h - 1 ), y1 = MIN( 2 * y + 1, h - 1 );
				int sum = level[y0 * w + x0] + level[y0 * w + x1] + level[y1 * w + x0] + level[y1 * w + x1];
				next[y * nw + x] = (uint8_t)((sum + 2) / 4);
			}
		}
		free( level );
		level = next;
		w = nw;
		h = nh;
	}
	free( level );

	mgl_textures[@(tex_id)] = texture;
}


static id<MTLDepthStencilState>
depth_state( int test, uint32_t func )
{
	MTLDepthStencilDescriptor *desc;
	id<MTLDepthStencilState> state;
	NSNumber *key;

	key = @(test ? (int)func : 0);
	state = mgl_depth_states[key];
	if (state != nil)
		return state;

	desc = [[MTLDepthStencilDescriptor alloc] init];
	if (!test) {
		desc.depthCompareFunction = MTLCompareFunctionAlways;
		desc.depthWriteEnabled = NO;
	}
	else {
		switch (func) {
			case GL_NEVER: desc.depthCompareFunction = MTLCompareFunctionNever; break;
			case GL_LESS: desc.depthCompareFunction = MTLCompareFunctionLess; break;
			case GL_EQUAL: desc.depthCompareFunction = MTLCompareFunctionEqual; break;
			case GL_LEQUAL: desc.depthCompareFunction = MTLCompareFunctionLessEqual; break;
			case GL_GREATER: desc.depthCompareFunction = MTLCompareFunctionGreater; break;
			case GL_NOTEQUAL: desc.depthCompareFunction = MTLCompareFunctionNotEqual; break;
			case GL_GEQUAL: desc.depthCompareFunction = MTLCompareFunctionGreaterEqual; break;
			default: desc.depthCompareFunction = MTLCompareFunctionAlways; break;
		}
		desc.depthWriteEnabled = YES;
	}
	state = [mgl_device newDepthStencilStateWithDescriptor:desc];
	mgl_depth_states[key] = state;

	return state;
}


static simd_float4x4
float4x4_from_gl( const float *m )
{
	simd_float4x4 r;

	r.columns[0] = simd_make_float4( m[0], m[1], m[2], m[3] );
	r.columns[1] = simd_make_float4( m[4], m[5], m[6], m[7] );
	r.columns[2] = simd_make_float4( m[8], m[9], m[10], m[11] );
	r.columns[3] = simd_make_float4( m[12], m[13], m[14], m[15] );

	return r;
}


void
mglb_frame_submit( const MGLFrame *frame )
{
	MTLRenderPassDescriptor *pass;
	id<CAMetalDrawable> drawable;
	id<MTLCommandBuffer> cmd;
	id<MTLRenderCommandEncoder> enc;
	id<MTLBuffer> tri_buf = nil, line_buf = nil, buf;
	id<MTLRenderPipelineState> last_pipeline = nil;
	id<MTLDepthStencilState> last_depth = nil;
	id<MTLTexture> texture, last_texture = nil;
	MGLUniforms u;
	MTLViewport vp;
	CGSize size;
	const float *last_mv = NULL, *last_proj = NULL;
	int last_cull = -1, last_bias = -1;
	size_t i;

	if (mgl_view == nil)
		return;

	@autoreleasepool {
		double t_acquire = CACurrentMediaTime( );
		pass = mgl_view.currentRenderPassDescriptor;
		drawable = mgl_view.currentDrawable;
		if (getenv( "MACFSV_DEBUG" ) != NULL) {
			static int nil_count = 0;
			double wait = CACurrentMediaTime( ) - t_acquire;
			if ((pass == nil) || (drawable == nil))
				NSLog( @"present: no drawable (%d) after %.1f ms", ++nil_count, 1000.0 * wait );
			else if (wait > 0.008)
				NSLog( @"present: waited %.1f ms for a drawable", 1000.0 * wait );
		}
		if ((pass == nil) || (drawable == nil))
			return;

		if (frame->clear_mask & GL_COLOR_BUFFER_BIT) {
			pass.colorAttachments[0].loadAction = MTLLoadActionClear;
			pass.colorAttachments[0].clearColor = MTLClearColorMake( frame->clear_color[0], frame->clear_color[1], frame->clear_color[2], 1.0 );
		}
		else
			pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
		pass.colorAttachments[0].storeAction = MTLStoreActionStore;
		pass.depthAttachment.loadAction = MTLLoadActionClear;
		pass.depthAttachment.clearDepth = 1.0;
		pass.depthAttachment.storeAction = MTLStoreActionDontCare;

		if (frame->num_tris > 0)
			tri_buf = [mgl_device newBufferWithBytes:frame->tris length:frame->num_tris * sizeof(MGLTriVertex) options:MTLResourceStorageModeShared];
		if (frame->num_lines > 0)
			line_buf = [mgl_device newBufferWithBytes:frame->lines length:frame->num_lines * sizeof(MGLLineSeg) options:MTLResourceStorageModeShared];

		cmd = [mgl_queue commandBuffer];
		enc = [cmd renderCommandEncoderWithDescriptor:pass];
		[enc setFrontFacingWinding:MTLWindingCounterClockwise];

		size = mgl_view.drawableSize;
		vp.originX = frame->viewport[0];
		vp.originY = size.height - (double)(frame->viewport[1] + frame->viewport[3]);
		vp.width = frame->viewport[2];
		vp.height = frame->viewport[3];
		vp.znear = 0.0;
		vp.zfar = 1.0;
		[enc setViewport:vp];
		[enc setFragmentSamplerState:mgl_sampler atIndex:0];

		memset( &u, 0, sizeof(u) );

		for (i = 0; i < frame->num_draws; i++) {
			const MGLDraw *d = &frame->draws[i];
			const MGLState *st = &d->st;
			id<MTLRenderPipelineState> pipeline;
			id<MTLDepthStencilState> ds;
			int cull, bias;

			if (d->buffer != NULL)
				buf = (__bridge id<MTLBuffer>)d->buffer;
			else
				buf = (d->kind == MGL_DRAW_TRIS) ? tri_buf : line_buf;
			if (buf == nil)
				continue;

			pipeline = mgl_pipelines[d->kind][st->blend ? 1 : 0];
			if (pipeline != last_pipeline) {
				[enc setRenderPipelineState:pipeline];
				last_pipeline = pipeline;
			}

			ds = depth_state( st->depth_test, st->depth_func );
			if (ds != last_depth) {
				[enc setDepthStencilState:ds];
				last_depth = ds;
			}

			cull = (d->kind == MGL_DRAW_TRIS) && st->cull;
			if (cull != last_cull) {
				[enc setCullMode:cull ? MTLCullModeBack : MTLCullModeNone];
				last_cull = cull;
			}

			bias = (d->kind == MGL_DRAW_TRIS) && st->poly_offset;
			if (bias != last_bias) {
				/* glPolygonOffset( 1.0, 1.0 ) */
				if (bias)
					[enc setDepthBias:1.0f slopeScale:1.0f clamp:0.0f];
				else
					[enc setDepthBias:0.0f slopeScale:0.0f clamp:0.0f];
				last_bias = bias;
			}

			if (st->texture2d) {
				texture = mgl_textures[@(st->texture)];
				if (texture == nil)
					texture = mgl_dummy_texture;
			}
			else
				texture = mgl_dummy_texture;
			if (texture != last_texture) {
				[enc setFragmentTexture:texture atIndex:0];
				last_texture = texture;
			}

			/* Uniforms */
			if ((last_mv == NULL) || memcmp( last_mv, d->mv, sizeof(d->mv) ) || memcmp( last_proj, d->proj, sizeof(d->proj) )) {
				simd_float4x4 mv = float4x4_from_gl( d->mv );
				simd_float4x4 proj = float4x4_from_gl( d->proj );
				simd_float3x3 upper, inv;

				upper.columns[0] = mv.columns[0].xyz;
				upper.columns[1] = mv.columns[1].xyz;
				upper.columns[2] = mv.columns[2].xyz;
				inv = simd_inverse( upper );
				u.mvp = simd_mul( proj, mv );
				u.mv = mv;
				/* Rows of the inverse transpose = columns of the inverse */
				u.nm0 = simd_make_float4( inv.columns[0], 0.0f );
				u.nm1 = simd_make_float4( inv.columns[1], 0.0f );
				u.nm2 = simd_make_float4( inv.columns[2], 0.0f );
				last_mv = d->mv;
				last_proj = d->proj;
			}
			u.viewport = simd_make_float2( (float)frame->viewport[2], (float)frame->viewport[3] );
			u.line_width = st->line_width * mgl_line_scale;
			u.flags = 0;
			if (st->lighting) u.flags |= U_LIGHTING;
			if (st->light0) u.flags |= U_LIGHT0;
			if (st->texture2d) u.flags |= U_TEXTURE;
			if (st->alpha_test) u.flags |= U_ALPHA_TEST;
			if (st->fog) u.flags |= U_FOG;
			if (st->line_stipple && (d->kind == MGL_DRAW_LINES)) u.flags |= U_STIPPLE;
			if (st->flat) u.flags |= U_FLAT;
			u.alpha_ref = st->alpha_ref;
			u.alpha_func = st->alpha_func;
			u.fog_start = st->fog_start;
			u.fog_end = (st->fog_end != st->fog_start) ? st->fog_end : (st->fog_start + 1.0f);
			u.stipple_factor = (st->stipple_factor > 0) ? st->stipple_factor : 1;
			u.stipple_pattern = st->stipple_pattern;
			/* Stipple counts in original-resolution pixels */
			u.stipple_factor = (uint32_t)lrintf( (float)u.stipple_factor * mgl_line_scale );
			if (u.stipple_factor < 1)
				u.stipple_factor = 1;

			[enc setVertexBytes:&u length:sizeof(u) atIndex:1];
			[enc setFragmentBytes:&u length:sizeof(u) atIndex:1];
			[enc setVertexBuffer:buf offset:d->offset atIndex:0];

			if (d->kind == MGL_DRAW_TRIS)
				[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:d->count];
			else
				[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6 * (NSUInteger)d->count];
		}

		[enc endEncoding];
		if (getenv( "MACFSV_DEBUG" ) != NULL) {
			double t_submit = CACurrentMediaTime( );
			[drawable addPresentedHandler:^(id<MTLDrawable> d) {
				static int presented = 0, skipped = 0;
				static double t_sec = 0.0, worst = 0.0;
				double now = CACurrentMediaTime( );
				if (d.presentedTime > 0.0) {
					++presented;
					if ((d.presentedTime - t_submit) > worst)
						worst = d.presentedTime - t_submit;
				}
				else
					++skipped;
				if ((now - t_sec) >= 1.0) {
					NSLog( @"screen: %d frames shown/s, %d dropped, worst submit-to-screen %.0f ms", presented, skipped, 1000.0 * worst );
					presented = skipped = 0;
					worst = 0.0;
					t_sec = now;
				}
			}];
		}
		[cmd presentDrawable:drawable];
		[cmd commit];
	}
}


/* end minigl_metal.m */
