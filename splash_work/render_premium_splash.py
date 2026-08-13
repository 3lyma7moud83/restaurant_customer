from pathlib import Path

import cv2
import imageio_ffmpeg
import numpy as np


SRC = Path(r"C:\Users\saudi\Downloads\Hailuo_Video_Create a premium 3-second vert_540178774308560901 (2).mp4")
WORK = Path(__file__).resolve().parent
OUT = WORK / "premium_mobile_splash_1080x1920_60fps.mp4"

W, H = 1080, 1920
FPS = 60
DURATION = 3.0
FRAMES = int(FPS * DURATION)


def clamp01(x):
    return np.clip(x, 0.0, 1.0)


def smoothstep(x):
    x = clamp01(x)
    return x * x * (3.0 - 2.0 * x)


def ease_out_quint(x):
    x = clamp01(x)
    return 1.0 - (1.0 - x) ** 5


def get_frame_at(seconds):
    cap = cv2.VideoCapture(str(SRC))
    if not cap.isOpened():
        raise RuntimeError(f"Could not open source video: {SRC}")
    cap.set(cv2.CAP_PROP_POS_MSEC, seconds * 1000.0)
    ok, frame = cap.read()
    cap.release()
    if not ok:
        raise RuntimeError(f"Could not decode frame at {seconds}s")
    return frame


def trim_rgba(rgba, pad=8):
    alpha = rgba[:, :, 3]
    ys, xs = np.where(alpha > 4)
    if len(xs) == 0 or len(ys) == 0:
        return rgba
    x1 = max(0, xs.min() - pad)
    x2 = min(rgba.shape[1], xs.max() + pad + 1)
    y1 = max(0, ys.min() - pad)
    y2 = min(rgba.shape[0], ys.max() + pad + 1)
    return rgba[y1:y2, x1:x2].copy()


def unsharp_bgra(rgba, amount=0.28, sigma=0.9):
    bgr = rgba[:, :, :3]
    blur = cv2.GaussianBlur(bgr, (0, 0), sigma)
    sharp = cv2.addWeighted(bgr, 1.0 + amount, blur, -amount, 0)
    out = rgba.copy()
    out[:, :, :3] = sharp
    return out


def extract_bag(frame):
    x1, y1, x2, y2 = 1080, 395, 1835, 1015
    roi = frame[y1:y2, x1:x2].copy()
    mask = np.zeros(roi.shape[:2], np.uint8)
    rect = (35, 35, roi.shape[1] - 70, roi.shape[0] - 60)
    bgd = np.zeros((1, 65), np.float64)
    fgd = np.zeros((1, 65), np.float64)
    cv2.grabCut(roi, mask, rect, bgd, fgd, 8, cv2.GC_INIT_WITH_RECT)

    hsv = cv2.cvtColor(roi, cv2.COLOR_BGR2HSV)
    orange = cv2.inRange(hsv, np.array([5, 80, 60]), np.array([35, 255, 255]))
    red1 = cv2.inRange(hsv, np.array([0, 60, 50]), np.array([8, 255, 255]))
    red2 = cv2.inRange(hsv, np.array([170, 60, 50]), np.array([180, 255, 255]))
    white = cv2.inRange(hsv, np.array([0, 0, 150]), np.array([180, 85, 255]))

    hull = np.zeros(mask.shape, np.uint8)
    pts = np.array(
        [
            [78, 142],
            [265, 100],
            [555, 112],
            [706, 140],
            [720, 514],
            [535, 552],
            [142, 542],
            [78, 478],
        ],
        np.int32,
    )
    cv2.fillPoly(hull, [pts], 255)

    # The handle is source-black on a dark background, so it needs explicit alpha.
    handle = np.zeros(mask.shape, np.uint8)
    cv2.ellipse(handle, (378, 76), (108, 42), 0, 180, 360, 255, 15, cv2.LINE_AA)
    cv2.ellipse(handle, (378, 78), (85, 26), 0, 180, 360, 0, 12, cv2.LINE_AA)

    seed_fg = ((orange | red1 | red2 | white | handle) > 0) & (hull > 0)
    mask[seed_fg] = cv2.GC_FGD
    loose = cv2.dilate(cv2.bitwise_or(hull, handle), np.ones((23, 23), np.uint8), iterations=1)
    mask[loose == 0] = cv2.GC_BGD
    cv2.grabCut(roi, mask, None, bgd, fgd, 6, cv2.GC_INIT_WITH_MASK)

    alpha = np.where((mask == cv2.GC_FGD) | (mask == cv2.GC_PR_FGD), 255, 0).astype(np.uint8)
    alpha = cv2.bitwise_and(alpha, loose)
    alpha = cv2.bitwise_or(alpha, handle)
    alpha = cv2.morphologyEx(alpha, cv2.MORPH_CLOSE, np.ones((7, 7), np.uint8), iterations=2)
    alpha = cv2.morphologyEx(alpha, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8), iterations=1)
    alpha = cv2.GaussianBlur(alpha, (5, 5), 0)

    denoised = cv2.bilateralFilter(roi, 5, 28, 28)
    rgba = cv2.cvtColor(denoised, cv2.COLOR_BGR2BGRA)
    rgba[:, :, 3] = alpha
    rgba = unsharp_bgra(rgba, amount=0.24, sigma=0.8)
    return trim_rgba(rgba, pad=10)


def extract_logo(frame):
    x1, y1, x2, y2 = 1065, 245, 1935, 390
    roi = frame[y1:y2, x1:x2].copy()
    b, g, r = cv2.split(roi)
    hsv = cv2.cvtColor(roi, cv2.COLOR_BGR2HSV)
    h, s, v = cv2.split(hsv)

    white = ((r > 155) & (g > 150) & (b > 145) & ((np.maximum.reduce([r, g, b]) - np.minimum.reduce([r, g, b])) < 75))
    orange = ((h >= 5) & (h <= 32) & (s > 95) & (v > 125) & (r > 145) & (g > 60) & (b < 95))
    hard = (white | orange).astype(np.uint8) * 255

    labels, comps, stats, _ = cv2.connectedComponentsWithStats(hard, 8)
    cleaned = np.zeros_like(hard)
    for label in range(1, labels):
        area = stats[label, cv2.CC_STAT_AREA]
        x = stats[label, cv2.CC_STAT_LEFT]
        y = stats[label, cv2.CC_STAT_TOP]
        w = stats[label, cv2.CC_STAT_WIDTH]
        hgt = stats[label, cv2.CC_STAT_HEIGHT]
        if area >= 5 and y > 8 and y + hgt < hard.shape[0] - 6 and w < hard.shape[1] - 20:
            cleaned[comps == label] = 255

    cleaned = cv2.morphologyEx(cleaned, cv2.MORPH_CLOSE, np.ones((2, 2), np.uint8), iterations=1)
    alpha = cv2.GaussianBlur(cleaned, (3, 3), 0)
    rgba = cv2.cvtColor(roi, cv2.COLOR_BGR2BGRA)
    rgba[:, :, 3] = alpha
    rgba = unsharp_bgra(rgba, amount=0.18, sigma=0.75)
    return trim_rgba(rgba, pad=8)


def add_radial(img, cx, cy, radius, color_bgr, opacity=1.0, power=2.0):
    yy, xx = np.ogrid[: img.shape[0], : img.shape[1]]
    dist = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)
    a = (1.0 - clamp01(dist / radius)) ** power * opacity
    color = np.array(color_bgr, np.float32)
    img[:] = np.clip(img.astype(np.float32) + a[..., None] * color, 0, 255).astype(np.uint8)


def add_blurred_line(img, p1, p2, color_bgr, thickness, opacity, blur):
    layer = np.zeros_like(img)
    cv2.line(layer, p1, p2, color_bgr, thickness, cv2.LINE_AA)
    if blur > 0:
        layer = cv2.GaussianBlur(layer, (0, 0), blur)
    img[:] = np.clip(img.astype(np.float32) + layer.astype(np.float32) * opacity, 0, 255).astype(np.uint8)


def make_background():
    y = np.linspace(0.0, 1.0, H, dtype=np.float32)[:, None]
    x = np.linspace(0.0, 1.0, W, dtype=np.float32)[None, :]
    base = np.zeros((H, W, 3), np.float32)
    base[:, :, 0] = 18 + 5 * (1 - y) + 2 * x
    base[:, :, 1] = 19 + 6 * (1 - y) + 2 * x
    base[:, :, 2] = 21 + 7 * (1 - y) + 3 * x

    rng = np.random.default_rng(42)
    noise = rng.normal(0, 1.4, (H, W, 1)).astype(np.float32)
    base += noise
    bg = np.clip(base, 0, 255).astype(np.uint8)

    shadow = np.zeros_like(bg)
    panels = [
        (np.array([[-210, 0], [10, 0], [-480, H], [-720, H]], np.int32), (10, 11, 13)),
        (np.array([[125, 0], [295, 0], [-210, H], [-410, H]], np.int32), (20, 21, 24)),
        (np.array([[390, 0], [555, 0], [70, H], [-120, H]], np.int32), (26, 27, 31)),
        (np.array([[780, 0], [970, 0], [510, H], [315, H]], np.int32), (22, 23, 27)),
        (np.array([[1030, 0], [1265, 0], [800, H], [565, H]], np.int32), (13, 14, 17)),
    ]
    for pts, color in panels:
        cv2.fillPoly(bg, [pts], color, cv2.LINE_AA)
        cv2.polylines(shadow, [pts], True, (18, 18, 20), 22, cv2.LINE_AA)
    shadow = cv2.GaussianBlur(shadow, (0, 0), 15)
    bg = cv2.addWeighted(bg, 1.0, shadow, 0.48, 0)

    for p1, p2, thick in [
        ((-60, 420), (205, 0), 5),
        ((145, 640), (520, 0), 7),
        ((860, 1010), (1130, 530), 5),
        ((710, 1460), (1090, 810), 4),
        ((990, 490), (1145, 260), 4),
    ]:
        add_blurred_line(bg, p1, p2, (19, 109, 242), thick + 10, 0.28, 18)
        cv2.line(bg, p1, p2, (45, 156, 255), thick, cv2.LINE_AA)

    floor_y = 1270
    floor = bg[floor_y:].astype(np.float32)
    fy = np.linspace(0.0, 1.0, H - floor_y, dtype=np.float32)[:, None]
    floor *= (0.82 - 0.16 * fy)[:, :, None]
    floor += np.array([4, 5, 6], np.float32)
    bg[floor_y:] = np.clip(floor, 0, 255).astype(np.uint8)
    add_blurred_line(bg, (0, floor_y), (W, floor_y - 8), (64, 62, 60), 2, 0.35, 7)

    add_radial(bg, 535, 1070, 600, (12, 58, 105), 0.85, 2.4)
    add_radial(bg, 100, 1220, 450, (14, 54, 108), 0.55, 2.0)
    add_radial(bg, 960, 720, 520, (15, 45, 90), 0.45, 2.3)
    add_radial(bg, 540, 650, 760, (22, 22, 24), 0.26, 2.0)

    # Soft atmosphere: a low-contrast veil instead of visible particles.
    fog = np.zeros_like(bg)
    add_radial(fog, 540, 830, 760, (28, 25, 23), 0.30, 2.6)
    fog = cv2.GaussianBlur(fog, (0, 0), 28)
    bg = cv2.addWeighted(bg, 1.0, fog, 0.55, 0)
    return bg


def overlay_rgba(dst, src, x, y, opacity=1.0):
    x, y = int(round(x)), int(round(y))
    h, w = src.shape[:2]
    x1 = max(0, x)
    y1 = max(0, y)
    x2 = min(dst.shape[1], x + w)
    y2 = min(dst.shape[0], y + h)
    if x1 >= x2 or y1 >= y2:
        return
    sx1 = x1 - x
    sy1 = y1 - y
    sx2 = sx1 + (x2 - x1)
    sy2 = sy1 + (y2 - y1)
    patch = src[sy1:sy2, sx1:sx2]
    alpha = (patch[:, :, 3].astype(np.float32) / 255.0 * opacity)[:, :, None]
    dst[y1:y2, x1:x2] = np.clip(
        patch[:, :, :3].astype(np.float32) * alpha + dst[y1:y2, x1:x2].astype(np.float32) * (1.0 - alpha),
        0,
        255,
    ).astype(np.uint8)


def resize_rgba(img, width=None, height=None, scale=None):
    if scale is not None:
        width = max(1, int(round(img.shape[1] * scale)))
        height = max(1, int(round(img.shape[0] * scale)))
    elif width is not None:
        height = max(1, int(round(img.shape[0] * width / img.shape[1])))
    elif height is not None:
        width = max(1, int(round(img.shape[1] * height / img.shape[0])))
    return cv2.resize(img, (width, height), interpolation=cv2.INTER_LANCZOS4)


def make_shadow(width, height, opacity):
    layer = np.zeros((height, width, 4), np.uint8)
    center = (width // 2, height // 2)
    alpha = np.zeros((height, width), np.uint8)
    cv2.ellipse(alpha, center, (max(1, width // 2 - 8), max(1, height // 3)), 0, 0, 360, int(255 * opacity), -1, cv2.LINE_AA)
    layer[:, :, 3] = cv2.GaussianBlur(alpha, (0, 0), 24)
    return layer


def make_glow_from_alpha(asset, color_bgr, blur=16, opacity=0.25):
    glow = np.zeros_like(asset)
    alpha = cv2.GaussianBlur(asset[:, :, 3], (0, 0), blur)
    glow[:, :, :3] = color_bgr
    glow[:, :, 3] = np.clip(alpha.astype(np.float32) * opacity, 0, 255).astype(np.uint8)
    return glow


def apply_light_sweep(asset, amount):
    if amount <= 0:
        return asset
    out = asset.copy()
    h, w = asset.shape[:2]
    x = np.arange(w, dtype=np.float32)[None, :]
    center = -w * 0.35 + amount * w * 1.7
    band = np.exp(-((x - center) ** 2) / (2 * (w * 0.055) ** 2))
    band = np.repeat(band, h, axis=0)
    alpha = asset[:, :, 3].astype(np.float32) / 255.0
    add = (band * alpha * 44.0).astype(np.float32)
    out[:, :, :3] = np.clip(out[:, :, :3].astype(np.float32) + add[:, :, None], 0, 255).astype(np.uint8)
    return out


def apply_camera(frame, scale):
    if scale <= 1.0001:
        return frame
    sw = int(round(W * scale))
    sh = int(round(H * scale))
    zoom = cv2.resize(frame, (sw, sh), interpolation=cv2.INTER_LANCZOS4)
    x = (sw - W) // 2
    y = (sh - H) // 2
    return zoom[y : y + H, x : x + W]


def add_bloom(frame):
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    mask = cv2.threshold(gray, 150, 255, cv2.THRESH_BINARY)[1]
    bright = cv2.bitwise_and(frame, frame, mask=mask)
    bloom = cv2.GaussianBlur(bright, (0, 0), 12)
    return cv2.addWeighted(frame, 1.0, bloom, 0.14, 0)


def render():
    source_frame = get_frame_at(2.5)
    bag = extract_bag(source_frame)
    logo = extract_logo(source_frame)
    cv2.imwrite(str(WORK / "bag_cutout_refined.png"), bag)
    cv2.imwrite(str(WORK / "logo_cutout_refined.png"), logo)

    base_bg = make_background()
    black = np.zeros_like(base_bg)

    bag_target_w = 620
    logo_target_w = 650
    floor_y = 1268

    writer = imageio_ffmpeg.write_frames(
        str(OUT),
        (W, H),
        fps=FPS,
        codec="libx264",
        quality=None,
        macro_block_size=1,
        output_params=["-pix_fmt", "yuv420p", "-crf", "15", "-preset", "slow", "-movflags", "+faststart"],
    )
    writer.send(None)

    preview_times = {0.0, 0.5, 1.6, 2.5, 2.9833333333333334}
    for i in range(FRAMES):
        t = i / FPS
        bg_in = smoothstep(t / 0.5)
        frame = (black.astype(np.float32) * (1.0 - bg_in) + base_bg.astype(np.float32) * bg_in).astype(np.uint8)

        bag_p = smoothstep((t - 0.5) / 1.1)
        logo_p = smoothstep((t - 1.6) / 0.9)
        cam = 1.0 + 0.035 * ease_out_quint((t - 2.5) / 0.5)

        if bag_p > 0:
            settle = 1.0 - ease_out_quint((t - 0.5) / 1.1)
            micro = np.sin(clamp01((t - 0.5) / 1.1) * np.pi) * 7.0
            bag_w = int(round(bag_target_w * (0.965 + 0.035 * bag_p)))
            bag_scaled = resize_rgba(bag, width=int(round(bag_w * cam)))
            bag_h, bag_w = bag_scaled.shape[:2]
            bottom_y = floor_y - 8 + 90 * settle - micro
            x = W / 2 - bag_w / 2
            y = bottom_y - bag_h

            shadow_w = int(round((bag_w * 0.92) * (0.85 + 0.15 * bag_p)))
            shadow_h = int(round(120 * cam))
            shadow = make_shadow(shadow_w, shadow_h, 0.34 * bag_p)
            overlay_rgba(frame, shadow, W / 2 - shadow_w / 2, floor_y - 52 * cam, 1.0)

            reflect = cv2.flip(bag_scaled, 0)
            reflect_h = min(int(bag_h * 0.48), H - int(floor_y))
            reflect = reflect[:reflect_h].copy()
            grad = np.linspace(0.28, 0.0, reflect_h, dtype=np.float32)[:, None]
            reflect[:, :, 3] = np.clip(reflect[:, :, 3].astype(np.float32) * grad, 0, 255).astype(np.uint8)
            reflect[:, :, :3] = cv2.GaussianBlur(reflect[:, :, :3], (0, 0), 2.4)
            overlay_rgba(frame, reflect, x, floor_y + 4 * cam, 0.55 * bag_p)

            glow = make_glow_from_alpha(bag_scaled, (11, 66, 125), blur=18, opacity=0.10 * bag_p)
            overlay_rgba(frame, glow, x, y, 1.0)
            overlay_rgba(frame, bag_scaled, x, y, bag_p)

        if logo_p > 0:
            logo_scaled = resize_rgba(logo, width=int(round(logo_target_w * cam)))
            sweep = smoothstep((t - 2.0) / 0.55)
            logo_scaled = apply_light_sweep(logo_scaled, sweep)
            lh, lw = logo_scaled.shape[:2]
            lx = W / 2 - lw / 2
            ly = 520 * cam - (cam - 1.0) * 190
            glow = make_glow_from_alpha(logo_scaled, (28, 123, 255), blur=12, opacity=0.30 * logo_p)
            overlay_rgba(frame, glow, lx, ly, 1.0)
            overlay_rgba(frame, logo_scaled, lx, ly, logo_p)

        frame = add_bloom(frame)
        frame = apply_camera(frame, cam)
        frame = cv2.convertScaleAbs(frame, alpha=1.04, beta=-2)

        if any(abs(t - pt) < 0.5 / FPS for pt in preview_times):
            cv2.imwrite(str(WORK / f"preview_{t:0.2f}.png"), frame)

        writer.send(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB).tobytes())

    writer.close()
    print(OUT)


if __name__ == "__main__":
    render()
