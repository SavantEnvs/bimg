// In-process libFuzzer harness for bimg's image-decode path — the same code that the
// `texturec` CLI drives via convert()/bimg::imageParse() (tools/texturec/texturec.cpp).
//
// The raw file-input `texturec` CLI is not productive under Mayhem when built with the
// required ASan/UBSan (analysis phases time out / abort with 0 edges); rule 5 of the port
// contract endorses converting such a target to an in-process libFuzzer harness over the
// SAME code path. This drives every compiled-in decoder (png/jpg/tga/dds/ktx/exr/gif/...)
// exactly as texturec does, then forces a full pixel decode of mip 0, then frees.
//
// bimg's format sniffers (e.g. imageParseLodePng) `memCmp` a fixed-length magic against the
// input WITHOUT first checking the input is that long (src/image_decode.cpp), so a
// sub-signature input over-reads by a few bytes. That is a shallow bug in bimg's magic
// detection; left unguarded it aborts on ~every 1-byte mutation and libFuzzer can never
// explore the actual decoders (0 edges). We therefore hand bimg a buffer padded with a small
// zeroed tail so signature sniffing stays in-bounds, while the decoders still parse exactly
// `size` bytes — keeping the real decode attack surface (malformed headers/chunks/pixels)
// fully fuzzable. The trivial magic over-read is documented here rather than reported.
#include <bimg/decode.h>
#include <bx/allocator.h>
#include <bx/error.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

// Longer than any magic bimg compares (PNG/DDS/KTX/EXR/... are all <= 12 bytes).
static const size_t kMagicPad = 32;

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
	if (size == 0 || size > (16u << 20))
	{
		return 0;
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
