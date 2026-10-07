"""Motion-compensated stability proxy, not ground-truth segmentation accuracy.

Requires numpy/opencv. OLD_CACHE NEW_CACHE OUTPUT.json. Maps both masks into
the same 540-pixel-wide source coordinates and uses source-image optical flow.
"""
import json
import sys
from pathlib import Path
import cv2
import numpy as np

old, new, destination = map(Path, sys.argv[1:])
folders = [old, new]
recordings = [json.loads((p / "scene.json").read_text()) for p in folders]
captures = [cv2.VideoCapture(str(p / "foreground.mp4")) for p in folders]
source = cv2.VideoCapture(str(new / "original.mp4"))
w = 540
h = round(source.get(cv2.CAP_PROP_FRAME_HEIGHT) / source.get(cv2.CAP_PROP_FRAME_WIDTH) * w)
gridx, gridy = np.meshgrid(np.arange(w, dtype=np.float32), np.arange(h, dtype=np.float32))
flow_engine = cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_MEDIUM)
diagnostics = json.loads((new / "cutout-frames.json").read_text())
previous = None
rows = []
while True:
    ok, original = source.read()
    if not ok:
        break
    original = cv2.resize(original, (w, h))
    gray = cv2.cvtColor(original, cv2.COLOR_BGR2GRAY)
    masks = []
    for recording, capture in zip(recordings, captures):
        ok, packed = capture.read()
        if not ok:
            raise RuntimeError("Cache ended before the source")
        alpha = packed[:, packed.shape[1] // 2 :, 0].astype(np.float32) / 255
        (x, y), (rw, rh) = recording["sourceRect"]
        transform = np.float32([[rw*w/alpha.shape[1], 0, x*w], [0, rh*h/alpha.shape[0], y*h]])
        masks.append(cv2.warpAffine(alpha, transform, (w, h), flags=cv2.INTER_LINEAR))
    row = {"frame": len(rows), "time": diagnostics[len(rows)]["time"]}
    person = np.ones((h, w), dtype=bool)
    for entry in diagnostics[max(0,len(rows)-1):len(rows)+1]:
        if "ballBounds" in entry:
            (x, y), (bw, bh) = entry["ballBounds"]
            x0, x1 = max(0,int((x-bw*.3)*w)), min(w,int((x+bw*1.3)*w)+1)
            y0, y1 = max(0,int((y-bh*.3)*h)), min(h,int((y+bh*1.3)*h)+1)
            person[y0:y1, x0:x1] = False
    row["newOnlyOpaquePixels"] = int(np.count_nonzero((masks[1]>.8) & (masks[0]<.1) & person))
    if previous is not None:
        oldgray, oldrgb, oldmasks = previous
        motion = flow_engine.calc(gray, oldgray, None)
        mx, my = gridx+motion[:,:,0], gridy+motion[:,:,1]
        oldphoto = cv2.remap(oldrgb, mx, my, cv2.INTER_LINEAR).astype(np.float32)/255
        photo_match = np.max(np.abs(original.astype(np.float32)/255-oldphoto),axis=2)<.08
        warped = [cv2.remap(m, mx, my, cv2.INTER_LINEAR) for m in oldmasks]
        union = np.maximum.reduce(masks+warped)>.02
        eligible = cv2.dilate(union.astype(np.uint8),np.ones((5,5),np.uint8)).astype(bool) & photo_match & person
        row["eligiblePixels"] = int(eligible.sum())
        for name, mask, prior in zip(["old", "new"], masks, warped):
            delta = np.abs(mask-prior)
            row[name+"MeanAlphaChange"] = float(delta[eligible].mean()) if eligible.any() else 0
            row[name+"LargeChanges"] = int(np.count_nonzero((delta>.5) & eligible))
    previous = gray, original, masks
    rows.append(row)
for capture in captures:
    if capture.read()[0]:
        raise RuntimeError("Cache continues past the source")
summary = {"frames":len(rows),"coordinateSize":[w,h],"note":"Optical-flow/photometric stability proxy; not accuracy. Different masks can score differently even without flicker.","rows":rows}
for name in ["old","new"]:
    summary[name] = {"meanAlphaChange":float(np.mean([r[name+"MeanAlphaChange"] for r in rows[1:]])),
                     "largeChanges":sum(r[name+"LargeChanges"] for r in rows[1:])}
destination.write_text(json.dumps(summary,indent=2))
print(json.dumps({k:v for k,v in summary.items() if k!="rows"},indent=2))
print("Largest new-only regions:",[(r["frame"],r["newOnlyOpaquePixels"]) for r in sorted(rows,key=lambda r:r["newOnlyOpaquePixels"],reverse=True)[:10]])
