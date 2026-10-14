# Fault-Tolerant (TMR) FSM Controller
#   make test    run the automated fault-injection testbench (Icarus Verilog)
#   make synth   flattened Yosys synthesis of the production configuration,
#                asserting that all three replicas survive optimization
#   make wave    rebuild the testbench with VCD dumping
#   make clean

IVERILOG ?= iverilog
VVP      ?= vvp
YOSYS    ?= yosys

RTL   := rtl/tmr_voter.v rtl/ctrl_fsm_replica.v rtl/tmr_fsm_controller.v \
         rtl/lfsr_fault_injector.v rtl/ft_fsm_top.v
BUILD := build

.PHONY: all test synth wave clean

all: test synth

$(BUILD):
	mkdir -p $(BUILD)

test: | $(BUILD)
	$(IVERILOG) -g2005 -Wall -I rtl -o $(BUILD)/tb_ft_fsm.vvp $(RTL) tb/tb_ft_fsm.v
	$(VVP) -n $(BUILD)/tb_ft_fsm.vvp | tee $(BUILD)/tb_ft_fsm.log
	@grep -q "ALL TESTS PASSED" $(BUILD)/tb_ft_fsm.log

# 1) the full system (controller + injector) must synthesize cleanly
# 2) with injection tied off the replicas are identical; after a flattening
#    synthesis there must still be three replica instances (9 state flops)
synth: | $(BUILD)
	$(YOSYS) -q -l $(BUILD)/synth_top.log -p "\
	    read_verilog -Irtl $(RTL); \
	    synth -flatten -top ft_fsm_top; \
	    check -assert; \
	    tee -q -o $(BUILD)/synth_top_stat.txt stat"
	$(YOSYS) -q -l $(BUILD)/synth_prod.log -p "\
	    read_verilog -Irtl rtl/tmr_voter.v rtl/ctrl_fsm_replica.v rtl/tmr_fsm_controller.v syn/tmr_fsm_prod.v; \
	    synth -flatten -top tmr_fsm_prod; \
	    check -assert; \
	    select -assert-count 3 tmr_fsm_prod/t:ctrl_fsm_replica; \
	    select -assert-count 3 ctrl_fsm_replica/t:\$$_DFF*; \
	    tee -q -o $(BUILD)/synth_prod_stat.txt stat"
	@echo "synthesis OK: 3 replica instances x 3 state flops kept after flattening"
	@grep -E "^===|cells$$|DFF" $(BUILD)/synth_prod_stat.txt

wave: | $(BUILD)
	$(IVERILOG) -g2005 -I rtl -DDUMP -o $(BUILD)/tb_ft_fsm_wave.vvp $(RTL) tb/tb_ft_fsm.v
	cd $(BUILD) && $(VVP) -n tb_ft_fsm_wave.vvp

clean:
	rm -rf $(BUILD)
