### Add Control-flows
Introduce Control Flows: 
- passthrough - no processing
- grayscale - for debug, to visualize the RGB to Y conversion
  Y values passed through RAM should be outputed on VGA.
  This way we can test RGB->Y conversion and general RAM access.
- motion detection

Place muxes and enables in the design to selectively enable certain blocks.
Implement these as top level side-band signals for now, driven by the TB. To be extended as control registers in the future.
Add control-flows as makefile option.
Inform Python env about control-flows since it impacts what it has to verify.

### Refine IP testbenches
make a plan to increase verification coverage for the IP testbenches.
especially datapath checks are not sufficient.


### Architecture spec
go through axi4-stream_video_motion_detection.md and place all relevant sections in README.md and Claude.md files.
the README.md should not contain architecture details, place all architecture documents in docs/specs/.
Write major architecture specification, strategies, and decisions into the top level architecture document (`2026-04-08-sparevideo-top-arch.md`).
Write detailed specification for each module in their own module architecture document, one document per module under `docs/specs/`. Name it `YYYY-MM-DD-<module>-arch.md`.


### Refine skills
Refine skills present in .claude/skills, add particulars related to sparevideo.

### Add software-testing skill
Add a software-testing skill for writing python tests
For every added control flow, write a new control flow model in python.
Verify correctness of RTL video output by comparing to the model python control flow