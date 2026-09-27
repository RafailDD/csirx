/* Self-checking testbench for pckthandler.v
 *
 * 1. Replays pckthandler_testvec.txt (din, din_valid, dout_exp, fr_active_exp, fr_valid_exp);
 *    outputs are checked one clock after each input is applied.
 * 2. Byte-level packet tests: packets are built with real CSI-2 headers
 *    (ECC from csi_ref.vh), split into 16-bit words the way wordalign presents
 *    them, and the payload coming out is checked against a scoreboard.
 *    Covers ECC single-bit correction and double-bit rejection of headers,
 *    embedded data, lines_per_frame/last_packet, and odd word counts.
 * See also pckthandler_tb2.v
 *
 * Gedeon Nyengele <nyengele@stanford.edu>
 * January 2018
 */

`timescale 1ns/1ps

module pckthandler_tb;
	`include "tb_common.vh"
	`include "csi_ref.vh"

	localparam DT_FS = 8'h00, DT_FE = 8'h01, DT_EMBED = 8'h12, DT_RAW10 = 8'h2B;

	reg clk, reset, din_valid;
	reg [15:0] din;
	reg [31:0] lines_per_frame;
	wire fr_active, fr_valid, last_packet;
	wire [15:0] dout;

	reg [15:0] dout_exp;
	reg fr_valid_exp, fr_active_exp;
	integer fd, status, nvec;
	reg [128*8-1:0] vecstr;

	// Packet under construction
	reg [7:0] pkt[0:8191];
	integer pkt_len;

	// Scoreboard / monitor
	reg [15:0] exp_words[0:8191];
	integer n_exp, exp_last_idx;
	reg [15:0] got_words[0:8191];
	integer n_got, n_last, got_last_idx;
	reg monitor_en;
	integer k, line;

	pckthandler DUT(.rxbyteclkhs(clk), .reset(reset), .in_stream(din), .in_stream_valid(din_valid),
		.out_stream(dout), .frame_active(fr_active), .frame_valid(fr_valid),
		.lines_per_frame(lines_per_frame), .last_packet(last_packet));

	initial clk = 0;
	always #10 clk = ~clk;

	always @(negedge clk) if (monitor_en) begin
		if (fr_valid) begin
			`CHECK_EQ(fr_active, 1'b1, "frame_valid implies frame_active")
			got_words[n_got] = dout;
			if (last_packet) begin
				n_last = n_last + 1;
				got_last_idx = n_got;
			end
			n_got = n_got + 1;
		end
		else
			`CHECK_EQ(last_packet, 1'b0, "last_packet only with frame_valid")
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

	// Build a packet: header (optionally corrupted), payload, 2-byte CRC footer.
	// Accepted payload words go to the scoreboard.
	task build_packet;
		input [7:0] dt;
		input [15:0] wc;
		input [31:0] hdr_flip; // bits to flip in the header
		input accept, last;
		reg [31:0] hdr;
		integer b;
		begin
			hdr = csi_header(dt, wc) ^ hdr_flip;
			pkt[0] = hdr[7:0]; pkt[1] = hdr[15:8]; pkt[2] = hdr[23:16]; pkt[3] = hdr[31:24];
			pkt_len = 4;
			if (dt >= 8'h10) begin // long packet
				for (b = 0; b < wc; b = b + 1)
					pkt[4 + b] = $random;
				pkt[4 + wc] = $random; pkt[5 + wc] = $random; // CRC (not checked by the core)
				pkt_len = 6 + wc;
				if (accept)
					for (b = 0; b < wc; b = b + 2) begin
						exp_words[n_exp] = {pkt[4 + b], pkt[5 + b]};
						if (last && (b + 2 >= wc)) exp_last_idx = n_exp;
						n_exp = n_exp + 1;
					end
			end
			if (pkt_len % 2) begin
				pkt[pkt_len] = 8'h00;
				pkt_len = pkt_len + 1;
			end
		end
	endtask

	// Send the packet as 16-bit words {lane0 byte, lane1 byte}, then an LP gap
	task send_built_packet;
		integer w;
		begin
			for (w = 0; w < pkt_len; w = w + 2) begin
				@(posedge clk);
				din <= {pkt[w], pkt[w + 1]};
				din_valid <= 1;
			end
			@(posedge clk);
			din <= 16'h0000; din_valid <= 0;
			repeat(3) @(posedge clk);
		end
	endtask

	task send_packet;
		input [7:0] dt;
		input [15:0] wc;
		input [31:0] hdr_flip;
		input accept, last;
		begin
			build_packet(dt, wc, hdr_flip, accept, last);
			send_built_packet;
		end
	endtask

	initial begin
		din = 0; din_valid = 0; reset = 1; lines_per_frame = 0; monitor_en = 0;
		clear_scoreboard;
		repeat(2) @(posedge clk);
		@(negedge clk) reset = 0;

		// Part 1: vector file
		nvec = 0;
		fd = $fopen("pckthandler_testvec.txt", "r");
		if (fd == 0) $fatal(1, "Could not open pckthandler_testvec.txt (run from unit_tests/)");
		while (!$feof(fd)) begin
			status = $fgets(vecstr, fd);
			if ($sscanf(vecstr, "%h, %h, %h, %h, %h", din, din_valid, dout_exp, fr_active_exp, fr_valid_exp) == 5) begin
				@(posedge clk); #1;
				`CHECK_EQ(dout, dout_exp, "vector dout")
				`CHECK_EQ(fr_active, fr_active_exp, "vector frame_active")
				`CHECK_EQ(fr_valid, fr_valid_exp, "vector frame_valid")
				`CHECK_EQ(last_packet, 1'b0, "vector last_packet")
				nvec = nvec + 1;
			end
		end
		$fclose(fd);
		`CHECK(nvec > 0, "vector file contained vectors")
		@(negedge clk) din_valid = 0;
		repeat(3) @(posedge clk);

		monitor_en = 1;

		// Part 2: a clean frame with embedded data and 4 lines
		lines_per_frame = 4;
		send_packet(DT_FS, 16'h0000, 0, 0, 0);
		`CHECK_EQ(fr_active, 1'b1, "frame_active after frame start")
		send_packet(DT_EMBED, 16'd12, 0, 0, 0);
		for (line = 1; line <= 4; line = line + 1)
			send_packet(DT_RAW10, 16'd40, 0, 1, line == 4);
		send_packet(DT_FE, 16'h0000, 0, 0, 0);
		`CHECK_EQ(fr_active, 1'b0, "frame_active after frame end")
		check_scoreboard("clean frame");

		// Part 3: single-bit header errors in every data bit are corrected
		lines_per_frame = 0;
		send_packet(DT_FS, 16'h0000, 32'h1 << 3, 0, 0);
		`CHECK_EQ(fr_active, 1'b1, "corrected frame start")
		for (line = 0; line < 24; line = line + 1)
			send_packet(DT_RAW10, 16'd10, 32'h1 << line, 1, 0);
		send_packet(DT_FE, 16'h0000, 32'h1 << 17, 0, 0);
		`CHECK_EQ(fr_active, 1'b0, "corrected frame end")
		check_scoreboard("single-bit header errors");

		// Part 4: double-bit header errors are dropped
		send_packet(DT_FS, 16'h0000, 32'h0000_0003, 0, 0);
		`CHECK_EQ(fr_active, 1'b0, "uncorrectable frame start ignored")
		send_packet(DT_FS, 16'h0000, 0, 0, 0);
		send_packet(DT_RAW10, 16'd10, 32'h0000_0101, 0, 0);
		send_packet(DT_RAW10, 16'd10, 32'h8000_0001, 0, 0);
		send_packet(DT_RAW10, 16'd10, 0, 1, 0);
		send_packet(DT_FE, 16'h0000, 32'h0000_1100, 0, 0);
		`CHECK_EQ(fr_active, 1'b1, "uncorrectable frame end ignored")
		send_packet(DT_FE, 16'h0000, 0, 0, 0);
		`CHECK_EQ(fr_active, 1'b0, "frame end")
		check_scoreboard("double-bit header errors");

		// Part 5: odd word counts and a single-line frame
		lines_per_frame = 1;
		send_packet(DT_FS, 16'h0000, 0, 0, 0);
		send_packet(DT_RAW10, 16'd15, 0, 1, 1);
		send_packet(DT_FE, 16'h0000, 0, 0, 0);
		check_scoreboard("odd word count (15)");
		send_packet(DT_FS, 16'h0000, 0, 0, 0);
		send_packet(DT_RAW10, 16'd1, 0, 1, 1);
		send_packet(DT_FE, 16'h0000, 0, 0, 0);
		check_scoreboard("odd word count (1)");

		// Part 6: synchronous reset between lines drops the rest of the frame.
		// (Reset during a packet is covered by pckthandler_fsm_tb; here it would
		// make ph_finder parse payload bytes as a header.)
		lines_per_frame = 2;
		send_packet(DT_FS, 16'h0000, 0, 0, 0);
		send_packet(DT_RAW10, 16'd40, 0, 1, 0);
		@(posedge clk) reset <= 1;
		@(posedge clk) reset <= 0;
		@(negedge clk);
		`CHECK_EQ(fr_active, 1'b0, "frame_active cleared by reset")
		clear_scoreboard;
		send_packet(DT_RAW10, 16'd10, 0, 0, 0);
		send_packet(DT_FS, 16'h0000, 0, 0, 0);
		send_packet(DT_RAW10, 16'd10, 0, 1, 0);
		send_packet(DT_RAW10, 16'd10, 0, 1, 1);
		send_packet(DT_FE, 16'h0000, 0, 0, 0);
		check_scoreboard("after reset");

		`TB_FINISH
	end
endmodule
