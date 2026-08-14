CXXFLAGS ?= -O2 -Wall -Wextra
CXXFLAGS += -std=c++14

radiomon: radiomon.cpp radio_regs.h plot_lib.hpp
	$(CXX) $(CXXFLAGS) -o $@ radiomon.cpp -lm

clean:
	rm -f radiomon
