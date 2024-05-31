CC = c++
CFLAGS = --std=c++20 -Wall -Wextra -pedantic -Wformat=2 -Wfloat-equal -Wlogical-op -Wshift-overflow=2 -Wduplicated-cond -Wcast-qual -Wcast-align 
LIBS=-lsfml-graphics -lsfml-window -lsfml-system

SRCS = fleng.cpp
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

.PHONY: all clean debug prep release remake run

all: prep release run

debug: $(DBGEXE)

$(DBGEXE): $(DBGOBJS)
	$(CC) $(CFLAGS) $(DBGCFLAGS) $(LIBS) -o $(DBGEXE) $^

$(DBGDIR)/%.o: %.cpp
	$(CC) -c $(CFLAGS) $(DBGCFLAGS) -o $@ $<

release: $(RELEXE)

$(RELEXE): $(RELOBJS)
	$(CC) $(CFLAGS) $(RELCFLAGS) $(LIBS) -o $(RELEXE) $^

$(RELDIR)/%.o: %.cpp
	$(CC) -c $(CFLAGS) $(RELCFLAGS) -o $@ $<

run:
	$(RELEXE)

prep:
	@mkdir -p $(DBGDIR) $(RELDIR)

remake: clean all

clean:
	rm -f $(RELEXE) $(RELOBJS) $(DBGEXE) $(DBGOBJS)

