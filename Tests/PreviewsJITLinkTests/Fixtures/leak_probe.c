#include <stdint.h>

static char leak_probe_bss[200u << 20];

int32_t leak_probe_value(void) {
  leak_probe_bss[0] = 7;
  return leak_probe_bss[0] + 35;
}
