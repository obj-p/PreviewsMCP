#include <stdint.h>

extern int32_t previewsmcp_absent_symbol(void);

static char slab_bss[200u << 20];

int32_t abandon_slab_entry(void) {
  slab_bss[0] = 1;
  return previewsmcp_absent_symbol() + slab_bss[0];
}
