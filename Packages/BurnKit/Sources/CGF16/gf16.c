// Multiplying by a constant in GF(2^16) is linear, so a word's product is the XOR of the
// products of its four 4-bit pieces, each looked up in a 16-entry table. On ARM, NEON's
// table-lookup instruction does 16 of those lookups at once.

#include "CGF16.h"

#if defined(__aarch64__)
#include <arm_neon.h>
#endif

static void muladd_words(uint8_t *dst, const uint8_t *const *sources, const uint8_t *tables, size_t count,
                         size_t start, size_t bytes) {
    for (size_t i = start; i + 1 < bytes; i += 2) {
        uint8_t low = dst[i];
        uint8_t high = dst[i + 1];
        for (size_t s = 0; s < count; s++) {
            const uint8_t *t = tables + s * BK_GF16_TABLE_BYTES;
            uint8_t a = sources[s][i];
            uint8_t b = sources[s][i + 1];
            low ^= t[a & 15] ^ t[32 + (a >> 4)] ^ t[64 + (b & 15)] ^ t[96 + (b >> 4)];
            high ^= t[16 + (a & 15)] ^ t[48 + (a >> 4)] ^ t[80 + (b & 15)] ^ t[112 + (b >> 4)];
        }
        dst[i] = low;
        dst[i + 1] = high;
    }
}

void bk_gf16_muladd(uint8_t *dst, const uint8_t *const *sources, const uint8_t *tables, size_t count,
                    size_t bytes) {
    size_t i = 0;
#if defined(__aarch64__)
    const uint8x16_t mask = vdupq_n_u8(0x0F);
    // 32 bytes at a time: vld2q splits 16 words into their low bytes and their high bytes.
    for (; i + 32 <= bytes; i += 32) {
        uint8x16x2_t sum = vld2q_u8(dst + i);
        for (size_t s = 0; s < count; s++) {
            const uint8_t *t = tables + s * BK_GF16_TABLE_BYTES;
            uint8x16x2_t word = vld2q_u8(sources[s] + i);
            uint8x16_t n0 = vandq_u8(word.val[0], mask);
            uint8x16_t n1 = vshrq_n_u8(word.val[0], 4);
            uint8x16_t n2 = vandq_u8(word.val[1], mask);
            uint8x16_t n3 = vshrq_n_u8(word.val[1], 4);
            uint8x16_t low = veorq_u8(veorq_u8(vqtbl1q_u8(vld1q_u8(t), n0), vqtbl1q_u8(vld1q_u8(t + 32), n1)),
                                      veorq_u8(vqtbl1q_u8(vld1q_u8(t + 64), n2), vqtbl1q_u8(vld1q_u8(t + 96), n3)));
            uint8x16_t high = veorq_u8(veorq_u8(vqtbl1q_u8(vld1q_u8(t + 16), n0), vqtbl1q_u8(vld1q_u8(t + 48), n1)),
                                       veorq_u8(vqtbl1q_u8(vld1q_u8(t + 80), n2), vqtbl1q_u8(vld1q_u8(t + 112), n3)));
            sum.val[0] = veorq_u8(sum.val[0], low);
            sum.val[1] = veorq_u8(sum.val[1], high);
        }
        vst2q_u8(dst + i, sum);
    }
#endif
    muladd_words(dst, sources, tables, count, i, bytes);
}
