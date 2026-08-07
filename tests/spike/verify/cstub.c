/* cstub.c — see cstub.h. Deliberately trivial; the point is the calling convention, not the code. */
#include "cstub.h"
#include <stdio.h>

void stub_log(int level, const char* msg) {
    printf("[cstub level=%d] %s\n", level, msg);
}

int stub_sum_u16(const uint16_t* data, int count) {
    int acc = 0;
    for (int i = 0; i < count; i++) acc += (int)data[i];
    return acc;
}

void stub_fill_u8(uint8_t* data, int count, int value) {
    for (int i = 0; i < count; i++) data[i] = (uint8_t)value;
}

uint64_t stub_mix64(uint64_t a, uint64_t b) {
    return a * b + 0x9E3779B97F4A7C15ULL;
}
