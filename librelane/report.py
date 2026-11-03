#!/usr/bin/env python3
"""Summarise a LibreLane run: timing per corner, area, power and sign-off checks.

    python3 librelane/report.py librelane/runs/<tag>
"""

import json
import sys
from pathlib import Path

CORNERS = ["nom_tt_025C_1v80", "nom_ss_100C_1v60", "max_ss_100C_1v60", "min_ff_n40C_1v95"]
CHECKS = [
    ("Routing DRC", "route__drc_errors"),
    ("Magic DRC", "magic__drc_error__count"),
    ("KLayout DRC", "klayout__drc_error__count"),
    ("LVS", "design__lvs_error__count"),
    ("Antenna", "route__antenna_violation__count"),
    ("Max slew", "design__max_slew_violation__count"),
    ("Max cap", "design__max_cap_violation__count"),
]


def main(run_dir):
    """Print the summary of one run.

    :param run_dir: LibreLane run directory (contains resolved.json and final/)
    """
    run = Path(run_dir)
    cfg = json.loads((run / "resolved.json").read_text())
    m = json.loads((run / "final" / "metrics.json").read_text())
    period = float(cfg["CLOCK_PERIOD"])

    print(f"{cfg['DESIGN_NAME']} — {run.name} — {cfg['PDK']} / {cfg['STD_CELL_LIBRARY']}, "
          f"clock {period:g} ns ({1000 / period:.1f} MHz)\n")

    print(f"{'Corner':<20} {'Setup WS':>10} {'Hold WS':>10} {'Fmax':>10}")
    for c in CORNERS:
        setup = m.get(f"timing__setup__ws__corner:{c}")
        hold = m.get(f"timing__hold__ws__corner:{c}")
        if setup is None:
            continue
        fmax = 1000 / (period - setup)
        print(f"{c:<20} {setup:>9.2f}  {hold:>9.2f}  {fmax:>6.1f} MHz")

    print(f"\nCells {m['design__instance__count__stdcell']}, "
          f"cell area {m['design__instance__area__stdcell']:.0f} µm², "
          f"die {m['design__die__area']:.0f} µm², "
          f"utilisation {100 * m['design__instance__utilization']:.1f} %, "
          f"power {1000 * m['power__total']:.2f} mW")

    print()
    failed = False
    for name, key in CHECKS:
        value = m.get(key)
        if value is None:
            continue
        failed |= value != 0
        print(f"{name:<12} {'OK' if value == 0 else value}")
    setup_ok = m["timing__setup__ws"] >= 0 and m["timing__hold__ws"] >= 0
    print(f"{'Timing':<12} {'OK' if setup_ok else 'VIOLATED'}")
    return 0 if setup_ok and not failed else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
