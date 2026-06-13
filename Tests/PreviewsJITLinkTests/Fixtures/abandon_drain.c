#include <stdint.h>

extern int32_t previewsmcp_absent_symbol(void);

static char drain_bss[900u << 20];

int32_t abandon_drain_entry(void) {
  drain_bss[0] = 1;
  return previewsmcp_absent_symbol() + drain_bss[0];
}
