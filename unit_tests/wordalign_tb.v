/* Self-checking testbench for wordalign.v
 *
 * Each lane carries its half of a packet (lane 0: even bytes, lane 1: odd bytes),
 * with rxvalidhs starting on each lane at a different cycle to model inter-lane
 * skew. The aligned output must be exactly the sequence of {lane0, lane1} byte
 * pairs, with word_valid high for exactly the packet length.
 *
 * Covers skews of 0..MAX_CHANNEL_DELAY in both directions, back-to-back packets
 * (re-lock after each LP gap), resynchronisation after reset, and checks that a
 * skew larger than the supported maximum never produces output.
 */

`timescale 1ns/1ps

module wordalign_tb;
	`include "tb_common.vh"

	localparam MAX_DELAY = 2;

	reg clk, resetn;
	reg dl0_valid, dl1_valid;
	reg [7:0] dl0_data, dl1_data;
	wire [15:0] word_out;
	wire word_valid;

	// Per-lane byte streams for the current packet
	reg [7:0] lane0[0:255];
	reg [7:0] lane1[0:255];
	integer len;

	// Monitor
	reg [15:0] got[0:1023];
	integer n_got, n_valid_runs;
	reg prev_valid;
	integer k, s0, s1, n;

	wordalign #(.MAX_CHANNEL_DELAY(MAX_DELAY)) DUT(
		.clk(clk), .resetn(resetn),
		.dl0_rxvalidhs(dl0_valid), .dl1_rxvalidhs(dl1_valid),
		.dl0_rxdatahs(dl0_data), .dl1_rxdatahs(dl1_data),
		.word_out(word_out), .word_valid(word_valid));

	initial clk = 0;
	always #10 clk = ~clk;

	always @(negedge clk) begin
		if (word_valid) begin
			got[n_got] = word_out;
			n_got = n_got + 1;
			if (!prev_valid) n_valid_runs = n_valid_runs + 1;
		end
		prev_valid = word_valid;
	end

	task clear_monitor;
		begin
			n_got = 0; n_valid_runs = 0;
		end
	endtask

	task make_packet;
		input integer length;
		begin
			len = length;
			for (k = 0; k < len; k = k + 1) begin
				lane0[k] = $random;
				lane1[k] = $random;
			end
		end
	endtask

	// Drive the packet with lane 0 starting `skew0` cycles and lane 1 starting
	// `skew1` cycles after the first cycle. Invalid bytes are driven as X.
	task send_packet;
		input integer skew0, skew1;
		integer c, last;
		begin
			last = len + ((skew0 > skew1) ? skew0 : skew1);
			for (c = 0; c < last; c = c + 1) begin
				@(posedge clk);
				if (c >= skew0 && c < skew0 + len) begin
					dl0_valid <= 1; dl0_data <= lane0[c - skew0];
				end
				else begin
					dl0_valid <= 0; dl0_data <= 8'hxx;
				end
				if (c >= skew1 && c < skew1 + len) begin
					dl1_valid <= 1; dl1_data <= lane1[c - skew1];
				end
				else begin
					dl1_valid <= 0; dl1_data <= 8'hxx;
				end
			end
			@(posedge clk);
			dl0_valid <= 0; dl1_valid <= 0; dl0_data <= 8'hxx; dl1_data <= 8'hxx;
			repeat(MAX_DELAY + 4) @(posedge clk);
		end
	endtask

	task check_packet;
		input [8*40-1:0] what;
		begin
			`CHECK_EQ(n_got, len, what)
			`CHECK_EQ(n_valid_runs, 1, "word_valid is one contiguous run")
			for (k = 0; k < n_got && k < len; k = k + 1)
				`CHECK_EQ(got[k], {lane0[k], lane1[k]}, what)
			clear_monitor;
		end
	endtask

	initial begin
		resetn = 0; dl0_valid = 0; dl1_valid = 0; dl0_data = 0; dl1_data = 0;
		prev_valid = 0;
		clear_monitor;
		repeat(3) @(posedge clk);
		#1;
		`CHECK_EQ({word_valid, word_out}, 17'd0, "outputs in reset")
		@(negedge clk) resetn = 1;

		// Every combination of lane skews within the supported range
		for (s0 = 0; s0 <= MAX_DELAY; s0 = s0 + 1)
			for (s1 = 0; s1 <= MAX_DELAY; s1 = s1 + 1) begin
				make_packet(16);
				send_packet(s0, s1);
				check_packet("aligned packet");
			end

		// Short packets (4 bytes = 2 per lane) with up to one cycle of skew
		for (s0 = 0; s0 <= 1; s0 = s0 + 1)
			for (s1 = 0; s1 <= 1; s1 = s1 + 1) begin
				make_packet(2);
				send_packet(s0, s1);
				check_packet("short packet");
			end

		// Many back-to-back packets of random length and skew.
		// NOTE: lengths are kept above MAX_DELAY. If one lane's burst ends before
		// the other lane's begins, the falling edge of rxvalidhs is also taken as
		// a sync pulse and the late lane is misaligned (known wordalign limitation).
		for (n = 0; n < 50; n = n + 1) begin
			make_packet(MAX_DELAY + 1 + ($unsigned($random) % 60));
			send_packet($unsigned($random) % (MAX_DELAY + 1), $unsigned($random) % (MAX_DELAY + 1));
			check_packet("random packet");
		end

		// Reset in the middle of a packet, then a clean packet
		make_packet(32);
		fork
			send_packet(0, 1);
			begin
				repeat(10) @(posedge clk);
				resetn <= 0;
				@(posedge clk) resetn <= 1;
			end
		join
		clear_monitor;
		make_packet(12);
		send_packet(1, 0);
		check_packet("packet after reset");

		// Skew beyond MAX_CHANNEL_DELAY cannot be aligned: no output at all
		make_packet(16);
		send_packet(0, MAX_DELAY + 1);
		`CHECK_EQ(n_got, 0, "no output with excessive skew (lane 1 late)")
		clear_monitor;
		make_packet(16);
		send_packet(MAX_DELAY + 2, 0);
		`CHECK_EQ(n_got, 0, "no output with excessive skew (lane 0 late)")
		clear_monitor;

		// ...and the aligner still works afterwards
		make_packet(20);
		send_packet(2, 0);
		check_packet("packet after excessive skew");

		`TB_FINISH
	end
endmodule
