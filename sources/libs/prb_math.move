module leizd::prb_math {
    const SCALE: u128 = 1000000000;

    /// @param x The exponent as an unsigned 96.32-bit fixed-point number.
    /// @return The result as an unsigned 30.9-decimal fixed-point number.
    public fun exp2(x: u128): u128 {

        let result = 0x8000000000000000;
        if (x & 0x8000000000000000 > 0) result = (result * 0x16A09E667F3BCC90) >> 64;
        if (x & 0x4000000000000000 > 0) result = (result * 0x1306FE0A31B7152D) >> 64;
        if (x & 0x2000000000000000 > 0) result = (result * 0x1172B83C7D517ADC) >> 64;
        if (x & 0x1000000000000000 > 0) result = (result * 0x10B5586CF9890F62) >> 64;
        if (x & 0x800000000000000 > 0) result = (result * 0x1059B0D31585743A) >> 64;
        if (x & 0x400000000000000 > 0) result = (result * 0x102C9A3E778060EE) >> 64;
        if (x & 0x200000000000000 > 0) result = (result * 0x10163DA9FB33356D) >> 64;
        if (x & 0x100000000000000 > 0) result = (result * 0x100B1AFA5ABCBED6) >> 64;
        if (x & 0x80000000000000 > 0) result = (result * 0x10058C86DA1C09EA) >> 64;
        if (x & 0x40000000000000 > 0) result = (result * 0x1002C605E2E8CEC5) >> 64;
        if (x & 0x20000000000000 > 0) result = (result * 0x100162F3904051FA) >> 64;
        if (x & 0x10000000000000 > 0) result = (result * 0x1000B175EFFDC76B) >> 64;
        if (x & 0x8000000000000 > 0) result = (result * 0x100058BA01FB9F96) >> 64;
        if (x & 0x4000000000000 > 0) result = (result * 0x10002C5CC37DA949) >> 64;
        if (x & 0x2000000000000 > 0) result = (result * 0x1000162E525EE054) >> 64;
        if (x & 0x1000000000000 > 0) result = (result * 0x10000B17255775C0) >> 64;
        if (x & 0x800000000000 > 0) result = (result * 0x1000058B91B5BC9A) >> 64;
        if (x & 0x400000000000 > 0) result = (result * 0x100002C5C89D5EC6) >> 64;
        if (x & 0x200000000000 > 0) result = (result * 0x10000162E43F4F83) >> 64;
        if (x & 0x100000000000 > 0) result = (result * 0x100000B1721BCFC9) >> 64;
        if (x & 0x80000000000 > 0) result = (result * 0x10000058B90CF1E6) >> 64;
        if (x & 0x40000000000 > 0) result = (result * 0x1000002C5C863B73) >> 64;
        if (x & 0x20000000000 > 0) result = (result * 0x100000162E430E5A) >> 64;
        if (x & 0x10000000000 > 0) result = (result * 0x1000000B17218355) >> 64;
        if (x & 0x8000000000 > 0) result = (result * 0x100000058B90C0B4) >> 64;
        if (x & 0x4000000000 > 0) result = (result * 0x10000002C5C8601C) >> 64;
        if (x & 0x2000000000 > 0) result = (result * 0x1000000162E42FFF) >> 64;
        if (x & 0x1000000000 > 0) result = (result * 0x10000000B17217FB) >> 64;
        if (x & 0x800000000 > 0) result = (result * 0x1000000058B90BFC) >> 64;
        if (x & 0x400000000 > 0) result = (result * 0x100000002C5C85FE) >> 64;
        if (x & 0x200000000 > 0) result = (result * 0x10000000162E42FF) >> 64;
        if (x & 0x100000000 > 0) result = (result * 0x100000000B17217F) >> 64;
        if (x & 0x80000000 > 0) result = (result * 0x10000000058B90BF) >> 64;
        if (x & 0x40000000 > 0) result = (result * 0x1000000002C5C85F) >> 64;
        if (x & 0x20000000 > 0) result = (result * 0x100000000162E42F) >> 64;
        if (x & 0x10000000 > 0) result = (result * 0x1000000000B17217) >> 64;
        if (x & 0x8000000 > 0) result = (result * 0x100000000058B90B) >> 64;
        if (x & 0x4000000 > 0) result = (result * 0x10000000002C5C85) >> 64;
        if (x & 0x2000000 > 0) result = (result * 0x1000000000162E42) >> 64;
        if (x & 0x1000000 > 0) result = (result * 0x10000000000B1721) >> 64;
        if (x & 0x800000 > 0) result = (result * 0x1000000000058B90) >> 64;
        if (x & 0x400000 > 0) result = (result * 0x100000000002C5C8) >> 64;
        if (x & 0x200000 > 0) result = (result * 0x10000000000162E4) >> 64;
        if (x & 0x100000 > 0) result = (result * 0x100000000000B172) >> 64;
        if (x & 0x80000 > 0) result = (result * 0x10000000000058B9) >> 64;
        if (x & 0x40000 > 0) result = (result * 0x1000000000002C5C) >> 64;
        if (x & 0x20000 > 0) result = (result * 0x100000000000162E) >> 64;
        if (x & 0x10000 > 0) result = (result * 0x1000000000000B17) >> 64;
        if (x & 0x8000 > 0) result = (result * 0x100000000000058B) >> 64;
        if (x & 0x4000 > 0) result = (result * 0x10000000000002C5) >> 64;
        if (x & 0x2000 > 0) result = (result * 0x1000000000000162) >> 64;
        if (x & 0x1000 > 0) result = (result * 0x10000000000000B1) >> 64;
        if (x & 0x800 > 0) result = (result * 0x1000000000000058) >> 64;
        if (x & 0x400 > 0) result = (result * 0x100000000000002C) >> 64;
        if (x & 0x200 > 0) result = (result * 0x1000000000000016) >> 64;
        if (x & 0x100 > 0) result = (result * 0x100000000000000B) >> 64;
        if (x & 0x80 > 0) result = (result * 0x1000000000000005) >> 64;
        if (x & 0x40 > 0) result = (result * 0x1000000000000002) >> 64;
        if (x & 0x20 > 0) result = (result * 0x1000000000000001) >> 64;
        if (x & 0x10 > 0) result = (result * 0x1000000000000000) >> 64;
        
        result = result << (((x >> 64) + 1) as u8);
        
        // result *= 1e9 / 2^16
        result = result * 1000000000 / 18446744073709551616;
        result
    }
}
