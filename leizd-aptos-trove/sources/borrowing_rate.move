// HACK: duplicated to leizd-aptos-core
module leizd_aptos_trove::borrowing_rate {
    use leizd_aptos_trove::base_rate;
    use leizd_aptos_lib::math128;

    fun borrowing_fee_floor(): u64 {
        base_rate::precision() / 1000 / 5 // 0.5%
    }

    fun max_borrowing_fee(): u64 {
        base_rate::precision() / 100 / 5 // 5%
    }

    public fun borrowing_fee(debt_amount: u64): u64 {
        (calc_borrowing_fee(borrowing_rate(), debt_amount) as u64)
    }

    public fun borrowing_fee_with_decay(debt_amount: u64): u64 {
        (calc_borrowing_fee(borrowing_rate_with_decay(), debt_amount) as u64)
    }

    fun borrowing_rate(): u128 {
        calc_borrowing_rate(base_rate::base_rate())
    }

    fun borrowing_rate_with_decay(): u128 {
        calc_borrowing_rate(base_rate::calc_decayed_base_rate())
    }

    fun calc_borrowing_rate(base_rate: u128): u128 {
        math128::min(((borrowing_fee_floor() as u128) + base_rate), (max_borrowing_fee() as u128))
    }

    fun calc_borrowing_fee(borrowing_rate: u128, debt_amount: u64): u128 {
        borrowing_rate / (debt_amount as u128) / (base_rate::precision() as u128)
    }

}
