#!/usr/bin/env python3
"""Turn same-sized binary PPM frames into a 3-3-2 gifbuild animation spec."""

import argparse
import sys
from pathlib import Path


def tokens(stream):
    while True:
        byte = stream.read(1)
        while byte and byte.isspace():
            byte = stream.read(1)
        if not byte:
            return
        if byte == b"#":
            stream.readline()
            continue
        value = bytearray(byte)
        byte = stream.read(1)
        while byte and not byte.isspace():
            value.extend(byte)
            byte = stream.read(1)
        yield bytes(value)


def read_ppm(path):
    with path.open("rb") as stream:
        token_stream = tokens(stream)
        try:
            magic = next(token_stream)
            width = int(next(token_stream))
            height = int(next(token_stream))
            maximum = int(next(token_stream))
        except (StopIteration, ValueError) as exc:
            raise ValueError(f"invalid PPM header: {path}") from exc
        if magic != b"P6" or maximum != 255 or width < 1 or height < 1:
            raise ValueError(f"unsupported PPM format: {path}")
        pixels = stream.read()
        expected = width * height * 3
        if len(pixels) != expected:
            raise ValueError(
                f"PPM raster length mismatch in {path}: {len(pixels)} != {expected}"
            )
        return width, height, pixels


def palette():
    values = []
    for red in range(8):
        for green in range(8):
            for blue in range(4):
                values.append((round(red * 255 / 7), round(green * 255 / 7), round(blue * 255 / 3)))
    return values


def quantized_hex(pixels):
    table = "0123456789abcdef"
    output = bytearray(len(pixels) // 3 * 2)
    target = 0
    for source in range(0, len(pixels), 3):
        index = ((pixels[source] >> 5) << 5) | ((pixels[source + 1] >> 5) << 2) | (pixels[source + 2] >> 6)
        output[target] = ord(table[index >> 4])
        output[target + 1] = ord(table[index & 15])
        target += 2
    return output


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--delay", type=int, default=14, help="frame delay in centiseconds")
    parser.add_argument("--end-delay", type=int, default=70, help="first/last delay in centiseconds")
    parser.add_argument("frames", nargs="+", type=Path)
    return parser.parse_args()


def write_line(value=b""):
    if isinstance(value, str):
        value = value.encode("ascii")
    sys.stdout.buffer.write(value + b"\n")


def main():
    args = parse_args()
    if args.delay < 1 or args.end_delay < 1:
        raise SystemExit("delays must be positive centiseconds")
    frames = [read_ppm(path) for path in args.frames]
    width, height = frames[0][0], frames[0][1]
    if any(frame[0] != width or frame[1] != height for frame in frames):
        raise SystemExit("all frames must have identical dimensions")

    write_line(f"screen width {width}")
    write_line(f"screen height {height}")
    write_line("screen colors 256")
    write_line("screen background 255")
    write_line("screen map")
    for red, green, blue in palette():
        write_line(f"rgb {red} {green} {blue}")
    write_line("end")
    write_line("netscape loop 0")

    for number, (_, _, pixels) in enumerate(frames):
        delay = args.end_delay if number in {0, len(frames) - 1} else args.delay
        write_line("graphics control")
        write_line("disposal mode 1")
        write_line(f"delay {delay}")
        write_line("end")
        write_line("image")
        write_line("image top 0")
        write_line("image left 0")
        write_line(f"image bits {width} by {height} hex")
        raster = quantized_hex(pixels)
        for offset in range(0, len(raster), width * 2):
            write_line(raster[offset:offset + width * 2])


if __name__ == "__main__":
    main()
