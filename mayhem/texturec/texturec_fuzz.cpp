// In-process libFuzzer harness for bimg's image-decode path — the same code that the
// `texturec` CLI drives via convert()/bimg::imageParse() (tools/texturec/texturec.cpp).
//
// The raw file-input `texturec` CLI is not productive under Mayhem when built with the
// required ASan/UBSan (analysis phases time out / abort with 0 edges); rule 5 of the port
// contract endorses converting such a target to an in-process libFuzzer harness over the
// SAME code path. This drives every compiled-in decoder (png/jpg/tga/dds/ktx/exr/gif/...)
// exactly as texturec does, then forces a full pixel decode of mip 0, then frees.
//
// bimg's format sniffers `memCmp` a fixed-length magic against the input WITHOUT first
// checking the input is that long (src/image_decode.cpp: imageParseLodePng@170 reads 6
// bytes of PNG magic, imageParseTinyExr@571 reads 4 bytes of EXR magic — contrast with
// their imageParseInfo* siblings, which DO guard with `_size < sizeof(magic)` first), so a
// sub-signature input over-reads by a few bytes. That is a shallow, real bug in bimg's magic
// detection (upstream bkaradzic/bimg, not introduced by this port); left unguarded it aborts
// on ~every 1-byte mutation and libFuzzer can never explore the actual decoders (0 edges).
// We therefore hand bimg a buffer padded with a small zeroed tail so signature sniffing
// stays in-bounds, while the decoders still parse exactly `size` bytes — keeping the real
// decode attack surface (malformed headers/chunks/pixels) fully fuzzable. As of this port
// there is no upstream issue for it; it is disclosed here (and on the porting PR) rather
// than filed, for lack of a tool/identity to open one on bkaradzic/bimg from this worker.
#include <bimg/decode.h>
#include <bx/allocator.h>
#include <bx/error.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

// Longer than any magic bimg compares (PNG/DDS/KTX/EXR/... are all <= 12 bytes).
static const size_t kMagicPad = 32;

// stb_image's GIF loader (3rdparty/stb/stb_image.h, stbi__gif_load_next) takes the logical-screen
// size straight from the 16-bit header fields and mallocs 4*w*h (out) + 4*w*h (background) + w*h
// (history) = 9 bytes/pixel BEFORE reading any pixel data, and memsets them. The library's contract
// for that is a NULL return with "Out of memory" (it checks every one of the three mallocs), and it
// rejects only images whose 4*w*h overflows int (~2 GiB, stb_image.h:195-211). So a handful of header
// bytes declaring ~400M pixels is a defined error for a real caller, but under this fuzz process's
// 2048 MB libFuzzer allocation/RSS limit it aborts as "out-of-memory" instead, which says nothing
// about memory safety. We reject (-1) GIFs whose header declares more than 2^24 pixels (4096x4096,
// ~150 MB of loader buffers, well inside the limit); the rest of the GIF decoder is fuzzed as before.
static const uint64_t kMaxGifPixels = 1u << 24;

static bool gifDeclaresTooManyPixels(const uint8_t* data, size_t size)
{
	// "GIF87a" / "GIF89a", then little-endian uint16 width and height (stbi__gif_test_raw/_header).
	if (size < 10 || 0 != memcmp(data, "GIF8", 4) || (data[4] != '7' && data[4] != '9') || data[5] != 'a')
	{
		return false;
	}
	const uint64_t w = data[6] | (uint64_t)data[7] << 8;
	const uint64_t h = data[8] | (uint64_t)data[9] << 8;
	return w * h > kMaxGifPixels;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
	if (size == 0 || size > (16u << 20))
	{
		return 0;
	}

	if (gifDeclaresTooManyPixels(data, size))
	{
		return -1;
	}

	uint8_t* buf = (uint8_t*)malloc(size + kMagicPad);
	if (NULL == buf)
	{
		return 0;
	}
	memcpy(buf, data, size);
	memset(buf + size, 0, kMagicPad);

	static bx::DefaultAllocator s_allocator;
	bx::Error err;

	bimg::ImageContainer* image = bimg::imageParse(
		  &s_allocator
		, buf
		, (uint32_t)size
		, bimg::TextureFormat::Count
		, &err
		);

	if (NULL != image)
	{
		bimg::ImageMip mip;
		bimg::imageGetRawData(*image, 0, 0, image->m_data, image->m_size, mip);
		bimg::imageFree(image);
	}

	free(buf);
	return 0;
}
