#!/usr/bin/env python3
"""Read-only process CPU/RSS observation; run while the app stays in a chosen UI state."""
import argparse
import json
import pathlib
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--seconds', type=float, default=30)
parser.add_argument('--label', default='foreground-active-monitor')
args = parser.parse_args()
pids = subprocess.check_output(['pgrep', '-x', 'MacXTerm'], text=True).split()
if len(pids) != 1:
    raise SystemExit('Expected exactly one running MacXTerm process')
pid = pids[0]
def sample():
    fields = subprocess.check_output(['ps', '-p', pid, '-o', 'time=', '-o', 'rss='], text=True).split()
    total = 0
    for part in fields[0].split(':'):
        total = total * 60 + float(part)
    return total, int(fields[1]) / 1024

first, _ = sample()
start = time.monotonic()
time.sleep(max(1, args.seconds))
last, rss = sample()
elapsed = time.monotonic() - start
result = {'seconds': round(elapsed, 3), 'cpu_seconds': round(last-first, 3),
          'cpu_percent_one_core': round((last-first)/elapsed*100, 3),
          'rss_mib_at_end': round(rss, 2), 'label': args.label,
          'scope': 'Entire MacXTerm process; a single observation, not monitoring-only cost.'}
out = pathlib.Path('.build') / ('performance-' + args.label + '.json')
out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(result, ensure_ascii=False))
