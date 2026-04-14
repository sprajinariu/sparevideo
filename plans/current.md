### Add Control-flows
Introduce Control Flows: 
- passthrough - no processing
- motion detection

Place muxes in the design to selectively enable certain blocks.
If a block output is left unconnected, make sure it's backpressure input from the consumer side is tied to 1, so that it doesn't affect earlier pipeline stages.
Implement the control flow selection as a top level side-band signal for now, driven by the TB. To be extended as control registers in the future.
Add control-flows as makefile option.

### Refine IP testbenches
plans/old/2026-04-14_increase-ip-tb-coverage.md — DONE

### Update RTL: Async reset
switch to an async reset instead of synchronous

### Add software-testing skill
Add a software-testing skill for writing python tests


### Add control flow selection to python env
Inform Python env about control-flows since it impacts what it has to verify.
Use different models for different control flows.
Add a python model for pass-through and for grayscale.
Create a python model and use it to verify the design implementation.
Should be pixel-accurate.
