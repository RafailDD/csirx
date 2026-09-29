# csirx
Open-source CSI-2 receiver for Xilinx UltraScale parts 


# Supported cameras
Right now, this only supports the Sony IMX219 (aka the Raspberry Pi camera).  In the Raspberry Pi configuration, it supports 2 data lanes and 10-bit RAW output.

# Testing
The testbenches in `unit_tests/` are self-checking and run with [Icarus Verilog](https://steveicarus.github.io/iverilog/) (v11 or newer):

```
make test          # run every testbench; exits non-zero on any failure
make wordalign     # run a single testbench
make VCD=1 axi_csi # also dump waveforms to build/axi_csi.vcd
```

| Testbench | Covers |
|-----------|--------|
| `ecc_block_tb` | Packet header ECC: clean headers, correction of every single-bit data error, detection of every double-bit error |
| `ph_finder_tb` | Header capture, bypass, and restart on `din_valid` drop or reset |
| `raw10_decoder_tb` | RAW10 unpacking of random lines against a reference packer, `last_packet` pipeline, realignment |
| `pckthandler_fsm_tb` | Frame start/end, data types, ECC-errored headers, word counts, lines per frame / `last_packet`, reset |
| `pckthandler_tb` | Header finder + ECC + FSM together, with real CSI-2 headers and injected header bit errors |
| `wordalign_tb` | Lane deskew for every skew within `MAX_CHANNEL_DELAY`, back-to-back packets, excessive skew |
| `axi_csi_tb` | Whole core: AXI-Lite registers, run/stop, single-frame mode, interrupts, output enable, AXI-Stream pixels and `tlast` |

`make replay` pushes the camera dump `unit_tests/image4.bin` through the packet handler (slow; manual inspection only).

# License
This code is released under the GNU LGPL 3.0.  That means you're welcome to use it however you want, but if you publish/sell a design based on a modified version of the code, then you need to share your changes to this code (but not the rest of your system).

# Links
Several others have created similar CSI-2 receivers:

* https://github.com/daveshah1/CSI2Rx

