/* Data-based testbench for pckthandler.v
 * This test pushes part of a real data dump from the byte aligner (image4.bin)
 * through the packet handler and writes the payload to image4_out.bin, which
 * can be inspected with viewdump.py.
 *
 * It also checks structural properties of the output: frame_valid only inside
 * frame_active, and every output line (burst of frame_valid) has the same length.
 *
 * NOTE: image4.bin predates the current packet handler. It is a continuous
 * byte stream without LP gaps (din_valid never drops), so ph_finder only ever
 * sees the first "header", and the stream contains no well-formed CSI-2 headers
 * for the IMX219 line length. With the current RTL no lines are decoded; this
 * testbench is kept as a manual tool (`make replay`) and is not part of
 * `make test`. The self-checking tests are pckthandler_tb.v and axi_csi_tb.v.
 *
 * Steven Bell <sebell@stanford.edu>
 * 22 January 2018
 */

`timescale 1ns/1ps

module pckthandler_tb2;
	`include "tb_common.vh"

	reg clk, reset, din_valid;
	reg [7:0] char_in; // Used to get data byte-by-byte
	reg [15:0] din;
	wire fr_active, fr_valid, last_packet;
	wire [15:0] dout;

	integer infile, outfile, count, stat;
	integer lines, line_words, first_line_words, frames_started;
	reg prev_fr_valid, prev_fr_active;

	pckthandler DUT(.rxbyteclkhs(clk), .reset(reset), .in_stream(din), .in_stream_valid(din_valid),
		.out_stream(dout), .frame_active(fr_active), .frame_valid(fr_valid),
		.lines_per_frame(32'd0), .last_packet(last_packet));

	initial clk = 0;
	always #10 clk = ~clk;

	// Track output structure
	always @(negedge clk) if (!reset) begin
		if (fr_valid) begin
			`CHECK_EQ(fr_active, 1'b1, "frame_valid implies frame_active")
			line_words = line_words + 1;
		end
		else if (prev_fr_valid) begin
			// End of an output line
			if (lines == 0) first_line_words = line_words;
			else `CHECK_EQ(line_words, first_line_words, "all lines have the same length")
			lines = lines + 1;
			line_words = 0;
		end
		if (fr_active && !prev_fr_active) frames_started = frames_started + 1;
		prev_fr_valid = fr_valid;
		prev_fr_active = fr_active;
	end

	initial begin
		din = 0; din_valid = 0; reset = 1;
		count = 0; lines = 0; line_words = 0; first_line_words = 0; frames_started = 0;
		prev_fr_valid = 0; prev_fr_active = 0;
		infile = $fopen("image4.bin", "rb");
		if (infile == 0) $fatal(1, "Could not open image4.bin (run from unit_tests/)");
		outfile = $fopen("image4_out.bin", "wb");
		repeat(2) @(posedge clk);
		@(negedge clk) reset = 0;

		while (!$feof(infile)) begin
			stat = $fread(char_in, infile); // Read the first input byte
			din[15:8] = char_in;
			stat = $fread(char_in, infile); // Read the second byte
			din[7:0] = char_in;
			din_valid = 1; // Always valid

			// Wait for the next cycle
			@(posedge clk);
			#1;

			// Write the output bytes if they are valid
			if (fr_valid)
				$fwrite(outfile, "%c%c", dout[15:8], dout[7:0]);

			// Print some progress
			if (count % 32'h10000 == 0)
				$display("count: %x  din: %x fr_active: %d, fr_valid: %d", count, din, fr_active, fr_valid);
			count = count + 1;
		end
		$fclose(infile);
		$fclose(outfile);

		$display("frames started: %0d, lines: %0d, words per line: %0d", frames_started, lines, first_line_words);
		`TB_FINISH
	end
endmodule
