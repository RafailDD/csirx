# Testing the CSI-2 receiver

The `unit_tests/` directory holds self-checking Verilog testbenches for every
module in `hdl/`, plus one that tests the whole core through its external
interfaces. Each testbench compares the design's outputs against expected
values, prints `PASS` or `FAIL`, and exits with a non-zero status on failure,
so the suite can gate a commit or a CI run.

- [Quick start](#quick-start)
- [Prerequisites](#prerequisites)
- [Running tests](#running-tests)
- [Inspecting results](#inspecting-results)
- [Debugging a failure](#debugging-a-failure)
- [What each testbench covers](#what-each-testbench-covers)
- [Vector files](#vector-files)
- [Writing a new testbench](#writing-a-new-testbench)
- [Continuous integration](#continuous-integration)
- [Known limitations](#known-limitations)

## Quick start

```sh
sudo apt-get install iverilog gtkwave   # once
make test                               # from the repository root
```

```
ecc_block        PASS      1.24s  131121 checks
ph_finder        PASS      0.03s  269 checks
raw10_decoder    PASS      0.04s  3868 checks
pckthandler_fsm  PASS      0.04s  4084 checks
pckthandler      PASS      0.05s  930 checks
wordalign        PASS      0.06s  2008 checks
axi_csi          PASS      0.12s  4613 checks

7 passed, 0 failed (1.58s). Logs: build/logs/
```

## Prerequisites

| Tool | Needed for | Install |
|------|------------|---------|
| [Icarus Verilog](https://steveicarus.github.io/iverilog/) (`iverilog`, `vvp`) | compiling and running the testbenches | Debian/Ubuntu: `sudo apt-get install iverilog`<br>macOS: `brew install icarus-verilog`<br>Windows: use WSL and the Ubuntu package |
| GNU Make, Bash | the test flow | usually preinstalled |
| A VCD viewer (optional) | looking at waveforms | [GTKWave](https://gtkwave.github.io/gtkwave/) (`sudo apt-get install gtkwave`), or [Surfer](https://surfer-project.org/) |

The suite is tested with Icarus Verilog 12. The testbenches are compiled with
`-g2012`, since `hdl/axi_csi.v` uses a SystemVerilog `localparam` in its
parameter list.

## Running tests

All commands run from the repository root. `make -C unit_tests <target>` works
too.

| Command | What it does |
|---------|--------------|
| `make test` | Builds and runs every testbench, continues past failures, prints a summary table, and writes logs and reports to `build/`. Exits non-zero if anything failed. |
| `make list` | Lists the testbenches. |
| `make <name>` | Runs one testbench with its full output on the terminal, e.g. `make wordalign`. |
| `make VCD=1 <name>` | Same as above, and also dumps every signal to `build/<name>.vcd`. |
| `make waves T=<name>` | Dumps the waveforms and opens them in GTKWave if it is installed. |
| `make summary` | Prints the summary of the last `make test`. |
| `make test TESTS="ph_finder wordalign"` | Runs a subset through the full flow (logs, summary, JUnit). |
| `make replay` | Replays the camera capture `image4.bin` through the packet handler. Slow (about 3.5 minutes) and for manual inspection only; see [Known limitations](#known-limitations). |
| `make clean` | Deletes `build/`. |

Testbenches run with `unit_tests/` as their working directory because they
read their vector files from there. The Makefile handles this; if you run
`vvp` by hand, `cd unit_tests` first.

Builds are incremental: a testbench is recompiled only when it, a shared
include, or a file in `hdl/` changes.

## Inspecting results

`make test` produces:

| File | Contents |
|------|----------|
| `build/logs/<name>.log` | Full compile and simulation output of one testbench: every `FAIL` line, any compiler warnings, and the final `PASS`/`FAIL` summary. |
| `build/test_summary.txt` | The summary table printed at the end of the run. |
| `build/test-results.xml` | JUnit XML, for CI systems and IDE test viewers. |
| `build/<name>.vcd` | Waveforms, only when run with `VCD=1` or `make waves`. |

Each row of the summary table is one of:

- **`PASS`**: every check passed. The detail column shows how many checks ran.
- **`FAIL`**: the simulation ran and at least one check failed. The detail
  column shows the *first* failing check; the log has all of them.
- **`ERROR`**: the testbench or the RTL did not compile. The compiler messages
  are in the log.

A failing check looks like this:

```
FAIL @331000: vector out_stream: got 'h0000, expected 'h1122
```

- `@331000` is the simulation time in **picoseconds** (all testbenches use
  `` `timescale 1ns/1ps ``), so this is 331 ns. Use it to find the moment in
  the waveform viewer.
- `vector out_stream` names the check: which part of the test and which
  signal. Search for that text in the testbench source to find the check.
- `got` / `expected` are the actual and expected values in hex. An `x` means
  the signal was undefined.

The last line of each log is the testbench's verdict:

```
PASS: pckthandler_fsm_tb (4084 checks)
FATAL: ...: FAIL: pckthandler_fsm_tb (3 of 4084 checks failed)
```

## Debugging a failure

1. Run `make test` and note the failing testbench and the first `FAIL @<time>` line.
2. Read the whole log, `build/logs/<name>.log`. The first failure is usually
   the cause; later ones often follow from it.
3. Find the check in the testbench source by searching for the message text.
   The comments at the top of each testbench, and the `// Part N` comments in
   it, say what each section is testing.
4. Dump waveforms and look at the failure time:
   ```sh
   make waves T=pckthandler_fsm     # or: make VCD=1 pckthandler_fsm; gtkwave build/pckthandler_fsm.vcd
   ```
   The design under test is always the instance `DUT` inside the testbench
   module (for example `pckthandler_fsm_tb.DUT`). In GTKWave, add signals from
   the hierarchy pane on the left, then jump to the time from the `FAIL` line
   (convert ps to ns: 331000 ps = 331 ns).
5. After fixing, rerun just that testbench with `make <name>`, then the whole
   suite with `make test`.

Random stimulus uses `$random` with the simulator's default seed, so every
run of a testbench is identical and failures are reproducible. Editing a
testbench can change the random sequence it generates.

## What each testbench covers

| Testbench | Design under test | Covers |
|-----------|-------------------|--------|
| `ecc_block_tb.v` | `ecc_block` | The vector file; headers with no errors; correction of every single-bit error in the 24 data bits; detection of every double-bit error in the 32-bit header; single-bit errors in the ECC byte never corrupt the data. Uses edge-case and random headers, checked against an independent reference ECC (`csi_ref.vh`). |
| `ph_finder_tb.v` | `ph_finder` | The vector file; header capture and payload bypass; restarting the header search when `din_valid` drops or on reset. |
| `raw10_decoder_tb.v` | `raw10_decoder` | The vector file; random RAW10 lines of different widths, packed as in the CSI-2 spec and compared beat by beat; the `last_packet` pipeline; no output without `frame_active`; realignment after a line is cut short or reset. |
| `pckthandler_fsm_tb.v` | `pckthandler_fsm` | The vector file; frame start and end; embedded data and other packet types skipped; pixel data outside a frame dropped; headers with ECC errors ignored; odd and zero word counts; `lines_per_frame` and `last_packet`; a 3280-byte line; reset mid-packet. |
| `pckthandler_tb.v` | `pckthandler` (`ph_finder` + `ecc_block` + FSM) | The vector file; packets built from real CSI-2 headers; correction of a single-bit error in every header data bit; rejection of double-bit errors; odd word counts; reset between lines. |
| `wordalign_tb.v` | `wordalign` | Every combination of lane skew from 0 to `MAX_CHANNEL_DELAY`; short packets; 50 back-to-back random packets; reset mid-packet; skew beyond the maximum produces no output, and alignment recovers afterwards. |
| `axi_csi_tb.v` | `axi_csi` (whole core, including `axilite_control`) | Drives both camera lanes with complete frames (frame start, embedded data, RAW10 lines, frame end), with lane skew, and uses an AXI-Lite master on the register interface. Checks: register reset values and read/write behaviour; run/stop through `CTRL_SET`/`CTRL_CLEAR`; continuous and single-frame modes; frame-start/end interrupts with masking and acknowledgement; output enable latched at frame start; the AXI-Stream pixels, `tstrb` and `tlast`; byte-clock and AXI resets. The AXI-Lite and byte clocks run at unrelated frequencies. |
| `pckthandler_tb2.v` | `pckthandler` | Not part of `make test`. Replays `image4.bin` and writes the payload to `image4_out.bin` (`make replay`). |

Shared files:

- `tb_common.vh`: the `CHECK_EQ`/`CHECK` macros, the `TB_FINISH` summary,
  and the `+vcd=<file>` waveform option.
- `csi_ref.vh`: reference CSI-2 header ECC (`csi_ecc`, `csi_header`) written
  from the spec's parity table, independently of the RTL.
- `run_tests.sh`: the runner behind `make test`.

## Vector files

Five testbenches first replay a vector file, then run their generated tests.
Each line is a comma-separated list of hex values. Lines that do not parse
(comments, blank lines) are skipped. For clocked modules, the inputs on a line
are applied, one clock edge passes, and then the outputs are compared.
`ecc_block` is combinational, so its outputs are compared 1 ns after the input
changes.

| File | Columns (inputs → expected outputs) |
|------|-------------------------------------|
| `ecc_block_testvec.txt` | `PH_in` → `PH_out`, `error` |
| `ph_finder_testvec.txt` | `din`, `din_valid` → `dout`, `dout_valid`, `ph_select` |
| `raw10_decoder_testvec.txt` | `din`, `frame_active`, `frame_valid` → `data_out`, `out_valid` |
| `pckthandler_fsm_testvec.txt` | `data_stream`, `ph_stream`, `valid_stream`, `ph_select` → `out_stream`, `frame_active`, `frame_valid` |
| `pckthandler_testvec.txt` | `din`, `din_valid` → `dout`, `frame_active`, `frame_valid` |

## Writing a new testbench

1. Create `unit_tests/<name>_tb.v` with a module named `<name>_tb`:

   ```verilog
   `timescale 1ns/1ps

   module foo_tb;
       `include "tb_common.vh"     // check macros, TB_FINISH, +vcd support
       `include "csi_ref.vh"       // optional: csi_ecc(), csi_header()

       reg clk = 0;
       always #10 clk = ~clk;

       // ... signals, and the DUT instantiated as `DUT` ...

       initial begin
           // ... drive inputs ...
           @(posedge clk); #1;
           `CHECK_EQ(DUT_output, 8'h2B, "what is being checked")
           `CHECK(other_output == 1'b1, "another check")
           `TB_FINISH                // prints PASS/FAIL and sets the exit status
       end
   endmodule
   ```

   Modules in `hdl/` are found automatically (`iverilog -y hdl`). Connect
   ports by name, so the testbench fails to compile, rather than silently
   misconnecting, if a port list changes.

2. Add `<name>` to `TESTS` in the top-level `Makefile`.
3. Run `make <name>`, then `make test`.

Tips:

- Prefer a scoreboard (record what the DUT should output, capture what it
  does output, compare) over hard-coding the exact cycle each output appears.
  The existing packet tests work this way, so they survive pipeline changes.
- Message strings should say *what* is checked; `CHECK_EQ` already prints the
  values and the time.
- To check that a testbench really catches bugs, change one line of the RTL
  (flip a comparison, drop a reset term) and confirm that `make test` fails.

## Continuous integration

`.github/workflows/tests.yml` runs `make test` on every push and pull request
on GitHub Actions. For each run:

- the job summary page shows the results table and the `FAIL` lines of any
  failing testbench;
- a `test-results` artifact holds `build/logs/`, the summary and the JUnit
  XML;
- **Run workflow** (manual dispatch) has a *waves* option that also uploads
  VCD waveforms for every testbench.

GitHub disables Actions on forks until you enable them under the repository's
**Actions** tab.

## Known limitations

These are properties of the RTL that the tests document rather than fix:

- **`wordalign`, short packets with large skew:** a falling edge of
  `rxvalidhs` is also taken as a sync pulse. If one lane's burst ends before
  the other lane's starts (burst length ≤ skew), the late lane is misaligned.
  `wordalign_tb` keeps its random packets longer than `MAX_CHANNEL_DELAY`, and
  tests short packets only with skew of up to 1 cycle.
- **`ecc_block`, errors in the ECC byte:** the CSI-2 spec treats a single-bit
  error in the ECC byte as correctable, but `ecc_block` flags it as
  uncorrectable, so the packet is dropped. The test checks only that the data
  is never mis-corrected.
- **`m_axis_tready` is ignored:** the core has no backpressure, so the tests
  keep `tready` high.
- **`image4.bin`** is a continuous capture with no gaps between packets and no
  CSI-2 headers that the current packet handler recognizes, so `make replay`
  decodes no lines. It is kept for manual experiments with `viewdump.py`.
