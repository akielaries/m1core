# builds every application and test
SUBDIRS := apps/blink apps/hello tests/isa

.PHONY: all clean $(SUBDIRS)

all clean:
	@for d in $(SUBDIRS); do $(MAKE) --no-print-directory -C $$d $@ || exit 1; done
