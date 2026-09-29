/* Self-checking testbench for ph_finder module
 *
 * 1. Replays ph_finder_testvec.txt (din, din_valid, dout_exp, valid_exp, ph_select_exp);
 *    outputs are checked one clock after each input is applied.
 * 2. Directed tests: header re-acquisition after din_valid drops, synchronous
 *    reset in the middle of a packet, and a long bypass run.
 *
 * Gedeon Nyengele <nyengele@stanford.edu>
 * Jan 12 2018
 */

`timescale 1ns/1ps

module ph_finder_tb;
	`include "tb_common.vh"

	reg clk, reset, din_valid;
	reg [15:0] din;
	wire [31:0] dout;
	wire dout_valid, ph_select;

	integer fd, status, nvec, n;
	reg [128*8-1:0] vecstr;
	reg [31:0] d_exp;
	reg v_exp, ph_exp;

	ph_finder DUT(.rxbyteclkhs(clk), .reset(reset), .din(din), .din_valid(din_valid),
		.dout(dout), .dout_valid(dout_valid), .ph_select(ph_select));

	initial clk = 0;
	always #10 clk = ~clk;

	// Drive one input word, clock it in, and check the registered outputs
	task step;
		input [15:0] d;
		input v;
		input [31:0] exp_dout;
		input exp_valid, exp_ph;
		begin
			din = d; din_valid = v;
			@(posedge clk); #1;
			`CHECK_EQ(dout, exp_dout, "dout")
			`CHECK_EQ(dout_valid, exp_valid, "dout_valid")
			`CHECK_EQ(ph_select, exp_ph, "ph_select")
		end
	endtask

	initial begin
		din = 0; din_valid = 1; reset = 1;
		repeat(2) @(posedge clk);
		#1;
		`CHECK_EQ({dout, dout_valid, ph_select}, 34'd0, "outputs in reset")
		@(negedge clk) reset = 0;

		// Part 1: vector file
		nvec = 0;
		fd = $fopen("ph_finder_testvec.txt", "r");
		if (fd == 0) $fatal(1, "Could not open ph_finder_testvec.txt (run from unit_tests/)");
		while (!$feof(fd)) begin
			status = $fgets(vecstr, fd);
			if ($sscanf(vecstr, "%h, %h, %h, %h, %h", din, din_valid, d_exp, v_exp, ph_exp) == 5) begin
				step(din, din_valid, d_exp, v_exp, ph_exp);
				nvec = nvec + 1;
			end
		end
		$fclose(fd);
		`CHECK(nvec > 0, "vector file contained vectors")

		// Part 2: din_valid low for one cycle restarts header search
		step(16'h0000, 1'b0, 32'h0, 1'b0, 1'b0);
		step(16'h2B10, 1'b1, 32'h0, 1'b0, 1'b0);
		step(16'h0098, 1'b1, 32'h9800102B, 1'b1, 1'b1);
		step(16'hA1A2, 1'b1, 32'hA1A20000, 1'b1, 1'b0);
		step(16'hB1B2, 1'b0, 32'h0, 1'b0, 1'b0);
		step(16'hC1C2, 1'b1, 32'h0, 1'b0, 1'b0);
		step(16'hD1D2, 1'b1, 32'hD2D1C2C1, 1'b1, 1'b1);

		// Part 3: synchronous reset mid-packet also restarts header search
		step(16'hE1E2, 1'b1, 32'hE1E20000, 1'b1, 1'b0);
		reset = 1;
		step(16'hF1F2, 1'b1, 32'h0, 1'b0, 1'b0);
		step(16'hF3F4, 1'b1, 32'h0, 1'b0, 1'b0);
		reset = 0;
		step(16'h0102, 1'b1, 32'h0, 1'b0, 1'b0);
		step(16'h0304, 1'b1, 32'h04030201, 1'b1, 1'b1);

		// Part 4: header only captured once; everything after is bypassed
		for (n = 0; n < 64; n = n + 1)
			step(n * 16'h0101 + 16'h0001, 1'b1, {n * 16'h0101 + 16'h0001, 16'h0000}, 1'b1, 1'b0);

		// Part 5: reset while din_valid is low
		reset = 1;
		step(16'hFFFF, 1'b0, 32'h0, 1'b0, 1'b0);
		reset = 0;
		step(16'h1111, 1'b1, 32'h0, 1'b0, 1'b0);
		step(16'h2222, 1'b1, 32'h22221111, 1'b1, 1'b1);

		`TB_FINISH
	end
endmodule
