`timescale 1ns/100ps
module sync_fifo_reg
#(
    parameter ALMOST_FULL_TH = 2,
    parameter DSIZE = 8,
    parameter ASIZE = 4
)
(
    clk,
    rst_n,
    winc,
    wdata,
    wfull,
    wfull_almost,
    rempty,
    rinc,
    rdata
);

input                   clk;
input                   rst_n;
output  [DSIZE-1:0]     rdata;
output                  wfull;
output                  wfull_almost;
output                  rempty;
input   [DSIZE-1:0]     wdata;
input                   winc;
input                   rinc;

wire [ASIZE-1:0]    waddr, raddr;

sync_fifo_ctrl #( .ADDRSIZE(ASIZE), .ALMOST_FULL_TH(ALMOST_FULL_TH)) 
sync_fifo_ctrl_inst
(
    .clk            (clk   ),
    .rst_n          (rst_n ),
    .wfull          (wfull ),
    .wfull_almost   (wfull_almost),
    .waddr          (waddr ),
    .winc           (winc  ),
    .rempty         (rempty),
    .raddr          (raddr ),
    .rinc           (rinc  )
);

fifomem #(DSIZE, ASIZE) fifomem
(
    .rdata  (rdata), 
    .wdata  (wdata),
    .waddr  (waddr), 
    .raddr  (raddr),
    .wclken (winc), 
    .wfull  (wfull),
    .wclk   (clk)
);

endmodule
