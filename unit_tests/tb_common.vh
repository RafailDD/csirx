/* Shared helpers for the self-checking testbenches.
 *
 * Each testbench `includes this file inside its module body. It provides
 * error/check counters, comparison macros that report mismatches, and a
 * TB_FINISH macro that prints a PASS/FAIL summary and exits with a non-zero
 * status (via $fatal) if anything failed, so `make test` can gate on it.
 */

integer tb_errors = 0;
integer tb_checks = 0;

// Optional waveform dump: vvp <sim> +vcd=<file>
reg [1023:0] tb_vcd_file;
initial
	if ($value$plusargs("vcd=%s", tb_vcd_file)) begin
		$dumpfile(tb_vcd_file);
		$dumpvars;
	end

// Compare two values with 4-state equality (X/Z never match a known value)
// (Macro parameter names are deliberately odd: some simulators substitute
// them inside string literals too.)
`define CHECK_EQ(a__, e__, w__) \
	begin \
		tb_checks = tb_checks + 1; \
		if ((a__) !== (e__)) begin \
			tb_errors = tb_errors + 1; \
			$display("FAIL @%0t: %0s: got 'h%h, expected 'h%h", $time, w__, a__, e__); \
		end \
	end

// Check that a condition holds
`define CHECK(c__, w__) \
	begin \
		tb_checks = tb_checks + 1; \
		if ((c__) !== 1'b1) begin \
			tb_errors = tb_errors + 1; \
			$display("FAIL @%0t: %0s", $time, w__); \
		end \
	end

`define TB_FINISH \
	begin \
		if (tb_errors == 0) begin \
			$display("PASS: %m (%0d checks)", tb_checks); \
			$finish; \
		end \
		else \
			$fatal(1, "FAIL: %m (%0d of %0d checks failed)", tb_errors, tb_checks); \
	end
