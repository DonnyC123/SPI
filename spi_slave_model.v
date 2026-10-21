// Behavioral SPI slave

module spi_slave_model #(
  parameter integer DATA_W     = 8,
  parameter         CPOL       = 1'b0,
  parameter         CPHA       = 1'b0,
  parameter integer RESP_DEPTH = 16
) (
  input  wire              cs_n,
  input  wire              sclk,
  input  wire              mosi,
  output reg               miso,

  input  wire [RESP_DEPTH*DATA_W-1:0] resp,  // Byte k is sent k-th in each transaction

  output reg  [DATA_W-1:0] rx_byte,  // Last full byte
  output reg  [31:0]       rx_count
);

  localparam           SAMPLE_RISING = (CPOL == CPHA);  // Modes 0 and 3 sample on rising

  integer              resp_idx;

  reg     [DATA_W-1:0] tx_shift;
  reg     [DATA_W-1:0] rx_shift;
  integer              tx_left;
  integer              rx_bits;

  // Drive the next bit on miso
  task automatic shift_out;
    begin
      if (tx_left == 0) begin
        tx_shift = resp[(resp_idx % RESP_DEPTH)*DATA_W +: DATA_W];
        tx_left  = DATA_W;
        resp_idx = resp_idx + 1;
      end
      miso     = tx_shift[DATA_W-1];
      tx_shift = tx_shift << 1;
      tx_left  = tx_left - 1;
    end
  endtask

  task automatic sample_in;
    begin
      rx_shift = {rx_shift[DATA_W-2:0], mosi};
      rx_bits  = rx_bits + 1;
      if (rx_bits == DATA_W) begin
        rx_byte  = rx_shift;
        rx_count = rx_count + 1;
        rx_bits  = 0;
      end
    end
  endtask


  initial begin
    miso     = 1'b0;
    rx_byte  = {DATA_W{1'b0}};
    rx_count = 0;
    resp_idx = 0;
    tx_shift = {DATA_W{1'b0}};
    rx_shift = {DATA_W{1'b0}};
    tx_left  = 0;
    rx_bits  = 0;
  end

  // Start of a transaction
  always @(negedge cs_n) begin
    resp_idx = 0;
    tx_left  = 0;
    rx_bits  = 0;
    if (CPHA == 0) begin
      shift_out;
    end
  end

  // sclk edges: sample on one edge, shift on the other
  always @(sclk) begin
    if (!cs_n) begin
      if (sclk == SAMPLE_RISING) begin
        sample_in;
      end else begin
        shift_out;
      end
    end
  end

endmodule
