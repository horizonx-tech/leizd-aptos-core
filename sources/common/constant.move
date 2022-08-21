module leizd::constant {

    const DECIMAL_PRECISION_U64: u64 = 1000000000000000000;
    const DECIMAL_PRECISION_U128: u128 = 1000000000000000000;
    const U64_MAX: u64 = 18446744073709551615;
    const LOG2_E: u128 = 1442695040888963407;

    public fun decimal_precision_u64(): u64 {
        DECIMAL_PRECISION_U64
    }

    public fun decimal_precision_u128(): u128 {
        DECIMAL_PRECISION_U128
    }

    public fun u64_max(): u64 {
        U64_MAX
    }
}