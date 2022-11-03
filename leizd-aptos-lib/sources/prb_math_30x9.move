module leizd_aptos_lib::prb_math_30x9 {
    use leizd_aptos_lib::prb_math;

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
        // Without this check, the value passed to "exp2" would be less than -29897352854.
        if (!positive && x > 20723265849) {
            return 0
        };
        
        // Without this check, the value passed to "exp2" would be greater than 64e9.
        assert!(positive && x < 44361419583 || !positive, 0);

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

    #[test]
    public entry fun test_exp_positive() {
        let result = exp(1, true);
        assert!(result == 1000000000, 0); // CHECK: 1000000001

        let result = exp(321200000, true);
        assert!(result == 1378781309, 0); // CHECK: 1.378781310

        let result = exp(500000000, true);
        assert!(result == 1648721270, 0); // CHECK: 1.648721271

        let result = exp(1000000000, true);
        assert!(result == 2718281826, 0); // CHECK: 2.718281828

        let result = exp(2000000000, true);
        assert!(result == 7389056089, 0); // CHECK: 7.389056099

        let result = exp(2718281828, true);
        assert!(result == 15154262213, 0); // CHECK: 15.154262235

        let result = exp(3141592653, true);
        assert!(result == 23140692571, 0); // CHECK: 23.1406926191310
    }

    #[test]
    public entry fun test_exp_negative() {
        let result = exp(1, false);
        assert!(result == 1000000000, 0); // CHECK: 0.999999999

        let result = exp(10000, false);
        assert!(result == 999990000, 0);

        let result = exp(321200000, false);
        assert!(result == 725278181, 0); 

        let result = exp(500000000, false);
        assert!(result == 606530659, 0);

        let result = exp(1000000000, false);
        assert!(result == 367879441, 0);

        let result = exp(2000000000, false);
        assert!(result == 135335283, 0);

        let result = exp(2718281828, false);
        assert!(result == 65988035, 0);

        let result = exp(3141592653, false);
        assert!(result == 43213918, 0);
    }

    #[test]
    public entry fun test_exp2_positive() {
        let result = exp2(1, true);
        assert!(result == 1000000000, 0);

        let result = exp2(10000, true);
        assert!(result == 1000006931, 0);

        let result = exp2(321200000, true);
        assert!(result == 1249369313, 0);

        let result = exp2(500000000, true);
        assert!(result == 1414213562, 0);

        let result = exp2(1000000000, true);
        assert!(result == 2000000000, 0);

        let result = exp2(1000000000, true);
        assert!(result == 2000000000, 0);

        let result = exp2(2000000000, true);
        assert!(result == 4000000000, 0);

        let result = exp2(2718281828, true);
        assert!(result == 6580885988, 0);

        let result = exp2(3141592653, true);
        assert!(result == 8824977823, 0);
    }

    #[test]
    public entry fun test_exp2_negative() {
        let result = exp2(1, false);
        assert!(result == 1000000000, 0);

        let result = exp2(10000, false);
        assert!(result == 999993069, 0); // 1000000000000000000 / 1000006931

        let result = exp2(321200000, false);
        assert!(result == 800403843, 0); // 1000000000000000000 / 1249369313

        let result = exp2(500000000, false);
        assert!(result == 707106781, 0); // 1000000000000000000 / 1414213562

        let result = exp2(1000000000, false);
        assert!(result == 500000000, 0); // 1000000000000000000 / 2000000000

        let result = exp2(2000000000, false);
        assert!(result == 250000000, 0); // 1000000000000000000 / 4000000000

        let result = exp2(2718281828, false);
        assert!(result == 151955223, 0); // 1000000000000000000 / 6580885988

        let result = exp2(3141592653, false);
        assert!(result == 113314732, 0); // 1000000000000000000 / 8824977823
    }
}