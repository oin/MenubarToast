CC = clang
CFLAGS = -Wall -Wextra -O2 -fobjc-arc
FRAMEWORKS = -framework AppKit -framework QuartzCore -framework Foundation
TARGET = MenubarToast
SRC = MenubarToast.m

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) $(FRAMEWORKS) -o $(TARGET) $(SRC)

clean:
	rm -f $(TARGET)

.PHONY: clean
