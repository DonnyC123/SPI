module spi_master #(
  parameter integer DATA_W          = 8,                                           // Bits per word (fixed, MSB first)
  parameter integer SCLK_HALF_DIV_W = 8,
  parameter integer NUM_DEVICES     = 1,
  parameter integer CS_SEL_W        = (NUM_DEVICES > 1) ? $clog2(NUM_DEVICES) : 1
) (
  input  wire                       clk,
  input  wire                       rst_n,

  // Config, loaded on cfg_wr (ignored unless idle)
  input  wire                       cfg_wr,
  input  wire [SCLK_HALF_DIV_W-1:0] sclk_half_div,  // sclk = clk / (2 * (sclk_half_div + 1))
  input  wire                       cpol,           // Idle level of sclk (0 -> idle low)
  input  wire                       cpha,           // Sample edge (0 -> leading, 1 -> trailing)

  // Transfer control
  input  wire                       start,          // 1-cycle pulse, ignored if busy
  input  wire                       more,           // Sampled on start
  input  wire [DATA_W-1:0]          tx_data,        // Sampled on start
  input  wire [CS_SEL_W-1:0]        cs_sel,         // Sampled on first start

  // Status
  output wire                       busy,
  output wire                       done,
  output wire [DATA_W-1:0]          rx_data,

  // Spi interface
  input  wire                       miso,
  output wire                       sclk,
  output wire                       mosi,
  output wire [NUM_DEVICES-1:0]     cs_n
);

  localparam integer               STATE_W    = 5;
  localparam         [STATE_W-1:0] S_IDLE     = 5'b00001;
  localparam         [STATE_W-1:0] S_CONTINUE = 5'b00010;
  localparam         [STATE_W-1:0] S_SETUP    = 5'b00100;
  localparam         [STATE_W-1:0] S_SHIFT    = 5'b01000;
  localparam         [STATE_W-1:0] S_HOLD     = 5'b10000;

  localparam integer               EDGE_W     = $clog2(2 * DATA_W);  // 2 sclk edges per bit
  localparam integer               LAST_EDGE  = 2 * DATA_W - 1;

  // Config
  reg                       cpol_d;
  reg                       cpol_q;
  reg                       cpha_d;
  reg                       cpha_q;
  reg [SCLK_HALF_DIV_W-1:0] sclk_half_div_d;
  reg [SCLK_HALF_DIV_W-1:0] sclk_half_div_q;

  // Control
  reg [STATE_W-1:0]         state_d;
  reg [STATE_W-1:0]         state_q;
  reg [NUM_DEVICES-1:0]     cs_n_d;
  reg [NUM_DEVICES-1:0]     cs_n_q;
  reg                       sclk_d;
  reg                       sclk_q;
  reg                       more_d;
  reg                       more_q;
  reg [EDGE_W-1:0]          edge_cnt_d;
  reg [EDGE_W-1:0]          edge_cnt_q;
  reg                       done_d;
  reg                       done_q;

  reg [DATA_W-1:0]          tx_data_d;  // TX shift register, MSB goes out first
  reg [DATA_W-1:0]          tx_data_q;
  reg                       mosi_d;
  reg                       mosi_q;
  reg [DATA_W-1:0]          rx_shift_d;  // RX shift register, miso shifts in at LSB
  reg [DATA_W-1:0]          rx_shift_q;
  reg [DATA_W-1:0]          rx_data_d;
  reg [DATA_W-1:0]          rx_data_q;

  reg [SCLK_HALF_DIV_W-1:0] div_cnt_d;
  reg [SCLK_HALF_DIV_W-1:0] div_cnt_q;

  reg                       sclk_en;
  reg                       tick;
  reg                       sample_edge;
  reg                       last_edge;

  // Config register: only writable while idle (cs_n high)
  always @(*) begin
    cpol_d          = cpol_q;
    cpha_d          = cpha_q;
    sclk_half_div_d = sclk_half_div_q;
    if (cfg_wr && state_q == S_IDLE) begin
      cpol_d          = cpol;
      cpha_d          = cpha;
      sclk_half_div_d = sclk_half_div;
    end
  end

  // Control FSM and data path: cs_n, sclk, mosi, miso
  always @(*) begin
    sample_edge = (edge_cnt_q[0] == cpha_q);
    last_edge   = (edge_cnt_q == LAST_EDGE[EDGE_W-1:0]);


    state_d    = state_q;
    cs_n_d     = cs_n_q;
    sclk_d     = sclk_q;
    more_d     = more_q;
    edge_cnt_d = edge_cnt_q;
    tx_data_d  = tx_data_q;
    mosi_d     = mosi_q;
    rx_shift_d = rx_shift_q;
    rx_data_d  = rx_data_q;
    done_d     = 1'b0;
    sclk_en    = 1'b0;

    case (state_q)
      S_IDLE: begin
        sclk_d = cpol_d;  // Hold sclk at its idle level (follows a cfg_wr this cycle)
        if (start) begin
          more_d         = more;
          edge_cnt_d     = {EDGE_W{1'b0}};
          cs_n_d         = {NUM_DEVICES{1'b1}};
          cs_n_d[cs_sel] = 1'b0;
          if (cpha_d) begin
            tx_data_d = tx_data;  // CPHA=1: MSB goes out on the first edge
          end else begin
            {mosi_d, tx_data_d} = {tx_data, 1'b0};  // CPHA=0: first edge samples, MSB out now
          end
          state_d = S_SETUP;
        end
      end

      // Between bytes: cs_n stays low, sclk idles
      S_CONTINUE: begin
        if (start) begin
          more_d     = more;
          edge_cnt_d = {EDGE_W{1'b0}};
          if (cpha_q) begin
            tx_data_d = tx_data;  // CPHA=1: MSB goes out on the first edge
          end else begin
            {mosi_d, tx_data_d} = {tx_data, 1'b0};  // CPHA=0: first edge samples, MSB out now
          end
          state_d = S_SHIFT;  // cs_n already low, no setup needed
        end
      end

      S_SETUP: begin
        sclk_en = 1'b1;
        if (tick) begin
          state_d = S_SHIFT;
        end
      end

      S_SHIFT: begin
        sclk_en = 1'b1;
        if (tick) begin
          sclk_d     = ~sclk_q;
          edge_cnt_d = edge_cnt_q + 1'b1;
          if (sample_edge) begin
            rx_shift_d = {rx_shift_q[DATA_W-2:0], miso};
          end else begin
            {mosi_d, tx_data_d} = {tx_data_q, 1'b0};
          end
          if (last_edge) begin
            done_d    = 1'b1;
            rx_data_d = rx_shift_d;  // Includes this edge's sample
            if (more_q) begin
              state_d = S_CONTINUE;
            end else begin
              state_d = S_HOLD;
            end
          end
        end
      end

      S_HOLD: begin
        sclk_en = 1'b1;
        if (tick) begin
          cs_n_d  = {NUM_DEVICES{1'b1}};
          state_d = S_IDLE;
        end
      end

      default: begin
        cs_n_d  = {NUM_DEVICES{1'b1}};
        state_d = S_IDLE;
      end
    endcase
  end

  // Half period timer: tick every (sclk_half_div + 1) when sclk_en
  always @(*) begin
    tick = sclk_en && (div_cnt_q == {SCLK_HALF_DIV_W{1'b0}});
    if (!sclk_en || tick) begin
      div_cnt_d = sclk_half_div_d;
    end else begin
      div_cnt_d = div_cnt_q - 1'b1;
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cpol_q          <= 1'b0;
      cpha_q          <= 1'b0;
      sclk_half_div_q <= {SCLK_HALF_DIV_W{1'b1}};
      state_q         <= S_IDLE;
      cs_n_q          <= {NUM_DEVICES{1'b1}};
      sclk_q          <= 1'b0;
      more_q          <= 1'b0;
      edge_cnt_q      <= {EDGE_W{1'b0}};
      done_q          <= 1'b0;
      tx_data_q       <= {DATA_W{1'b0}};
      mosi_q          <= 1'b0;
      rx_shift_q      <= {DATA_W{1'b0}};
      rx_data_q       <= {DATA_W{1'b0}};
      div_cnt_q       <= {SCLK_HALF_DIV_W{1'b1}};
    end else begin
      cpol_q          <= cpol_d;
      cpha_q          <= cpha_d;
      sclk_half_div_q <= sclk_half_div_d;
      state_q         <= state_d;
      cs_n_q          <= cs_n_d;
      sclk_q          <= sclk_d;
      more_q          <= more_d;
      edge_cnt_q      <= edge_cnt_d;
      done_q          <= done_d;
      tx_data_q       <= tx_data_d;
      mosi_q          <= mosi_d;
      rx_shift_q      <= rx_shift_d;
      rx_data_q       <= rx_data_d;
      div_cnt_q       <= div_cnt_d;
    end
  end

  assign busy    = !(state_q == S_IDLE || state_q == S_CONTINUE);
  assign done    = done_q;
  assign rx_data = rx_data_q;
  assign sclk    = sclk_q;
  assign mosi    = mosi_q;
  assign cs_n    = cs_n_q;

endmodule
