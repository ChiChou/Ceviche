#pragma once
#include <stddef.h>
#include <stdint.h>

// zlib (RFC 1950) stream, as TIFF Deflate compression expects. Returns the compressed size, or 0 when it does not fit.
size_t cdng_deflate(const void *source, size_t source_size, void *destination, size_t destination_size, int level);
size_t cdng_deflate_bound(size_t source_size);

// Lossless JPEG (ITU T.81 process 14, predictor 1, 16-bit), the integer compression DNG readers support. Encodes
// width × height pixels of `components` interleaved samples as one frame. Returns the size, or 0 when it does not fit.
size_t cdng_lossless_jpeg(const uint16_t *samples, int width, int height, int components, uint8_t *destination, size_t destination_size);
