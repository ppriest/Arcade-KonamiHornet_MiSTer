// SPDX-License-Identifier: GPL-3.0-or-later
// sim/voodoo_tb against a SpinalVoodoo build in obj_voodoo/patched (rtl/voodoo/gen), for trying
// a patch before it is vendored into rtl/voodoo/spinalvoodoo.
#include "Vtb_voodoop.h"
#include "Vtb_voodoop___024root.h"
#define VTOP Vtb_voodoop
#define TBNAME tb_voodoop
#define TEXCHECK
#include "../voodoo_tb/main.cpp"
