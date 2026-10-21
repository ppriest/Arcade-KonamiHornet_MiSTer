# arcsnd's native benches. Run from an MSYS2 MINGW64 shell (or with its bin first on PATH).
#   make hornet_bench   the Hornet board against a MAME capture (hornet/bench.cpp)
CC       ?= gcc
CXX      ?= g++
CFLAGS   ?= -O2
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wno-sign-compare
OUT      ?= ../../obj_arcsnd

MUSASHI = hornet/musashi/m68kcpu.c hornet/musashi/m68kops.c hornet/musashi/m68kdasm.c hornet/musashi/softfloat/softfloat.c
MUSASHI_O = $(patsubst %.c,$(OUT)/%.o,$(notdir $(MUSASHI)))
HORNET = hornet/board.cpp hornet/rf5c400.cpp common/logerror.cpp

hornet_bench: $(OUT)/hornet_bench

$(OUT)/%.o: hornet/musashi/%.c
	mkdir -p $(OUT)
	$(CC) $(CFLAGS) -Ihornet/musashi -c -o $@ $<
$(OUT)/softfloat.o: hornet/musashi/softfloat/softfloat.c
	mkdir -p $(OUT)
	$(CC) $(CFLAGS) -Ihornet/musashi -c -o $@ $<

$(OUT)/hornet_bench: $(HORNET) hornet/bench.cpp $(wildcard hornet/*.h common/*.h) $(MUSASHI_O)
	$(CXX) $(CXXFLAGS) -Ihornet -Icommon -o $@ $(HORNET) hornet/bench.cpp $(MUSASHI_O)

.PHONY: hornet_bench
