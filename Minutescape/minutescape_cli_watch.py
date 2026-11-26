"""Record a local test trace against an unaccelerated host stopwatch."""
import argparse
import json
from pathlib import Path
import time


def watch(trace, output, wait):
    seen = 0
    last_status = 0
    deadline = time.monotonic() + wait
    with output.open('a', encoding='utf-8') as out:
        while time.monotonic() < deadline:
            lines = trace.read_text(encoding='utf-8').splitlines() if trace.exists() else []
            now = time.perf_counter()
            for line in lines[seen:]:
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    break
                seen += 1
                record = {'host': now, **row}
                out.write(json.dumps(record) + '\n')
                event = row['event']
                if event != 'sample' or now - last_status >= 5:
                    print(json.dumps(record), flush=True)
                    if event == 'sample':
                        last_status = now
                if event in ('complete', 'error'):
                    return
            out.flush()
            time.sleep(0.1)
    print(f'Observation window ended after {seen} records.', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trace', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--wait', type=float, default=50)
    args = parser.parse_args()
    watch(args.trace, args.output, args.wait)
