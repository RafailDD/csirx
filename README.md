# csirx
Open-source CSI-2 receiver for Xilinx UltraScale parts 


# Supported cameras
Right now, this only supports the Sony IMX219 (aka the Raspberry Pi camera).  In the Raspberry Pi configuration, it supports 2 data lanes and 10-bit RAW output.

# Testing
The testbenches in `unit_tests/` check their own results and run with [Icarus Verilog](https://steveicarus.github.io/iverilog/):

```
make test             # run every testbench; summary + logs in build/, non-zero exit on failure
make wordalign        # run one testbench with full output
make waves T=axi_csi  # dump waveforms and open them in GTKWave
```

See [unit_tests/README.md](unit_tests/README.md) for:
- prerequisites;
- how to read results and debug a failure;
- what each testbench covers;
- how to add a new testbench;
- CI.

GitHub Actions runs the suite on every pull request and every push to `master`.

# License
This code is released under the GNU LGPL 3.0.  That means you're welcome to use it however you want, but if you publish/sell a design based on a modified version of the code, then you need to share your changes to this code (but not the rest of your system).

# Links
Several others have created similar CSI-2 receivers:

* https://github.com/daveshah1/CSI2Rx

