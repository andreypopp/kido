import json
import math


def filters(timeline, duration, output, camera, cuts, mobile=False):
    events = {item["event"]: item["seconds"] for item in timeline}
    intervals = []
    for first, offset, last, end_offset, budget in cuts:
        start, end = events[first] + offset, events[last] + end_offset
        if end > start:
            intervals.append((start, end, min(1, budget / (end - start))))
    intervals.sort()
    assert all(a[1] <= b[0] for a, b in zip(intervals, intervals[1:]))

    def mapped(t):
        return t - sum(max(0, min(t, end) - start) * (1 - factor)
                       for start, end, factor in intervals)

    frames = [(0, (1, 0, 0))] + [(mapped(events[event] + offset), target)
                                for event, offset, target in camera]
    frames.sort()
    keyframes = [{"time": round(t, 3), "zoom": v[0], "top_left": list(v[1:])} for t, v in frames]
    (output / ("camera-mobile.json" if mobile else "camera.json")).write_text(json.dumps(keyframes, indent=2) + "\n")

    def expression(index):
        value = str(frames[0][1][index])
        previous_at, previous_from, previous_target = 0, frames[0][1][index], frames[0][1][index]
        for t, target in frames[1:]:
            progress = (1 - math.cos(math.pi * min(1, max(0, (t - previous_at) / .8)))) / 2
            base = previous_from + (previous_target - previous_from) * progress
            ease = f"(1-cos(PI*min(1,max(0,(t-{t:.5f})/0.8))))/2"
            current = f"({base}+({target[index]}-{base})*{ease})"
            value = f"if(lt(t,{t:.5f}),{value},{current})"
            previous_at, previous_from, previous_target = t, base, target[index]
        return value

    zoom, cx, cy = (expression(i) for i in range(3))
    removed = sum((end - start) * (1 - factor) for start, end, factor in intervals)
    duration = max(duration, 20 + removed)
    pts = "T" + "".join(f"-max(0,min(T,{end})-{start})*{1-factor}"
                         for start, end, factor in intervals)
    width, height, canvas = (1080, 1350, 2250) if mobile else (1600, 960, 1600)
    canvas_height = canvas * 3 / 5
    return (f"fps=60,trim=duration={duration},setpts='({pts})/TB',fps=30,"
            f"scale=w='trunc({canvas}*({zoom})/2)*2':h=-2:eval=frame:flags=lanczos,"
            f"crop={width}:{height}:x='min({canvas}*({zoom})-{width},max(0,({cx})*{canvas}*({zoom})))':"
            f"y='min({canvas_height}*({zoom})-{height},max(0,({cy})*{canvas_height}*({zoom})))',setsar=1")
