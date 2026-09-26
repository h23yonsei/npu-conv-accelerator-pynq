"""Equivalence tests: conv2d_9for (tiled) must match conv2d_6for (naive) exactly."""

import numpy as np

from conv2d import conv2d_6for, conv2d_9for

CASES = [
    # stride=1, tile sizes that don't evenly divide the output
    dict(input_ch=2, input_h=10, input_w=10, output_ch=4, kh=3, kw=3, stride=1, tile_h=3, tile_w=3, tile_oc=2),
    # stride=2
    dict(input_ch=1, input_h=7, input_w=7, output_ch=3, kh=2, kw=2, stride=2, tile_h=2, tile_w=2, tile_oc=2),
    # larger random case: a 14x14 output in 5x5 tiles and 3 output channels per tile, so the last tiles are partial
    dict(input_ch=3, input_h=16, input_w=16, output_ch=8, kh=3, kw=3, stride=1, tile_h=5, tile_w=5, tile_oc=3),
    # tile sizes exactly matching output (single tile)
    dict(input_ch=1, input_h=5, input_w=5, output_ch=2, kh=3, kw=3, stride=1, tile_h=3, tile_w=3, tile_oc=2),
    # tile sizes larger than the whole output
    dict(input_ch=4, input_h=6, input_w=6, output_ch=4, kh=3, kw=3, stride=1, tile_h=8, tile_w=8, tile_oc=8),
]


def test_equivalence():
    rng = np.random.default_rng(0)
    for case in CASES:
        i_act = rng.integers(-128, 128, size=(case['input_ch'], case['input_h'], case['input_w']), dtype=np.int8)
        weight = rng.integers(-128, 128, size=(case['output_ch'], case['input_ch'], case['kh'], case['kw']), dtype=np.int8)

        ref = conv2d_6for(i_act, weight, stride=case['stride'])
        tiled = conv2d_9for(
            i_act, weight,
            stride=case['stride'],
            tile_h=case['tile_h'], tile_w=case['tile_w'], tile_oc=case['tile_oc'],
        )

        assert ref.shape == tiled.shape, f"shape mismatch for case {case}: {ref.shape} vs {tiled.shape}"
        assert np.array_equal(ref, tiled), f"value mismatch for case {case}"

    print(f"All {len(CASES)} equivalence cases passed.")


if __name__ == "__main__":
    test_equivalence()
