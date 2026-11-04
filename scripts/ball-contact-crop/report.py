"""Summarize the outline scores. Paired: both masks judged on the same images."""
import json, statistics as st, sys

def stats(rows, method, kind, field):
    return [r[method][kind][field] for r in rows if method in r]

def summarize(path):
    d = json.load(open(path))
    rows = d['rows']; found = [r for r in rows if r.get('found')]
    print(f"\nedge {d['edge']}: {len(rows)} outlines, ball found in {len(found)}, consensus accepted in {sum('consensus' in r for r in found)}")
    def table(name, subset):
        if not subset: return
        print(f"  {name} (n={len(subset)})")
        for kind in ('raw', 'drawn'):
            for method in ('full', 'crop3.5', 'crop2.5', 'consensus'):
                have = [r for r in subset if method in r and 'full' in r]
                if not have: continue
                med = lambda f: st.median(stats(have, method, kind, f))
                print(f"    {kind:5} {method:9} n={len(have):3}  overlap {med('iou')*100:5.1f}%  spill {med('spill')*100:5.1f}%  real ball left {med('miss')*100:5.1f}%")
    table('all sizes', found)
    app = [r for r in found if min(r['width'], r['height']) >= 720]
    table('720p or larger, the size the app analyses', app)
    for low, high in ((0, 40), (40, 90), (90, 999)):
        table(f'720p+, ball {low}-{high} px', [r for r in app if low <= r['diameter'] < high])
    # The shipping rule: use the zoomed mask where two crops agree, otherwise today's mask.
    shipped = [(r, r.get('consensus', r['full'])) for r in app]
    both = [r['full']['drawn']['iou'] for r, _ in shipped], [s['drawn']['iou'] for _, s in shipped]
    better = sum(b > a + 0.005 for a, b in zip(*both)); worse = sum(b < a - 0.005 for a, b in zip(*both))
    print(f"  as it would ship, 720p+: overlap {st.median(both[0])*100:.1f}% to {st.median(both[1])*100:.1f}%; "
          f"mean {st.mean(both[0])*100:.1f}% to {st.mean(both[1])*100:.1f}%; better {better}, worse {worse}, same {len(shipped)-better-worse}")
    for f, label in (('miss', 'real ball left'), ('spill', 'spill')):
        a = [r['full']['drawn'][f] for r, _ in shipped]; b = [s['drawn'][f] for _, s in shipped]
        print(f"    {label}: median {st.median(a)*100:.1f}% to {st.median(b)*100:.1f}%, mean {st.mean(a)*100:.1f}% to {st.mean(b)*100:.1f}%")

for path in sys.argv[1:]:
    summarize(path)
