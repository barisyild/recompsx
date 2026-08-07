/* cstub.h — a stand-in for src/backend/api/backend_c_api.h, used by the M0-VERIFY spike to
 * prove the Haxe -> flat-C binding works exactly as docs/specs/backend.md assumes. */
#ifndef RECOMPSX_CSTUB_H
#define RECOMPSX_CSTUB_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

void     stub_log(int level, const char* msg);
int      stub_sum_u16(const uint16_t* data, int count);
void     stub_fill_u8(uint8_t* data, int count, int value);
uint64_t stub_mix64(uint64_t a, uint64_t b);

#ifdef __cplusplus
}
#endif
#endif
