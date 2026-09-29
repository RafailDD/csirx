/* Self-checking testbench for pckthandler_fsm.v
 *
 * 1. Replays pckthandler_fsm_testvec.txt
 *    (data_stream, ph_stream, valid_stream, ph_select, out_exp, fr_active_exp, fr_valid_exp);
 *    outputs are checked one clock after each input is applied.
 * 2. Directed packet-level tests driven the way ph_finder presents packets
 *    (one header cycle with ph_select, then payload words, then a gap), with an
 *    output monitor that records every word emitted while frame_valid is high.
 *    Covers: frame start/end, embedded-data and unknown packets, pixel data
 *    outside a frame, ECC-errored headers, odd and zero word counts,
 *    lines_per_frame/last_packet, and reset in the middle of a packet.
 */

`timescale 1ns/1ps

module pckthandler_fsm_tb;
	`include "tb_common.vh"

	localparam DT_FS = 8'h00, DT_FE = 8'h01, DT_EMBED = 8'h12, DT_RAW10 = 8'h2B, DT_RAW8 = 8'h2A;

	reg clk, reset;
	reg [15:0] data_stream;
	reg [23:0] ph_stream;
	reg ph_select, valid_stream, ecc_error;
	reg [31:0] lines_per_frame;

	wire [15:0] out_stream;
	wire frame_active, frame_valid, last_packet;

	integer fd, status, nvec;
	reg [128*8-1:0] vecstr;
	reg [15:0] out_exp;
	reg fr_active_exp, fr_valid_exp;

	// Scoreboard: expected output words (in order) and index of last_packet word
	reg [15:0] exp_words[0:4095];
	integer n_exp, exp_last_idx;
	// Monitor: captured output words
	reg [15:0] got_words[0:4095];
	integer n_got, n_last, got_last_idx;
	reg monitor_en;
	reg [15:0] word_seed;
	integer k;

	pckthandler_fsm DUT(.rxbyteclkhs(clk), .reset(reset), .data_stream(data_stream),
		.ph_stream(ph_stream), .ph_select(ph_select), .valid_stream(valid_stream),
		.ecc_error(ecc_error), .out_stream(out_stream), .frame_active(frame_active),
		.frame_valid(frame_valid), .lines_per_frame(lines_per_frame), .last_packet(last_packet));

	initial clk = 0;
	always #10 clk = ~clk;

	// Output monitor and invariants, sampled between clock edges
	always @(negedge clk) if (monitor_en) begin
		if (frame_valid) begin
			`CHECK_EQ(frame_active, 1'b1, "frame_valid implies frame_active")
			got_words[n_got] = out_stream;
			if (last_packet) begin
				n_last = n_last + 1;
				got_last_idx = n_got;
			end
			n_got = n_got + 1;
		end
		else begin
			`CHECK_EQ(out_stream, 16'd0, "out_stream is zero outside frame_valid")
			`CHECK_EQ(last_packet, 1'b0, "last_packet only with frame_valid")
		end
	end

	task clear_scoreboard;
		begin
			n_exp = 0; exp_last_idx = -1;
			n_got = 0; n_last = 0; got_last_idx = -1;
		end
	endtask

	task check_scoreboard;
		input [8*40-1:0] what;
		begin
			`CHECK_EQ(n_got, n_exp, what)
			for (k = 0; k < n_got && k < n_exp; k = k + 1)
				`CHECK_EQ(got_words[k], exp_words[k], what)
			`CHECK_EQ(got_last_idx, exp_last_idx, "index of last_packet word")
			`CHECK_EQ(n_last, (exp_last_idx >= 0) ? 1 : 0, "number of last_packet words")
			clear_scoreboard;
		end
	endtask

	task idle;
		input integer cycles;
		begin
			repeat(cycles) begin
				@(posedge clk);
				valid_stream <= 0; ph_select <= 0; ph_stream <= 0; data_stream <= 0; ecc_error <= 0;
			end
		end
	endtask

	// Present a packet header, then `words` payload words, then an LP gap.
	// If `accept` is set the payload (up to the word count) is added to the
	// scoreboard; `last` marks its final word as the frame's last packet.
	task send_packet;
		input [7:0] dt;
		input [15:0] wc;
		input err;
		input integer words;
		input accept, last;
		integer w;
		begin
			@(posedge clk);
			valid_stream <= 1; ph_select <= 1; ecc_error <= err;
			ph_stream <= {wc, dt}; data_stream <= 16'hBAAD;
			for (w = 0; w < words; w = w + 1) begin
				@(posedge clk);
				ph_select <= 0; ecc_error <= 0; ph_stream <= 0;
				data_stream <= word_seed;
				if (accept && (2 * w < wc)) begin
					exp_words[n_exp] = word_seed;
					if (last && (2 * w + 2 >= wc)) exp_last_idx = n_exp;
					n_exp = n_exp + 1;
				end
				word_seed = word_seed * 16'd25173 + 16'd13849;
			end
			idle(3);
		end
	endtask

	// Long packet with its payload plus a 2-byte CRC footer
	task send_line;
		input [7:0] dt;
		input [15:0] wc;
		input err, accept, last;
		begin
			send_packet(dt, wc, err, (wc + 1) / 2 + 1, accept, last);
		end
	endtask

	task send_short;
		input [7:0] dt;
		input err;
		begin
			send_packet(dt, 16'h0000, err, 1, 0, 0);
		end
	endtask

	integer line;

	initial begin
		data_stream = 0; ph_stream = 0; ph_select = 0; valid_stream = 0; ecc_error = 0;
		lines_per_frame = 0; reset = 1; monitor_en = 0; word_seed = 16'h1234;
		clear_scoreboard;
		repeat(2) @(posedge clk);
		#1;
		`CHECK_EQ({frame_active, frame_valid, last_packet, out_stream}, 19'd0, "outputs in reset")
		@(negedge clk) reset = 0;

		// Part 1: vector file
		nvec = 0;
		fd = $fopen("pckthandler_fsm_testvec.txt", "r");
		if (fd == 0) $fatal(1, "Could not open pckthandler_fsm_testvec.txt (run from unit_tests/)");
		while (!$feof(fd)) begin
			status = $fgets(vecstr, fd);
			if ($sscanf(vecstr, "%h, %h, %h, %h, %h, %h, %h", data_stream, ph_stream, valid_stream,
					ph_select, out_exp, fr_active_exp, fr_valid_exp) == 7) begin
				@(posedge clk); #1;
				`CHECK_EQ(out_stream, out_exp, "vector out_stream")
				`CHECK_EQ(frame_active, fr_active_exp, "vector frame_active")
				`CHECK_EQ(frame_valid, fr_valid_exp, "vector frame_valid")
				`CHECK_EQ(last_packet, 1'b0, "vector last_packet")
				nvec = nvec + 1;
			end
		end
		$fclose(fd);
		`CHECK(nvec > 0, "vector file contained vectors")
		idle(4);
		`CHECK_EQ(frame_active, 1'b0, "vector file ends with frame end")

		monitor_en = 1;

		// Part 2: pixel data outside a frame is dropped
		send_line(DT_RAW10, 16'd10, 0, 0, 0);
		`CHECK_EQ(frame_active, 1'b0, "no frame yet")
		check_scoreboard("pixel data outside frame");

		// Part 3: a full frame with 3 lines and embedded data
		lines_per_frame = 3;
		send_short(DT_FS, 0);
		`CHECK_EQ(frame_active, 1'b1, "frame_active after frame start")
		send_line(DT_EMBED, 16'd10, 0, 0, 0);
		for (line = 1; line <= 3; line = line + 1)
			send_line(DT_RAW10, 16'd10, 0, 1, line == 3);
		send_short(DT_FE, 0);
		`CHECK_EQ(frame_active, 1'b0, "frame_active cleared by frame end")
		check_scoreboard("3-line frame");

		// Part 4: a second frame restarts the line count; odd and zero word counts
		send_short(DT_FS, 0);
		send_line(DT_RAW10, 16'd7, 0, 1, 0);
		send_line(DT_RAW10, 16'd0, 0, 1, 0);   // counts as a line, but no payload
		send_line(DT_RAW10, 16'd5, 0, 1, 1);
		send_short(DT_FE, 0);
		check_scoreboard("odd/zero word counts");

		// Part 5: headers with ECC errors are ignored
		send_short(DT_FS, 1);
		`CHECK_EQ(frame_active, 1'b0, "errored frame start ignored")
		send_short(DT_FS, 0);
		send_line(DT_RAW10, 16'd10, 1, 0, 0);  // dropped line (not counted)
		send_line(DT_RAW10, 16'd10, 0, 1, 0);
		send_short(DT_FE, 1);
		`CHECK_EQ(frame_active, 1'b1, "errored frame end ignored")
		send_line(DT_RAW10, 16'd10, 0, 1, 0);
		send_line(DT_RAW10, 16'd10, 0, 1, 1);
		send_short(DT_FE, 0);
		`CHECK_EQ(frame_active, 1'b0, "frame end after errored frame end")
		check_scoreboard("ECC-errored headers");

		// Part 6: other data types are skipped; more lines than lines_per_frame
		lines_per_frame = 2;
		send_short(DT_FS, 0);
		send_line(DT_RAW8, 16'd8, 0, 0, 0);
		send_line(8'h30, 16'd8, 0, 0, 0);      // user-defined data type
		send_line(DT_RAW10, 16'd20, 0, 1, 0);
		send_line(DT_RAW10, 16'd20, 0, 1, 1);
		send_line(DT_RAW10, 16'd20, 0, 1, 0);  // line 3 of a "2-line" frame
		send_short(DT_FE, 0);
		check_scoreboard("other data types / extra lines");

		// Part 7: lines_per_frame = 0 never flags a last packet
		lines_per_frame = 0;
		send_short(DT_FS, 0);
		for (line = 0; line < 4; line = line + 1)
			send_line(DT_RAW10, 16'd6, 0, 1, 0);
		send_short(DT_FE, 0);
		check_scoreboard("lines_per_frame = 0");

		// Part 8: a long line (IMX219 full-width RAW10 line is 3280 bytes)
		lines_per_frame = 1;
		send_short(DT_FS, 0);
		send_line(DT_RAW10, 16'd3280, 0, 1, 1);
		send_short(DT_FE, 0);
		check_scoreboard("3280-byte line");

		// Part 9: reset in the middle of a packet clears all state
		lines_per_frame = 1;
		send_short(DT_FS, 0);
		@(posedge clk);
		valid_stream <= 1; ph_select <= 1; ph_stream <= {16'd40, DT_RAW10};
		repeat(4) begin
			@(posedge clk);
			ph_select <= 0; data_stream <= 16'h5A5A;
		end
		@(negedge clk);
		`CHECK_EQ(frame_valid, 1'b1, "mid-packet before reset")
		reset <= 1;
		@(posedge clk); #1;
		`CHECK_EQ({frame_active, frame_valid, last_packet, out_stream}, 19'd0, "outputs after reset")
		@(negedge clk) reset <= 0;
		idle(3);
		clear_scoreboard;
		// After reset, a line without a new frame start is dropped
		send_line(DT_RAW10, 16'd10, 0, 0, 0);
		send_short(DT_FS, 0);
		send_line(DT_RAW10, 16'd10, 0, 1, 1);
		send_short(DT_FE, 0);
		check_scoreboard("after mid-packet reset");

		`TB_FINISH
	end
endmodule
