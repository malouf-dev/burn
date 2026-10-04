#ifndef CGF16_H
#define CGF16_H

#include <stddef.h>
#include <stdint.h>

/// Bytes of tables per source: for each of the four 4-bit pieces of a word, the product's low
/// byte and high byte for all 16 values of that piece.
#define BK_GF16_TABLE_BYTES 128

/// For 16-bit little-endian words: dst[i] ^= factor[s] × sources[s][i], summed over `count`
/// sources, in GF(2^16). `tables` holds `count` blocks of BK_GF16_TABLE_BYTES, one per source,
/// which encode its factor. `bytes` must be even, and every source must be that long.
void bk_gf16_muladd(uint8_t *dst, const uint8_t *const *sources, const uint8_t *tables, size_t count,
                    size_t bytes);

#endif
