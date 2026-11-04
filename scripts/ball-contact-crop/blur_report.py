"""How much fake blur the print gets, and how it pulses frame to frame against the real ball."""
import json, math, statistics as st, sys

def report(path):
    d = json.load(open(path))
    rows = [r for r in d['rows'] if r.get('source') and r.get('today') and r.get('nosmear')]
    print(f"\n{d['source']}: {len(rows)} frames with a ball")
    smear = sorted(r['smear'] for r in rows); radius = st.median(r['radius'] for r in rows)
    measured = [r for r in rows if 'measured' in r]
    moving = [r for r in rows if r['smear'] >= 2 * 1.5]
    print(f"  ball radius {radius:.0f} px at 1080p")
    print(f"  smear added today: median {st.median(smear):.1f} px, p90 {smear[int(.9*len(smear))]:.1f} px, max {smear[-1]:.1f} px")
    print(f"  real blur measurable in the footage: {len(measured)} of {len(moving)} frames that get smear" +
          (f"; median measured {st.median(r['measured'] for r in measured):.1f} px vs smear {st.median(r['smear'] for r in measured):.1f} px on those frames" if measured else ""))
    def pulse(key):
        out = []
        for a, b in zip(rows, rows[1:]):
            if abs(a['time'] - b['time']) < 0.03 and a[key] > 0 and b[key] > 0:
                out.append(abs(math.log(b[key] / a[key])))
        return st.mean(out), sorted(out)[int(.95 * len(out))]
    for key, name in (('source', 'real ball'), ('today', 'today'), ('nosmear', 'no fake blur')):
        mean, p95 = pulse(key)
        vals = [r[key] for r in rows]
        low = sum(v < st.median(vals) * 0.5 for v in vals) / len(vals)
        print(f"  {name:13} sharpness jump per frame: mean {mean*100:5.1f}%, p95 {p95*100:5.1f}%; frames under half the clip's usual sharpness: {low*100:4.1f}%")
    # Does the print's blur follow the real ball's? Rank correlation of log sharpness with smear length.
    def corr(xs, ys):
        mx, my = st.mean(xs), st.mean(ys)
        n = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
        d = math.sqrt(sum((x - mx) ** 2 for x in xs) * sum((y - my) ** 2 for y in ys))
        return n / d if d else 0
    s = [r['smear'] for r in rows]
    for key, name in (('source', 'real ball'), ('today', 'today'), ('nosmear', 'no fake blur')):
        print(f"  sharpness vs smear length, {name:13} correlation {corr(s, [math.log(r[key]) for r in rows]):+.2f}")
    fast = sorted(rows, key=lambda r: -r['smear'])[:max(10, len(rows)//20)]
    slow = sorted(rows, key=lambda r: r['smear'])[:max(10, len(rows)//20)]
    for key, name in (('source', 'real ball'), ('today', 'today'), ('nosmear', 'no fake blur')):
        print(f"  {name:13} sharpness in fastest 5% of frames vs slowest 5%: {st.median(r[key] for r in fast)/st.median(r[key] for r in slow):.2f}x")

for p in sys.argv[1:]:
    report(p)
