`timescale 1ns / 1ps

module spi_top_tb #(
  parameter integer NUM_DEVICES = 4  // 1 to 4
);

  localparam integer DATA_W          = 8;
  localparam integer SCLK_HALF_DIV_W = 8;
  localparam integer CS_SEL_W        = (NUM_DEVICES > 1) ? $clog2(NUM_DEVICES) : 1;
  localparam integer RESP_DEPTH      = 16;
  localparam integer T_DEV           = (NUM_DEVICES > 1) ? 1 : 0;
  localparam integer OTHER_DEV       = (T_DEV + 1) % NUM_DEVICES;
  localparam integer CLK_PERIOD      = 10;
  localparam integer LOG_DEPTH       = 64;
  localparam integer POLL_LIMIT      = 10000;


  // SPI mode of each device
  localparam [3:0]             SLAVE_CPOL = 4'b1100;
  localparam [3:0]             SLAVE_CPHA = 4'b1010;

  // Byte addresses
  localparam [4:0]             CFG        = 5'h00;
  localparam [4:0]             CTRL       = 5'h04;
  localparam [4:0]             TXDATA     = 5'h08;
  localparam [4:0]             RXDATA     = 5'h0C;
  localparam [4:0]             STATUS     = 5'h10;

  reg                       clk;
  reg                       rst_n;

  reg                       bus_wr;
  reg     [4:0]             bus_addr;
  reg     [31:0]            bus_wdata;
  wire    [31:0]            bus_rdata;

  wire                      miso;
  wire                      sclk;
  wire                      mosi;
  wire    [NUM_DEVICES-1:0] cs_n;

  // Slave side
  wire    [NUM_DEVICES-1:0] slave_miso;
  wire    [DATA_W-1:0]      slave_rx_byte  [0:NUM_DEVICES-1];
  wire    [31:0]            slave_rx_count [0:NUM_DEVICES-1];

  reg     [DATA_W-1:0]      rx_log         [0:NUM_DEVICES-1][0:LOG_DEPTH-1];
  integer                   rx_log_len     [0:NUM_DEVICES-1];

  reg     [RESP_DEPTH*DATA_W-1:0] resp_flat  [0:NUM_DEVICES-1];

  integer                   errors;
  reg     [31:0]            rdata;

  // Transfer test scratch
  reg     [DATA_W-1:0]      rx;
  reg     [DATA_W-1:0]      exp            [0:LOG_DEPTH-1];
  integer                   d;
  integer                   n;
  time                      t_rise0;
  time                      t_rise1;


  spi_top #(
      .DATA_W         (DATA_W),
      .SCLK_HALF_DIV_W(SCLK_HALF_DIV_W),
      .NUM_DEVICES    (NUM_DEVICES)
  ) dut (
      .clk      (clk),
      .rst_n    (rst_n),
      .bus_wr   (bus_wr),
      .bus_addr (bus_addr),
      .bus_wdata(bus_wdata),
      .bus_rdata(bus_rdata),
      .miso     (miso),
      .sclk     (sclk),
      .mosi     (mosi),
      .cs_n     (cs_n)
  );

  genvar g;
  generate
    for (g = 0; g < NUM_DEVICES; g = g + 1) begin : g_slave
      spi_slave_model #(
          .DATA_W(DATA_W),
          .CPOL  (SLAVE_CPOL[g]),
          .CPHA  (SLAVE_CPHA[g])
      ) u_slave (
          .cs_n    (cs_n[g]),
          .sclk    (sclk),
          .mosi    (mosi),
          .miso    (slave_miso[g]),
          .resp    (resp_flat[g]),
          .rx_byte (slave_rx_byte[g]),
          .rx_count(slave_rx_count[g])
      );

      initial begin
        rx_log_len[g] = 0;
      end

      always @(slave_rx_count[g]) begin
        if (rx_log_len[g] < LOG_DEPTH) begin
          rx_log[g][rx_log_len[g]] = slave_rx_byte[g];
        end
        rx_log_len[g] = rx_log_len[g] + 1;
      end
    end
  endgenerate

  // only the selected slave (cs_n low) drives it
  assign miso = |(slave_miso & ~cs_n);

  initial begin
    clk = 1'b0;
    forever begin
      #(CLK_PERIOD / 2) clk = ~clk;
    end
  end

  task bus_write(input [4:0] addr, input [31:0] data);
    begin
      @(negedge clk);
      bus_wr    = 1'b1;
      bus_addr  = addr;
      bus_wdata = data;
      @(negedge clk);
      bus_wr = 1'b0;
    end
  endtask

  task bus_read(input [4:0] addr, output [31:0] data);
    begin
      @(negedge clk);
      bus_addr = addr;
      @(negedge clk);
      data     = bus_rdata;
    end
  endtask

  task bus_rw(input [4:0] addr, input [31:0] wdata, output [31:0] data);
    begin
      @(negedge clk);
      bus_wr    = 1'b1;
      bus_addr  = addr;
      bus_wdata = wdata;
      @(negedge clk);
      bus_wr    = 1'b0;
      data      = bus_rdata;
    end
  endtask

  task check_read(input [4:0] addr, input [31:0] expected, input [511:0] name);
    begin
      bus_read(addr, rdata);
      if (rdata !== expected) begin
        $display("FAIL %0s: addr 0x%02h read 0x%08h, expected 0x%08h", name, addr, rdata, expected);
        errors = errors + 1;
      end else begin
        $display("PASS %0s", name);
      end
    end
  endtask

  task log_clear(input integer dev);
    begin
      rx_log_len[dev] = 0;
    end
  endtask

  task check_log(input integer dev, input integer len, input [511:0] name);
    integer k;
    reg     bad;
    begin
      bad = 1'b0;
      if (rx_log_len[dev] != len) begin
        $display("FAIL %0s: device %0d got %0d bytes, expected %0d", name, dev, rx_log_len[dev], len);
        bad = 1'b1;
      end else begin
        for (k = 0; k < len; k = k + 1) begin
          if (rx_log[dev][k] !== exp[k]) begin
            $display("FAIL %0s: device %0d byte %0d got 0x%02h, expected 0x%02h", name, dev, k, rx_log[dev][k], exp[k]);
            bad = 1'b1;
          end
        end
      end
      if (bad) begin
        errors = errors + 1;
      end else begin
        $display("PASS %0s", name);
      end
    end
  endtask

  task wait_idle;
    reg     [31:0] status;
    integer        polls;
    begin
      status = 32'h0000_0005;
      polls  = 0;
      while ((status[0] || status[2]) && polls < POLL_LIMIT) begin
        bus_read(STATUS, status);
        polls = polls + 1;
      end
      if (status[0] || status[2]) begin
        $display("FAIL wait_idle: timed out, STATUS = 0x%08h", status);
        errors = errors + 1;
      end
    end
  endtask

  task wait_done;
    reg     [31:0] status;
    integer        polls;
    begin
      status = 32'd0;
      polls  = 0;
      while (!status[1] && polls < POLL_LIMIT) begin
        bus_read(STATUS, status);
        polls = polls + 1;
      end
      if (!status[1]) begin
        $display("FAIL wait_done: timed out, STATUS = 0x%08h", status);
        errors = errors + 1;
      end
      bus_write(STATUS, 32'h0000_0002);
    end
  endtask

  // Load CFG
  task spi_config(input cpol, input cpha, input [SCLK_HALF_DIV_W-1:0] sclk_half_div);
    begin
      bus_write(CFG, {16'h0000, sclk_half_div, 6'b000000, cpha, cpol});
      bus_write(CTRL, 32'h0000_0004);
    end
  endtask

  // Send one byte to device dev and return the byte received
  task spi_xfer(input integer dev, input [DATA_W-1:0] tx, input more, output [DATA_W-1:0] rx);
    reg [31:0] ctrl;
    reg [31:0] rxdata;
    begin
      ctrl       = 32'd0;
      ctrl[0]    = 1'b1;
      ctrl[1]    = more;
      ctrl[15:8] = dev[7:0];
      bus_write(TXDATA, {{(32 - DATA_W) {1'b0}}, tx});
      bus_write(CTRL, ctrl);
      wait_done;
      bus_read(RXDATA, rxdata);
      rx = rxdata[DATA_W-1:0];
    end
  endtask

  // Set response byte idx of device dev
  task set_resp(input integer dev, input integer idx, input [DATA_W-1:0] value);
    begin
      resp_flat[dev][idx*DATA_W +: DATA_W] = value;
    end
  endtask

  task check_eq(input [63:0] actual, input [63:0] expected, input [511:0] name);
    begin
      if (actual !== expected) begin
        $display("FAIL %0s: got 0x%0h, expected 0x%0h", name, actual, expected);
        errors = errors + 1;
      end else begin
        $display("PASS %0s", name);
      end
    end
  endtask

  task log_clear_all;
    integer k;
    begin
      for (k = 0; k < NUM_DEVICES; k = k + 1) begin
        log_clear(k);
      end
    end
  endtask


  initial begin
    $dumpfile("spi_top_tb.vcd");
    $dumpvars(0, spi_top_tb);

    errors    = 0;
    rst_n     = 1'b0;
    bus_wr    = 1'b0;
    bus_addr  = 5'd0;
    bus_wdata = 32'd0;

    repeat (4) begin
      @(negedge clk);
    end
    rst_n = 1'b1;


    // These basic tests check the spi registers
    check_read(CFG, 32'h0000_FF00, "reset CFG");
    check_read(CTRL, 32'h0000_0000, "reset CTRL");
    check_read(TXDATA, 32'h0000_0000, "reset TXDATA");
    check_read(RXDATA, 32'h0000_0000, "reset RXDATA");
    check_read(STATUS, 32'h0000_0000, "reset STATUS");

    // Readback spi top registers
    bus_write(CFG, 32'hDEAD_BEEF);
    check_read(CFG, 32'h0000_BE03, "CFG readback");

    bus_write(TXDATA, 32'h1234_5678);
    check_read(TXDATA, 32'h0000_0078, "TXDATA readback");

    bus_write(CTRL, 32'h5A5A_5A06);
    check_read(CTRL, 32'h0000_0002 | ((32'h5A & ((1 << CS_SEL_W) - 1)) << 8), "CTRL cfg_wr reads 0");

    // Read only and unmapped addresses
    bus_write(RXDATA, 32'hFFFF_FFFF);
    check_read(RXDATA, 32'h0000_0000, "RXDATA ignores writes");

    bus_write(STATUS, 32'hFFFF_FFFF);
    check_read(STATUS, 32'h0000_0000, "STATUS ignores writes");

    bus_write(5'h14, 32'hFFFF_FFFF);
    check_read(5'h14, 32'h0000_0000, "unmapped reads 0");


    // Write a single byte to each device
    for (d = 0; d < NUM_DEVICES; d = d + 1) begin
      wait_idle;
      spi_config(SLAVE_CPOL[d], SLAVE_CPHA[d], 8'd2);
      set_resp(d, 0, 8'h3C ^ d[7:0]);
      log_clear_all;

      spi_xfer(d, 8'hA5 ^ d[7:0], 1'b0, rx);
      wait_idle;

      $display("mode %0d single byte results", d);
      check_eq(rx, 8'h3C ^ d[7:0], "master received slave response");
      exp[0] = 8'hA5 ^ d[7:0];
      check_log(d, 1, "slave received master byte");
      for (n = 0; n < NUM_DEVICES; n = n + 1) begin
        if (n != d) begin
          check_log(n, 0, "unselected device saw nothing");
        end
      end
    end


    // Multi-byte with more
    for (d = 0; d < NUM_DEVICES; d = d + 1) begin
      wait_idle;
      spi_config(SLAVE_CPOL[d], SLAVE_CPHA[d], 8'd1);
      set_resp(d, 0, 8'h11);
      set_resp(d, 1, 8'h22);
      set_resp(d, 2, 8'h33);
      log_clear(d);

      $display("mode %0d three byte transaction", d);
      spi_xfer(d, 8'hC0, 1'b1, rx);
      check_eq(rx, 8'h11, "byte 0 response");
      check_read(STATUS, 32'h0000_0004, "open and not busy between bytes");
      spi_xfer(d, 8'hC1, 1'b1, rx);
      check_eq(rx, 8'h22, "byte 1 response");
      check_read(STATUS, 32'h0000_0004, "open and not busy between bytes");
      spi_xfer(d, 8'hC2, 1'b0, rx);
      check_eq(rx, 8'h33, "byte 2 response");
      wait_idle;
      check_read(STATUS, 32'h0000_0000, "closed after last byte");

      exp[0] = 8'hC0;
      exp[1] = 8'hC1;
      exp[2] = 8'hC2;
      check_log(d, 3, "slave received all three bytes");
    end


    // Check one
    $display("done flag");
    wait_idle;
    spi_config(SLAVE_CPOL[0], SLAVE_CPHA[0], 8'd1);
    bus_write(TXDATA, 32'h0000_005A);
    bus_write(CTRL, 32'h0000_0001);
    wait_idle;
    check_read(STATUS, 32'h0000_0002, "done set after transfer");
    bus_write(STATUS, 32'h0000_0000);
    check_read(STATUS, 32'h0000_0002, "done ignores write 0");
    bus_write(STATUS, 32'h0000_0002);
    check_read(STATUS, 32'h0000_0000, "done cleared by write 1");


    $display("done cleared by start");
    wait_idle;
    spi_config(SLAVE_CPOL[0], SLAVE_CPHA[0], 8'd8);
    bus_write(TXDATA, 32'h0000_0011);
    bus_write(CTRL, 32'h0000_0001);
    wait_idle;
    check_read(STATUS, 32'h0000_0002, "done set after first byte");
    bus_write(TXDATA, 32'h0000_0022);
    bus_write(CTRL, 32'h0000_0001);
    check_read(STATUS, 32'h0000_0005, "done cleared by accepted start");
    wait_idle;
    check_read(STATUS, 32'h0000_0002, "done set after second byte");
    bus_write(STATUS, 32'h0000_0002);


    $display("done wins over W1C");
    wait_idle;
    bus_write(TXDATA, 32'h0000_0033);
    bus_write(CTRL, 32'h0000_0001);
    repeat (2 * DATA_W) begin
      @(sclk);
    end
    bus_write(STATUS, 32'h0000_0002);
    wait_idle;
    check_read(STATUS, 32'h0000_0002, "done kept when W1C lands with done");
    bus_write(STATUS, 32'h0000_0002);


    // start while busy is ignored
    $display("start while busy");
    wait_idle;
    spi_config(SLAVE_CPOL[0], SLAVE_CPHA[0], 8'd8);
    log_clear(0);
    bus_write(TXDATA, 32'h0000_0066);
    bus_write(CTRL, 32'h0000_0001);
    check_read(STATUS, 32'h0000_0005, "busy and open during transfer");
    bus_write(TXDATA, 32'h0000_0099);
    bus_write(CTRL, 32'h0000_0001);
    wait_idle;
    bus_write(STATUS, 32'h0000_0002);
    exp[0] = 8'h66;
    check_log(0, 1, "second start ignored");


    // cfg_wr test
    $display("cfg_wr while open");
    wait_idle;
    spi_config(SLAVE_CPOL[T_DEV], SLAVE_CPHA[T_DEV], 8'd2);
    set_resp(T_DEV, 0, 8'hAB);
    set_resp(T_DEV, 1, 8'hCD);
    log_clear(T_DEV);
    spi_xfer(T_DEV, 8'h12, 1'b1, rx);
    spi_config(~SLAVE_CPOL[T_DEV], ~SLAVE_CPHA[T_DEV], 8'd5);  // Opposite mode: would corrupt the next byte if applied
    check_read(CFG, {16'h0000, 8'd5, 6'b000000, ~SLAVE_CPHA[T_DEV], ~SLAVE_CPOL[T_DEV]},
               "CFG holds the new (unapplied) value");
    spi_xfer(T_DEV, 8'h34, 1'b0, rx);
    check_eq(rx, 8'hCD, "second byte response still correct");
    wait_idle;
    exp[0] = 8'h12;
    exp[1] = 8'h34;
    check_log(T_DEV, 2, "both bytes sent in the original mode");


    if (NUM_DEVICES > 1) begin
      $display("cs_sel while open");
      wait_idle;
      spi_config(SLAVE_CPOL[T_DEV], SLAVE_CPHA[T_DEV], 8'd2);
      set_resp(T_DEV, 0, 8'h5A);
      set_resp(T_DEV, 1, 8'hA5);
      log_clear_all;
      spi_xfer(T_DEV, 8'h77, 1'b1, rx);
      spi_xfer(OTHER_DEV, 8'h88, 1'b0, rx);
      check_eq(rx, 8'hA5, "second byte answered by the first device");
      wait_idle;
      exp[0] = 8'h77;
      exp[1] = 8'h88;
      check_log(T_DEV, 2, "first device got both bytes");
      check_log(OTHER_DEV, 0, "new cs_sel device got nothing");
    end


    // Clock divider tests
    for (n = 0; n < 4; n = n + 1) begin
      wait_idle;
      spi_config(SLAVE_CPOL[0], SLAVE_CPHA[0], n[7:0] * 8'd3);
      bus_write(TXDATA, 32'h0000_00F0);
      bus_write(CTRL, 32'h0000_0001);
      @(posedge sclk);
      t_rise0 = $time;
      @(posedge sclk);
      t_rise1 = $time;
      wait_idle;
      bus_write(STATUS, 32'h0000_0002);

      $display("sclk_half_div = %0d", n * 3);
      check_eq(t_rise1 - t_rise0, 2 * (n * 3 + 1) * CLK_PERIOD, "sclk period");
    end


    $display("read and write same cycle");
    wait_idle;
    bus_write(TXDATA, 32'h0000_0011);
    bus_rw(TXDATA, 32'h0000_0022, rdata);
    check_eq(rdata, 32'h0000_0011, "TXDATA read returns old value");
    check_read(TXDATA, 32'h0000_0022, "TXDATA write landed");
    bus_write(CTRL, 32'h0000_0001);
    wait_idle;
    bus_rw(STATUS, 32'h0000_0002, rdata);
    check_eq(rdata, 32'h0000_0002, "STATUS read returns done before clear");
    check_read(STATUS, 32'h0000_0000, "STATUS W1C landed");


    $display("reset mid-transfer");
    wait_idle;
    spi_config(SLAVE_CPOL[T_DEV], SLAVE_CPHA[T_DEV], 8'd8);
    bus_write(TXDATA, 32'h0000_00AA);
    bus_write(CTRL, (T_DEV << 8) | 32'h0000_0001);
    repeat (3) begin
      @(posedge sclk);
    end
    check_eq(cs_n, {NUM_DEVICES{1'b1}} ^ (1 << T_DEV), "device selected before reset");
    #1 rst_n = 1'b0;
    #8 check_eq({cs_n, sclk, mosi}, {{NUM_DEVICES{1'b1}}, 1'b0, 1'b0}, "async reset idles SPI pins");
    repeat (4) begin
      @(negedge clk);
    end
    rst_n = 1'b1;
    check_read(CFG, 32'h0000_FF00, "CFG back to reset value");
    check_read(CTRL, 32'h0000_0000, "CTRL back to reset value");
    check_read(TXDATA, 32'h0000_0000, "TXDATA back to reset value");
    check_read(RXDATA, 32'h0000_0000, "RXDATA back to reset value");
    check_read(STATUS, 32'h0000_0000, "STATUS back to reset value");


    // Reset CFG is mode 0 with sclk_half_div = 0xFF, the slowest clock
    $display("transfer with reset CFG");
    set_resp(0, 0, 8'h96);
    log_clear_all;
    bus_write(TXDATA, 32'h0000_00C3);
    bus_write(CTRL, 32'h0000_0001);
    @(posedge sclk);
    t_rise0 = $time;
    @(posedge sclk);
    t_rise1 = $time;
    wait_idle;
    bus_write(STATUS, 32'h0000_0002);
    check_eq(t_rise1 - t_rise0, 2 * 256 * CLK_PERIOD, "sclk period at sclk_half_div = 0xFF");
    check_read(RXDATA, 32'h0000_0096, "master received slave response");
    exp[0] = 8'hC3;
    check_log(0, 1, "device 0 received byte in reset mode");

    if (errors == 0) begin
      $display("ALL TESTS PASSED");
    end else begin
      $display("%0d TEST(S) FAILED", errors);
    end
    $finish;
  end

endmodule
