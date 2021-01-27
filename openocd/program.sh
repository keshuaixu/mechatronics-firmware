#!/usr/bin/env bash
openocd -f "interface/ftdi/digilent_jtag_$1.cfg" -f "fpga.cfg" -c "init;program_$2 $3;exit"