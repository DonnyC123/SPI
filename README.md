# SPI Master

An SPI master with a simple register interface, hardened for SkyWater 130 nm.
Currently it is built to run at 100 MHz with Yosys, OpenROAD, Magic and Netgen.

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `DATA_W` | 8 | Bits per transfer, MSB first (up to 32) |
| `SCLK_HALF_DIV_W` | 8 | Width of the clock divider (up to 8) |
| `NUM_DEVICES` | 1 | Number of chip selects (up to 256) |

## Ports

| Port | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | System clock |
| `rst_n` | in | 1 | Asynchronous active-low reset |
| `bus_wr` | in | 1 | Write strobe, one cycle per write |
| `bus_addr` | in | 5 | Byte address (bits [4:2] select the register) |
| `bus_wdata` | in | 32 | Write data |
| `bus_rdata` | out | 32 | Read data, valid the cycle after `bus_addr` |
| `miso` | in | 1 | SPI data from the slave |
| `sclk` | out | 1 | SPI clock |
| `mosi` | out | 1 | SPI data to the slave |
| `cs_n` | out | `NUM_DEVICES` | Active-low chip selects, one per device |

## Register map

| Address | Name | Access | Fields |
|---|---|---|---|
| 0x00 | CFG | RW | [0] cpol, [1] cpha, [15:8] sclk_half_div |
| 0x04 | CTRL | RW | [0] start (W, reads 0), [1] more, [2] cfg_wr (W, reads 0), [15:8] cs_sel |
| 0x08 | TXDATA | RW | [7:0] byte to send |
| 0x0C | RXDATA | R | [7:0] byte received by the last transfer |
| 0x10 | STATUS | R/W1C | [0] busy, [1] done, [2] open |

- **CFG** holds the SPI mode and speed. Writing it does nothing until `cfg_wr` is set in CTRL.
  - `cpol` is the idle level of `sclk`.
  - `cpha` = 0 samples on the leading edge, 1 on the trailing edge.
  - `sclk` = `clk / (2 × (sclk_half_div + 1))`. The reset value is `0xFF`, the slowest setting.
- **CTRL**
  - `start` begins a transfer. It is ignored while busy.
  - `more` keeps `cs_n` low after the byte, so the next byte continues the same transaction.
  - `cfg_wr` loads CFG into the SPI engine. It is ignored while a transaction is open.
  - `cs_sel` picks the device. It is used only by the first byte of a transaction.
- **STATUS**
  - `busy` is set while a byte is shifting.
  - `done` is set when a byte finishes and cleared by writing 1 to bit 1 or by the next accepted start. If a W1C and a finishing byte land in the same cycle, `done` stays set.
  - `open` is set while any `cs_n` is low.

Bits not listed are not stored and read as 0. `cs_sel` values at or above
`NUM_DEVICES` select no device.

## Using it

One byte to device 2 (`NUM_DEVICES` ≥ 3), SPI mode 0, `sclk` = `clk / 16`:

```
write CFG    = 0x0000_0700          // cpol 0, cpha 0, sclk_half_div 7
write CTRL   = 0x0000_0004          // cfg_wr
write TXDATA = 0x0000_00A5
write CTRL   = 0x0000_0201          // cs_sel 2, start
poll  STATUS until bit 1 (done) is 1
read  RXDATA                        // byte from the slave
write STATUS = 0x0000_0002          // clear done
```

For a multi-byte transaction, set `more` (CTRL bit 1) on every byte except the
last. `cs_n` stays low between bytes and goes high after the last one.

## Simulation

```
make sim          # RTL sim, NUM_DEVICES = 1 and 4 (Verilator)
make gls1 gls4    # gate-level sim of the hardened netlist, no delays (Icarus)
make sdf1 sdf4    # gate-level sim with routed delays at 3 corners (Icarus)
```

The testbench runs at 100 MHz. It connects one slave model per chip select,
in SPI modes 0–3, and checks:

- register reset values and access;
- one byte and three-byte transactions in each mode;
- the `done` flag, including clear on start and `done` winning over a W1C;
- `start` ignored while busy;
- `cfg_wr` and `cs_sel` ignored while a transaction is open;
- the clock divider;
- a read and write in the same cycle;
- reset in the middle of a transfer.

It prints `ALL TESTS PASSED` or the number of failures.

## Hardening

```
make harden1 harden4   # GDS for NUM_DEVICES = 1 and 4
make synth             # harden both, then run gls and sdf for both
```

Each build goes into `runs/devN/`, and the folder is cleared first.

| Step | Script | Tool | Output |
|---|---|---|---|
| Synthesis | `flow/synth.tcl` | Yosys | `synth.v` |
| Place and route | `flow/pnr.tcl` | OpenROAD | `final/nl`, `final/pnl`, `final/def`, `final/odb` |
| Timing, per corner | `flow/sta.tcl` | OpenROAD | `final/spef`, `final/sdf`, `reports/sta_*.rpt` |
| GDS | `flow/magic.tcl` | Magic | `final/gds/spi_top.gds` |
| DRC and extraction | `flow/magic_check.tcl` | Magic | `reports/drc.rpt`, `final/spi_top.layout.spice` |
| LVS | `flow/lvs.tcl` | Netgen | `reports/lvs.rpt` |

`flow/common.tcl` holds the shared PDK paths and cell lists, and
`flow/constraints.sdc` holds the timing constraints:
- 10 ns clock;
- 4 ns input and output delay;
- `inv_2` drivers and `inv_16` loads;
- 5% derate;
- max transition 0.75 ns, max cap 0.2 pF, max fanout 16.

The build stops with an error on any of:
- an undriven net in the RTL;
- negative setup or hold slack at any corner;
- a DRC error in the GDS;
- an LVS mismatch.

The antenna count is printed in the summary.

Timing corners: `max_ss_100C_1v60` (worst setup), `nom_tt_025C_1v80`, and
`min_ff_n40C_1v95` (worst hold).

### Setup

The Makefile is set up for the ece393 tools on moore. It adds `/vol/ece393`
tool folders to `PATH` and `LD_LIBRARY_PATH` and uses the PDK in
`/vol/ece393/open_pdks/share/pdk`. Override `PDK_ROOT` to use another PDK,
and `RUNS` to build somewhere other than `runs/`.

### Results

Built at 100 MHz with 60% core utilization:

| | 1 device | 4 devices |
|---|---|---|
| Die | 96.6 × 96.6 µm | 98.7 × 98.7 µm |
| Setup slack (`max_ss`) | +2.41 ns | +2.25 ns |
| Hold slack (`min_ff`) | +0.109 ns | +0.111 ns |
| DRC / antenna / LVS | 0 / 0 / match | 0 / 0 / match |

These numbers are from a 2026 OpenROAD. Other tool versions place and route
slightly differently.

In the 1-device build one clock tree buffer drives 17 flip-flops against a max
fanout of 16. It is a clock net and is waived.

### Viewing the layout

```
klayout -l $PDK_ROOT/sky130A/libs.tech/klayout/tech/sky130A.lyp runs/dev1/final/gds/spi_top.gds
```

Press `*` in KLayout to show the inside of the standard cells.
