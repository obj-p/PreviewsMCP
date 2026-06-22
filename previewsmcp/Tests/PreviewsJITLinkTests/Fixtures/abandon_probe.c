#include <stdint.h>

static char probe_bss[300u << 20];

int32_t abandon_probe_value(void) {
  probe_bss[0] = 42;
  return probe_bss[0];
}
