/* Reference models shared by the testbenches (include inside a module body). */

// CSI-2 packet header ECC (MIPI CSI-2 v1.x, 24-bit header, 6-bit Hamming code).
// Each data bit contributes the syndrome listed in the spec's parity table,
// written out here independently of the RTL's parity equations.
function [7:0] csi_ecc_col;
	input integer bit_idx;
	begin
		case (bit_idx)
			0:  csi_ecc_col = 8'h07;  1:  csi_ecc_col = 8'h0B;
			2:  csi_ecc_col = 8'h0D;  3:  csi_ecc_col = 8'h0E;
			4:  csi_ecc_col = 8'h13;  5:  csi_ecc_col = 8'h15;
			6:  csi_ecc_col = 8'h16;  7:  csi_ecc_col = 8'h19;
			8:  csi_ecc_col = 8'h1A;  9:  csi_ecc_col = 8'h1C;
			10: csi_ecc_col = 8'h23;  11: csi_ecc_col = 8'h25;
			12: csi_ecc_col = 8'h26;  13: csi_ecc_col = 8'h29;
			14: csi_ecc_col = 8'h2A;  15: csi_ecc_col = 8'h2C;
			16: csi_ecc_col = 8'h31;  17: csi_ecc_col = 8'h32;
			18: csi_ecc_col = 8'h34;  19: csi_ecc_col = 8'h38;
			20: csi_ecc_col = 8'h1F;  21: csi_ecc_col = 8'h2F;
			22: csi_ecc_col = 8'h37;  23: csi_ecc_col = 8'h3B;
			default: csi_ecc_col = 8'h00;
		endcase
	end
endfunction

function [7:0] csi_ecc;
	input [23:0] data;
	integer b;
	begin
		csi_ecc = 8'h00;
		for (b = 0; b < 24; b = b + 1)
			if (data[b]) csi_ecc = csi_ecc ^ csi_ecc_col(b);
	end
endfunction

// Full 32-bit packet header as it appears on the wire: {ECC, WC_MSB, WC_LSB, DI}
function [31:0] csi_header;
	input [7:0] data_id;
	input [15:0] word_count;
	begin
		csi_header = {csi_ecc({word_count, data_id}), word_count, data_id};
	end
endfunction
