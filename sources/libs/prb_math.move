module leizd::prb_math {
    const SCALE: u128 = 1000000000;
    const MAX_UD30x9: u128 = 340282366920938463463374607431768211455;

    /// @param x The exponent as an unsigned 96.32-bit fixed-point number.
    /// @return The result as an unsigned 30.9-decimal fixed-point number.
    public fun exp2(x: u128): u128 {
        let result:u128 = 0x800000000000000000000000;
        
        if (x & 0x80000000 > 0) result = (result * 0x16A09E667) >> 32;
        if (x & 0x40000000 > 0) result = (result * 0x1306FE0A3) >> 32;
        if (x & 0x20000000 > 0) result = (result * 0x1172B83C7) >> 32;
        if (x & 0x10000000 > 0) result = (result * 0x10B5586CF) >> 32;
        if (x & 0x8000000 > 0) result = (result * 0x1059B0D31) >> 32;
        if (x & 0x4000000 > 0) result = (result * 0x102C9A3E7) >> 32;
        if (x & 0x2000000 > 0) result = (result * 0x10163DA9F) >> 32;
        if (x & 0x1000000 > 0) result = (result * 0x100B1AFA5) >> 32;
        if (x & 0x800000 > 0) result = (result * 0x10058C86D) >> 32;
        if (x & 0x400000 > 0) result = (result * 0x1002C605E) >> 32;
        if (x & 0x200000 > 0) result = (result * 0x100162F39) >> 32;
        if (x & 0x100000 > 0) result = (result * 0x1000B175E) >> 32;
        if (x & 0x80000 > 0) result = (result * 0x100058BA0) >> 32;
        if (x & 0x40000 > 0) result = (result * 0x10002C5CC) >> 32;
        if (x & 0x20000 > 0) result = (result * 0x1000162E5) >> 32;
        if (x & 0x10000 > 0) result = (result * 0x10000B172) >> 32;
        if (x & 0x8000 > 0) result = (result * 0x1000058B9) >> 32;
        if (x & 0x4000 > 0) result = (result * 0x100002C5C) >> 32;
        if (x & 0x2000 > 0) result = (result * 0x10000162E) >> 32;
        if (x & 0x1000 > 0) result = (result * 0x100000B17) >> 32;
        if (x & 0x800 > 0) result = (result * 0x10000058B) >> 32;
        if (x & 0x400 > 0) result = (result * 0x1000002C5) >> 32;
        if (x & 0x200 > 0) result = (result * 0x100000162) >> 32;
        if (x & 0x100 > 0) result = (result * 0x1000000B1) >> 32;
        if (x & 0x80 > 0) result = (result * 0x100000058) >> 32;
        if (x & 0x40 > 0) result = (result * 0x10000002C) >> 32;
        if (x & 0x20 > 0) result = (result * 0x100000016) >> 32;
        if (x & 0x10 > 0) result = (result * 0x10000000B) >> 32;
        if (x & 0x8 > 0) result = (result * 0x100000005) >> 32;
        if (x & 0x4 > 0) result = (result * 0x100000002) >> 32;
        if (x & 0x2 > 0) result = (result * 0x100000001) >> 32;
        if (x & 0x1 > 0) result = (result * 0x100000001) >> 32;
        
        result = result * SCALE;

        // result >>= (95 - (x >> 32))
        result = result >> ((95 - (x >> 32)) as u8);
        result
    }

    #[test]
    public entry fun test_exp2() {
        // TODO
    }
}
