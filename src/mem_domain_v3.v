module mem_domain_v3 (
    input         clk,
    input         rst,
    input         iso_en,
    input         save,
    input         restore,
    input  [31:0] data_in,
    input         data_valid,
    output [31:0] mem_out,
    output        buffer_full,
    output [3:0]  fill_level,
    output reg [7:0] retained_reg_count
);

// Replace array with explicit registers to avoid Yosys memory issues
reg [31:0] buf0, buf1, buf2, buf3, buf4, buf5, buf6, buf7;
reg [2:0]  wr_ptr, rd_ptr;
reg        full_reg;

// Retention
reg [2:0] ret_wr_ptr, ret_rd_ptr;

// Read mux
reg [31:0] rd_data;
always @(*) begin
    case (rd_ptr)
        3'd0: rd_data = buf0;
        3'd1: rd_data = buf1;
        3'd2: rd_data = buf2;
        3'd3: rd_data = buf3;
        3'd4: rd_data = buf4;
        3'd5: rd_data = buf5;
        3'd6: rd_data = buf6;
        3'd7: rd_data = buf7;
        default: rd_data = 32'h0;
    endcase
end

assign mem_out    = iso_en ? 32'h0 : rd_data;
assign buffer_full= iso_en ? 1'b0  : full_reg;
assign fill_level = iso_en ? 4'h0  : {1'b0, wr_ptr} - {1'b0, rd_ptr};

always @(posedge clk or posedge rst) begin
    if (rst) retained_reg_count <= 8'd8;
    else     retained_reg_count <= 8'd8;
end

// Retention save
always @(posedge clk or posedge rst) begin
    if (rst) begin
        ret_wr_ptr <= 0;
        ret_rd_ptr <= 0;
    end else if (save) begin
        ret_wr_ptr <= wr_ptr;
        ret_rd_ptr <= rd_ptr;
    end
end

// Write mux
always @(posedge clk or posedge rst) begin
    if (rst) begin
        buf0 <= 0; buf1 <= 0; buf2 <= 0; buf3 <= 0;
        buf4 <= 0; buf5 <= 0; buf6 <= 0; buf7 <= 0;
        wr_ptr   <= 0;
        rd_ptr   <= 0;
        full_reg <= 0;
    end else if (restore) begin
        wr_ptr <= ret_wr_ptr;
        rd_ptr <= ret_rd_ptr;
    end else if (!iso_en) begin
        if (data_valid && !full_reg) begin
            case (wr_ptr)
                3'd0: buf0 <= data_in;
                3'd1: buf1 <= data_in;
                3'd2: buf2 <= data_in;
                3'd3: buf3 <= data_in;
                3'd4: buf4 <= data_in;
                3'd5: buf5 <= data_in;
                3'd6: buf6 <= data_in;
                3'd7: buf7 <= data_in;
            endcase
            wr_ptr   <= wr_ptr + 1;
            full_reg <= (wr_ptr + 1'b1 == rd_ptr);
        end
        if (full_reg) begin
            rd_ptr   <= rd_ptr + 1;
            full_reg <= 0;
        end
    end
end

endmodule
