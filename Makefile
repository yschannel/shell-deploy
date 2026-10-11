CXX := g++
CXXFLAGS := -std=c++17 -Wall -Wextra -Wpedantic -O2
TARGET := bin/app
SOURCE := src/main.cpp

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SOURCE) Makefile
	@mkdir -p bin
	$(CXX) $(CXXFLAGS) $(SOURCE) -o $(TARGET)

clean:
	rm -f -- $(TARGET)
