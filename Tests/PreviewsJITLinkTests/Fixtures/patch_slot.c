#include <stdint.h>

static int32_t impl_v1(void) { return 1; }
int32_t impl_v2(void) { return 2; }

int32_t (*patch_slot_fn)(void) = impl_v1;

int32_t patch_slot_call(void) { return patch_slot_fn(); }
