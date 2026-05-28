// =============================================
// MEM Domain v3 — 1.2V supply
// Receives data through level shifters
// Has retention for buffer pointers
// =============================================
module mem_domain_v3 (
    input         clk,
    input         rst,
    input         iso_en,
    input         save,
    input         restore,
    input  [31:0] data_in,   // already level-shifted
    input         data_valid,
    output [31:0] mem_out,
    output        buffer_full,
    output [3:0]  fill_level,
    output reg [7:0] retained_reg_count
);

reg [31:0] buffer [0:7];
reg [3:0]  wr_ptr, rd_ptr;
reg        full_reg;

// Retention
reg [3:0] ret_wr_ptr, ret_rd_ptr;

assign mem_out    = iso_en ? 32'h0 : buffer[rd_ptr[2:0]];
assign buffer_full= iso_en ? 1'b0  : full_reg;
assign fill_level = iso_en ? 4'h0  : (wr_ptr - rd_ptr);

always @(posedge clk) retained_reg_count = 8'd8; // wr_ptr + rd_ptr

always @(posedge clk or posedge rst) begin
    if (rst) begin
        ret_wr_ptr <= 0;
        ret_rd_ptr <= 0;
    end else if (save) begin
        ret_wr_ptr <= wr_ptr;
        ret_rd_ptr <= rd_ptr;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wr_ptr   <= 0;
        rd_ptr   <= 0;
        full_reg <= 0;
    end else if (restore) begin
        wr_ptr <= ret_wr_ptr;
        rd_ptr <= ret_rd_ptr;
    end else if (!iso_en) begin
        if (data_valid && !full_reg) begin
            buffer[wr_ptr[2:0]] <= data_in;
            wr_ptr   <= wr_ptr + 1;
            full_reg <= ((wr_ptr + 1'b1) == rd_ptr);
        end
        if (full_reg) begin
            rd_ptr   <= rd_ptr + 1;
            full_reg <= 0;
        end
    end
end

endmodule
