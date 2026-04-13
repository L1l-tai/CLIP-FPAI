`timescale 1ns/100ps
module sync_fifo_ctrl 
#(
    parameter ADDRSIZE = 4,
    parameter ALMOST_FULL_TH = 2
)
(
    clk,
    rst_n,
    wfull,
    wfull_almost,
    waddr,
    winc,
    rempty,
    raddr,
    rinc
);

input                   clk;
input                   rst_n;
output                  wfull;
output                  wfull_almost;
output                  rempty;
input                   winc;
input                   rinc;
output  [ADDRSIZE-1:0]  waddr;
output  [ADDRSIZE-1:0]  raddr;

reg     [ADDRSIZE :0]   wptr;
reg     [ADDRSIZE :0]   rptr;
wire    [ADDRSIZE-1 :0] distance_to_full;

always @(posedge clk or negedge rst_n)
if(!rst_n)
    wptr <= 0;
else
    if(winc & (~wfull))
        wptr <= wptr + 1;
    else
        wptr <= wptr;
        
always @(posedge clk or negedge rst_n)
if(!rst_n)
    rptr <= 0;
else
    if(rinc & (~rempty))
        rptr <= rptr + 1;
    else
        rptr <= rptr;

assign  waddr = wptr[ADDRSIZE-1:0];
assign  raddr = rptr[ADDRSIZE-1:0];

assign  wfull = (wptr == {(~rptr[ADDRSIZE]),rptr[ADDRSIZE-1:0]});
assign  distance_to_full = raddr - waddr;
assign  wfull_almost = (distance_to_full <= ALMOST_FULL_TH) & ((rptr[ADDRSIZE] ^ wptr[ADDRSIZE]) | (waddr > raddr));

assign  rempty = (wptr == rptr);


endmodule
