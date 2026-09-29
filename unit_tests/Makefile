# Convenience wrapper: the testbenches are built and run from the top-level Makefile.
#   make -C unit_tests test
#   make -C unit_tests wordalign

.PHONY: default
default: test

%:
	$(MAKE) -C .. $@
