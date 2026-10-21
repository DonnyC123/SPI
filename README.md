# SPI Master

An SPI master with a simple register interface, hardened for SkyWater 130 nm.
Currently it is built to run at a 100 MHz clock with Yosys, OpenROAD, Magic and Netgen.

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `DATA_W` | 8 | Bits per transfer, MSB first (up to 32) |
| `SCLK_HALF_DIV_W` | 8 | Width of the clock divider (up to 8) |
| `NUM_DEVICES` | 1 | Number of chip selects (up to 256) |

## Ports

| Port | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | system clock |
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
