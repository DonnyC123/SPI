# RHEL 8 (moore) with the ece393 tools
#   make sim      RTL sim, NUM_DEVICES = 1 and 4
#   make synth    harden NUM_DEVICES = 1 and 4, then gate-level sim each (functional and SDF)
#   make sim1 / sim4 / harden1 / harden4 / gls1 / gls4 / sdf1 / sdf4 for one variant

ECE393    ?= /vol/ece393
PDK_ROOT  ?= $(ECE393)/open_pdks/share/pdk
SKY130A   := $(PDK_ROOT)/sky130A
CELLS     := $(SKY130A)/libs.ref/sky130_fd_sc_hd/verilog
RUNS      ?= runs

export PATH            := $(ECE393)/tools/bin:$(ECE393)/tools/klayout:$(ECE393)/oss-cad-suite/bin:$(PATH)
export LD_LIBRARY_PATH := $(ECE393)/tools/klayout$(if $(LD_LIBRARY_PATH),:$(LD_LIBRARY_PATH))
export PYTHONPATH      := $(ECE393)/tools/klayout/pymod$(if $(PYTHONPATH),:$(PYTHONPATH))
export PDK_ROOT
export PDK          := sky130A
export VERILOG_FILES = $(RTL)
export FP_CORE_UTIL := 60

DEVICES     := 1 4
SDF_CORNERS := max_ss_100C_1v60 nom_tt_025C_1v80 min_ff_n40C_1v95

RTL       := spi_top.v spi_master.v
TB        := spi_top_tb.v spi_slave_model.v
BUILD     := build

SIM_T     := $(addprefix sim,$(DEVICES))
HARDEN_T  := $(addprefix harden,$(DEVICES))
GLS_T     := $(addprefix gls,$(DEVICES))
SDF_T     := $(addprefix sdf,$(DEVICES))

.PHONY: all sim synth clean $(SIM_T) $(HARDEN_T) $(GLS_T) $(SDF_T)

all: sim

sim: $(SIM_T)

synth:
	$(MAKE) $(HARDEN_T)
	$(MAKE) $(GLS_T) $(SDF_T)

$(SIM_T): sim%:
	@mkdir -p $(BUILD)
	verilator --binary --timing -Wno-fatal --default-language 1364-2005 -GNUM_DEVICES=$* \
	  --Mdir $(BUILD)/sim$* --top-module spi_top_tb $(TB) $(RTL)
	./$(BUILD)/sim$*/Vspi_top_tb > $(BUILD)/sim$*.log
	@grep -E "FAIL|ALL TESTS|TEST\(S\)" $(BUILD)/sim$*.log
	@! grep -q FAIL $(BUILD)/sim$*.log

$(HARDEN_T): harden%:
	rm -rf $(RUNS)/dev$*
	@mkdir -p $(RUNS)/dev$*
	export RUN_DIR=$(abspath $(RUNS))/dev$* NUM_DEVICES=$*; \
	yosys -c flow/synth.tcl > $(RUNS)/dev$*/synth.log && \
	openroad -exit flow/pnr.tcl > $(RUNS)/dev$*/pnr.log 2>&1 && \
	for c in $(SDF_CORNERS); do \
	  CORNER=$$c openroad -exit flow/sta.tcl > $(RUNS)/dev$*/sta_$$c.log 2>&1 || exit 1; \
	done && \
	(cd $(RUNS)/dev$* && magic -dnull -noconsole -rcfile $(SKY130A)/libs.tech/magic/sky130A.magicrc \
	  $(CURDIR)/flow/magic.tcl > magic.log 2>&1) && \
	(cd $(RUNS)/dev$* && magic -dnull -noconsole -rcfile $(SKY130A)/libs.tech/magic/sky130A.magicrc \
	  $(CURDIR)/flow/magic_check.tcl > magic_check.log 2>&1) && \
	(cd $(RUNS)/dev$* && netgen -batch source $(CURDIR)/flow/lvs.tcl > lvs.log 2>&1)
	@grep -h -A2 "^== " $(RUNS)/dev$*/sta_*.log
	@grep "DRC errors" $(RUNS)/dev$*/magic_check.log
	@grep "net violations" $(RUNS)/dev$*/pnr.log | tail -1
	@grep -E "Final result|match uniquely|Netlists do not match" $(RUNS)/dev$*/reports/lvs.rpt | tail -1

$(RUNS)/dev%/final/nl/spi_top.nl.v:
	$(MAKE) harden$*

$(BUILD)/spi_top_gl%.v: $(RUNS)/dev%/final/nl/spi_top.nl.v
	@mkdir -p $(BUILD)
	awk '{print} !done && /\);[[:space:]]*$$/ {print " parameter DATA_W = 8;"; \
	  print " parameter SCLK_HALF_DIV_W = 8;"; print " parameter NUM_DEVICES = $*;"; done=1}' \
	  $< > $@

$(GLS_T): gls%: $(BUILD)/spi_top_gl%.v
	iverilog -g2005 -DFUNCTIONAL -DUNIT_DELAY=#0.1 -Pspi_top_tb.NUM_DEVICES=$* -s spi_top_tb \
	  -o $(BUILD)/gls$* $(CELLS)/primitives.v $(CELLS)/sky130_fd_sc_hd.v $< $(TB)
	cd $(BUILD) && vvp -n gls$* > gls$*.log
	@grep -E "FAIL|ALL TESTS|TEST\(S\)" $(BUILD)/gls$*.log
	@! grep -q FAIL $(BUILD)/gls$*.log

$(SDF_T): sdf%: $(BUILD)/spi_top_gl%.v
	@for c in $(SDF_CORNERS); do \
	  printf 'module sdf_annotate;\n  initial begin\n    $$sdf_annotate("%s", spi_top_tb.dut);\n  end\nendmodule\n' \
	    $(abspath $(RUNS))/dev$*/final/sdf/$$c/spi_top__$$c.sdf > $(BUILD)/sdf_annotate$*_$$c.v; \
	  iverilog -g2005 -gspecify -ginterconnect -DUNIT_DELAY= -Pspi_top_tb.NUM_DEVICES=$* \
	    -s spi_top_tb -s sdf_annotate -o $(BUILD)/sdf$*_$$c $(CELLS)/primitives.v $(CELLS)/sky130_fd_sc_hd.v \
	    $< $(BUILD)/sdf_annotate$*_$$c.v $(TB) > $(BUILD)/sdf$*_$$c.compile.log 2>&1 || exit 1; \
	  (cd $(BUILD) && vvp -n sdf$*_$$c > sdf$*_$$c.log 2>&1); \
	  printf '%-18s ' $$c; grep -E "FAIL|ALL TESTS|TEST\(S\)" $(BUILD)/sdf$*_$$c.log; \
	done
	@! grep -q FAIL $(foreach c,$(SDF_CORNERS),$(BUILD)/sdf$*_$(c).log)

clean:
	rm -rf $(BUILD)
