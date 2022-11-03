// HACK: duplicated to leizd-aptos-core
module leizd_aptos_trove::base_rate_calculator {
    const PRECISION: u64 = 1000000;

    const MICROSECONDS_IN_MINUTE: u64 = 60 * 1000000;

    const MINUTES_IN_1000_YEARS: u128 = 525600000;

    public fun precision(): u64 {
        PRECISION
    }

    /* 
    * Exponentiation function for 6-digit decimal base, and integer exponent n.
    * 
    * Uses the efficient "exponentiation by squaring" algorithm. O(log(n)) complexity. 
    * 
    * Called by only one function that represents time in units of minutes:
    * - base_rate#calc_decayed_base_rate
    * 
    * The exponent is capped to avoid reverting due to overflow. The cap 525600000 equals
    * "minutes in 1000 years": 60 * 24 * 365 * 1000
    * 
    * If a period of > 1000 years is ever used as an exponent in either of the above functions, the result will be
    * negligibly different from just passing the cap, since: 
    *
    * In calc_decayed_base_rate function, the decayed base rate will be 0 for 1000 years or > 1000 years
    */
    public fun dec_pow(base: u64, minutes: u64): u128 {
        let y = (PRECISION as u128);
        let x = (base as u128);
        let n = (minutes as u128);
        if (n > MINUTES_IN_1000_YEARS) {
            n = MINUTES_IN_1000_YEARS;
        };
        if (n == 0) {
            return (PRECISION as u128)
        };
        while (n > 1) {
            if (n % 2 == 0) {
                x = dec_mul(x, x);
                n = n / 2;
            } else {
                y = dec_mul(x, y);
                x = dec_mul(x, x);
                n = (n - 1) / 2
            }
        };
        dec_mul(x, y)
    }

    /* 
    * Multiply two decimal numbers and use normal rounding rules:
    * -round product up if 7'th mantissa digit >= 5
    * -round product down if 7'th mantissa digit < 5
    *
    * Used only inside the exponentiation, calc_dec_pow().
    */
    fun dec_mul(x: u128, y: u128):u128 {
        let prod_xy = x * y;
        let precision = (PRECISION as u128);
        (prod_xy + (precision / 2)) / (precision)
    }

    #[test]
    fun test_dec_pow() {
        // TODO: add test cases
        assert!(dec_pow(2 * PRECISION, 3) == (8 * PRECISION as u128), (dec_pow(2 * PRECISION, 3) as u64));
    }

}
