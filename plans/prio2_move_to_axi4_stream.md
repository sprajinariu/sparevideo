
Start with this as a base and Develop this Plan further before implementing!

## Goals

Implement axi4-stream as the base of pipeline architecture.
Investigate available open cores for axi4-stream designs(FIFOs and other utility blocks).


## Non-Goals


## Proposed Architecture

TB -> axi4-stream -> async_FIFO -> internal processing -> async_FIFO -> axi4-stream / VGA -> TB

Make input and output synchronous to a slower display clock 
Processing is done on a faster (200MHz?) clock
output done on either axi4-stream or VGA.
Rename top level and TB to something like sparevideo.
Move sparevideo top into a /top folder.
All other design IPs should go into an /ip folder.

## Open questions
within the internal processing pipeline we might need a frame buffer RAM for future use.
It could require multiple read/write channels and some arbitration.
Evaluate if there's any robust online open core for this.
SInce we are only interested in simulation, the RAM will be FF-based. We don't care about FPGA/ASIC versions.
But the multiple read/write channels and arbitration is what we actually need in digital.
