/* Self-checking testbench for ecc_block.v
 *
 * 1. Replays the vectors in ecc_block_testvec.txt (PH_in, PH_out_exp, error_exp).
 * 2. For a set of edge-case and random headers, checks against the reference
 *    ECC in csi_ref.vh:
 *    - an intact header is reported as no_error and passed through
 *    - every single-bit error in the 24 data bits is corrected
 *    - every double-bit error anywhere in the 32-bit header is detected
 *    - single-bit errors in the ECC byte never corrupt the data
 *
 * Gedeon Nyengele <nyengele@stanford.edu>
 */

`timescale 1ns/1ps

module ecc_block_tb;
	`include "tb_common.vh"
	`include "csi_ref.vh"

	reg [31:0] PH_in;
	wire [23:0] PH_out;
	wire no_error, corrected_error, error;

	reg [23:0] PH_out_exp;
	reg error_exp;

	integer fd, status, nvec;
	reg [128*8-1:0] vecstr;

	integer n, i, j;
	reg [23:0] data;
	reg [31:0] header;

	ecc_block DUT(.PH_in(PH_in), .PH_out(PH_out), .no_error(no_error),
		.corrected_error(corrected_error), .error(error));

	// Apply a header and check all outputs against expectations
	task check_header;
		input [31:0] ph;
		input [23:0] exp_data;
		input [2:0] exp_flags; // {no_error, corrected_error, error}
		begin
			PH_in = ph;
			#1;
			`CHECK_EQ(PH_out, exp_data, "PH_out")
			`CHECK_EQ({no_error, corrected_error, error}, exp_flags, "{no_error, corrected_error, error}")
		end
	endtask

	// Run every error class for one data word
	task check_data_word;
		input [23:0] d;
		begin
			header = {csi_ecc(d), d};

			// Intact header
			check_header(header, d, 3'b100);

			// Single-bit error in a data bit: corrected
			for (i = 0; i < 24; i = i + 1)
				check_header(header ^ (32'd1 << i), d, 3'b010);

			// Single-bit error in the ECC byte: data must pass through unmodified.
			// NOTE: CSI-2 says these are correctable, but ecc_block reports them as
			// uncorrectable (and pckthandler drops the packet). We only check that
			// the error is not mis-"corrected" into the data and not reported as clean.
			for (i = 24; i < 32; i = i + 1) begin
				PH_in = header ^ (32'd1 << i);
				#1;
				`CHECK_EQ(PH_out, d, "PH_out with ECC bit error")
				`CHECK_EQ(no_error, 1'b0, "no_error with ECC bit error")
				`CHECK_EQ(corrected_error ^ error, 1'b1, "exactly one error flag with ECC bit error")
			end

			// Any double-bit error: detected, never "corrected"
			for (i = 0; i < 32; i = i + 1)
				for (j = i + 1; j < 32; j = j + 1) begin
					PH_in = header ^ (32'd1 << i) ^ (32'd1 << j);
					#1;
					`CHECK_EQ({no_error, corrected_error, error}, 3'b001, "flags with double-bit error")
				end
		end
	endtask

	initial begin
		PH_in = 0;

		// Part 1: vector file
		nvec = 0;
		fd = $fopen("ecc_block_testvec.txt", "r");
		if (fd == 0) $fatal(1, "Could not open ecc_block_testvec.txt (run from unit_tests/)");
		while (!$feof(fd)) begin
			status = $fgets(vecstr, fd);
			if ($sscanf(vecstr, "%h, %h, %h", PH_in, PH_out_exp, error_exp) == 3) begin
				#1;
				`CHECK_EQ(PH_out, PH_out_exp, "vector PH_out")
				`CHECK_EQ(error, error_exp, "vector error")
				`CHECK_EQ(no_error | corrected_error | error, 1'b1, "vector flag set")
				nvec = nvec + 1;
			end
		end
		$fclose(fd);
		`CHECK(nvec > 0, "vector file contained vectors")

		// Part 2: reference model sanity - known headers from the vector file
		`CHECK_EQ(csi_header(8'h2B, 16'h0004), 32'h3400042B, "reference ECC for RAW10 WC=4")
		`CHECK_EQ(csi_header(8'h01, 16'h0000), 32'h07000001, "reference ECC for frame end")

		// Part 3: edge cases and random headers
		check_data_word(24'h000000);
		check_data_word(24'hFFFFFF);
		check_data_word(24'h000001);
		check_data_word(24'h800000);
		check_data_word(24'hAAAAAA);
		check_data_word(24'h555555);
		for (n = 0; n < 24; n = n + 1)
			check_data_word(24'd1 << n);
		for (n = 0; n < 200; n = n + 1) begin
			data = $random;
			check_data_word(data);
		end

		`TB_FINISH
	end
endmodule
