#include "CDNG.h"
#include <limits.h>
#include <string.h>
#include <zlib.h>

size_t cdng_deflate_bound(size_t source_size) { return compressBound((uLong)source_size); }

size_t cdng_deflate(const void *source, size_t source_size, void *destination, size_t destination_size, int level) {
    uLongf size = (uLongf)destination_size;
    if (compress2(destination, &size, source, (uLong)source_size, level) != Z_OK) return 0;
    return size;
}

typedef struct { uint8_t *data; size_t size, used; uint32_t buffer; int bits; int overflow; } bit_writer;

static void put_byte(bit_writer *w, uint8_t byte) {
    if (w->used >= w->size) { w->overflow = 1; return; }
    w->data[w->used++] = byte;
}

static void put_bits(bit_writer *w, uint32_t value, int count) {
    for (int i = count - 1; i >= 0; i--) {
        w->buffer = (w->buffer << 1) | ((value >> i) & 1);
        if (++w->bits == 8) {
            put_byte(w, (uint8_t)w->buffer);
            if ((w->buffer & 0xFF) == 0xFF) put_byte(w, 0); // byte stuffing
            w->buffer = 0; w->bits = 0;
        }
    }
}

static void put_marker(bit_writer *w, uint8_t marker) { put_byte(w, 0xFF); put_byte(w, marker); }
static void put_word(bit_writer *w, int value) { put_byte(w, (uint8_t)(value >> 8)); put_byte(w, (uint8_t)value); }

static int category(int difference) {
    int magnitude = difference < 0 ? -difference : difference, bits = 0;
    while (magnitude) { bits++; magnitude >>= 1; }
    return bits;
}

// Optimal code lengths limited to 16 bits, as in ITU T.81 Annex K.2.
static void huffman_table(const long *frequencies, uint8_t bits[17], uint8_t values[17], int *value_count) {
    long freq[18]; int codesize[18] = {0}, others[18];
    for (int i = 0; i < 17; i++) freq[i] = frequencies[i];
    freq[17] = 1; // reserved so no code is all ones
    for (int i = 0; i < 18; i++) others[i] = -1;
    for (;;) {
        int c1 = -1, c2 = -1; long v = LONG_MAX;
        for (int i = 0; i < 18; i++) if (freq[i] && freq[i] <= v) { v = freq[i]; c1 = i; }
        v = LONG_MAX;
        for (int i = 0; i < 18; i++) if (freq[i] && freq[i] <= v && i != c1) { v = freq[i]; c2 = i; }
        if (c2 < 0) break;
        freq[c1] += freq[c2]; freq[c2] = 0;
        codesize[c1]++; while (others[c1] >= 0) { c1 = others[c1]; codesize[c1]++; }
        others[c1] = c2;
        codesize[c2]++; while (others[c2] >= 0) { c2 = others[c2]; codesize[c2]++; }
    }
    int count[33] = {0};
    for (int i = 0; i < 18; i++) if (codesize[i]) count[codesize[i]]++;
    for (int i = 32; i > 16; i--) while (count[i] > 0) {
        int j = i - 2; while (count[j] == 0) j--;
        count[i] -= 2; count[i - 1]++; count[j + 1] += 2; count[j]--;
    }
    int longest = 16; while (count[longest] == 0) longest--;
    count[longest]--; // drop the reserved symbol
    memset(bits, 0, 17);
    for (int i = 1; i <= 16; i++) bits[i] = (uint8_t)count[i];
    int n = 0;
    for (int length = 1; length <= 32; length++) for (int s = 0; s < 17; s++) if (codesize[s] == length) values[n++] = (uint8_t)s;
    *value_count = n;
}

size_t cdng_lossless_jpeg(const uint16_t *samples, int width, int height, int components, uint8_t *destination, size_t destination_size) {
    if (!samples || width <= 0 || height <= 0 || width > 65535 || height > 65535 || components < 1 || components > 4) return 0;
    long frequencies[17] = {0};
    #define DIFFERENCE(x, y, c) ({ \
        int s = samples[((size_t)(y) * width + (x)) * components + (c)]; \
        int p = (x) > 0 ? samples[((size_t)(y) * width + (x) - 1) * components + (c)] : (y) > 0 ? samples[((size_t)(y) - 1) * width * components + (c)] : 32768; \
        int d = (s - p) & 0xFFFF; d >= 32768 ? d - 65536 : d; })
    for (int y = 0; y < height; y++) for (int x = 0; x < width; x++) for (int c = 0; c < components; c++) frequencies[category(DIFFERENCE(x, y, c))]++;
    uint8_t bits[17], values[17]; int value_count = 0;
    huffman_table(frequencies, bits, values, &value_count);
    uint16_t codes[17] = {0}; uint8_t lengths[17] = {0};
    int code = 0, k = 0;
    for (int length = 1; length <= 16; length++) {
        for (int i = 0; i < bits[length]; i++) { codes[values[k]] = (uint16_t)code++; lengths[values[k]] = (uint8_t)length; k++; }
        code <<= 1;
    }
    bit_writer w = { destination, destination_size, 0, 0, 0, 0 };
    put_marker(&w, 0xD8);
    put_marker(&w, 0xC4); put_word(&w, 2 + 1 + 16 + value_count); put_byte(&w, 0x00);
    for (int i = 1; i <= 16; i++) put_byte(&w, bits[i]);
    for (int i = 0; i < value_count; i++) put_byte(&w, values[i]);
    put_marker(&w, 0xC3); put_word(&w, 8 + 3 * components); put_byte(&w, 16); put_word(&w, height); put_word(&w, width); put_byte(&w, (uint8_t)components);
    for (int c = 0; c < components; c++) { put_byte(&w, (uint8_t)c); put_byte(&w, 0x11); put_byte(&w, 0); }
    put_marker(&w, 0xDA); put_word(&w, 6 + 2 * components); put_byte(&w, (uint8_t)components);
    for (int c = 0; c < components; c++) { put_byte(&w, (uint8_t)c); put_byte(&w, 0x00); }
    put_byte(&w, 1); put_byte(&w, 0); put_byte(&w, 0); // predictor 1, Se, Ah/Al
    for (int y = 0; y < height && !w.overflow; y++) for (int x = 0; x < width; x++) for (int c = 0; c < components; c++) {
        int d = DIFFERENCE(x, y, c), ssss = category(d);
        put_bits(&w, codes[ssss], lengths[ssss]);
        if (ssss && ssss < 16) put_bits(&w, (uint32_t)(d < 0 ? d - 1 : d) & ((1u << ssss) - 1), ssss);
    }
    #undef DIFFERENCE
    if (w.bits) put_bits(&w, 0x7F, 8 - w.bits); // pad with ones
    put_marker(&w, 0xD9);
    return w.overflow ? 0 : w.used;
}
