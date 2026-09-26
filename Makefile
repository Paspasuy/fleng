CC = c++
CFLAGS = --std=c++20 -Wall -Wextra -pedantic -Wformat=2 -Wfloat-equal -Wlogical-op -Wshift-overflow=2 -Wduplicated-cond -Wcast-qual -Wcast-align 
LIBS=-lsfml-graphics -lsfml-window -lsfml-system -lavcodec -lavformat -lswscale -lavutil

# Homebrew installs outside the default search paths on macOS
BREW_PREFIX := $(shell brew --prefix 2>/dev/null)
ifneq ($(BREW_PREFIX),)
CFLAGS += -I$(BREW_PREFIX)/include
LIBS += -L$(BREW_PREFIX)/lib
endif

# Water simulation core (Zig, sim/), linked as a static library.
SIMLIB = sim/zig-out/lib/libfleng_sim.a
SIMSRCS = $(wildcard sim/src/*.zig) sim/build.zig

ifeq ($(shell uname),Darwin)
CFLAGS += -DGL_SILENCE_DEPRECATION
LIBS += -framework OpenGL
else
LIBS += -lGL
endif

SRCS = src/fleng.cpp src/math.cpp
HEADERS = src/utils/*.hpp src/*.cpp src/*.hpp src/objects/*.hpp sim/include/*.h

OBJS = $(SRCS:.cpp=.o)
EXE  = fleng

DBGDIR = build/debug
DBGEXE = $(DBGDIR)/$(EXE)
DBGOBJS = $(addprefix $(DBGDIR)/, $(OBJS))
DBGCFLAGS = -O2 -g -D_GLIBCXX_DEBUG -D_GLIBCXX_DEBUG_PEDANTIC -D_FORTIFY_SOURCE=2 -fsanitize=address -fsanitize=undefined -fno-sanitize-recover -fstack-protector

RELDIR = build/release
RELEXE = $(RELDIR)/$(EXE)
RELOBJS = $(addprefix $(RELDIR)/, $(OBJS))
RELCFLAGS = -O3

.PHONY: all clean debug prepare release remake run

all: release run

debug: $(DBGEXE)

$(DBGEXE): $(DBGOBJS) $(SIMLIB)
	$(CC) $(CFLAGS) $(DBGCFLAGS) -o $(DBGEXE) $^ $(LIBS)

$(DBGDIR)/%.o: %.cpp $(HEADERS)
	@mkdir -p $(@D)
	$(CC) -c $(CFLAGS) $(DBGCFLAGS) -o $@ $<

release: $(RELEXE)

$(RELEXE): $(RELOBJS) $(SIMLIB)
	$(CC) $(CFLAGS) $(RELCFLAGS) -o $(RELEXE) $^ $(LIBS)

$(RELDIR)/%.o: %.cpp $(HEADERS)
	@mkdir -p $(@D)
	$(CC) -c $(CFLAGS) $(RELCFLAGS) -o $@ $<

ifeq ($(shell uname),Darwin)
# Build for an older macOS than the host so the linker doesn't warn.
ZIGTARGET = -Dtarget=native-macos.13.0 -Dcpu=native
endif

$(SIMLIB): $(SIMSRCS)
	cd sim && zig build -Doptimize=ReleaseFast $(ZIGTARGET)
ifeq ($(shell uname),Darwin)
	@# Apple's linker needs 8-byte aligned archive members, which Zig's archiver
	@# doesn't produce: unpack the archive and repack it with Apple's libtool.
	rm -rf $(SIMLIB).d && mkdir $(SIMLIB).d
	cd $(SIMLIB).d && ar x ../$(notdir $(SIMLIB)) && chmod 644 *.o && libtool -static -o ../$(notdir $(SIMLIB)) *.o
	rm -rf $(SIMLIB).d
endif

run:
	$(RELEXE)

prepare:
	@mkdir -p $(DBGDIR) $(RELDIR)
	@mkdir -p $(DBGDIR)/src $(RELDIR)/src
	@mkdir -p $(DBGDIR)/src/utils $(RELDIR)/src/utils
	#@ln -sf ../../shaders/ $(DBGDIR)
	#@ln -sf ../../shaders/ $(RELDIR)

pretty:
	find src/ -iname '*.hpp' -o -iname '*.cpp' | xargs clang-format -i

remake: clean all

clean:
	rm -f $(RELEXE) $(RELOBJS) $(DBGEXE) $(DBGOBJS)

