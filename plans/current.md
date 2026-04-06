## TB rework
signals are being driven in the TB on negedge, using blocking operators.
This was done to avoid race conditions with posedge of the design clock.
This is a workaround for the real problem. Synchronous signals in the TB are being driven by blocking operators.
GO back to drive signals on the posedge in the TB, but use non-blocking operators.
Print wall-clock elapsed for each processed frame.

## sim/sv folders
TB source files (tb_sparevideo.sv) should reside in dv/sv.
Simulation should run under dv/sim, and sim objects (.vvp ?) should reside there.

## Text format
Is there a need to have hex space-separated? It increases the file sizes.
If not required remove the space-separation.

## Python
introduce some folder structure to the python files.
Add a /models folder to model future video processing.
/tests can hold all tests specifically designed to test python-only implementation.
Document steps on how to run python-focused tests in readmes as well. These should be rerun after changes to python files. Add some secondary makefile step
Review python scripts for structure. Do we need these all files? it's unclear which files are used from where. 

## Makefile steps
there should be a separate make rtl_compile step to compile the RTL, pre-requisite to make sim
This should depend if files have been updated - should not be run if make run-pipeline is re-started, but RTL is unchanged.
Document what commands use python
Document what make commands can use OPTIONS 


## General guidelines:
Ask follow-up questions and clarify objectives before implementing