#include "gcd.h"

/* Dummy: returns 0 for every input. Replace with the binary GCD. */
uint32_t gcd_u32(uint32_t a, uint32_t b)
{
    if (a == 0)
        return b;
    if (b == 0)
        return a;

    unsigned shift = 0;

    // Implement binary GCD algorithm

    while ((a & 1u) == 0 && (b & 1u) == 0) {  // both a and b are even
        a >>= 1;
        b >>= 1;
        shift++;
    }

    while ((a & 1u) == 0) {  // a is even
        a >>= 1;
    }

    do {
        while ((b & 1u) == 0) {  // b is even
            b >>= 1;
        }
        if (a > b) {
            uint32_t temp = a;
            a = b;
            b = temp;
        }
        b = b - a;
    } while (b != 0);

    return a << shift;
}
