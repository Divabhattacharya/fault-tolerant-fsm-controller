# Fault-Tolerant FSM Controller (TMR)

Verilog RTL for a bus-transaction control FSM protected by Triple Modular
Redundancy. It also includes an on-chip LFSR fault injector and error counters,
plus an automated fault-injection testbench.

## The protected FSM

```
IDLE --start--> REQUEST --grant--> ADDRESS --> DATA --ack--> COMPLETE --> IDLE
                   |                              |
                   +------------abort-------------+--> ERROR --> IDLE
```

Moore outputs: `req` (REQUEST), `addr_en` (ADDRESS), `data_en` (DATA),
`done` (COMPLETE), `err` (ERROR). The state is 3-bit binary. The unused codes
`110`/`111` fall back to IDLE.

## Architecture

```
                 +--------------------- voted state (feedback) ------------------+
                 v                                                               |
inputs --> [replica 0: next-state -> state reg ^ seu0 -> output decode] --+      |
inputs --> [replica 1: next-state -> state reg ^ seu1 -> output decode] --+--> [state voter] --+
inputs --> [replica 2: next-state -> state reg ^ seu2 -> output decode] --+--> [output voter] --> req, addr_en, data_en, done, err
                                                                          |
                                                                          +--> mismatch --> error counters

[16-bit LFSR] --> fire? / which replica / which bit --> seu mask
```

- **Voter feedback (scrubbing).** Each replica computes its next state from the
  voted state, not from its own register. An upset replica is rewritten with the
  correct state on the next clock edge, so it recovers in one cycle without a reset.
- **Voted outputs.** Each replica decodes its own outputs, and the outputs are
  majority-voted as well, so the output decoder is triplicated too.
- **Error counters** (16-bit, saturating): `corrected_count` counts cycles in
  which a disagreement was detected and masked. `replica_err_count0/1/2` count,
  per replica, the cycles in which that replica was outvoted.
- **LFSR fault injector.** A 16-bit maximal-length Fibonacci LFSR
  (x^16 + x^14 + x^13 + x^11 + 1) runs on chip. A fault fires with probability
  2^-rate (`rate = 0` fires every cycle). Other LFSR bit fields pick the replica
  and the state bit, and each fault flips exactly one bit of one replica's state
  register. `inject_count` counts the faults fired.
- **Synthesis safety.** With injection tied off, the three replicas are
  logically identical, and a flattening synthesis run merges them into one
  register, silently removing the redundancy. We observed this in Yosys: without
  the fix, a flattened build kept only 3 state flip-flops. The replicas are
  therefore marked `keep_hierarchy` and `dont_touch`, and `make synth` asserts
  that all three are still present after flattening.

| File | Contents |
|---|---|
| `rtl/ctrl_fsm_defs.vh` | state encoding |
| `rtl/ctrl_fsm_replica.v` | one FSM copy: next-state from voted state, upset port, own output decoder |
| `rtl/tmr_voter.v` | bitwise 2-of-3 majority voter with per-input disagreement flags |
| `rtl/tmr_fsm_controller.v` | 3 replicas + state and output voters + error counters |
| `rtl/lfsr_fault_injector.v` | LFSR-driven single-bit upset generator + injection counter |
| `rtl/ft_fsm_top.v` | system top: controller + injector + directed-upset test port |
| `syn/tmr_fsm_prod.v` | production configuration (injection tied off), used by `make synth` |
| `tb/tb_ft_fsm.v` | automated fault-injection testbench |

## Verification

Requirements: Icarus Verilog and Yosys (tested with Icarus Verilog 13.0 and Yosys 0.70).

```
make test     # fault-injection testbench (Icarus Verilog)
make synth    # Yosys: synthesize the full top, then the production config
              # flattened, asserting 3 replicas x 3 state flops survive
make wave     # VCD dump for GTKWave
```

A behavioral golden model of the unprotected FSM runs in lockstep with the DUT.
On every cycle the checker verifies that:

- the voted state and voted outputs equal the golden model
- each replica's state equals *golden state XOR the upset applied at the last
  clock edge*. This proves the upset landed, the other two replicas were
  untouched, and the hit replica was back in step one cycle later.
- `fault_detected` is high exactly when an upset was applied

Test suites:

1. reset values
2. a fault-free run, covering all 11 legal state transitions
3. directed single-bit upsets: every replica × bit × cycle of a scenario that
   visits all six states (144 runs, 54/54 state × replica × bit bins)
4. multi-bit upsets confined to one replica (240 runs)
5. LFSR random campaigns at fault rates 1, 1/2, 1/4, 1/16 and 1/64 per cycle.
   For each campaign, the injector count, the corrected count, the per-replica
   counters and the testbench's own tally must all agree.
6. 100 asynchronous resets while faults are injected every cycle
7. LFSR period equals 65,535 (maximal length)
8. known TMR limits: a same-bit upset in two replicas must escape and must be
   caught by the golden comparison (this proves the checker can see failures),
   and a common-mode upset into an illegal code must return to IDLE in one cycle

Results:

```
[3] directed single-bit upsets: 144 runs, (state x replica x bit) coverage 54/54
[5] rate 2^-0:  30000 cycles,  30000 upsets injected,  30000 detected+corrected
    rate 2^-1:  30000 cycles,  15082 upsets injected,  15082 detected+corrected
    rate 2^-2:  30000 cycles,   7618 upsets injected,   7618 detected+corrected
    rate 2^-4:  30000 cycles,   1970 upsets injected,   1970 detected+corrected
    rate 2^-6:  30000 cycles,    524 upsets injected,    524 detected+corrected
[7] LFSR period = 65535 (maximal = 65535)
cycles checked against golden model : 178845
upsets applied under checker        : 57480 (33220 while not IDLE)
hit replica's own outputs wrong      : 57456 (all masked by the voter)
errors                               : 0
```

Replica selection uses `lfsr[11:8] % 3`, so replica 0 is hit slightly more
often (about 37% vs 31%).

**Testbench sensitivity.** Each of the following bugs was injected on its own,
and every one made the testbench fail: an OR instead of a majority vote, no
voter feedback (next state taken from the replica's own register), outputs taken
from replica 0 only, a wrong `corrected_count`, a missing LFSR tap
(non-maximal period), no illegal-state recovery, and an injector that hits two
replicas at once.

## Scope

TMR here masks any upset confined to one replica at a time, including multi-bit
ones. It cannot mask the same bit being upset in two replicas in the same cycle,
or a common-mode upset of all three. The voters, inputs, clock and reset are not
triplicated.
