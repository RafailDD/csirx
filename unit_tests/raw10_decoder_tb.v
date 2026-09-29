/* Self-checking testbench for raw10_decoder.v
 *
 * 1. Replays raw10_decoder_testvec.txt (din, fr_active, fr_valid, dout_exp, valid_exp);
 *    outputs are checked one clock after each input is applied.
 * 2. Streams randomly generated RAW10 lines (packed as in the CSI-2 spec) through
 *    the decoder and compares every output beat against the original pixels,
 *    including the last_packet_in -> last_packet_out pipeline.
 * 3. Checks that dropping frame_valid mid-group or resetting re-aligns the decoder.
 */

`timescale 1ns/1ps

module raw10_decoder_tb;
	`include "tb_common.vh"

	reg clk, reset, frame_active, frame_valid, last_in;
	reg [15:0] din;

	wire [63:0] dout;
	wire valid, last_out;

	reg [63:0] dout_exp;
	reg valid_exp;

	integer fd, status, nvec;
	reg [128*8-1:0] vecstr;

	// Pixel/byte buffers for the randomized test
	reg [9:0] pixels[0:1023];
	reg [7:0] bytes[0:2047];
	integer npix, nbytes, nwords, p, w, line;

	// Output monitor
	reg monitor_en;
	integer beats, last_beats, last_beat_idx;
	reg [63:0] beat_log[0:255];

	raw10_decoder DUT(.rxbyteclkhs(clk), .reset(reset), .data_in(din),
		.frame_active(frame_active), .frame_valid(frame_valid),
		.data_out(dout), .out_valid(valid),
		.last_packet_in(last_in), .last_packet_out(last_out));

	initial clk = 0;
	always #10 clk = ~clk;

	// Sample outputs between clock edges
	always @(negedge clk) if (monitor_en) begin
		if (valid) begin
			beat_log[beats] = dout;
			if (last_out) begin
				last_beats = last_beats + 1;
				last_beat_idx = beats;
			end
			beats = beats + 1;
		end
		else begin
			`CHECK_EQ(dout, 64'd0, "data_out is zero when out_valid is low")
			`CHECK_EQ(last_out, 1'b0, "last_packet_out only with a valid beat")
		end
	end

	// Generate npix random pixels and pack them into RAW10 bytes
	task make_line;
		input integer num_pixels;
		integer k;
		begin
			npix = num_pixels;
			nbytes = 0;
			for (k = 0; k < npix; k = k + 1)
				pixels[k] = $random;
			for (k = 0; k < npix; k = k + 4) begin
				bytes[nbytes + 0] = pixels[k + 0][9:2];
				bytes[nbytes + 1] = pixels[k + 1][9:2];
				bytes[nbytes + 2] = pixels[k + 2][9:2];
				bytes[nbytes + 3] = pixels[k + 3][9:2];
				bytes[nbytes + 4] = {pixels[k + 3][1:0], pixels[k + 2][1:0],
				                     pixels[k + 1][1:0], pixels[k + 0][1:0]};
				nbytes = nbytes + 5;
			end
			nwords = (nbytes + 1) / 2;
			bytes[nbytes] = 8'hEE; // padding byte if the length is odd
		end
	endtask

	// Stream the packed line, marking the final word with last_packet_in
	task send_line;
		input mark_last;
		begin
			for (w = 0; w < nwords; w = w + 1) begin
				@(posedge clk);
				din <= {bytes[2*w], bytes[2*w + 1]};
				frame_active <= 1; frame_valid <= 1;
				last_in <= mark_last && (w == nwords - 1);
			end
			@(posedge clk);
			frame_valid <= 0; last_in <= 0; din <= 16'hDEAD;
			repeat(3) @(posedge clk);
		end
	endtask

	// Compare captured beats with the pixels of the current line
	task check_line;
		input expect_last;
		integer b;
		begin
			`CHECK_EQ(beats, npix / 4, "number of output beats")
			for (b = 0; b < beats && b < npix / 4; b = b + 1)
				`CHECK_EQ(beat_log[b], {6'd0, pixels[4*b + 3], 6'd0, pixels[4*b + 2],
				                        6'd0, pixels[4*b + 1], 6'd0, pixels[4*b + 0]}, "decoded pixels")
			if (expect_last) begin
				`CHECK_EQ(last_beats, 1, "exactly one last_packet_out beat")
				`CHECK_EQ(last_beat_idx, beats - 1, "last_packet_out on final beat")
			end
			else
				`CHECK_EQ(last_beats, 0, "no last_packet_out")
		end
	endtask

	task clear_monitor;
		begin
			beats = 0; last_beats = 0; last_beat_idx = -1;
		end
	endtask

	initial begin
		din = 0; frame_valid = 0; frame_active = 0; last_in = 0; reset = 1;
		monitor_en = 0;
		clear_monitor;
		repeat(2) @(posedge clk);
		@(negedge clk) reset = 0;

		// Part 1: vector file
		nvec = 0;
		fd = $fopen("raw10_decoder_testvec.txt", "r");
		if (fd == 0) $fatal(1, "Could not open raw10_decoder_testvec.txt (run from unit_tests/)");
		while (!$feof(fd)) begin
			status = $fgets(vecstr, fd);
			if ($sscanf(vecstr, "%h, %h, %h, %h, %h", din, frame_active, frame_valid, dout_exp, valid_exp) == 5) begin
				@(posedge clk); #1;
				`CHECK_EQ(dout, dout_exp, "vector dout")
				`CHECK_EQ(valid, valid_exp, "vector out_valid")
				`CHECK_EQ(last_out, 1'b0, "vector last_packet_out")
				nvec = nvec + 1;
			end
		end
		$fclose(fd);
		`CHECK(nvec > 0, "vector file contained vectors")
		@(negedge clk);
		frame_active = 0; frame_valid = 0;
		repeat(2) @(posedge clk);

		// Part 2: random lines of various widths (multiples of 4 pixels)
		monitor_en = 1;
		for (line = 0; line < 40; line = line + 1) begin
			clear_monitor;
			make_line(4 * (1 + ($unsigned($random) % 40)));
			send_line(line % 3 == 0);
			check_line(line % 3 == 0);
		end

		// Part 3: frame_active low blocks output even with frame_valid high
		clear_monitor;
		make_line(16);
		for (w = 0; w < nwords; w = w + 1) begin
			@(posedge clk);
			din <= {bytes[2*w], bytes[2*w + 1]};
			frame_active <= 0; frame_valid <= 1; last_in <= 1;
		end
		@(posedge clk) frame_valid <= 0; last_in <= 0;
		repeat(3) @(posedge clk);
		`CHECK_EQ(beats, 0, "no output without frame_active")

		// Part 4: abort a line mid-group; the next line must decode cleanly
		clear_monitor;
		make_line(8);
		for (w = 0; w < 4; w = w + 1) begin
			@(posedge clk);
			din <= {bytes[2*w], bytes[2*w + 1]};
			frame_active <= 1; frame_valid <= 1;
		end
		@(posedge clk) frame_valid <= 0;
		repeat(2) @(posedge clk);
		clear_monitor;
		make_line(12);
		send_line(1);
		check_line(1);

		// Part 5: synchronous reset mid-line also re-aligns
		clear_monitor;
		make_line(8);
		for (w = 0; w < 3; w = w + 1) begin
			@(posedge clk);
			din <= {bytes[2*w], bytes[2*w + 1]};
			frame_active <= 1; frame_valid <= 1;
		end
		@(posedge clk) reset <= 1; last_in <= 1;
		@(posedge clk) reset <= 0; frame_valid <= 0; last_in <= 0;
		repeat(2) @(posedge clk);
		clear_monitor;
		make_line(8);
		send_line(0);
		check_line(0);

		`TB_FINISH
	end
endmodule
