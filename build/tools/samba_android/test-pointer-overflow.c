/* Compile on the PC against the patched Samba headers, then execute on Android. */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "lib/util/overflow.h"

int main(void)
{
    uint8_t *p = malloc(256);
    assert(p != NULL);
    assert(!ptr_overflow(p, 0, uint8_t));
    assert(!ptr_overflow(p, 56, uint8_t));
    assert(ptr_overflow(p, UINTPTR_MAX, uint8_t));
    assert(ptr_overflow(p, UINTPTR_MAX, uint64_t));
    const uintptr_t address_max = UINTPTR_MAX >> 8;
    for (uintptr_t tag = 0; tag <= 255; tag++) {
        uintptr_t near_end = (tag << 56) | (address_max - 15);
        uint8_t *tagged = (uint8_t *)near_end;
        assert(!ptr_overflow(tagged, 15, uint8_t));
        assert(ptr_overflow(tagged, 16, uint8_t));
        assert(!ptr_overflow(tagged, 1, uint64_t));
        assert(ptr_overflow(tagged, 2, uint64_t));
        assert(ptr_overflow(tagged, -1, uint8_t));
    }
    printf("PASS tagged heap pointer %p and 256 tag/boundary cases\n", p);
    free(p);
    return 0;
}
