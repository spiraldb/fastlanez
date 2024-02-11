# Fastlanez

A toolkit for building SIMD compression codecs based on the [FastLanes compression layout](https://www.vldb.org/pvldb/vol16/p2132-afroozeh.pdf).

## What is FastLanes?

## Why Zig?

## C Library

Can be built in any of scalar, SIMD, or auto-vectorized mode.

## Design

* FastLanes for a given width. Default is 1024.
* Code that finds a 256 byte aligned starting point, and handles the beginning.
* Code that finds the largest 1024 bit things and handles the end.
* Tranposed kernels, e.g. Delta and RLE. These operate over 1024 bit vectors.
* Bit-packing
* Fused bit-packing


FastLanes ISA - construct an ISA for building fastlanes algorithms.
The ISA implements the various operations required.
* Scalar_64T - performs operations over uint64 values
* Scalar_AV - auto-vectorized pure scalar operations
* Vector - performs operations using Zig @Vectors
* SIMD_{arch} - uses $arch specific intrinsics

### Bit-Packing

### Fused FFOR

### Delta

### RLE

Fastlanes-RLE focusses on systems that represent data in-memory as dict-encoded.
The dictionary is the "values" vector (so may not be unique).
The codes (index) vector increases by one for each new run. So 0 0 0 1 1 2 2 2 3 3 etc.
The codes vector can then be delta-encoded using 1 bit per value (0 for same, 1 for increment).

Notes:
* For long average run lengths, the codes vector should store deltas as patches over a zero array.
  It essentially becomes a bit-set indicating where each new run begins.
* For short run lengths (<12),