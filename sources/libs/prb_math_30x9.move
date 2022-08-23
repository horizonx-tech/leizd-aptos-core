module leizd::prb_math_30x9 {
    use leizd::prb_math;

    // log2(e) as a signed 30.9-decimal fixed-point number.
    const LOG2_E: u128 = 1442695040;
    // The maximum value a signed 30.9-decimal fixed-point number.
    const MAX_UD30x9: u128 = 340282366920938463463374607431768211455;

    const SCALE: u128      = 1000000000;
    const HALF_SCALE: u128 = 500000000;

    public fun exp(x: u128, positive: bool): u128 {
        let double_scale_product = x * LOG2_E;
        exp2((double_scale_product + HALF_SCALE) / SCALE, positive)
    }

    public fun exp2(x: u128, positive: bool): u128 {

        if (!positive) {
            if (x > 59794705707972522261) { // TODO: magic number
                return 0
            };
            1000000000000000000000000000000000000 / exp2(x, true) // result = 1e36 / exp2(-x)
        } else {
            // 2**64 doesn't fit within the 64.64-bit fixed-point representation.
            assert!(x < 64000000000, 0); // TODO: 64e9?
            let x64x64 = (x << 64) / SCALE;
            prb_math::exp2(x64x64)
        }    
    }
}