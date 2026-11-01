// domain_shell: behavioural model of a switchable domain for power-aware simulation
// (docs/BRIEF.md A3). Not synthesised. Uses Icarus 4-state values to model power loss.
//   * N_NORM normal registers: reset to RST_BASE+i; become X when power is lost.
//   * N_RET retention registers (if HAS_RET): a live copy in the domain (X when power is lost) and
//     an always-on shadow written by ret_save. ret_restore loads the shadow back; a restore
//     overrides the domain reset (docs/DECISIONS.md D-003.6). Without a restore since the last
//     power loss, the live copy comes out of reset as 0.
//   * Every output leaves through an isolation clamp powered from AON (behavioural iso_wrap):
//     the register bus clamps to 0, rdy_n clamps to 1.
// pwr = both power switches acknowledged (from the switch model).
module domain_shell #(
    parameter int     N_NORM   = 4,
    parameter int     N_RET    = 2,
    parameter bit     HAS_RET  = 1'b1,
    parameter int     W        = 8,
    parameter logic [W-1:0] RST_BASE = 8'hA0
) (
    input  logic                       pd_clk,
    input  logic                       pwr,
    input  logic                       rst_n,
    input  logic                       ret_save,
    input  logic                       ret_restore,
    input  logic                       iso_en,
    // testbench write port (domain side, clocked by pd_clk)
    input  logic                       wr_en,
    input  logic [3:0]                 wr_idx,     // 0..N_NORM-1 normal, N_NORM.. retention
    input  logic [W-1:0]               wr_data,
    // raw (domain side) and isolated (AON side) outputs
    output logic [(N_NORM+N_RET)*W-1:0] regs_raw,
    output logic [(N_NORM+N_RET)*W-1:0] regs_iso,
    output logic                       rdy_n_raw,
    output logic                       rdy_n_iso,
    // retention shadow, for the scoreboard
    output logic [N_RET*W-1:0]         shadow_o
);
    logic [W-1:0] nreg   [N_NORM];
    logic [W-1:0] rlive  [N_RET];
    logic [W-1:0] shadow [N_RET];
    logic         restored;       // a restore happened since the last power loss

    // power loss: everything powered by the domain becomes X
    always @(negedge pwr) begin
        for (int i = 0; i < N_NORM; i++) nreg[i] = 'x;
        for (int i = 0; i < N_RET; i++)  rlive[i] = 'x;
        restored = 1'b0;
    end
    initial begin
        for (int i = 0; i < N_NORM; i++) nreg[i] = 'x;
        for (int i = 0; i < N_RET; i++)  begin rlive[i] = 'x; shadow[i] = '0; end
        restored = 1'b0;
    end

    // normal registers: asynchronous reset while powered, writes on the domain clock
    always @(posedge pd_clk or negedge rst_n or posedge pwr) begin
        if (!pwr) begin
            // unpowered: stays X
        end else if (!rst_n) begin
            for (int i = 0; i < N_NORM; i++) nreg[i] <= RST_BASE + W'(i);
        end else if (wr_en && wr_idx < N_NORM) begin
            nreg[wr_idx] <= wr_data;
        end
    end

    if (HAS_RET) begin : g_ret
        // save: shadow (AON) captures the live copy on the rising edge of ret_save
        always @(posedge ret_save) for (int i = 0; i < N_RET; i++) shadow[i] <= rlive[i];
        // restore (level) overrides reset; reset applies only if nothing was restored
        always @(posedge pd_clk or negedge rst_n or posedge ret_restore or posedge pwr) begin
            if (!pwr) begin
            end else if (ret_restore) begin
                for (int i = 0; i < N_RET; i++) rlive[i] <= shadow[i];
                restored <= 1'b1;
            end else if (!rst_n) begin
                if (!restored) for (int i = 0; i < N_RET; i++) rlive[i] <= '0;
            end else if (wr_en && wr_idx >= N_NORM && wr_idx < N_NORM + N_RET) begin
                rlive[wr_idx - N_NORM] <= wr_data;
            end
        end
    end else begin : g_noret
        always @(posedge pd_clk or negedge rst_n or posedge pwr) begin
            if (!pwr) begin
            end else if (!rst_n) begin
                for (int i = 0; i < N_RET; i++) rlive[i] <= '0;
            end else if (wr_en && wr_idx >= N_NORM && wr_idx < N_NORM + N_RET) begin
                rlive[wr_idx - N_NORM] <= wr_data;
            end
        end
    end

    always_comb begin
        for (int i = 0; i < N_NORM; i++) regs_raw[i*W +: W] = nreg[i];
        for (int i = 0; i < N_RET; i++)  regs_raw[(N_NORM+i)*W +: W] = rlive[i];
        for (int i = 0; i < N_RET; i++)  shadow_o[i*W +: W] = shadow[i];
    end
    assign rdy_n_raw = pwr ? !rst_n : 1'bx;           // "not ready" flag, X when unpowered

    // isolation clamps (AON side): bus clamp 0, rdy_n clamp 1
    for (genvar b = 0; b < (N_NORM+N_RET)*W; b++) begin : g_iso
        iso_wrap #(.CLAMP(1'b0)) u_iso (.d(regs_raw[b]), .iso_en(iso_en), .q(regs_iso[b]));
    end
    iso_wrap #(.CLAMP(1'b1)) u_iso_rdy (.d(rdy_n_raw), .iso_en(iso_en), .q(rdy_n_iso));
endmodule
