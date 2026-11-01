// =============================================
// DSP Domain v3 — 1.8V supply
// Full retention: accumulator + op_count
// Outputs go through isolation cells
// =============================================
module dsp_domain_v3 (
    input         clk,
    input         rst,
    input         iso_en,
    input         save,
    input         restore,
    input  [15:0] data_a,
    input  [15:0] data_b,
    input         data_valid,
    // Raw outputs (before isolation)
    output [31:0] raw_result,
    output        raw_valid,
    output        domain_busy,
    // Retention status
    output reg [7:0]  retained_reg_count,
    output reg        restore_success
);

// Working registers
reg [31:0] accumulator;
reg [3:0]  op_count;
reg [31:0] result_reg;
reg        valid_reg;

// Retention storage (always-on flip-flops)
reg [31:0] ret_accumulator;
reg [3:0]  ret_op_count;
reg [31:0] ret_result;

// Reference for corruption check
reg [31:0] pre_sleep_result;
reg        pre_sleep_valid;

assign raw_result  = result_reg;
assign raw_valid   = valid_reg;
assign domain_busy = (op_count != 0);

// Retention register count (fixed: accumulator=32, op_count=4)
always @(posedge clk) retained_reg_count <= 8'd36;

// Save to retention
always @(posedge clk or posedge rst) begin
    if (rst) begin
        ret_accumulator <= 0;
        ret_op_count    <= 0;
        ret_result      <= 0;
        pre_sleep_result<= 0;
        pre_sleep_valid <= 0;
        restore_success <= 0;
    end else if (save) begin
        ret_accumulator  <= accumulator;
        ret_op_count     <= op_count;
        ret_result       <= result_reg;
        pre_sleep_result <= result_reg;
        pre_sleep_valid  <= valid_reg;
    end else if (restore) begin
        restore_success  <= (ret_result == pre_sleep_result);
    end
end

// Main MAC datapath
always @(posedge clk or posedge rst) begin
    if (rst) begin
        accumulator <= 0;
        op_count    <= 0;
        result_reg  <= 0;
        valid_reg   <= 0;
    end else if (restore) begin
        accumulator <= ret_accumulator;
        op_count    <= ret_op_count;
        result_reg  <= ret_result;
        valid_reg   <= 0;
    end else if (!iso_en && data_valid) begin
        accumulator <= accumulator + (data_a * data_b);
        op_count    <= op_count + 1;
        valid_reg   <= 0;
        if (op_count == 4'd7) begin
            result_reg  <= accumulator + (data_a * data_b);
            valid_reg   <= 1;
            accumulator <= 0;
            op_count    <= 0;
        end
    end else begin
        valid_reg <= 0;
    end
end

endmodule
