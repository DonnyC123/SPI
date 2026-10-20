// Register map:
//   0x00 CFG     RW    [0] cpol, [1] cpha, [15:8] sclk_half_div
//   0x04 CTRL    RW    [0] start (W, reads 0), [1] more, [2] cfg_wr (W, reads 0), [15:8] cs_sel
//   0x08 TXDATA  RW    [7:0] next byte to send
//   0x0C RXDATA  R     [7:0] byte received by the last transfer
//   0x10 STATUS  R/W1C [0] busy, [1] done, [2] open

module spi_top #(
  parameter integer DATA_W          = 8,                                           // <= 32
  parameter integer SCLK_HALF_DIV_W = 8,                                           // <= 8
  parameter integer NUM_DEVICES     = 1,                                           // <= 256
  parameter integer CS_SEL_W        = (NUM_DEVICES > 1) ? $clog2(NUM_DEVICES) : 1
) (
  input  wire                   clk,
  input  wire                   rst_n,

  // Register bus
  input  wire                   bus_wr,
  input  wire [4:0]             bus_addr,
  input  wire [31:0]            bus_wdata,
  output wire [31:0]            bus_rdata,

  // Spi interface
  input  wire                   miso,
  output wire                   sclk,
  output wire                   mosi,
  output wire [NUM_DEVICES-1:0] cs_n
);

  localparam integer       NUM_REGS = 5;
  localparam         [2:0] A_CFG    = 3'd0;
  localparam         [2:0] A_CTRL   = 3'd1;
  localparam         [2:0] A_TXDATA = 3'd2;
  localparam         [2:0] A_RXDATA = 3'd3;
  localparam         [2:0] A_STATUS = 3'd4;


  wire                 busy;
  wire                 done;
  wire    [DATA_W-1:0] rx_data;

  reg     [31:0]       regs_d  [0:NUM_REGS-1];
  reg     [31:0]       regs_q  [0:NUM_REGS-1];
  integer              i;
  integer              j;

  reg                  cfg_wr_d;
  reg                  cfg_wr_q;
  reg                  start_d;
  reg                  start_q;
  reg     [31:0]       rdata_d;
  reg     [31:0]       rdata_q;


  always @(*) begin
    for (i = 0; i < NUM_REGS; i = i + 1) begin
      regs_d[i] = regs_q[i];
    end
    cfg_wr_d = 1'b0;
    start_d  = 1'b0;

    // write interface
    if (bus_wr) begin
      case (bus_addr[4:2])
        A_CFG: begin
          regs_d[A_CFG][1:0]                = bus_wdata[1:0];
          regs_d[A_CFG][8+:SCLK_HALF_DIV_W] = bus_wdata[8+:SCLK_HALF_DIV_W];
        end
        A_CTRL: begin
          regs_d[A_CTRL][1]           = bus_wdata[1];
          regs_d[A_CTRL][8+:CS_SEL_W] = bus_wdata[8+:CS_SEL_W];
          start_d                     = bus_wdata[0];
          cfg_wr_d                    = bus_wdata[2];
        end
        A_TXDATA: begin
          regs_d[A_TXDATA][DATA_W-1:0] = bus_wdata[DATA_W-1:0];
        end
        A_STATUS: begin
          if (bus_wdata[1]) begin
            regs_d[A_STATUS][1] = 1'b0;
          end
        end
        default: begin
        end
      endcase
    end

    // done flag
    if (done) begin
      regs_d[A_STATUS][1] = 1'b1;
    end
    if (start_q && !busy) begin
      regs_d[A_STATUS][1] = 1'b0;
    end

    // read interface
    case (bus_addr[4:2])
      A_CFG: begin
        rdata_d = regs_q[A_CFG];
      end
      A_CTRL: begin
        rdata_d    = regs_q[A_CTRL];
        rdata_d[0] = 1'b0;
        rdata_d[2] = 1'b0;
      end
      A_TXDATA: begin
        rdata_d = regs_q[A_TXDATA];
      end
      A_RXDATA: begin
        rdata_d             = 32'd0;
        rdata_d[DATA_W-1:0] = rx_data;
      end
      A_STATUS: begin
        rdata_d    = 32'd0;
        rdata_d[0] = busy;
        rdata_d[1] = regs_q[A_STATUS][1];
        rdata_d[2] = !(&cs_n);
      end
      default: begin
        rdata_d = 32'd0;
      end
    endcase
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (j = 0; j < NUM_REGS; j = j + 1) begin
        regs_q[j] <= 32'd0;
      end
      regs_q[A_CFG][8+:SCLK_HALF_DIV_W] <= {SCLK_HALF_DIV_W{1'b1}};
      cfg_wr_q                          <= 1'b0;
      start_q                           <= 1'b0;
      rdata_q                           <= 32'd0;
    end else begin
      for (j = 0; j < NUM_REGS; j = j + 1) begin
        regs_q[j] <= regs_d[j];
      end
      cfg_wr_q <= cfg_wr_d;
      start_q  <= start_d;
      rdata_q <= rdata_d;
    end
  end

  assign bus_rdata = rdata_q;


  spi_master #(
      .DATA_W         (DATA_W),
      .SCLK_HALF_DIV_W(SCLK_HALF_DIV_W),
      .NUM_DEVICES    (NUM_DEVICES),
      .CS_SEL_W       (CS_SEL_W)
  ) u_spi_master (
      .clk          (clk),
      .rst_n        (rst_n),
      .cfg_wr       (cfg_wr_q),
      .sclk_half_div(regs_q[A_CFG][8+:SCLK_HALF_DIV_W]),
      .cpol         (regs_q[A_CFG][0]),
      .cpha         (regs_q[A_CFG][1]),
      .start        (start_q),
      .more         (regs_q[A_CTRL][1]),
      .cs_sel       (regs_q[A_CTRL][8+:CS_SEL_W]),
      .tx_data      (regs_q[A_TXDATA][DATA_W-1:0]),
      .busy         (busy),
      .done         (done),
      .rx_data      (rx_data),
      .miso         (miso),
      .sclk         (sclk),
      .mosi         (mosi),
      .cs_n         (cs_n)
  );

endmodule
