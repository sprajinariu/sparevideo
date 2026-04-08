## TB rework
combine the common logic between sw-dry-run branch with the normal RTL branch in the TB.
The branches have a lot of common logic.

## Python


## Makefile steps
Document which steps accept <options>, it is unclear.
is it run-pipeline? compile? which one.
if prepare command is given with <options>, does sim still need to be passed the same <options>?

## Verilator support
default sim/compile steps will use Verilator from now on.
Keep iverilog as a backup solution, selectable via an option for applicable make steps (compile, sim).


## Readmes:
