# Unit tests for the CSI-2 receiver (Icarus Verilog). See unit_tests/README.md.
#
#   make test             run every testbench, write logs + summary to build/
#   make list             list the testbenches
#   make <name>           run one testbench with its output on the terminal
#   make VCD=1 <name>     ...and dump waveforms to build/<name>.vcd
#   make waves T=<name>   dump waveforms and open them in GTKWave
#   make summary          print the summary of the last `make test`
#   make replay           replay the camera dump through pckthandler (slow, manual)
#   make clean            remove build/
#
# Testbenches run from unit_tests/ since they read their vector files from there.

IVERILOG := iverilog -g2012 -Wall -Wno-timescale
VVP := vvp -n
BUILDDIR := build

HDL_DIR ?= hdl
HDL := $(wildcard $(HDL_DIR)/*.v)
TB_INCLUDES := unit_tests/tb_common.vh unit_tests/csi_ref.vh

TESTS := ecc_block ph_finder raw10_decoder pckthandler_fsm pckthandler wordalign axi_csi

VVP_ARGS = $(if $(VCD),+vcd=$(abspath $(BUILDDIR))/$@.vcd)

.PHONY: all test list summary waves clean replay $(TESTS)

all: test

test:
	@BUILDDIR=$(BUILDDIR) TESTS="$(TESTS)" MAKE="$(MAKE)" unit_tests/run_tests.sh

list:
	@for t in $(TESTS); do echo "$$t  (unit_tests/$${t}_tb.v)"; done

summary:
	@cat $(BUILDDIR)/test_summary.txt 2>/dev/null || echo "No results yet: run 'make test'."

waves:
	@test -n "$(T)" || { echo "Usage: make waves T=<test>   (see 'make list')"; exit 2; }
	-$(MAKE) --no-print-directory VCD=1 $(T)
	@if command -v gtkwave >/dev/null 2>&1; then \
		gtkwave $(BUILDDIR)/$(T).vcd >/dev/null 2>&1 & \
	else \
		echo "Waveforms written to $(BUILDDIR)/$(T).vcd (install GTKWave, or open it in any VCD viewer)"; \
	fi

$(TESTS): %: $(BUILDDIR)/%_tb
	cd unit_tests && $(VVP) $(abspath $<) $(VVP_ARGS)

replay: $(BUILDDIR)/pckthandler_tb2
	cd unit_tests && $(VVP) $(abspath $<)

$(BUILDDIR)/%: unit_tests/%.v $(HDL) $(TB_INCLUDES) | $(BUILDDIR)
	$(IVERILOG) -y $(HDL_DIR) -I unit_tests -o $@ $<

$(BUILDDIR):
	mkdir -p $@

clean:
	rm -rf $(BUILDDIR)
