# FastLanez

A Zig implementation of the paper [Decoding >100 Billion Integers per Second with Scalar Code](https://www.vldb.org/pvldb/vol16/p2132-afroozeh.pdf).

Huge thanks to [**Azim Afroozeh**](https://www.cwi.nl/en/people/azim-afroozeh/) and [**Peter Boncz**](https://www.cwi.nl/en/people/peter-boncz/) for sharing this incredible work.

Supported Codecs:
* **Bit-Packing** - packing T bit integers into 0 <= W < T bit integers.
* **Delta** - taking the difference between adjacent values.
* **Fused Frame-of-Reference** - a fused kernel that subtracts a reference value before applying bit-packing.

Requires Zig trunk >= 0.12.0-dev.2541

Benchmarks can be run with `zig build bench -Doptimize=ReleaseSafe`

## What is FastLanes?

FastLanes describes a practical approach to developing SIMD-based lightweight compression codecs. With a clever
transposed layout of data it enables efficient compression and decompression among CPUs with varying width SIMD
registers, even for codecs with data dependencies such as Delta and RLE.

FastLanes operates over vectors of 1024 elements, 1024-bits at a time. It is up to the caller to decide how to
handle padding. A typical FastLanes codec might look something like this:

* Take an `FL.Vector` of 1024 elements of width `T`.
* Transpose the vector with `FL.transpose`.
* Apply a light-weight codec, such as `Delta`.
* Bit-pack into integers of width `W`.
* Return the `W * MM1024` words.

Strictly speaking, the transpose is only required for codecs with data dependencies, i.e. where the output value
of the next element depends on the previous element. However, if all FastLanes compressed vectors are ordered the
same way, it's possible to more efficiently perform comparisons between these vectors without un-transposing the data.

### Unified Transposed Layout

The transposed layout works like this:
* Take a 1024 element vector.
* Split into 8 blocks of 128 elements.
* Transpose the 128 elements from 8x16 to 16x8.
* Reorder the blocks according to `0, 4, 2, 6, 1, 5, 3, 7`

> Figure 6d in the paper is very helpful for visualizing this!

With this order it is possible to make adjacent cells appear in adjacent SIMD words, regardless of how wide the CPU's SIMD
register is. For example, a vector of u32s will be rearranged and then iterated such that adjacent words look like this:

```
2xu32 64-bit SIMD
{ 0, 64 }
{ 1, 65 }
{ 2, 66 }
...

4xu32 128-bit SIMD
{ 0, 64, 128, 192 }
{ 1, 65, 129, 193 }
{ 2, 66, 130, 194 }
...

16xu32 512-bit SIMD
{ 0, 64, 128, 192, 256, 320, 384, 448, 512, 576, 640, 704, 768, 832, 896, 960 }
{ 1, 65, 129, 193, 257, 321, 385, 449, 513, 577, 641, 705, 769, 833, 897, 961 }
{ 2, 66, 130, 194, 258, 322, 386, 450, 514, 578, 642, 706, 770, 834, 898, 962 }
...
```

Note that for a codec like Delta, instead of taking the delta from a single starting element, we must start with a 1024-bits
worth of base values. So 32 * u32s.

## Design of FastLanez

FastLanez leverages Zig's SIMD abstraction to create a virtual 1024-bit word: `@Vector(1024 / @bitSizeOf(T), T)`.

This allows us to implement codecs that are astonishingly close to the psuedo-code presented by the paper. Here is
Listing 2 (unpacking 3-bit integers into 8-bit integers) ported to FastLanez with line-breaks adjusted to match the original:

```zig
comptime var mask: [W + 1]E = undefined;
inline for (0..W + 1) |i| {
    mask[i] = (1 << i) - 1;
}

var r0: FL.MM1024 = undefined;
var r1: FL.MM1024 = undefined;

r0 = FL.load(in, 0);
r1 = FL.and_rshift(r0, 0, mask[3]); FL.store(out, 0, r1);
r1 = FL.and_rshift(r0, 3, mask[3]); FL.store(out, 1, r1);
r1 = FL.and_rshift(r0, 6, mask[2]);
r0 = FL.load(in, 1); FL.store(out, 2, FL.or_(r1, FL.and_lshift(r0, 2, mask[1])));
r1 = FL.and_rshift(r0, 1, mask[3]); FL.store(out, 3, r1);
r1 = FL.and_rshift(r0, 4, mask[3]); FL.store(out, 4, r1);
r1 = FL.and_rshift(r0, 7, mask[1]);
r0 = FL.load(in, 2); FL.store(out, 5, FL.or_(r1, FL.and_lshift(r0, 1, mask[2])));
r1 = FL.and_rshift(r0, 2, mask[3]); FL.store(out, 6, r1);
r1 = FL.and_rshift(r0, 5, mask[3]); FL.store(out, 7, r1);
```

Zig's comptime feature allows us to wrap up this logic and generate **all** kernels at compile-time
without any runtime performance overhead:

```zig
const FL = FastLanez(u8);

pub fn unpack(comptime W: comptime_int, in: *const FL.PackedBytes(W), out: *FL.Vector) void {
    comptime var unpacker = FL.bitunpacker(W);
    var tmp: FL.MM1024 = undefined;
    inline for (0..FL.T) |i| {
        const next, tmp = unpacker.unpack(in, tmp);
        FL.store(out, i, next);
    }
}
```

### Loop Ordering

There is a key difference to the implementation of this library vs FastLanes: loop ordering.

* FastLanes: SIMD word, tile, row.
* FastLanez: tile, row, SIMD word. Where the SIMD word loop is internal to the Zig `@Vector`.

We can see the difference more clearly with some psuedo-code:

```zig
const a, const b = FL.load(input, 0), FL.load(input, 1);
FL.store(output, 0, FL.add(a, b));
```

Unoptimized FastLanes assembly would look something like this:
```asm
LDR
ADD
STR
LDR
ADD
STR
...
```

Whereas unoptimized FastLanez assembly would look like this:
```asm
LDR
LDR
...
ADD
ADD
...
STR
STR
...
```

Given there is a limited number of SIMD registers in a CPU, one would expect the FastLanes code to perform better.
In fact, our benchmarking suggests that option 2 has a slight edge. Although I don't suspect this will hold true
for more complex compression kernels and may become an issue in the future requiring us to invert the loop ordering
of this library.

Another possible advantage to the FastLanes loop ordering is that we can avoid unrolling the outer SIMD word loop,
resulting in potentially much smaller code size for minimal impact on performance.


## C Library

TODO: this library will be made available as a C library.

## Python Library

TODO: this library will be made available as a Python library using [Ziggy Pydust](https://github.com/fulcrum-so/ziggy-pydust).

## Benchmarks

Benchmarks can be run with `zig build bench -Doptimize=ReleaseSafe`

As with all benchmarks, take the results with a pinch of salt.

> I found the performance of benchmarks varies greatly depending on whether the inputs and outputs are stack allocated or
  heap allocated. I was surprised to find that often heap allocation was significantly faster than stack allocation.
  If anyone happens to know why, please do let me know!
