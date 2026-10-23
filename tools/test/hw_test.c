/* Compiles firmware/include/hw.h and checks names against values quoted in the specs,
   and CPORT against the _P names (spec 3, section 9, test 11). Run by tools/Makefile. */
#include "hw.h"

#define CHECK(x) _Static_assert(x, #x)

CHECK(SYSID == 0x70);
CHECK(SYSID_P == 0x7000);
CHECK(BGCOLOR_P == 0x0410);
CHECK(SERDATA_PORT == 0x53);
CHECK(REGS_CUSTOM == 0x1000);
CHECK(MMU0W_1 == 0x91);
CHECK(L1_BPL0PT2 == 0x0C6);
CHECK(INTENA_SETCLR_M == 0x80);
CHECK(DMX_CTRL_DSTKIND_M == 0x18000UL);
CHECK(DMX_VALUE_N == 4);

/* CPORT gives the same ports as the _P names */
CHECK(CPORT(BGCOLOR) == BGCOLOR_P);
CHECK(CPORT(SPR0 + SPR_H) == SPR0_H_P);
CHECK(CPORT(L2_PATPT2) == L2_PATPT2_P);
CHECK(CPORT(COPCON) == 0x0011);
CHECK(CPORT(DMX3_CHERR) == DMX3_CHERR_P);
CHECK(CPORT(DMXINTEN) == 0x3412);

int main(void) { return 0; }
