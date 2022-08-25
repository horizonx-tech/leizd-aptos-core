module leizd::prb_math_30x9 {
    use leizd::prb_math;

    // log2(e) as a signed 30.9-decimal fixed-point number.
    // 1_442695040
    const LOG2_E: u128 = 1442695040;

    // The maximum value a signed 30.9-decimal fixed-point number:
    // 340282366920938463463374607431_768211455
    const MAX_UD30x9: u128 = 340282366920938463463374607431768211455;

    // How many trailing decimals can be represented.
    const SCALE: u128      = 1000000000;

    // Half the SCALE number.
    const HALF_SCALE: u128 = 500000000;

    /// Calculates the natural exponent of x.
    public fun exp(x: u128, positive: bool): u128 {
        // TODO: should be under 64e9 for "exp2"
        let double_scale_product = x * LOG2_E;
        exp2((double_scale_product + HALF_SCALE) / SCALE, positive)
    }

    /// Calculates the binary exponent of x using the binary fraction method.
    public fun exp2(x: u128, positive: bool): u128 {

        if (!positive) {
            // 2**29.897352853 = 1e9
            if (x > 29897352854) {
                return 0
            };
            // The numerator is SCALE * SCALE
            1000000000000000000 / exp2(x, true) // result = 1e18 / exp2(-x)
        } else {
            // 2**64 doesn't fit within the 64.64-bit fixed-point representation.
            assert!(x < 64000000000, 0);
            let x64x64 = (x << 64) / SCALE;
            prb_math::exp2(x64x64)
        }    
    }
}