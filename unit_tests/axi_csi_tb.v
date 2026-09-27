/* System-level self-checking testbench for axi_csi.v (and axilite_control.v)
 *
 * Drives the two PPI data lanes (with optional inter-lane skew) with complete
 * CSI-2 frames: frame start, optional embedded data line, RAW10 lines built
 * from random pixels with real packet-header ECC, and frame end. The AXI-Lite
 * register interface is exercised with a small bus-functional master, and the
 * AXI-Stream output is compared against the original pixels.
 *
 * Covers: register reset values and read/write behaviour, run/stop via the
 * CTRL_SET/CTRL_CLEAR registers, continuous vs. single-frame mode, SOF/EOF
 * interrupt posting, masking and acknowledgement, output enable (latched at
 * frame start), tlast from the lines-per-frame register, and resets.
 *
 * The AXI-Lite and PPI byte clocks run at unrelated frequencies.
 */

`timescale 1ns/1ps

module axi_csi_tb;
	`include "tb_common.vh"
	`include "csi_ref.vh"

	localparam DT_FS = 8'h00, DT_FE = 8'h01, DT_EMBED = 8'h12, DT_RAW10 = 8'h2B;

	// Register map (byte addresses)
	localparam REG_CONFIG = 5'h00, REG_CTRL_SET = 5'h04, REG_CTRL_CLEAR = 5'h08,
	           REG_STATUS = 5'h0C, REG_FR_LINES = 5'h10;
	// CONFIG / CTRL / STATUS bits
	localparam BIT_RS = 0, BIT_GLOBALINT = 1, BIT_SOF = 2, BIT_EOF = 3, BIT_OUTEN = 4;
	localparam [31:0] CFG_CONT = 32'h1, CFG_GIE = 32'h2, CFG_SOF = 32'h4, CFG_EOF = 32'h8, CFG_OUTEN = 32'h10;

	// Clocks and resets
	reg aclk, aresetn, bclk, bresetn;

	// PPI
	reg dl0_rxactivehs, dl1_rxactivehs, dl0_rxsynchs, dl1_rxsynchs;
	reg dl0_rxvalidhs, dl1_rxvalidhs;
	reg [7:0] dl0_rxdatahs, dl1_rxdatahs;
	wire cl_enable, dl0_enable, dl1_enable, dl0_forcerxmode, dl1_forcerxmode;

	// AXI-Lite
	reg [4:0] awaddr, araddr;
	reg awvalid, wvalid, bready, arvalid, rready;
	reg [31:0] wdata;
	reg [3:0] wstrb;
	wire awready, wready, bvalid, arready, rvalid;
	wire [1:0] bresp, rresp;
	wire [31:0] rdata;

	// AXI-Stream
	wire tvalid, tlast;
	wire [63:0] tdata;
	wire [7:0] tstrb;
	reg tready;

	wire csi_intr;

	axi_csi DUT(
		.csi_intr(csi_intr),
		.rxbyteclkhs_resetn(bresetn),
		.ppi_cl_stopstate(1'b0),
		.ppi_cl_enable(cl_enable),
		.ppi_rxbyteclkhs_clk(bclk),
		.ppi_dl0_rxactivehs(dl0_rxactivehs),
		.ppi_dl0_rxsynchs(dl0_rxsynchs),
		.ppi_dl0_enable(dl0_enable),
		.ppi_dl0_forcerxmode(dl0_forcerxmode),
		.ppi_dl0_rxvalidhs(dl0_rxvalidhs),
		.ppi_dl0_rxdatahs(dl0_rxdatahs),
		.ppi_dl1_rxactivehs(dl1_rxactivehs),
		.ppi_dl1_rxsynchs(dl1_rxsynchs),
		.ppi_dl1_enable(dl1_enable),
		.ppi_dl1_forcerxmode(dl1_forcerxmode),
		.ppi_dl1_rxvalidhs(dl1_rxvalidhs),
		.ppi_dl1_rxdatahs(dl1_rxdatahs),
		.regspace_s_axi_aclk(aclk),
		.regspace_s_axi_aresetn(aresetn),
		.regspace_s_axi_awaddr(awaddr),
		.regspace_s_axi_awprot(3'b000),
		.regspace_s_axi_awvalid(awvalid),
		.regspace_s_axi_awready(awready),
		.regspace_s_axi_wdata(wdata),
		.regspace_s_axi_wstrb(wstrb),
		.regspace_s_axi_wvalid(wvalid),
		.regspace_s_axi_wready(wready),
		.regspace_s_axi_bresp(bresp),
		.regspace_s_axi_bvalid(bvalid),
		.regspace_s_axi_bready(bready),
		.regspace_s_axi_araddr(araddr),
		.regspace_s_axi_arprot(3'b000),
		.regspace_s_axi_arvalid(arvalid),
		.regspace_s_axi_arready(arready),
		.regspace_s_axi_rdata(rdata),
		.regspace_s_axi_rresp(rresp),
		.regspace_s_axi_rvalid(rvalid),
		.regspace_s_axi_rready(rready),
		.output_m_axis_tvalid(tvalid),
		.output_m_axis_tdata(tdata),
		.output_m_axis_tstrb(tstrb),
		.output_m_axis_tlast(tlast),
		.output_m_axis_tready(tready)
	);

	initial aclk = 0;
	always #5 aclk = ~aclk;   // 100 MHz AXI-Lite clock
	initial bclk = 0;
	always #7 bclk = ~bclk;   // ~71 MHz PPI byte clock

	// ------------------------------------------------------------------
	// AXI-Lite bus-functional master
	// ------------------------------------------------------------------
	task axi_write;
		input [4:0] addr;
		input [31:0] data;
		integer timeout;
		begin
			@(posedge aclk);
			awaddr <= addr; awvalid <= 1; wdata <= data; wvalid <= 1; wstrb <= 4'hF;
			timeout = 0;
			@(posedge aclk);
			while (!(awready && wready) && timeout < 20) begin
				@(posedge aclk);
				timeout = timeout + 1;
			end
			`CHECK(timeout < 20, "AXI write address/data handshake")
			awvalid <= 0; wvalid <= 0;
			timeout = 0;
			while (!bvalid && timeout < 20) begin
				@(posedge aclk);
				timeout = timeout + 1;
			end
			`CHECK(timeout < 20, "AXI write response")
			`CHECK_EQ(bresp, 2'b00, "AXI write response OKAY")
		end
	endtask

	task axi_read;
		input [4:0] addr;
		output [31:0] data;
		integer timeout;
		begin
			@(posedge aclk);
			araddr <= addr; arvalid <= 1;
			timeout = 0;
			@(posedge aclk);
			while (!arready && timeout < 20) begin
				@(posedge aclk);
				timeout = timeout + 1;
			end
			`CHECK(timeout < 20, "AXI read address handshake")
			arvalid <= 0;
			timeout = 0;
			while (!rvalid && timeout < 20) begin
				@(posedge aclk);
				timeout = timeout + 1;
			end
			`CHECK(timeout < 20, "AXI read data")
			`CHECK_EQ(rresp, 2'b00, "AXI read response OKAY")
			data = rdata;
		end
	endtask

	reg [31:0] rd;

	task expect_reg;
		input [4:0] addr;
		input [31:0] value;
		input [8*48-1:0] what;
		begin
			axi_read(addr, rd);
			`CHECK_EQ(rd, value, what)
		end
	endtask

	// Let clock-domain crossings settle before checking status/interrupts
	task settle;
		begin
			repeat(6) @(posedge aclk);
		end
	endtask

	// ------------------------------------------------------------------
	// PPI driver
	// ------------------------------------------------------------------
	reg [7:0] pkt[0:8191];
	integer pkt_len;
	integer lane_skew; // cycles by which lane 1 lags lane 0 (negative: leads)

	// Expected AXI-Stream beats
	reg [63:0] exp_beats[0:8191];
	integer n_exp, exp_last_idx;
	reg [9:0] px[0:3];

	task build_packet;
		input [7:0] dt;
		input [15:0] wc;
		input record; // record the payload pixels on the scoreboard
		input last;   // the final beat of this packet should carry tlast
		reg [31:0] hdr;
		integer b, p;
		begin
			hdr = csi_header(dt, wc);
			pkt[0] = hdr[7:0]; pkt[1] = hdr[15:8]; pkt[2] = hdr[23:16]; pkt[3] = hdr[31:24];
			pkt_len = 4;
			if (dt >= 8'h10) begin
				// RAW10 payload: groups of 4 random pixels -> 5 bytes
				for (b = 0; b < wc; b = b + 5) begin
					for (p = 0; p < 4; p = p + 1)
						px[p] = $random;
					pkt[4 + b + 0] = px[0][9:2];
					pkt[4 + b + 1] = px[1][9:2];
					pkt[4 + b + 2] = px[2][9:2];
					pkt[4 + b + 3] = px[3][9:2];
					pkt[4 + b + 4] = {px[3][1:0], px[2][1:0], px[1][1:0], px[0][1:0]};
					if (record) begin
						exp_beats[n_exp] = {6'd0, px[3], 6'd0, px[2], 6'd0, px[1], 6'd0, px[0]};
						if (last && (b + 5 >= wc)) exp_last_idx = n_exp;
						n_exp = n_exp + 1;
					end
				end
				pkt[4 + wc] = $random; pkt[5 + wc] = $random; // CRC (not checked)
				pkt_len = 6 + wc;
			end
			if (pkt_len % 2) begin
				pkt[pkt_len] = 8'h00;
				pkt_len = pkt_len + 1;
			end
		end
	endtask

	// Send pkt[] over both lanes: even bytes on lane 0, odd bytes on lane 1
	task send_built_packet;
		integer c, n, s0, s1, last;
		begin
			n = pkt_len / 2;
			s0 = (lane_skew < 0) ? -lane_skew : 0;
			s1 = (lane_skew > 0) ? lane_skew : 0;
			last = n + ((s0 > s1) ? s0 : s1);
			for (c = 0; c < last; c = c + 1) begin
				@(posedge bclk);
				dl0_rxactivehs <= 1; dl1_rxactivehs <= 1;
				dl0_rxsynchs <= (c == s0 - 1);
				dl1_rxsynchs <= (c == s1 - 1);
				if (c >= s0 && c < s0 + n) begin
					dl0_rxvalidhs <= 1; dl0_rxdatahs <= pkt[2 * (c - s0)];
				end
				else begin
					dl0_rxvalidhs <= 0; dl0_rxdatahs <= 8'h00;
				end
				if (c >= s1 && c < s1 + n) begin
					dl1_rxvalidhs <= 1; dl1_rxdatahs <= pkt[2 * (c - s1) + 1];
				end
				else begin
					dl1_rxvalidhs <= 0; dl1_rxdatahs <= 8'h00;
				end
			end
			@(posedge bclk);
			dl0_rxvalidhs <= 0; dl1_rxvalidhs <= 0; dl0_rxdatahs <= 0; dl1_rxdatahs <= 0;
			dl0_rxactivehs <= 0; dl1_rxactivehs <= 0; dl0_rxsynchs <= 0; dl1_rxsynchs <= 0;
			repeat(8) @(posedge bclk); // LP gap between packets
		end
	endtask

	task send_packet;
		input [7:0] dt;
		input [15:0] wc;
		input record, last;
		begin
			build_packet(dt, wc, record, last);
			send_built_packet;
		end
	endtask

	// A frame of `lines` RAW10 lines, `width` pixels each (multiple of 4).
	// `record`: payload expected on the AXI-Stream output;
	// `tlast_line`: line whose final beat should carry tlast (0 = none).
	task send_frame_start;
		begin
			send_packet(DT_FS, 16'h0000, 0, 0);
		end
	endtask

	task send_frame_body;
		input integer lines, width;
		input record;
		input integer tlast_line;
		integer l;
		begin
			send_packet(DT_EMBED, 16'd20, 0, 0);
			for (l = 1; l <= lines; l = l + 1)
				send_packet(DT_RAW10, width * 10 / 8, record, l == tlast_line);
			send_packet(DT_FE, 16'h0000, 0, 0);
		end
	endtask

	task send_frame;
		input integer lines, width;
		input record;
		input integer tlast_line;
		begin
			send_frame_start;
			send_frame_body(lines, width, record, tlast_line);
		end
	endtask

	// ------------------------------------------------------------------
	// AXI-Stream monitor
	// ------------------------------------------------------------------
	reg [63:0] got_beats[0:8191];
	integer n_got, n_last, got_last_idx, k;

	always @(negedge bclk) begin
		if (tvalid) begin
			`CHECK_EQ(tstrb, 8'hFF, "tstrb on a valid beat")
			got_beats[n_got] = tdata;
			if (tlast) begin
				n_last = n_last + 1;
				got_last_idx = n_got;
			end
			n_got = n_got + 1;
		end
		else if (bresetn) begin
			`CHECK_EQ(tlast, 1'b0, "tlast only on a valid beat")
			`CHECK_EQ(tdata, 64'd0, "tdata is zero between beats")
		end
	end

	task clear_scoreboard;
		begin
			n_exp = 0; exp_last_idx = -1;
			n_got = 0; n_last = 0; got_last_idx = -1;
		end
	endtask

	task check_stream;
		input [8*40-1:0] what;
		begin
			`CHECK_EQ(n_got, n_exp, what)
			for (k = 0; k < n_got && k < n_exp; k = k + 1)
				`CHECK_EQ(got_beats[k], exp_beats[k], what)
			`CHECK_EQ(got_last_idx, exp_last_idx, "index of tlast beat")
			`CHECK_EQ(n_last, (exp_last_idx >= 0) ? 1 : 0, "number of tlast beats")
			clear_scoreboard;
		end
	endtask

	// STATUS register value: {EOF, SOF, any, RS}
	function [31:0] status;
		input eof, sof, rs;
		begin
			status = {28'd0, eof, sof, eof | sof, rs};
		end
	endfunction

	// ------------------------------------------------------------------
	// Test sequence
	// ------------------------------------------------------------------
	integer a;

	initial begin
		aresetn = 0; bresetn = 0;
		awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0; bready = 1;
		araddr = 0; arvalid = 0; rready = 1; tready = 1;
		dl0_rxactivehs = 0; dl1_rxactivehs = 0; dl0_rxsynchs = 0; dl1_rxsynchs = 0;
		dl0_rxvalidhs = 0; dl1_rxvalidhs = 0; dl0_rxdatahs = 0; dl1_rxdatahs = 0;
		lane_skew = 0;
		clear_scoreboard;
		repeat(5) @(posedge aclk);
		aresetn = 1;
		@(posedge bclk) bresetn <= 1;
		repeat(3) @(posedge aclk);

		// -- Static outputs --
		`CHECK_EQ({cl_enable, dl0_enable, dl1_enable}, 3'b111, "D-PHY lanes enabled")
		`CHECK_EQ({dl0_forcerxmode, dl1_forcerxmode}, 2'b11, "forcerxmode")
		`CHECK_EQ(csi_intr, 1'b0, "no interrupt after reset")
		`CHECK_EQ(tvalid, 1'b0, "no output after reset")

		// -- Register reset values --
		expect_reg(REG_CONFIG, 32'h0, "CONFIG reset value");
		expect_reg(REG_CTRL_SET, 32'h0, "CTRL_SET reads zero");
		expect_reg(REG_CTRL_CLEAR, 32'h0, "CTRL_CLEAR reads zero");
		expect_reg(REG_STATUS, 32'h0, "STATUS reset value");
		expect_reg(REG_FR_LINES, 32'h0, "FR_LINES reset value");
		for (a = 5; a < 8; a = a + 1)
			expect_reg(a * 4, 32'hDEADBEEF, "unimplemented register");

		// -- Register read/write --
		axi_write(REG_CONFIG, 32'hA5A5_5A5A & ~CFG_CONT & ~CFG_GIE);
		expect_reg(REG_CONFIG, 32'hA5A5_5A5A & ~CFG_CONT & ~CFG_GIE, "CONFIG read-back");
		axi_write(REG_FR_LINES, 32'h1234_5678);
		expect_reg(REG_FR_LINES, 32'h1234_5678, "FR_LINES read-back");
		axi_write(REG_STATUS, 32'hFFFF_FFFF);
		expect_reg(REG_STATUS, 32'h0, "STATUS is read-only");
		axi_write(REG_CTRL_CLEAR, 32'hFFFF_FFFE);
		expect_reg(REG_CTRL_CLEAR, 32'h0, "CTRL_CLEAR still reads zero");
		for (a = 5; a < 8; a = a + 1) begin
			axi_write(a * 4, 32'h0000_0000);
			expect_reg(a * 4, 32'hDEADBEEF, "unimplemented register after write");
		end
		axi_write(REG_CONFIG, 32'h0);
		expect_reg(REG_CONFIG, 32'h0, "CONFIG cleared");

		// -- A frame while stopped is ignored completely --
		axi_write(REG_FR_LINES, 3);
		axi_write(REG_CONFIG, CFG_CONT | CFG_GIE | CFG_SOF | CFG_EOF | CFG_OUTEN);
		send_frame(3, 16, 0, 0);
		settle;
		check_stream("frame while stopped");
		expect_reg(REG_STATUS, status(0, 0, 0), "STATUS after frame while stopped");
		`CHECK_EQ(csi_intr, 1'b0, "no interrupt while stopped")

		// -- Start (continuous mode) --
		axi_write(REG_CTRL_SET, 32'h1);
		settle;
		expect_reg(REG_STATUS, status(0, 0, 1), "running");

		// -- Frame 1: SOF interrupt, ack, data, EOF interrupt, ack --
		send_frame_start;
		settle;
		expect_reg(REG_STATUS, status(0, 1, 1), "SOF posted");
		`CHECK_EQ(csi_intr, 1'b1, "SOF interrupt");
		axi_write(REG_CTRL_SET, 1 << BIT_SOF);   // ack SOF only
		settle;
		expect_reg(REG_STATUS, status(0, 0, 1), "SOF acknowledged, still running");
		`CHECK_EQ(csi_intr, 1'b0, "interrupt cleared by SOF ack");
		send_frame_body(3, 16, 1, 3);
		settle;
		check_stream("frame 1");
		expect_reg(REG_STATUS, status(1, 0, 1), "EOF posted, continuous mode keeps running");
		`CHECK_EQ(csi_intr, 1'b1, "EOF interrupt");
		axi_write(REG_CTRL_SET, 1 << BIT_EOF);   // ack EOF only
		settle;
		expect_reg(REG_STATUS, status(0, 0, 1), "EOF acknowledged");
		`CHECK_EQ(csi_intr, 1'b0, "interrupt cleared by EOF ack");

		// -- Frame 2: wider lines, lane skew, global ack clears both --
		lane_skew = 2;
		send_frame(3, 64, 1, 3);
		settle;
		check_stream("frame 2 (lane 1 lags by 2)");
		expect_reg(REG_STATUS, status(1, 1, 1), "SOF and EOF posted");
		axi_write(REG_CTRL_SET, 1 << BIT_GLOBALINT);
		settle;
		expect_reg(REG_STATUS, status(0, 0, 1), "global ack clears both");

		// -- Frame 3: lane 0 lags; lines_per_frame does not match -> no tlast --
		lane_skew = -1;
		axi_write(REG_FR_LINES, 5);
		send_frame(3, 24, 1, 0);
		settle;
		check_stream("frame 3 (no tlast)");
		axi_write(REG_FR_LINES, 2);
		send_frame(4, 8, 1, 2);
		settle;
		check_stream("frame 4 (tlast on line 2 of 4)");
		axi_write(REG_FR_LINES, 3);
		axi_write(REG_CTRL_SET, 1 << BIT_GLOBALINT);
		lane_skew = 0;

		// -- Interrupt masking --
		axi_write(REG_CONFIG, CFG_CONT | CFG_SOF | CFG_EOF | CFG_OUTEN); // global disable
		send_frame(3, 8, 1, 3);
		settle;
		check_stream("frame with interrupts masked");
		expect_reg(REG_STATUS, status(1, 1, 1), "status bits set even when masked");
		`CHECK_EQ(csi_intr, 1'b0, "global interrupt enable masks the line");
		axi_write(REG_CONFIG, CFG_CONT | CFG_GIE | CFG_SOF | CFG_OUTEN); // SOF only
		settle;
		`CHECK_EQ(csi_intr, 1'b1, "pending SOF with SOF enabled");
		axi_write(REG_CTRL_SET, 1 << BIT_SOF);
		settle;
		`CHECK_EQ(csi_intr, 1'b0, "pending EOF with EOF masked");
		axi_write(REG_CONFIG, CFG_CONT | CFG_GIE | CFG_EOF | CFG_OUTEN); // EOF only
		settle;
		`CHECK_EQ(csi_intr, 1'b1, "pending EOF with EOF enabled");
		axi_write(REG_CTRL_SET, 1 << BIT_EOF);
		settle;
		`CHECK_EQ(csi_intr, 1'b0, "EOF acknowledged");

		// -- Output enable: disabled frames produce no stream, latched at SOF --
		axi_write(REG_CONFIG, CFG_CONT | CFG_GIE | CFG_SOF | CFG_EOF);
		send_frame(3, 8, 0, 0);
		settle;
		check_stream("output disabled");
		expect_reg(REG_STATUS, status(1, 1, 1), "interrupts still posted with output disabled");
		axi_write(REG_CTRL_SET, 1 << BIT_GLOBALINT);
		// Enable output mid-frame: takes effect from the next frame
		send_frame_start;
		axi_write(REG_CONFIG, CFG_CONT | CFG_GIE | CFG_SOF | CFG_EOF | CFG_OUTEN);
		send_frame_body(3, 8, 0, 0);
		settle;
		check_stream("output enabled mid-frame");
		send_frame(3, 8, 1, 3);
		settle;
		check_stream("output enabled from next frame");
		// Disable output mid-frame: the current frame still completes
		send_frame_start;
		axi_write(REG_CONFIG, CFG_CONT | CFG_GIE | CFG_SOF | CFG_EOF);
		send_frame_body(3, 8, 1, 3);
		settle;
		check_stream("output disabled mid-frame");
		axi_write(REG_CTRL_SET, 1 << BIT_GLOBALINT);

		// -- Stop via CTRL_CLEAR --
		axi_write(REG_CONFIG, CFG_CONT | CFG_OUTEN);
		axi_write(REG_CTRL_CLEAR, 32'h1);
		settle;
		expect_reg(REG_STATUS, status(0, 0, 0), "stopped by CTRL_CLEAR");
		send_frame(3, 8, 0, 0);
		settle;
		check_stream("frame after stop");
		expect_reg(REG_STATUS, status(0, 0, 0), "no interrupts after stop");

		// -- Single-frame mode: stops itself after one frame --
		axi_write(REG_CONFIG, CFG_OUTEN);
		axi_write(REG_CTRL_SET, 32'h1);
		settle;
		expect_reg(REG_STATUS, status(0, 0, 1), "running (single frame)");
		send_frame(3, 16, 1, 3);
		settle;
		check_stream("single frame");
		expect_reg(REG_STATUS, status(1, 1, 0), "stopped after one frame");
		send_frame(3, 16, 0, 0);
		settle;
		check_stream("frame after single-frame capture");
		axi_write(REG_CTRL_SET, 32'h1 | (1 << BIT_GLOBALINT)); // restart and ack
		settle;
		expect_reg(REG_STATUS, status(0, 0, 1), "restarted single frame");
		send_frame(2, 12, 1, 0);
		settle;
		check_stream("second single frame");
		expect_reg(REG_STATUS, status(1, 1, 0), "stopped again");

		// -- CTRL_CLEAR without the RS bit does nothing --
		axi_write(REG_CONFIG, CFG_CONT | CFG_OUTEN);
		axi_write(REG_CTRL_SET, 32'h1 | (1 << BIT_GLOBALINT));
		axi_write(REG_CTRL_CLEAR, 32'hFFFF_FFFE);
		settle;
		expect_reg(REG_STATUS, status(0, 0, 1), "CTRL_CLEAR bit 0 not set");

		// -- Byte-clock reset mid-frame drops the frame; next frame is fine --
		send_frame_start;
		@(posedge bclk) bresetn <= 0;
		repeat(3) @(posedge bclk);
		@(posedge bclk) bresetn <= 1;
		send_frame_body(3, 8, 0, 0);
		settle;
		check_stream("frame interrupted by byte-clock reset");
		send_frame(3, 8, 1, 3);
		settle;
		check_stream("frame after byte-clock reset");

		// -- AXI reset returns all registers to their defaults and stops the core --
		@(posedge aclk) aresetn <= 0;
		repeat(3) @(posedge aclk);
		@(posedge aclk) aresetn <= 1;
		expect_reg(REG_CONFIG, 32'h0, "CONFIG after AXI reset");
		expect_reg(REG_STATUS, 32'h0, "STATUS after AXI reset");
		expect_reg(REG_FR_LINES, 32'h0, "FR_LINES after AXI reset");
		send_frame(2, 8, 0, 0);
		settle;
		check_stream("frame after AXI reset");

		`TB_FINISH
	end

	// Watchdog
	initial begin
		#20_000_000;
		$fatal(1, "Timeout");
	end
endmodule
