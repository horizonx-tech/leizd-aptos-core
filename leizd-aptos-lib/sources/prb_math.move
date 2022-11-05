module leizd_aptos_lib::prb_math {

    use leizd_aptos_lib::fixed_point64;

    const SCALE: u128 = 1000000000;

    /// - This function does not work with fixed-point numbers.
    public fun sqrt(x: u128): u128 {
        if (x == 0) {
            return 0
        };
        let x_aux = x;
        let result = 1;
        if (x_aux >= 0x10000000000000000) {
            x_aux = x_aux >> 64;
            result = result << 32;
        };
        if (x_aux >= 0x100000000) {
            x_aux = x_aux >> 32;
            result = result << 16;
        };
        if (x_aux >= 0x10000) {
            x_aux = x_aux >> 16;
            result = result << 8;
        };
        if (x_aux >= 0x100) {
            x_aux = x_aux >> 8;
            result = result << 4;
        };
        if (x_aux >= 0x10) {
            x_aux = x_aux >> 4;
            result = result << 2;
        };
        if (x_aux >= 0x4) {
            result = result << 1;
        };
        
        result = (result + x / result) >> 1;
        result = (result + x / result) >> 1;
        result = (result + x / result) >> 1;
        result = (result + x / result) >> 1;
        result = (result + x / result) >> 1;
        result = (result + x / result) >> 1;
        result = (result + x / result) >> 1;
        let rounded_down_result = x / result;
        if (result >= rounded_down_result) {
            rounded_down_result
        } else {
            result
        }
    }

    /// @dev Uses 64.64-bit fixed-point numbers - it is the most efficient way.
    /// `x` should be under 34.100000000 because of the overflow.
    /// @return The result as an unsigned 30.9-decimal fixed-point number.
    public fun exp2(x: u128): u128 {

        let result = 0x8000000000000000;
        if (x & 0x8000000000000000 > 0) result = (result * 0x16A09E667F3BCC909) >> 64;
        if (x & 0x4000000000000000 > 0) result = (result * 0x1306FE0A31B7152DF) >> 64;
        if (x & 0x2000000000000000 > 0) result = (result * 0x1172B83C7D517ADCE) >> 64;
        if (x & 0x1000000000000000 > 0) result = (result * 0x10B5586CF9890F62A) >> 64;
        if (x & 0x800000000000000 > 0) result = (result * 0x1059B0D31585743AE) >> 64;
        if (x & 0x400000000000000 > 0) result = (result * 0x102C9A3E778060EE7) >> 64;
        if (x & 0x200000000000000 > 0) result = (result * 0x10163DA9FB33356D8) >> 64;
        if (x & 0x100000000000000 > 0) result = (result * 0x100B1AFA5ABCBED61) >> 64;
        if (x & 0x80000000000000 > 0) result = (result * 0x10058C86DA1C09EA2) >> 64;
        if (x & 0x40000000000000 > 0) result = (result * 0x1002C605E2E8CEC50) >> 64;
        if (x & 0x20000000000000 > 0) result = (result * 0x100162F3904051FA1) >> 64;
        if (x & 0x10000000000000 > 0) result = (result * 0x1000B175EFFDC76BA) >> 64;
        if (x & 0x8000000000000 > 0) result = (result * 0x100058BA01FB9F96D) >> 64;
        if (x & 0x4000000000000 > 0) result = (result * 0x10002C5CC37DA9492) >> 64;
        if (x & 0x2000000000000 > 0) result = (result * 0x1000162E525EE0547) >> 64;
        if (x & 0x1000000000000 > 0) result = (result * 0x10000B17255775C04) >> 64;
        if (x & 0x800000000000 > 0) result = (result * 0x1000058B91B5BC9AE) >> 64;
        if (x & 0x400000000000 > 0) result = (result * 0x100002C5C89D5EC6D) >> 64;
        if (x & 0x200000000000 > 0) result = (result * 0x10000162E43F4F831) >> 64;
        if (x & 0x100000000000 > 0) result = (result * 0x100000B1721BCFC9A) >> 64;
        if (x & 0x80000000000 > 0) result = (result * 0x10000058B90CF1E6E) >> 64;
        if (x & 0x40000000000 > 0) result = (result * 0x1000002C5C863B73F) >> 64;
        if (x & 0x20000000000 > 0) result = (result * 0x100000162E430E5A2) >> 64;
        if (x & 0x10000000000 > 0) result = (result * 0x1000000B172183551) >> 64;
        if (x & 0x8000000000 > 0) result = (result * 0x100000058B90C0B49) >> 64;
        if (x & 0x4000000000 > 0) result = (result * 0x10000002C5C8601CC) >> 64;
        if (x & 0x2000000000 > 0) result = (result * 0x1000000162E42FFF0) >> 64;
        if (x & 0x1000000000 > 0) result = (result * 0x10000000B17217FBB) >> 64;
        if (x & 0x800000000 > 0) result = (result * 0x1000000058B90BFCE) >> 64;
        if (x & 0x400000000 > 0) result = (result * 0x100000002C5C85FE3) >> 64;
        if (x & 0x200000000 > 0) result = (result * 0x10000000162E42FF1) >> 64;
        if (x & 0x100000000 > 0) result = (result * 0x100000000B17217F8) >> 64;
        if (x & 0x80000000 > 0) result = (result * 0x10000000058B90BFC) >> 64;
        if (x & 0x40000000 > 0) result = (result * 0x1000000002C5C85FE) >> 64;
        if (x & 0x20000000 > 0) result = (result * 0x100000000162E42FF) >> 64;
        if (x & 0x10000000 > 0) result = (result * 0x1000000000B17217F) >> 64;
        if (x & 0x8000000 > 0) result = (result * 0x100000000058B90C0) >> 64;
        if (x & 0x4000000 > 0) result = (result * 0x10000000002C5C860) >> 64;
        if (x & 0x2000000 > 0) result = (result * 0x1000000000162E430) >> 64;
        if (x & 0x1000000 > 0) result = (result * 0x10000000000B17218) >> 64;
        if (x & 0x800000 > 0) result = (result * 0x1000000000058B90C) >> 64;
        if (x & 0x400000 > 0) result = (result * 0x100000000002C5C86) >> 64;
        if (x & 0x200000 > 0) result = (result * 0x10000000000162E43) >> 64;
        if (x & 0x100000 > 0) result = (result * 0x100000000000B1721) >> 64;
        if (x & 0x80000 > 0) result = (result * 0x10000000000058B91) >> 64;
        if (x & 0x40000 > 0) result = (result * 0x1000000000002C5C8) >> 64;
        if (x & 0x20000 > 0) result = (result * 0x100000000000162E4) >> 64;
        if (x & 0x10000 > 0) result = (result * 0x1000000000000B172) >> 64;
        if (x & 0x8000 > 0) result = (result * 0x100000000000058B9) >> 64;
        if (x & 0x4000 > 0) result = (result * 0x10000000000002C5D) >> 64;
        if (x & 0x2000 > 0) result = (result * 0x1000000000000162E) >> 64;
        if (x & 0x1000 > 0) result = (result * 0x10000000000000B17) >> 64;
        if (x & 0x800 > 0) result = (result * 0x1000000000000058C) >> 64;
        if (x & 0x400 > 0) result = (result * 0x100000000000002C6) >> 64;
        if (x & 0x200 > 0) result = (result * 0x10000000000000163) >> 64;
        if (x & 0x100 > 0) result = (result * 0x100000000000000B1) >> 64;
        if (x & 0x80 > 0) result = (result * 0x10000000000000059) >> 64;
        if (x & 0x40 > 0) result = (result * 0x1000000000000002C) >> 64;
        if (x & 0x20 > 0) result = (result * 0x10000000000000016) >> 64;
        if (x & 0x10 > 0) result = (result * 0x1000000000000000B) >> 64;
        if (x & 0x8 > 0) result = (result * 0x10000000000000006) >> 64;
        if (x & 0x4 > 0) result = (result * 0x10000000000000003) >> 64;
        if (x & 0x2 > 0) result = (result * 0x10000000000000001) >> 64;
        if (x & 0x1 > 0) result = (result * 0x10000000000000001) >> 64;

        result = result << (((x >> 64) + 1) as u8);
        
        // result *= 1e9 / 2^64
        result = fixed_point64::divide_u128(
            fixed_point64::multiply_u128(
                1000000000,
                fixed_point64::create_from_raw_value(result)
            ),
            fixed_point64::create_from_raw_value(18446744073709551616)
        );
        result
    }

    #[test]
    fun test_sqrt() {

        let x = 1000000000; // 1.0
        let expected = 1000000000;
        let result = sqrt(x*SCALE);
        assert!(result == expected, 0);

        let x = 2000000000; // 2.0
        let expected = 1414213562;
        let result = sqrt(x*SCALE);
        assert!(result == expected, 0);

        let x = 3000000000; // 3.0
        let expected = 1732050807;
        let result = sqrt(x*SCALE);
        assert!(result == expected, 0);

        let x = 4000000000; // 4.0
        let expected = 2000000000;
        let result = sqrt(x*SCALE);
        assert!(result == expected, 0);

        let x = 500000000; // 0.5
        let expected = 707106781;
        let result = sqrt(x*SCALE);
        assert!(result == expected, 0);

        let x = 15250000000; // 15.25
        let expected = 3905124837;
        let result = sqrt(x*SCALE);
        assert!(result == expected, 0);

        let x = 25175830000; // 25.17583
        let expected = 5017552192;
        let result = sqrt(x*SCALE);
        assert!(result == expected, 0);

        let x = 125175836587; // 125.175836587
        let expected = 11188200775;
        let result = sqrt(x*SCALE);
        assert!(result == expected, 0);

        let x = 353544195156250000000; // 353,544,195,156
        let expected = 594595825041052; // 594,595.825041052
        let result = sqrt(x*SCALE);
        assert!(result == expected, 0);
    }

    #[test]
    fun test_exp2() {
        let x = 1;
        let expected = 1000000000;
        x = (x << 64) / SCALE;
        let result = exp2(x);
        assert!(result == expected, 0);

        let x = 10000;
        let expected = 1000006931;
        x = (x << 64) / SCALE;
        let result = exp2(x);
        assert!(result == expected, 0);

        let x = 321200000;
        let expected = 1249369313;
        x = (x << 64) / SCALE;
        let result = exp2(x);
        assert!(result == expected, 0);

        let x = 500000000;
        let expected = 1414213562;
        x = (x << 64) / SCALE;
        let result = exp2(x);
        assert!(result == expected, 0);

        let x = 1000000000;
        let expected = 2000000000;
        x = (x << 64) / SCALE;
        let result = exp2(x);
        assert!(result == expected, 0);

        let x = 2000000000;
        let expected = 4000000000;
        x = (x << 64) / SCALE;
        let result = exp2(x);
        assert!(result == expected, 0);

        let x = 2718281828;
        let expected = 6580885988;
        x = (x << 64) / SCALE;
        let result = exp2(x);
        assert!(result == expected, 0);

        let x = 3141592653;
        let expected = 8824977823;
        x = (x << 64) / SCALE;
        let result = exp2(x);
        assert!(result == expected, 0);

        let x = 4000000000;
        let expected = 16000000000;
        x = (x << 64) / SCALE;
        let result = exp2(x);
        assert!(result == expected, 0);

        let x = 16000000000;
        let expected = 65536000000000;
        x = (x << 64) / SCALE;
        let result = exp2(x);
        assert!(result == expected, 0);

        let x = 20513000000;
        let expected = 1496333162347630;
        x = (x << 64) / SCALE;
        let result = exp2(x);
        assert!(result == expected, 0);

        let x = 33333333000;
        let expected = 10822636909120553476;
        x = (x << 64) / SCALE; 
        let result = exp2(x);
        assert!(result == expected, 0);
        
        let x = 34100000000;
        let expected = 18412927881256241384;
        x = (x << 64) / SCALE;
        let result = exp2(x);
        assert!(result == expected, 0);
    }
}
