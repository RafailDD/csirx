# Unit tests for the CSI-2 receiver (Icarus Verilog)
#
#   make test          build and run all self-checking testbenches
#   make <name>        run one testbench, e.g. `make wordalign`
#   make replay        replay the camera dump through pckthandler (slow, manual)
#   make VCD=1 <name>  also dump waveforms to build/<name>.vcd
#
# Testbenches run from unit_tests/ since they read their vector files from there.

IVERILOG := iverilog -g2012 -Wall -Wno-timescale
VVP := vvp -n
BUILDDIR := build

HDL_DIR ?= hdl
HDL := $(wildcard $(HDL_DIR)/*.v)
TB_INCLUDES := unit_tests/tb_common.vh unit_tests/csi_ref.vh

TESTS := ecc_block ph_finder raw10_decoder pckthandler_fsm pckthandler wordalign axi_csi

VVP_ARGS = $(if $(VCD),+vcd=../$(BUILDDIR)/$@.vcd)

.PHONY: all test clean replay $(TESTS)

all: test

test: $(TESTS)
	@echo "All $(words $(TESTS)) testbenches passed."

$(TESTS): %: $(BUILDDIR)/%_tb
	cd unit_tests && $(VVP) ../$< $(VVP_ARGS)

replay: $(BUILDDIR)/pckthandler_tb2
	cd unit_tests && $(VVP) ../$<

$(BUILDDIR)/%: unit_tests/%.v $(HDL) $(TB_INCLUDES) | $(BUILDDIR)
	$(IVERILOG) -y $(HDL_DIR) -I unit_tests -o $@ $<

$(BUILDDIR):
	mkdir -p $@

clean:
	rm -rf $(BUILDDIR)
