// tb_top: simulation top for the cocotb testbench. pmu_top plus one domain_shell per domain.
// The Q-Channel devices, power switches, wake sources and APB are driven from Python (tb/).
module tb_top #(
    parameter int              N_PD    = 3,
    parameter logic [N_PD-1:0] HAS_RET = 3'b011,
    parameter int              W       = 8,
    parameter int              N_NORM  = 4,
    parameter int              N_RET   = 2
) (
    input  logic              PCLK, PRESETn, PSEL, PENABLE, PWRITE,
    input  logic [11:0]       PADDR,
    input  logic [31:0]       PWDATA,
    output logic [31:0]       PRDATA,
    output logic              PREADY, PSLVERR,
    output logic [N_PD-1:0]   QREQn,
    input  logic [N_PD-1:0]   QACCEPTn, QDENY, QACTIVE,
    output logic [N_PD-1:0]   clk_en, pd_clk, iso_en, ret_save, ret_restore, rst_n,
    output logic [N_PD-1:0]   psw_trickle_en, psw_main_en,
    input  logic [N_PD-1:0]   psw_trickle_ack, psw_main_ack,
    input  logic [7:0]        wake_irq,
    output logic              irq,
    output logic [7*N_PD:0]   pmu_state,
    // domain shells
    input  logic [N_PD-1:0]   dom_wr_en,
    input  logic [4*N_PD-1:0] dom_wr_idx,
    input  logic [W*N_PD-1:0] dom_wr_data,
    output logic [(N_NORM+N_RET)*W*N_PD-1:0] dom_regs_raw, dom_regs_iso,
    output logic [N_RET*W*N_PD-1:0]           dom_shadow,
    output logic [N_PD-1:0]   dom_rdy_n_iso
);
    pmu_top #(.N_PD(N_PD), .HAS_RET(HAS_RET)) u_pmu (.*);

    for (genvar d = 0; d < N_PD; d++) begin : g_dom
        localparam int RB = (N_NORM + N_RET) * W;
        logic rdy_raw;
        domain_shell #(.N_NORM(N_NORM), .N_RET(N_RET), .HAS_RET(HAS_RET[d]), .W(W),
                       .RST_BASE(W'(8'hA0 + 8'h10 * d))) u_dom (
            .pd_clk(pd_clk[d]), .pwr(psw_trickle_ack[d] && psw_main_ack[d]), .rst_n(rst_n[d]),
            .ret_save(ret_save[d]), .ret_restore(ret_restore[d]), .iso_en(iso_en[d]),
            .wr_en(dom_wr_en[d]), .wr_idx(dom_wr_idx[4*d +: 4]), .wr_data(dom_wr_data[W*d +: W]),
            .regs_raw(dom_regs_raw[RB*d +: RB]), .regs_iso(dom_regs_iso[RB*d +: RB]),
            .rdy_n_raw(rdy_raw), .rdy_n_iso(dom_rdy_n_iso[d]),
            .shadow_o(dom_shadow[N_RET*W*d +: N_RET*W]));
    end
endmodule
